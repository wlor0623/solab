package zhou.solab.engine

import android.content.Context
import zhou.solab.tools.err
import zhou.solab.tools.ok
import zhou.solab.tools.str
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.zip.ZipInputStream

internal class BlutterCoordinator(private val context: Context, private val store: BlutterResultStore = BlutterResultStore(context), private val registry: BlutterRunnerRegistry = BlutterRunnerRegistry(context)) {
    private val embedded = BlutterEmbeddedBackend(context, store)
    private val exec = BlutterExecBackend(context, store)
    fun handle(args: JSONObject, workDirectory: WorkDirectory? = null): JSONObject {
        // Blutter 产物强制落工作目录：path 模式绑到 <工作目录>/blutter/v1；
        // 未选工作目录或 SAF 模式（无真实路径）时拒绝 analyze 系操作，禁止静默回退内部目录。
        if (workDirectory != null && !store.bindBlutterRoot(workDirectory)) {
            return err("WORK_DIRECTORY_PATH_REQUIRED", "Blutter 分析产物必须写入工作目录。请使用「选择工作目录」设置一个真实文件路径（非 SAF 虚拟目录）后再分析。", "workDirMode", if (workDirectory.rootPath != null) "saf-tree" else "none")
        }
        return when (args.str("action", "inspect")) {
            "inspect" -> inspect(args, workDirectory)
            "analyze" -> requireBlutterWorkDir(workDirectory) { analyze(args, workDirectory) }
            "status" -> status(args.str("jobId"))
            "result" -> result(args.str("jobId"), args.optString("kind").takeIf { it.isNotBlank() }, args.optString("cursor").takeIf { it.isNotBlank() }, args.optInt("limit", 100), args.optBoolean("fullInventory", false))
            "cancel" -> cancel(args.str("jobId"))
            "search" -> search(args)
            "raw_strings" -> rawStrings(args, workDirectory)
            "values" -> values(args)
            "xref" -> xref(args)
            "trace" -> trace(args)
            "locate" -> locate(args, workDirectory)
            "report" -> report(args)
            "callers" -> callers(args)
            "disasm" -> disasm(args)
            "diff" -> diff(args, workDirectory)
            "packages" -> ok(registry.capabilities(args))
            "prune" -> ok(store.bindBlutterRoot(workDirectory).let {
                val age = args.optLong("olderThanMillis", 7L * 24 * 60 * 60 * 1000)
                if (args.optBoolean("dryRun", true)) store.prunePreview(age) else store.prune(age)
            })
            else -> err("UNKNOWN_ACTION", "Unsupported Blutter action", "action", args.str("action"))
        }
    }


    /**
     * 跨版本差分：blutterAction=diff，compareToJobId=新包 jobId，
     * classPrefix 过滤旧索引（可选），minSimilarity 默认 0.45。
     * 输出映射行用于把旧对话 pendingChanges 迁移到新包定位。
     */
    private fun diff(args: JSONObject, workDirectory: WorkDirectory?): JSONObject {
        val other = resolveResultDir(args.str("compareToJobId"))
            ?: return err("RESULT_NOT_FOUND", " compareToJobId 无可用 blutter 结果；请先对新包执行 analyze", "compareToJobId", args.str("compareToJobId"))
        val current = resolveResultDir(args.str("jobId"))
            ?: return err("RESULT_NOT_FOUND", "当前会话无 blutter 结果", "jobId", args.str("jobId"))
        if (other.second.absolutePath == current.second.absolutePath) {
            return err("SAME_RESULT", "两个 jobId 指向同一结果目录，无法差分", "jobId", args.str("jobId"))
        }
        val started = System.nanoTime()
        val oldIdx = BlutterDiff.buildIndex(current.second)
        val newIdx = BlutterDiff.buildIndex(other.second)
        val rows = BlutterDiff.match(
            oldIdx,
            newIdx,
            oldPrefix = args.str("classPrefix").trim(),
            minSimilarity = args.optDouble("minSimilarity", 0.45).coerceIn(0.2, 0.95),
            limit = args.optInt("limit", 40).coerceIn(1, 200),
        )
        return ok(
            JSONObject()
                .put("action", "diff")
                .put("oldJobId", current.first)
                .put("newJobId", other.first)
                .put("oldFunctions", oldIdx.size)
                .put("newFunctions", newIdx.size)
                .put("mapped", rows.length())
                .put("mappings", rows)
                .put(
                    "nextStep",
                    "优先处理 similarity=1 的行：把旧对话对应 locator 的 va 替换为 newVa 后直接复用补丁参数；0.45~0.8 的行需按 newVa 重新 disasm 验证分支再改。",
                )
                .put("elapsedMs", (System.nanoTime() - started) / 1_000_000),
        )
    }

    private fun requireBlutterWorkDir(workDirectory: WorkDirectory?, block: () -> JSONObject): JSONObject {
        if (workDirectory?.isPathMode != true || workDirectory.rootPath == null) {
            return err("WORK_DIRECTORY_PATH_REQUIRED", "Blutter 分析需要真实文件路径的工作目录。请先在设置中「选择工作目录」并授予所有文件访问权限。", "workDirMode", if (workDirectory != null) "saf-tree" else "none")
        }
        return block()
    }

    /** P1-B：runner 矩阵能力转发（capabilityRegistry 的 blutter 节点复用，避免重复解析 manifest）。 */
    fun capabilities(): JSONObject = registry.capabilities()

    private fun inspect(args: JSONObject, workDirectory: WorkDirectory?): JSONObject {
        val path = args.str("path")
        if (path.isBlank()) return err("INPUT_REQUIRED", "path is required for inspect", "path", path)
        val file = File(path)
        return try {
            if (file.isDirectory) inspectDirectory(file, path, args.str("abi", "auto")) else if (file.isFile) {
                if (!file.extension.equals("apk", true)) return err("UNSUPPORTED_INPUT", "请传 APK 路径（.apk）或含 libapp.so + libflutter.so 的目录，不要传单个 .so 文件：blutter 需要从 APK 同时提取 libapp.so 与 libflutter.so 才能确定 Dart 版本与 runner", "path", path)
                val inventory = FlutterArtifactInspector.inspectApk(file, args.str("abi", "auto"))
                val selected = inventory.optJSONObject("selected")
                if (selected == null) ok(inventory) else {
                    val detailed = FlutterArtifactInspector.inspectLibraries(FlutterArtifactInspector.extractLibraries(file, args.str("abi", "auto")))
                    ok(inventory.put("selectedAnalysis", detailed))
                }
            } else if (workDirectory != null) {
                val bytes = workDirectory.readFile(path, ApkAnalyzer.MAX_INPUT_BYTES)
                val inventory = FlutterArtifactInspector.inspectApk(bytes, path, args.str("abi", "auto"))
                val selected = inventory.optJSONObject("selected")
                if (selected == null) ok(inventory) else ok(inventory.put("selectedAnalysis", FlutterArtifactInspector.inspectLibraries(FlutterArtifactInspector.extractLibraries(bytes, path, args.str("abi", "auto")))))
            } else err("INPUT_NOT_FOUND", "Input path does not exist and no work directory is selected", "path", path)
        } catch (error: Exception) { err(error.message?.substringBefore(':')?.takeIf { it in setOf("INPUT_LIMIT_EXCEEDED", "APK_INVALID", "UNSUPPORTED_ELF") } ?: "FLUTTER_INSPECT_FAILED", error.message ?: "Flutter inspection failed", "path", path) }
    }

    private fun analyze(args: JSONObject, workDirectory: WorkDirectory?): JSONObject {
        store.prune(7L * 24 * 60 * 60 * 1000)
        val jobId = store.create(args)
        store.progress(jobId, "resolving_input", "正在读取 APK 并提取 Flutter 库")
        val input = runCatching { resolveRunnerInput(args, workDirectory) }.getOrElse { error ->
            val problem = JSONObject()
                .put("code", "INPUT_RESOLUTION_FAILED")
                .put("message", error.message ?: "Cannot resolve Flutter libraries")
                .put("recoverable", false)
                .put("stage", "resolving_input")
            return failedAnalyze(jobId, problem)
        }
        val analysis = runCatching { FlutterArtifactInspector.inspectLibraries(input) }.getOrElse { error ->
            val problem = JSONObject()
                .put("code", "FLUTTER_INSPECT_FAILED")
                .put("message", error.message ?: "Cannot inspect Flutter libraries")
                .put("recoverable", false)
                .put("stage", "resolving_input")
            return failedAnalyze(jobId, problem)
        }
        val flutter = analysis.optJSONObject("flutter") ?: JSONObject()
        val requirement = BlutterRunnerRequirement(
            engineRevision = flutter.optJSONArray("engineIds")?.optString(0)?.takeIf { it.isNotBlank() },
            dartVersion = flutter.optString("dartVersion").takeIf { it.isNotBlank() },
            snapshotHash = flutter.optString("snapshotHash").takeIf { it.isNotBlank() },
            abi = analysis.optString("abi", args.str("abi", "arm64-v8a")),
            compressedPointers = flutter.optBoolean("compressedPointers", false),
            analysis = !args.optBoolean("noAnalysis", false),
        )
        val selection = registry.selectWithEvidence(requirement)
        if (selection != null) {
            val runner = selection.runner
            return runCatching {
                val cacheKey = BlutterResultStore.resultKey(
                    input.libapp,
                    input.libflutter,
                    runner.sha256,
                    BlutterResultStore.analysisCacheOptions(args),
                )
                store.reuse(jobId, cacheKey)?.let { cached ->
                    return@runCatching ok(cached)
                }
                store.claimAnalysisKey(jobId, cacheKey)?.let { activeJobId ->
                    store.cancel(jobId)
                    val active = store.get(activeJobId) ?: JSONObject().put("jobId", activeJobId).put("status", "running")
                    return@runCatching ok(active
                        .put("deduplicated", true)
                        .put("progressMessage", "相同 APK 与参数已在分析，已复用现有任务"))
                }
                if (runner.backend == "exec") exec.start(jobId, selection, input, args, workDirectory) else embedded.start(jobId, selection, input, args)
                ok(JSONObject()
                    .put("jobId", jobId)
                    .put("status", "running")
                    .put("stage", "runner_launch")
                    .put("stageLabel", "启动 Blutter runner")
                    .put("progressMessage", "任务已进入后台，状态接口将持续返回心跳和产物增长")
                    .put("backend", runner.backend)
                    .put("runner", runner.toJson())
                    .put("runnerMatch", selection.toJson()))
            }.getOrElse { error ->
                val problem = JSONObject().put("code", "INPUT_RESOLUTION_FAILED").put("message", error.message ?: "Cannot resolve Flutter libraries").put("recoverable", false).put("stage", "resolving_input")
                failedAnalyze(jobId, problem)
            }
        }
        val required = JSONObject().put("engineRevision", requirement.engineRevision ?: JSONObject.NULL).put("dartVersion", requirement.dartVersion ?: JSONObject.NULL).put("snapshotHash", requirement.snapshotHash ?: JSONObject.NULL).put("abi", requirement.abi).put("compressedPointers", requirement.compressedPointers).put("analysis", requirement.analysis)
        val error = JSONObject().put("code", "FLUTTER_VERSION_NOT_SUPPORTED").put("message", "No bundled Blutter runner matches this snapshot. Bundled coverage: Dart 2.14-3.12 arm64-v8a exec runners (blutter-termux).").put("recoverable", false).put("stage", "runner_selection").put("supportedDartRange", "2.14-3.12").put("required", required)
        return failedAnalyze(jobId, error)
            .put("inspection", analysis)
            .put("requiredRunner", required)
            .put("nextActions", JSONArray().put("inspect the APK fingerprint without running analysis").put("call so_analyze(action=blutter, blutterAction=packages) for the bundled runner matrix"))
    }

