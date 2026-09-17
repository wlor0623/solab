package zhou.solab.engine

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

// exec 后端：调用打包在 nativeLibraryDir 里的 blutter-termux 可执行 runner
//（libblutter_<dart>.so，命令行约定：runner -i <libapp文件> -o <输出目录>，产出 pp.txt + objs.txt）。
// 子进程天然隔离，无需 isolated-process 服务；ICU 依赖通过 LD_LIBRARY_PATH 解析。
internal class BlutterExecBackend(private val context: Context, private val store: BlutterResultStore) {
    private val executor = Executors.newSingleThreadExecutor()
    private val postExecutor = Executors.newSingleThreadExecutor()
    private val active = ConcurrentHashMap<String, Process>()

    fun start(jobId: String, selection: BlutterRunnerSelection, libraries: FlutterRunnerInput, options: JSONObject, workDirectory: WorkDirectory? = null) {
        val runner = selection.runner
        val nativeDir = context.applicationInfo.nativeLibraryDir ?: return fail(jobId, "RUNNER_BIN_NOT_FOUND", "nativeLibraryDir is unavailable", "runner_launch")
        val runnerBin = File(nativeDir, "lib${runner.libraryName}.so")
        if (!runnerBin.isFile) return fail(jobId, "RUNNER_BIN_NOT_FOUND", "Exec runner ${runner.libraryName} is not bundled in this build (heavyLibs=false?)", "runner_launch")
        val actualSha256 = sha256(runnerBin)
        if (!actualSha256.equals(runner.sha256, true)) return fail(jobId, "RUNNER_INTEGRITY_FAILED", "Exec runner checksum does not match its manifest", "runner_integrity")
        val runnerCxx = File(nativeDir, "libblutter_cxx.so")
        val runnerCapstone = File(nativeDir, "libblutter_capstone.so")
        if (!runnerCxx.isFile || !runnerCapstone.isFile) return fail(jobId, "RUNNER_RUNTIME_NOT_FOUND", "Blutter runtime libraries are not bundled", "runner_launch")
        val jobDir = store.jobDir(jobId)
        val runnerTempDir = File(context.cacheDir, "blutter-runner/$jobId").apply { mkdirs() }
        val runnerRuntimeDir = File(context.codeCacheDir, "blutter-runtime/$jobId").apply { mkdirs() }
        runnerCxx.copyTo(File(runnerRuntimeDir, "libc++_shared.so"), overwrite = true)
        runnerCapstone.copyTo(File(runnerRuntimeDir, "libcapstone.so"), overwrite = true)
        val libapp = libraries.libapp
        val outputDir = File(jobDir, "output").apply { mkdirs() }
        store.update(jobId, "running", "runner_launch")
        executor.submit {
            if (store.get(jobId)?.optString("status") == "cancelled") {
                runCatching { runnerTempDir.deleteRecursively() }
                runCatching { runnerRuntimeDir.deleteRecursively() }
                return@submit
            }
            if (active.containsKey(jobId)) {
                runCatching { runnerTempDir.deleteRecursively() }
                runCatching { runnerRuntimeDir.deleteRecursively() }
                return@submit
            }
            val started = System.currentTimeMillis()
            val consoleFile = File(runnerTempDir, "console.log")
            val process = try {
                ProcessBuilder("/system/bin/linker64", runnerBin.absolutePath, "-i", libapp.absolutePath, "-o", outputDir.absolutePath)
                    .apply { environment()["LD_LIBRARY_PATH"] = "${runnerRuntimeDir.absolutePath}:$nativeDir" }
                    .redirectErrorStream(true)
                    .redirectOutput(consoleFile)
                    .start()
            } catch (error: Exception) {
                runCatching { runnerTempDir.deleteRecursively() }
                runCatching { runnerRuntimeDir.deleteRecursively() }
                return@submit fail(jobId, "RUNNER_LAUNCH_FAILED", error.message ?: "Cannot launch exec runner", "runner_launch")
            }
            active[jobId] = process
            store.progress(jobId, "runner_execution", "Runner 已启动，正在解析 Dart AOT")
            try {
                var finished = false
                while (!finished && System.currentTimeMillis() - started < TimeUnit.MINUTES.toMillis(TIMEOUT_MINUTES)) {
                    finished = process.waitFor(HEARTBEAT_SECONDS, TimeUnit.SECONDS)
                    if (!finished) {
                        val (bytes, files) = outputMetrics(outputDir)
                        val stage = if (files > 0) "writing_indexes" else "runner_execution"
                        val message = if (files > 0) "正在生成对象池和反汇编，已产生 $files 个文件" else "正在解析 Dart AOT，runner 仍在运行"
                        store.progress(jobId, stage, message, bytes, files)
                    }
                }
                if (!finished) {
                    process.destroyForcibly()
                    return@submit fail(jobId, "RUNNER_TIMEOUT", "Exec runner exceeded ${TIMEOUT_MINUTES}m limit", "runner_execution")
                }
                val console = runCatching { consoleFile.readText().takeLast(MAX_CONSOLE_CHARS) }.getOrDefault("")
                val objs = File(outputDir, "objs.txt")
                val pp = File(outputDir, "pp.txt")
                val asm = File(outputDir, "asm")
                val hasUsableOutput = objs.length() > 0 && pp.length() > 0 &&
                    asm.walkTopDown().any { it.isFile && it.extension == "dart" }
                if (process.exitValue() != 0 && !hasUsableOutput) {
                    return@submit fail(jobId, "RUNNER_FAILED", "Exec runner exited with code ${process.exitValue()}: ${console.takeLast(2000)}", "runner_execution")
                }
                if (!objs.isFile) return@submit fail(jobId, "RUNNER_RESULT_INVALID", "Runner produced no objs.txt: ${console.takeLast(2000)}", "runner_execution")
                commit(jobId, selection, libraries, options, outputDir, System.currentTimeMillis() - started, workDirectory)
            } catch (error: Exception) {
                fail(jobId, "RUNNER_EXCEPTION", error.message ?: error.javaClass.simpleName, "runner_execution")
            } finally {
                active.remove(jobId)
                runCatching { runnerTempDir.deleteRecursively() }
                runCatching { runnerRuntimeDir.deleteRecursively() }
            }
        }
    }

