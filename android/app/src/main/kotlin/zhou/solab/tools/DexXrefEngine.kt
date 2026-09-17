package zhou.solab.tools

import android.content.Context
import com.android.tools.smali.dexlib2.iface.ClassDef
import com.android.tools.smali.dexlib2.iface.Method
import com.android.tools.smali.dexlib2.iface.instruction.Instruction
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction
import com.android.tools.smali.dexlib2.iface.reference.FieldReference
import com.android.tools.smali.dexlib2.iface.reference.MethodReference
import com.android.tools.smali.dexlib2.iface.reference.Reference
import org.json.JSONArray
import org.json.JSONObject
import zhou.solab.engine.FieldRefsIndexStore
import java.io.File

/**
 * M2: DEX 调用图引擎（自研，替代 mt_apk_dex_xref）。
 *
 * 单遍索引：遍历全部 classes*.dex 的每个方法，收集 invoke 指令的
 * MethodReference 建正向边表（caller → target）；查询时：
 *  - callees：直接查边表
 *  - callers：全表扫描反向匹配（O(边数)）
 *  - dispatchCandidates：命中 target 的 invoke-virtual 调用点
 *    （虚拟分派噪声，单独列出不混入 directCallers）
 *
 * 缓存与分页契约（2026-08-28 重设计，取代"物化列表封顶"方案）：
 *  - 快照缓存完整结果（compact 行，\u0001 分隔），翻页只为请求切片物化
 *    JSON——任何 offset 都能到达真实数据，不存在"封顶后看不见的尾部"。
 *  - 缓存按条数 + 总字符预算驱逐；单条快照超预算时跳过缓存（翻页重算），
 *    保证预算是硬上界。
 *  - 真实总数保留在 summary（totalCallers/totalCallSites/totalRefs），
 *    truncated 标记=是否还有下一页（可达），不是"数据被丢弃"。
 */
object DexXrefEngine {

    private const val MAX_APK_BYTES = 512L * 1024 * 1024
    private const val MAX_CALL_SITES = 300
    private const val MAX_GRAPH_NODES = 200
    private const val XREF_CACHE_MAX = 64

    /** 缓存总字符预算（≈16MB 堆，UTF-16）：单条超预算的快照不缓存，翻页时重算。 */
    private const val XREF_CACHE_MAX_CHARS = 8_000_000L
    private var xrefCacheChars = 0L
    private val xrefCache = LinkedHashMap<String, XrefSnapshot>(
        XREF_CACHE_MAX,
        0.75f,
        true,
    )

    /**
     * 查询结果快照：行为紧凑字符串（\u0001 分隔字段），翻页时按切片物化。
     * 行格式：
     *  - directCallers/callees: qualifiedId \u0001 dexFile \u0001 callSiteCount
     *  - dispatchCandidates:    qualifiedId \u0001 callSiteCount
     *  - callSites:             caller \u0001 instructionIndex \u0001 opcode \u0001 dispatch \u0001 dexFile
     *  - fieldRefs:             field \u0001 method \u0001 relation \u0001 accessKind \u0001 opcode \u0001 instructionIndex \u0001 dexId \u0001 dexFile
     */
    internal class XrefSnapshot(
        val directCallers: List<String> = emptyList(),
        val dispatchCandidates: List<String> = emptyList(),
        val callees: List<String> = emptyList(),
        val callSites: List<String> = emptyList(),
        val fieldRefs: List<String> = emptyList(),
        val summary: JSONObject = JSONObject(),
        val flowGraph: String? = null,
    ) {
        val sizeChars: Long by lazy {
            (directCallers.sumOf { it.length } +
                dispatchCandidates.sumOf { it.length } +
                callees.sumOf { it.length } +
                callSites.sumOf { it.length } +
                fieldRefs.sumOf { it.length } +
                summary.length() +
                (flowGraph?.length ?: 0)
            ).toLong()
        }
    }

    /** 写入缓存并按条数+字符预算驱逐；单条超预算的快照直接跳过（翻页重算）。 */
    private fun cachePut(key: String, snapshot: XrefSnapshot) {
        synchronized(xrefCache) {
            if (snapshot.sizeChars > XREF_CACHE_MAX_CHARS) return
            val previous = xrefCache.put(key, snapshot)
            xrefCacheChars += snapshot.sizeChars - (previous?.sizeChars ?: 0L)
            while ((xrefCache.size > XREF_CACHE_MAX || xrefCacheChars > XREF_CACHE_MAX_CHARS) &&
                xrefCache.size > 1
            ) {
                val eldest = xrefCache.entries.iterator()
                xrefCacheChars -= eldest.next().value.sizeChars
                eldest.remove()
            }
        }
    }

