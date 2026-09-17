package zhou.solab.engine

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.BufferedInputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Base64
import java.util.UUID

internal class BlutterResultStore private constructor(initialRoot: File) {
    constructor(context: Context) : this(File(context.noBackupFilesDir, "blutter/v1"))

    internal constructor(rootDirectory: File, @Suppress("UNUSED_PARAMETER") testOnly: Boolean) : this(rootDirectory)

    companion object {
        private val JOB_ID = Regex("^blutter-[A-Za-z0-9_-]{8,128}$")
        private val PAGE_KINDS = setOf("libraries", "classes", "functions", "objects")

        fun resultKey(libapp: ByteArray, libflutter: ByteArray, runnerSha256: String, options: String): String {
            val digest = java.security.MessageDigest.getInstance("SHA-256")
            listOf(libapp, libflutter).forEach { bytes -> digest.update(bytes) }
            digest.update(runnerSha256.toByteArray())
            digest.update(options.toByteArray())
            return digest.digest().joinToString("") { "%02x".format(it) }
        }

        fun resultKey(libapp: File, libflutter: File, runnerSha256: String, options: String): String {
            val digest = java.security.MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(128 * 1024)
            listOf(libapp, libflutter).forEach { file ->
                BufferedInputStream(file.inputStream(), buffer.size).use { input ->
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

        /**
         * 结果缓存只由实际会改变分析结果的选项决定。
         *
         * path、wait、timeoutMs、jobId、goal 等都是调度或查询参数；把整份请求
         * JSON 纳入 key 会让同一 APK 每次改路径或等待方式都新建一个完整结果目录。
         */
        fun analysisCacheOptions(args: JSONObject): String = JSONObject()
            .put("format", 2)
            .put("abi", args.optString("abi", "auto").lowercase())
            .put("noAnalysis", args.optBoolean("noAnalysis", false))
            .toString()
    }
    // 产物 root 跟随当前工作目录（path 模式：<工作目录>/blutter/v1），
    // Blutter 分析产物体积大头（pp/objs/asm/JSONL 全量索引）全部落到用户目录，
    // 不再占用 App 内部存储。runner 二进制受 Android 外部存储执行限制仍留在
    // nativeLibraryDir，这部分不属于产物体积。默认回退到内部目录以便引擎
    // 能构造（实际 analyze 前会由 bindBlutterRoot 强制改为工作目录）。
    private var root: File = initialRoot.apply { mkdirs() }
    private fun jobsDir() = File(root, "jobs").apply { mkdirs() }
    private fun resultsDir() = File(root, "results").apply { mkdirs() }

    /** 把 Blutter 产物 root 强制绑定到工作目录内部路径；path 模式返回成功。 */
    @Synchronized
    fun bindBlutterRoot(workDirectory: WorkDirectory?): Boolean {
        if (workDirectory?.isPathMode == true && workDirectory.rootPath != null) {
            val bound = File(workDirectory.rootPath, "SoLab/blutter/v1")
            bound.mkdirs()
            root = bound
            reapOrphanJobs()
            return true
        }
        return false
    }

    /** 每进程只判死一次（首次 bind 在本进程创建任何 job 之前发生）。 */
    @Volatile
    private var orphansReaped = false

    /**
     * 孤儿 job 判死：running/queued 状态的 job 属于上一个已死进程——
     * exec/embedded runner 都在本进程内运行，进程被杀后这些 job 永远不会
     * 再有状态更新，而 prune 只删终态 job，input/ 里的 libapp.so 等数十 MB
     * 中间产物会永久残留。这里标记 interrupted（终态，可被 prune 回收）并
     * 立即删除 input/output 释放空间。要求已静默 ≥5 分钟，防止极端时序
     * 下误杀本进程刚创建的任务。
     */
    @Synchronized
    fun reapOrphanJobs(idleMillis: Long = 5 * 60 * 1000L) {
        if (orphansReaped) return
        orphansReaped = true
        val cutoff = System.currentTimeMillis() - idleMillis.coerceAtLeast(0)
        jobsDir().listFiles()?.forEach { dir ->
            val state = readState(dir.name) ?: return@forEach
            if (state.optString("status") in setOf("running", "queued")) {
                val updatedAt = state.optLong("updatedAt", 0L)
                if (updatedAt in 1..cutoff) {
                    update(dir.name, "interrupted", "orphan_reaped")
                    File(dir, "input").deleteRecursively()
                    File(dir, "output").deleteRecursively()
                }
            }
        }
    }

    @Synchronized
    fun create(request: JSONObject): String {
        val id = "blutter-${UUID.randomUUID()}"
        val dir = File(jobsDir(), id).apply { mkdirs() }
        write(File(dir, "state.json"), JSONObject().put("jobId", id).put("status", "queued").put("stage", "created").put("createdAt", System.currentTimeMillis()).put("updatedAt", System.currentTimeMillis()).put("request", request))
        return id
    }

    @Synchronized
    fun jobDir(jobId: String): File {
        requireValidJobId(jobId)
        return File(jobsDir(), jobId).apply { mkdirs() }
    }

    @Synchronized
    fun update(jobId: String, status: String, stage: String, error: JSONObject? = null, resultKey: String? = null, progress: JSONObject? = null) {
        requireValidJobId(jobId)
        val state = readState(jobId) ?: return
        state.put("status", status).put("stage", stage).put("updatedAt", System.currentTimeMillis())
        if (error != null) state.put("error", error) else state.remove("error")
        if (resultKey != null) state.put("resultKey", resultKey)
        progress?.keys()?.forEach { key -> state.put(key, progress.get(key)) }
        write(File(File(jobsDir(), jobId), "state.json"), state)
    }

    @Synchronized
    fun get(jobId: String): JSONObject? = readState(jobId)?.also { state ->
        val now = System.currentTimeMillis()
        state.put("elapsedMillis", (now - state.optLong("createdAt", now)).coerceAtLeast(0))
        state.put("heartbeatAgeMillis", (now - state.optLong("updatedAt", now)).coerceAtLeast(0))
        state.put("stageLabel", stageLabel(state.optString("stage")))
    }

    @Synchronized
    fun requestPath(jobId: String): String =
        readState(jobId)?.optJSONObject("request")?.optString("path").orEmpty()

    @Synchronized
    fun progress(jobId: String, stage: String, message: String, outputBytes: Long = 0, outputFiles: Int = 0) {
        update(jobId, "running", stage, progress = JSONObject()
            .put("progressMessage", message)
            .put("outputBytes", outputBytes.coerceAtLeast(0))
            .put("outputFiles", outputFiles.coerceAtLeast(0)))
    }

    @Synchronized
    fun claimAnalysisKey(jobId: String, analysisKey: String): String? {
        requireValidJobId(jobId)
        val existing = jobsDir().listFiles().orEmpty().asSequence()
            .filter { it.name != jobId }
            .mapNotNull { dir -> readState(dir.name) }
            .firstOrNull { state ->
                state.optString("status") in setOf("queued", "running") &&
                    state.optString("analysisKey") == analysisKey
            }
            ?.optString("jobId")
        if (existing != null) return existing
        update(jobId, "queued", "runner_selection", progress = JSONObject().put("analysisKey", analysisKey))
        return null
    }

    @Synchronized
    fun resultDir(jobId: String): File? {
        requireValidJobId(jobId)
        val key = readState(jobId)?.optString("resultKey")?.takeIf { it.isNotBlank() } ?: return null
        return File(resultsDir(), key).takeIf { it.isDirectory }
    }

    /** 结果目录（按 resultKey），跟随 [root]（可能被 bind 到工作目录）。
     *  供 exec/embedded backend 复制 pp.txt/objs.txt/asm 时使用，
     *  必须与 [commit] 写 result.json 的目录一致，否则 locate/search/xref 读不到产物。 */
    @Synchronized
    fun resultDirForKey(key: String): File = File(resultsDir(), key).apply { mkdirs() }

    @Synchronized
    fun saveReport(jobId: String, reportName: String, report: JSONObject) {
        require(reportName in setOf("membership", "capture", "ads")) { "Unsupported report name" }
        val dir = resultDir(jobId) ?: return
        write(File(dir, "$reportName-report.json"), report)
    }

    @Synchronized
    fun readReport(jobId: String, reportName: String): JSONObject? {
        require(reportName in setOf("membership", "capture", "ads")) { "Unsupported report name" }
        val file = resultDir(jobId)?.resolve("$reportName-report.json") ?: return null
        return runCatching { file.takeIf(File::isFile)?.let { JSONObject(it.readText()) } }.getOrNull()
    }

    /** 最近一次成功任务（search/xref 不传 jobId 时用）。 */
    @Synchronized
    fun latestSucceededJobId(): String? = jobsDir().listFiles().orEmpty()
        .mapNotNull { dir -> readState(dir.name)?.takeIf { it.optString("status") == "succeeded" }?.let { dir.name to it.optLong("updatedAt", 0L) } }
        .maxByOrNull { it.second }?.first

    @Synchronized
    fun commit(jobId: String, result: JSONObject, key: String): JSONObject {
        requireValidJobId(jobId)
        require(key.matches(Regex("^[a-f0-9]{32,128}$"))) { "Invalid result key" }
        val dir = File(resultsDir(), key)
        if (!dir.exists()) dir.mkdirs()
        write(File(dir, "result.json"), result)
        update(jobId, "succeeded", "committed", resultKey = key, progress = JSONObject()
            .put("progressMessage", "Blutter 分析完成，产物已可查询")
            .put("heartbeatAgeMillis", 0))
        return result
    }

    @Synchronized
    fun updateCommittedResult(jobId: String, mutate: (JSONObject) -> Unit): Boolean {
        val dir = resultDir(jobId) ?: return false
        val file = File(dir, "result.json")
        val result = runCatching { JSONObject(file.readText()) }.getOrNull() ?: return false
        mutate(result)
        write(file, result)
        return true
    }

    @Synchronized
    fun reuse(jobId: String, key: String): JSONObject? {
        requireValidJobId(jobId)
        if (!key.matches(Regex("^[a-f0-9]{32,128}$"))) return null
        val file = File(File(resultsDir(), key), "result.json")
        if (!file.isFile) return null
        val result = runCatching { JSONObject(file.readText()) }.getOrNull() ?: return null
        val provenance = result.optJSONObject("provenance") ?: JSONObject()
        provenance.put("cacheHit", true)
        update(jobId, "succeeded", "cache_hit", resultKey = key, progress = JSONObject()
            .put("progressMessage", "命中已有 Blutter 结果，无需重复分析"))
        return JSONObject()
            .put("jobId", jobId)
            .put("status", "succeeded")
            .put("stage", "cache_hit")
            .put("stageLabel", stageLabel("cache_hit"))
            .put("cacheHit", true)
            .put("resultKey", key)
            .put("backend", result.optString("backend"))
            .put("summary", result.optJSONObject("summary") ?: JSONObject())
            .put("provenance", provenance)
            .put("progressMessage", "命中已有 Blutter 结果，无需重复分析")
            .put("nextStep", "需要明细时使用同一 jobId 调用 result、search、locate 或 disasm")
    }


    @Synchronized
    fun result(jobId: String, kind: String?, cursor: String?, limit: Int): JSONObject? {
        requireValidJobId(jobId)
        require(limit in 1..1000) { "limit must be between 1 and 1000" }
        val state = readState(jobId) ?: return null
        val key = state.optString("resultKey")
        if (key.isBlank()) return JSONObject().put("jobId", jobId).put("status", state.optString("status"))
        val file = File(File(resultsDir(), key), "result.json")
        if (!file.isFile) return null
        val result = JSONObject(file.readText())
        if (kind == null) return result.put("jobId", jobId)
        require(kind in PAGE_KINDS) { "Unsupported result kind" }
        val response = JSONObject()
            .put("jobId", jobId)
            .put("status", result.optString("status", "succeeded"))
            .put("backend", result.optString("backend"))
            .put("summary", result.optJSONObject("summary") ?: JSONObject())
        for (other in PAGE_KINDS) {
            val counts = result.optJSONObject("summary")?.optJSONObject("counts")
            if (other != kind && counts?.has(other) == true) response.put("${other}Total", counts.optInt(other))
        }
        val offset = decodeCursor(cursor, jobId, kind)
        // 优先走 JSONL 全量分页（新结果无 5000 条上限，total 取真实计数）
        val jsonl = File(File(resultsDir(), key), "$kind.jsonl")
        if (jsonl.isFile) {
            val declared = result.optJSONObject("summary")?.optJSONObject("counts")?.optInt(kind, -1) ?: -1
            val total = if (declared >= 0) declared else jsonl.useLines { it.count() }
            val end = minOf(offset + limit, total)
            val selected = JSONArray()
            if (offset < total) jsonl.useLines { lines ->
                lines.drop(offset).take(end - offset).forEach { selected.put(JSONObject(it)) }
            }
            return response.put(kind, JSONObject()
                .put("items", selected)
                .put("total", total)
                .put("offset", offset)
                .put("hasMore", end < total)
                .put("nextCursor", if (end < total) encodeCursor(jobId, kind, end) else JSONObject.NULL))
        }
        // objects.jsonl 只是 objs.txt 的 JSON 包装副本，实际体积可达原文件 2-3 倍。
        // 新结果只保留原始 objs.txt；用户明确读取完整对象清单时再流式分页转换。
        val objectsText = File(File(resultsDir(), key), "objs.txt")
        if (kind == "objects" && objectsText.isFile) {
            val declared = result.optJSONObject("summary")?.optJSONObject("counts")?.optInt(kind, -1) ?: -1
            val total = if (declared >= 0) declared else objectsText.useLines { lines -> lines.count { it.isNotBlank() } }
            val selected = JSONArray()
            objectsText.useLines { lines ->
                lines.filter(String::isNotBlank).drop(offset).take(limit).forEachIndexed { index, raw ->
                    selected.put(JSONObject()
                        .put("kind", "object")
                        .put("id", "object-${offset + index}")
                        .put("name", raw.trim()))
                }
            }
            val end = offset + selected.length()
            return response.put(kind, JSONObject()
                .put("items", selected)
                .put("total", total)
                .put("offset", offset)
                .put("hasMore", end < total)
                .put("nextCursor", if (end < total) encodeCursor(jobId, kind, end) else JSONObject.NULL))
        }
        // 旧结果回退：result.json 内嵌分页（当时受 5000 条上限约束）
        val page = result.optJSONObject(kind) ?: return response
        val items = page.optJSONArray("items") ?: JSONArray()
        val end = minOf(offset + limit, items.length())
        val selected = JSONArray()
        for (index in offset until end) selected.put(items.get(index))
        return response.put(kind, JSONObject()
            .put("items", selected)
            .put("total", items.length())
            .put("offset", offset)
            .put("hasMore", end < items.length())
            .put("nextCursor", if (end < items.length()) encodeCursor(jobId, kind, end) else JSONObject.NULL))
    }

    @Synchronized
    fun cancel(jobId: String): Boolean {
        val state = readState(jobId) ?: return false
        if (state.optString("status") in setOf("succeeded", "failed", "cancelled", "interrupted")) return false
        update(jobId, "cancelled", "cancelled")
        return true
    }

    @Synchronized
    fun prunePreview(olderThanMillis: Long): JSONObject = pruneInternal(olderThanMillis, true)

    @Synchronized
    fun prune(olderThanMillis: Long): JSONObject = pruneInternal(olderThanMillis, false)

    private fun pruneInternal(olderThanMillis: Long, dryRun: Boolean): JSONObject {
        val cutoff = System.currentTimeMillis() - olderThanMillis.coerceAtLeast(0)
        var removedJobs = 0
        var freedBytes = 0L
        val jobCandidates = jobsDir().listFiles().orEmpty().filter { dir ->
            val state = readState(dir.name)
            val terminal = state?.optString("status") in setOf("succeeded", "failed", "cancelled", "interrupted")
            terminal && (state?.optLong("updatedAt", Long.MAX_VALUE) ?: Long.MAX_VALUE) < cutoff
        }
        jobCandidates.forEach { dir ->
            val bytes = directoryBytes(dir)
            if (dryRun || dir.deleteRecursively()) {
                removedJobs++
                freedBytes += bytes
            }
        }
        var removedResults = 0
        val removedJobNames = jobCandidates.map { it.name }.toSet()
        val referenced = jobsDir().listFiles().orEmpty()
            .filter { !dryRun || it.name !in removedJobNames }
            .mapNotNull { readState(it.name)?.optString("resultKey")?.takeIf(String::isNotBlank) }
            .toSet()
        val resultCandidates = resultsDir().listFiles().orEmpty().filter { it.lastModified() < cutoff && it.name !in referenced }
        resultCandidates.forEach { dir ->
            val bytes = directoryBytes(dir)
            if (dryRun || dir.deleteRecursively()) {
                removedResults++
                freedBytes += bytes
            }
        }
        return JSONObject()
            .put("dryRun", dryRun)
            .put(if (dryRun) "candidateJobs" else "removedJobs", removedJobs)
            .put(if (dryRun) "candidateResults" else "removedResults", removedResults)
            .put("freedBytes", freedBytes)
            .put("keptResults", resultsDir().listFiles().orEmpty().size - if (dryRun) removedResults else 0)
            .put("cutoff", cutoff)
    }

    private fun directoryBytes(file: File): Long = if (file.isFile) file.length() else file.listFiles().orEmpty().sumOf(::directoryBytes)

    private fun stageLabel(stage: String): String = when (stage) {
        "created" -> "等待开始"
        "resolving_input" -> "读取 APK 与 Flutter 库"
        "runner_selection" -> "匹配 Dart runner"
        "runner_launch" -> "启动 Blutter runner"
        "runner_execution" -> "解析 Dart AOT"
        "writing_indexes" -> "生成对象池与反汇编"
        "indexing_entities" -> "索引类与函数"
        "moving_artifacts" -> "整理分析产物"
        "building_pool_index" -> "建立对象池引用索引"
        "building_semantic_index" -> "建立语义与交叉引用索引"
        "committing" -> "保存结果"
        "committed", "cache_hit" -> "分析完成"
        else -> stage.ifBlank { "处理中" }
    }

    private fun readState(jobId: String): JSONObject? = runCatching { requireValidJobId(jobId); File(File(jobsDir(), jobId), "state.json").takeIf { it.isFile }?.let { JSONObject(it.readText()) } }.getOrNull()
    private fun write(file: File, value: JSONObject) {
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, "${file.name}.${UUID.randomUUID()}.tmp")
        temp.writeText(value.toString())
        runCatching { Files.move(temp.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING) }
            .getOrElse { Files.move(temp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING) }
    }
    private fun requireValidJobId(jobId: String) { require(JOB_ID.matches(jobId)) { "Invalid Blutter job id" } }
    private fun encodeCursor(jobId: String, kind: String, offset: Int): String = Base64.getUrlEncoder().withoutPadding().encodeToString("$jobId|$kind|$offset".toByteArray())
    private fun decodeCursor(cursor: String?, jobId: String, kind: String): Int {
        if (cursor.isNullOrBlank()) return 0
        val parts = runCatching { String(Base64.getUrlDecoder().decode(cursor)).split('|') }.getOrNull()
            ?: throw IllegalArgumentException("Invalid cursor")
        require(parts.size == 3 && parts[0] == jobId && parts[1] == kind) { "Cursor does not belong to this result" }
        return parts[2].toIntOrNull()?.takeIf { it >= 0 } ?: throw IllegalArgumentException("Invalid cursor offset")
    }
}