    fun cancel(jobId: String): Boolean {
        val process = active.remove(jobId) ?: return false
        process.destroyForcibly()
        return true
    }

    private fun commit(jobId: String, selection: BlutterRunnerSelection, libraries: FlutterRunnerInput, options: JSONObject, outputDir: File, durationMillis: Long, workDirectory: WorkDirectory?) {
        val runner = selection.runner
        val key = store.get(jobId)?.optString("analysisKey")
            ?.takeIf { it.matches(Regex("^[a-f0-9]{32,128}$")) }
            ?: BlutterResultStore.resultKey(
                libraries.libapp,
                libraries.libflutter,
                runner.sha256,
                BlutterResultStore.analysisCacheOptions(options),
            )
        // 修复路径不一致：产物必须和 result.json 落到同一个目录（store 的 root，
        // 已被 bindBlutterRoot 重定向到工作目录），否则 locate/search/xref 读不到
        // pp.txt/objs.txt/asm（此前硬编码 context.noBackupFilesDir 内部目录导致 ENOENT）。
        val resultDir = store.resultDirForKey(key)
        val asmDir = File(outputDir, "asm")
        if (store.get(jobId)?.optString("status") == "cancelled") {
            resultDir.deleteRecursively()
            outputDir.deleteRecursively()
            return
        }
        val generated = Instant.now().toString()
        val pp = File(outputDir, "pp.txt")
        val objs = File(outputDir, "objs.txt")
        val result = JSONObject()
            .put("jobId", jobId).put("status", "succeeded").put("backend", "exec")
            .put("createdAt", generated).put("completedAt", generated)
            .put("input", JSONObject()
                .put("displayName", libraries.displayName)
                .put("abi", libraries.abi)
                .put("libapp", fileJson(libraries.libappEntry, libraries.libapp))
                .put("libflutter", fileJson(libraries.libflutterEntry, libraries.libflutter)))
            .put("flutter", JSONObject().put("dartVersion", runner.dartVersion ?: JSONObject.NULL).put("engineRevision", JSONObject.NULL).put("compressedPointers", JSONObject.NULL).put("nullSafety", JSONObject.NULL).put("confidence", 0.5))
            .put("runner", JSONObject().put("runnerId", runner.runnerId).put("source", runner.source).put("backend", "exec").put("sha256", runner.sha256).put("match", selection.toJson()))
            .put("libappLoadSegments", libappLoadSegments(libraries.libapp))
            .put("summary", JSONObject()
                .put("backend", "exec")
                .put("rawOutput", JSONObject().put("ppTxt", fileStat(pp)).put("objsTxt", fileStat(objs)))
                .put("fullDump", JSONObject().put("libraries", "libraries.jsonl").put("classes", "classes.jsonl").put("functions", "functions.jsonl").put("objects", "objs.txt"))
                .put("inventoryIndex", JSONObject().put("status", "building").put("message", "原始产物已可用，清单索引正在后台生成"))
                .put("poolIndex", JSONObject().put("status", "building").put("message", "对象池引用索引正在后台生成"))
                .put("functionIndex", JSONObject().put("status", "building").put("message", "轻量函数索引正在后台生成"))
                .put("semanticIndex", JSONObject()
                    .put("status", "deferred")
                    .put("message", "全量语义索引仅在 deep/trace 时按需生成；普通 locate/disasm 不再等待")))
            .put("provenance", JSONObject().put("protocolVersion", 1).put("normalizerVersion", "exec-2").put("cacheHit", false).put("durationMillis", durationMillis))
        val (artifactBytes, artifactFiles) = outputMetrics(outputDir)
        store.progress(jobId, "moving_artifacts", "正在整理分析产物，避免重复复制大目录", artifactBytes, artifactFiles)
        moveArtifact(pp, File(resultDir, "pp.txt"))
        moveArtifact(objs, File(resultDir, "objs.txt"))
        File(resultDir, "objects.jsonl").delete()
        moveArtifact(asmDir, File(resultDir, "asm"))
        if (store.get(jobId)?.optString("status") == "cancelled") {
            resultDir.deleteRecursively()
            outputDir.deleteRecursively()
            return
        }
        store.update(jobId, "running", "committing")
        store.commit(jobId, result, key)
        runCatching { outputDir.deleteRecursively() }
        postExecutor.submit {
            // 快速构建器同时写函数头二进制，fn 报告紧随其后读 cacheHit。
            buildInventoryIndex(jobId, resultDir)
            buildFunctionIndex(jobId, resultDir)
        }
        // pp.txt 倒排索引预热：构建成本≈一次全量扫描，后台完成后续所有
        // VIP 词式搜索走候选集快路径（毫秒级），不再逐轮全量扫。
        postExecutor.submit {
            val meta = runCatching { PpPostings.build(resultDir) }.getOrNull()
            runCatching {
                store.updateCommittedResult(jobId) { committed ->
                    committed.getJSONObject("summary").put("ppIndex", if (meta != null)
                        JSONObject()
                            .put("status", "ready")
                            .put("lineIds", meta.optLong("lineIds"))
                            .put("tokens", meta.optInt("tokens"))
                            .put("hotTokens", meta.optInt("hotTokens"))
                            .put("buildMs", meta.optLong("elapsedMs"))
                    else JSONObject().put("status", "failed"))
                }
            }
        }
        postExecutor.submit { buildPoolIndex(jobId, resultDir, libraries.libapp) }
    }

