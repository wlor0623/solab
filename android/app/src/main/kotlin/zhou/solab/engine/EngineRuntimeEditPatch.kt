package zhou.solab.engine

import zhou.solab.tools.SettingsStore
import zhou.solab.tools.err
import zhou.solab.tools.ok
import zhou.solab.nativecore.NativeEngine
import org.json.JSONArray
import org.json.JSONObject


internal fun EngineRuntime.editHex(workspaceId: String, editSessionId: String, locator: String, edits: JSONArray, dryRun: Boolean = false, targetVersion: String = ""): JSONObject = guarded {
        val session = workspaces[workspaceId]?.edits?.get(editSessionId) ?: return@guarded err("EDIT_SESSION_NOT_FOUND", "Edit session not found")
        if (!dryRun && targetVersion.isNotBlank() && targetVersion != sha256(session.data)) {
            return@guarded err("VERSION_DRIFT", "targetVersion does not match current edit session bytes; the session changed after the preview. Re-run dryRun and confirm with the fresh targetVersion.", "targetVersion", targetVersion)
        }
        val settings = SettingsStore(context)
        val strict = settings.editStrictValidation
        val maxPatch = settings.maxPatchBytes
        val elf = lief.parse(session.data)
        // edits[i].va（绝对 VA）优先：与 disasm/xref 返回的地址直接对齐，免换算相对偏移；
        // 只有存在无 va 的 edit 时才需要 locator 解析出 baseOff 供 byteOffset 相对定位
        val anyRelativeEdit = (0 until edits.length()).any { edits.getJSONObject(it).optString("va").isBlank() }
        val sec = if (anyRelativeEdit) ElfSectionResolver.resolve(elf, locator) else null
        // locator 支持 section / so_function / 符号名 / 裸 VA；edits[i].byteOffset 为目标起点后的字节偏移
        val baseOff = if (!anyRelativeEdit) 0 else sec?.offset?.toInt() ?: run {
            val va = resolveCodeAddress(session.data, elf, locator)
                ?: return@guarded err("SECTION_NOT_FOUND", "Section '${LocatorParser.target(locator, "so_section")}' not found and locator resolves to no function/symbol/address. Call so_analyze(action=read_elf, view=list, subView=sections) for sections or so_analyze(action=rz_functions) for callable targets.", "locator", locator, "availableSections" to elf.sections.mapIndexed { index, section -> EngineJson.sectionKey(section, index) })
            vaToOffset(elf, va)?.toInt()
                ?: return@guarded err("OFFSET_OUT_OF_RANGE", "Address ${hex(va)} cannot be mapped to a file offset", "locator", locator)
        }
        val sectionName = sec?.name ?: LocatorParser.target(locator, "so_function").ifBlank { locator }
        val previews = JSONArray()
        val pending = mutableListOf<Pair<Int, ByteArray>>()
        for (i in 0 until edits.length()) {
            val edit = edits.getJSONObject(i)
            val aliases = listOf("newHex", "hex", "bytes", "data", "rawHex")
                .mapNotNull { key -> edit.optString(key).trim().takeIf { it.isNotBlank() }?.let { key to it } }
                .toMutableList()
            val rawValue = edit.opt("rawValue")
            when (rawValue) {
                is String -> rawValue.trim().takeIf { it.isNotBlank() }?.let { aliases += "rawValue" to it }
                is JSONArray -> aliases += "rawValue" to (0 until rawValue.length()).joinToString("") { index -> "%02x".format(rawValue.optInt(index).coerceIn(0, 255)) }
            }
            val normalizedValues = aliases.map { it.second.replace(Regex("[\\s,]"), "").lowercase() }.distinct()
            if (normalizedValues.size > 1) return@guarded err("CONFLICTING_ARGUMENTS", "Hex aliases contain different values at edit index $i", "edits[$i]", JSONObject(aliases.toMap()))
            val rawHex = aliases.firstOrNull()?.second.orEmpty()
            if (rawHex.isBlank()) {
                return@guarded err("INVALID_ARGUMENT", "Missing newHex (aliases: hex/bytes/data/rawHex/rawValue) for hex edit at index $i", "edits[$i].newHex", null)
            }
            val cleaned = rawHex.replace(" ", "").replace("\t", "").replace("\n", "").replace(",", "")
            if (cleaned.isEmpty() || cleaned.length % 2 != 0 || !cleaned.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }) {
                return@guarded err("INVALID_HEX", "newHex must be even-length hex digits, got: $rawHex", "edits[$i].newHex", rawHex)
            }
            val patch = cleaned.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
            if (patch.isEmpty()) {
                return@guarded err("INVALID_ARGUMENT", "Decoded patch is empty for hex edit at index $i", "edits[$i].newHex", rawHex)
            }
            if (patch.size > maxPatch) {
                return@guarded err("PATCH_TOO_LARGE", "Patch size ${patch.size} exceeds maxPatchBytes $maxPatch", "edits[$i].newHex", patch.size)
            }
            // VA 模式：绝对虚拟地址定位（disasm/xref/locate 返回的 VA 原样传入），优先于 byteOffset
            val vaStr = edit.optString("va").trim()
            if (vaStr.isNotBlank()) {
                val va = LocatorParser.hex(vaStr)
                    ?: return@guarded err("INVALID_ARGUMENT", "edits[$i].va must be a hex address like 0x5d1d34", "edits[$i].va", vaStr)
                val off = vaToOffset(elf, va)?.toInt()
                    ?: return@guarded err("OFFSET_OUT_OF_RANGE", "Address ${hex(va)} cannot be mapped to a file offset", "edits[$i].va", vaStr)
                if (off < 0 || off + patch.size > session.data.size) {
                    return@guarded err("OFFSET_OUT_OF_RANGE", "Hex edit range [${hex(off.toLong())}, +${patch.size}) exceeds file bytes (${session.data.size})", "edits[$i].va", vaStr)
                }
                val old = session.data.copyOfRange(off, off + patch.size)
                if (!edit.optBoolean("overrideStackCheck", false)) {
                    val verdict = StackGuard.check(old, patch, elf.architecture)
                    if (!verdict.ok) {
                        return@guarded err(verdict.code, verdict.message, "edits[$i]", verdict.details)
                    }
                }
                val section = sectionForOffset(elf, off.toLong())
                val preview = JSONObject()
                    .put("index", i)
                    .put("fileOffset", hex(off.toLong()))
                    .put("virtualAddress", hex(va))
                    .put("section", section?.name ?: JSONObject.NULL)
                    .put("sectionOffset", section?.let { hex(off.toLong() - it.offset) } ?: JSONObject.NULL)
                    .put("oldHex", PatchByteUtils.hexBytes(old))
                    .put("newHex", PatchByteUtils.hexBytes(patch))
                    .put("length", patch.size)
                if (dryRun) {
                    previews.put(preview)
                }
                pending += off to patch
                continue
            }
            val relOff = edit.optInt("byteOffset", edit.optInt("offset", Int.MIN_VALUE))
            if (relOff == Int.MIN_VALUE) {
                return@guarded err("INVALID_ARGUMENT", "Missing byteOffset (alias: offset) for hex edit at index $i", "edits[$i].byteOffset", null)
            }
            if (strict && relOff < 0) {
                return@guarded err("OFFSET_OUT_OF_RANGE", "byteOffset must be >= 0, got $relOff", "edits[$i].byteOffset", relOff)
            }
            val off = baseOff + relOff
            if (off < 0 || off + patch.size > session.data.size) {
                return@guarded err("OFFSET_OUT_OF_RANGE", "Hex edit range [${hex(off.toLong())}, +${patch.size}) exceeds file bytes (${session.data.size})", "edits[$i].byteOffset", relOff)
            }
            if (sec != null && (off < sec.offset.toInt() || off + patch.size > sec.offset.toInt() + sec.size.toInt())) {
                return@guarded err("OFFSET_OUT_OF_RANGE", "Hex edit range falls outside section '$sectionName'", "edits[$i].byteOffset", relOff)
            }
            val old = session.data.copyOfRange(off, off + patch.size)
            // P0 栈帧平衡守卫：拦截删 prologue 留 epilogue 的闪退补丁
            if (!edit.optBoolean("overrideStackCheck", false)) {
                val verdict = StackGuard.check(old, patch, elf.architecture)
                if (!verdict.ok) {
                    return@guarded err(verdict.code, verdict.message, "edits[$i]", verdict.details)
                }
            }
            val preview = JSONObject()
                .put("index", i)
                .put("fileOffset", hex(off.toLong()))
                .put("sectionOffset", hex(relOff.toLong()))
                .put("oldHex", PatchByteUtils.hexBytes(old))
                .put("newHex", PatchByteUtils.hexBytes(patch))
                .put("length", patch.size)
            if (dryRun) {
                previews.put(preview)
            }
            pending += off to patch
        }
        if (dryRun) {
            return@guarded ok(JSONObject()
                .put("dryRun", true)
                .put("preview", previews)
                .put("previewCount", previews.length())
                .put("targetVersion", sha256(session.data)))
        }
        val nextData = session.data.copyOf()
        val nextPatches = pending.map { (off, patch) ->
            val old = nextData.copyOfRange(off, off + patch.size)
            val record = PatchRecord(System.currentTimeMillis(), "hex", locator, off, PatchByteUtils.hexBytes(old), PatchByteUtils.hexBytes(patch))
            System.arraycopy(patch, 0, nextData, off, patch.size)
            record
        }
        if (nextPatches.isNotEmpty()) maybeAutoSnapshot(session, "hex", settings)
        System.arraycopy(nextData, 0, session.data, 0, session.data.size)
        if (nextPatches.isNotEmpty()) session.undone.clear()
        session.patches += nextPatches
        if (nextPatches.isNotEmpty()) {
            session.revision++
            pageStore.clear()
            searchCache.clear()
        }
        val res = JSONObject().put("newTargetVersion", sha256(session.data)).put("editCount", session.revision).put("patchCount", session.patches.size).put("applied", pending.size)
        maybeAutoPersist(workspaceId, session, settings)?.let { res.put("autoPersist", it) }
        ok(res)
    }

