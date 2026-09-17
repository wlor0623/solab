package zhou.solab.engine

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.ParcelFileDescriptor
import zhou.solab.blutter.BlutterRunnerService
import zhou.solab.blutter.IBlutterRunner
import zhou.solab.blutter.IBlutterRunnerCallback
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap

internal class BlutterEmbeddedBackend(
    private val context: Context,
    private val store: BlutterResultStore,
) {
    private val active = ConcurrentHashMap<String, ActiveJob>()

    fun start(jobId: String, selection: BlutterRunnerSelection, libraries: FlutterRunnerInput, options: JSONObject) {
        val runner = selection.runner
        val nativeDir = context.applicationInfo.nativeLibraryDir
        val runnerBinary = nativeDir?.let { File(it, "lib${runner.libraryName}.so") }
        if (runnerBinary == null || !runnerBinary.isFile || !sha256(runnerBinary).equals(runner.sha256, true)) {
            return fail(jobId, "RUNNER_INTEGRITY_FAILED", "Embedded runner checksum does not match its manifest", "runner_integrity", false)
        }
        val jobDir = store.jobDir(jobId)
        val output = File(jobDir, "runner-result.json").apply { if (exists()) delete() }
        val connection = RunnerConnection(jobId, selection, libraries, libraries.libapp, libraries.libflutter, output, options)
        active[jobId] = ActiveJob(connection)
        store.update(jobId, "running", "binding_runner")
        val intent = Intent(context, BlutterRunnerService::class.java)
        if (!context.bindService(intent, connection, Context.BIND_AUTO_CREATE)) {
            active.remove(jobId)
            runCatching { output.delete() }
            fail(jobId, "RUNNER_BIND_FAILED", "Cannot bind the isolated Blutter runner process", "binding_runner", true)
        }
    }

    fun cancel(jobId: String): Boolean {
        val job = active.remove(jobId) ?: return false
        runCatching { job.runner?.cancel(jobId) }
        store.update(jobId, "cancelling", "cancelling")
        runCatching { context.unbindService(job.connection) }
        (job.connection as? RunnerConnection)?.cleanupFiles()
        return true
    }

    private inner class RunnerConnection(
        private val jobId: String,
        private val selection: BlutterRunnerSelection,
        private val libraries: FlutterRunnerInput,
        private val libapp: File,
        private val libflutter: File,
        private val output: File,
        private val options: JSONObject,
    ) : ServiceConnection {
        private val descriptor = selection.runner
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            val runner = IBlutterRunner.Stub.asInterface(binder)
            val job = active[jobId] ?: return
            job.runner = runner
            store.update(jobId, "running", "runner_execution")
            var appFd: ParcelFileDescriptor? = null
            var flutterFd: ParcelFileDescriptor? = null
            var resultFd: ParcelFileDescriptor? = null
            try {
                appFd = ParcelFileDescriptor.open(libapp, ParcelFileDescriptor.MODE_READ_ONLY)
                flutterFd = ParcelFileDescriptor.open(libflutter, ParcelFileDescriptor.MODE_READ_ONLY)
                resultFd = ParcelFileDescriptor.open(output, ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_TRUNCATE or ParcelFileDescriptor.MODE_READ_WRITE)
                runner.run(jobId, descriptor.libraryName, appFd, flutterFd, resultFd, options.toString(), callback)
            } catch (error: Exception) {
                finishFailure("RUNNER_TRANSPORT_FAILED", error.message ?: "Runner transport failed", true)
            } finally {
                runCatching { appFd?.close() }
                runCatching { flutterFd?.close() }
                runCatching { resultFd?.close() }
            }
        }

        override fun onServiceDisconnected(name: ComponentName) {
            if (active.containsKey(jobId)) finishFailure("RUNNER_INTERRUPTED", "The isolated runner process disconnected", true, "interrupted")
        }

        override fun onBindingDied(name: ComponentName) {
            finishFailure("RUNNER_CRASHED", "The isolated runner process died", true, "interrupted")
        }

        override fun onNullBinding(name: ComponentName) {
            finishFailure("RUNNER_BIND_FAILED", "The isolated runner returned no Binder", true)
        }

        private val callback = object : IBlutterRunnerCallback.Stub() {
            override fun onProgress(callbackJobId: String, stage: String, percent: Int) {
                if (callbackJobId == jobId && active.containsKey(jobId)) store.update(jobId, "running", stage)
            }

            override fun onCompleted(callbackJobId: String, exitCode: Int, errorCode: String, message: String, resultBytes: Long, resultSha256: String) {
                if (callbackJobId != jobId || !active.containsKey(jobId)) return
                if (exitCode != 0 || errorCode.isNotBlank()) {
                    finishFailure(errorCode.ifBlank { "RUNNER_FAILED" }, message.ifBlank { "Blutter runner exited with code $exitCode" }, true)
                    return
                }
                runCatching { commitOutput() }.onFailure { error ->
                    finishFailure("RUNNER_RESULT_INVALID", error.message ?: "Runner result is invalid", false)
                }
            }
        }

        private fun commitOutput() {
            check(output.isFile) { "Runner did not create a result" }
            check(output.length() in 2..MAX_RESULT_BYTES) { "Runner result exceeds the allowed size" }
            val result = JSONObject(output.readText())
            val generated = Instant.now().toString()
            val input = JSONObject()
                .put("displayName", libraries.displayName)
                .put("abi", libraries.abi)
                .put("libapp", fileJson(libraries.libappEntry, libraries.libapp))
                .put("libflutter", fileJson(libraries.libflutterEntry, libraries.libflutter))
            val nativeSummary = result.optJSONObject("summary") ?: error("Missing runner summary")
            for (kind in listOf("libraries", "classes", "functions", "objects")) {
                val page = result.optJSONObject(kind) ?: error("Missing result page: $kind")
                check(page.has("items") && page.has("total") && page.has("hasMore") && page.has("nextCursor")) { "Invalid result page: $kind" }
                validateEntities(page.optJSONArray("items"), kind)
            }
            result.put("jobId", jobId).put("status", "succeeded").put("backend", "embedded")
                .put("createdAt", generated).put("completedAt", generated).put("input", input)
                .put("flutter", JSONObject().put("dartVersion", JSONObject.NULL).put("engineRevision", JSONObject.NULL).put("compressedPointers", JSONObject.NULL).put("nullSafety", JSONObject.NULL).put("confidence", 0.0))
                .put("runner", JSONObject().put("runnerId", descriptor.runnerId).put("source", "embedded").put("upstreamCommit", descriptor.upstreamCommit).put("sha256", descriptor.sha256).put("match", selection.toJson()))
                .put("summary", nativeSummary)
                .put("provenance", JSONObject().put("protocolVersion", 1).put("normalizerVersion", "native-1").put("cacheHit", false).put("durationMillis", 0))
            val key = BlutterResultStore.resultKey(
                libraries.libapp,
                libraries.libflutter,
                descriptor.sha256,
                BlutterResultStore.analysisCacheOptions(options),
            )
            store.update(jobId, "running", "committing")
            store.commit(jobId, result, key)
            finish()
        }

        private fun finishFailure(code: String, message: String, recoverable: Boolean, status: String = "failed") {
            fail(jobId, code, message, "runner_execution", recoverable, status)
            finish()
        }

        private fun finish() {
            if (active.remove(jobId) != null) runCatching { context.unbindService(this) }
            cleanupFiles()
        }

        fun cleanupFiles() {
            runCatching { output.delete() }
        }
    }

    private fun fail(jobId: String, code: String, message: String, stage: String, recoverable: Boolean, status: String = "failed") {
        store.update(jobId, status, stage, JSONObject().put("code", code).put("message", message).put("recoverable", recoverable).put("stage", stage))
    }

    private fun digest(libapp: File, libflutter: File, runnerSha256: String, options: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        listOf(libapp, libflutter).forEach { file ->
            file.inputStream().use { input ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
        }
        digest.update(runnerSha256.toByteArray())
        digest.update(options.toByteArray())
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun fileJson(name: String, file: File): JSONObject = JSONObject().put("name", name).put("size", file.length()).put("sha256", sha256(file))
    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
    private fun validateEntities(items: org.json.JSONArray?, kind: String) {
        require(items != null) { "Missing items for $kind" }
        for (index in 0 until items.length()) {
            val item = items.optJSONObject(index) ?: error("Invalid entity in $kind")
            val expectedKind = mapOf("libraries" to "library", "classes" to "class", "functions" to "function", "objects" to "object")[kind] ?: error("Unsupported result kind")
            require(item.optString("kind") == expectedKind) { "Invalid entity kind in $kind" }
            require(item.optString("id").isNotBlank() && item.has("name")) { "Invalid entity fields in $kind" }
            if (item.has("address") && !item.isNull("address")) require(item.optString("address").matches(Regex("^0x[0-9a-fA-F]+$"))) { "Invalid entity address" }
        }
    }

    private data class ActiveJob(val connection: ServiceConnection, var runner: IBlutterRunner? = null)

    private companion object {
        const val MAX_RESULT_BYTES = 512L * 1024L * 1024L
    }
}