    private fun failedAnalyze(jobId: String, problem: JSONObject): JSONObject {
        val stage = problem.optString("stage", "unknown")
        store.update(jobId, "failed", stage, problem)
        return err(
            problem.optString("code", "BLUTTER_ANALYZE_FAILED"),
            problem.optString("message", "Blutter analysis failed"),
            null,
            null,
            "jobId" to jobId,
            "stage" to stage,
        ).put("jobId", jobId)
            .put("status", "failed")
            .also { it.getJSONObject("error").put("recoverable", problem.optBoolean("recoverable", false)) }
    }

    private fun status(jobId: String): JSONObject = store.get(jobId)?.let { ok(it) } ?: err("JOB_NOT_FOUND", "Blutter job was not found", "jobId", jobId)

    // search/xref：基于已完成任务的产物（pp.txt + asm/）做补丁点定位，jobId 缺省取最近成功任务
    private fun search(args: JSONObject): JSONObject {
        val query = args.str("query").trim()
        if (query.isEmpty()) return err("QUERY_REQUIRED", "query is required for search (e.g. tun / is_vip / vipAdExempt)", "query", query)
        val limit = args.optInt("limit", 50).coerceIn(1, 200)
        val scope = args.str("scope", "pp").lowercase()
        if (scope !in setOf("pp", "asm", "all")) return err("INVALID_SCOPE", "scope must be pp | asm | all", "scope", scope)
        val resolved = resolveResultDir(args.str("jobId"))
            ?: return err("RESULT_NOT_FOUND", "No succeeded blutter result available; run analyze first", "jobId", args.str("jobId"))
        val response = JSONObject().put("jobId", resolved.first).put("query", query).put("scope", scope)
        val poolOffsets = parseBlutterPoolOffsets(query)
        if (scope == "pp" || scope == "all") response.put("pp", BlutterSearchIndex.searchPp(resolved.second, query, caseInsensitive = true, limit = limit))
        if (scope == "asm" || scope == "all") response.put(
            "asm",
            BlutterSearchIndex.searchAsm(
                resolved.second,
                query,
                caseInsensitive = true,
                limit = limit,
                fullScan = args.optBoolean("fullScan", false),
                includePaths = pathFilters(args.str("includePath")),
                excludePaths = pathFilters(args.str("excludePath")),
                includeThirdParty = args.optBoolean("includeThirdParty", false),
            ),
        )
        if ((scope == "asm" || scope == "all") && poolOffsets.isNotEmpty()) {
            response.put("rawPoolRefs", BlutterSearchIndex.xrefMany(resolved.second, poolOffsets, limit))
        }
        response.put("nextStep", "用命中项的 offset 调 blutterAction=xref 拿引用该池项的函数 VA")
        return ok(response)
    }

    private fun rawStrings(args: JSONObject, workDirectory: WorkDirectory?): JSONObject {
        val goal = args.str("goal").ifBlank { args.str("query") }.trim()
        if (goal.isEmpty()) return err("QUERY_REQUIRED", "query or goal is required for raw_strings", "query", goal)
        return runCatching {
            val libraries = resolveLibraries(args, workDirectory)
            val terms = (listOf(goal) + blutterLocateKeywords(goal)).distinct().take(64)
            ok(BlutterSearchIndex.rawStringSearch(libraries.libapp, terms, args.optInt("limit", 50).coerceIn(1, 200))
                .put("path", args.str("path"))
                .put("fallbackOnly", true)
                .put("nextStep", "原始字符串只证明内容存在。Blutter 成功后再用 locate/xref 绑定到函数；禁止仅凭字符串直接修改。"))
        }.getOrElse { error ->
            err("RAW_STRING_SCAN_FAILED", error.message ?: "Cannot scan libapp.so", "path", args.str("path"))
        }
    }

    private fun values(args: JSONObject): JSONObject {
        val rawValues = args.str("query")
            .ifBlank { args.opt("value")?.toString().orEmpty() }
            .ifBlank { args.str("values") }
            .trim()
        val requestedValues = parseBlutterValues(rawValues)
        if (requestedValues.isEmpty()) {
            return err("VALUES_REQUIRED", "query must contain one or more decimal/hex values, e.g. 5,55 or 0x5,0x37", "query", rawValues)
        }
        val resolved = resolveResultDir(args.str("jobId"))
            ?: return err("RESULT_NOT_FOUND", "No succeeded blutter result available; run analyze first", "jobId", args.str("jobId"))
        val goal = args.str("goal").trim()
        val domain = blutterIntentDomain(goal)
        val groups = blutterIntentGroups(domain)
        val profile = if (groups.isEmpty()) JSONObject() else BlutterSearchIndex.profilePp(resolved.second, groups)
        val systems = profile.optJSONArray("systems") ?: JSONArray()
        val selectedId = profile.optJSONObject("selectedSystem")?.optString("id").orEmpty()
        val contextSystemIds = linkedSetOf<String>().apply {
            if (selectedId.isNotBlank()) add(selectedId)
            if (domain == "membership") add("presentation_only")
        }
        val contextOffsets = mutableListOf<Long>()
        (0 until systems.length()).mapNotNull(systems::optJSONObject)
            .filter { it.optString("id") in contextSystemIds }
            .forEach { system ->
                val samples = system.optJSONArray("samples") ?: JSONArray()
                (0 until samples.length()).mapNotNull(samples::optJSONObject).forEach { sample ->
                    sample.optString("offset").removePrefix("0x").toLongOrNull(16)?.let(contextOffsets::add)
                }
            }
        val ppContext = BlutterSearchIndex.ppContexts(resolved.second, contextOffsets.distinct().take(16))
        val contextClasses = mutableListOf<String>()
        val symbols = ppContext.optJSONArray("symbols") ?: JSONArray()
        (0 until symbols.length()).map(symbols::optString).filter(String::isNotBlank).forEach(contextClasses::add)
        val anchorVa = args.str("va").ifBlank { args.str("addr") }
            .removePrefix("0x").removePrefix("0X").toLongOrNull(16)
        if (anchorVa != null) {
            val anchor = BlutterSearchIndex.disasmFunction(resolved.second, anchorVa, 200)
            if (anchor.optBoolean("usable", false)) {
                anchor.optJSONObject("function")?.optString("class")?.takeIf(String::isNotBlank)?.let(contextClasses::add)
            }
        }
        val result = BlutterSearchIndex.searchImmediateValues(
            resolved.second,
            requestedValues,
            blutterSemanticHints(domain, listOf(selectedId).filter(String::isNotBlank)) + blutterGoalHints(goal),
            contextClasses.distinct(),
            contextOffsets.distinct(),
            args.optInt("limit", 30).coerceIn(1, 100),
        )
        return ok(JSONObject()
            .put("jobId", resolved.first)
            .put("goal", goal)
            .put("intentDomain", domain)
            .put("valueSearch", result)
            .put("intentProfile", blutterCompactIntentProfile(profile))
            .put("contextSummary", JSONObject()
                .put("symbols", JSONArray(contextClasses.distinct().take(24)))
                .put("symbolCount", contextClasses.distinct().size)
                .put("poolOffsetCount", contextOffsets.distinct().size))
            .put("nextStep", "valueSearch 已同时检查原始立即数、Dart Smi 编码和对象池整数引用。优先核对 score 高且 contextClass=true / matchedHints 非空的函数；addressingOffsetsExcluded 是字段/栈偏移，绝不能当等级值。用候选 functionVa 调原生 disasm 读真实函数边界后再决定补丁。"))
    }

    private fun xref(args: JSONObject): JSONObject {
        // 支持多偏移聚合（逗号/空格分隔，如 "0x4d58,0x4d60"）：
        // 一次 asm 扫描返回全部，避免逐个 xref 反复遍历大目录。
        val raw = args.str("poolOffset").ifBlank { args.str("offset") }.trim()
        val offsets = parseBlutterPoolOffsets(raw)
        if (offsets.isEmpty()) return err("OFFSET_REQUIRED", "poolOffset is required (hex pool offset from search, e.g. 0x1aba8; multiple offsets may be comma-separated)", "poolOffset", raw)
        val limit = args.optInt("limit", 100).coerceIn(1, 500)
        val resolved = resolveResultDir(args.str("jobId"))
            ?: return err("RESULT_NOT_FOUND", "No succeeded blutter result available; run analyze first", "jobId", args.str("jobId"))
        val scan = BlutterSearchIndex.xrefMany(resolved.second, offsets, limit)
        val response = JSONObject()
            .put("jobId", resolved.first)
            .put("offsets", JSONArray(offsets.map { "0x${it.toString(16)}" }))
            .put("addressMapping", scan.optString("addressMapping"))
        val byOffset = scan.optJSONObject("refsByOffset") ?: JSONObject()
        var totalRefs = 0
        for (offset in offsets) {
            val key = "0x${offset.toString(16)}"
            val refs = byOffset.optJSONArray(key) ?: JSONArray()
            totalRefs += refs.length()
            response.put(key, refs)
        }
        return ok(response
            .put("count", totalRefs)
            .put("nextStep", "先检查 refs[].boundaryStatus。verified 才可用 functionVa 调 blutterAction=disasm；unverified 禁止使用 artifactFunctionHint，改用 verificationVa 调 so_analyze(action=disasm) 读取原始代码，再以 refs[].va 作 locator 进入 edit_open→edit_asm dryRun。"))
    }

    private fun trace(args: JSONObject): JSONObject {
        val rawOffsets = args.str("poolOffset").ifBlank { args.str("offset") }.trim()
        val offsets = parseBlutterPoolOffsets(rawOffsets)
        if (offsets.isEmpty()) return err("OFFSET_REQUIRED", "poolOffset is required", "poolOffset", rawOffsets)
        val resolved = resolveResultDir(args.str("jobId"))
            ?: return err("RESULT_NOT_FOUND", "No succeeded blutter result available; run analyze first", "jobId", args.str("jobId"))
        val refs = BlutterSearchIndex.xrefMany(resolved.second, offsets, 12)
        val anchors = blutterReferenceAnchors(refs.optJSONObject("refsByOffset") ?: JSONObject())
        val goal = args.str("goal").ifBlank { args.str("query") }.trim()
        val domain = blutterIntentDomain(goal)
        val flow = BlutterSearchIndex.traceFieldFlow(
            resolved.second,
            anchors,
            extractBlutterGoalValues(goal),
            blutterSemanticHints(domain, emptyList()) + blutterGoalHints(goal),
            emptyList(),
            blutterGoalHints(goal),
            args.optInt("limit", 20).coerceIn(1, 100),
            excludePatterns = excludePatterns(args),
        )
        return ok(JSONObject()
            .put("jobId", resolved.first)
            .put("poolOffsets", JSONArray(offsets.map { "0x${it.toString(16)}" }))
            .put("fieldFlow", flow)
            .put("nextStep", "优先验证 consumers 中 sliceConfidence=high 且 decisionEvidence 进入比较/分支的函数。字段偏移来自真实写入，决策证据来自读取后的寄存器切片，不由字段名或数值猜测。"))
    }

