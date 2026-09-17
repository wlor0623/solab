package zhou.solab.engine

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

internal data class BlutterRunnerRequirement(
    val engineRevision: String?,
    val dartVersion: String?,
    val snapshotHash: String?,
    val abi: String,
    val compressedPointers: Boolean,
    val analysis: Boolean,
)

internal data class BlutterRunnerDescriptor(
    val runnerId: String,
    val dartVersion: String?,
    val engineRevision: String?,
    val abi: String,
    val compressedPointers: Boolean,
    val analysis: Boolean,
    val sha256: String,
    val source: String,
    val libraryName: String,
    val upstreamCommit: String = "",
    val dartRevision: String? = null,
    val snapshotAliases: List<String> = emptyList(),
    val backend: String = "embedded",
    val staticStatus: String = "unverified",
    val smokeStatus: String = "not_run",
    val packagedSha256: String? = null,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("runnerId", runnerId)
        .put("dartVersion", dartVersion ?: JSONObject.NULL)
        .put("engineRevision", engineRevision ?: JSONObject.NULL)
        .put("abi", abi)
        .put("compressedPointers", compressedPointers)
        .put("analysis", analysis)
        .put("sha256", sha256)
        .put("packagedSha256", packagedSha256 ?: JSONObject.NULL)
        .put("source", source)
        .put("libraryName", libraryName)
        .put("upstreamCommit", upstreamCommit)
        .put("dartRevision", dartRevision ?: JSONObject.NULL)
        .put("snapshotAliases", JSONArray(snapshotAliases))
        .put("backend", backend)
        .put("staticStatus", staticStatus)
        .put("smokeStatus", smokeStatus)
}

internal data class BlutterRunnerSelection(
    val runner: BlutterRunnerDescriptor,
    val strategy: String,
    val verified: Boolean,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("strategy", strategy)
        .put("verified", verified)
        .put("warning", if (verified) JSONObject.NULL else "Runner is a Dart-version fallback; engine/snapshot compatibility is not independently verified.")
}

internal data class BlutterRunnerIntegrity(
    val status: String,
    val bytes: Long,
)

internal object BlutterCapabilityFormatter {
    fun format(
        manifest: JSONObject,
        runners: List<BlutterRunnerDescriptor>,
        integrity: Map<String, BlutterRunnerIntegrity>,
        args: JSONObject = JSONObject(),
    ): JSONObject {
        val coverage = manifest.optJSONArray("coverage") ?: JSONArray()
        val coverageStatuses = linkedMapOf<String, Int>()
        var supportedCoverage = 0
        for (index in 0 until coverage.length()) {
            val item = coverage.optJSONObject(index) ?: continue
            val status = item.optString("status", "unknown")
            coverageStatuses[status] = (coverageStatuses[status] ?: 0) + 1
            if (item.optBoolean("supported")) supportedCoverage++
        }
        val runnerItems = JSONArray(runners.map { runner ->
            val health = integrity[runner.runnerId] ?: BlutterRunnerIntegrity("unknown", 0)
            JSONObject()
                .put("runnerId", runner.runnerId)
                .put("dartVersion", runner.dartVersion ?: JSONObject.NULL)
                .put("abi", runner.abi)
                .put("backend", runner.backend)
                .put("analysis", runner.analysis)
                .put("integrityStatus", health.status)
                .put("bytes", health.bytes)
                .put("staticStatus", runner.staticStatus)
                .put("smokeStatus", runner.smokeStatus)
        })
        val integrityCounts = linkedMapOf<String, Int>()
        integrity.values.forEach { health -> integrityCounts[health.status] = (integrityCounts[health.status] ?: 0) + 1 }
        val response = JSONObject()
            .put("schemaVersion", manifest.optInt("schemaVersion", 2))
            .put("matrixVersion", manifest.optString("matrixVersion"))
            .put("protocolVersion", manifest.optInt("protocolVersion", 1))
            .put("upstreamCommit", manifest.optString("upstreamCommit"))
            .put("execution", "all_in_one_apk")
            .put("fullyOffline", true)
            .put("runnerCount", runners.size)
            .put("runners", runnerItems)
            .put("summary", JSONObject()
                .put("backends", counts(runners.map { it.backend }))
                .put("abis", JSONArray(runners.map { it.abi }.distinct().sorted()))
                .put("integrity", JSONObject(integrityCounts as Map<*, *>))
                .put("coverageTotal", coverage.length())
                .put("coverageSupported", supportedCoverage)
                .put("coverageStatuses", JSONObject(coverageStatuses as Map<*, *>)))
        if (args.optBoolean("fullInventory", false)) {
            val offset = args.optInt("offset", 0).coerceIn(0, coverage.length())
            val limit = args.optInt("limit", 20).coerceIn(1, 50)
            val end = minOf(offset + limit, coverage.length())
            val items = JSONArray()
            for (index in offset until end) items.put(coverage.get(index))
            response.put("coverage", JSONObject()
                .put("items", items)
                .put("total", coverage.length())
                .put("offset", offset)
                .put("hasMore", end < coverage.length())
                .put("nextOffset", if (end < coverage.length()) end else JSONObject.NULL))
        }
        return response
    }

    private fun counts(values: List<String>): JSONObject {
        val counts = linkedMapOf<String, Int>()
        values.forEach { counts[it] = (counts[it] ?: 0) + 1 }
        return JSONObject(counts as Map<*, *>)
    }
}