internal fun EngineRuntime.editHexVa(workspaceId: String, editSessionId: String, va: Long, patch: ByteArray, dryRun: Boolean = false, targetVersion: String = ""): JSONObject = guarded {
        val session = workspaces[workspaceId]?.edits?.get(editSessionId) ?: return@guarded err("EDIT_SESSION_NOT_FOUND", "Edit session not found")
        if (!dryRun && targetVersion.isNotBlank() && targetVersion != sha256(session.data)) {
            return@guarded err("VERSION_DRIFT", "targetVersion does not match current edit session bytes; the session changed after the preview. Re-run dryRun and confirm with the fresh targetVersion.", "targetVersion", targetVersion)
        }
        if (patch.isEmpty()) return@guarded err("INVALID_ARGUMENT", "patchHex decoded to empty bytes", "patchHex", "")
        val settings = SettingsStore(context)
        if (patch.size > settings.maxPatchBytes) return@guarded err("PATCH_TOO_LARGE", "Patch size ${patch.size} exceeds maxPatchBytes ${settings.maxPatchBytes}", "patchHex", patch.size)
        val elf = lief.parse(session.data)
        val off = vaToOffset(elf, va)?.toInt() ?: return@guarded err("OFFSET_OUT_OF_RANGE", "Address ${hex(va)} cannot be mapped to a file offset", "va", hex(va))
        if (off < 0 || off + patch.size > session.data.size) return@guarded err("OFFSET_OUT_OF_RANGE", "Patch range [${hex(off.toLong())}, +${patch.size}) exceeds file bytes (${session.data.size})", "va", hex(va))
        val old = session.data.copyOfRange(off, off + patch.size)
        // P0 栈帧平衡守卫（VA 直补同样拦截；无 per-edit override 时可整体跳过本调用）
        val verdict = StackGuard.check(old, patch, elf.architecture)
        if (!verdict.ok) {
            return@guarded err(verdict.code, verdict.message, "patchHex", verdict.details)
        }
        val section = sectionForOffset(elf, off.toLong())
        val preview = JSONObject()
            .put("fileOffset", hex(off.toLong()))
            .put("virtualAddress", hex(va))
            .put("section", section?.name ?: JSONObject.NULL)
            .put("sectionOffset", section?.let { hex(off.toLong() - it.offset) } ?: JSONObject.NULL)
            .put("oldHex", PatchByteUtils.hexBytes(old))
            .put("newHex", PatchByteUtils.hexBytes(patch))
            .put("length", patch.size)
        if (dryRun) {
            return@guarded ok(JSONObject()
                .put("dryRun", true)
                .put("preview", JSONArray().put(preview))
                .put("previewCount", 1)
                .put("targetVersion", sha256(session.data)))
        }
        maybeAutoSnapshot(session, "hex-va", settings)
        session.undone.clear()
        session.patches += PatchRecord(System.currentTimeMillis(), "hex-va", "va:${hex(va)}", off, PatchByteUtils.hexBytes(old), PatchByteUtils.hexBytes(patch))
        System.arraycopy(patch, 0, session.data, off, patch.size)
        session.revision++
        pageStore.clear()
        searchCache.clear()
        val res = JSONObject()
            .put("workspaceId", workspaceId)
            .put("editSessionId", editSessionId)
            .put("newTargetVersion", sha256(session.data))
            .put("editCount", session.revision)
            .put("patchCount", session.patches.size)
            .put("applied", 1)
            .put("patch", preview)
        maybeAutoPersist(workspaceId, session, settings)?.let { res.put("autoPersist", it) }
        ok(res)
    }