    /** 用户目标 → 多关键词 pp 精查 → 一次 asm 扫描取函数/VA。 */
    private fun locate(args: JSONObject, workDirectory: WorkDirectory?): JSONObject {
        val started = System.nanoTime()
        val goal = args.str("goal").ifBlank { args.str("query") }.trim()
        if (goal.isEmpty()) return err("GOAL_REQUIRED", "goal is required for locate (e.g. 去掉代理检测 / 定位会员判断)", "goal", goal)
        val resolved = resolveResultDir(args.str("jobId")) ?: return if (args.str("path").isNotBlank()) {
            rawStrings(args, workDirectory).put("reason", "No succeeded Blutter result; returned direct libapp.so string evidence instead of an empty result.")
        } else {
            err("RESULT_NOT_FOUND", "No succeeded blutter result available; run analyze first, or pass path for raw libapp.so string fallback", "jobId", args.str("jobId"))
        }
        val limit = args.optInt("limit", 12).coerceIn(1, 30)
        val intentDomain = blutterIntentDomain(goal)
        val intentGroups = blutterIntentGroups(intentDomain)
        val comparisonSystemId = when (intentDomain) {
            "membership" -> "presentation_only"
            "ads" -> "ad_ui_container"
            else -> null
        }
        val ppPipeline = BlutterSearchIndex.profileAndLocatePp(
            resolved.second,
            intentGroups,
            blutterPrimaryKeywords(goal),
            blutterLocateKeywords(goal),
            limit,
            comparisonSystemId,
        )
        val intentProfile = ppPipeline.optJSONObject("profile") ?: JSONObject()
        val profileStatus = intentProfile.optString("classificationStatus", "not_applicable")
        val rankedSystems = intentProfile.optJSONArray("systems") ?: JSONArray()
        val selectedSystems = (0 until minOf(rankedSystems.length(), if (intentProfile.optBoolean("ambiguous")) 2 else 1))
            .mapNotNull(rankedSystems::optJSONObject)
        val selectedSystemIds = selectedSystems.map { it.optString("id") }
        val classificationStatus = if (
            profileStatus == "clear" && selectedSystemIds.any(::blutterCluesOnlySystem)
        ) "clues_only" else profileStatus
        val keywordStage = ppPipeline.optString("keywordStage", "exact")
        val pp = ppPipeline.optJSONObject("locate") ?: JSONObject()
        val rawCandidates = pp.optJSONArray("candidates") ?: JSONArray()
        val primaryStage = keywordStage == "intent_profile" || keywordStage == "exact"
        val exactCandidates = if (primaryStage) {
            (0 until rawCandidates.length()).mapNotNull(rawCandidates::optJSONObject)
        } else emptyList()
        val orderedCandidates = JSONArray()
        (exactCandidates + (0 until rawCandidates.length()).mapNotNull(rawCandidates::optJSONObject))
            .distinctBy { it.optString("offset") }
            .take(limit)
            .forEach(orderedCandidates::put)
        // 用户明确原词有命中时，只对原词命中的池项做 XREF。领域扩展词仍返回作线索，
        // 但不得反客为主生成无关补丁候选。
        val xrefCandidates = exactCandidates.ifEmpty {
            (0 until orderedCandidates.length()).mapNotNull(orderedCandidates::optJSONObject)
        }
        val offsets = xrefCandidates.mapNotNull { row ->
            row.optString("offset").removePrefix("0x").toLongOrNull(16)
        }
        val refs = BlutterSearchIndex.xrefMany(resolved.second, offsets, perOffsetLimit = 4)
        var candidateSource = if (selectedSystems.isEmpty()) keywordStage else
            "intent_profile:${selectedSystems.joinToString(",") { it.optString("id") }}"
        val comparisonMatches = JSONArray()
        if (comparisonSystemId != null && comparisonSystemId !in selectedSystemIds) {
            (0 until rankedSystems.length()).mapNotNull(rankedSystems::optJSONObject)
                .firstOrNull { it.optString("id") == comparisonSystemId }
                ?.optJSONArray("samples")
                ?.let { samples ->
                    (0 until samples.length()).mapNotNull(samples::optJSONObject).forEach { sample ->
                        comparisonMatches.put(JSONObject(sample.toString()).put("contextOnly", true))
                    }
                }
        }
        // 全链收口：按引用计数聚合 top 函数，并生成可直接修改的紧凑候选。
        val byOffset = refs.optJSONObject("refsByOffset") ?: JSONObject()
        val functionScores = LinkedHashMap<String, Int>()
        val functionVas = HashMap<String, Long>()
        val functionNames = HashMap<String, String>()
        val functionFiles = HashMap<String, String>()
        val functionOffsets = LinkedHashMap<String, LinkedHashSet<String>>()
        val functionReferenceVas = LinkedHashMap<String, LinkedHashSet<Long>>()
        byOffset.keys().forEach { offsetKey ->
            val rows = byOffset.optJSONArray(offsetKey) ?: return@forEach
            (0 until rows.length()).forEach { index ->
                val row = rows.optJSONObject(index) ?: return@forEach
                val fname = row.optString("function").takeIf { it.isNotBlank() && it != "null" }
                    ?: row.optString("class").takeIf { it.isNotBlank() && it != "null" } ?: return@forEach
                val fva = row.optString("functionVa").removePrefix("0x").toLongOrNull(16)
                    ?: row.optString("va").removePrefix("0x").toLongOrNull(16)
                    ?: return@forEach
                val functionKey = fva.toString(16)
                functionScores[functionKey] = (functionScores[functionKey] ?: 0) + 1
                functionVas[functionKey] = fva
                functionNames.putIfAbsent(functionKey, fname)
                row.optString("file").takeIf(String::isNotBlank)?.let { functionFiles.putIfAbsent(functionKey, it) }
                functionOffsets.getOrPut(functionKey) { linkedSetOf() }.add(offsetKey)
                row.optString("va").removePrefix("0x").toLongOrNull(16)?.let {
                    functionReferenceVas.getOrPut(functionKey) { linkedSetOf() }.add(it)
                }
            }
        }
        val bodies = JSONArray()
        val patchCandidates = JSONArray()
        val clueCandidates = JSONArray()
        val verificationWindows = JSONArray()
        val seen = HashSet<Long>()
        val poolTextByOffset = HashMap<String, String>()
        val poolTermsByOffset = HashMap<String, List<String>>()
        (0 until orderedCandidates.length()).forEach { index ->
            val row = orderedCandidates.optJSONObject(index) ?: return@forEach
            poolTextByOffset[row.optString("offset")] = row.optString("text")
            val terms = row.optJSONArray("matchedTerms") ?: JSONArray()
            poolTermsByOffset[row.optString("offset")] = (0 until terms.length()).map(terms::optString)
        }
        (0 until comparisonMatches.length()).forEach { index ->
            val row = comparisonMatches.optJSONObject(index) ?: return@forEach
            poolTextByOffset[row.optString("offset")] = row.optString("text")
        }
        val firstPartyRoots = BlutterSearchIndex.firstPartyAsmRoots(resolved.second)
        val rankedDirectFunctions = functionScores.entries.map { entry ->
            val offsetsForFunction = functionOffsets[entry.key].orEmpty().toList()
            val terms = offsetsForFunction.flatMap { poolTermsByOffset[it].orEmpty() }.distinct()
            val distinctStringBonus = offsetsForFunction.mapNotNull(poolTextByOffset::get).distinct().size.coerceAtMost(5) * 40
            val name = functionNames[entry.key].orEmpty()
            val sourceScore = blutterSourceOwnershipScore(functionFiles[entry.key].orEmpty(), firstPartyRoots)
            Triple(entry, offsetsForFunction, blutterDirectCandidateScore(intentDomain, selectedSystemIds, name, terms) + distinctStringBonus + sourceScore)
        }.sortedWith(compareByDescending<Triple<Map.Entry<String, Int>, List<String>, Int>> { it.third }
            .thenByDescending { it.first.value })
        rankedDirectFunctions.take(4).forEach { (entry, offsetsForFunction, semanticScore) ->
            val name = functionNames[entry.key] ?: return@forEach
            val score = entry.value
            val fva = functionVas[entry.key] ?: return@forEach
            val referenceVas = functionReferenceVas[entry.key].orEmpty().toList().sorted()
            val (verificationVa, verificationMaxBytes) = blutterVerificationWindow(fva, referenceVas)
            if (blutterParserLikeFunction(name)) {
                clueCandidates.put(JSONObject()
                    .put("functionVa", "0x${fva.toString(16)}")
                    .put("function", name)
                    .put("refCount", score)
                    .put("semanticScore", semanticScore)
                    .put("verificationVa", "0x${verificationVa.toString(16)}")
                    .put("verificationMaxBytes", verificationMaxBytes)
                    .put("matchedPoolOffsets", JSONArray(offsetsForFunction))
                    .put("matchedStrings", JSONArray(offsetsForFunction.mapNotNull(poolTextByOffset::get)))
                    .put("reason", "parser_or_serializer_is_field_origin_evidence_not_a_business_patch_target"))
                return@forEach
            }
            verificationWindows.put(JSONObject()
                .put("function", name)
                .put("functionVa", "0x${fva.toString(16)}")
                .put("verificationVa", "0x${verificationVa.toString(16)}")
                .put("maxBytes", verificationMaxBytes)
                .put("referenceVas", JSONArray(referenceVas.map { "0x${it.toString(16)}" }))
                .put("matchedStrings", JSONArray(offsetsForFunction.mapNotNull(poolTextByOffset::get))))
            if (!blutterDirectCandidateEligible(semanticScore)) {
                clueCandidates.put(JSONObject()
                    .put("functionVa", "0x${fva.toString(16)}")
                    .put("function", name)
                    .put("refCount", score)
                    .put("semanticScore", semanticScore)
                    .put("verificationVa", "0x${verificationVa.toString(16)}")
                    .put("verificationMaxBytes", verificationMaxBytes)
                    .put("referenceVas", JSONArray(referenceVas.map { "0x${it.toString(16)}" }))
                    .put("matchedPoolOffsets", JSONArray(offsetsForFunction))
                    .put("matchedStrings", JSONArray(offsetsForFunction.mapNotNull(poolTextByOffset::get)))
                    .put("reason", "reference_exists_but_return_type_or_business_semantics_do_not_match_selected_system"))
                return@forEach
            }
            val body = runCatching { BlutterSearchIndex.disasmFunction(resolved.second, fva, 200) }.getOrNull() ?: return@forEach
            if (!body.optBoolean("found") || !body.optBoolean("usable", true)) {
                clueCandidates.put(JSONObject()
                    .put("functionVa", "0x${fva.toString(16)}")
                    .put("function", name)
                    .put("refCount", score)
                    .put("semanticScore", semanticScore)
                    .put("verificationVa", "0x${verificationVa.toString(16)}")
                    .put("verificationMaxBytes", verificationMaxBytes)
                    .put("referenceVas", JSONArray(referenceVas.map { "0x${it.toString(16)}" }))
                    .put("matchedPoolOffsets", JSONArray(offsetsForFunction))
                    .put("matchedStrings", JSONArray(offsetsForFunction.mapNotNull(poolTextByOffset::get)))
                    .put("reason", "function_body_unavailable_use_reference_va"))
                return@forEach
            }
            val faddr = body.optJSONObject("function")?.optString("addr")?.removePrefix("0x")?.toLongOrNull(16)
            if (faddr != null && !seen.add(faddr)) return@forEach
            patchCandidates.put(JSONObject()
                .put("functionVa", body.optString("va"))
                .put("function", body.optJSONObject("function"))
                .put("refCount", score)
                .put("semanticScore", semanticScore)
                .put("verificationVa", "0x${verificationVa.toString(16)}")
                .put("verificationMaxBytes", verificationMaxBytes)
                .put("referenceVas", JSONArray(referenceVas.map { "0x${it.toString(16)}" }))
                .put("matchedPoolOffsets", JSONArray(offsetsForFunction))
                .put("matchedStrings", JSONArray(offsetsForFunction.mapNotNull(poolTextByOffset::get)))
                .put("patchHint", body.optString("patchHint"))
                .put("hasConditionalBranch", body.optBoolean("hasBusinessConditionalBranch")))
            if (args.optBoolean("includeBodies", false)) bodies.put(body.put("refCount", score))
        }
        var ppContext = JSONObject().put("contexts", JSONArray()).put("symbols", JSONArray())
        var classOutline = JSONObject().put("classes", JSONArray()).put("methods", JSONArray())
        var valueContextOffsets = offsets.distinct()
        if (patchCandidates.length() == 0 && classificationStatus == "clear") {
            val structuralOffsets = ((0 until orderedCandidates.length()).mapNotNull { index ->
                val row = orderedCandidates.optJSONObject(index) ?: return@mapNotNull null
                val matchedTerms = row.optJSONArray("matchedTerms") ?: JSONArray()
                val structural = (0 until matchedTerms.length()).map(matchedTerms::optString)
                    .any(::blutterStructuralFeatureTerm)
                if (structural) row.optString("offset").removePrefix("0x").toLongOrNull(16) else null
            } + (0 until comparisonMatches.length()).mapNotNull { index ->
                comparisonMatches.optJSONObject(index)?.optString("offset")?.removePrefix("0x")?.toLongOrNull(16)
            }).distinct().take(16)
            valueContextOffsets = (valueContextOffsets + structuralOffsets).distinct()
            if (structuralOffsets.isNotEmpty()) {
                ppContext = BlutterSearchIndex.ppContexts(resolved.second, structuralOffsets)
                val symbolsJson = ppContext.optJSONArray("symbols") ?: JSONArray()
                val symbols = (0 until symbolsJson.length()).map(symbolsJson::optString).filter(String::isNotBlank)
                if (symbols.isNotEmpty()) {
                    classOutline = BlutterSearchIndex.outlineClasses(
                        resolved.second,
                        symbols,
                        blutterSemanticHints(intentDomain, selectedSystemIds),
                        24,
                    )
                    data class ContextCandidate(
                        val method: JSONObject,
                        val body: JSONObject,
                        val valueEvidence: JSONArray,
                        val score: Int,
                    )
                    val methods = classOutline.optJSONArray("methods") ?: JSONArray()
                    (0 until methods.length()).mapNotNull(methods::optJSONObject)
                        .filter { it.optBoolean("semanticMatch") }
                        .take(16)
                        .mapNotNull { method ->
                            val fva = method.optString("functionVa").removePrefix("0x").toLongOrNull(16)
                                ?: return@mapNotNull null
                            val body = runCatching { BlutterSearchIndex.disasmFunction(resolved.second, fva, 200) }.getOrNull()
                                ?: return@mapNotNull null
                            if (!body.optBoolean("found") || !body.optBoolean("usable", false)) return@mapNotNull null
                            val lines = body.optJSONArray("lines") ?: JSONArray()
                            val valueEvidence = BlutterSearchIndex.functionValueEvidence(
                                (0 until lines.length()).map(lines::optString),
                            )
                            val smallBusinessValues = (0 until valueEvidence.length())
                                .map { valueEvidence.getJSONObject(it).getLong("value") }
                                .count { it in 0..255 }
                            ContextCandidate(method, body, valueEvidence, method.optInt("score") + smallBusinessValues * 200)
                        }
                        .sortedWith(compareByDescending<ContextCandidate> { it.score }
                            .thenBy { it.method.optString("functionVa") })
                        .take(3)
                        .forEach { candidate ->
                            val method = candidate.method
                            val body = candidate.body
                            val valueEvidence = candidate.valueEvidence
                            val fva = method.optString("functionVa").removePrefix("0x").toLongOrNull(16)
                                ?: return@forEach
                            if (!seen.add(fva)) return@forEach
                            patchCandidates.put(JSONObject()
                                .put("functionVa", method.optString("functionVa"))
                                .put("function", body.optJSONObject("function"))
                                .put("refCount", 0)
                                .put("semanticScore", candidate.score)
                                .put("evidenceSource", "pp_adjacent_type_class_outline")
                                .put("contextSymbols", JSONArray(symbols))
                                .put("matchedHints", method.optJSONArray("matchedHints"))
                                .put("observedValues", JSONArray((0 until valueEvidence.length())
                                    .map { valueEvidence.getJSONObject(it).getLong("value") }.distinct()))
                                .put("valueEvidence", valueEvidence)
                                .put("matchedPoolOffsets", JSONArray(structuralOffsets.map { "0x${it.toString(16)}" }))
                                .put("matchedStrings", JSONArray(structuralOffsets.mapNotNull { poolTextByOffset["0x${it.toString(16)}"] }))
                                .put("patchHint", body.optString("patchHint"))
                                .put("hasConditionalBranch", body.optBoolean("hasBusinessConditionalBranch")))
                            if (args.optBoolean("includeBodies", false)) bodies.put(body.put("refCount", 0))
                        }
                    if (patchCandidates.length() > 0) candidateSource += ":pp_context_class_outline"
                }
            }
        }
        val explicitValues = extractBlutterGoalValues(goal)
        val contextSymbols = ppContext.optJSONArray("symbols") ?: JSONArray()
        val deep = args.optBoolean("deep", false)
        val valueSearch = when {
            explicitValues.isEmpty() -> JSONObject()
            deep -> BlutterSearchIndex.searchImmediateValues(
                resolved.second,
                explicitValues,
                blutterSemanticHints(intentDomain, selectedSystemIds) + blutterGoalHints(goal),
                (0 until contextSymbols.length()).map(contextSymbols::optString).filter(String::isNotBlank),
                valueContextOffsets,
                20,
            )
            else -> JSONObject()
                .put("values", JSONArray(explicitValues))
                .put("deferred", true)
                .put("reason", "FAST_PATH_USES_CANDIDATE_WINDOWS")
        }
        val shouldTraceFieldFlow = deep
        val fieldFlow = if (shouldTraceFieldFlow) {
            BlutterSearchIndex.traceFieldFlow(
                resolved.second,
                blutterReferenceAnchors(byOffset),
                explicitValues,
                blutterSemanticHints(intentDomain, selectedSystemIds) + blutterGoalHints(goal),
                (0 until contextSymbols.length()).map(contextSymbols::optString).filter(String::isNotBlank),
                blutterGoalHints(goal),
                20,
                excludePatterns = excludePatterns(args),
            )
        } else {
            JSONObject()
                .put("fieldWrites", JSONArray())
                .put("consumers", JSONArray())
                .put("deferred", true)
                .put("reason", "DEEP_TRACE_NOT_REQUESTED")
        }
        val valueCandidates = valueSearch.optJSONArray("candidates") ?: JSONArray()
        val strongValueCandidates = (0 until valueCandidates.length())
            .mapNotNull(valueCandidates::optJSONObject)
            .filter { candidate ->
                candidate.optInt("score") >= 200 || candidate.optBoolean("contextClass") ||
                    (candidate.optJSONArray("matchedHints")?.length() ?: 0) > 0
            }
            .take(5)
        val existingVerificationVas = (0 until verificationWindows.length()).mapNotNull { index ->
            verificationWindows.optJSONObject(index)?.optString("functionVa")
        }.toMutableSet()
        strongValueCandidates.forEach { candidate ->
            val functionVa = candidate.optString("functionVa")
            if (functionVa.isBlank() || !existingVerificationVas.add(functionVa)) return@forEach
            verificationWindows.put(JSONObject()
                .put("function", candidate.opt("function"))
                .put("functionVa", functionVa)
                .put("verificationVa", functionVa)
                .put("maxBytes", 1024)
                .put("evidenceSource", "explicit_value_evidence")
                .put("matchedValues", candidate.optJSONArray("values") ?: JSONArray())
                .put("valueEvidence", candidate.optJSONArray("evidence") ?: JSONArray())
                .put("contextClass", candidate.optBoolean("contextClass"))
                .put("matchedHints", candidate.optJSONArray("matchedHints") ?: JSONArray()))
        }
        val fieldConsumers = fieldFlow.optJSONArray("consumers") ?: JSONArray()
        val rankedFieldConsumers = (0 until fieldConsumers.length()).mapNotNull(fieldConsumers::optJSONObject)
        val decisionFieldConsumers = rankedFieldConsumers.filter { it.optBoolean("hasDecisionSink") }
        val strongFieldConsumers = (decisionFieldConsumers.ifEmpty {
            rankedFieldConsumers.filter { it.optInt("score") >= 300 }
        }).take(8)
        strongFieldConsumers.forEach { candidate ->
            val functionVa = candidate.optString("functionVa")
            if (functionVa.isBlank() || !existingVerificationVas.add(functionVa)) return@forEach
            verificationWindows.put(JSONObject()
                .put("function", candidate.opt("function"))
                .put("functionVa", functionVa)
                .put("verificationVa", functionVa)
                .put("maxBytes", 1024)
                .put("evidenceSource", "semantic_field_data_flow")
                .put("fieldOffsets", candidate.optJSONArray("fieldOffsets") ?: JSONArray())
                .put("fieldReads", candidate.optJSONArray("fieldReads") ?: JSONArray())
                .put("matchedTypes", candidate.optJSONArray("matchedTypes") ?: JSONArray())
                .put("matchedFiles", candidate.optJSONArray("matchedFiles") ?: JSONArray())
                .put("valueEvidence", candidate.optJSONArray("valueEvidence") ?: JSONArray())
                .put("decisionEvidence", candidate.optJSONArray("decisionEvidence") ?: JSONArray())
                .put("sliceConfidence", candidate.optString("sliceConfidence")))
        }
        val rawDecisionFlow = if (
            "tier_level" in selectedSystemIds && verificationWindows.length() > 0
        ) {
            runCatching {
                val libapp = resolveCurrentLibapp(args, workDirectory, resolved.first)
                if (libapp == null) JSONObject().put("status", "source_unavailable")
                else BlutterSearchIndex.rawDecisionFlow(
                    libapp,
                    verificationWindows,
                    byOffset,
                    poolTextByOffset,
                    explicitValues,
                    5,
                )
            }.getOrElse { error ->
                JSONObject()
                    .put("status", "raw_scan_failed")
                    .put("message", error.message ?: "Cannot inspect current libapp bytes")
            }
        } else JSONObject().put("status", "not_applicable")
        val rawDecisionCandidates = rawDecisionFlow.optJSONArray("candidates") ?: JSONArray()
        (0 until rawDecisionCandidates.length()).mapNotNull(rawDecisionCandidates::optJSONObject).forEach { candidate ->
            val functionVa = candidate.optString("functionVa")
            if (functionVa.isBlank() || !seen.add(functionVa.removePrefix("0x").toLongOrNull(16) ?: return@forEach)) {
                return@forEach
            }
            patchCandidates.put(JSONObject(candidate.toString())
                .put("refCount", 0)
                .put("semanticScore", candidate.optInt("score"))
                .put("hasConditionalBranch", true))
        }
        if (rawDecisionCandidates.length() > 0) candidateSource += ":raw_arm64_decision_flow"
        val includeEvidence = args.optBoolean("includeEvidence", false)
        val payload = JSONObject()
            .put("jobId", resolved.first)
            .put("goal", goal)
            .put("elapsedMs", (System.nanoTime() - started) / 1_000_000)
            .put("intentDomain", intentDomain)
            .put("intentProfile", blutterCompactIntentProfile(intentProfile))
            .put("systemIdentified", classificationStatus == "clear")
            .put("classificationStatus", classificationStatus)
            .put("keywordStage", keywordStage)
            .put("ppScan", JSONObject()
                .put("cacheHit", ppPipeline.optBoolean("cacheHit"))
                .put("elapsedMs", ppPipeline.optLong("scanElapsedMs"))
                .put("scannedLines", ppPipeline.optLong("scannedLines")))
            .put("pipeline", if (deep) "key -> reference -> field flow -> value evidence -> verification" else "key -> compact reference -> candidate window -> raw value/branch verification")
            .put("contentFound", pp.optInt("matched") > 0)
            .put("exactContentFound", keywordStage == "exact" && exactCandidates.isNotEmpty())
            .put("primaryContentFound", primaryStage && exactCandidates.isNotEmpty())
            .put("poolMatches", orderedCandidates)
            .put("comparisonMatches", blutterJsonArrayTake(comparisonMatches, 6))
            .put("candidateSource", candidateSource)
            .put("patchCandidates", patchCandidates)
            .put("clueCandidates", clueCandidates)
            .put("verificationWindows", verificationWindows)
            .put("explicitValues", JSONArray(explicitValues))
            .put("valueSearch", valueSearch)
            .put("valueCandidates", JSONArray(strongValueCandidates))
            .put("fieldFlow", fieldFlow)
            .put("fieldCandidates", JSONArray(strongFieldConsumers))
            .put("rawDecisionFlow", rawDecisionFlow)
            .put("candidateCount", patchCandidates.length())
            .put("contextSummary", JSONObject()
                .put("symbols", ppContext.optJSONArray("symbols")?.length() ?: 0)
                .put("classes", classOutline.optJSONArray("classes")?.length() ?: 0)
                .put("methods", classOutline.optJSONArray("methods")?.length() ?: 0))
            .put("readyForVerification", classificationStatus != "ambiguous" && (patchCandidates.length() > 0 || verificationWindows.length() > 0 || strongValueCandidates.isNotEmpty() || strongFieldConsumers.isNotEmpty()))
            .put("readyForPatch", false)
            .put("ppSummary", JSONObject().put("matched", pp.optInt("matched")).put("candidateCount", orderedCandidates.length()))
            .put("functionBodies", bodies)
            .put("nextStep", if (strongFieldConsumers.isNotEmpty()) {
                if (decisionFieldConsumers.isNotEmpty())
                    "已从字段键追到真实字段读取，并由寄存器切片证明前列候选进入比较、条件分支或返回。直接核对 decisionEvidence 的比较值与分支方向后 dryRun；无需再按文案盲搜。"
                else
                    "已追到同偏移字段读取，但尚无寄存器决策证据。fieldCandidates 仅作线索，继续 disasm 验证，禁止直接修改。"
            } else if (strongValueCandidates.isNotEmpty()) {
                "已把用户给出的数值按原始整数和 Dart Smi 编码交叉定位到类型/文件上下文。直接对 valueCandidates[0].functionVa 做原生 disasm，确认字段读取、比较方向和返回值。"
            } else when (classificationStatus) {
                "ambiguous" -> "业务体系仍有歧义：先比较 intentProfile.systems 前两项的 matchedKeywords、samples 与 XREF，确认真实状态字段或广告展示闸门；禁止修改 UI 文案、支付词或单一字符串命中。"
                "clues_only" -> if (intentDomain == "ads") "当前只命中广告容器/UI，尚未定位展示触发点；改查 shouldShowAd/isAdEnabled 或 showInterstitialAd/showRewardedAd 的调用链，禁止修改容器。" else "当前只找到 UI、网络栈或 SDK 线索，尚未识别真实业务判定；继续搜索状态字段、等级、到期值或调用函数，禁止据此修改。"
                else -> if (patchCandidates.length() == 0)
                    if (verificationWindows.length() > 0) "体系已按 PP 中英文特征统计收敛，但 Blutter 函数体不完整。直接对 verificationWindows 中的 verificationVa 做原生 disasm，从字符串引用现场核对比较值和返回值；禁止从未知大小函数头盲扫或直接修改。"
                    else "体系已按 PP 中英文特征统计收敛，但直接 XREF 和相邻类型类轮廓都没有真实函数候选；下一步应结合抓包响应字段或动态调用记录补证，禁止读取不存在的候选或直接修改。"
                else "体系已按 PP 中英文特征统计收敛。优先从最高候选 verificationVa 的字符串引用现场反汇编，确认同一函数同时覆盖等级标签、比较值和返回值；不要仅凭候选排序或展示 getter 修改。三重证据一致后才 edit_asm dryRun。"
            })
        if (includeEvidence) payload.put("ppContext", ppContext).put("classOutline", classOutline)
        if (intentDomain in setOf("membership", "capture", "ads")) {
            val report = blutterBuildAnalysisReport(payload)
            store.saveReport(resolved.first, intentDomain, report)
            payload.put("reportSaved", true)
                .put("reportStatus", report.optString("status"))
                .put("reportAction", "so_analyze(action=blutter, blutterAction=report, jobId=${resolved.first}, report=$intentDomain)")
        }
        return ok(payload)
    }

