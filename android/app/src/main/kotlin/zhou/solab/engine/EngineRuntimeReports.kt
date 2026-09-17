package zhou.solab.engine

import zhou.solab.tools.SettingsStore
import zhou.solab.tools.err
import zhou.solab.tools.ok
import zhou.solab.tools.toJsonArray
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.math.min

internal fun EngineRuntime.analysisReport(workspaceId: String, editSessionId: String = "", writeToFile: Boolean = true): JSONObject = guarded {
    val resolvedId = resolveWorkspaceId(workspaceId, "")
    val ws = workspaces[resolvedId] ?: return@guarded err("WORKSPACE_NOT_FOUND", "Workspace not found", "workspaceId", workspaceId)
    val elf = elfFor(resolvedId, editSessionId)
    val data = dataFor(resolvedId, editSessionId)
    val recommendations = JSONArray()
    if (elf.sections.isEmpty()) recommendations.put("No section headers detected: run so_analyze(action=fix_sections) before section-based patching")
    if ((elf.dynSymbols.count { it.name == "JNI_OnLoad" || it.name.startsWith("Java_") }) > 0) recommendations.put("JNI exports detected: use so_analyze(action=emulate) for JNI_OnLoad or Java_* validation")
    val payload = JSONObject()
        .put("workspaceId", resolvedId)
        .put("editSessionId", editSessionId)
        .put("generatedAt", System.currentTimeMillis())
        .put("source", JSONObject()
            .put("path", ws.source.path)
            .put("name", ws.source.name)
            .put("source", ws.source.source)
            .put("apkPath", ws.source.apkPath)
            .put("apkEntry", ws.source.apkEntry)
            .put("abi", ws.source.abi))
        .put("architecture", elf.architecture)
        .put("checksums", checksums(data))
        .put("sections", elf.sections.mapIndexed { index, section -> EngineJson.sectionJson(ws.source.name, section, index) }.toJsonArray())
        .put("programHeaders", JSONArray(elf.programHeaders.map { EngineJson.phJson(it) }))
        .put("dynamicEntries", JSONArray(elf.dynamicEntries.map { EngineJson.dynJson(it) }))
        .put("dynsyms", elf.dynSymbols.map { EngineJson.symbolJson(ws.source.name, it) }.toJsonArray())
        .put("strings", elf.strings.map { EngineJson.stringJson(ws.source.name, it) }.toJsonArray())
        .put("security", JSONObject())
        .put("recommendations", recommendations)
    val file = if (writeToFile) {
        val dir = reportDir()
        val safeName = ws.source.name.replace(Regex("[^\\p{L}\\p{N}._-]"), "_")
        File(dir, "${safeName}.${System.currentTimeMillis()}.analysis-report.json").also { it.writeText(payload.toString(2)) }
    } else null
    ok(JSONObject().put("report", payload).put("written", file != null).put("reportPath", file?.absolutePath ?: JSONObject.NULL))
}

internal fun EngineRuntime.editAudit(workspaceId: String, editSessionId: String): JSONObject = guarded {
    val ws = workspaces[workspaceId] ?: return@guarded err("WORKSPACE_NOT_FOUND", "Workspace not found")
    // P1-2 前置提示：audit 需要活动编辑会话，未建会话时明确告知第一步
    val session = ws.edits[editSessionId] ?: return@guarded err("EDIT_SESSION_NOT_FOUND",
        "Edit session not found: audit 需要活动编辑会话，请先 so_analyze(action=edit_open) 创建，再用相应编辑 action 修改，并传入返回的 editSessionId。当前 workspace 已有会话: ${if (ws.edits.isEmpty()) "无" else ws.edits.keys.joinToString(", ")}")
    val patchesArr = JSONArray()
    session.patches.forEachIndexed { idx, p -> patchesArr.put(PatchByteUtils.patchJson(p).put("index", idx).put("active", true)) }
    val undoneArr = JSONArray()
    session.undone.forEachIndexed { idx, p -> undoneArr.put(PatchByteUtils.patchJson(p).put("index", idx).put("active", false)) }
    val snapshotsArr = JSONArray()
    session.snapshots.forEachIndexed { idx, s ->
        snapshotsArr.put(JSONObject()
            .put("index", idx)
            .put("snapshotId", s.id)
            .put("revision", s.revision)
            .put("sha256", s.sha256)
            .put("patchCount", s.patchCount)
            .put("timeMillis", s.timeMillis))
    }
    val byKind = JSONObject()
    session.patches.groupBy { it.kind }.forEach { (kind, list) -> byKind.put(kind, list.size) }
    ok(JSONObject()
        .put("workspaceId", workspaceId)
        .put("editSessionId", editSessionId)
        .put("revision", session.revision)
        .put("activePatchCount", session.patches.size)
        .put("undonePatchCount", session.undone.size)
        .put("snapshotCount", session.snapshots.size)
        .put("patchesByKind", byKind)
        .put("patches", patchesArr)
        .put("undonePatches", undoneArr)
        .put("snapshots", snapshotsArr)
        .put("currentTargetVersion", sha256(session.data)))
}