internal fun EngineRuntime.editAsm(workspaceId: String, editSessionId: String, locator: String, edits: JSONArray, dryRun: Boolean = false, targetVersion: String = ""): JSONObject = guarded {
        val restored = editSessionOrRestore(workspaceId, editSessionId)
            ?: return@guarded err("WORKSPACE_NOT_FOUND", "Workspace not found")
        val activeSessionId = restored.first
        val session = restored.second
        val sessionRestored = activeSessionId != editSessionId
        if (!dryRun && targetVersion.isNotBlank() && targetVersion != sha256(session.data)) {
            return@guarded err("VERSION_DRIFT", "targetVersion does not match current edit session bytes; the session changed after the preview. Re-run dryRun and confirm with the fresh targetVersion.", "targetVersion", targetVersion)
        }
        val settings = SettingsStore(context)
        val maxPatch = settings.maxPatchBytes
        val elf = lief.parse(session.data)
        val name = LocatorParser.target(locator, "so_function")
        val sym = (elf.symbols + elf.dynSymbols).firstOrNull { it.name == name }
        val startVa = resolveCodeAddress(session.data, elf, locator) ?: return@guarded err("FUNCTION_NOT_FOUND", "Function or address '$name' could not be resolved", "locator", locator, "acceptedForms" to acceptedLocatorForms())
        val base = vaToOffset(elf, startVa)?.toInt() ?: return@guarded err("OFFSET_OUT_OF_RANGE", "Function address ${hex(startVa)} cannot be mapped", "locator", locator)
        val thumb = elf.architecture == "arm32" && ((sym?.value ?: startVa) and 1L) == 1L
        val functionSize = sym?.let { functionByteSize(elf, it, base, session.data.size) }
            ?: rawExecutableWindowSize(elf, startVa, base, session.data.size)
        val assembledNop = runCatching { NativeEngine.active().assemble("nop", elf.architecture, startVa, thumb) }
            .getOrElse { PatchByteUtils.architectureNop(elf.architecture, thumb) }
        val nop = if (assembledNop.isEmpty()) PatchByteUtils.architectureNop(elf.architecture, thumb) else assembledNop
        val previews = JSONArray()
        val nextData = session.data.copyOf()
        val nextPatches = mutableListOf<PatchRecord>()
        // P1 AOT 提示：Dart 快照函数建议无栈最小桩
        val isAotSnapshot = runCatching {
            workspaces[workspaceId]?.source?.name.equals("libapp.so", ignoreCase = true) ||
                (elf.symbols + elf.dynSymbols).any { it.name.startsWith("_kDart") }
        }.getOrDefault(false)
        for (i in 0 until edits.length()) {
            val edit = edits.getJSONObject(i)
            val mode = edit.optString("mode", "replace_instructions")
            if (mode in setOf("insert_before", "insert_after", "prepend_function", "append_function", "write_function") && !edit.has("byteLength") && !edit.has("instructionCount")) {
                return@guarded err("UNSUPPORTED_OPERATION", "Insertion-style asm edits require an explicit byteLength or instructionCount because Android native build does not relocate downstream function bytes")
            }
            val isForceReturn = mode in setOf("force_return_constant", "return_constant", "constant_return")
            // P0 恒返回常量安全桩：mov w0,#N; ret（对象→mov x0,xzr; ret），不碰 fp/sp；
            // 值 >0xFFFF 自动扩 movz+movk 12 字节桩（上限 32 位），桩长即覆盖范围
            val forceStub: ByteArray? = if (isForceReturn) {
                val returnType = edit.optString("returnType", "int")
                val requestedEncoding = edit.optString("valueEncoding", "auto").lowercase()
                val valueEncoding = when (requestedEncoding) {
                    "", "auto" -> if (isAotSnapshot) "dart_aot" else "native"
                    "native", "dart_aot" -> requestedEncoding
                    else -> return@guarded err("INVALID_ARGUMENT", "valueEncoding must be auto|native|dart_aot", "edits[$i].valueEncoding", requestedEncoding)
                }
                val value = when (val rawValue = edit.opt("value")) {
                    null, JSONObject.NULL -> return@guarded err("INVALID_ARGUMENT", "mode=force_return_constant requires 'value' (0..4294967295) and optional returnType: int|bool|object", "edits[$i].value", null)
                    is Boolean -> if (rawValue) 1L else 0L
                    is Number -> rawValue.toLong()
                    is String -> LocatorParser.hex(rawValue) ?: rawValue.toLongOrNull()
                        ?: return@guarded err("INVALID_ARGUMENT", "value must be an integer or hex string, got: $rawValue", "edits[$i].value", rawValue)
                    else -> return@guarded err("INVALID_ARGUMENT", "value must be an integer or hex string", "edits[$i].value", rawValue.toString())
                }
                try {
                    StackGuard.forceReturnConstant(elf.architecture, returnType, value, thumb, valueEncoding)
                } catch (e: IllegalArgumentException) {
                    return@guarded err("INVALID_ARGUMENT", e.message ?: "force_return_constant failed", "edits[$i]", JSONObject().put("value", value).put("returnType", returnType).put("valueEncoding", valueEncoding))
                }
            } else {
                null
            }
            var range = if (isForceReturn) 0 to forceStub!!.size else asmEditRange(edit, startVa, thumb, elf.architecture, nop.size, functionSize)
            val patch = if (mode == "nop_out" || mode == "delete_instructions") {
                PatchByteUtils.repeatBytes(nop, range.second)
            } else if (isForceReturn) {
                forceStub!!
            } else {
                val asm = edit.optString("writeAsm", edit.optString("newAsm", edit.optString("asm", edit.optString("assembly", "")))).trim()
                if (asm.isBlank()) return@guarded err("ASM_SYNTAX_ERROR", "Missing writeAsm/newAsm/asm (alias: assembly) for asm edit at index $i")
                val encoded = runCatching { NativeEngine.active().assemble(asm, elf.architecture, startVa + range.first, thumb) }
                    .getOrElse { return@guarded err("ASM_SYNTAX_ERROR", it.message ?: "Assembler failed to encode: $asm") }
                if (encoded.isEmpty()) return@guarded err("ASM_SYNTAX_ERROR", "Assembler produced no bytes for: $asm")
                if (encoded.size > range.second && !edit.has("instructionCount") && !edit.has("byteLength")) {
                    val step = if (thumb) 2 else if (elf.architecture in setOf("arm32", "arm64")) 4 else nop.size.coerceAtLeast(1)
                    val needed = ((encoded.size + step - 1) / step) * step
                    if (range.first + needed <= functionSize) range = range.first to needed
                }
                if (encoded.size > range.second) return@guarded err("SIZE_MISMATCH", "Assembled code (${encoded.size}B) is larger than selected instruction range (${range.second}B). Set instructionCount/byteLength to cover multiple instructions, or split into single-instruction edits.", "edits[$i]", JSONObject().put("assembled", encoded.size).put("range", range.second))
                encoded + PatchByteUtils.repeatBytes(nop, range.second - encoded.size)
            }
            if (patch.size > maxPatch) {
                return@guarded err("PATCH_TOO_LARGE", "Patch size ${patch.size} exceeds maxPatchBytes $maxPatch", "edits[$i]", patch.size)
            }
            if (isForceReturn && patch.size > functionSize) {
                return@guarded err("SIZE_MISMATCH", "Stub size (${patch.size}B) exceeds function bytes ($functionSize B) at ${hex(startVa)}", "edits[$i]", JSONObject().put("stub", patch.size).put("function", functionSize))
            }
            val writeOffset = base + range.first
            val old = nextData.copyOfRange(writeOffset, writeOffset + patch.size)
            // P0 栈帧平衡守卫：拦截删 prologue 留 epilogue 的闪退补丁
            if (!isForceReturn && !edit.optBoolean("overrideStackCheck", false)) {
                val verdict = StackGuard.check(old, patch, elf.architecture)
                if (!verdict.ok) {
                    return@guarded err(verdict.code, verdict.message, "edits[$i]", verdict.details)
                }
            }
            val asmText = if (isForceReturn) {
                val requestedEncoding = edit.optString("valueEncoding", "auto").lowercase()
                val valueEncoding = if (requestedEncoding.isBlank() || requestedEncoding == "auto") {
                    if (isAotSnapshot) "dart_aot" else "native"
                } else requestedEncoding
                "force_return_constant(returnType=${edit.optString("returnType", "int")}, value=${edit.opt("value")}, valueEncoding=$valueEncoding)"
            } else {
                edit.optString("writeAsm", edit.optString("newAsm", edit.optString("asm", edit.optString("assembly", mode))))
            }
            val preview = JSONObject()
                .put("index", i)
                .put("fileOffset", hex(writeOffset.toLong()))
                .put("virtualAddress", hex(startVa + range.first))
                .put("oldHex", PatchByteUtils.hexBytes(old))
                .put("newHex", PatchByteUtils.hexBytes(patch))
                .put("asm", asmText)
                .put("mode", mode)
                .put("length", patch.size)
            if (isForceReturn) {
                val requestedEncoding = edit.optString("valueEncoding", "auto").lowercase()
                preview.put(
                    "valueEncoding",
                    if (requestedEncoding.isBlank() || requestedEncoding == "auto") {
                        if (isAotSnapshot) "dart_aot" else "native"
                    } else requestedEncoding,
                )
            }
            if (isAotSnapshot) {
                preview.put("aotHint", if (isForceReturn) {
                    "目标是 Flutter/Dart AOT：force_return_constant 已按 valueEncoding 生成对象编码；bool 返回 NULL_REG+0x20/0x30，null 返回 NULL_REG，int 返回 Smi。"
                } else {
                    "目标是 Flutter/Dart AOT：当前是原始指令编辑，不会自动转换 Dart 对象编码。对象值必须改用 force_return_constant 或先证明原生标量 ABI。"
                })
            }
            if (dryRun) {
                // P1 dryRun 自动反汇编预览：新字节的实际指令流
                runCatching {
                    NativeEngine.active().disassemble(patch, elf.architecture, startVa + range.first, thumb, 16)
                }.getOrNull()?.takeIf { it.isNotBlank() }?.let { preview.put("disasm", it.take(2000)) }
                previews.put(preview)
                continue
            }
            nextPatches += PatchRecord(System.currentTimeMillis(), "asm", locator, writeOffset, PatchByteUtils.hexBytes(old), PatchByteUtils.hexBytes(patch), asmText)
            System.arraycopy(patch, 0, nextData, writeOffset, patch.size)
        }
        if (dryRun) {
            return@guarded ok(JSONObject()
                .put("dryRun", true)
                .put("editSessionId", activeSessionId)
                .put("sessionRestored", sessionRestored)
                .put("preview", previews)
                .put("previewCount", previews.length())
                .put("targetVersion", sha256(session.data)))
        }
        if (nextPatches.isNotEmpty()) {
            maybeAutoSnapshot(session, "asm", settings)
            session.undone.clear()
            System.arraycopy(nextData, 0, session.data, 0, session.data.size)
            session.patches += nextPatches
            session.revision++
            pageStore.clear()
            searchCache.clear()
        }
        val resAsm = JSONObject().put("editSessionId", activeSessionId).put("sessionRestored", sessionRestored).put("newTargetVersion", sha256(session.data)).put("editCount", session.revision).put("patchCount", session.patches.size).put("applied", nextPatches.size)
        if (nextPatches.isNotEmpty()) maybeAutoPersist(workspaceId, session, settings)?.let { resAsm.put("autoPersist", it) }
        ok(resAsm)
    }