    private fun report(args: JSONObject): JSONObject {
        val reportName = args.str("report", "membership").lowercase()
        if (reportName !in setOf("membership", "capture", "ads")) {
            return err("INVALID_REPORT", "report must be membership | capture | ads", "report", reportName)
        }
        val resolved = resolveResultDir(args.str("jobId"))
            ?: return err("RESULT_NOT_FOUND", "No succeeded blutter result available; run analyze first", "jobId", args.str("jobId"))
        val saved = store.readReport(resolved.first, reportName)
            ?: return err(
                "REPORT_NOT_READY",
                "No saved $reportName report. Run blutterAction=locate once with the target goal; do not repeat analyze.",
                "jobId",
                resolved.first,
            )
        return ok(saved.put("jobId", resolved.first).put("reused", true))
    }

    /** 反向引用：函数 VA → 直接调用点及对象池闭包间接调用点。 */
    private fun callers(args: JSONObject): JSONObject {
        val raw = args.str("va").ifBlank { args.str("addr") }.trim()
        val va = raw.removePrefix("0x").removePrefix("0X").toLongOrNull(16)
            ?: return err("VA_REQUIRED", "va is required (function VA from locate/xref/disasm, e.g. 0x804698) to find its callers", "va", raw)
        val limit = args.optInt("limit", 50).coerceIn(1, 200)
        val poolOffsets = parseBlutterPoolOffsets(args.str("poolOffset").ifBlank { args.str("offset") })
        val resolved = resolveResultDir(args.str("jobId"))
            ?: return err("RESULT_NOT_FOUND", "No succeeded blutter result available; run analyze first", "jobId", args.str("jobId"))
        val result = BlutterSearchIndex.callersOf(resolved.second, va, limit, poolOffsets)
        return ok(result
            .put("jobId", resolved.first)
            .put("targetVa", "0x${va.toString(16)}")
            .put("nextStep", "callers 同时返回 bl/b 直接调用与对象池闭包 blr 间接调用。若 closurePoolOffsets 为空，说明 pp.txt 未标注该 Code VA；把已知闭包槽作为 poolOffset 重发一次。读 caller 函数体用 blutterAction=disasm va=functionVa。"))
    }