internal fun EngineRuntime.listBuildOutputs(prefix: String = "", limit: Int = 200): JSONObject = guarded {
    val settings = SettingsStore(context)
    val dir = artifactDir("so")
    val boundedLimit = limit.coerceIn(1, settings.maxBuildOutputs)
    val items = JSONArray()
    if (dir.exists()) {
        dir.listFiles { f -> f.isFile && (f.name.endsWith(".so", true) || f.name.endsWith(".patch-report.json", true)) }
            ?.sortedByDescending { it.lastModified() }
            ?.asSequence()
            ?.filter { prefix.isBlank() || it.name.startsWith(prefix, ignoreCase = true) }
            ?.take(boundedLimit)
            ?.forEach { f ->
                val isReport = f.name.endsWith(".patch-report.json", true)
                items.put(JSONObject()
                    .put("name", f.name)
                    .put("path", f.absolutePath)
                    .put("openPath", f.absolutePath)
                    .put("size", f.length())
                    .put("modified", f.lastModified())
                    .put("kind", if (isReport) "patch-report" else "so")
                    .put("canOpen", !isReport))
            }
    }
    val count = items.length()
    ok(JSONObject()
        .put("items", items)
        .put("usage", "Pass the path/openPath of any item with kind=so to so_analyze(action=open). patch-report items are JSON sidecars from so_analyze(action=build).")
        .put("directory", dir.absolutePath)
        .put("pagination", pagination(false, null, count, boundedLimit, count)))
}

internal fun EngineRuntime.auditDir(): File {
    return artifactDir("audits")
}

internal fun EngineRuntime.reportDir(): File {
    return artifactDir("reports")
}

internal fun EngineRuntime.persistAudit(workspaceId: String, editSessionId: String): JSONObject = guarded {
    val settings = SettingsStore(context)
    if (!settings.auditPersist) return@guarded ok(JSONObject().put("persisted", false).put("reason", "auditPersist disabled"))
    val ws = workspaces[workspaceId] ?: return@guarded err("WORKSPACE_NOT_FOUND", "Workspace not found")
    val session = ws.edits[editSessionId] ?: return@guarded err("EDIT_SESSION_NOT_FOUND", "Edit session not found")
    val dir = auditDir()
    val existing = dir.listFiles { f -> f.isFile && f.name.startsWith("$editSessionId-") }?.toList() ?: emptyList()
    if (existing.size >= settings.maxAudits) existing.sortedBy { it.lastModified() }.take(existing.size - settings.maxAudits + 1).forEach { it.delete() }
    val ts = System.currentTimeMillis()
    val file = File(dir, "$editSessionId-$ts.json")
    val payload = JSONObject()
        .put("workspaceId", workspaceId)
        .put("editSessionId", editSessionId)
        .put("sourcePath", ws.source.path)
        .put("sourceSha256", sha256(ws.data))
        .put("persistedAt", ts)
        .put("revision", session.revision)
        .put("activePatchCount", session.patches.size)
        .put("undonePatchCount", session.undone.size)
        .put("snapshotCount", session.snapshots.size)
        .put("currentTargetVersion", sha256(session.data))
        .put("patches", session.patches.mapIndexed { i, p -> PatchByteUtils.patchJson(p).put("index", i).put("active", true) }.toJsonArray())
        .put("undonePatches", session.undone.mapIndexed { i, p -> PatchByteUtils.patchJson(p).put("index", i).put("active", false) }.toJsonArray())
        .put("snapshots", session.snapshots.mapIndexed { i, s -> JSONObject().put("index", i).put("revision", s.revision).put("sha256", s.sha256).put("patchCount", s.patchCount).put("timeMillis", s.timeMillis) }.toJsonArray())
    file.writeText(payload.toString(2))
    ok(JSONObject().put("persisted", true).put("path", file.absolutePath).put("size", file.length()).put("persistedAt", ts))
}