    /** 规范化 qualifiedId：Lpkg/Class;->name(params)ret */
    private fun qidOf(m: MethodReference): String =
        "${m.definingClass}->${m.name}(${m.parameterTypes.joinToString("")})${m.returnType}"

    private fun qidOf(m: Method): String =
        "${m.definingClass}->${m.name}(${m.parameterTypes.joinToString("")})${m.returnType}"

    /** 无签名目标（Lpkg/Class;->name）是否命中某 qualifiedId */
    internal fun matchesNoSignature(target: String, qid: String): Boolean =
        qid.startsWith(target) && qid.getOrNull(target.length) == '('

    /** 字段引用紧凑行（8 段 \u0001 分隔）：全量扫描与 SQLite 索引共用，
     *  保证两路产出行格式完全同构，fieldRowJson/fieldPage 直接复用。 */
    internal fun fieldRefRow(
        fieldQid: String,
        methodQid: String,
        relation: String,
        accessKind: String,
        opcode: String,
        insnIndex: Int,
        dexId: Int,
        dexFile: String,
    ): String = listOf(
        fieldQid,
        methodQid,
        relation,
        accessKind,
        opcode,
        insnIndex.toString(),
        dexId.toString(),
        dexFile,
    ).joinToString("\u0001")

    // APK 内容 sha256 进程内缓存（键含 mtime+size，补丁改写自动换新）。
    // 覆盖全部重扫路径的哈希成本会抵消索引收益，必须缓存。
    private val apkShaCache = java.util.concurrent.ConcurrentHashMap<String, String>()

    private fun apkSha256Of(apk: File): String {
        val key = "${apk.canonicalPath}|${apk.lastModified()}|${apk.length()}"
        return synchronized(apkShaCache) {
            apkShaCache.getOrPut(key) { zhou.solab.sha256(apk) }
        }
    }