internal fun EngineRuntime.editSymbol(workspaceId: String, editSessionId: String, locator: String, edits: JSONArray, dryRun: Boolean = false, targetVersion: String = ""): JSONObject = guarded {
        val session = workspaces[workspaceId]?.edits?.get(editSessionId) ?: return@guarded err("EDIT_SESSION_NOT_FOUND", "Edit session not found")
        if (!dryRun && targetVersion.isNotBlank() && targetVersion != sha256(session.data)) {
            return@guarded err("VERSION_DRIFT", "targetVersion does not match current edit session bytes; the session changed after the preview. Re-run dryRun and confirm with the fresh targetVersion.", "targetVersion", targetVersion)
        }
        val settings = SettingsStore(context)
        val name = LocatorParser.target(locator, "so_symbol")
        val previews = JSONArray()
        val nextData = session.data.copyOf()
        val nextPatches = mutableListOf<PatchRecord>()
        for (i in 0 until edits.length()) {
            val edit = edits.getJSONObject(i)
            if (edit.optString("op", "rename") == "rename") {
                val newName = edit.optString("newName", name)
                // 无符号地址（裸 VA 如 0xe0befc）没有符号表条目，rename 无从谈起——
                // 提前拦截，别让底层 SYMTAB_OVERFLOW 用「改长」的措辞误导
                if (name.startsWith("0x", true) && LocatorParser.hex(name) != null) {
                    return@guarded err("SYMBOL_NOT_ADDRESS",
                        "目标 $name 是无符号地址（不在符号表中），无符号名可改。edit_symbol 仅支持对「已有符号」等长或改短重命名；" +
                            "无符号地址请用 edit_hex/edit_asm 直接补丁字节（恒返回常量用 mode=force_return_constant），" +
                            "或用 lief addExportedFunction 在该地址新增导出符号。")
                }
                if (newName.length > name.length) return@guarded err("SYMTAB_OVERFLOW",
                    "改长重命名不被支持：Android 原生构建做字节级 strtab 原位替换，无法扩容符号表" +
                        "（等长/改短可用，改短部分自动补 \\0）。替代方案：lief addExportedFunction 在目标地址新增任意长度导出符号，" +
                        "或对地址用 edit_hex/edit_asm 定位。当前 oldLen=${name.length} newLen=${newName.length}")
                val oldBytes = name.toByteArray()
                val newBytes = newName.toByteArray()
                val pos = indexOf(nextData, oldBytes)
                if (pos < 0) return@guarded err("SYMBOL_NOT_FOUND", "Symbol string not found in SO bytes")
                val replacement = ByteArray(oldBytes.size) { if (it < newBytes.size) newBytes[it] else 0 }
                val preview = JSONObject()
                    .put("index", i)
                    .put("fileOffset", hex(pos.toLong()))
                    .put("oldHex", PatchByteUtils.hexBytes(oldBytes))
                    .put("newHex", PatchByteUtils.hexBytes(replacement))
                    .put("asm", "rename $name -> $newName")
                    .put("length", oldBytes.size)
                if (dryRun) {
                    previews.put(preview)
                    continue
                }
                nextPatches += PatchRecord(System.currentTimeMillis(), "symbol", locator, pos, PatchByteUtils.hexBytes(oldBytes), PatchByteUtils.hexBytes(replacement), "rename $name -> $newName")
                for (j in oldBytes.indices) nextData[pos + j] = if (j < newBytes.size) newBytes[j] else 0
            } else {
                return@guarded err("UNSUPPORTED_OPERATION", "Only same-or-shorter rename is supported")
            }
        }
        if (dryRun) {
            return@guarded ok(JSONObject()
                .put("dryRun", true)
                .put("preview", previews)
                .put("previewCount", previews.length())
                .put("targetVersion", sha256(session.data)))
        }
        if (nextPatches.isNotEmpty()) {
            maybeAutoSnapshot(session, "symbol", settings)
            session.undone.clear()
            System.arraycopy(nextData, 0, session.data, 0, session.data.size)
            session.patches += nextPatches
            session.revision++
            pageStore.clear()
            searchCache.clear()
        }
        val resSym = JSONObject().put("newTargetVersion", sha256(session.data)).put("editCount", session.revision).put("patchCount", session.patches.size).put("applied", nextPatches.size)
        if (nextPatches.isNotEmpty()) maybeAutoPersist(workspaceId, session, settings)?.let { resSym.put("autoPersist", it) }
        ok(resSym)
    }