    /** 按函数/指令 VA 读 asm 反汇编体（含 [pp+0x...] 池注释）——官方工作流核心一步。 */

    /** consumers 噪声排除：consumerExclude 数组或 | 分隔字符串。 */
    private fun excludePatterns(args: JSONObject): List<String> {
        val out = linkedSetOf<String>()
        val arr = args.optJSONArray("consumerExclude")
        if (arr != null) {
            (0 until arr.length()).forEach { i ->
                arr.optString(i).split('|', ',', ';').forEach { piece ->
                    if (piece.isNotBlank()) out.add(piece.trim())
                }
            }
        } else {
            args.str("consumerExclude").ifBlank { "" }
                .split('|', ',', ';')
                .forEach { if (it.isNotBlank()) out.add(it.trim()) }
        }
        return out.toList().take(16)
    }

    private fun disasm(args: JSONObject): JSONObject {
        val raw = args.str("va").ifBlank { args.str("addr") }.trim()
        val va = raw.removePrefix("0x").removePrefix("0X").toLongOrNull(16)
            ?: return err("VA_REQUIRED", "va is required (function or instruction VA from locate/xref, e.g. 0x804698)", "va", raw)
        val limit = args.optInt("limit", 400).coerceIn(20, 2000)
        val offset = args.optInt("offset", 0).coerceAtLeast(0)
        // 大函数取窗口：vaEnd（不含）直接按地址截断；byteOffset/bytes 以
        // 函数起点为基准换算为 VA 边界（ARM64 每指令 4 字节）。
        var vaEnd = args.str("vaEnd").ifBlank { args.str("to") }.removePrefix("0x").removePrefix("0X").toLongOrNull(16) ?: 0L
        if (vaEnd <= va) {
            val byteOffset = args.optInt("byteOffset", -1)
            val bytes = args.optInt("bytes", 0)
            if (byteOffset >= 0 && bytes > 0) {
                vaEnd = va + (byteOffset.toLong() / 4 + bytes / 4 + 1) * 4
            }
        }
        val resolved = resolveResultDir(args.str("jobId"))
            ?: return err("RESULT_NOT_FOUND", "No succeeded blutter result available; run analyze first", "jobId", args.str("jobId"))
        return ok(
            BlutterSearchIndex.disasmFunction(resolved.second, va, limit, offset, vaEnd)
                .put("jobId", resolved.first)
                .put("evidenceSource", "blutter_analysis_artifact")
                .put("currentFileVerified", false)
                .put("verificationSafe", false)
                .put("warning", "这是 Blutter 任务生成时的历史分析产物，只用于定位和理解；它不会随 patched.so 或签名 APK 自动更新。")
                .put("verificationAction", "验收补丁必须对当前 SO/APK 使用 so_analyze(action=hexdump/disasm) 读取真实字节，禁止用本结果判断补丁是否生效。"),
        )
    }

    private fun pathFilters(raw: String): List<String> = raw
        .split('|', ',', ';')
        .map(String::trim)
        .filter(String::isNotBlank)
        .distinctBy(String::lowercase)
        .take(16)

    private fun resolveResultDir(jobId: String): Pair<String, File>? {
        val id = jobId.takeIf { it.isNotBlank() } ?: store.latestSucceededJobId() ?: return null
        return store.resultDir(id)?.let { id to it }
    }

    private fun result(jobId: String, kind: String?, cursor: String?, limit: Int, fullInventory: Boolean): JSONObject {
        if (!fullInventory && !cursor.isNullOrBlank()) {
            return err("REFERENCE_PAGING_BLOCKED", "类/函数/对象清单只作参考，禁止无目标顺序翻页。请用 locate/search/xref/disasm 按证据定位；只有用户明确要求导出完整清单时才传 fullInventory=true。", "cursor", cursor)
        }
        return runCatching {
            val safeLimit = if (fullInventory) limit.coerceIn(1, 1000) else limit.coerceIn(1, 100)
            store.result(jobId, kind, cursor, safeLimit)?.let { payload ->
                if (kind != null && !fullInventory) {
                    payload.put("referenceOnly", true)
                        .put("pagingBlocked", true)
                        .put("nextStep", "不要继续翻清单。按目标使用 locate/search/xref/disasm；当前页没有新证据就停止读取。")
                    payload.optJSONObject(kind)?.put("nextCursor", JSONObject.NULL)
                }
                ok(payload)
            } ?: err("RESULT_NOT_FOUND", "Blutter result is not available", "jobId", jobId)
        }.getOrElse { err("INVALID_RESULT_REQUEST", it.message ?: "Invalid result request", "jobId", jobId) }
    }
    private fun cancel(jobId: String): JSONObject {
        embedded.cancel(jobId)
        exec.cancel(jobId)
        return if (store.cancel(jobId)) ok(JSONObject().put("jobId", jobId).put("status", "cancelled")) else err("JOB_NOT_CANCELLABLE", "Job was not found or already finished", "jobId", jobId)
    }