    fun xref(
        context: Context,
        apkPath: String,
        target: String,
        direction: String = "to",
        callerPrefix: String = "",
        offset: Int = 0,
        limit: Int = 50,
        includeGraph: Boolean = false,
        callSiteOffset: Int = 0,
        callSiteLimit: Int = MAX_CALL_SITES,
    ): JSONObject {
        val apk = File(apkPath)
        if (!apk.isFile) return err("FILE_NOT_FOUND", "APK 不存在: $apkPath", "apkPath", apkPath)
        if (apk.length() > MAX_APK_BYTES) return err("APK_LIMIT_EXCEEDED", "APK 超过 512MiB 上限", "apkPath", apkPath)
        if (target.isBlank()) return err("INVALID_ARGUMENT", "缺少 target(qualifiedId)", "target", "")
        if (direction !in setOf("to", "from", "both", "overrides")) {
            return err("INVALID_ARGUMENT", "direction 必须是 to/from/both/overrides", "direction", direction)
        }
        if (direction == "overrides") return overrides(context, apk, target, limit, includeGraph)

        val normTarget = target.trim()
        val wantSignature = normTarget.contains('(')
        // 缓存键不含分页参数：缓存完整快照，翻页在快照上切片。
        val cacheKey = listOf(
            apk.canonicalPath,
            apk.length(),
            apk.lastModified(),
            normTarget,
            direction,
            callerPrefix,
            includeGraph,
        ).joinToString("|")
        synchronized(xrefCache) {
            xrefCache[cacheKey]?.let { cached ->
                return xrefPage(cached, normTarget, direction, offset, limit, callSiteOffset, callSiteLimit)
                    .put("cache", "hit")
            }
        }

        return runCatching {
            // 只聚合当前目标的结果，不再构建整包调用图。全图会为数十万方法
            // 分配大量临时边表；同样的单遍扫描下，这里显著降低内存和 GC 压力。
            val dexOf = HashMap<String, String>() // qualifiedId → dex 文件名
            val callerCounts = HashMap<String, Int>()
            val virtualCallerCounts = HashMap<String, Int>()
            val calleeCounts = HashMap<String, Int>()
            var dexCount = 0
            var scannedMethods = 0
            var targetSeen = false
            var totalCallSites = 0
            val callSiteRows = mutableListOf<String>()

            fun hit(qid: String): Boolean =
                if (wantSignature) qid == normTarget else matchesNoSignature(normTarget, qid)

            DexIo.eachDex(context, apk) { dexName, dexFile ->
                dexCount++
                for (cls: ClassDef in dexFile.classes) {
                    for (m: Method in cls.methods) {
                        val callerQId = qidOf(m)
                        val callerIsTarget = hit(callerQId)
                        if (callerIsTarget) {
                            targetSeen = true
                            dexOf.putIfAbsent(callerQId, dexName)
                        }
                        scannedMethods++
                        val impl = m.implementation ?: continue
                        for ((instructionIndex, insn) in impl.instructions.withIndex()) {
                            if (insn !is ReferenceInstruction) continue
                            val ref: Reference = insn.reference
                            if (ref !is MethodReference) continue
                            val targetQId = qidOf(ref)
                            if ((direction == "from" || direction == "both") && callerIsTarget) {
                                calleeCounts.merge(targetQId, 1) { a, b -> a + b }
                                dexOf.putIfAbsent(targetQId, dexName)
                            }
                            if ((direction == "to" || direction == "both") && hit(targetQId)) {
                                targetSeen = true
                                dexOf.putIfAbsent(targetQId, dexName)
                                if (callerPrefix.isEmpty() || callerQId.startsWith(callerPrefix)) {
                                    val virtualDispatch = insn.opcode.name.startsWith("INVOKE_VIRTUAL") ||
                                        insn.opcode.name.startsWith("INVOKE_INTERFACE")
                                    val counts = if (virtualDispatch) {
                                        virtualCallerCounts
                                    } else {
                                        callerCounts
                                    }
                                    counts.merge(callerQId, 1) { a, b -> a + b }
                                    dexOf.putIfAbsent(callerQId, dexName)
                                    totalCallSites++
                                    callSiteRows.add(
                                        listOf(
                                            callerQId,
                                            instructionIndex.toString(),
                                            insn.opcode.name,
                                            if (virtualDispatch) "virtual" else "direct",
                                            dexName,
                                        ).joinToString("\u0001")
                                    )
                                }
                            }
                        }
                    }
                }
            }

            // ===== 查询阶段（全量快照，分页在 xrefPage 切片）=====
            // targetSeen 在定义扫描与调用引用两处置位；全方向校验：
            // 把「target 不存在」（TARGET_NOT_FOUND，换定位方式）与
            // 「存在但无直接调用方」（空列表，可能是回调/反射/间接调用）
            // 区分开，原先 to 方向两者都返回空列表，模型无从分辨。
            if (!targetSeen) {
                return@runCatching err(
                    "TARGET_NOT_FOUND",
                    "未在 DEX 中找到目标方法: $normTarget（定义与调用引用均不存在）。" +
                        "用 class_outline 或 dex_search 拿到准确 qualifiedId 后重试，不要换参数硬试",
                    "target",
                    normTarget,
                )
            }
            val callerRows = callerCounts.entries.sortedBy { it.key }
                .map { listOf(it.key, dexOf[it.key] ?: "", it.value.toString()).joinToString("\u0001") }
            val dispatchRows = virtualCallerCounts.entries.sortedBy { it.key }
                .map { listOf(it.key, it.value.toString()).joinToString("\u0001") }
            val calleeRows = calleeCounts.entries.sortedBy { it.key }
                .map { listOf(it.key, dexOf[it.key] ?: "", it.value.toString()).joinToString("\u0001") }
            val summary = JSONObject()
                .put("totalCallers", callerRows.size)
                .put("totalCallees", calleeRows.size)
                .put("totalCallSites", totalCallSites)
                .put("dexCount", dexCount)
                .put("scannedMethods", scannedMethods)
            val flowGraphJson = if (includeGraph) {
                // 图有 MAX_GRAPH_NODES 硬顶：喂入每侧前 200 行即可覆盖全部可达节点
                buildCallGraph(
                    normTarget,
                    materializeCallerRows(callerRows.take(MAX_GRAPH_NODES)),
                    materializeDispatchRows(dispatchRows.take(MAX_GRAPH_NODES)),
                    materializeCalleeRows(calleeRows.take(MAX_GRAPH_NODES)),
                ).toString()
            } else {
                null
            }
            val snapshot = XrefSnapshot(
                directCallers = callerRows,
                dispatchCandidates = dispatchRows,
                callees = calleeRows,
                callSites = callSiteRows,
                summary = summary,
                flowGraph = flowGraphJson,
            )
            cachePut(cacheKey, snapshot)
            xrefPage(snapshot, normTarget, direction, offset, limit, callSiteOffset, callSiteLimit)
        }.getOrElse { e ->
            err("XREF_INDEX_FAILED", "DEX 调用图构建失败: ${e.message ?: e.javaClass.simpleName}", "apkPath", apkPath)
        }
    }