internal object BlutterRunnerMatcher {
    fun select(requirement: BlutterRunnerRequirement, runners: List<BlutterRunnerDescriptor>): BlutterRunnerDescriptor? =
        selectWithEvidence(requirement, runners)?.runner

    fun selectWithEvidence(requirement: BlutterRunnerRequirement, runners: List<BlutterRunnerDescriptor>): BlutterRunnerSelection? {
        val eligible = runners.asSequence()
            .filter { it.abi == requirement.abi && (!requirement.analysis || it.analysis) }
            .filter { it.backend == "exec" || it.compressedPointers == requirement.compressedPointers }
            .toList()
        requirement.engineRevision?.let { revision ->
            eligible.firstOrNull { it.engineRevision == revision }?.let {
                return BlutterRunnerSelection(it, "exact_engine", true)
            }
        }
        requirement.snapshotHash?.lowercase()?.let { snapshot ->
            eligible.firstOrNull { runner -> runner.snapshotAliases.any { it.equals(snapshot, true) } }?.let {
                return BlutterRunnerSelection(it, "exact_snapshot", true)
            }
        }
        requirement.dartVersion?.let { version ->
            eligible.firstOrNull { it.dartVersion == version }?.let {
                return BlutterRunnerSelection(it, "exact_dart", false)
            }
        }
        return compatible(requirement, eligible)?.let { BlutterRunnerSelection(it, "dart_minor_fallback", false) }
    }

    // exec runner 按 major.minor 前缀匹配（如目标 3.12.2 命中 runner 3.12）；
    // 压缩指针由 runner 运行时从 snapshot flags 自行检测，匹配阶段忽略。
    private fun compatible(requirement: BlutterRunnerRequirement, runners: List<BlutterRunnerDescriptor>): BlutterRunnerDescriptor? {
        val version = requirement.dartVersion ?: return null
        val parts = version.split('.')
        if (parts.size < 2) return null
        val prefix = if (parts.size >= 3) "${parts[0]}.${parts[1]}" else version
        return runners
            .filter { it.backend == "exec" && it.abi == requirement.abi && it.dartVersion == prefix && (!requirement.analysis || it.analysis) }
            .minByOrNull { it.runnerId }
    }
}

internal class BlutterRunnerRegistry(private val context: Context) {
    private val manifest by lazy { loadManifest() }
    val upstreamCommit: String get() = manifest.optString("upstreamCommit")
    val runners: List<BlutterRunnerDescriptor> by lazy { parseRunners(manifest.optJSONArray("runners"), "embedded") }
    private val integrity by lazy { verifyPackagedRunners() }

    fun select(requirement: BlutterRunnerRequirement): BlutterRunnerDescriptor? = BlutterRunnerMatcher.select(requirement, runners)
    fun selectWithEvidence(requirement: BlutterRunnerRequirement): BlutterRunnerSelection? = BlutterRunnerMatcher.selectWithEvidence(requirement, runners)

    fun capabilities(args: JSONObject = JSONObject()): JSONObject = BlutterCapabilityFormatter.format(manifest, runners, integrity, args)

    private fun verifyPackagedRunners(): Map<String, BlutterRunnerIntegrity> = runners.associate { runner ->
        val file = File(context.applicationInfo.nativeLibraryDir, "lib${runner.libraryName}.so")
        // Android 安装时使用 Gradle strip 后的 runner；sha256 对应安装/执行文件，
        // packagedSha256 对应 strip 前的构建输入，不能拿来校验 nativeLibraryDir。
        val expected = runner.sha256
        val status = when {
            !file.isFile -> "missing"
            runCatching { sha256(file) }.getOrNull() != expected -> "hash_mismatch"
            else -> "ready"
        }
        runner.runnerId to BlutterRunnerIntegrity(status, if (file.isFile) file.length() else 0)
    }

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

    private fun loadManifest(): JSONObject = context.assets.open("blutter/runners.json").bufferedReader().use { JSONObject(it.readText()) }

    private fun parseRunners(array: JSONArray?, source: String): List<BlutterRunnerDescriptor> {
        if (array == null) return emptyList()
        return (0 until array.length()).mapNotNull { index ->
            val item = array.optJSONObject(index) ?: return@mapNotNull null
            val id = item.optString("runnerId")
            val abi = item.optString("abi")
            val sha256 = item.optString("sha256")
            if (id.isBlank() || abi.isBlank() || !sha256.matches(Regex("[a-f0-9]{64}"))) return@mapNotNull null
            val libraryName = item.optString("libraryName")
            if (!libraryName.matches(Regex("^blutter_[A-Za-z0-9_]+$"))) return@mapNotNull null
            val aliases = item.optJSONArray("snapshotAliases")?.let { array -> (0 until array.length()).mapNotNull(array::optString) } ?: emptyList()
            val backend = item.optString("backend", "embedded").takeIf { it == "exec" } ?: "embedded"
            val packagedSha256 = item.optString("packagedSha256").takeIf { it.matches(Regex("[a-f0-9]{64}")) }
            BlutterRunnerDescriptor(id, item.optString("dartVersion").takeIf { it.isNotBlank() }, item.optString("engineRevision").takeIf { it.isNotBlank() }, abi, item.optBoolean("compressedPointers"), item.optBoolean("analysis", true), sha256, if (backend == "exec") item.optString("source", "blutter-termux") else source, libraryName, manifest.optString("upstreamCommit"), item.optString("dartRevision").takeIf { it.isNotBlank() }, aliases, backend, item.optString("staticStatus", "unverified"), item.optString("smokeStatus", "not_run"), packagedSha256)
        }
    }
}