    private fun resolveLibraries(args: JSONObject, workDirectory: WorkDirectory?): FlutterLibraries {
        val path = args.str("path")
        val file = File(path)
        if (file.isDirectory) {
            val app = file.resolve("libapp.so").takeIf { it.isFile } ?: file.resolve("App").takeIf { it.isFile } ?: error("FLUTTER_LIBS_NOT_FOUND")
            val flutter = file.resolve("libflutter.so").takeIf { it.isFile } ?: file.resolve("Flutter").takeIf { it.isFile } ?: error("FLUTTER_LIBS_NOT_FOUND")
            return FlutterLibraries(file.name, "arm64-v8a", app.readBytes(), flutter.readBytes(), app.name, flutter.name)
        }
        val requestedAbi = args.str("abi", "arm64-v8a")
        if (file.isFile) {
            // 磁盘缓存：verify/locate/raw_strings 每轮都会走这里重读整个 APK 并解压，
            // 缓存提取产物后仅在 (路径,大小,mtime,abi) 变化时重提——补丁/重打包自动失效。
            readLibsCache(file, requestedAbi)?.let { return it }
            val libraries = FlutterArtifactInspector.extractLibraries(file, requestedAbi)
            writeLibsCache(file, requestedAbi, libraries)
            return libraries
        }
        val bytes = workDirectory?.readFile(path, ApkAnalyzer.MAX_INPUT_BYTES) ?: error("INPUT_NOT_FOUND")
        return FlutterArtifactInspector.extractLibraries(bytes, path, requestedAbi)
    }

    private fun resolveRunnerInput(args: JSONObject, workDirectory: WorkDirectory?): FlutterRunnerInput {
        val path = args.str("path")
        val file = File(path)
        val requestedAbi = args.str("abi", "arm64-v8a")
        if (file.isDirectory) {
            val app = file.resolve("libapp.so").takeIf { it.isFile } ?: file.resolve("App").takeIf { it.isFile } ?: error("FLUTTER_LIBS_NOT_FOUND")
            val flutter = file.resolve("libflutter.so").takeIf { it.isFile } ?: file.resolve("Flutter").takeIf { it.isFile } ?: error("FLUTTER_LIBS_NOT_FOUND")
            return FlutterRunnerInput(file.name, if (requestedAbi == "auto") "arm64-v8a" else requestedAbi, app, flutter, app.name, flutter.name)
        }
        if (file.isFile) {
            val dir = libsCacheDir(file, requestedAbi)
            val app = File(dir, "libapp.so")
            val flutter = File(dir, "libflutter.so")
            val meta = runCatching { JSONObject(File(dir, "meta.json").readText()) }.getOrNull()
            if (app.isFile && flutter.isFile && meta != null) {
                return FlutterRunnerInput(
                    meta.optString("displayName").takeIf { it.isNotBlank() } ?: file.name,
                    meta.optString("abi").takeIf { it.isNotBlank() } ?: requestedAbi,
                    app,
                    flutter,
                    meta.optString("libappEntry").takeIf { it.isNotBlank() } ?: "lib/$requestedAbi/libapp.so",
                    meta.optString("libflutterEntry").takeIf { it.isNotBlank() } ?: "lib/$requestedAbi/libflutter.so",
                )
            }
            return FlutterArtifactInspector.extractLibrariesTo(file, requestedAbi, dir).also { pruneLibsCache() }
        }
        return materializeRunnerInput(args, resolveLibraries(args, workDirectory))
    }

    private fun libsCacheRoot(): File = File(context.cacheDir, "blutter-libs").apply { mkdirs() }

    private fun libsCacheDir(file: File, requestedAbi: String): File {
        val stamp = "${file.absolutePath}|${file.length()}|${file.lastModified()}|$requestedAbi"
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(stamp.toByteArray())
        return File(libsCacheRoot(), digest.joinToString("") { "%02x".format(it) }.take(24))
    }

    private fun readLibsCache(file: File, requestedAbi: String): FlutterLibraries? {
        val dir = libsCacheDir(file, requestedAbi)
        val app = File(dir, "libapp.so")
        val flutter = File(dir, "libflutter.so")
        if (!app.isFile || !flutter.isFile) return null
        val meta = runCatching { JSONObject(File(dir, "meta.json").readText()) }.getOrNull()
        return FlutterLibraries(
            meta?.optString("displayName")?.takeIf { it.isNotBlank() } ?: file.nameWithoutExtension,
            meta?.optString("abi")?.takeIf { it.isNotBlank() } ?: requestedAbi,
            app.readBytes(),
            flutter.readBytes(),
            meta?.optString("libappEntry")?.takeIf { it.isNotBlank() } ?: "lib/$requestedAbi/libapp.so",
            meta?.optString("libflutterEntry")?.takeIf { it.isNotBlank() } ?: "lib/$requestedAbi/libflutter.so",
        )
    }

    private fun writeLibsCache(file: File, requestedAbi: String, libraries: FlutterLibraries) {
        runCatching {
            val dir = libsCacheDir(file, requestedAbi)
            dir.mkdirs()
            File(dir, "libapp.so").writeBytes(libraries.libapp)
            File(dir, "libflutter.so").writeBytes(libraries.libflutter)
            File(dir, "meta.json").writeText(JSONObject()
                .put("displayName", libraries.displayName)
                .put("abi", libraries.abi)
                .put("libappEntry", libraries.libappEntry)
                .put("libflutterEntry", libraries.libflutterEntry)
                .toString())
            pruneLibsCache()
        }
    }

    private fun materializeRunnerInput(args: JSONObject, libraries: FlutterLibraries): FlutterRunnerInput {
        val source = File(args.str("path"))
        val requestedAbi = args.str("abi", "arm64-v8a")
        val dir = if (source.isFile) {
            libsCacheDir(source, requestedAbi)
        } else {
            val stamp = libraries.displayName + '|' + libraries.abi + '|' + libraries.libapp.size + '|' + libraries.libflutter.size
            val digest = java.security.MessageDigest.getInstance("SHA-256").digest(stamp.toByteArray())
            File(libsCacheRoot(), "input-" + digest.joinToString("") { "%02x".format(it) }.take(24))
        }
        dir.mkdirs()
        val app = File(dir, "libapp.so")
        val flutter = File(dir, "libflutter.so")
        if (!app.isFile || app.length() != libraries.libapp.size.toLong()) app.writeBytes(libraries.libapp)
        if (!flutter.isFile || flutter.length() != libraries.libflutter.size.toLong()) flutter.writeBytes(libraries.libflutter)
        return FlutterRunnerInput(
            libraries.displayName,
            libraries.abi,
            app,
            flutter,
            libraries.libappEntry,
            libraries.libflutterEntry,
        )
    }

    /** 只保留最近 2 份提取缓存（一份 APK 的 libapp+libflutter 可达 30-60MB）。 */
    private fun pruneLibsCache(keep: Int = 2) {
        val dirs = libsCacheRoot().listFiles()?.filter { it.isDirectory } ?: return
        if (dirs.size <= keep) return
        dirs.sortedByDescending { it.lastModified() }.drop(keep).forEach { it.deleteRecursively() }
    }

    private fun resolveCurrentLibapp(
        args: JSONObject,
        workDirectory: WorkDirectory?,
        jobId: String,
    ): ByteArray? {
        val path = args.str("path").ifBlank { store.requestPath(jobId) }
        if (path.isBlank()) return null
        val file = File(path)
        // 快路径：目录模式直接读 libapp；APK 模式命中磁盘缓存只读 libapp，免读整个 APK 免解压
        if (file.isDirectory) {
            return (file.resolve("libapp.so").takeIf { it.isFile } ?: file.resolve("App").takeIf { it.isFile })?.readBytes()
        }
        if (file.isFile) {
            val dir = libsCacheDir(file, args.str("abi", "arm64-v8a"))
            val cached = File(dir, "libapp.so")
            if (cached.isFile) return cached.readBytes()
        }
        val request = JSONObject(args.toString()).put("path", path)
        return resolveLibraries(request, workDirectory).libapp
    }

    private fun inspectDirectory(dir: File, path: String, requestedAbi: String): JSONObject {
        val app = dir.resolve("libapp.so").takeIf { it.isFile } ?: dir.resolve("App").takeIf { it.isFile }
        val flutter = dir.resolve("libflutter.so").takeIf { it.isFile } ?: dir.resolve("Flutter").takeIf { it.isFile }
        if (app == null || flutter == null) return err("FLUTTER_LIBS_NOT_FOUND", "Directory must contain libapp.so and libflutter.so", "path", path)
        val abi = if (requestedAbi == "auto") "arm64-v8a" else requestedAbi
        return ok(FlutterArtifactInspector.inspectLibraries(FlutterLibraries(dir.name, abi, app.readBytes(), flutter.readBytes(), app.name, flutter.name)))
    }
}

internal fun blutterJsonArrayTake(source: JSONArray, limit: Int): JSONArray {
    val result = JSONArray()
    for (index in 0 until minOf(source.length(), limit.coerceAtLeast(0))) result.put(source.get(index))
    return result
}

internal fun blutterCompactIntentProfile(profile: JSONObject): JSONObject {
    val systems = profile.optJSONArray("systems") ?: JSONArray()
    val compactSystems = JSONArray()
    for (index in 0 until minOf(systems.length(), 2)) {
        val source = systems.optJSONObject(index) ?: continue
        compactSystems.put(JSONObject()
            .put("id", source.optString("id"))
            .put("label", source.optString("label"))
            .put("hitCount", source.optInt("hitCount"))
            .put("uniqueKeywordCount", source.optInt("uniqueKeywordCount"))
            .put("evidenceScore", source.optInt("evidenceScore"))
            .put("matchedKeywords", blutterJsonArrayTake(source.optJSONArray("matchedKeywords") ?: JSONArray(), 12))
            .put("samples", blutterJsonArrayTake(source.optJSONArray("samples") ?: JSONArray(), 3)))
    }
    return JSONObject()
        .put("scannedLines", profile.optLong("scannedLines"))
        .put("classificationStatus", profile.optString("classificationStatus", "not_found"))
        .put("ambiguous", profile.optBoolean("ambiguous"))
        .put("selectedSystem", compactSystems.optJSONObject(0) ?: JSONObject.NULL)
        .put("systems", compactSystems)
}