    private fun buildInventoryIndex(jobId: String, resultDir: File) {
        runCatching {
            // 合并并行索引：一次排序分片扫描同时产出三类 jsonl 与函数头二进制。
            val counts = AsmFastIndex.build(resultDir)

            fun pageNames(file: String): JSONArray {
                val f = File(resultDir, file)
                if (!f.isFile) return JSONArray()
                return JSONArray(f.readLines().take(MAX_PAGE_ITEMS).mapNotNull { line ->
                    runCatching { org.json.JSONObject(line).optString("name") }.getOrNull()
                        ?.takeIf(String::isNotEmpty)
                })
            }
            val librariesPage = pageNames("libraries.jsonl")
            val classesPage = pageNames("classes.jsonl")
            val functionsPage = pageNames("functions.jsonl")
            var objectsTotal = 0
            val objectsPage = JSONArray()
            File(resultDir, "objs.txt").useLines { lines ->
                lines.forEach { raw ->
                    val trimmed = raw.trim()
                    if (trimmed.isEmpty()) return@forEach
                    objectsTotal++
                    if (objectsPage.length() < MAX_PAGE_ITEMS) {
                        objectsPage.put(org.json.JSONObject().put("kind", "object")
                            .put("id", "object-${objectsPage.length()}").put("name", trimmed))
                    }
                }
            }

            store.updateCommittedResult(jobId) { committed ->
                committed.put("libraries", page(librariesPage, counts.libraries, "libraries"))
                    .put("classes", page(classesPage, counts.classes, "classes"))
                    .put("functions", page(functionsPage, counts.functions, "functions"))
                    .put("objects", page(objectsPage, objectsTotal, "objects"))
                committed.getJSONObject("summary")
                    .put("counts", JSONObject().put("libraries", counts.libraries)
                        .put("classes", counts.classes).put("functions", counts.functions)
                        .put("objects", objectsTotal))
                    .put("inventoryIndex", JSONObject().put("status", "ready")
                        .put("elapsedMs", counts.elapsedMs)
                        .put("scannedFiles", counts.scannedFiles)
                        .put("workers", Runtime.getRuntime().availableProcessors().coerceIn(2, 6)))
            }
        }.onFailure { error ->
            store.updateCommittedResult(jobId) { committed ->
                committed.getJSONObject("summary").put("inventoryIndex", JSONObject()
                    .put("status", "failed").put("message", error.message ?: error.javaClass.simpleName))
            }
        }
    }