    /** 全量快照 → 分页响应：directCallers/callSites 切片，dispatch/callees 全量物化。 */
    internal fun xrefPage(
        snapshot: XrefSnapshot,
        target: String,
        direction: String,
        offset: Int,
        limit: Int,
        callSiteOffset: Int = 0,
        callSiteLimit: Int = MAX_CALL_SITES,
    ): JSONObject {
        val callers = snapshot.directCallers
        val safeOffset = offset.coerceAtLeast(0)
        val safeLimit = limit.coerceAtLeast(1)
        // truncated = 是否还有可翻页的数据；真实总数在 summary.totalCallers。
        val truncated = safeOffset + safeLimit < callers.size
        val sites = snapshot.callSites
        val safeCsOffset = callSiteOffset.coerceAtLeast(0)
        val safeCsLimit = callSiteLimit.coerceIn(1, 5000)
        val csTruncated = safeCsOffset + safeCsLimit < sites.size
        val response = ok(JSONObject()
            .put("tool", "dex_xref")
            .put("target", target)
            .put("direction", direction)
            .put("directCallers", materializeCallerRows(snapSlice(callers, safeOffset, safeLimit)))
            .put("dispatchCandidates", materializeDispatchRows(snapshot.dispatchCandidates))
            .put("callees", materializeCalleeRows(snapshot.callees))
            .put("callSites", materializeCallSiteRows(target, snapSlice(sites, safeCsOffset, safeCsLimit)))
            .put("callSitesTruncated", csTruncated)
            .put("callSitesNextCursor", if (csTruncated) "${safeCsOffset + safeCsLimit}" else "")
            .put("truncated", truncated)
            .put("nextCursor", if (truncated) "${safeOffset + safeLimit}" else "")
            .put("summary", snapshot.summary)
            .put("hint", "directCallers 为精确调用点; dispatchCandidates 为 invoke-virtual 调用点(实际执行可能经子类分派,需结合 class_outline 确认)。target 存在而 callers 为空: 可能确实无直接调用方(回调注册/反射/反射式间接调用对静态扫描不可见),不要当作定位失败反复重试。全部列表都可分页到达: 翻页用 offset/limit,深读 callSites 用 callSiteOffset/callSiteLimit"))
        snapshot.flowGraph?.let { response.put("flowGraph", JSONObject(it)) }
        return response
    }

    private fun snapSlice(rows: List<String>, offset: Int, limit: Int): List<String> =
        rows.subList(offset.coerceAtMost(rows.size), (offset + limit).coerceAtMost(rows.size))

    private fun materializeCallerRows(rows: List<String>): JSONArray {
        val out = JSONArray()
        for (row in rows) {
            val p = row.split('\u0001')
            out.put(JSONObject()
                .put("qualifiedId", p[0])
                .put("dexFile", p.getOrElse(1) { "" })
                .put("callSiteCount", p.getOrElse(2) { "1" }.toIntOrNull() ?: 1))
        }
        return out
    }

    private fun materializeDispatchRows(rows: List<String>): JSONArray {
        val out = JSONArray()
        for (row in rows) {
            val p = row.split('\u0001')
            out.put(JSONObject()
                .put("qualifiedId", p[0])
                .put("callSiteCount", p.getOrElse(1) { "1" }.toIntOrNull() ?: 1))
        }
        return out
    }

    private fun materializeCalleeRows(rows: List<String>): JSONArray {
        val out = JSONArray()
        for (row in rows) {
            val p = row.split('\u0001')
            out.put(JSONObject()
                .put("qualifiedId", p[0])
                .put("dexFile", p.getOrElse(1) { "" })
                .put("callSiteCount", p.getOrElse(2) { "1" }.toIntOrNull() ?: 1))
        }
        return out
    }