internal fun blutterBuildAnalysisReport(payload: JSONObject): JSONObject {
    val classification = payload.optString("classificationStatus", "not_found")
    val candidates = payload.optJSONArray("patchCandidates") ?: JSONArray()
    val windows = payload.optJSONArray("verificationWindows") ?: JSONArray()
    val status = when {
        classification == "ambiguous" -> "ambiguous"
        classification == "clues_only" -> "clues_only"
        classification != "clear" -> "not_found"
        candidates.length() > 0 -> "candidates_need_verification"
        windows.length() > 0 -> "references_need_verification"
        else -> "system_identified_no_function"
    }
    val selected = payload.optJSONObject("intentProfile")?.optJSONObject("selectedSystem")
    return JSONObject()
        .put("reportVersion", 1)
        .put("reportType", "${payload.optString("intentDomain", "business")}_analysis")
        .put("generatedAt", System.currentTimeMillis())
        .put("jobId", payload.optString("jobId"))
        .put("goal", payload.optString("goal"))
        .put("status", status)
        .put("system", selected ?: JSONObject.NULL)
        .put("classificationStatus", classification)
        .put("ppSummary", payload.optJSONObject("ppSummary") ?: JSONObject())
        .put("matchedContent", blutterJsonArrayTake(payload.optJSONArray("poolMatches") ?: JSONArray(), 12))
        .put("patchCandidates", blutterJsonArrayTake(candidates, 5))
        .put("verificationWindows", blutterJsonArrayTake(windows, 5))
        .put("clueCandidates", blutterJsonArrayTake(payload.optJSONArray("clueCandidates") ?: JSONArray(), 3))
        .put("readyForVerification", payload.optBoolean("readyForVerification"))
        .put("readyForPatch", false)
        .put("conclusion", when (status) {
            "candidates_need_verification" -> "已识别业务体系并定位候选函数；必须核对同一函数内的状态字段、比较值和返回值后再修改。"
            "references_need_verification" -> "已识别业务体系和字符串引用现场；函数边界不完整，需从 verificationVa 核对原生反汇编。"
            "system_identified_no_function" -> "已识别业务体系，但当前静态证据没有收敛到真实判定函数，不能修改。"
            "ambiguous" -> "存在多个业务体系，当前证据不足以选定真实状态来源，不能修改。"
            "clues_only" -> "当前只有展示、网络栈或 SDK 线索，没有真实业务判定证据。"
            else -> "未识别到目标业务体系。"
        })
        .put("nextStep", payload.optString("nextStep"))
}

private fun blutterStructuralFeatureTerm(term: String): Boolean {
    if (term.isBlank() || term.any { it.code > 0x7f }) return false
    val lower = term.lowercase()
    return listOf(
        "vip", "member", "premium", "pro", "level", "tier", "type", "status", "expire", "valid",
        "subscription", "entitle", "privilege", "proxy", "vpn", "certificate", "pinning", "trust",
        "adfree", "showad", "canshowad", "shouldshowad", "needshowad", "adready",
        "splashad", "rewarded", "interstitial", "bannerad", "nativead", "feedad",
        "adsdk", "initad", "adconfig", "adview", "adcontainer",
    ).any(lower::contains)
}

internal fun blutterCluesOnlySystem(systemId: String): Boolean =
    systemId in setOf("presentation_only", "network_stack", "ad_ui_container")

private fun blutterSemanticHints(domain: String, systemIds: List<String>): List<String> = when {
    "tier_level" in systemIds -> listOf("vipType", "vipLevel", "memberType", "memberLevel", "userLevel", "level", "tier", "type", "privilege")
    "state_boolean" in systemIds -> listOf("isVip", "hasVip", "isMember", "isPremium", "entitled", "unlocked", "active", "status", "enabled")
    "pro_paid_unlock" in systemIds -> listOf("isPro", "proUser", "premium", "paid", "license", "purchased", "unlocked", "fullVersion")
    "expiry_lifetime" in systemIds -> listOf("expire", "expiry", "expiration", "validUntil", "endTime", "remaining", "deadline", "lifetime")
    "subscription_purchase" in systemIds -> listOf("subscription", "subscribe", "renew", "billing", "receipt", "purchase", "productId", "planId")
    domain == "capture" -> listOf("proxy", "vpn", "certificate", "pinning", "trust", "verify", "hostname", "security")
    "ad_display_trigger" in systemIds -> listOf(
        "isAdEnabled", "shouldShowAd", "canShowAd", "needShowAd", "showAd",
        "showSplashAd", "showInterstitialAd", "showRewardedAd", "showBannerAd",
        "showNativeAd", "showFeedAd", "loadAndShowAd", "playAd", "displayAd",
    )
    else -> emptyList()
}

internal fun blutterDirectCandidateScore(
    domain: String,
    systemIds: List<String>,
    functionName: String,
    matchedTerms: List<String>,
): Int {
    val lower = functionName.lowercase()
    val nameScore = if (blutterSemanticHints(domain, systemIds).any { lower.contains(it.lowercase()) }) 100 else 0
    val evidenceScore = if (matchedTerms.any(::blutterStructuralFeatureTerm)) 60 else 0
    val returnScore = when {
        "tier_level" in systemIds -> when {
            lower.startsWith("int ") -> 50
            lower.startsWith("string ") || lower.startsWith("bool ") -> 30
            lower.contains(" void ") || lower.startsWith("void ") -> -100
            else -> 0
        }
        "state_boolean" in systemIds || "pro_paid_unlock" in systemIds -> when {
            lower.startsWith("bool ") -> 50
            lower.startsWith("int ") -> 20
            lower.contains(" void ") || lower.startsWith("void ") -> -100
            else -> 0
        }
        "expiry_lifetime" in systemIds -> when {
            lower.startsWith("int ") || lower.startsWith("datetime ") -> 50
            lower.startsWith("string ") -> 20
            lower.contains(" void ") || lower.startsWith("void ") -> -100
            else -> 0
        }
        domain == "capture" -> when {
            lower.startsWith("bool ") -> 50
            lower.startsWith("int ") -> 20
            lower.contains(" void ") || lower.startsWith("void ") -> -80
            else -> 0
        }
        "ad_display_trigger" in systemIds -> when {
            lower.startsWith("bool ") -> 50
            lower.startsWith("int ") -> 20
            lower.contains(" void ") || lower.startsWith("void ") -> 30
            else -> 10
        }
        domain == "ads" -> if (lower.contains(" void ") || lower.startsWith("void ")) 10 else 0
        else -> if (lower.contains(" void ") || lower.startsWith("void ")) -40 else 10
    }
    return nameScore + evidenceScore + returnScore
}

internal fun blutterDirectCandidateEligible(score: Int): Boolean = score >= 100

internal fun blutterParserLikeFunction(functionName: String): Boolean {
    val lower = functionName.lowercase()
    return lower.contains("fromjson") || lower.contains("tojson") ||
        lower.contains("from_json") || lower.contains("to_json") ||
        lower.contains("deserialize") || lower.contains("serialize") ||
        lower.contains("jsondecode") || lower.contains("jsonencode")
}

internal fun blutterSourceOwnershipScore(file: String, firstPartyRoots: Set<String>): Int {
    if (firstPartyRoots.isEmpty()) return 0
    val root = file.replace('\\', '/').removePrefix("asm/").substringBefore('/')
    return if (root in firstPartyRoots) 100 else -80
}

internal fun blutterVerificationWindow(functionVa: Long, referenceVas: List<Long>): Pair<Long, Int> {
    val sorted = referenceVas.sorted()
    val start = sorted.firstOrNull()?.let { maxOf(functionVa, it - 0x100L) } ?: functionVa
    val end = sorted.lastOrNull()?.plus(0x100L) ?: (start + 0x400L)
    return start to (end - start).coerceIn(0x100L, 0x4000L).toInt()
}

internal fun parseBlutterValues(raw: String): List<Long> = raw
    .split(Regex("[,;/\\s]+"))
    .map { it.trim().removePrefix("#").lowercase() }
    .filter(String::isNotBlank)
    .mapNotNull { token ->
        when {
            token.startsWith("-0x") -> token.removePrefix("-0x").toLongOrNull(16)?.let { -it }
            token.startsWith("0x") -> token.removePrefix("0x").toLongOrNull(16)
            else -> token.toLongOrNull()
        }
    }
    .distinct()

internal fun parseBlutterPoolOffsets(raw: String): List<Long> = raw
    .split(Regex("[|,;\\s]+"))
    .map { it.trim().removePrefix("pp+").removePrefix("0x").removePrefix("0X") }
    .filter(String::isNotBlank)
    .mapNotNull { it.toLongOrNull(16) }
    .distinct()

internal fun blutterReferenceAnchors(refsByOffset: JSONObject): Map<Long, List<Long>> {
    val anchors = linkedMapOf<Long, LinkedHashSet<Long>>()
    refsByOffset.keys().forEach { offset ->
        val rows = refsByOffset.optJSONArray(offset) ?: return@forEach
        (0 until rows.length()).mapNotNull(rows::optJSONObject).forEach { row ->
            val functionVa = row.optString("functionVa").removePrefix("0x").toLongOrNull(16) ?: return@forEach
            val referenceVa = row.optString("va").removePrefix("0x").toLongOrNull(16) ?: return@forEach
            anchors.getOrPut(functionVa) { linkedSetOf() }.add(referenceVa)
        }
    }
    return anchors.mapValues { it.value.toList().sorted() }
}

internal fun extractBlutterGoalValues(goal: String): List<Long> =
    Regex("(?<![A-Za-z0-9_.])#?(?:0[xX][0-9a-fA-F]+|[0-9]+)(?![A-Za-z0-9_.])")
        .findAll(goal)
        .mapNotNull { match -> parseBlutterValues(match.value).singleOrNull() }
        .filter { it in 0..0xffff }
        .distinct()
        .take(8)
        .toList()

private fun blutterGoalHints(goal: String): List<String> =
    Regex("[A-Za-z0-9_%:-]+\\.dart", RegexOption.IGNORE_CASE)
        .findAll(goal)
        .map { it.value }
        .distinctBy(String::lowercase)
        .take(8)
        .toList()

internal fun blutterIntentDomain(goal: String): String {
    val lower = goal.lowercase()
    return when {
        listOf("抓包", "代理", "证书", "中间人", "vpn", "proxy", "pinning", "mitm", "ssl", "tls", "certificate", "trustmanager").any(lower::contains) -> "capture"
        listOf(
            "广告", "开屏", "激励", "插屏", "横幅", "信息流", "原生广告", "激励视频",
            "ad", "ads", "advert", "splash", "splash ad", "rewarded", "reward video",
            "interstitial", "banner", "banner ad", "native ad",
        ).any { term ->
            if (term.length <= 3 && term.all(Char::isLetter)) Regex("(^|[^a-z])${Regex.escape(term)}([^a-z]|$)").containsMatchIn(lower) else lower.contains(term)
        } -> "ads"
        listOf("会员", "权益", "订阅", "到期", "过期", "永久", "高级版", "专业版", "付费版", "完整版", "vip", "svip", "vvip", "premium", "membership", "member", "subscription", "subscribe", "entitlement", "pro", "paid", "lifetime", "expiry", "expire").any { term ->
            if (term.length <= 3 && term.all(Char::isLetter)) Regex("(^|[^a-z])${Regex.escape(term)}([^a-z]|$)").containsMatchIn(lower) else lower.contains(term)
        } -> "membership"
        else -> "generic"
    }
}