private fun EngineRuntime.asmEditRange(edit: JSONObject, startVa: Long, thumb: Boolean, architecture: String, fallbackInsnSize: Int, maxBytes: Int): Pair<Int, Int> {
        val step = if (architecture == "arm32" && thumb) 2 else fallbackInsnSize.coerceAtLeast(1)
        if (edit.has("address") && edit.optString("address").isNotBlank()) {
            // JSON number 按十进制 VA 解析；字符串按 hex VA 解析（0x 前缀可选），避免数字被误当 hex 错位
            val addr = when (val rawAddress = edit.opt("address")) {
                is Number -> rawAddress.toLong()
                is String -> rawAddress.trim().let { LocatorParser.hex(it) ?: it.removePrefix("0x").removePrefix("0X").toLongOrNull(16) }
                else -> null
            } ?: throw IllegalArgumentException("address must be a hex VA like 0x978, got ${edit.opt("address")}")
            val off = (addr - startVa).toInt()
            val length = when {
                edit.optInt("byteLength", 0) > 0 -> edit.optInt("byteLength", 0)
                edit.optInt("length", 0) > 0 -> edit.optInt("length", 0)
                edit.has("instructionCount") -> edit.optInt("instructionCount", 1).coerceAtLeast(1) * step
                edit.has("count") -> edit.optInt("count", 1).coerceAtLeast(1) * step
                else -> step
            }
            require(off >= 0 && length > 0 && off + length <= maxBytes) { "Assembly edit address range [${hex(off.toLong())}, +$length) exceeds function bytes ($maxBytes)" }
            return off to length
        }
        if (edit.has("instructionIndex")) {
            val idx = edit.optInt("instructionIndex", 0)
            val count = edit.optInt("instructionCount", edit.optInt("count", 1)).coerceAtLeast(1)
            val off = idx * step
            val length = when {
                edit.optInt("byteLength", 0) > 0 -> edit.optInt("byteLength", 0)
                edit.optInt("length", 0) > 0 -> edit.optInt("length", 0)
                else -> count * step
            }
            require(idx >= 0 && length > 0 && off + length <= maxBytes) { "Assembly edit instruction range exceeds function bytes" }
            return off to length
        }
        val explicitByteOffset = when {
            edit.has("byteOffset") && edit.optInt("byteOffset", 0) != 0 -> edit.optInt("byteOffset", 0)
            edit.has("offset") && edit.optInt("offset", 0) != 0 -> edit.optInt("offset", 0)
            edit.has("byteOffset") && !edit.has("instructionIndex") -> edit.optInt("byteOffset", 0)
            edit.has("offset") && !edit.has("instructionIndex") -> edit.optInt("offset", 0)
            else -> 0
        }
        val length = edit.optInt("byteLength", edit.optInt("length", 0)).takeIf { it > 0 } ?: edit.optInt("instructionCount", edit.optInt("count", 1)).coerceAtLeast(1) * step
        require(explicitByteOffset >= 0 && length > 0 && explicitByteOffset + length <= maxBytes) { "Assembly edit byte range exceeds function bytes" }
        return explicitByteOffset to length
    }