internal fun EngineRuntime.listAudits(prefix: String = "", limit: Int = 100): JSONObject = guarded {
    val settings = SettingsStore(context)
    val dir = auditDir()
    val bounded = limit.coerceIn(1, settings.maxAudits)
    val items = JSONArray()
    if (dir.exists()) {
        dir.listFiles { f -> f.isFile && f.name.endsWith(".json") && (prefix.isBlank() || f.name.startsWith(prefix)) }
            ?.sortedByDescending { it.lastModified() }
            ?.take(bounded)
            ?.forEach { f ->
                val meta = runCatching {
                    val obj = JSONObject(f.readText())
                    JSONObject()
                        .put("editSessionId", obj.optString("editSessionId"))
                        .put("workspaceId", obj.optString("workspaceId"))
                        .put("sourcePath", obj.optString("sourcePath"))
                        .put("revision", obj.optInt("revision"))
                        .put("activePatchCount", obj.optInt("activePatchCount"))
                        .put("undonePatchCount", obj.optInt("undonePatchCount"))
                        .put("snapshotCount", obj.optInt("snapshotCount"))
                        .put("persistedAt", obj.optLong("persistedAt"))
                        .put("currentTargetVersion", obj.optString("currentTargetVersion"))
                }.getOrDefault(JSONObject().put("editSessionId", f.nameWithoutExtension))
                items.put(meta.put("file", f.name).put("path", f.absolutePath).put("size", f.length()))
            }
    }
    ok(JSONObject().put("items", items).put("directory", dir.absolutePath).put("pagination", pagination(false, null, items.length(), bounded, items.length())))
}

internal fun EngineRuntime.loadAudit(file: String): JSONObject = guarded {
    val f = File(file)
    if (!f.exists() || !f.isFile) return@guarded err("AUDIT_NOT_FOUND", "Audit file not found: $file", "file", file)
    val obj = runCatching { JSONObject(f.readText()) }.getOrElse { return@guarded err("AUDIT_CORRUPTED", "Audit file is not valid JSON: ${it.message}", "file", file) }
    ok(obj.put("path", f.absolutePath))
}

internal fun EngineRuntime.diff(workspaceId: String, editSessionId: String, limit: Int, compareSessionId: String = "", compareWorkspaceId: String = ""): JSONObject = guarded {
    val settings = SettingsStore(context)
    val cap = limit.coerceIn(1, settings.maxCompareRanges)
    val ws = workspaces[workspaceId] ?: return@guarded err("WORKSPACE_NOT_FOUND", "Workspace not found")
    val session = ws.edits[editSessionId] ?: return@guarded err("EDIT_SESSION_NOT_FOUND", "Edit session not found")
    val baselineWs = if (compareWorkspaceId.isNotBlank()) workspaces[compareWorkspaceId] ?: return@guarded err("WORKSPACE_NOT_FOUND", "Compare workspace not found") else ws
    val compareData = if (compareSessionId.isBlank()) ws.data else baselineWs.edits[compareSessionId]?.data ?: return@guarded err("EDIT_SESSION_NOT_FOUND", "Compare edit session not found: $compareSessionId")
    val ranges = JSONArray()
    var i = 0
    val maxSize = maxOf(compareData.size, session.data.size)
    while (i < maxSize && ranges.length() < cap) {
        if (i < compareData.size && i < session.data.size && compareData[i] == session.data[i]) {
            i++
            continue
        }
        val start = i
        while (i < maxSize && !(i < compareData.size && i < session.data.size && compareData[i] == session.data[i])) i++
        val old = if (start < compareData.size) compareData.copyOfRange(start, min(i, compareData.size)) else ByteArray(0)
        val next = if (start < session.data.size) session.data.copyOfRange(start, min(i, session.data.size)) else ByteArray(0)
        ranges.put(JSONObject().put("fileOffset", hex(start.toLong())).put("length", i - start).put("oldHex", PatchByteUtils.hexBytes(old)).put("newHex", PatchByteUtils.hexBytes(next)))
    }
    val result = JSONObject()
        .put("workspaceId", workspaceId)
        .put("editSessionId", editSessionId)
        .put("patchCount", session.patches.size)
        .put("patches", session.patches.map(PatchByteUtils::patchJson).toJsonArray())
        .put("diffRanges", ranges)
        .put("diffRangeCount", ranges.length())
        .put("targetVersion", sha256(session.data))
    if (compareSessionId.isNotBlank()) {
        result.put("compareSessionId", compareSessionId)
        result.put("compareWorkspaceId", compareWorkspaceId.ifBlank { workspaceId })
        result.put("compareTargetVersion", sha256(compareData))
        result.put("mode", "session_vs_session")
    } else {
        result.put("mode", "session_vs_original")
    }
    ok(result)
}