    private fun materializeCallSiteRows(target: String, rows: List<String>): JSONArray {
        val out = JSONArray()
        for (row in rows) {
            val p = row.split('\u0001')
            out.put(JSONObject()
                .put("caller", p[0])
                .put("callee", target)
                .put("instructionIndex", p.getOrElse(1) { "0" }.toIntOrNull() ?: 0)
                .put("opcode", p.getOrElse(2) { "" })
                .put("dispatch", p.getOrElse(3) { "direct" })
                .put("dexFile", p.getOrElse(4) { "" }))
        }
        return out
    }

    internal fun buildCallGraph(
        target: String,
        directCallers: JSONArray,
        dispatchCandidates: JSONArray,
        callees: JSONArray,
    ): JSONObject {
        val nodes = JSONArray()
        val edges = JSONArray()
        val seen = linkedSetOf<String>()
        var truncated = false
        fun addNode(id: String, role: String): Boolean {
            if (id in seen) return true
            if (seen.size >= MAX_GRAPH_NODES) {
                truncated = true
                return false
            }
            seen += id
            nodes.put(JSONObject().put("id", id).put("label", id.substringAfterLast('/')).put("role", role))
            return true
        }
        fun addEdge(from: String, to: String, relation: String, count: Int) {
            if (!addNode(from, "method") || !addNode(to, "method")) return
            edges.put(JSONObject().put("from", from).put("to", to)
                .put("relation", relation).put("callSiteCount", count))
        }
        addNode(target, "target")
        (0 until directCallers.length()).forEach { index ->
            val row = directCallers.getJSONObject(index)
            addEdge(row.getString("qualifiedId"), target, "direct_call", row.optInt("callSiteCount", 1))
        }
        (0 until dispatchCandidates.length()).forEach { index ->
            val row = dispatchCandidates.getJSONObject(index)
            addEdge(row.getString("qualifiedId"), target, "virtual_dispatch", row.optInt("callSiteCount", 1))
        }
        (0 until callees.length()).forEach { index ->
            val row = callees.getJSONObject(index)
            addEdge(target, row.getString("qualifiedId"), "calls", row.optInt("callSiteCount", 1))
        }
        return JSONObject()
            .put("format", "directed_method_graph_v1")
            .put("root", target)
            .put("nodes", nodes)
            .put("edges", edges)
            .put("truncated", truncated)
    }

    internal fun inheritancePath(
        start: String,
        target: String,
        parents: Map<String, List<String>>,
    ): List<String>? {
        val queue = ArrayDeque<List<String>>()
        val visited = mutableSetOf(start)
        queue.addLast(listOf(start))
        while (queue.isNotEmpty()) {
            val path = queue.removeFirst()
            val current = path.last()
            for (parent in parents[current].orEmpty()) {
                if (parent == target) return path + parent
                if (visited.add(parent)) queue.addLast(path + parent)
            }
        }
        return null
    }

    internal fun overrideSignatureMatches(targetProto: String, candidateProto: String): Boolean {
        val close = targetProto.indexOf(')')
        if (close < 0) return true
        return candidateProto.startsWith(targetProto.substring(0, close + 1))
    }