internal fun blutterIntentGroups(domain: String): List<PpFeatureGroup> = when (domain) {
    "membership" -> listOf(
        PpFeatureGroup("state_boolean", "布尔会员/权益状态", listOf(
            "isVip", "is_vip", "hasVip", "has_vip", "vipEnabled", "vip_enabled", "vipActive", "vip_active",
            "checkVip", "checkVipStatus", "getVipStatus", "getVipFlag", "isVipUser", "isVipMember", "getisVip",
            "isMember", "is_member", "memberEnabled", "member_active", "isPremium", "is_premium", "premiumEnabled",
            "isSubscribed", "is_subscribed", "hasSubscription", "has_subscription", "isEntitled", "entitled",
            "hasEntitlement", "getEntitlementStatus", "isActivated", "hasActivated", "isUnlocked", "hasUnlocked",
            "unlocked", "adFree", "ad_free", "会员状态", "是否会员", "已开通会员", "会员已激活", "权益已解锁",
        ), 140),
        PpFeatureGroup("tier_level", "等级/类型会员体系", listOf(
            "vipType", "vip_type", "vipLevel", "vip_level", "memberType", "member_type", "memberLevel", "member_level",
            "userLevel", "user_level", "membershipTier", "membership_tier", "subscriptionTier", "tierId", "tier_id",
            "getVipType", "getVipLevel", "getProLevel", "isGoldenVip", "isPlatinumVip", "isDiamondVip", "isSuperVip",
            "isUltimateVip", "svip", "vvip", "supreme", "diamond", "platinum", "gold", "silver", "bronze",
            "会员类型", "会员等级", "用户等级", "权益等级", "普通会员", "高级会员", "超级会员", "至尊会员", "钻石会员", "黄金会员", "白银会员",
            "至尊永久VIP", "钻石永久VIP", "永久VIP",
        ), 135),
        PpFeatureGroup("pro_paid_unlock", "Pro/付费解锁体系", listOf(
            "isPro", "is_pro", "proUser", "pro_user", "proEnabled", "pro_enabled", "proVersion", "pro_version",
            "isProUser", "isProMember", "getProStatus", "isProfessional", "isAdvanced", "isProVersion", "isProActivated",
            "isProUnlocked", "upgradeToPro", "unlockPro", "isPlus", "isPlusUser", "isPlusMember", "premiumUser",
            "premium_user", "paidUser", "paid_user", "fullVersion", "full_version", "isFullVersion", "isPaidVersion",
            "isPurchased", "purchased", "licensed", "licenseValid", "isLicenseValid", "unlockAll", "unlock_all",
            "专业版", "高级版", "付费版", "完整版", "增强版", "已购买", "永久解锁", "解锁全部", "升级Pro",
        ), 130),
        PpFeatureGroup("expiry_lifetime", "到期时间/永久会员体系", listOf(
            "expireTime", "expire_time", "expiryTime", "expiry_time", "expirationTime", "expiration_time",
            "getExpiredTime", "getExpireTime", "getVipExpire", "getVipExpireTime", "getMemberExpireTime", "getExpirationTime",
            "getSubscriptionEndTime", "getTrialEndTime", "getRemainingTime", "getTimeRemaining", "getRemainingDays",
            "expiredAt", "expiresAt", "validUntil", "getValidUntil", "valid_until", "endTime", "end_time", "dueDate",
            "deadline", "getDeadline", "remainingDays", "expireTimestamp", "getExpireTimestamp", "nextBillingTime",
            "lifetime", "permanent", "forever", "neverExpire", "never_expire", "会员到期", "到期时间", "有效期",
            "剩余时间", "剩余天数", "永久会员", "永久有效", "永不过期",
        ), 125),
        PpFeatureGroup("subscription_purchase", "订阅/购买体系", listOf(
            "subscription", "subscriptionStatus", "subscription_status", "subscribe", "subscribed", "renew", "renewal",
            "getSubscriptionStatus", "isActiveSubscription", "hasActiveSubscription", "isAutoRenewing", "isTrial", "isTrialUser",
            "isFreeTrial", "verifyPurchase", "validatePurchase", "checkReceipt", "verifyReceipt", "billing", "receipt",
            "purchase", "purchaseStatus", "getPurchaseStatus", "productId", "product_id", "sku", "paywall", "planId", "plan_id",
            "订单", "订阅状态", "已订阅", "自动续费", "免费试用", "恢复购买", "购买会员", "开通会员", "续费", "支付", "付款",
        ), 105),
        PpFeatureGroup("presentation_only", "会员展示/UI 文案", listOf(
            "vipBadge", "vip_badge", "memberBadge", "member_badge", "vipIcon", "vip_icon", "memberIcon", "member_icon",
            "vipLabel", "vip_label", "memberCenter", "member_center", "displayEffect", "display_effect", "badgeEffect",
            "会员中心", "会员徽章", "会员图标", "展示效果", "会员文案", "升级提示",
        ), 35),
    )
    "capture" -> listOf(
        PpFeatureGroup("proxy_vpn_detection", "代理/VPN 检测", listOf(
            "isVpn", "is_vpn", "vpnActive", "vpn_active", "vpnConnected", "vpn_connected", "isProxy", "is_proxy",
            "checkVpn", "checkProxy", "detectVpn", "detectProxy", "proxyEnabled", "proxy_enabled", "httpProxy", "http_proxy",
            "httpsProxy", "https_proxy", "socksProxy", "socks_proxy", "ProxySelector", "NetworkInterface",
            "NetworkCapabilities", "TRANSPORT_VPN", "tun0", "ppp0", "代理检测", "VPN检测", "检测到代理", "检测到VPN", "抓包检测", "抓包环境",
        ), 140),
        PpFeatureGroup("tls_pinning", "TLS/证书固定", listOf(
            "CertificatePinner", "certificatePinning", "certificate_pinning", "sslPinning", "ssl_pinning", "publicKeyPin",
            "pin-sha256", "sha256/", "checkServerTrusted", "verifyCertificate", "verifyHostname", "HostnameVerifier",
            "certificateVerifyFailed", "CERTIFICATE_VERIFY_FAILED", "证书固定", "证书锁定", "证书校验", "证书验证失败",
            "公钥校验", "SSL校验", "TLS校验", "中间人检测",
        ), 140),
        PpFeatureGroup("certificate_trust", "证书/信任链", listOf(
            "X509Certificate", "X509TrustManager", "TrustManager", "TrustManagerFactory", "trustedCertificates",
            "SecurityContext", "badCertificateCallback", "onBadCertificate", "handshakeException", "CERTIFICATE_VERIFY_FAILED",
            "证书", "信任证书", "信任链", "根证书", "客户端证书", "握手失败",
        ), 125),
        PpFeatureGroup("network_stack", "网络栈线索", listOf(
            "OkHttpClient", "Dio", "HttpClient", "WebView", "Cronet", "retrofit", "interceptor", "networkSecurityConfig",
            "网络请求", "请求拦截器", "网络安全配置", "代理服务器",
        ), 45),
    )
    "ads" -> listOf(
        PpFeatureGroup("ad_sdk_init", "广告 SDK 初始化", listOf(
            "Pangle", "PangleSdk", "TTAdSdk", "GDTSDK", "GDTAdSdk", "AdSdk", "AdManager", "MobAds", "AdMob",
            "MobileAds", "UnityAds", "Mintegral", "Vungle", "IronSource", "InMobi", "AppLovin",
            "initAd", "initAds", "initAdSdk", "adSdkInit", "sdkInit", "穿山甲", "优量汇", "广点通", "快手联盟", "百度联盟", "广告初始化", "广告SDK",
        ), 140),
        PpFeatureGroup("ad_display_trigger", "广告展示触发", listOf(
            "showAd", "show_ad", "showSplashAd", "showInterstitialAd", "showRewardAd", "showBannerAd",
            "showRewardedAd", "showNativeAd", "showFeedAd", "loadAndShowAd", "displayAd", "playAd", "presentAd",
            "isAdReady", "canShowAd", "shouldShowAd",
            "isAdEnabled", "is_ad_enabled", "adSwitch", "ad_switch", "needShowAd", "loadInterstitial",
            "loadRewardedVideo", "requestBannerAd", "loadNativeAd", "loadFeedAd", "isAdFree", "adFree", "noAds", "isNoAds",
            "显示广告", "播放广告", "是否展示广告", "广告开关", "插屏展示", "开屏展示", "信息流广告", "原生广告", "激励视频",
        ), 135),
        PpFeatureGroup("ad_remote_config", "广告配置/远程开关", listOf(
            "adConfig", "ad_config", "remoteAdSwitch", "adFrequency", "ad_frequency", "adInterval", "maxAdCount",
            "adPlacement", "ad_placement", "adUnitId", "ad_unit_id", "placementId", "广告配置", "广告频率", "广告位", "广告开关配置",
        ), 120),
        PpFeatureGroup("ad_ui_container", "广告容器/UI", listOf(
            "AdBannerView", "AdContainer", "adView", "ad_view", "adLayout", "ad_layout", "广告容器", "广告位UI", "广告图片",
        ), 35),
    )
    else -> emptyList()
}

internal fun blutterMembershipGoal(goal: String): Boolean {
    val lower = goal.lowercase()
    return listOf(
        "会员", "vip", "svip", "premium", "订阅", "至尊", "钻石", "黄金", "白银",
        "等级", "权益", "永久", "到期", "过期", "expire", "tier", "level",
    ).any(lower::contains)
}

internal fun blutterPrimaryKeywords(goal: String): List<String> {
    val normalizedGoal = goal.trim()
    if (normalizedGoal.isEmpty()) return emptyList()
    val lower = normalizedGoal.lowercase()
    val terms = linkedSetOf(normalizedGoal)
    listOf(
        "至尊永久VIP", "钻石永久VIP", "普通VIP", "普通会员", "永久会员", "会员等级", "会员类型",
        "至尊", "钻石", "黄金", "白银", "会员", "vip", "svip", "premium", "订阅", "到期", "过期",
        "广告", "开屏", "激励", "横幅", "插屏", "代理", "vpn", "证书", "抓包",
    ).forEach { term -> if (lower.contains(term.lowercase())) terms += term }
    return terms.toList()
}

internal fun blutterLocateKeywords(goal: String): List<String> {
    val normalizedGoal = goal.trim()
    val lower = normalizedGoal.lowercase()
    val terms = linkedSetOf<String>()
    // 用户明确输入永远排第一，不能被领域词表和数量上限挤掉。
    if (normalizedGoal.isNotEmpty()) terms += normalizedGoal
    if (blutterMembershipGoal(normalizedGoal)) {
        listOf("至尊永久VIP", "钻石永久VIP", "至尊", "钻石", "黄金", "白银").forEach { tier ->
            if (lower.contains(tier.lowercase())) terms += tier
        }
        terms += listOf(
            "vipType", "vip_type", "vipLevel", "vip_level", "userLevel", "user_level",
            "memberType", "member_type", "memberLevel", "member_level", "isVip", "is_vip",
            "isSvip", "is_svip", "hasVip", "has_vip", "vip", "svip", "member", "membership",
            "premium", "subscription", "entitlement", "privilege", "benefit", "会员", "会员等级",
            "会员类型", "VIP等级", "普通会员", "普通VIP", "永久会员", "到期", "过期", "有效期",
        )
    }
    if (lower.contains("抓包") || lower.contains("代理") || lower.contains("vpn") || lower.contains("tun") || lower.contains("证书")) {
        terms += listOf("抓包", "代理", "vpn", "tun", "隧道", "证书", "校验", "网络", "proxy", "http_proxy", "https_proxy", "socks", "certificate", "trust", "pinning", "mitm", "ssl", "tls", "okhttp", "webview", "network", "security")
    }
    if (lower.contains("广告") || lower.contains("开屏") || Regex("\\bad\\b").containsMatchIn(lower)) {
        terms += listOf(
            "广告", "开屏", "激励", "横幅", "插屏", "splash", "reward", "interstitial", "banner", "nativead", "ad",
            "showAd", "showInterstitialAd", "showRewardAd", "showSplashAd", "shouldShowAd", "isAdEnabled", "canShowAd",
        )
    }
    return terms.take(32)
}