// 借鉴玄星逆核 meta_info(action=suggest)：按当前 SO 统计上下文给下一步动作建议。
// 错误恢复契约：任何 so_analyze action 报错后，带 workspaceId 重调 suggest 拿替代路径。
internal fun EngineRuntime.soSuggest(workspaceId: String, editSessionId: String = ""): JSONObject = guarded {
    val next = JSONArray()
        .put("Mutating edits (edit_hex/edit_asm/edit_symbol) default to dryRun=true preview; re-run with dryRun=false (plus targetVersion for locator-based edits) to apply.")
        .put("Always run edit_check before build — it detects claimed-but-unapplied patches.")
        .put("Persist findings with so_analyze(action=analysis_report, writeToFile=true) before final handoff.")
    if (workspaceId.isBlank()) {
        return@guarded ok(JSONObject()
            .put("workflow", "triage")
            .put("nextActions", next.put("Open the SO with action=open (or action=list_sources to discover files in the work directory), then re-run suggest with the returned workspaceId.")))
    }
    val stats = readStats(workspaceId, editSessionId)
    if (!stats.optBoolean("ok", false)) return@guarded stats
    val counts = stats.optJSONObject("counts") ?: JSONObject()
    if (counts.optInt("sections", 0) == 0) next.put("No section headers: run fix_sections (or xanso_build_sections force=true) before section-based reads/patches.")
    if (counts.optInt("functions", 0) == 0 && counts.optInt("exportedFunctions", 0) == 0) {
        next.put("No functions recovered: list(view=sections) to get the .text VA, then disasm(addr=<.text VA>) and rz_analyze to force re-analysis.")
    }
    if (counts.optInt("strings", 0) == 0) next.put("No strings extracted: try rz_search_bytes or hexdump; packed SOs may need unidbg emulation instead.")
    if (counts.optInt("jniExports", 0) > 0) next.put("JNI exports present: list(view=dynsyms) then emulate(symbolName=JNI_OnLoad or Java_*) to validate behavior; emulate_dump addr = module base (unidbg_dispatch op=session_modules) + ELF VA.")
    if (counts.optInt("symbols", 0) == 0) next.put("Stripped symbols: locate targets from imports (list(view=imports)) via xrefs/rz_search_bytes, then rz_decompile to read logic.")
    next.put("For quick instruction-level semantic checks prefer rz_esil (light Rizin VM) over emulate (heavy Unidbg).")
    ok(JSONObject()
        .put("workspaceId", stats.optString("workspaceId"))
        .put("editSessionId", editSessionId)
        .put("stats", counts)
        .put("nextActions", next))
}

internal fun EngineRuntime.writePatchReport(workspaceId: String, session: EditSession, output: File): File {
    val report = File(output.parentFile, "${output.nameWithoutExtension}.patch-report.json")
    val ws = workspaces[workspaceId]
    val emptyPatches = session.patches.count { it.newHex.isBlank() }
    val diffRanges = JSONArray()
    if (ws != null) {
        var i = 0
        while (i < ws.data.size && i < session.data.size && diffRanges.length() < 500) {
            if (ws.data[i] == session.data[i]) { i++; continue }
            val start = i
            while (i < ws.data.size && i < session.data.size && ws.data[i] != session.data[i]) i++
            diffRanges.put(JSONObject().put("fileOffset", hex(start.toLong())).put("length", i - start))
        }
    }
    val payload = JSONObject()
        .put("workspaceId", workspaceId)
        .put("editSessionId", session.id)
        .put("sourcePath", ws?.source?.path ?: JSONObject.NULL)
        .put("outputPath", output.absolutePath)
        .put("revision", session.revision)
        .put("patchCount", session.patches.size)
        .put("claimedPatches", session.patches.size)
        .put("effectivePatches", diffRanges.length())
        .put("emptyPatches", emptyPatches)
        .put("snapshotCount", session.snapshots.size)
        .put("undonePatchCount", session.undone.size)
        .put("patches", session.patches.map(PatchByteUtils::patchJson).toJsonArray())
        .put("diffRanges", diffRanges)
        .put("snapshots", session.snapshots.mapIndexed { idx, s ->
            JSONObject().put("index", idx).put("revision", s.revision).put("sha256", s.sha256).put("patchCount", s.patchCount).put("timeMillis", s.timeMillis)
        }.toJsonArray())
        .put("checksums", checksums(session.data))
    // 人读变更摘要：交付/回滚一眼可判（改了什么、SHA 前后、规模）。
    val beforeSha = ws?.let { sha256(it.data) } ?: "unknown"
    val afterSha = sha256(session.data)
    payload.put("changeSummary", buildString {
        append("已生成补丁 SO: ").append(output.name).append('\n')
        append("源文件: ").append(ws?.source?.name ?: "unknown").append('\n')
        append("SHA256 前: ").append(beforeSha).append('\n')
        append("SHA256 后: ").append(afterSha).append('\n')
        append("补丁 ").append(session.patches.size).append(" 项（生效 ")
            .append(diffRanges.length()).append(" 处，空补丁 ").append(emptyPatches).append(" 项）")
    })
    report.writeText(payload.toString(2))
    return report
}