    private fun overrides(
        context: Context,
        apk: File,
        target: String,
        limit: Int,
        includeGraph: Boolean,
    ): JSONObject {
        val separator = target.indexOf("->")
        if (separator <= 0) return err("INVALID_ARGUMENT", "重写查询需要 Lpkg/Base;->method(params)ret", "target", target)
        val owner = target.substring(0, separator)
        val member = target.substring(separator + 2)
        val methodName = member.substringBefore('(')
        if (methodName.isBlank()) return err("INVALID_ARGUMENT", "重写查询缺少方法名", "target", target)
        val proto = member.indexOf('(').takeIf { it >= 0 }?.let(member::substring).orEmpty()
        val parameterProto = proto.indexOf(')').takeIf { it >= 0 }?.let { proto.substring(0, it + 1) }.orEmpty()
        val targetReturnType = proto.substringAfter(')', "")

        return runCatching {
            data class ClassInfo(
                val parents: List<String>,
                val methods: List<Method>,
                val dexFile: String,
            )
            val classes = linkedMapOf<String, ClassInfo>()
            var dexCount = 0
            DexIo.eachDex(context, apk) { dexName, dexFile ->
                dexCount++
                dexFile.classes.forEach { cls ->
                    classes[cls.type] = ClassInfo(
                        listOfNotNull(cls.superclass) + cls.interfaces,
                        cls.methods.toList(),
                        dexName,
                    )
                }
            }
            val targetKnown = owner in classes || classes.values.any { owner in it.parents }
            if (!targetKnown) {
                return@runCatching err(
                    "TARGET_NOT_FOUND",
                    "DEX 类层级中不存在目标类型: $owner",
                    "target",
                    target,
                )
            }

            val parents = classes.mapValues { it.value.parents }
            val matches = mutableListOf<JSONObject>()
            classes.forEach { (className, info) ->
                if (className == owner) return@forEach
                val path = inheritancePath(className, owner, parents) ?: return@forEach
                info.methods.forEach { method ->
                    if (method.name != methodName) return@forEach
                    val qualifiedId = qidOf(method)
                    val candidateProto = qualifiedId.substringAfter("->$methodName")
                    if (parameterProto.isNotEmpty() && !overrideSignatureMatches(proto, candidateProto)) return@forEach
                    val candidateReturnType = candidateProto.substringAfter(')', "")
                    matches += JSONObject()
                        .put("qualifiedId", qualifiedId)
                        .put("class", className)
                        .put("method", methodName)
                        .put("prototype", candidateProto)
                        .put("returnType", candidateReturnType)
                        .put("returnTypeExact", targetReturnType.isBlank() || candidateReturnType == targetReturnType)
                        .put("inheritanceDistance", path.size - 1)
                        .put("inheritancePath", JSONArray(path))
                        .put("dexFile", info.dexFile)
                }
            }
            matches.sortWith(compareBy<JSONObject> { it.optInt("inheritanceDistance") }
                .thenBy { it.optString("qualifiedId") })
            val returned = matches.take(limit.coerceIn(1, 500))
            val response = ok(JSONObject()
                .put("tool", "dex_xref")
                .put("direction", "overrides")
                .put("target", target)
                .put("baseClass", owner)
                .put("methodName", methodName)
                .put("prototype", proto.takeIf(String::isNotBlank) ?: JSONObject.NULL)
                .put("overrides", JSONArray(returned))
                .put("total", matches.size)
                .put("truncated", returned.size < matches.size)
                .put("summary", JSONObject().put("dexCount", dexCount).put("classCount", classes.size)))
            if (includeGraph) {
                response.put("flowGraph", JSONObject()
                    .put("format", "directed_method_graph_v1")
                    .put("root", target)
                    .put("nodes", JSONArray(listOf(JSONObject().put("id", target).put("role", "base")) +
                        returned.map { JSONObject().put("id", it.getString("qualifiedId")).put("role", "override") }))
                    .put("edges", JSONArray(returned.map { JSONObject()
                        .put("from", target).put("to", it.getString("qualifiedId"))
                        .put("relation", "overridden_by") }))
                    .put("truncated", returned.size < matches.size))
            }
            response
        }.getOrElse { e ->
            err("OVERRIDE_INDEX_FAILED", "重写方法查找失败: ${e.message ?: e.javaClass.simpleName}", "target", target)
        }
    }