    private fun buildPoolIndex(jobId: String, resultDir: File, libapp: File) {
        runCatching { BlutterSearchIndex.buildArm64PoolIndex(libapp, resultDir) }
            .onSuccess {
                store.updateCommittedResult(jobId) { committed ->
                    committed.getJSONObject("summary").put("poolIndex", JSONObject().put("status", "ready"))
                }
            }
            .onFailure { error ->
                store.updateCommittedResult(jobId) { committed ->
                    committed.getJSONObject("summary").put("poolIndex", JSONObject()
                        .put("status", "failed").put("message", error.message ?: error.javaClass.simpleName))
                }
            }
    }

    private fun buildFunctionIndex(jobId: String, resultDir: File) {
        runCatching { BlutterSearchIndex.ensureFunctionHeaderIndex(resultDir) }
            .onSuccess { meta ->
                store.updateCommittedResult(jobId) { committed ->
                    committed.getJSONObject("summary").put("functionIndex", JSONObject()
                        .put("status", "ready")
                        .put("functions", meta.optInt("functions"))
                        .put("cacheHit", meta.optBoolean("cacheHit")))
                }
            }
            .onFailure { error ->
                store.updateCommittedResult(jobId) { committed ->
                    committed.getJSONObject("summary").put("functionIndex", JSONObject()
                        .put("status", "failed").put("message", error.message ?: error.javaClass.simpleName))
                }
            }
    }

    private fun fail(jobId: String, code: String, message: String, stage: String) {
        store.update(jobId, "failed", stage, JSONObject().put("code", code).put("message", message).put("recoverable", false).put("stage", stage))
    }

    // 内嵌页只作参考预览；定位必须走 search/locate/xref/disasm，不能顺序翻完整清单。
    private fun page(items: JSONArray, total: Int, kind: String): JSONObject = JSONObject()
        .put("items", items)
        .put("total", total)
        .put("hasMore", items.length() < total)
        .put("referenceOnly", true)
        .put("pagingHint", if (items.length() < total) "仅前 ${items.length()} 条参考预览。不要顺序翻页；按目标改用 locate/search/xref/disasm。只有用户明确要求导出完整 $kind 清单时才读取全量。" else JSONObject.NULL)