    /**
     * Field XREF：字段 → 读写它的方法（跨 dex 聚合，带指令 index 与 opcode）。
     *
     * 方向：给定字段（如 Lcom/x/UserInfoBean;->isVip:Z），返回所有
     * iget/sget/iput/sput 引用它的指令（method + instructionIndex + opcode）。
     * FieldReference 直判（iget/sget/iput/sput 均为此类型；invoke 是
     * MethodReference 天然排除）。
     *
     * 分页：offset/limit 都缺省时一次返回全部（Dart 网关全量消费的兼容路径）；
     * 传 offset/limit 则切片返回。行序 = 写入方优先（定位修改点的权威证据），
     * 读取方按扫描序追加，翻页不会打乱该序。
     */
    fun fieldXref(
        context: Context,
        apkPath: String,
        fieldTarget: String,
        offset: Int? = null,
        limit: Int? = null,
    ): JSONObject {
        val apk = File(apkPath)
        if (!apk.isFile) return err("FILE_NOT_FOUND", "APK 不存在: $apkPath", "apkPath", apkPath)
        if (apk.length() > MAX_APK_BYTES) return err("APK_LIMIT_EXCEEDED", "APK 超过 512MiB 上限", "apkPath", apkPath)
        if (fieldTarget.isBlank()) return err("INVALID_ARGUMENT", "缺少 fieldTarget", "fieldTarget", "")
        val normTarget = fieldTarget.trim().removePrefix("dex_field:")
        val separator = normTarget.lastIndexOf(":")
        val targetOwnerAndName = if (separator > 0) normTarget.substring(0, separator) else normTarget
        // 字段引用扫描成本与方法 xref 同级：同款快照缓存（key 加前缀隔离）。
        val cacheKey = listOf(
            "field",
            apk.canonicalPath,
            apk.length(),
            apk.lastModified(),
            normTarget,
        ).joinToString("|")
        // P0 索引：READY 门=真实建成（meta built=1 + schema 匹配）。
        // 未建成时惰性触发后台构建（幂等、不阻塞本次查询——本次照旧走
        // 全量扫描，构建完成后后续查询自动切换 SELECT），分析零附加负担。
        val indexStore = FieldRefsIndexStore.of(context)
        val apkSha = runCatching { apkSha256Of(apk) }.getOrNull()
        synchronized(xrefCache) {
            xrefCache[cacheKey]?.let { cached ->
                // 缓存快照可能是 scan 期建的；索引建成后命中缓存同样标记
                // index=sqlite（行数据等价由构造保证，标记如实反映当前服务源）
                val indexLabel =
                    if (apkSha != null && indexStore.isReady(apkSha)) "sqlite" else "scan"
                return fieldPage(cached, normTarget, offset, limit)
                    .put("cache", "hit")
                    .put("index", indexLabel)
            }
        }
        if (apkSha != null) {
            if (indexStore.isReady(apkSha)) {
                val rows = indexStore.fieldRows(apkSha, normTarget, targetOwnerAndName)
                var writes = 0
                var reads = 0
                for (row in rows) {
                    if (row.split('\u0001').getOrElse(2) { "" } == "WRITE_FIELD") writes++ else reads++
                }
                val meta = indexStore.metaOf(apkSha)
                val summary = JSONObject()
                    .put("totalRefs", rows.size)
                    .put("totalWrites", writes)
                    .put("totalReads", reads)
                    .put("dexCount", meta?.dexCount ?: 0)
                    .put("scannedMethods", meta?.scannedMethods ?: 0)
                    .put("referenceInstructions", meta?.referenceInstructions ?: 0)
                    .put("fieldReferences", meta?.fieldReferences ?: 0)
                    .put("ownerNameMatches", rows.size)
                    .put("indexSource", "sqlite")
                val snapshot = XrefSnapshot(fieldRefs = rows, summary = summary)
                return fieldPage(snapshot, normTarget, offset, limit).put("index", "sqlite")
            }
            indexStore.triggerBuild(apk, apkSha)
        }

        return runCatching {
            // 写入方优先收集：字段权威写入方是定位修改点的关键证据，翻页/截断
            // 都不能把 writers 混进 readers 序（消费端结论依赖 writer 完整在前）。
            val writerRows = mutableListOf<String>()
            val readerRows = mutableListOf<String>()
            var dexCount = 0
            var scannedMethods = 0
            var referenceInstructions = 0
            var fieldReferences = 0
            var ownerNameMatches = 0
            DexIo.eachDex(context, apk) { dexName, dexFile ->
                dexCount++
                for (cls: ClassDef in dexFile.classes) {
                    for (m: Method in cls.methods) {
                        val impl = m.implementation ?: continue
                        scannedMethods++
                        var insnIdx = 0
                        for (insn: Instruction in impl.instructions) {
                            if (insn !is ReferenceInstruction) { insnIdx++; continue }
                            referenceInstructions++
                            val ref: Reference = insn.reference
                            if (ref !is FieldReference) { insnIdx++; continue }
                            fieldReferences++
                            val fieldQId = "${ref.definingClass}->${ref.name}:${ref.type}"
                            val ownerAndName = "${ref.definingClass}->${ref.name}"
                            if (ownerAndName == targetOwnerAndName) ownerNameMatches++
                            if (fieldQId != normTarget && ownerAndName != targetOwnerAndName) { insnIdx++; continue }
                            val opcode = insn.opcode.name
                            val relation = fieldRelation(opcode)
                            val accessKind = fieldAccessKind(opcode)
                            val row = fieldRefRow(
                                fieldQid = fieldQId,
                                methodQid = qidOf(m),
                                relation = relation,
                                accessKind = accessKind,
                                opcode = opcode,
                                insnIndex = insnIdx,
                                dexId = dexCount - 1,
                                dexFile = dexName,
                            )
                            if (relation == "WRITE_FIELD") writerRows.add(row) else readerRows.add(row)
                            insnIdx++
                        }
                    }
                }
            }
            val fieldRows = writerRows + readerRows
            val summary = JSONObject()
                .put("totalRefs", fieldRows.size)
                .put("totalWrites", writerRows.size)
                .put("totalReads", readerRows.size)
                .put("dexCount", dexCount)
                .put("scannedMethods", scannedMethods)
                .put("referenceInstructions", referenceInstructions)
                .put("fieldReferences", fieldReferences)
                .put("ownerNameMatches", ownerNameMatches)
            val snapshot = XrefSnapshot(fieldRefs = fieldRows, summary = summary)
            cachePut(cacheKey, snapshot)
            fieldPage(snapshot, normTarget, offset, limit).put("index", "scan")
        }.getOrElse { e ->
            err("FIELD_XREF_FAILED", "字段引用构建失败: ${e.message ?: e.javaClass.simpleName}", "apkPath", apkPath)
        }
    }