    private fun fileJson(name: String, file: File): JSONObject = JSONObject().put("name", name).put("size", file.length()).put("sha256", sha256(file))
    private fun libappLoadSegments(file: File): JSONArray = runCatching {
        RandomAccessFile(file, "r").use { input ->
            val header = ByteArray(64)
            input.readFully(header)
            require(header.copyOfRange(0, 4).contentEquals(byteArrayOf(0x7f, 'E'.code.toByte(), 'L'.code.toByte(), 'F'.code.toByte())))
            require((header[4].toInt() and 0xff) == 2 && (header[5].toInt() and 0xff) == 1)
            val offset = elfU64(header, 32)
            val entrySize = elfU16(header, 54)
            val count = elfU16(header, 56)
            val tableBytes = entrySize.toLong() * count
            require(entrySize >= 56 && tableBytes <= 8L * 1024 * 1024 && offset >= 0 && offset + tableBytes <= input.length())
            val table = ByteArray(tableBytes.toInt())
            input.seek(offset)
            input.readFully(table)
            JSONArray((0 until count).mapNotNull { index ->
                val base = index * entrySize
                val type = elfU32(table, base)
                val fileOffset = elfU64(table, base + 8)
                val virtualAddress = elfU64(table, base + 16)
                val fileSize = elfU64(table, base + 32)
                if (type == 1L && fileSize > 0) JSONObject()
                    .put("virtualAddress", "0x${virtualAddress.toString(16)}")
                    .put("fileOffset", "0x${fileOffset.toString(16)}")
                    .put("fileSize", "0x${fileSize.toString(16)}") else null
            })
        }
    }.getOrDefault(JSONArray())
    private fun elfU16(bytes: ByteArray, offset: Int): Int =
        (bytes[offset].toInt() and 0xff) or ((bytes[offset + 1].toInt() and 0xff) shl 8)
    private fun elfU32(bytes: ByteArray, offset: Int): Long =
        (bytes[offset].toLong() and 0xff) or
            ((bytes[offset + 1].toLong() and 0xff) shl 8) or
            ((bytes[offset + 2].toLong() and 0xff) shl 16) or
            ((bytes[offset + 3].toLong() and 0xff) shl 24)
    private fun elfU64(bytes: ByteArray, offset: Int): Long =
        elfU32(bytes, offset) or (elfU32(bytes, offset + 4) shl 32)
    private fun fileStat(file: File): JSONObject = JSONObject().put("file", file.name).put("bytes", if (file.isFile) file.length() else 0)
    private fun outputMetrics(root: File): Pair<Long, Int> {
        var bytes = 0L
        var files = 0
        root.walkTopDown().filter(File::isFile).forEach { file ->
            bytes += file.length()
            files++
        }
        return bytes to files
    }

    private fun moveArtifact(source: File, destination: File) {
        if (!source.exists()) return
        destination.parentFile?.mkdirs()
        if (destination.exists()) destination.deleteRecursively()
        val moved = runCatching {
            Files.move(source.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            true
        }.getOrElse {
            runCatching {
                // Android 公共存储的 FUSE 层通常拒绝 ATOMIC_MOVE，但普通 rename
                // 仍是同盘 O(1) 操作。此前直接退化成复制 145MB，白白多耗二十多秒。
                Files.move(source.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING)
                true
            }.getOrDefault(false)
        }
        if (!moved) {
            if (source.isDirectory) source.copyRecursively(destination, overwrite = true) else source.copyTo(destination, overwrite = true)
            source.deleteRecursively()
        }
    }
    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
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

    private fun digest(libapp: ByteArray, libflutter: ByteArray, runnerSha256: String, options: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(libapp)
        digest.update(libflutter)
        digest.update(runnerSha256.toByteArray())
        digest.update(options.toByteArray())
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private companion object {
        const val TIMEOUT_MINUTES = 10L
        const val HEARTBEAT_SECONDS = 2L
        const val MAX_CONSOLE_CHARS = 64 * 1024
        const val MAX_PAGE_ITEMS = 50
    }

    // asm 文件里的方法签名行：排除注释/标记前缀，含括号，以 { 或 ; 结尾
}