    /** 快照 → field_xref 响应：offset/limit 缺省 = 全量（网关兼容），传参 = 切片。 */
    internal fun fieldPage(
        snapshot: XrefSnapshot,
        fieldTarget: String,
        offset: Int?,
        limit: Int?,
    ): JSONObject {
        val rows = snapshot.fieldRefs
        val base = ok(JSONObject()
            .put("tool", "field_xref")
            .put("fieldTarget", fieldTarget)
            .put("summary", snapshot.summary))
        if (offset == null && limit == null) {
            val fieldRefs = JSONArray()
            for (row in rows) fieldRefs.put(fieldRowJson(row))
            return base.put("fieldRefs", fieldRefs)
        }
        val safeOffset = (offset ?: 0).coerceAtLeast(0)
        val safeLimit = (limit ?: 500).coerceIn(1, 5000)
        val truncated = safeOffset + safeLimit < rows.size
        val sliced = JSONArray()
        for (row in snapSlice(rows, safeOffset, safeLimit)) sliced.put(fieldRowJson(row))
        return base
            .put("fieldRefs", sliced)
            .put("offset", safeOffset)
            .put("returned", sliced.length())
            .put("totalRefs", rows.size)
            .put("truncated", truncated)
            .put("nextCursor", if (truncated) "${safeOffset + safeLimit}" else "")
            .put("hint", "写入方(WRITE_FIELD)排在最前,读取方随后;翻页用 nextOffset 继续即可到达全部引用")
    }

    private fun fieldRowJson(row: String): JSONObject {
        val p = row.split('\u0001')
        return JSONObject()
            .put("field", p[0])
            .put("method", p.getOrElse(1) { "" })
            .put("relation", p.getOrElse(2) { "READ_FIELD" })
            .put("accessKind", p.getOrElse(3) { "" })
            .put("opcode", p.getOrElse(4) { "" })
            .put("instructionIndex", p.getOrElse(5) { "0" }.toIntOrNull() ?: 0)
            .put("dexId", p.getOrElse(6) { "0" }.toIntOrNull() ?: 0)
            .put("dexFile", p.getOrElse(7) { "" })
    }

    internal fun fieldRelation(opcode: String): String {
        val normalized = opcode.lowercase()
        return if (normalized.startsWith("iput") || normalized.startsWith("sput")) "WRITE_FIELD" else "READ_FIELD"
    }

    internal fun fieldAccessKind(opcode: String): String {
        val normalized = opcode.lowercase()
        val isWrite = normalized.startsWith("iput") || normalized.startsWith("sput")
        val isStatic = normalized.startsWith("sget") || normalized.startsWith("sput")
        return if (isWrite) {
            if (isStatic) "WRITE_STATIC" else "WRITE_INSTANCE"
        } else {
            if (isStatic) "READ_STATIC" else "READ_INSTANCE"
        }
    }
}
