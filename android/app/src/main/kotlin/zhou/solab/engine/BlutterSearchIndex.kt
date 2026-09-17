package zhou.solab.engine

import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.PriorityQueue
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

internal data class PpFeatureGroup(
    val id: String,
    val label: String,
    val keywords: List<String>,
    val weight: Int,
)

/**
 * Blutter 产物的精准查询（定位补丁点用）：基于 results/<key>/ 下的 pp.txt 与 asm/ 反汇编树。
 *
 *  - searchPp:  pp.txt 按子串过滤，返回池偏移 + 整行（query=is_vip → [pp+0x1aba8] String:"is_vip"）
 *  - searchAsm: asm/**/*.dart 按子串过滤，命中行附带所在类/函数与文件位置
 *  - xref:      池偏移 → 引用该池项的指令 VA + 所属函数。blutter 已在 asm 里为每条
 *               池引用写了 [pp+0x...] 注释（等价于内存扫 add PP,#hi,lsl #12 + ldr 指令对），
 *               离线即可完成定位，无需 libapp.so 在手。
 */
internal object BlutterSearchIndex {
    private const val ARM64_POOL_INDEX = "pp-xref-arm64.jsonl"
    private const val ARM64_POOL_INDEX_V2 = "pp-xref-arm64-v2.bin"
    private const val ARM64_POOL_INDEX_MAGIC = 0x42585232
    private const val ARM64_CLOSURE_CALL_INDEX = "pp-xref-arm64-closure-calls-v1.bin"
    private const val ARM64_CLOSURE_CALL_INDEX_MAGIC = 0x42584331
    private const val ARM64_FUNCTION_INDEX = "arm64-functions.jsonl"
    private const val ASM_PATH_INDEX = "blutter-asm-paths-v1.txt"
    private const val FUNCTION_HEADER_INDEX = "blutter-function-headers-v2.bin"
    private const val FUNCTION_HEADER_INDEX_MAGIC = 0x42464832
    private const val MEMORY_ACCESS_INDEX = "blutter-memory-access-v2.bin"
    private const val MEMORY_ACCESS_INDEX_MAGIC = 0x424d4132
    private const val FIELD_SLICE_INDEX = "blutter-field-slice-v1.bin"
    private const val FIELD_SLICE_INDEX_MAGIC = 0x42465331
    private const val SEMANTIC_INDEX = "blutter-semantic-v2.jsonl.gz"
    private const val SEMANTIC_META = "blutter-semantic-v2.meta.json"
    private const val SEMANTIC_VERSION = 4
    private const val LEGACY_SEMANTIC_INDEX = "blutter-semantic-v1.jsonl"
    private const val LEGACY_SEMANTIC_META = "blutter-semantic-v1.meta.json"
    private const val FIELD_SLICE_WINDOW = 24
    private const val NO_SLICE_VALUE = Long.MIN_VALUE
    private const val SLICE_COMPARISON = 1
    private const val SLICE_DIRECT_BRANCH = 2
    private const val SLICE_FLAGS_BRANCH = 3
    private const val SLICE_BOOLEAN_RESULT = 4
    private const val SLICE_RETURN = 5
    private const val SLICE_CALL_ARGUMENT = 6
    private const val QUERY_CACHE_LIMIT = 4
    private const val HEAVY_QUERY_CACHE_LIMIT = 2
    private const val PP_LINES_CACHE_LIMIT = 1
    // pp.txt 驻留缓存上限：缓存原始字节（内存 = 文件大小，避免 List<String>
    // 双份缓存打爆 largeHeap）。超过此大小走流式逐行扫描（内存 O(1)）。
    // 128MB 覆盖 200MB 级 APK 的 pp.txt，二次查询从内存解码比磁盘 IO 快 10-100 倍。
    private const val PP_CACHE_MAX_BYTES = 128L * 1024L * 1024L
    private val INSN_VA = Regex("//\\s*0x([0-9a-fA-F]+):")
    private val PP_OFFSET = Regex("^\\s*\\[pp\\+0x([0-9a-fA-F]+)]", RegexOption.IGNORE_CASE)
    private val REF = Regex("\\[pp\\+0x([0-9a-fA-F]+)]", RegexOption.IGNORE_CASE)
    private val FUNC_ADDR = Regex("^\\s*// \\*\\* addr: 0x([0-9a-fA-F]+), size: -?0x([0-9a-fA-F]+)", RegexOption.IGNORE_CASE)
    private val CALL_TARGET_RE = Regex("\\b(bl|b)\\s+#?0x([0-9a-fA-F]+)", RegexOption.IGNORE_CASE)
    private val INSN_ADDR = Regex("^\\s*(?://\\s*)?0x([0-9a-fA-F]+):")
    private val VALUE_INSTRUCTION = Regex(
        "^\\s*//\\s+0x([0-9a-fA-F]+):\\s+(mov|movz|movn|cmp|cmn)\\s+[^,]+,\\s*#(-?0x[0-9a-fA-F]+|-?\\d+)\\b",
        RegexOption.IGNORE_CASE,
    )
    private val MEMORY_IMMEDIATE = Regex(
        "^\\s*//\\s+0x[0-9a-fA-F]+:\\s+(?:ldr|ldur|str|stur|ldrb|ldrh|strb|strh)\\w*\\s+.*\\[[^]]*#(-?0x[0-9a-fA-F]+|-?\\d+)[^]]*]",
        RegexOption.IGNORE_CASE,
    )
    private val MEMORY_ACCESS = Regex(
        "^\\s*(?://\\s*)?0x([0-9a-fA-F]+):\\s+((?:ldr|ldur|str|stur|ldrb|ldrh|strb|strh)\\w*)\\s+([^,]+),\\s*\\[([a-z0-9]+),\\s*#(-?0x[0-9a-fA-F]+|-?\\d+)[^]]*]",
        RegexOption.IGNORE_CASE,
    )
    private val ARM64_INSTRUCTION = Regex(
        "^\\s*(?://\\s*)?0x([0-9a-fA-F]+):\\s+([a-z][a-z0-9.]*)\\s*(.*)$",
        RegexOption.IGNORE_CASE,
    )
    private val ARM64_REGISTER = Regex("\\b[wx](\\d{1,2})\\b", RegexOption.IGNORE_CASE)
    private val ARM64_IMMEDIATE = Regex("#(-?0x[0-9a-fA-F]+|-?\\d+)", RegexOption.IGNORE_CASE)
    private val POOL_INTEGER = Regex(
        "^\\s*\\[pp\\+0x([0-9a-fA-F]+)]\\s+(Mint|Smi|Int|Integer):\\s*(-?0x[0-9a-fA-F]+|-?\\d+)\\s*$",
        RegexOption.IGNORE_CASE,
    )
    private val ADD_PP = Regex("\\badd\\s+(x\\d+),\\s*x27,\\s*#(0x[0-9a-fA-F]+|\\d+),\\s*lsl\\s*#12", RegexOption.IGNORE_CASE)
    private val LDR_FROM = Regex("\\bldr\\w*\\s+[^,]+,\\s*\\[(x\\d+),\\s*#(0x[0-9a-fA-F]+|\\d+)]", RegexOption.IGNORE_CASE)
    private val NON_OBJECT_BASE_REGISTERS = setOf(15, 26, 27, 28, 29, 30, 31, 32, 127)

    private data class ActiveFieldSlice(
        val sourceVa: Long,
        val fieldOffset: Long,
        val sourceRegister: Int,
        val registers: MutableSet<Int>,
        var remaining: Int = FIELD_SLICE_WINDOW,
        var flagsTainted: Boolean = false,
    )
    // 语义索引（blutter-semantic-v1.jsonl）按 asm 指令逐行落盘，中型 Flutter app 可达
    // 百万行级；解析成 List<JSONObject> 驻留缓存会打爆 largeHeap（实测 locate 即 OOM）。
    // 语义查询一律流式逐行解析（内存 O(1)），只有函数头（几千条、极小）允许驻留缓存。
    private data class FunctionHeaderCacheKey(val path: String, val modified: Long, val size: Long)
    private data class Arm64FunctionsCacheKey(val path: String, val modified: Long, val size: Long)
    private data class PpLinesCacheKey(val path: String, val modified: Long, val size: Long)
    private data class PpCacheKey(val path: String, val modified: Long, val size: Long, val query: String)
    private data class AsmSearchCacheKey(
        val path: String,
        val sourceFingerprint: String,
        val query: String,
        val caseInsensitive: Boolean,
        val limit: Int,
        val fullScan: Boolean,
        val includePaths: List<String>,
        val excludePaths: List<String>,
        val includeThirdParty: Boolean,
    )
    private val functionHeaderCache = object : LinkedHashMap<FunctionHeaderCacheKey, List<FunctionHeader>>(HEAVY_QUERY_CACHE_LIMIT, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<FunctionHeaderCacheKey, List<FunctionHeader>>?): Boolean = size > HEAVY_QUERY_CACHE_LIMIT
    }
    private val ppProfileCache = object : LinkedHashMap<PpCacheKey, JSONObject>(QUERY_CACHE_LIMIT, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<PpCacheKey, JSONObject>?): Boolean = size > QUERY_CACHE_LIMIT
    }
    private val ppLocateCache = object : LinkedHashMap<PpCacheKey, JSONObject>(QUERY_CACHE_LIMIT, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<PpCacheKey, JSONObject>?): Boolean = size > QUERY_CACHE_LIMIT
    }
    private val ppSearchCache = object : LinkedHashMap<PpCacheKey, JSONObject>(QUERY_CACHE_LIMIT, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<PpCacheKey, JSONObject>?): Boolean = size > QUERY_CACHE_LIMIT
    }
    private val ppContextCache = object : LinkedHashMap<PpCacheKey, JSONObject>(QUERY_CACHE_LIMIT, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<PpCacheKey, JSONObject>?): Boolean = size > QUERY_CACHE_LIMIT
    }
    private val ppLocatePipelineCache = object : LinkedHashMap<PpCacheKey, JSONObject>(QUERY_CACHE_LIMIT, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<PpCacheKey, JSONObject>?): Boolean = size > QUERY_CACHE_LIMIT
    }
    private val ppLinesCache = object : LinkedHashMap<PpLinesCacheKey, ByteArray>(PP_LINES_CACHE_LIMIT, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<PpLinesCacheKey, ByteArray>?): Boolean = size > PP_LINES_CACHE_LIMIT
    }
    private val asmSearchCache = object : LinkedHashMap<AsmSearchCacheKey, JSONObject>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<AsmSearchCacheKey, JSONObject>?): Boolean = size > 8
    }
    private val arm64FunctionsCache = object : LinkedHashMap<Arm64FunctionsCacheKey, List<Long>>(HEAVY_QUERY_CACHE_LIMIT, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Arm64FunctionsCacheKey, List<Long>>?): Boolean = size > HEAVY_QUERY_CACHE_LIMIT
    }

    @JvmField
    internal var ppScanCount = 0

    @Synchronized
    internal fun resetQueryCacheForTest() {
        functionHeaderCache.clear()
        arm64FunctionsCache.clear()
        ppProfileCache.clear()
        ppLocateCache.clear()
        ppSearchCache.clear()
        ppContextCache.clear()
        ppLocatePipelineCache.clear()
        ppLinesCache.clear()
        asmSearchCache.clear()
        ppScanCount = 0
    }

    fun firstPartyAsmRoots(resultDir: File): Set<String> {
        val libraries = File(resultDir, "libraries.jsonl")
        if (!libraries.isFile) return emptySet()
        return libraries.useLines { lines ->
            lines.mapNotNull { raw ->
                val name = runCatching { JSONObject(raw).optString("name") }.getOrNull().orEmpty()
                if (!name.startsWith("file:///")) return@mapNotNull null
                val path = name.replace('\\', '/')
                val marker = "/.dart_tool/"
                val markerIndex = path.indexOf(marker)
                if (markerIndex < 0) return@mapNotNull null
                path.substring(0, markerIndex).substringAfterLast('/').takeIf(String::isNotBlank)
            }.toSet()
        }
    }

    @Synchronized
    fun ensureSemanticIndex(resultDir: File, force: Boolean = false): JSONObject {
        val index = File(resultDir, SEMANTIC_INDEX)
        val meta = File(resultDir, SEMANTIC_META)
        if (!force && index.isFile && meta.isFile && File(resultDir, MEMORY_ACCESS_INDEX).isFile &&
            File(resultDir, FIELD_SLICE_INDEX).isFile) {
            val stored = runCatching { JSONObject(meta.readText()) }.getOrNull()
            if (stored?.optInt("version") == SEMANTIC_VERSION) return JSONObject(stored.toString()).put("cacheHit", true)
        }
        val legacyIndex = File(resultDir, LEGACY_SEMANTIC_INDEX)
        val legacyMeta = File(resultDir, LEGACY_SEMANTIC_META)
        if (!force && legacyIndex.isFile && legacyMeta.isFile) {
            val stored = runCatching { JSONObject(legacyMeta.readText()) }.getOrNull()
            if (stored?.optInt("version") == 1) {
                return JSONObject(stored.toString())
                    .put("index", LEGACY_SEMANTIC_INDEX)
                    .put("legacy", true)
                    .put("cacheHit", true)
            }
        }
        val asmDir = File(resultDir, "asm")
        require(asmDir.isDirectory) { "ASM_RESULT_NOT_FOUND" }
        resultDir.mkdirs()
        val tempIndex = File(resultDir, "$SEMANTIC_INDEX.tmp")
        val functionIndex = File(resultDir, FUNCTION_HEADER_INDEX)
        val tempFunctionIndex = File(resultDir, "$FUNCTION_HEADER_INDEX.tmp")
        val memoryIndex = File(resultDir, MEMORY_ACCESS_INDEX)
        val tempMemoryIndex = File(resultDir, "$MEMORY_ACCESS_INDEX.tmp")
        val fieldSliceIndex = File(resultDir, FIELD_SLICE_INDEX)
        val tempFieldSliceIndex = File(resultDir, "$FIELD_SLICE_INDEX.tmp")
        var scannedFiles = 0
        var functionCount = 0
        var referenceCount = 0
        var immediateCount = 0
        var memoryAccessCount = 0
        var fieldSliceCount = 0
        val addressingImmediateCounts = HashMap<Long, Int>()
        DataOutputStream(BufferedOutputStream(FileOutputStream(tempFieldSliceIndex))).use { fieldSliceOut ->
          fieldSliceOut.writeInt(FIELD_SLICE_INDEX_MAGIC)
          DataOutputStream(BufferedOutputStream(FileOutputStream(tempMemoryIndex))).use { memoryOut ->
            memoryOut.writeInt(MEMORY_ACCESS_INDEX_MAGIC)
            DataOutputStream(BufferedOutputStream(FileOutputStream(tempFunctionIndex))).use { functionOut ->
                functionOut.writeInt(FUNCTION_HEADER_INDEX_MAGIC)
                GZIPOutputStream(BufferedOutputStream(FileOutputStream(tempIndex))).bufferedWriter().use { out ->
                asmDir.walkTopDown().filter { it.isFile && it.extension == "dart" }.forEach { file ->
                val rel = "asm/${file.relativeTo(asmDir).path}"
                var currentClass: String? = null
                var pendingSignature: String? = null
                var currentFunctionVa: String? = null
                var pendingPoolAdd: Pair<String, Long>? = null
                val activeFieldSlices = mutableListOf<ActiveFieldSlice>()
                file.useLines { lines ->
                    lines.forEachIndexed { lineIndex, raw ->
                        val trimmed = raw.trim()
                        if (trimmed.startsWith("class ")) currentClass = className(trimmed)
                        val header = FUNC_ADDR.matchEntire(raw)
                        if (header != null) {
                            activeFieldSlices.clear()
                            currentFunctionVa = header.groupValues[1].lowercase()
                            val functionSize = header.groupValues[2].lowercase()
                            out.write(JSONObject()
                                .put("type", "function")
                                .put("va", currentFunctionVa)
                                .put("size", functionSize)
                                .put("function", pendingSignature ?: JSONObject.NULL)
                                .put("class", currentClass ?: JSONObject.NULL)
                                .put("file", rel)
                                .put("line", lineIndex + 1).toString())
                            out.newLine()
                            functionOut.writeLong(currentFunctionVa!!.toLong(16))
                            functionOut.writeLong(if (functionSize.startsWith("-")) 0L else functionSize.toLong(16))
                            functionOut.writeUTF(pendingSignature.orEmpty())
                            functionOut.writeUTF(currentClass.orEmpty())
                            functionOut.writeUTF(rel)
                            functionCount++
                        } else if (raw.startsWith("  ") && isFunctionSignature(trimmed)) {
                            pendingSignature = trimmed.trimEnd('{', ' ', ';')
                        }
                        var explicitReference = false
                        REF.findAll(raw).forEach { hit ->
                            explicitReference = true
                            writeSemanticReference(out, hit.groupValues[1], raw, rel, currentFunctionVa, pendingSignature, currentClass, "asm_annotation")
                            referenceCount++
                        }
                        if (!explicitReference) {
                            val ldr = LDR_FROM.find(raw)
                            val pending = pendingPoolAdd
                            if (ldr != null && pending != null && ldr.groupValues[1].equals(pending.first, true)) {
                                val offset = pending.second + parseImmediate(ldr.groupValues[2])
                                writeSemanticReference(out, offset.toString(16), raw, rel, currentFunctionVa, pendingSignature, currentClass, "arm64_add_ldr_fallback")
                                referenceCount++
                            }
                        }
                        valueEvidence(raw, null)?.let { evidence ->
                            out.write(JSONObject(evidence.toString())
                                .put("type", "immediate")
                                .put("functionVa", currentFunctionVa ?: JSONObject.NULL)
                                .put("function", pendingSignature ?: JSONObject.NULL)
                                .put("class", currentClass ?: JSONObject.NULL)
                                .put("file", rel).toString())
                            out.newLine()
                            immediateCount++
                        }
                        currentFunctionVa?.toLongOrNull(16)?.let { functionVa ->
                            fieldSliceCount += advanceFieldSlices(raw, functionVa, activeFieldSlices, fieldSliceOut)
                        }
                        MEMORY_ACCESS.find(raw)?.let { access ->
                            val mnemonic = access.groupValues[2].lowercase()
                            val fieldOffset = parseNumeric(access.groupValues[5]) ?: return@let
                            val functionVa = currentFunctionVa?.toLongOrNull(16) ?: return@let
                            val baseRegister = registerNumber(access.groupValues[4])
                            val dataRegister = registerNumber(access.groupValues[3])
                            if (baseRegister in NON_OBJECT_BASE_REGISTERS) return@let
                            memoryOut.writeLong(access.groupValues[1].toLong(16))
                            memoryOut.writeLong(functionVa)
                            memoryOut.writeLong(fieldOffset)
                            memoryOut.writeBoolean(mnemonic.startsWith("st"))
                            memoryOut.writeByte(baseRegister)
                            memoryOut.writeByte(dataRegister)
                            memoryAccessCount += 1
                            if (!mnemonic.startsWith("st") && dataRegister in 0..30 && fieldOffset in 1..0x4000) {
                                activeFieldSlices += ActiveFieldSlice(
                                    access.groupValues[1].toLong(16),
                                    fieldOffset,
                                    dataRegister,
                                    mutableSetOf(dataRegister),
                                )
                            }
                        }
                        MEMORY_IMMEDIATE.find(raw)?.groupValues?.get(1)?.let(::parseNumeric)?.let { value ->
                            addressingImmediateCounts[value] = (addressingImmediateCounts[value] ?: 0) + 1
                        }
                        pendingPoolAdd = ADD_PP.find(raw)?.let { add ->
                            add.groupValues[1] to (parseImmediate(add.groupValues[2]) shl 12)
                        }
                    }
                }
                scannedFiles++
            }
                addressingImmediateCounts.forEach { (value, count) ->
                    out.write(JSONObject()
                        .put("type", "addressing_immediate")
                        .put("value", value)
                        .put("count", count).toString())
                    out.newLine()
                }
                }
            }
        }
        }
        moveAtomic(tempIndex, index)
        moveAtomic(tempFunctionIndex, functionIndex)
        moveAtomic(tempMemoryIndex, memoryIndex)
        moveAtomic(tempFieldSliceIndex, fieldSliceIndex)
        File(resultDir, "blutter-memory-access-v1.bin").delete()
        val generated = JSONObject()
            .put("version", SEMANTIC_VERSION)
            .put("index", SEMANTIC_INDEX)
            .put("scannedFiles", scannedFiles)
            .put("functions", functionCount)
            .put("references", referenceCount)
            .put("immediates", immediateCount)
            .put("memoryAccesses", memoryAccessCount)
            .put("fieldSliceSinks", fieldSliceCount)
            .put("addressingImmediateValues", addressingImmediateCounts.size)
            .put("functionIndex", FUNCTION_HEADER_INDEX)
            .put("functionIndexBytes", functionIndex.length())
            .put("memoryAccessIndex", MEMORY_ACCESS_INDEX)
            .put("memoryAccessIndexBytes", memoryIndex.length())
            .put("fieldSliceIndex", FIELD_SLICE_INDEX)
            .put("fieldSliceIndexBytes", fieldSliceIndex.length())
            .put("indexBytes", index.length())
            .put("cacheHit", false)
        val tempMeta = File(resultDir, "$SEMANTIC_META.tmp")
        tempMeta.writeText(generated.toString())
        moveAtomic(tempMeta, meta)
        legacyIndex.delete()
        legacyMeta.delete()
        clearSemanticQueryCache(resultDir)
        return generated
    }

    @Synchronized
    internal fun ensureFunctionHeaderIndex(resultDir: File, force: Boolean = false): JSONObject {
        val index = File(resultDir, FUNCTION_HEADER_INDEX)
        if (!force && index.isFile) {
            return JSONObject()
                .put("cacheHit", true)
                .put("functions", functionHeaderCount(resultDir))
                .put("functionIndex", FUNCTION_HEADER_INDEX)
                .put("functionIndexBytes", index.length())
        }
        val asmDir = File(resultDir, "asm")
        require(asmDir.isDirectory) { "ASM_RESULT_NOT_FOUND" }
        val tempIndex = File(resultDir, "$FUNCTION_HEADER_INDEX.tmp")
        var scannedFiles = 0
        var functionCount = 0
        DataOutputStream(BufferedOutputStream(FileOutputStream(tempIndex))).use { out ->
            out.writeInt(FUNCTION_HEADER_INDEX_MAGIC)
            asmDir.walkTopDown().filter { it.isFile && it.extension == "dart" }.forEach { file ->
                val rel = "asm/${file.relativeTo(asmDir).path}"
                var currentClass: String? = null
                var pendingSignature: String? = null
                file.useLines { lines ->
                    lines.forEach { raw ->
                        val trimmed = raw.trim()
                        if (trimmed.startsWith("class ")) currentClass = className(trimmed)
                        val header = FUNC_ADDR.matchEntire(raw)
                        if (header != null) {
                            val rawSize = header.groupValues[2].lowercase()
                            out.writeLong(header.groupValues[1].toLong(16))
                            out.writeLong(if (rawSize.startsWith("-")) 0L else rawSize.toLong(16))
                            out.writeUTF(pendingSignature.orEmpty())
                            out.writeUTF(currentClass.orEmpty())
                            out.writeUTF(rel)
                            functionCount++
                        } else if (raw.startsWith("  ") && isFunctionSignature(trimmed)) {
                            pendingSignature = trimmed.trimEnd('{', ' ', ';')
                        }
                    }
                }
                scannedFiles++
            }
        }
        moveAtomic(tempIndex, index)
        clearSemanticQueryCache(resultDir)
        return JSONObject()
            .put("cacheHit", false)
            .put("scannedFiles", scannedFiles)
            .put("functions", functionCount)
            .put("functionIndex", FUNCTION_HEADER_INDEX)
            .put("functionIndexBytes", index.length())
    }

    private fun moveAtomic(source: File, target: File) {
        runCatching { Files.move(source.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING) }
            .getOrElse { Files.move(source.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING) }
    }

    private fun writeSemanticReference(
        out: java.io.BufferedWriter,
        offset: String,
        raw: String,
        file: String,
        functionVa: String?,
        function: String?,
        clazz: String?,
        mode: String,
    ) {
        val instructionVa = INSN_ADDR.find(raw)?.groupValues?.get(1)?.lowercase()
        out.write(JSONObject()
            .put("type", "reference")
            .put("offset", offset.lowercase())
            .put("va", instructionVa ?: functionVa ?: JSONObject.NULL)
            .put("functionVa", functionVa ?: JSONObject.NULL)
            .put("function", function ?: JSONObject.NULL)
            .put("class", clazz ?: JSONObject.NULL)
            .put("file", file)
            .put("insn", raw.trim().take(300))
            .put("referenceMode", mode).toString())
        out.newLine()
    }

    private fun clearSemanticQueryCache(resultDir: File) {
        val path = resultDir.absoluteFile.normalize().path
        synchronized(this) {
            functionHeaderCache.keys.removeAll { it.path.startsWith(path) }
            arm64FunctionsCache.keys.removeAll { it.path.startsWith(path) }
            asmSearchCache.keys.removeAll { it.path.startsWith(path) }
        }
    }

    private fun ppCacheKey(resultDir: File, query: String): PpCacheKey {
        val pp = File(resultDir, "pp.txt")
        return PpCacheKey(pp.absoluteFile.normalize().path, pp.lastModified(), pp.length(), query)
    }

    /**
     * pp.txt 行遍历：≤PP_CACHE_MAX_BYTES 的文件读为原始字节驻留缓存跨查询复用；
     * 超过上限走流式逐行回调（内存 O(1)）。回调返回 false 提前终止（等价 break）。
     */
    private fun forEachPpLine(resultDir: File, block: (String) -> Boolean) {
        val pp = File(resultDir, "pp.txt")
        val key = PpLinesCacheKey(pp.absoluteFile.normalize().path, pp.lastModified(), pp.length())
        synchronized(this) {
            ppLinesCache[key]?.let { cached ->
                ByteArrayInputStream(cached).bufferedReader().use { reader ->
                    while (true) {
                        val line = reader.readLine() ?: break
                        if (!block(line)) break
                    }
                }
                return
            }
        }
        if (pp.length() <= PP_CACHE_MAX_BYTES) {
            val bytes = pp.readBytes()
            synchronized(this) {
                ppLinesCache[key] = bytes
                ppScanCount++
            }
            ByteArrayInputStream(bytes).bufferedReader().use { reader ->
                while (true) {
                    val line = reader.readLine() ?: break
                    if (!block(line)) break
                }
            }
        } else {
            synchronized(this) { ppScanCount++ }
            pp.bufferedReader().use { reader ->
                while (true) {
                    val line = reader.readLine() ?: break
                    if (!block(line)) break
                }
            }
        }
    }

    /** 流式遍历语义索引：逐行解析逐行回调，不把百万行 JSONL 驻留堆内。 */
    private inline fun forEachSemanticRow(resultDir: File, block: (JSONObject) -> Unit): JSONObject {
        val meta = ensureSemanticIndex(resultDir)
        val index = semanticIndexFile(resultDir)
        val input = if (index.name.endsWith(".gz")) GZIPInputStream(FileInputStream(index)) else FileInputStream(index)
        input.bufferedReader().use { reader ->
            while (true) {
                val raw = reader.readLine() ?: break
                val row = runCatching { JSONObject(raw) }.getOrNull() ?: continue
                block(row)
            }
        }
        return meta
    }

    /** 函数头列表（几千条、极小）允许驻留缓存；disasmFunction 高频调用不再全量扫索引。 */
    private fun functionHeaders(resultDir: File): List<FunctionHeader> {
        val compactIndex = File(resultDir, FUNCTION_HEADER_INDEX)
        if (!compactIndex.isFile && File(resultDir, "asm").isDirectory) ensureFunctionHeaderIndex(resultDir)
        if (compactIndex.isFile) {
            val key = FunctionHeaderCacheKey(compactIndex.absoluteFile.normalize().path, compactIndex.lastModified(), compactIndex.length())
            synchronized(this) { functionHeaderCache[key]?.let { return it } }
            val headers = readFunctionHeaders(compactIndex)
            synchronized(this) { functionHeaderCache[key] = headers }
            return headers
        }
        val index = semanticIndexFile(resultDir)
        val key = FunctionHeaderCacheKey(index.absoluteFile.normalize().path, index.lastModified(), index.length())
        synchronized(this) {
            functionHeaderCache[key]?.let { return it }
        }
        val headers = mutableListOf<FunctionHeader>()
        forEachSemanticRow(resultDir) { row ->
            if (row.optString("type") != "function") return@forEachSemanticRow
            val rawSize = row.optString("size").trim()
            val size = if (rawSize.startsWith("-")) 0L else rawSize.removePrefix("0x").removePrefix("0X").toLongOrNull(16) ?: 0L
            headers += FunctionHeader(
                row.optString("va").toLongOrNull(16) ?: 0L,
                size,
                row.optString("function").takeIf(String::isNotBlank),
                row.optString("class").takeIf(String::isNotBlank),
                row.optString("file"),
            )
        }
        synchronized(this) {
            functionHeaderCache[key] = headers
        }
        return headers
    }

    private fun readFunctionHeaders(index: File): List<FunctionHeader> {
        val headers = mutableListOf<FunctionHeader>()
        DataInputStream(BufferedInputStream(index.inputStream())).use { input ->
            if (input.readInt() != FUNCTION_HEADER_INDEX_MAGIC) return emptyList()
            while (true) {
                try {
                    headers += FunctionHeader(
                        input.readLong(),
                        input.readLong(),
                        input.readUTF().takeIf(String::isNotBlank),
                        input.readUTF().takeIf(String::isNotBlank),
                        input.readUTF(),
                    )
                } catch (_: EOFException) {
                    break
                }
            }
        }
        return headers
    }

    private data class MemoryAccess(
        val instructionVa: Long,
        val functionVa: Long,
        val offset: Long,
        val write: Boolean,
        val baseRegister: Int,
        val dataRegister: Int,
    )

    private data class FieldSliceSink(
        val sourceVa: Long,
        val functionVa: Long,
        val fieldOffset: Long,
        val sinkVa: Long,
        val kind: Int,
        val sourceRegister: Int,
        val value: Long,
    )

    private inline fun forEachMemoryAccess(resultDir: File, block: (MemoryAccess) -> Unit) {
        ensureSemanticIndex(resultDir)
        val index = File(resultDir, MEMORY_ACCESS_INDEX)
        if (!index.isFile) return
        DataInputStream(BufferedInputStream(index.inputStream())).use { input ->
            if (input.readInt() != MEMORY_ACCESS_INDEX_MAGIC) return
            while (true) {
                try {
                    block(MemoryAccess(
                        input.readLong(),
                        input.readLong(),
                        input.readLong(),
                        input.readBoolean(),
                        input.readUnsignedByte(),
                        input.readUnsignedByte(),
                    ))
                } catch (_: EOFException) {
                    break
                }
            }
        }
    }

    private inline fun forEachFieldSlice(resultDir: File, block: (FieldSliceSink) -> Unit) {
        ensureSemanticIndex(resultDir)
        val index = File(resultDir, FIELD_SLICE_INDEX)
        if (!index.isFile) return
        DataInputStream(BufferedInputStream(index.inputStream())).use { input ->
            if (input.readInt() != FIELD_SLICE_INDEX_MAGIC) return
            while (true) {
                try {
                    block(FieldSliceSink(
                        input.readLong(),
                        input.readLong(),
                        input.readLong(),
                        input.readLong(),
                        input.readUnsignedByte(),
                        input.readUnsignedByte(),
                        input.readLong(),
                    ))
                } catch (_: EOFException) {
                    break
                }
            }
        }
    }

    private fun advanceFieldSlices(
        raw: String,
        functionVa: Long,
        active: MutableList<ActiveFieldSlice>,
        out: DataOutputStream,
    ): Int {
        val instruction = ARM64_INSTRUCTION.matchEntire(raw) ?: return 0
        val sinkVa = instruction.groupValues[1].toLongOrNull(16) ?: return 0
        val mnemonic = instruction.groupValues[2].lowercase()
        val operands = instruction.groupValues[3]
        val registers = ARM64_REGISTER.findAll(operands).map { it.groupValues[1].toInt() }.toSet()
        val firstOperand = operands.substringBefore(',').trim()
        val destination = registerNumber(firstOperand).takeIf { it in 0..30 }
        val sourceRegisters = ARM64_REGISTER.findAll(operands.substringAfter(',', ""))
            .map { it.groupValues[1].toInt() }.toSet()
        val immediate = ARM64_IMMEDIATE.find(operands)?.groupValues?.get(1)?.let(::parseNumeric)
        var emitted = 0
        val iterator = active.iterator()
        while (iterator.hasNext()) {
            val slice = iterator.next()
            slice.remaining -= 1
            if (slice.remaining < 0 || slice.registers.isEmpty()) {
                iterator.remove()
                continue
            }
            var terminate = false
            val taintedOperand = registers.any(slice.registers::contains)
            when {
                mnemonic in setOf("cmp", "cmn", "tst") -> {
                    slice.flagsTainted = taintedOperand
                    if (taintedOperand) {
                        writeFieldSlice(out, slice, functionVa, sinkVa, SLICE_COMPARISON, immediate)
                        emitted++
                    }
                }
                mnemonic in setOf("cbz", "cbnz", "tbz", "tbnz") -> {
                    if (registerNumber(firstOperand) in slice.registers) {
                        writeFieldSlice(out, slice, functionVa, sinkVa, SLICE_DIRECT_BRANCH, immediate)
                        emitted++
                        terminate = true
                    }
                }
                mnemonic.startsWith("b.") -> {
                    if (slice.flagsTainted) {
                        writeFieldSlice(out, slice, functionVa, sinkVa, SLICE_FLAGS_BRANCH, null)
                        emitted++
                        terminate = true
                    }
                }
                mnemonic == "ret" -> {
                    if (0 in slice.registers) {
                        writeFieldSlice(out, slice, functionVa, sinkVa, SLICE_RETURN, null)
                        emitted++
                    }
                    terminate = true
                }
                mnemonic == "b" || mnemonic == "br" -> terminate = true
                mnemonic == "bl" || mnemonic == "blr" -> {
                    if (slice.registers.any { it in 0..7 }) {
                        writeFieldSlice(out, slice, functionVa, sinkVa, SLICE_CALL_ARGUMENT, null)
                        emitted++
                    }
                    slice.registers.removeAll(0..18)
                }
                destination != null && instructionWritesDestination(mnemonic) -> {
                    val flagsDerived = slice.flagsTainted && (mnemonic == "cset" || mnemonic.startsWith("cs"))
                    val registerDerived = sourceRegisters.any(slice.registers::contains)
                    slice.registers.remove(destination)
                    if (flagsDerived || registerDerived) slice.registers.add(destination)
                    if (flagsDerived) {
                        writeFieldSlice(out, slice, functionVa, sinkVa, SLICE_BOOLEAN_RESULT, null)
                        emitted++
                    }
                    if (mnemonic in setOf("adds", "subs", "ands")) {
                        slice.flagsTainted = registerDerived
                    }
                }
            }
            if (terminate || slice.registers.isEmpty()) iterator.remove()
        }
        return emitted
    }

    private fun instructionWritesDestination(mnemonic: String): Boolean =
        !mnemonic.startsWith("st") && mnemonic !in setOf(
            "cmp", "cmn", "tst", "cbz", "cbnz", "tbz", "tbnz",
            "b", "br", "bl", "blr", "ret", "nop", "prfm",
        ) && !mnemonic.startsWith("b.")

    private fun writeFieldSlice(
        out: DataOutputStream,
        slice: ActiveFieldSlice,
        functionVa: Long,
        sinkVa: Long,
        kind: Int,
        value: Long?,
    ) {
        out.writeLong(slice.sourceVa)
        out.writeLong(functionVa)
        out.writeLong(slice.fieldOffset)
        out.writeLong(sinkVa)
        out.writeByte(kind)
        out.writeByte(slice.sourceRegister)
        out.writeLong(value ?: NO_SLICE_VALUE)
    }

    private fun fieldSliceKind(kind: Int): String = when (kind) {
        SLICE_COMPARISON -> "comparison"
        SLICE_DIRECT_BRANCH -> "direct_conditional_branch"
        SLICE_FLAGS_BRANCH -> "flags_conditional_branch"
        SLICE_BOOLEAN_RESULT -> "boolean_result"
        SLICE_RETURN -> "return"
        SLICE_CALL_ARGUMENT -> "call_argument"
        else -> "unknown"
    }

    private fun semanticIndexFile(resultDir: File): File {
        val current = File(resultDir, SEMANTIC_INDEX)
        if (current.isFile) return current
        return File(resultDir, LEGACY_SEMANTIC_INDEX)
    }

    private inline fun forEachFunctionHeaderRow(
        resultDir: File,
        block: (addr: Long, size: Long, name: String?, className: String?, file: String) -> Unit,
    ) {
        functionHeaders(resultDir).forEach { block(it.va, it.size, it.name, it.className, it.file) }
    }

    internal fun isFunctionSignature(line: String): Boolean {
        if (line.startsWith("//") || line.startsWith("class ")) return false
        val open = line.indexOf('(')
        return open > 0 && line.indexOf(')', open) > open && (line.endsWith("{") || line.endsWith(";"))
    }

    fun rawStringSearch(bytes: ByteArray, queries: List<String>, limit: Int): JSONObject {
        val started = System.nanoTime()
        val needles = queries.map(String::trim).filter(String::isNotEmpty).distinctBy(String::lowercase)
        val matches = JSONArray()
        var start = -1
        fun inspect(end: Int) {
            if (start < 0 || end - start < 3 || matches.length() >= limit) return
            val text = runCatching { String(bytes, start, end - start, Charsets.UTF_8) }.getOrNull()?.trim().orEmpty()
            if (text.isEmpty() || text.contains('\uFFFD')) return
            val matched = needles.filter { containsTerm(text, it) }
            if (matched.isEmpty()) return
            matches.put(JSONObject().put("fileOffset", "0x${start.toString(16)}").put("text", text.take(300)).put("matchedTerms", JSONArray(matched)))
        }
        for (index in bytes.indices) {
            val value = bytes[index].toInt() and 0xff
            val printable = value in 0x20..0x7e || value >= 0x80
            if (printable) {
                if (start < 0) start = index
                if (index - start >= 1024) {
                    inspect(index)
                    start = index
                }
            } else if (start >= 0) {
                inspect(index)
                start = -1
                if (matches.length() >= limit) break
            }
        }
        if (matches.length() < limit) inspect(bytes.size)
        return JSONObject().put("queries", JSONArray(needles)).put("matches", matches).put("count", matches.length()).put("scannedBytes", bytes.size).put("elapsedMs", (System.nanoTime() - started) / 1_000_000).put("source", "libapp.so raw UTF-8 strings")
    }

    /**
     * 直接扫描 libapp.so，覆盖 Blutter asm 未写 pp 注释时的 ARM64 取池引用。
     * 指令模式对齐 PPTool（github.com/Kirlif/PPTool, Apache-2.0）Instruct64 的三条路径：
     *  ① 单指令 ldr xN, [x27, #imm*scale] —— 池前 32KB 直接寻址，无需 add 指令对
     *  ② add xN, x27, #hi[, lsl #12] + 1..6 条内 ldr [xN, #imm*scale]（6 种 load 宽度）
     *  ③ 双 add 拆分：add xN, x27, #hi + add xM, xN, #lo + ldr [xM]（低位非 8 对齐时）
     * 目标寄存器走 PPTool 白名单（x15/x18/x21/x22/x26/x28/x29 为 Dart/平台保留，不作出址目标）。
     */
    fun buildArm64PoolIndex(libapp: ByteArray, resultDir: File) {
        val executableRanges = arm64ExecutableRanges(libapp)
        DataOutputStream(BufferedOutputStream(File(resultDir, ARM64_POOL_INDEX_V2).outputStream())).use { out ->
            DataOutputStream(BufferedOutputStream(File(resultDir, ARM64_CLOSURE_CALL_INDEX).outputStream())).use { calls ->
            out.writeInt(ARM64_POOL_INDEX_MAGIC)
            calls.writeInt(ARM64_CLOSURE_CALL_INDEX_MAGIC)
            executableRanges.forEach { range ->
                var offset = range.fileOffset
                while (offset + 28 <= range.fileEnd) {
                    val word = arm64Word(libapp, offset)
                    val va = range.virtualAddress + offset - range.fileOffset
                    // ① 单指令 ldr xN, [x27, #imm]：基址就是 PP(x27)
                    ldrPoolScale(word, 27)?.let { scale ->
                        val rd = word and 31
                        if (validPoolTarget(rd)) {
                            val poolOffset = ((word ushr 10) and 0xfff).toLong() * scale
                            writeRawPoolReference(out, poolOffset, va, offset, 1)
                        }
                    }
                    // ①-LDP：ldp xRt, xRt2, [x27, #imm*8]（PPTool 未覆盖，Dart AOT
                    // 闭包+代码对的成对池加载——xref 对闭包槽 0x21ad0/0x21ad8 落空的根因）。
                    ldpPoolPair(word, 27)?.let { (rt, rt2, scale) ->
                        // LDP 的 imm7 在 bit21:15（不是 LDR 的 imm12 位置）
                        val poolBase = ldpPoolOffset(word, scale)
                        if (validPoolTarget(rt)) {
                            writeRawPoolReference(out, poolBase, va, offset, 4)
                        }
                        if (validPoolTarget(rt2)) {
                            writeRawPoolReference(out, poolBase + 8, va, offset, 4)
                        }
                        findBlrAfter(libapp, offset, rt, rt2)?.let { (callOffset, targetRegister) ->
                            val callVa = va + callOffset - offset
                            writeRawClosureCall(calls, poolBase, va, callVa, offset, callOffset, targetRegister, 4)
                            writeRawClosureCall(calls, poolBase + 8, va, callVa, offset, callOffset, targetRegister, 4)
                        }
                    }
                    // ②/③ add xN, x27, #hi[, lsl #12] 路径（PPTool 仅匹配 64 位 sf=1 编码）
                    val baseRegister = (word ushr 5) and 31
                    if ((word and 0xff000000.toInt()) == 0x91000000.toInt() && baseRegister == 27 && validPoolTarget(word and 31)) {
                        val targetRegister = word and 31
                        val high = ((word ushr 10) and 0xfff).toLong() shl if ((word and 0x00400000) != 0) 12 else 0
                        var secondAddLow = -1L
                        var secondAddReg = -1
                        for (step in 1..6) {
                            val next = arm64Word(libapp, offset + step * 4)
                            ldpPoolPair(next, targetRegister)?.takeIf { secondAddLow < 0 }?.let { (rt, rt2, scale) ->
                                val loadOffset = offset + step * 4
                                val loadVa = va + step * 4
                                val poolBase = high + ldpPoolOffset(next, scale)
                                if (validPoolTarget(rt)) writeRawPoolReference(out, poolBase, loadVa, loadOffset, 5)
                                if (validPoolTarget(rt2)) writeRawPoolReference(out, poolBase + 8, loadVa, loadOffset, 5)
                                findBlrAfter(libapp, loadOffset, rt, rt2)?.let { (callOffset, targetRegister) ->
                                    val callVa = va + callOffset - offset
                                    writeRawClosureCall(calls, poolBase, loadVa, callVa, loadOffset, callOffset, targetRegister, 5)
                                    writeRawClosureCall(calls, poolBase + 8, loadVa, callVa, loadOffset, callOffset, targetRegister, 5)
                                }
                                return@let
                            }
                            if (secondAddLow < 0 && ldpPoolPair(next, targetRegister) != null) break
                            // ② 紧随的 ldr [targetRegister, #imm*scale]
                            val directScale = ldrPoolScale(next, targetRegister)
                            if (directScale != null) {
                                val poolOffset = high + (((next ushr 10) and 0xfff).toLong() * directScale)
                                writeRawPoolReference(out, poolOffset, va, offset, 2)
                                break
                            }
                            // ③ 双 add 拆分：add xM, xN, #lo（64 位无 shift）记忆，等后续 ldr [xM]
                            if (secondAddLow < 0 && (next and 0xff000000.toInt()) == 0x91000000.toInt() &&
                                ((next ushr 5) and 31) == targetRegister && (next and 0x00400000) == 0) {
                                secondAddLow = ((next ushr 10) and 0xfff).toLong()
                                secondAddReg = next and 31
                                continue
                            }
                            if (secondAddLow >= 0) {
                                ldpPoolPair(next, secondAddReg)?.let { (rt, rt2, scale) ->
                                    val loadOffset = offset + step * 4
                                    val loadVa = va + step * 4
                                    val poolBase = high + secondAddLow + ldpPoolOffset(next, scale)
                                    if (validPoolTarget(rt)) writeRawPoolReference(out, poolBase, loadVa, loadOffset, 5)
                                    if (validPoolTarget(rt2)) writeRawPoolReference(out, poolBase + 8, loadVa, loadOffset, 5)
                                    findBlrAfter(libapp, loadOffset, rt, rt2)?.let { (callOffset, targetRegister) ->
                                        val callVa = va + callOffset - offset
                                        writeRawClosureCall(calls, poolBase, loadVa, callVa, loadOffset, callOffset, targetRegister, 5)
                                        writeRawClosureCall(calls, poolBase + 8, loadVa, callVa, loadOffset, callOffset, targetRegister, 5)
                                    }
                                    return@let
                                }
                                if (ldpPoolPair(next, secondAddReg) != null) break
                                val followScale = ldrPoolScale(next, secondAddReg)
                                if (followScale != null) {
                                    val poolOffset = high + secondAddLow + (((next ushr 10) and 0xfff).toLong() * followScale)
                                    writeRawPoolReference(out, poolOffset, va, offset, 3)
                                    break
                                }
                            }
                        }
                    }
                    offset += 4
                }
            }
            }
        }
        File(resultDir, ARM64_POOL_INDEX).delete()
        File(resultDir, ARM64_FUNCTION_INDEX).bufferedWriter().use { out ->
            executableRanges.forEach { range ->
                var offset = range.fileOffset
                while (offset + 4 <= range.fileEnd) {
                    if (isArm64FramePrologue(arm64Word(libapp, offset))) {
                        val va = range.virtualAddress + offset - range.fileOffset
                        out.write(JSONObject().put("va", va.toString(16)).put("mode", "arm64_frame_prologue").toString())
                        out.newLine()
                    }
                    offset += 4
                }
            }
        }
    }

    /** 大型 libapp.so 的分块扫描版本，避免为整份库分配连续大数组。 */
    fun buildArm64PoolIndex(libapp: File, resultDir: File) {
        val ranges = arm64ExecutableRanges(libapp)
        val chunkSize = 1024 * 1024
        RandomAccessFile(libapp, "r").use { input ->
            DataOutputStream(BufferedOutputStream(File(resultDir, ARM64_POOL_INDEX_V2).outputStream())).use { out ->
                DataOutputStream(BufferedOutputStream(File(resultDir, ARM64_CLOSURE_CALL_INDEX).outputStream())).use { calls ->
                out.writeInt(ARM64_POOL_INDEX_MAGIC)
                calls.writeInt(ARM64_CLOSURE_CALL_INDEX_MAGIC)
                    ranges.forEach { range ->
                        var chunkStart = range.fileOffset
                        while (chunkStart < range.fileEnd) {
                            val scanEnd = minOf(chunkStart + chunkSize, range.fileEnd)
                            val readEnd = minOf(scanEnd + 64, range.fileEnd)
                            val bytes = ByteArray(readEnd - chunkStart)
                            input.seek(chunkStart.toLong())
                            input.readFully(bytes)
                            var offset = 0
                            val scanBytes = scanEnd - chunkStart
                            while (offset + 4 <= scanBytes && offset + 28 <= bytes.size) {
                                val word = arm64Word(bytes, offset)
                                val fileOffset = chunkStart + offset
                                val va = range.virtualAddress + fileOffset - range.fileOffset
                                ldrPoolScale(word, 27)?.let { scale ->
                                    val rd = word and 31
                                    if (validPoolTarget(rd)) writeRawPoolReference(out, ((word ushr 10) and 0xfff).toLong() * scale, va, fileOffset, 1)
                                }
                                ldpPoolPair(word, 27)?.let { (rt, rt2, scale) ->
                                    val poolBase = ldpPoolOffset(word, scale)
                                    if (validPoolTarget(rt)) writeRawPoolReference(out, poolBase, va, fileOffset, 4)
                                    if (validPoolTarget(rt2)) writeRawPoolReference(out, poolBase + 8, va, fileOffset, 4)
                                    findBlrAfter(bytes, offset, rt, rt2)?.let { (callOffset, targetRegister) ->
                                        val absoluteCallOffset = fileOffset + callOffset - offset
                                        val callVa = va + callOffset - offset
                                        writeRawClosureCall(calls, poolBase, va, callVa, fileOffset, absoluteCallOffset, targetRegister, 4)
                                        writeRawClosureCall(calls, poolBase + 8, va, callVa, fileOffset, absoluteCallOffset, targetRegister, 4)
                                    }
                                }
                                val baseRegister = (word ushr 5) and 31
                                if ((word and 0xff000000.toInt()) == 0x91000000.toInt() && baseRegister == 27 && validPoolTarget(word and 31)) {
                                    val targetRegister = word and 31
                                    val high = ((word ushr 10) and 0xfff).toLong() shl if ((word and 0x00400000) != 0) 12 else 0
                                    var secondAddLow = -1L
                                    var secondAddReg = -1
                                    for (step in 1..6) {
                                        val next = arm64Word(bytes, offset + step * 4)
                                        ldpPoolPair(next, targetRegister)?.takeIf { secondAddLow < 0 }?.let { (rt, rt2, scale) ->
                                            val loadOffset = offset + step * 4
                                            val loadFileOffset = fileOffset + step * 4
                                            val loadVa = va + step * 4
                                            val poolBase = high + ldpPoolOffset(next, scale)
                                            if (validPoolTarget(rt)) writeRawPoolReference(out, poolBase, loadVa, loadFileOffset, 5)
                                            if (validPoolTarget(rt2)) writeRawPoolReference(out, poolBase + 8, loadVa, loadFileOffset, 5)
                                            findBlrAfter(bytes, loadOffset, rt, rt2)?.let { (callOffset, targetRegister) ->
                                                val absoluteCallOffset = fileOffset + callOffset - offset
                                                val callVa = va + callOffset - offset
                                                writeRawClosureCall(calls, poolBase, loadVa, callVa, loadFileOffset, absoluteCallOffset, targetRegister, 5)
                                                writeRawClosureCall(calls, poolBase + 8, loadVa, callVa, loadFileOffset, absoluteCallOffset, targetRegister, 5)
                                            }
                                            return@let
                                        }
                                        if (secondAddLow < 0 && ldpPoolPair(next, targetRegister) != null) break
                                        val directScale = ldrPoolScale(next, targetRegister)
                                        if (directScale != null) {
                                            writeRawPoolReference(out, high + (((next ushr 10) and 0xfff).toLong() * directScale), va, fileOffset, 2)
                                            break
                                        }
                                        if (secondAddLow < 0 && (next and 0xff000000.toInt()) == 0x91000000.toInt() && ((next ushr 5) and 31) == targetRegister && (next and 0x00400000) == 0) {
                                            secondAddLow = ((next ushr 10) and 0xfff).toLong()
                                            secondAddReg = next and 31
                                            continue
                                        }
                                        if (secondAddLow >= 0) {
                                            ldpPoolPair(next, secondAddReg)?.let { (rt, rt2, scale) ->
                                                val loadOffset = offset + step * 4
                                                val loadFileOffset = fileOffset + step * 4
                                                val loadVa = va + step * 4
                                                val poolBase = high + secondAddLow + ldpPoolOffset(next, scale)
                                                if (validPoolTarget(rt)) writeRawPoolReference(out, poolBase, loadVa, loadFileOffset, 5)
                                                if (validPoolTarget(rt2)) writeRawPoolReference(out, poolBase + 8, loadVa, loadFileOffset, 5)
                                                findBlrAfter(bytes, loadOffset, rt, rt2)?.let { (callOffset, targetRegister) ->
                                                    val absoluteCallOffset = fileOffset + callOffset - offset
                                                    val callVa = va + callOffset - offset
                                                    writeRawClosureCall(calls, poolBase, loadVa, callVa, loadFileOffset, absoluteCallOffset, targetRegister, 5)
                                                    writeRawClosureCall(calls, poolBase + 8, loadVa, callVa, loadFileOffset, absoluteCallOffset, targetRegister, 5)
                                                }
                                                return@let
                                            }
                                            if (ldpPoolPair(next, secondAddReg) != null) break
                                            val followScale = ldrPoolScale(next, secondAddReg)
                                            if (followScale != null) {
                                                writeRawPoolReference(out, high + secondAddLow + (((next ushr 10) and 0xfff).toLong() * followScale), va, fileOffset, 3)
                                                break
                                            }
                                        }
                                    }
                                }
                                offset += 4
                            }
                            chunkStart = scanEnd
                        }
                }
                }
            }
        }
        File(resultDir, ARM64_POOL_INDEX).delete()
        File(resultDir, ARM64_FUNCTION_INDEX).bufferedWriter().use { functions ->
            RandomAccessFile(libapp, "r").use { input ->
                val bytes = ByteArray(chunkSize)
                ranges.forEach { range ->
                    var chunkStart = range.fileOffset
                    while (chunkStart < range.fileEnd) {
                        val count = minOf(bytes.size, range.fileEnd - chunkStart)
                        input.seek(chunkStart.toLong())
                        input.readFully(bytes, 0, count)
                        var offset = 0
                        while (offset + 4 <= count) {
                            if (isArm64FramePrologue(arm64Word(bytes, offset))) {
                                val va = range.virtualAddress + chunkStart + offset - range.fileOffset
                                functions.write(JSONObject().put("va", va.toString(16)).put("mode", "arm64_frame_prologue").toString())
                                functions.newLine()
                            }
                            offset += 4
                        }
                        chunkStart += count
                    }
                }
            }
        }
    }

    /** LDP (immediate signed offset, 64-bit)：ldp xRt, xRt2, [base, #imm*8]。返回 (Rt, Rt2, scale=8) 或 null。 */
    private fun ldpPoolPair(word: Int, base: Int): Triple<Int, Int, Long>? {
        // 64-bit LDP 立即数偏移家族：基掩码 0x7FC00000 取 (opc=10, 101 0010, L=1)
        // → 0x29400000；屏蔽符号位 bit31（0x7F 高字节=0x29 来自 0xA9 & 0x7F）。
        if ((word and 0x7fc00000.toInt()) != 0x29400000.toInt()) return null
        if (((word ushr 5) and 31) != base) return null
        val loadStore = (word ushr 22) and 1 // L=1 为加载（已含在 0x29 高位）
        if (loadStore != 1) return null
        val rt = word and 31
        val rt2 = (word ushr 10) and 31
        return Triple(rt, rt2, 8L)
    }

    private fun ldpPoolOffset(word: Int, scale: Long): Long {
        val imm7 = (word ushr 15) and 0x7f
        return (if (imm7 and 0x40 != 0) imm7 - 0x80 else imm7).toLong() * scale
    }

    /** LDR (immediate, unsigned offset) 家族：按基址寄存器过滤，返回寻址 scale（字节宽度），非本家族返回 null。PPTool 全宽度对齐。 */
    private fun ldrPoolScale(word: Int, base: Int): Long? {
        if (((word ushr 5) and 31) != base) return null
        return when (word and 0xffc00000.toInt()) {
            0xf9400000.toInt() -> 8L  // ldr x
            0xfd400000.toInt() -> 8L  // ldr d
            0xb9400000.toInt() -> 4L  // ldr w
            0xbd400000.toInt() -> 4L  // ldr s
            0x79400000.toInt() -> 2L  // ldrh
            0x39400000.toInt() -> 1L  // ldrb
            0x3dc00000 -> 16L         // ldr q（128 位）
            else -> null
        }
    }

    /** PPTool 同款出址目标白名单：x0-x14, x16,x17,x19,x20,x23,x24,x25,x30。 */
    private fun validPoolTarget(reg: Int): Boolean =
        reg in 0..14 || reg == 16 || reg == 17 || reg == 19 || reg == 20 || reg == 23 || reg == 24 || reg == 25 || reg == 30

    private fun findBlrAfter(bytes: ByteArray, ldpOffset: Int, firstRegister: Int, secondRegister: Int): Pair<Int, Int>? {
        for (step in 1..16) {
            val offset = ldpOffset + step * 4
            if (offset + 4 > bytes.size) break
            val register = blrRegister(arm64Word(bytes, offset)) ?: continue
            if (register == firstRegister || register == secondRegister) return offset to register
        }
        return null
    }

    private fun blrRegister(word: Int): Int? =
        if ((word and 0xfffffc1f.toInt()) == 0xd63f0000.toInt()) (word ushr 5) and 31 else null

    private fun writeRawPoolReference(
        out: DataOutputStream,
        poolOffset: Long,
        va: Long,
        fileOffset: Int,
        mode: Int,
    ) {
        out.writeLong(poolOffset)
        out.writeLong(va)
        out.writeInt(fileOffset)
        out.writeByte(mode)
    }

    private fun writeRawClosureCall(
        out: DataOutputStream,
        poolOffset: Long,
        loadVa: Long,
        callVa: Long,
        loadFileOffset: Int,
        callFileOffset: Int,
        targetRegister: Int,
        mode: Int,
    ) {
        out.writeLong(poolOffset)
        out.writeLong(loadVa)
        out.writeLong(callVa)
        out.writeInt(loadFileOffset)
        out.writeInt(callFileOffset)
        out.writeByte(targetRegister)
        out.writeByte(mode)
    }

    private data class RawPoolReference(
        val poolOffset: Long,
        val va: Long,
        val fileOffset: Int,
        val mode: String,
    )

    private data class RawClosureCall(
        val poolOffset: Long,
        val loadVa: Long,
        val callVa: Long,
        val loadFileOffset: Int,
        val callFileOffset: Int,
        val targetRegister: Int,
        val mode: Int,
    )

    private fun forEachRawClosureCall(resultDir: File, block: (RawClosureCall) -> Unit) {
        val binary = File(resultDir, ARM64_CLOSURE_CALL_INDEX)
        if (!binary.isFile) return
        DataInputStream(BufferedInputStream(binary.inputStream())).use { input ->
            if (input.readInt() != ARM64_CLOSURE_CALL_INDEX_MAGIC) return
            while (true) {
                val row = try {
                    RawClosureCall(
                        input.readLong(), input.readLong(), input.readLong(),
                        input.readInt(), input.readInt(), input.readUnsignedByte(), input.readUnsignedByte(),
                    )
                } catch (_: EOFException) {
                    break
                }
                block(row)
            }
        }
    }

    private fun forEachRawPoolReference(resultDir: File, block: (RawPoolReference) -> Unit) {
        val binary = File(resultDir, ARM64_POOL_INDEX_V2)
        if (binary.isFile) {
            DataInputStream(BufferedInputStream(binary.inputStream())).use { input ->
                if (input.readInt() != ARM64_POOL_INDEX_MAGIC) return
                while (true) {
                    val row = try {
                        RawPoolReference(
                            input.readLong(),
                            input.readLong(),
                            input.readInt(),
                            when (input.readUnsignedByte()) {
                                1 -> "arm64_raw_ldr_pp"
                                2 -> "arm64_raw_add_ldr"
                                3 -> "arm64_raw_add_add_ldr"
                                4 -> "arm64_raw_ldp_pp"
                                5 -> "arm64_raw_add_ldp_pp"
                                else -> "arm64_raw_unknown"
                            },
                        )
                    } catch (_: EOFException) {
                        break
                    }
                    block(row)
                }
            }
            return
        }
        val legacy = File(resultDir, ARM64_POOL_INDEX)
        if (!legacy.isFile) return
        legacy.forEachLine { line ->
            val row = runCatching { JSONObject(line) }.getOrNull() ?: return@forEachLine
            val poolOffset = row.optString("offset").toLongOrNull(16) ?: return@forEachLine
            val va = row.optString("va").toLongOrNull(16) ?: return@forEachLine
            val fileOffset = row.optString("fileOffset").toIntOrNull(16) ?: return@forEachLine
            block(RawPoolReference(poolOffset, va, fileOffset, row.optString("mode")))
        }
    }

    fun searchPp(resultDir: File, query: String, caseInsensitive: Boolean, limit: Int): JSONObject {
        val queries = searchQueries(query, caseInsensitive)
        val cacheKey = ppCacheKey(resultDir, "search:${queries.joinToString("|")}:$caseInsensitive:$limit")
        synchronized(this) { ppSearchCache[cacheKey]?.let { return JSONObject(it.toString()) } }
        val matches = JSONArray()
        var truncated = false
        // 倒排快路径：所有查询串的词元都可精确索引时，只复核候选行。
        val fastLoaded = if (caseInsensitive) PpPostings.get(resultDir) else null
        val fastIds = fastLoaded?.let { loaded ->
            val termGroups = queries.map { it.trim().lowercase().split(Regex("\\s+")) }
            PpPostings.candidateIdsForAny(loaded, termGroups)
        }
        if (fastIds != null) {
            for (id in fastIds) {
                val raw = PpPostings.readLine(fastLoaded!!, id) ?: continue
                val matchedQueries = queries.filter { contains(raw, it, caseInsensitive) }
                if (matchedQueries.isEmpty()) continue
                if (matches.length() >= limit) { truncated = true; break }
                val offset = PP_OFFSET.find(raw)?.groupValues?.get(1)
                matches.put(JSONObject()
                    .put("offset", offset?.let { "0x${it.lowercase()}" } ?: JSONObject.NULL)
                    .put("matchedQueries", JSONArray(matchedQueries))
                    .put("text", raw.trim().take(300)))
            }
            val resultF = JSONObject().put("queries", JSONArray(queries)).put("matches", matches)
                .put("count", matches.length()).put("truncated", truncated)
                .put("fastPath", true)
            synchronized(this) { ppSearchCache[cacheKey] = JSONObject(resultF.toString()) }
            return resultF
        }
        forEachPpLine(resultDir) { raw ->
            val matchedQueries = queries.filter { contains(raw, it, caseInsensitive) }
            if (matchedQueries.isEmpty()) return@forEachPpLine true
            if (matches.length() >= limit) {
                truncated = true
                return@forEachPpLine false
            }
            val offset = PP_OFFSET.find(raw)?.groupValues?.get(1)
            matches.put(JSONObject()
                .put("offset", offset?.let { "0x${it.lowercase()}" } ?: JSONObject.NULL)
                .put("matchedQueries", JSONArray(matchedQueries))
                .put("text", raw.trim().take(300)))
            true
        }
        val result = JSONObject().put("queries", JSONArray(queries)).put("matches", matches)
            .put("count", matches.length()).put("truncated", truncated)
        synchronized(this) { ppSearchCache[cacheKey] = JSONObject(result.toString()) }
        return result
    }

    /** locate 首轮同时完成业务体系统计与池项排名，pp.txt 只读一次。 */
    fun profileAndLocatePp(
        resultDir: File,
        groups: List<PpFeatureGroup>,
        primaryQueries: List<String>,
        fallbackQueries: List<String>,
        limit: Int,
        excludedGroupId: String? = null,
        sampleLimit: Int = 6,
    ): JSONObject {
        data class Term(val value: String, val lower: String)
        data class State(
            var hits: Int = 0,
            val termCounts: LinkedHashMap<String, Int> = linkedMapOf(),
            val samples: MutableList<PpCandidate> = mutableListOf(),
        )
        data class Row(
            val offset: String,
            val text: String,
            val lower: String,
            val matchedTerms: Set<String>,
        )

        val normalized = groups.associateWith { group ->
            group.keywords.map(String::trim).filter(String::isNotEmpty)
                .distinctBy(String::lowercase).map { Term(it, it.lowercase()) }
        }
        // 预计算全部词条的小写形式：原实现每行对每个词条调 lowercase()，
        // 百万行 × 数百词条 = 上亿次字符串分配（GC 风暴），这是体系判断慢的根源
        val allTermList = (groups.flatMap(PpFeatureGroup::keywords) + primaryQueries + fallbackQueries)
            .map(String::trim).filter(String::isNotEmpty).distinctBy(String::lowercase)
            .map { Term(it, it.lowercase()) }
        val allTermPrefilter = anyOfRegex(allTermList.map(Term::lower), ignoreCase = true)
        val cacheQuery = buildString {
            append("pipeline:")
            append(groups.joinToString("|") { group ->
                "${group.id}:${group.weight}:${group.keywords.joinToString(",")}"
            })
            append(":primary=").append(primaryQueries.joinToString("|"))
            append(":fallback=").append(fallbackQueries.joinToString("|"))
            append(":exclude=").append(excludedGroupId)
            append(":limit=").append(limit).append(":sample=").append(sampleLimit)
        }
        val cacheKey = ppCacheKey(resultDir, cacheQuery)
        synchronized(this) {
            ppLocatePipelineCache[cacheKey]?.let {
                return JSONObject(it.toString()).put("cacheHit", true).put("scanElapsedMs", 0)
            }
        }

        val states = groups.associateWith { State() }
        val rows = mutableListOf<Row>()
        var scanned = 0L
        val started = System.nanoTime()
        // 倒排快路径：全部词条可精确索引时仅复核候选行，逐行逻辑与旧路径一致。
        val plFastLoaded = PpPostings.get(resultDir)
        val plFastIds = plFastLoaded?.let { PpPostings.candidateIds(it, allTermList.map(Term::lower)) }
        if (plFastIds != null) {
            for (id in plFastIds) {
                val raw = PpPostings.readLine(plFastLoaded!!, id) ?: continue
                scanned++
                val offset = PP_OFFSET.find(raw)?.groupValues?.get(1)?.lowercase() ?: continue
                val lower = raw.lowercase()
                val matchedAll = allTermList.filter { term ->
                    lower.contains(term.lower) && containsTerm(raw, term.value)
                }.mapTo(linkedSetOf(), Term::lower)
                if (matchedAll.isEmpty()) continue
                rows += Row(offset, raw.trim().take(300), lower, matchedAll)
                groups.forEach { group ->
                    val matched = normalized.getValue(group).filter { term -> term.lower in matchedAll }
                    if (matched.isEmpty()) return@forEach
                    val state = states.getValue(group)
                    state.hits++
                    matched.forEach { term ->
                        state.termCounts[term.value] = (state.termCounts[term.value] ?: 0) + 1
                    }
                    val specificity = matched.sumOf { it.value.length.coerceAtMost(24) * 3 }
                    val score = group.weight + matched.size * 100 + specificity +
                        if (lower.contains("string:")) 20 else 0
                    state.samples += PpCandidate(offset, raw.trim().take(300), matched.map(Term::value), score)
                    state.samples.sortWith(compareByDescending<PpCandidate> { it.score }
                        .thenBy { it.offset.toLongOrNull(16) ?: Long.MAX_VALUE })
                    if (state.samples.size > sampleLimit) state.samples.removeLast()
                }
            }
        } else forEachPpLine(resultDir) { raw ->
                scanned++
                val offset = PP_OFFSET.find(raw)?.groupValues?.get(1)?.lowercase() ?: return@forEachPpLine true
                // 行级预筛：整行不含任何词条即跳过（正则无命中 => 无词出现，超集安全）
                if (allTermPrefilter != null && !allTermPrefilter.containsMatchIn(raw)) return@forEachPpLine true
                val lower = raw.lowercase()
                val matchedAll = allTermList.filter { term ->
                    lower.contains(term.lower) && containsTerm(raw, term.value)
                }.mapTo(linkedSetOf(), Term::lower)
                if (matchedAll.isNotEmpty()) {
                    rows += Row(offset, raw.trim().take(300), lower, matchedAll)
                }
                groups.forEach { group ->
                    val matched = normalized.getValue(group).filter { term ->
                        term.lower in matchedAll
                    }
                    if (matched.isEmpty()) return@forEach
                    val state = states.getValue(group)
                    state.hits++
                    matched.forEach { term ->
                        state.termCounts[term.value] = (state.termCounts[term.value] ?: 0) + 1
                    }
                    val specificity = matched.sumOf { it.value.length.coerceAtMost(24) * 3 }
                    val score = group.weight + matched.size * 100 + specificity +
                        if (lower.contains("string:")) 20 else 0
                    state.samples += PpCandidate(offset, raw.trim().take(300), matched.map(Term::value), score)
                    state.samples.sortWith(compareByDescending<PpCandidate> { it.score }
                        .thenBy { it.offset.toLongOrNull(16) ?: Long.MAX_VALUE })
                    if (state.samples.size > sampleLimit) state.samples.removeLast()
                }
                true
        }

        val systems = groups.map { group ->
            val state = states.getValue(group)
            val uniqueTerms = state.termCounts.size
            val evidenceScore = group.weight + state.hits.coerceAtMost(20) * 5 + uniqueTerms * 15
            val matchedKeywords = normalized.getValue(group).map(Term::value).filter(state.termCounts::containsKey)
            JSONObject()
                .put("id", group.id)
                .put("label", group.label)
                .put("hitCount", state.hits)
                .put("uniqueKeywordCount", uniqueTerms)
                .put("evidenceScore", if (state.hits == 0) 0 else evidenceScore)
                .put("matchedKeywords", JSONArray(matchedKeywords))
                .put("keywordCounts", JSONObject(state.termCounts as Map<*, *>))
                .put("samples", JSONArray(state.samples.map { candidate ->
                    JSONObject().put("offset", "0x${candidate.offset}").put("text", candidate.text)
                        .put("matchedTerms", JSONArray(candidate.matchedTerms)).put("score", candidate.score)
                }))
        }.filter { it.optInt("hitCount") > 0 }
            .sortedWith(compareByDescending<JSONObject> { it.optInt("evidenceScore") }
                .thenByDescending { it.optInt("hitCount") })
        val selected = systems.firstOrNull()
        val runnerUp = systems.getOrNull(1)
        val ambiguous = selected != null && runnerUp != null &&
            selected.optInt("evidenceScore") - runnerUp.optInt("evidenceScore") < 20
        val profile = JSONObject()
            .put("scannedLines", scanned)
            .put("systems", JSONArray(systems))
            .put("selectedSystem", selected ?: JSONObject.NULL)
            .put("ambiguous", ambiguous)
            .put("classificationStatus", when {
                selected == null -> "not_found"
                ambiguous -> "ambiguous"
                else -> "clear"
            })
        val selectedSystems = systems.take(if (ambiguous) 2 else 1)
        val selectedIds = selectedSystems.map { it.optString("id") }
        val profileTerms = (primaryQueries + selectedSystems.flatMap { system ->
            val terms = system.optJSONArray("matchedKeywords") ?: JSONArray()
            (0 until terms.length()).map(terms::optString)
        }).filter(String::isNotBlank).distinct().take(32)
        val exclusions = excludedGroupId?.takeIf { it !in selectedIds }
            ?.let { id -> groups.firstOrNull { it.id == id }?.keywords }.orEmpty()
        var keywordStage = if (profileTerms.isNotEmpty()) "intent_profile" else "exact"

        fun locate(queries: List<String>, excluded: List<String>): JSONObject {
            val needles = queries.map(String::trim).filter(String::isNotEmpty).distinctBy(String::lowercase)
            val excludedTerms = excluded.map(String::trim).filter(String::isNotEmpty).distinctBy(String::lowercase)
            val worstFirst = compareBy<PpCandidate> { it.score }
                .thenByDescending { it.offset.toLongOrNull(16) ?: Long.MAX_VALUE }
            val candidates = PriorityQueue(worstFirst)
            val representatives = linkedMapOf<String, PpCandidate>()
            val maxCandidates = limit * 8
            var matchedCount = 0
            rows.forEach { row ->
                val matched = needles.filter { it.lowercase() in row.matchedTerms }
                if (matched.isEmpty() || excludedTerms.any { it.lowercase() in row.matchedTerms }) return@forEach
                matchedCount++
                val score = matched.size * 100 + (if (row.lower.contains("string:")) 20 else 0) +
                    (if (row.lower.contains("is_")) 10 else 0)
                val candidate = PpCandidate(row.offset, row.text, matched, score)
                matched.forEach { term ->
                    val previous = representatives[term]
                    if (previous == null || worstFirst.compare(candidate, previous) > 0) representatives[term] = candidate
                }
                if (candidates.size < maxCandidates) candidates += candidate
                else if (worstFirst.compare(candidate, candidates.peek()) > 0) {
                    candidates.poll()
                    candidates += candidate
                }
            }
            val ranked = candidates.sortedWith(compareByDescending<PpCandidate> { it.score }
                .thenBy { it.offset.toLongOrNull(16) ?: Long.MAX_VALUE })
            val top = buildList {
                representatives.values.forEach { candidate ->
                    if (none { existing: PpCandidate -> existing.offset == candidate.offset }) add(candidate)
                }
                ranked.forEach { candidate ->
                    if (size < limit && none { existing: PpCandidate -> existing.offset == candidate.offset }) add(candidate)
                }
            }.take(limit)
            return JSONObject().put("queries", JSONArray(needles)).put("excludedQueries", JSONArray(excludedTerms))
                .put("scannedLines", scanned).put("matched", matchedCount).put("truncated", matchedCount > top.size)
                .put("candidates", JSONArray(top.map { candidate ->
                    JSONObject().put("offset", "0x${candidate.offset}").put("text", candidate.text)
                        .put("matchedTerms", JSONArray(candidate.matchedTerms)).put("score", candidate.score)
                }))
        }

        var located = locate(profileTerms.ifEmpty { primaryQueries }, exclusions)
        if (located.optInt("matched") == 0 && profileTerms.isEmpty()) {
            keywordStage = "domain_fallback"
            located = locate(fallbackQueries, emptyList())
        }
        val result = JSONObject()
            .put("profile", profile)
            .put("locate", located)
            .put("keywordStage", keywordStage)
            .put("cacheHit", false)
            .put("scanElapsedMs", (System.nanoTime() - started) / 1_000_000)
            .put("scannedLines", scanned)
        synchronized(this) { ppLocatePipelineCache[cacheKey] = JSONObject(result.toString()) }
        return result
    }

    /** 单次流式扫描 pp.txt：按用户意图的多个关键词返回最相关池项，绝不把 pp.txt 整体交给模型。 */
    fun locatePp(
        resultDir: File,
        queries: List<String>,
        limit: Int,
        excludeQueries: List<String> = emptyList(),
    ): JSONObject {
        val needles = queries.map { it.trim().lowercase() }.filter { it.isNotEmpty() }.distinct()
        val exclusions = excludeQueries.map(String::trim).filter(String::isNotEmpty).distinctBy(String::lowercase)
        val cacheKey = ppCacheKey(resultDir, "locate:${needles.joinToString("|")}:${exclusions.joinToString("|")}:$limit")
        synchronized(this) { ppLocateCache[cacheKey]?.let { return JSONObject(it.toString()) } }
        val worstFirst = compareBy<PpCandidate> { it.score }
            .thenByDescending { it.offset.toLongOrNull(16) ?: Long.MAX_VALUE }
        val candidates = PriorityQueue(worstFirst)
        val representatives = linkedMapOf<String, PpCandidate>()
        val maxCandidates = limit * 8
        var scanned = 0L
        var matchedCount = 0
        // 倒排快路径候选集（词条任一不可索引则回退全量扫描）
        val fastLoaded = PpPostings.get(resultDir)
        val fastIds = fastLoaded?.let { PpPostings.candidateIds(it, needles) }
        fun processCandidate(raw: String): Boolean {
            val lower = raw.lowercase()
            val matched = needles.filter { containsTerm(raw, it) }
            if (matched.isEmpty()) return true
            if (exclusions.any { containsTerm(raw, it) }) return true
            val offset = PP_OFFSET.find(raw)?.groupValues?.get(1)?.lowercase() ?: return true
            scanned++
            val score = matched.size * 100 +
                (if (lower.contains("string:")) 20 else 0) +
                (if (lower.contains("is_")) 10 else 0)
            val candidate = PpCandidate(offset, raw.trim().take(300), matched, score)
            matched.forEach { term ->
                val previous = representatives[term]
                if (previous == null || worstFirst.compare(candidate, previous) > 0) representatives[term] = candidate
            }
            if (candidates.size < maxCandidates) {
                candidates += candidate
            } else if (worstFirst.compare(candidate, candidates.peek()) > 0) {
                candidates.poll()
                candidates += candidate
            }
            matchedCount++
            return true
        }
        if (fastIds != null && exclusions.all { PpPostings.EXACT_TERM.matches(it.trim().lowercase()) }) {
            fastIds.forEach { id ->
                val raw = PpPostings.readLine(fastLoaded!!, id) ?: return@forEach
                processCandidate(raw)
            }
        } else forEachPpLine(resultDir) { raw ->
            scanned++
            val lower = raw.lowercase()
            val matched = needles.filter { containsTerm(raw, it) }
            if (matched.isEmpty()) return@forEachPpLine true
            if (exclusions.any { containsTerm(raw, it) }) return@forEachPpLine true
            val offset = PP_OFFSET.find(raw)?.groupValues?.get(1)?.lowercase() ?: return@forEachPpLine true
            matchedCount++
            val score = matched.size * 100 +
                (if (lower.contains("string:")) 20 else 0) +
                (if (lower.contains("is_")) 10 else 0)
            val candidate = PpCandidate(offset, raw.trim().take(300), matched, score)
            matched.forEach { term ->
                val previous = representatives[term]
                if (previous == null || worstFirst.compare(candidate, previous) > 0) representatives[term] = candidate
            }
            if (candidates.size < maxCandidates) {
                candidates += candidate
            } else if (worstFirst.compare(candidate, candidates.peek()) > 0) {
                candidates.poll()
                candidates += candidate
            }
            true
        }
        val ranked = candidates
            .sortedWith(compareByDescending<PpCandidate> { it.score }.thenBy { it.offset.toLongOrNull(16) ?: Long.MAX_VALUE })
        val top = buildList {
            representatives.values.forEach { candidate -> if (this.none { existing: PpCandidate -> existing.offset == candidate.offset }) add(candidate) }
            ranked.forEach { candidate -> if (size < limit && this.none { existing: PpCandidate -> existing.offset == candidate.offset }) add(candidate) }
        }.take(limit)
        val result = JSONObject()
            .put("queries", JSONArray(needles))
            .put("excludedQueries", JSONArray(exclusions))
            .put("scannedLines", scanned)
            .put("matched", matchedCount)
            .put("truncated", matchedCount > top.size)
            .put("candidates", JSONArray(top.map { candidate ->
                JSONObject()
                    .put("offset", "0x${candidate.offset}")
                    .put("text", candidate.text)
                    .put("matchedTerms", JSONArray(candidate.matchedTerms))
                    .put("score", candidate.score)
            }))
        synchronized(this) { ppLocateCache[cacheKey] = JSONObject(result.toString()) }
        return result
    }

    /** 单次扫描 pp.txt，统计各中英文特征组并判断当前 App 实际使用的业务体系。 */
    fun profilePp(resultDir: File, groups: List<PpFeatureGroup>, sampleLimit: Int = 6): JSONObject {
        data class State(
            var hits: Int = 0,
            val termCounts: LinkedHashMap<String, Int> = linkedMapOf(),
            val samples: MutableList<PpCandidate> = mutableListOf(),
        )
        data class Term(val value: String, val lower: String)

        val normalized = groups.associateWith { group ->
            group.keywords.map(String::trim).filter(String::isNotEmpty).distinctBy(String::lowercase)
                .map { Term(it, it.lowercase()) }
        }
        val cacheKey = ppCacheKey(resultDir, "profile:${groups.joinToString("|") { group -> "${group.id}:${group.weight}:${group.keywords.joinToString(",")}" }}:$sampleLimit")
        synchronized(this) { ppProfileCache[cacheKey]?.let { return JSONObject(it.toString()) } }
        val states = groups.associateWith { State() }
        val profilePrefilter = anyOfRegex(
            groups.flatMap { group -> normalized.getValue(group) }.map(Term::lower),
            ignoreCase = true,
        )
        var scanned = 0L
        val pFastLoaded = PpPostings.get(resultDir)
        val pFastIds = pFastLoaded?.let { PpPostings.candidateIds(it, normalized.values.flatten().map(Term::lower)) }
        if (pFastIds != null) {
            for (id in pFastIds) {
                val raw = PpPostings.readLine(pFastLoaded!!, id) ?: continue
                scanned++
                val offset = PP_OFFSET.find(raw)?.groupValues?.get(1)?.lowercase() ?: continue
                val lower = raw.lowercase()
                groups.forEach { group ->
                    val matched = normalized.getValue(group).filter { term ->
                        lower.contains(term.lower) && containsTerm(raw, term.value)
                    }
                    if (matched.isEmpty()) return@forEach
                    val state = states.getValue(group)
                    state.hits++
                    matched.forEach { term ->
                        state.termCounts[term.value] = (state.termCounts[term.value] ?: 0) + 1
                    }
                    val specificity = matched.sumOf { it.value.length.coerceAtMost(24) * 3 }
                    val score = group.weight + matched.size * 100 + specificity +
                        if (lower.contains("string:")) 20 else 0
                    val candidate = PpCandidate(offset, raw.trim().take(300), matched.map(Term::value), score)
                    state.samples += candidate
                    state.samples.sortWith(compareByDescending<PpCandidate> { it.score }
                        .thenBy { it.offset.toLongOrNull(16) ?: Long.MAX_VALUE })
                    if (state.samples.size > sampleLimit) state.samples.removeLast()
                }
            }
        } else forEachPpLine(resultDir) { raw ->
            scanned++
            val offset = PP_OFFSET.find(raw)?.groupValues?.get(1)?.lowercase() ?: return@forEachPpLine true
            // 行级预筛：整行不含任何组词条即跳过（超集安全，精确匹配仍在下方逐词执行）
            if (profilePrefilter != null && !profilePrefilter.containsMatchIn(raw)) return@forEachPpLine true
            val lower = raw.lowercase()
            groups.forEach { group ->
                val matched = normalized.getValue(group).filter { term ->
                    lower.contains(term.lower) && containsTerm(raw, term.value)
                }
                if (matched.isEmpty()) return@forEach
                val state = states.getValue(group)
                state.hits++
                matched.forEach { term ->
                    state.termCounts[term.value] = (state.termCounts[term.value] ?: 0) + 1
                }
                val specificity = matched.sumOf { it.value.length.coerceAtMost(24) * 3 }
                val score = group.weight + matched.size * 100 + specificity + if (lower.contains("string:")) 20 else 0
                val candidate = PpCandidate(offset, raw.trim().take(300), matched.map(Term::value), score)
                state.samples += candidate
                state.samples.sortWith(compareByDescending<PpCandidate> { it.score }.thenBy { it.offset.toLongOrNull(16) ?: Long.MAX_VALUE })
                if (state.samples.size > sampleLimit) state.samples.removeLast()
            }
            true
        }
        val systems = groups.map { group ->
            val state = states.getValue(group)
            val uniqueTerms = state.termCounts.size
            val evidenceScore = group.weight + state.hits.coerceAtMost(20) * 5 + uniqueTerms * 15
            val matchedKeywords = normalized.getValue(group)
                .map(Term::value)
                .filter(state.termCounts::containsKey)
            JSONObject()
                .put("id", group.id)
                .put("label", group.label)
                .put("hitCount", state.hits)
                .put("uniqueKeywordCount", uniqueTerms)
                .put("evidenceScore", if (state.hits == 0) 0 else evidenceScore)
                .put("matchedKeywords", JSONArray(matchedKeywords))
                .put("keywordCounts", JSONObject(state.termCounts as Map<*, *>))
                .put("samples", JSONArray(state.samples.map { candidate ->
                    JSONObject()
                        .put("offset", "0x${candidate.offset}")
                        .put("text", candidate.text)
                        .put("matchedTerms", JSONArray(candidate.matchedTerms))
                        .put("score", candidate.score)
                }))
        }.filter { it.optInt("hitCount") > 0 }
            .sortedWith(compareByDescending<JSONObject> { it.optInt("evidenceScore") }.thenByDescending { it.optInt("hitCount") })
        val selected = systems.firstOrNull()
        val runnerUp = systems.getOrNull(1)
        val ambiguous = selected != null && runnerUp != null &&
            selected.optInt("evidenceScore") - runnerUp.optInt("evidenceScore") < 20
        val result = JSONObject()
            .put("scannedLines", scanned)
            .put("systems", JSONArray(systems))
            .put("selectedSystem", selected ?: JSONObject.NULL)
            .put("ambiguous", ambiguous)
            .put("classificationStatus", when {
                selected == null -> "not_found"
                ambiguous -> "ambiguous"
                else -> "clear"
            })
        synchronized(this) { ppProfileCache[cacheKey] = JSONObject(result.toString()) }
        return result
    }

    fun ppContexts(resultDir: File, poolOffsets: List<Long>, radius: Int = 4): JSONObject {
        data class Capture(
            val offset: String,
            val lines: MutableList<String>,
            var remaining: Int,
        )

        val targets = poolOffsets.map { it.toString(16) }.toSet()
        val cacheKey = ppCacheKey(resultDir, "context:${targets.sorted().joinToString(",")}:$radius")
        synchronized(this) { ppContextCache[cacheKey]?.let { return JSONObject(it.toString()) } }
        val before = ArrayDeque<String>()
        val active = mutableListOf<Capture>()
        val captures = linkedMapOf<String, Capture>()
        forEachPpLine(resultDir) { raw ->
            active.toList().forEach { capture ->
                capture.lines += raw.trim().take(300)
                capture.remaining--
                if (capture.remaining == 0) active.remove(capture)
            }
            val offset = PP_OFFSET.find(raw)?.groupValues?.get(1)?.lowercase()
            if (offset != null && offset in targets && offset !in captures) {
                val capture = Capture(offset, (before.toList() + raw.trim().take(300)).toMutableList(), radius)
                captures[offset] = capture
                active += capture
            }
            before += raw.trim().take(300)
            if (before.size > radius) before.removeFirst()
            true
        }
        val typeArguments = Regex("""TypeArguments?:\s*<([^>]+)>""")
        val listType = Regex("""\bList<([^>]+)>""")
        val closureType = Regex("""Closure:.*?=>\s*([A-Za-z_][A-Za-z0-9_]*)\s+from""")
        val fieldType = Regex("""Field\s+<([A-Za-z_][A-Za-z0-9_]*)[.@]""")
        val identifier = Regex("""[A-Za-z_][A-Za-z0-9_]*""")
        val builtIns = setOf("dynamic", "String", "int", "double", "bool", "Object", "List", "Map", "Set", "Function")
        val rows = captures.values.map { capture ->
            val symbols = linkedSetOf<String>()
            capture.lines.forEach { line ->
                sequenceOf(typeArguments.find(line), listType.find(line)).filterNotNull().forEach { match ->
                    identifier.findAll(match.groupValues[1]).map { it.value }.forEach(symbols::add)
                }
                closureType.find(line)?.groupValues?.get(1)?.let(symbols::add)
                fieldType.find(line)?.groupValues?.get(1)?.let(symbols::add)
            }
            symbols.removeAll(builtIns)
            symbols.removeAll { it.length < 2 || it.length > 24 || it.none(Char::isUpperCase) }
            JSONObject()
                .put("offset", "0x${capture.offset}")
                .put("symbols", JSONArray(symbols.toList()))
                .put("lines", JSONArray(capture.lines))
        }
        val result = JSONObject()
            .put("contexts", JSONArray(rows))
            .put("symbols", JSONArray(rows.flatMap { row ->
                val symbols = row.getJSONArray("symbols")
                (0 until symbols.length()).map(symbols::getString)
            }.distinct()))
        synchronized(this) { ppContextCache[cacheKey] = JSONObject(result.toString()) }
        return result
    }

    fun outlineClasses(resultDir: File, classNames: List<String>, semanticHints: List<String>, limit: Int): JSONObject {
        val targets = classNames.toSet()
        val hints = semanticHints.map(String::trim).filter(String::isNotEmpty).distinctBy(String::lowercase)
        val methods = functionHeaders(resultDir).mapNotNull { header ->
            val owner = header.className?.takeIf(String::isNotBlank) ?: return@mapNotNull null
            val signature = header.name?.takeIf(String::isNotBlank) ?: return@mapNotNull null
            if (owner !in targets) return@mapNotNull null
            val matchedHints = hints.filter { containsTerm(signature, it) }
            JSONObject()
                .put("class", owner)
                .put("function", signature)
                .put("functionVa", "0x${header.va.toString(16)}")
                .put("file", header.file)
                .put("semanticMatch", matchedHints.isNotEmpty())
                .put("matchedHints", JSONArray(matchedHints))
                .put("score", matchedHints.size * 100 + if (signature.contains("dyn:get:")) 20 else 0)
        }
        val ranked = methods.sortedWith(
            compareByDescending<JSONObject> { it.optBoolean("semanticMatch") }
                .thenByDescending { it.optInt("score") }
                .thenBy { it.optString("functionVa") },
        ).take(limit)
        return JSONObject()
            .put("classes", JSONArray(targets.toList()))
            .put("methods", JSONArray(ranked))
            .put("lookupMode", "compact_function_index")
    }

    fun searchAsm(
        resultDir: File,
        query: String,
        caseInsensitive: Boolean,
        limit: Int,
        fullScan: Boolean = false,
        includePaths: List<String> = emptyList(),
        excludePaths: List<String> = emptyList(),
        includeThirdParty: Boolean = false,
    ): JSONObject {
        val queries = searchQueries(query, caseInsensitive)
        // 路径过滤的新鲜度指纹：只覆盖「实际匹配 include 过滤的文件」——
        // 命中文件内容变化（mtime/size）必须使缓存键失效；无关文件不参与
        // 指纹（避免为整包 asm 全量 stat）。选择在前、缓存检查在后。
        val pathSelection = if (includePaths.isEmpty()) null
        else asmPathSelection(resultDir, includePaths, excludePaths)
        val sourceFingerprint = if (pathSelection == null) {
            val index = semanticIndexFile(resultDir)
            "${index.absolutePath}:${index.lastModified()}:${index.length()}"
        } else {
            val asmDir = File(resultDir, "asm")
            pathSelection
                .filter { matchesPathFilters(it, includePaths, excludePaths) }
                .joinToString(separator = "|") { rel ->
                    val file = File(asmDir, rel.removePrefix("asm/"))
                    "$rel:${file.lastModified()}:${file.length()}"
                }
        }
        val cacheKey = asmSearchCacheKey(
            resultDir,
            sourceFingerprint,
            queries,
            caseInsensitive,
            limit,
            fullScan,
            includePaths,
            excludePaths,
            includeThirdParty,
        )
        synchronized(this) {
            asmSearchCache[cacheKey]?.let {
                return JSONObject(it.toString()).put("cacheHit", true).put("scanElapsedMs", 0)
            }
        }
        val started = System.nanoTime()
        val result = if (pathSelection != null) {
            searchAsmFiles(resultDir, queries, caseInsensitive, limit, includePaths, excludePaths, includeThirdParty, pathSelection)
                .put("lookupMode", "asm_path_filtered_scan")
                .put("fullScan", fullScan)
        } else {
            val indexed = searchSemanticAsm(resultDir, queries, caseInsensitive, limit, includePaths, excludePaths)
            if (indexed.getJSONArray("matches").length() > 0 || !fullScan) indexed
            else searchAsmFiles(resultDir, queries, caseInsensitive, limit, includePaths, excludePaths, includeThirdParty)
                .put("semanticMiss", true)
        }
        result.put("cacheHit", false).put("scanElapsedMs", (System.nanoTime() - started) / 1_000_000)
        synchronized(this) { asmSearchCache[cacheKey] = JSONObject(result.toString()) }
        return result
    }

    private fun asmSearchCacheKey(
        resultDir: File,
        sourceFingerprint: String,
        queries: List<String>,
        caseInsensitive: Boolean,
        limit: Int,
        fullScan: Boolean,
        includePaths: List<String>,
        excludePaths: List<String>,
        includeThirdParty: Boolean,
    ): AsmSearchCacheKey {
        return AsmSearchCacheKey(
            resultDir.absoluteFile.normalize().path,
            sourceFingerprint,
            queries.joinToString("|"),
            caseInsensitive,
            limit,
            fullScan,
            includePaths.map(String::lowercase),
            excludePaths.map(String::lowercase),
            includeThirdParty,
        )
    }

    private fun searchSemanticAsm(
        resultDir: File,
        queries: List<String>,
        caseInsensitive: Boolean,
        limit: Int,
        includePaths: List<String>,
        excludePaths: List<String>,
    ): JSONObject {
        val meta = ensureSemanticIndex(resultDir)
        val index = semanticIndexFile(resultDir)
        val input = if (index.name.endsWith(".gz")) GZIPInputStream(FileInputStream(index)) else FileInputStream(index)
        val matches = JSONArray()
        var scannedRows = 0
        var truncated = false
        // 行级预筛：索引原始行不含任何词条时跳过 JSON 解析（超集安全——
        // 正则无命中 => 词不在行内；词条含 JSON 转义字符时禁用预筛走原路径）。
        // 百万行 JSON 解析从全量降到命中行（几十行），这是 asm 搜索卡的根源。
        val prefilter = if (queries.any { it.any { c -> c == '"' || c == '\\' } }) null
        else anyOfRegex(queries, ignoreCase = true)
        // path 过滤词预小写一次（与 matchesPathFilters 的小写语义等价）
        val includesLc = includePaths.map(String::lowercase)
        val excludesLc = excludePaths.map(String::lowercase)
        input.bufferedReader().use { reader ->
            while (true) {
                val raw = reader.readLine() ?: break
                scannedRows++
                if (prefilter != null && !prefilter.containsMatchIn(raw)) continue
                val row = runCatching { JSONObject(raw) }.getOrNull() ?: continue
                val searchable = listOf(
                    row.optString("function"),
                    row.optString("class"),
                    row.optString("file"),
                    row.optString("insn"),
                    row.optString("text"),
                ).filter(String::isNotBlank).joinToString(" ")
                // lowercase 一次复用给 path 过滤与词条匹配（原实现每行每词各转一次，
                // 百万行 × N 词 = 数百万次大字符串分配，GC 风暴）
                val haystackLc = searchable.lowercase()
                if (includesLc.isNotEmpty() && includesLc.none { haystackLc.contains(it) }) continue
                if (excludesLc.isNotEmpty() && excludesLc.any { haystackLc.contains(it) }) continue
                val matchedQueries = if (caseInsensitive) queries.filter { haystackLc.contains(it) }
                else queries.filter { searchable.contains(it) }
                if (matchedQueries.isEmpty()) continue
                if (matches.length() >= limit) {
                    truncated = true
                    break
                }
                matches.put(JSONObject()
                    .put("file", row.optString("file"))
                    .put("line", row.optInt("line", 0))
                    .put("function", row.optString("function").takeIf(String::isNotBlank) ?: JSONObject.NULL)
                    .put("class", row.optString("class").takeIf(String::isNotBlank) ?: JSONObject.NULL)
                    .put("text", row.optString("insn").ifBlank { row.optString("text") }.ifBlank { row.optString("function") }.take(300))
                    .put("matchedQueries", JSONArray(matchedQueries)))
            }
        }
        return JSONObject()
            .put("queries", JSONArray(queries))
            .put("matches", matches)
            .put("count", matches.length())
            .put("scannedFiles", meta.optInt("scannedFiles"))
            .put("scannedRows", scannedRows)
            .put("lookupMode", "semantic_index")
            .put("truncated", truncated)
            .put("fullScan", false)
            .put("includePath", JSONArray(includePaths))
            .put("excludePath", JSONArray(excludePaths))
            .put("hint", if (matches.length() == 0) "索引未命中。只有确需搜索非语义原始行时才用 fullScan=true，禁止逐词重复全目录扫描。" else "相关词可用 | 合并为一次查询。")
    }

    private fun asmPathSelection(resultDir: File, includePaths: List<String>, excludePaths: List<String>): List<String> {
        val index = File(resultDir, ASM_PATH_INDEX)
        // 索引新鲜度：asm 目录比索引新（新文件出现/删除）时重建——否则
        // 新增的 .dart 文件永远不会被 includePaths 扫描命中。
        val asmDir = File(resultDir, "asm")
        if (!index.isFile || asmDir.lastModified() > index.lastModified()) {
            val paths = asmDir.walkTopDown()
                .filter { it.isFile && it.extension == "dart" }
                .map { "asm/${it.relativeTo(asmDir).path.replace('\\', '/')}" }
                .sorted()
                .toList()
            val temporary = File(resultDir, "$ASM_PATH_INDEX.tmp")
            temporary.writeText(paths.joinToString(separator = "\n", postfix = if (paths.isEmpty()) "" else "\n"))
            runCatching {
                Files.move(temporary.toPath(), index.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            }.getOrElse {
                Files.move(temporary.toPath(), index.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        }
        // 返回全量 asm 路径；include/exclude 过滤与 skipped 计数在
        // searchAsmFiles 内部完成（否则被过滤文件永远进不了 skip 分支，
        // skippedFiles 恒为 0，测试与统计口径都失真）。
        return index.useLines { lines ->
            lines.map(String::trim)
                .filter(String::isNotEmpty)
                .toList()
        }
    }

    private fun searchAsmFiles(
        resultDir: File,
        queries: List<String>,
        caseInsensitive: Boolean,
        limit: Int,
        includePaths: List<String>,
        excludePaths: List<String>,
        includeThirdParty: Boolean,
        candidatePaths: List<String>? = null,
    ): JSONObject {
        val asmDir = File(resultDir, "asm")
        val matches = JSONArray()
        var truncated = false
        var scanned = 0
        var skippedFiles = 0
        val files = candidatePaths?.asSequence()
            ?.map { File(asmDir, it.removePrefix("asm/")) }
            ?.filter { it.isFile && it.extension == "dart" }
            ?: asmDir.walkTopDown().filter { it.isFile && it.extension == "dart" }
        files.forEach { file ->
            if (truncated) return@forEach
            val rel = "asm/${file.relativeTo(asmDir).path}"
            if (!matchesPathFilters(rel, includePaths, excludePaths) ||
                (includePaths.isEmpty() && !includeThirdParty && isLikelyThirdParty(rel))) {
                skippedFiles++
                return@forEach
            }
            var currentClass: String? = null
            var currentFunction: String? = null
            var pendingSignature: String? = null
            file.useLines { lines ->
                lines.forEachIndexed { index, raw ->
                    val trimmed = raw.trim()
                    if (trimmed.startsWith("class ")) currentClass = className(trimmed)
                    val addrHeader = FUNC_ADDR.matchEntire(raw)
                    when {
                        addrHeader != null -> currentFunction = pendingSignature
                        raw.startsWith("  ") && !trimmed.startsWith("//") && trimmed.isNotEmpty() -> pendingSignature = trimmed.trimEnd('{', ' ', ';')
                    }
                    val searchable = if (caseInsensitive) raw.lowercase() else raw
                    val matchedQueries = queries.filter(searchable::contains)
                    if (matchedQueries.isEmpty()) return@forEachIndexed
                    if (matches.length() >= limit) { truncated = true; return@forEachIndexed }
                    matches.put(JSONObject()
                        .put("file", rel)
                        .put("line", index + 1)
                        .put("function", currentFunction ?: JSONObject.NULL)
                        .put("class", currentClass ?: JSONObject.NULL)
                        .put("matchedQueries", JSONArray(matchedQueries))
                        .put("text", trimmed.take(300)))
                }
            }
            scanned++
        }
        return JSONObject()
            .put("queries", JSONArray(queries))
            .put("matches", matches)
            .put("count", matches.length())
            .put("scannedFiles", scanned)
            .put("skippedFiles", skippedFiles)
            .put("lookupMode", "asm_full_scan")
            .put("fullScan", true)
            .put("includePath", JSONArray(includePaths))
            .put("excludePath", JSONArray(excludePaths))
            .put("includeThirdParty", includeThirdParty)
            .put("truncated", truncated)
    }

    private fun matchesPathFilters(value: String, includes: List<String>, excludes: List<String>): Boolean {
        // 常见路径：无过滤条件，免去每行 lowercase 分配
        if (includes.isEmpty() && excludes.isEmpty()) return true
        val normalized = value.lowercase()
        if (includes.isNotEmpty() && includes.none { normalized.contains(it.lowercase()) }) return false
        return excludes.none { normalized.contains(it.lowercase()) }
    }

    private fun isLikelyThirdParty(value: String): Boolean {
        val normalized = value.lowercase().replace("%3a", ":").replace("%2f", "/")
        return listOf(
            "dart:",
            "package:flutter/",
            "package:archive/",
            "package:dio/",
            "package:http/",
            "package:crypto/",
            "package:collection/",
            "package:extended_image/",
            "package:path_provider/",
            "package:shared_preferences/",
        ).any(normalized::contains)
    }

    /**
     * Blutter may recover pool references but omit large AOT function bodies.
     * Inspect the current libapp bytes directly and join three independent facts:
     * display string branch values, direct calls, and small-integer return ladders.
     */
    fun rawDecisionFlow(
        libapp: ByteArray,
        verificationWindows: JSONArray,
        refsByOffset: JSONObject,
        poolTextByOffset: Map<String, String>,
        requestedValues: List<Long>,
        limit: Int = 5,
    ): JSONObject {
        data class RawFunction(
            val start: Long,
            val end: Long,
            val comparisons: MutableList<Pair<Long, Long>> = mutableListOf(),
            val returnedValues: LinkedHashSet<Long> = linkedSetOf(),
            val returnSites: MutableList<Pair<Long, Long>> = mutableListOf(),
            val calls: LinkedHashSet<Long> = linkedSetOf(),
        )

        val codeRanges = arm64ExecutableRanges(libapp)
        fun fileOffset(va: Long): Int? = codeRanges.firstOrNull { range ->
            va >= range.virtualAddress && va - range.virtualAddress < range.fileEnd - range.fileOffset
        }?.let { range -> range.fileOffset + (va - range.virtualAddress).toInt() }
        fun wordAt(va: Long): Int? = fileOffset(va)?.takeIf { it >= 0 && it + 4 <= libapp.size }
            ?.let { arm64Word(libapp, it) }
        fun movzX0(word: Int): Long? {
            if ((word and 0xffe0001f.toInt()) != 0xd2800000.toInt()) return null
            val shift = (word ushr 21 and 0x3) * 16
            return ((word ushr 5 and 0xffff).toLong() shl shift)
        }
        fun cmpX0(word: Int): Long? {
            if ((word and 0xffc003ff.toInt()) != 0xf100001f.toInt()) return null
            val shift = if (word and (1 shl 22) != 0) 12 else 0
            return ((word ushr 10 and 0xfff).toLong() shl shift)
        }
        fun branchTarget(va: Long, word: Int): Long? {
            if ((word and 0xfc000000.toInt()) != 0x94000000.toInt()) return null
            var immediate = word and 0x03ffffff
            if (immediate and 0x02000000 != 0) immediate = immediate or 0xfc000000.toInt()
            return va + immediate.toLong() * 4L
        }

        val windows = (0 until verificationWindows.length()).mapNotNull { index ->
            val row = verificationWindows.optJSONObject(index) ?: return@mapNotNull null
            val start = row.optString("verificationVa").removePrefix("0x").toLongOrNull(16)
                ?: return@mapNotNull null
            val size = row.optInt("maxBytes", 1024).coerceIn(64, 0x4000)
            start to start + size
        }.distinct()
        val functionStarts = linkedSetOf<Long>()
        windows.forEach { (start, end) ->
            var va = start and -4L
            while (va + 4 <= end) {
                val word = wordAt(va) ?: break
                if (word == 0xa9bf79fd.toInt() || isArm64FramePrologue(word)) functionStarts += va
                va += 4
            }
        }
        val orderedStarts = functionStarts.sorted()
        val functions = orderedStarts.mapIndexed { index, start ->
            val windowEnd = windows.filter { start >= it.first && start < it.second }
                .minOfOrNull { it.second } ?: (start + 0x400)
            val next = orderedStarts.drop(index + 1).firstOrNull { it < windowEnd } ?: windowEnd
            RawFunction(start, next)
        }
        functions.forEach { function ->
            var lastX0: Pair<Long, Long>? = null
            var va = function.start
            while (va + 4 <= function.end) {
                val word = wordAt(va) ?: break
                movzX0(word)?.let { lastX0 = va to it }
                cmpX0(word)?.let { function.comparisons += va to it }
                branchTarget(va, word)?.let(function.calls::add)
                if (word == 0xd65f03c0.toInt()) {
                    lastX0?.takeIf { va - it.first <= 16 }?.let {
                        function.returnedValues += it.second
                        function.returnSites += va to it.second
                    }
                }
                va += 4
            }
        }
        val byStart = functions.associateBy(RawFunction::start)
        fun callPath(from: Long, target: Long, depth: Int, visited: Set<Long> = emptySet()): List<Long>? {
            if (from == target) return listOf(from)
            if (depth == 0 || from in visited) return null
            val function = byStart[from] ?: return null
            for (callee in function.calls) {
                if (callee !in byStart) continue
                val tail = callPath(callee, target, depth - 1, visited + from) ?: continue
                return listOf(from) + tail
            }
            return null
        }

        data class ValueMapping(
            val value: Long,
            val consumer: Long,
            val comparisonVa: Long,
            val labels: LinkedHashSet<String> = linkedSetOf(),
            val poolOffsets: LinkedHashSet<String> = linkedSetOf(),
        )
        val mappings = linkedMapOf<Pair<Long, Long>, ValueMapping>()
        refsByOffset.keys().forEach { offset ->
            val rows = refsByOffset.optJSONArray(offset) ?: return@forEach
            (0 until rows.length()).mapNotNull(rows::optJSONObject).forEach { row ->
                val referenceVa = row.optString("va").removePrefix("0x").toLongOrNull(16) ?: return@forEach
                val function = functions.firstOrNull { referenceVa in it.start until it.end } ?: return@forEach
                val comparison = function.comparisons.lastOrNull { (va, _) -> va < referenceVa && referenceVa - va <= 0x20 }
                    ?: return@forEach
                val mapping = mappings.getOrPut(function.start to comparison.second) {
                    ValueMapping(comparison.second, function.start, comparison.first)
                }
                poolTextByOffset[offset]?.let(mapping.labels::add)
                mapping.poolOffsets += offset
            }
        }
        val requested = requestedValues.toSet()
        val candidates = functions.asSequence()
            .filter { it.returnedValues.size >= 2 }
            .map { function ->
                val related = mappings.values.mapNotNull { mapping ->
                    val path = callPath(mapping.consumer, function.start, 3) ?: return@mapNotNull null
                    if (mapping.value !in function.returnedValues) return@mapNotNull null
                    mapping to path
                }
                val mappedValues = related.map { it.first.value }.toSet()
                val requestedMatches = function.returnedValues.filter(requested::contains)
                val score = function.returnedValues.size * 100 + mappedValues.size * 350 +
                    requestedMatches.size * 500 + related.size * 80
                Triple(function, related, score)
            }
            .filter { it.second.isNotEmpty() || requested.any(it.first.returnedValues::contains) }
            .sortedByDescending(Triple<RawFunction, List<Pair<ValueMapping, List<Long>>>, Int>::third)
            .take(limit.coerceIn(1, 20))
            .toList()
        val output = JSONArray()
        candidates.forEach { (function, related, score) ->
            val targetMappings = JSONArray()
            related.groupBy { it.first.value }.toSortedMap().forEach { (value, rows) ->
                targetMappings.put(JSONObject()
                    .put("value", value)
                    .put("labels", JSONArray(rows.flatMap { it.first.labels }.distinct()))
                    .put("poolOffsets", JSONArray(rows.flatMap { it.first.poolOffsets }.distinct()))
                    .put("comparisonVas", JSONArray(rows.map { "0x${it.first.comparisonVa.toString(16)}" }.distinct()))
                    .put("consumerFunctionVas", JSONArray(rows.map { "0x${it.first.consumer.toString(16)}" }.distinct())))
            }
            val matchedRequested = function.returnedValues.filter(requested::contains)
            val confidence = when {
                related.map { it.first.value }.distinct().size >= 2 -> "high"
                related.isNotEmpty() && matchedRequested.isNotEmpty() -> "high"
                else -> "medium"
            }
            output.put(JSONObject()
                .put("functionVa", "0x${function.start.toString(16)}")
                .put("functionEndVa", "0x${function.end.toString(16)}")
                .put("returnedValues", JSONArray(function.returnedValues.toList().sorted()))
                .put("returnSites", JSONArray(function.returnSites.map { (va, value) ->
                    JSONObject().put("va", "0x${va.toString(16)}").put("value", value)
                }))
                .put("matchedRequestedValues", JSONArray(matchedRequested))
                .put("targetMappings", targetMappings)
                .put("callChains", JSONArray(related.map { (_, path) ->
                    JSONArray(path.map { "0x${it.toString(16)}" })
                }.distinctBy(JSONArray::toString)))
                .put("score", score)
                .put("confidence", confidence)
                .put("evidenceLevel", "L3")
                .put("evidenceSource", "current_libapp_raw_arm64_decision_flow")
                .put("returnEncoding", "native")
                .apply {
                    if (matchedRequested.size == 1) put("patchHint", JSONObject()
                        .put("mode", "force_return_constant")
                        .put("value", matchedRequested.single())
                        .put("returnType", "int")
                        .put("valueEncoding", "native"))
                })
        }
        return JSONObject()
            .put("status", if (output.length() > 0) "decision_flow_found" else "not_found")
            .put("currentBytesVerified", true)
            .put("inspectedWindowCount", windows.size)
            .put("functionCount", functions.size)
            .put("candidates", output)
            .put("candidateCount", output.length())
    }

    private fun searchQueries(query: String, caseInsensitive: Boolean): List<String> =
        query.split('|').map(String::trim).filter(String::isNotEmpty)
            .distinctBy { if (caseInsensitive) it.lowercase() else it }
            .take(16)
            .map { if (caseInsensitive) it.lowercase() else it }

    fun functionValueEvidence(lines: List<String>, requestedValues: Set<Long>? = null): JSONArray {
        val evidence = JSONArray()
        lines.forEach { raw ->
            valueEvidence(raw, requestedValues)?.let(evidence::put)
        }
        return evidence
    }

    private fun valueEvidence(raw: String, requestedValues: Set<Long>?): JSONObject? {
        val match = VALUE_INSTRUCTION.find(raw) ?: return null
        val value = parseNumeric(match.groupValues[3]) ?: return null
        if (requestedValues != null && value !in requestedValues) return null
        val mnemonic = match.groupValues[2].lowercase()
        return JSONObject()
            .put("instructionVa", "0x${match.groupValues[1].lowercase()}")
            .put("mnemonic", mnemonic)
            .put("kind", if (mnemonic == "cmp" || mnemonic == "cmn") "comparison" else "assignment")
            .put("value", value)
            .put("valueHex", signedHex(value))
            .put("text", raw.trim().take(300))
    }

    fun searchImmediateValues(
        resultDir: File,
        values: List<Long>,
        semanticHints: List<String>,
        contextClasses: List<String>,
        relevantPoolOffsets: List<Long>,
        limit: Int,
    ): JSONObject {
        data class FunctionScan(
            val file: String,
            val clazz: String?,
            val function: String?,
            val functionVa: String,
            val evidence: JSONArray = JSONArray(),
            val poolOffsets: LinkedHashSet<Long> = linkedSetOf(),
        )

        val logicalValues = values.distinct()
        val immediateMatches = linkedMapOf<Long, LinkedHashSet<Long>>()
        logicalValues.forEach { value ->
            immediateMatches.getOrPut(value) { linkedSetOf() }.add(value)
            if (value in (Long.MIN_VALUE / 2)..(Long.MAX_VALUE / 2)) {
                immediateMatches.getOrPut(value shl 1) { linkedSetOf() }.add(value)
            }
        }
        val requested = immediateMatches.keys
        val logicalValueSet = logicalValues.toSet()
        val hints = semanticHints.filter(String::isNotBlank).distinctBy(String::lowercase)
        val classes = contextClasses.filter(String::isNotBlank).toSet()
        val relevantOffsets = relevantPoolOffsets.toSet()
        val scansByVa = linkedMapOf<String, FunctionScan>()
        var excludedAddressingOffsets = 0
        val meta = forEachSemanticRow(resultDir) { row ->
            val functionVa = row.optString("functionVa").ifBlank { row.optString("va") }
            when (row.optString("type")) {
                "function" -> scansByVa.putIfAbsent(functionVa, FunctionScan(
                    row.optString("file"),
                    row.optString("class").takeIf(String::isNotBlank),
                    row.optString("function").takeIf(String::isNotBlank),
                    "0x$functionVa",
                ))
                "reference" -> row.optString("offset").toLongOrNull(16)?.let { scansByVa[functionVa]?.poolOffsets?.add(it) }
                "immediate" -> if (row.optLong("value") in requested) {
                    val immediate = row.optLong("value")
                    val matchedValues = immediateMatches[immediate].orEmpty()
                    scansByVa[functionVa]?.evidence?.put(JSONObject(row.toString()).apply {
                        remove("type"); remove("functionVa"); remove("function"); remove("class"); remove("file")
                        put("requestedValues", JSONArray(matchedValues))
                        put("valueEncoding", when {
                            immediate in logicalValueSet && matchedValues.size == 1 -> "raw"
                            immediate !in logicalValueSet && matchedValues.size == 1 -> "dart_smi"
                            else -> "raw_or_dart_smi"
                        })
                    })
                }
                "addressing_immediate" -> if (row.optLong("value") in requested) {
                    excludedAddressingOffsets += row.optInt("count", 1)
                }
            }
        }
        val candidates = scansByVa.values.filter { it.evidence.length() > 0 }.map { scan ->
            val matchedHints = hints.filter { hint ->
                containsTerm(scan.function.orEmpty(), hint) ||
                    containsTerm(scan.clazz.orEmpty(), hint) ||
                    scan.file.contains(hint, ignoreCase = true)
            }
            val relatedOffsets = scan.poolOffsets.filter { it in relevantOffsets }
            val matchedContextClasses = classes.filter { contextClass ->
                scan.clazz == contextClass || containsTerm(scan.function.orEmpty(), contextClass)
            }
            val contextClass = matchedContextClasses.isNotEmpty()
            val kinds = (0 until scan.evidence.length()).map { scan.evidence.getJSONObject(it).getString("kind") }
            val score = (if (contextClass) 300 else 0) + matchedHints.size * 160 +
                relatedOffsets.size.coerceAtMost(3) * 120 + kinds.sumOf { if (it == "comparison") 50 else 40 }
            JSONObject()
                .put("functionVa", scan.functionVa)
                .put("function", scan.function ?: JSONObject.NULL)
                .put("class", scan.clazz ?: JSONObject.NULL)
                .put("file", scan.file)
                .put("score", score)
                .put("contextClass", contextClass)
                .put("matchedContextClasses", JSONArray(matchedContextClasses))
                .put("matchedHints", JSONArray(matchedHints))
                .put("relatedPoolOffsets", JSONArray(relatedOffsets.map { "0x${it.toString(16)}" }))
                .put("values", JSONArray((0 until scan.evidence.length()).flatMap { index ->
                    val matched = scan.evidence.getJSONObject(index).optJSONArray("requestedValues") ?: JSONArray()
                    (0 until matched.length()).map(matched::getLong)
                }.distinct()))
                .put("evidence", scan.evidence)
        }.sortedWith(compareByDescending<JSONObject> { it.optInt("score") }
            .thenBy { it.optString("functionVa") })
        val poolMatches = JSONArray()
        File(resultDir, "pp.txt").forEachLine { raw ->
            val match = POOL_INTEGER.matchEntire(raw) ?: return@forEachLine
            val value = parseNumeric(match.groupValues[3]) ?: return@forEachLine
            if (value !in logicalValueSet || poolMatches.length() >= limit) return@forEachLine
            poolMatches.put(JSONObject()
                .put("offset", "0x${match.groupValues[1].lowercase()}")
                .put("type", match.groupValues[2])
                .put("value", value)
                .put("valueHex", signedHex(value))
                .put("text", raw.trim().take(300)))
        }
        val poolOffsets = (0 until poolMatches.length()).mapNotNull { index ->
            poolMatches.optJSONObject(index)?.optString("offset")?.removePrefix("0x")?.toLongOrNull(16)
        }
        val poolValueReferences = if (poolOffsets.isEmpty()) JSONObject()
        else xrefMany(resultDir, poolOffsets, perOffsetLimit = 4)
        return JSONObject()
            .put("values", JSONArray(logicalValues))
            .put("searchedImmediateValues", JSONArray(requested))
            .put("candidates", JSONArray(candidates.take(limit)))
            .put("candidateCount", candidates.size)
            .put("poolIntegerMatches", poolMatches)
            .put("poolValueReferences", poolValueReferences)
            .put("addressingOffsetsExcluded", excludedAddressingOffsets)
            .put("scannedFiles", meta.optInt("scannedFiles"))
            .put("lookupMode", "semantic_index")
            .put("truncated", candidates.size > limit)
    }

    /**
     * 从字段键的对象池引用现场推导对象字段写入，再按“相同偏移 + 类型/文件/数值语境”
     * 反查读取者。这里不依赖业务词表、固定字段名或固定数值，可用于任意混淆后的 Dart 模型。
     */
    fun traceFieldFlow(
        resultDir: File,
        anchorReferences: Map<Long, List<Long>>,
        values: List<Long>,
        semanticHints: List<String>,
        contextClasses: List<String>,
        fileHints: List<String>,
        limit: Int,
        excludePatterns: List<String> = emptyList(),
    ): JSONObject {
        // consumers 噪声过滤：命中排除模式（对 function/class/file 全路径
        // 的不区分大小写子串匹配）的函数直接剔除，避免 pointycastle 等
        // 第三方加密库淹没业务消费方。
        val excludes = excludePatterns.map(String::trim).filter(String::isNotEmpty)
            .map(String::lowercase).distinct()

        data class FieldWrite(
            val offset: Long,
            val functionVa: Long,
            val instructionVa: Long,
            val anchorVa: Long,
            val distance: Long,
            val function: String,
            val clazz: String,
            val file: String,
            val insn: String,
        )
        data class Consumer(
            val functionVa: Long,
            val function: String,
            val clazz: String,
            val file: String,
            val offsets: LinkedHashSet<Long> = linkedSetOf(),
            val reads: JSONArray = JSONArray(),
            val values: JSONArray = JSONArray(),
            val decisionEvidence: JSONArray = JSONArray(),
        )

        val normalizedAnchors = anchorReferences
            .filterKeys { it >= 0 }
            .mapValues { (_, refs) -> refs.filter { it >= 0 }.distinct().sorted() }
            .filterValues(List<Long>::isNotEmpty)
        if (normalizedAnchors.isEmpty()) {
            return JSONObject().put("fieldWrites", JSONArray()).put("consumers", JSONArray())
                .put("reason", "ANCHOR_REFERENCE_REQUIRED")
        }
        val headers = functionHeaders(resultDir).associateBy(FunctionHeader::va)
        val writes = mutableListOf<FieldWrite>()
        val contextTypes = linkedSetOf<String>()
        contextClasses.filter(String::isNotBlank).forEach(contextTypes::add)
        forEachMemoryAccess(resultDir) { access ->
            val anchors = normalizedAnchors[access.functionVa] ?: return@forEachMemoryAccess
            val header = headers[access.functionVa] ?: return@forEachMemoryAccess
            header.name?.takeIf(String::isNotBlank)?.let { signature ->
                extractSignatureTypes(signature).forEach(contextTypes::add)
            }
            if (!access.write) return@forEachMemoryAccess
            if (access.offset <= 0 || access.offset > 0x4000) return@forEachMemoryAccess
            val anchor = anchors.lastOrNull { it <= access.instructionVa } ?: return@forEachMemoryAccess
            val distance = access.instructionVa - anchor
            if (distance > 0x180) return@forEachMemoryAccess
            writes += FieldWrite(
                access.offset, access.functionVa, access.instructionVa, anchor, distance,
                header.name.orEmpty(), header.className.orEmpty(), header.file,
                "store [x${access.baseRegister}, #0x${access.offset.toString(16)}]",
            )
        }
        val rankedWrites = writes.distinctBy { Triple(it.functionVa, it.instructionVa, it.offset) }
            .sortedWith(compareBy<FieldWrite> { it.distance }.thenBy { it.offset })
        val fieldOffsets = rankedWrites.map(FieldWrite::offset).distinct().take(24).toSet()
        if (fieldOffsets.isEmpty()) {
            return JSONObject().put("fieldWrites", JSONArray()).put("consumers", JSONArray())
                .put("reason", "NO_NEARBY_OBJECT_FIELD_WRITE")
        }

        val logicalValues = values.distinct()
        val encodedValues = linkedSetOf<Long>().apply {
            logicalValues.forEach { value ->
                add(value)
                if (value in (Long.MIN_VALUE / 2)..(Long.MAX_VALUE / 2)) add(value shl 1)
            }
        }
        val consumers = linkedMapOf<Long, Consumer>()
        val valuesByFunction = linkedMapOf<Long, JSONArray>()
        forEachMemoryAccess(resultDir) { access ->
            if (access.write || access.offset !in fieldOffsets) return@forEachMemoryAccess
            val header = headers[access.functionVa] ?: return@forEachMemoryAccess
            val consumer = consumers.getOrPut(access.functionVa) {
                Consumer(access.functionVa, header.name.orEmpty(), header.className.orEmpty(), header.file)
            }
            consumer.offsets += access.offset
            if (consumer.reads.length() < 12) consumer.reads.put(JSONObject()
                .put("instructionVa", "0x${access.instructionVa.toString(16)}")
                .put("fieldOffset", "0x${access.offset.toString(16)}")
                .put("dataRegister", "x${access.dataRegister}")
                .put("insn", "load x${access.dataRegister}, [x${access.baseRegister}, #0x${access.offset.toString(16)}]"))
        }
        forEachFieldSlice(resultDir) { sink ->
            if (sink.fieldOffset !in fieldOffsets) return@forEachFieldSlice
            val consumer = consumers[sink.functionVa] ?: return@forEachFieldSlice
            if (consumer.decisionEvidence.length() >= 24) return@forEachFieldSlice
            val matchedValues = logicalValues.filter { value ->
                sink.value != NO_SLICE_VALUE && (sink.value == value ||
                    (value in (Long.MIN_VALUE / 2)..(Long.MAX_VALUE / 2) && sink.value == value shl 1))
            }
            consumer.decisionEvidence.put(JSONObject()
                .put("sourceInstructionVa", "0x${sink.sourceVa.toString(16)}")
                .put("sinkInstructionVa", "0x${sink.sinkVa.toString(16)}")
                .put("fieldOffset", "0x${sink.fieldOffset.toString(16)}")
                .put("sourceRegister", "x${sink.sourceRegister}")
                .put("kind", fieldSliceKind(sink.kind))
                .apply {
                    if (sink.value != NO_SLICE_VALUE) {
                        put("value", sink.value)
                        put("valueHex", signedHex(sink.value))
                    }
                    if (matchedValues.isNotEmpty()) {
                        put("requestedValues", JSONArray(matchedValues))
                        put("valueEncoding", if (sink.value in matchedValues) "raw" else "dart_smi")
                    }
                })
        }
        if (encodedValues.isNotEmpty()) {
            forEachSemanticRow(resultDir) { row ->
                val functionVa = row.optString("functionVa").toLongOrNull(16) ?: return@forEachSemanticRow
                when (row.optString("type")) {
                    "immediate" -> if (row.optLong("value") in encodedValues) {
                        valuesByFunction.getOrPut(functionVa) { JSONArray() }.put(JSONObject(row.toString()).apply {
                            remove("type"); remove("functionVa"); remove("function"); remove("class"); remove("file")
                        })
                    }
                }
            }
        }
        consumers.forEach { (functionVa, consumer) ->
            val evidence = valuesByFunction[functionVa] ?: return@forEach
            (0 until evidence.length()).forEach { consumer.values.put(evidence.getJSONObject(it)) }
        }
        val hints = semanticHints.filter(String::isNotBlank).distinctBy(String::lowercase)
        val normalizedFiles = fileHints.map { it.replace('\\', '/').substringAfterLast('/').lowercase() }
            .filter(String::isNotBlank).distinct()
        val consumerRows = consumers.values.mapNotNull { consumer ->
            val signatureContext = contextTypes.filter { type ->
                containsTerm(consumer.function, type) || containsTerm(consumer.clazz, type)
            }
            val matchedHints = hints.filter { hint ->
                containsTerm(consumer.function, hint) || containsTerm(consumer.clazz, hint) ||
                    consumer.file.contains(hint, ignoreCase = true)
            }
            val matchedFiles = normalizedFiles.filter { consumer.file.lowercase().endsWith(it) }
            val decisionKinds = (0 until consumer.decisionEvidence.length()).map { index ->
                consumer.decisionEvidence.getJSONObject(index).optString("kind")
            }
            val decisionScore = decisionKinds.sumOf { kind -> when (kind) {
                "comparison" -> 220
                "direct_conditional_branch", "flags_conditional_branch" -> 260
                "boolean_result" -> 180
                "return" -> 160
                "call_argument" -> 60
                else -> 0
            } }
            val score = signatureContext.size * 300 + matchedFiles.size * 260 + matchedHints.size * 100 +
                consumer.offsets.size * 80 + consumer.reads.length() * 25 + consumer.values.length() * 180 +
                decisionScore + if (consumer.function.contains("bool", ignoreCase = true)) 60 else 0
            if (excludes.isNotEmpty()) {
                val haystack = "${consumer.function} ${consumer.clazz} ${consumer.file}".lowercase()
                if (excludes.any { haystack.contains(it) }) null
            }
            val hasDecisionSink = decisionKinds.any { it != "call_argument" }
            val confidence = when {
                decisionKinds.any { it == "direct_conditional_branch" || it == "flags_conditional_branch" } -> "high"
                hasDecisionSink -> "medium"
                else -> "low"
            }
            JSONObject()
                .put("functionVa", "0x${consumer.functionVa.toString(16)}")
                .put("function", consumer.function.ifBlank { JSONObject.NULL })
                .put("class", consumer.clazz.ifBlank { JSONObject.NULL })
                .put("file", consumer.file)
                .put("score", score)
                .put("fieldOffsets", JSONArray(consumer.offsets.map { "0x${it.toString(16)}" }))
                .put("matchedTypes", JSONArray(signatureContext))
                .put("matchedFiles", JSONArray(matchedFiles))
                .put("matchedHints", JSONArray(matchedHints))
                .put("fieldReads", consumer.reads)
                .put("valueEvidence", consumer.values)
                .put("decisionEvidence", consumer.decisionEvidence)
                .put("hasDecisionSink", hasDecisionSink)
                .put("sliceConfidence", confidence)
        }.sortedWith(compareByDescending<JSONObject> { it.optInt("score") }
            .thenBy { it.optString("functionVa") })
        val writeRows = rankedWrites.take(24).map { write -> JSONObject()
            .put("fieldOffset", "0x${write.offset.toString(16)}")
            .put("functionVa", "0x${write.functionVa.toString(16)}")
            .put("instructionVa", "0x${write.instructionVa.toString(16)}")
            .put("anchorVa", "0x${write.anchorVa.toString(16)}")
            .put("distanceBytes", write.distance)
            .put("function", write.function.ifBlank { JSONObject.NULL })
            .put("class", write.clazz.ifBlank { JSONObject.NULL })
            .put("file", write.file)
            .put("insn", write.insn)
        }
        return JSONObject()
            .put("fieldWrites", JSONArray(writeRows))
            .put("fieldOffsets", JSONArray(fieldOffsets.map { "0x${it.toString(16)}" }))
            .put("inferredTypes", JSONArray(contextTypes))
            .put("consumers", JSONArray(consumerRows.take(limit)))
            .put("consumerCount", consumerRows.size)
            .put("consumerClusters", run {
                val byDir = LinkedHashMap<String, Int>()
                for (row in consumerRows) {
                    val f = row.optString("file")
                    val dirKey = f.substringBeforeLast('/', f).ifBlank { f }
                    byDir[dirKey] = (byDir[dirKey] ?: 0) + 1
                }
                JSONArray(byDir.entries.sortedByDescending { it.value }
                    .take(8)
                    .map { JSONObject().put("dir", it.key).put("count", it.value) })
            })
            .put("excludedConsumers", excludes.size)
            .put("truncated", consumerRows.size > limit)
            .put("lookupMode", "semantic_field_data_flow_with_register_slice")
            .put("sliceWindowInstructions", FIELD_SLICE_WINDOW)
    }

    private fun extractSignatureTypes(signature: String): List<String> {
        val ignored = setOf("static", "dynamic", "void", "bool", "int", "double", "string", "object", "closure")
        val tokens = Regex("[A-Za-z_$][A-Za-z0-9_$]*")
            .findAll(signature.substringBefore('('))
            .map(MatchResult::value)
            .toList()
            .dropLast(1)
        return tokens.asSequence()
            .filter { it.lowercase() !in ignored && (it.firstOrNull()?.isUpperCase() == true || it.any(Char::isUpperCase)) }
            .distinct()
            .toList()
    }

    private fun parseNumeric(raw: String): Long? {
        val text = raw.trim().lowercase()
        return when {
            text.startsWith("-0x") -> text.removePrefix("-0x").toLongOrNull(16)?.let { -it }
            text.startsWith("0x") -> text.removePrefix("0x").toLongOrNull(16)
            else -> text.toLongOrNull()
        }
    }

    private fun signedHex(value: Long): String = if (value < 0) "-0x${(-value).toString(16)}" else "0x${value.toString(16)}"

    fun xref(resultDir: File, poolOffset: Long, limit: Int): JSONObject {
        val asmDir = File(resultDir, "asm")
        val target = poolOffset.toString(16)
        val addressMap = addressMap(resultDir)
        val refs = JSONArray()
        var truncated = false
        var scanned = 0
        asmDir.walkTopDown().filter { it.isFile && it.extension == "dart" }.forEach { file ->
            if (truncated) return@forEach
            val rel = "asm/${file.relativeTo(asmDir).path}"
            var currentClass: String? = null
            var currentFunction: String? = null
            var currentFunctionVa: String? = null
            var pendingSignature: String? = null
            file.useLines { lines ->
                lines.forEach { raw ->
                    val trimmed = raw.trim()
                    if (trimmed.startsWith("class ")) currentClass = className(trimmed)
                    FUNC_ADDR.matchEntire(raw)?.let { header ->
                        currentFunction = pendingSignature
                        currentFunctionVa = "0x${header.groupValues[1].lowercase()}"
                    } ?: run {
                        if (raw.startsWith("  ") && !trimmed.startsWith("//") && trimmed.isNotEmpty()) {
                            pendingSignature = trimmed.trimEnd('{', ' ', ';')
                        }
                    }
                    val hit = REF.findAll(raw).firstOrNull { it.groupValues[1].lowercase() == target } ?: return@forEach
                    if (refs.length() >= limit) { truncated = true; return@forEach }
                    val instructionVa = INSN_ADDR.find(raw)?.groupValues?.get(1)?.toLongOrNull(16)
                    val functionVa = currentFunctionVa?.removePrefix("0x")?.toLongOrNull(16)
                    val va = instructionVa ?: functionVa
                    val fileOffset = va?.let(addressMap::fileOffset)
                    refs.put(JSONObject()
                        .put("va", va?.let { "0x${it.toString(16)}" } ?: currentFunctionVa ?: JSONObject.NULL)
                        .put("elfVa", va?.let { "0x${it.toString(16)}" } ?: JSONObject.NULL)
                        .put("fileOffset", fileOffset?.let { "0x${it.toString(16)}" } ?: JSONObject.NULL)
                        .put("patchLocator", va?.let { "0x${it.toString(16)}" } ?: currentFunctionVa ?: JSONObject.NULL)
                        .put("function", currentFunction ?: JSONObject.NULL)
                        .put("class", currentClass ?: JSONObject.NULL)
                        .put("file", rel)
                        .put("insn", trimmed.take(300))
                        .put("poolEntry", hit.value))
                }
            }
            scanned++
        }
        return JSONObject().put("refs", refs).put("count", refs.length()).put("scannedFiles", scanned).put("truncated", truncated).put("addressMapping", addressMap.status)
    }

    /** 多个池偏移共用一次 asm 扫描，避免每个候选都重复遍历巨大反汇编目录。 */
    fun xrefMany(resultDir: File, poolOffsets: List<Long>, perOffsetLimit: Int): JSONObject {
        val targets = poolOffsets.associateBy { it.toString(16) }
        val refsByOffset = targets.keys.associateWith { JSONArray() }.toMutableMap()
        val addressMap = addressMap(resultDir)
        val functionHeaders = functionHeaders(resultDir).sortedBy(FunctionHeader::va)
        val rawIndexAvailable = File(resultDir, ARM64_POOL_INDEX_V2).isFile || File(resultDir, ARM64_POOL_INDEX).isFile || File(resultDir, ARM64_CLOSURE_CALL_INDEX).isFile
        if (rawIndexAvailable) {
            val nativeFunctions = arm64Functions(resultDir)
            forEachRawClosureCall(resultDir) { row ->
                val rows = refsByOffset[row.poolOffset.toString(16)] ?: return@forEachRawClosureCall
                if (rows.length() >= perOffsetLimit) return@forEachRawClosureCall
                val blutterFunction = functionAtOrBefore(functionHeaders, row.loadVa)
                val nativeFunction = longAtOrBefore(nativeFunctions, row.loadVa)
                val nextNativeFunction = longAfter(nativeFunctions, row.loadVa)
                val verifiedBlutterFunction = blutterFunction?.takeIf {
                    it.size > 0 && row.loadVa >= it.va && row.loadVa < it.va + it.size
                }
                rows.put(JSONObject()
                    .put("va", "0x${row.loadVa.toString(16)}")
                    .put("verificationVa", "0x${row.loadVa.toString(16)}")
                    .put("functionVa", verifiedBlutterFunction?.va?.let { "0x${it.toString(16)}" } ?: JSONObject.NULL)
                    .put("fileOffset", (addressMap.fileOffset(row.loadVa) ?: row.loadFileOffset.toLong()).let { "0x${it.toString(16)}" })
                    .put("function", verifiedBlutterFunction?.name ?: JSONObject.NULL)
                    .put("class", verifiedBlutterFunction?.className ?: JSONObject.NULL)
                    .put("file", verifiedBlutterFunction?.file ?: "libapp.so")
                    .put("functionEvidence", if (verifiedBlutterFunction != null) "blutter_function_range_verified" else "raw_reference_requires_native_boundary")
                    .put("boundaryStatus", if (verifiedBlutterFunction != null) "verified" else "unverified")
                    .put("artifactFunctionHint", blutterFunction?.let { JSONObject()
                        .put("addr", "0x${it.va.toString(16)}")
                        .put("size", if (it.size > 0) "0x${it.size.toString(16)}" else JSONObject.NULL)
                        .put("name", it.name ?: JSONObject.NULL)
                        .put("class", it.className ?: JSONObject.NULL)
                        .put("file", it.file) } ?: JSONObject.NULL)
                    .put("nativeFunctionHint", nativeFunction?.let { "0x${it.toString(16)}" } ?: JSONObject.NULL)
                    .put("nextFunctionVa", nextNativeFunction?.let { "0x${it.toString(16)}" } ?: JSONObject.NULL)
                    .put("insn", if (row.mode == 4) "ldp xN, xM, [x27, #imm]; blr x${row.targetRegister}（闭包+代码对的寄存器间接调用）" else "add xN, x27, #hi; ldp xM, xK, [xN, #imm]; blr x${row.targetRegister}（闭包+代码对的寄存器间接调用）")
                    .put("referenceMode", if (row.mode == 4) "arm64_raw_ldp_pp_blr" else "arm64_raw_add_ldp_pp_blr")
                    .put("indirectCall", true)
                    .put("callVa", "0x${row.callVa.toString(16)}")
                    .put("callFileOffset", "0x${row.callFileOffset.toString(16)}")
                    .put("callRegister", "x${row.targetRegister}"))
            }
            forEachRawPoolReference(resultDir) { row ->
                val rows = refsByOffset[row.poolOffset.toString(16)] ?: return@forEachRawPoolReference
                if (rows.length() >= perOffsetLimit) return@forEachRawPoolReference
                val va = row.va
                val blutterFunction = functionAtOrBefore(functionHeaders, va)
                val nativeFunction = longAtOrBefore(nativeFunctions, va)
                val nextNativeFunction = longAfter(nativeFunctions, va)
                val verifiedBlutterFunction = blutterFunction?.takeIf {
                    it.size > 0 && va >= it.va && va < it.va + it.size
                }
                val rawFileOffset = row.fileOffset.toLong()
                rows.put(JSONObject()
                    .put("va", "0x${va.toString(16)}")
                    .put("verificationVa", "0x${va.toString(16)}")
                    .put("functionVa", verifiedBlutterFunction?.va?.let { "0x${it.toString(16)}" } ?: JSONObject.NULL)
                    .put("fileOffset", (addressMap.fileOffset(va) ?: rawFileOffset)?.let { "0x${it.toString(16)}" } ?: JSONObject.NULL)
                    .put("function", verifiedBlutterFunction?.name ?: JSONObject.NULL)
                    .put("class", verifiedBlutterFunction?.className ?: JSONObject.NULL)
                    .put("file", verifiedBlutterFunction?.file ?: "libapp.so")
                    .put("functionEvidence", if (verifiedBlutterFunction != null) "blutter_function_range_verified" else "raw_reference_requires_native_boundary")
                    .put("boundaryStatus", if (verifiedBlutterFunction != null) "verified" else "unverified")
                    .put("artifactFunctionHint", blutterFunction?.let { JSONObject()
                        .put("addr", "0x${it.va.toString(16)}")
                        .put("size", if (it.size > 0) "0x${it.size.toString(16)}" else JSONObject.NULL)
                        .put("name", it.name ?: JSONObject.NULL)
                        .put("class", it.className ?: JSONObject.NULL)
                        .put("file", it.file) } ?: JSONObject.NULL)
                    .put("nativeFunctionHint", nativeFunction?.let { "0x${it.toString(16)}" } ?: JSONObject.NULL)
                    .put("nextFunctionVa", nextNativeFunction?.let { "0x${it.toString(16)}" } ?: JSONObject.NULL)
                    .put("insn", when (row.mode) {
                        "arm64_raw_ldr_pp" -> "ldr xN, [x27, #imm]（单指令池寻址，PPTool 同源路径）"
                        "arm64_raw_ldp_pp" -> "ldp xN, xM, [x27, #imm]（闭包+代码对成对池加载）"
                        "arm64_raw_add_ldp_pp" -> "add xN, x27, #hi; ldp xM, xK, [xN, #imm]（闭包+代码对成对池加载）"
                        "arm64_raw_add_add_ldr" -> "add xN,x27,#hi; add xM,xN,#lo; ldr [xM,#imm]（双 add 拆分）"
                        else -> "add xN, x27, #hi; ldr [xN, #imm]（add+ldr 池寻址）"
                    })
                    .put("referenceMode", row.mode))
            }
        }
        val missingSemanticTargets = refsByOffset.filterValues { it.length() == 0 }.keys
        // fallback 统一流式语义索引：ensureSemanticIndex 已把所有 asm 注解引用
        // (asm_annotation) 与 add+ldr 池寻址 (arm64_add_ldr_fallback) 写入索引,
        // 与 walkTopDown + useLines 全量扫描 asm 目录等价, 但避免 2700+ 文件
        // 重复遍历 (单次 locate 节省数十秒)。语义索引不存在时由 ensureSemanticIndex
        // 一次性构建并持久化, 后续命中 cache。
        var fallbackScannedRows = 0
        if (missingSemanticTargets.isNotEmpty()) {
            forEachSemanticRow(resultDir) { row ->
                fallbackScannedRows++
                if (row.optString("type") != "reference") return@forEachSemanticRow
                val offset = row.optString("offset")
                if (offset !in missingSemanticTargets) return@forEachSemanticRow
                val rows = refsByOffset[offset] ?: return@forEachSemanticRow
                if (rows.length() >= perOffsetLimit) return@forEachSemanticRow
                val va = row.optString("va").toLongOrNull(16)
                rows.put(JSONObject()
                    .put("va", va?.let { "0x${it.toString(16)}" } ?: JSONObject.NULL)
                    .put("functionVa", row.optString("functionVa").takeIf(String::isNotBlank)?.let { "0x$it" } ?: JSONObject.NULL)
                    .put("fileOffset", va?.let(addressMap::fileOffset)?.let { "0x${it.toString(16)}" } ?: JSONObject.NULL)
                    .put("function", row.opt("function") ?: JSONObject.NULL)
                    .put("class", row.opt("class") ?: JSONObject.NULL)
                    .put("file", row.optString("file"))
                    .put("insn", row.optString("insn"))
                    .put("referenceMode", row.optString("referenceMode")))
            }
        }
        val result = JSONObject()
        refsByOffset.forEach { (offset, refs) -> result.put("0x$offset", refs) }
        return JSONObject()
            .put("refsByOffset", result)
            .put("scannedFiles", fallbackScannedRows)
            .put("lookupMode", when {
                rawIndexAvailable && missingSemanticTargets.isEmpty() -> "compact_pool_index"
                rawIndexAvailable -> "compact_pool_index_with_semantic_fallback"
                else -> "semantic_index"
            })
            .put("addressMapping", addressMap.status)
    }

    private fun functionAtOrBefore(headers: List<FunctionHeader>, va: Long): FunctionHeader? {
        val found = headers.binarySearchBy(va, selector = FunctionHeader::va)
        val index = if (found >= 0) found else -found - 2
        return headers.getOrNull(index)
    }

    private fun longAtOrBefore(values: List<Long>, va: Long): Long? {
        val found = values.binarySearch(va)
        val index = if (found >= 0) found else -found - 2
        return values.getOrNull(index)
    }

    private fun longAfter(values: List<Long>, va: Long): Long? {
        val found = values.binarySearch(va)
        val index = if (found >= 0) found + 1 else -found - 1
        return values.getOrNull(index)
    }

    /**
     * 按 VA 读取 blutter asm 中所属函数的完整反汇编体（含 [pp+0x...] 内联注释）。
     * 官方工作流核心一步：xref 拿到函数 VA 后读 asm 树下的函数文件，每条 ldr x?, [x27, #off]
     * 后的池对象注释（String:"is_vip" 等）直接可见，无需盲猜指令语义。
     * 命中规则：优先取 addr <= va < addr+size 的函数头；无精确命中时回退到
     * addr <= va 的最近函数头（matchMode=nearest）。
     */
    fun disasmFunction(
        resultDir: File,
        va: Long,
        maxLines: Int,
        lineOffset: Int = 0,
        vaUntil: Long = 0,
    ): JSONObject {
        // vaUntil>0：只输出 VA < vaUntil 的行（大函数按分支/判定区间取窗口），
        // 行数预算仍受 maxLines 约束。

        val asmDir = File(resultDir, "asm")
        var exact: FunctionHit? = null
        var nearest: FunctionHit? = null
        // 函数头走小体积缓存（列表仅几千条），避免每次 disasm 都流式全扫语义索引。
        // size 信息在索引的 function 行里，缓存结构需带 size。
        forEachFunctionHeaderRow(resultDir) { addr, size, name, className, file ->
            val hit = FunctionHit(addr, size, name, className, file)
            if (size > 0 && va >= addr && va < addr + size) exact = hit
            if (addr <= va && (nearest == null || addr > nearest!!.addr)) nearest = hit
        }
        var hit = exact
        if (hit == null) hit = nearest
        if (hit == null) {
            return JSONObject()
                .put("found", false)
                .put("reason", "VA_NOT_IN_ASM")
                .put("hint", "blutter 未还原该地址所在函数（可能是桩/未分析区域）。改用 so_analyze(action=disasm, addr=...) 看裸反汇编。")
        }
        // 二次读取：函数头行 → 下一个函数头（或文件尾）。
        // 流式读取：原先 readLines() 把整个 asm 文件读进内存只为切出一个
        // 函数体（asm 单文件可达数 MB）；收集到 maxLines 行后多看一行即可
        // 判定截断，无需读全文件。
        val targetFile = File(asmDir, hit.file.removePrefix("asm/"))
        val body = mutableListOf<String>()
        var headerFound = false
        var truncated = false
        var minInstructionVa: Long? = null
        var maxInstructionVa: Long? = null
        var requestedVaObserved = false
        var totalInstructionCount = 0
        // lineCount = 函数总行数（含截断后的未返回部分，只计数不驻留内存）。
        var totalLines = 0
        targetFile.useLines { seq ->
            for (raw in seq) {
                if (!headerFound) {
                    val m = FUNC_ADDR.matchEntire(raw)
                    if (m != null && m.groupValues[1].toLongOrNull(16) == hit.addr) {
                        headerFound = true
                        totalLines = 1
                        if (lineOffset == 0) body += raw
                    }
                    continue
                }
                if (FUNC_ADDR.matchEntire(raw) != null) break // 下一个函数头：函数体结束
                totalLines++
                val lineVa = INSN_VA.find(raw)?.groupValues?.get(1)?.toLongOrNull(16)
                if (lineVa != null) {
                    minInstructionVa = minInstructionVa?.let { minOf(it, lineVa) } ?: lineVa
                    maxInstructionVa = maxInstructionVa?.let { maxOf(it, lineVa) } ?: lineVa
                    requestedVaObserved = requestedVaObserved || lineVa == va
                    totalInstructionCount++
                }
                if (vaUntil > va) {
                    if (lineVa != null && lineVa >= vaUntil) {
                        truncated = true
                        break
                    }
                }
                if (totalLines > lineOffset && body.size < maxLines) {
                    body += raw
                } else if (totalLines > lineOffset) {
                    truncated = true // 已满 maxLines 行仍未到函数尾
                }
            }
        }
        if (!headerFound) return JSONObject().put("found", false).put("reason", "HEADER_LINE_NOT_FOUND")
        val returnedInstructionCount = body.count { Regex("//\\s*0x[0-9a-fA-F]+:").containsMatchIn(it) }
        val observedStart = minInstructionVa
        val observedEnd = maxInstructionVa?.plus(4)
        if (exact == null || hit.size <= 0 || totalInstructionCount == 0 || !requestedVaObserved) {
            val reason = when {
                exact == null -> "FUNCTION_BOUNDARY_UNVERIFIED"
                hit.size <= 0 || totalInstructionCount == 0 -> "FUNCTION_BODY_UNAVAILABLE"
                else -> "VA_NOT_IN_FUNCTION_BODY"
            }
            return JSONObject()
                .put("found", false)
                .put("usable", false)
                .put("reason", reason)
                .put("va", "0x${va.toString(16)}")
                .put("rawDisasmRequired", true)
                .put("rawDisasmVa", "0x${va.toString(16)}")
                .put("observedRange", if (observedStart != null && observedEnd != null) JSONObject().put("startAddr", "0x${observedStart.toString(16)}").put("endAddr", "0x${observedEnd.toString(16)}") else JSONObject.NULL)
                .put("function", JSONObject()
                    .put("addr", "0x${hit.addr.toString(16)}")
                    .put("size", if (hit.size > 0) "0x${hit.size.toString(16)}" else JSONObject.NULL)
                    .put("name", hit.name ?: JSONObject.NULL)
                    .put("class", hit.className ?: JSONObject.NULL)
                    .put("file", hit.file))
                .put("hint", "Blutter 函数边界未被指令体证实。请从该字符串引用指令 VA 做原生反汇编，不要把该函数头或大小当补丁边界。")
        }
        // 条件分支检测：会员判断最常见载体（tbnz/tbz/b.cond/cbz/cbnz）。
        // 写状态/void 函数不能 force_return_constant，分支改写是首选手法。
        val condBranchRe = Regex("\\b(tbnz|tbz|b\\.(eq|ne|gt|lt|ge|le|hi|lo|hs|ls)|cbz|cbnz)\\b", RegexOption.IGNORE_CASE)
        val rawCondBranchLines = body.withIndex().filter { condBranchRe.containsMatchIn(it.value) }
        val guardMarkers = listOf("CheckStackOverflow", "BoxInt64Instr", "AllocateMint", "RangeError", "NullError")
        val condBranchLines = rawCondBranchLines.filter { indexed ->
            body.subList(maxOf(0, indexed.index - 5), indexed.index + 1)
                .none { line -> guardMarkers.any(line::contains) }
        }.map { it.value }
        val patchHint = if (condBranchLines.isEmpty()) {
            "函数体无业务条件分支；栈检查、装箱和运行时保护分支已排除。先确认返回值确属目标状态/等级；只有返回类型和目标常量都明确时，才用 force_return_constant dryRun。"
        } else {
            "检测到 ${condBranchLines.size} 条非运行时保护条件分支。逐条确认比较值和成功分支后才能 dryRun；禁止仅凭分支数量直接 nop 或改跳转。"
        }
        val hasMore = totalLines > lineOffset + body.size
        return JSONObject()
            .put("found", true)
            .put("usable", true)
            .put("lookupMode", "compact_function_index")
            .put("matchMode", "exact")
            .put("boundaryConfidence", "artifact_and_instruction_verified")
            .put("va", "0x" + va.toString(16))
            .put("function", JSONObject()
                .put("addr", "0x" + hit.addr.toString(16))
                .put("size", "0x" + hit.size.toString(16))
                .put("name", hit.name ?: JSONObject.NULL)
                .put("class", hit.className ?: JSONObject.NULL)
                .put("file", hit.file))
            .put("lines", JSONArray(body))
            .put("lineCount", totalLines)
            .put("returnedLines", body.size)
            .put("offset", lineOffset)
            .put("hasMore", hasMore)
            .put("nextOffset", if (hasMore) lineOffset + body.size else JSONObject.NULL)
            .put("instructionCount", totalInstructionCount)
            .put("returnedInstructionCount", returnedInstructionCount)
            .put("truncated", truncated || lineOffset > 0)
            .put("hasBusinessConditionalBranch", condBranchLines.isNotEmpty())
            .put("businessConditionalBranchCount", condBranchLines.size)
            .put("ignoredGuardBranchCount", rawCondBranchLines.size - condBranchLines.size)
            .put("poolHint", "lines 中 [pp+0x...] 是 x27 对象池引用注释（String:\"...\"/Object 等），即该指令加载的 Dart 对象；修改判断逻辑前先读完整个函数体。")
            .put("patchHint", patchHint)
    }

    private data class FunctionHit(val addr: Long, val size: Long, val name: String?, val className: String?, val file: String)

    /**
     * 反向引用（函数 → 调用者）：扫全部 asm，找 bl / 尾调用 b 直接跳转到目标 VA 的调用点。
     * 与 xref（池偏移 → 引用指令）互为反向：xref 答"这个字符串/对象被谁用"，
     * callers 答"这个函数被谁调"。补丁后验证影响面 / 逆向追调用链均用它一次拿全。
     */
    fun callersOf(resultDir: File, va: Long, limit: Int, poolOffsets: List<Long> = emptyList()): JSONObject {
        val asmDir = File(resultDir, "asm")
        val target = va.toString(16)
        val callers = JSONArray()
        var truncated = false
        var scanned = 0
        asmDir.walkTopDown().filter { it.isFile && it.extension == "dart" }.forEach { file ->
            if (truncated) return@forEach
            val rel = "asm/${file.relativeTo(asmDir).path}"
            var currentClass: String? = null
            var currentFunction: String? = null
            var currentFunctionVa: String? = null
            var pendingSignature: String? = null
            file.useLines { lines ->
                lines.forEach { raw ->
                    val trimmed = raw.trim()
                    if (trimmed.startsWith("class ")) currentClass = className(trimmed)
                    FUNC_ADDR.matchEntire(raw)?.let { header ->
                        currentFunction = pendingSignature
                        currentFunctionVa = "0x${header.groupValues[1].lowercase()}"
                    } ?: run {
                        if (raw.startsWith("  ") && !trimmed.startsWith("//") && trimmed.isNotEmpty()) {
                            pendingSignature = trimmed.trimEnd('{', ' ', ';')
                        }
                    }
                    // 行级预筛：bl/b 目标为 target 的行必然包含该 hex 子串（超集安全），
                    // 数千万行只对极少数候选行跑正则
                    if (!raw.contains(target, ignoreCase = true)) return@forEach
                    val hit = CALL_TARGET_RE.findAll(raw).firstOrNull { it.groupValues[2].lowercase() == target } ?: return@forEach
                    if (callers.length() >= limit) { truncated = true; return@forEach }
                    val callVa = INSN_ADDR.find(raw)?.groupValues?.get(1)?.toLongOrNull(16)
                    callers.put(JSONObject()
                        .put("callVa", callVa?.let { "0x${it.toString(16)}" } ?: currentFunctionVa ?: JSONObject.NULL)
                        .put("functionVa", currentFunctionVa ?: JSONObject.NULL)
                        .put("function", currentFunction ?: JSONObject.NULL)
                        .put("class", currentClass ?: JSONObject.NULL)
                        .put("file", rel)
                        .put("insn", trimmed.take(300))
                        .put("callType", "direct"))
                }
            }
            scanned++
        }
        val directCount = callers.length()
        val inferredPoolOffsets = closurePoolOffsetsForCodeVa(resultDir, va)
        val closurePoolOffsets = (poolOffsets + inferredPoolOffsets).distinct()
        if (!truncated && closurePoolOffsets.isNotEmpty()) {
            val closureTargets = closurePoolOffsets.toSet()
            val headers = functionHeaders(resultDir).sortedBy(FunctionHeader::va)
            val nativeFunctions = arm64Functions(resultDir)
            val addressMap = addressMap(resultDir)
            forEachRawClosureCall(resultDir) { row ->
                if (truncated || row.poolOffset !in closureTargets) return@forEachRawClosureCall
                if (callers.length() >= limit) {
                    truncated = true
                    return@forEachRawClosureCall
                }
                val blutterFunction = functionAtOrBefore(headers, row.loadVa)
                val nativeFunction = longAtOrBefore(nativeFunctions, row.loadVa)
                val functionVa = blutterFunction?.va ?: nativeFunction
                callers.put(JSONObject()
                    .put("callVa", "0x${row.callVa.toString(16)}")
                    .put("functionVa", functionVa?.let { "0x${it.toString(16)}" } ?: JSONObject.NULL)
                    .put("function", blutterFunction?.name ?: JSONObject.NULL)
                    .put("class", blutterFunction?.className ?: JSONObject.NULL)
                    .put("file", blutterFunction?.file ?: "libapp.so")
                    .put("fileOffset", (addressMap.fileOffset(row.callVa) ?: row.callFileOffset.toLong()).let { "0x${it.toString(16)}" })
                    .put("poolOffset", "0x${row.poolOffset.toString(16)}")
                    .put("insn", "blr x${row.targetRegister}（对象池闭包代码间接调用）")
                    .put("callType", "closure_indirect")
                    .put("referenceMode", if (row.mode == 4) "arm64_raw_ldp_pp_blr" else "arm64_raw_add_ldp_pp_blr"))
            }
        }
        return JSONObject()
            .put("callers", callers)
            .put("count", callers.length())
            .put("directCallersCount", directCount)
            .put("indirectClosureCallersCount", callers.length() - directCount)
            .put("closurePoolOffsets", JSONArray(closurePoolOffsets.map { "0x${it.toString(16)}" }))
            .put("closurePoolOffsetSource", when {
                poolOffsets.isNotEmpty() && inferredPoolOffsets.isNotEmpty() -> "explicit_and_pp_code_entry"
                poolOffsets.isNotEmpty() -> "explicit"
                inferredPoolOffsets.isNotEmpty() -> "pp_code_entry"
                else -> "none"
            })
            .put("scannedFiles", scanned)
            .put("truncated", truncated)
    }

    private fun closurePoolOffsetsForCodeVa(resultDir: File, va: Long): List<Long> {
        val needle = "0x${va.toString(16)}"
        val offsets = linkedSetOf<Long>()
        forEachPpLine(resultDir) { line ->
            if (line.contains(needle, ignoreCase = true)) {
                PP_OFFSET.find(line)?.groupValues?.getOrNull(1)?.toLongOrNull(16)?.let(offsets::add)
            }
            true
        }
        return offsets.toList()
    }

    private data class PpCandidate(
        val offset: String,
        val text: String,
        val matchedTerms: List<String>,
        val score: Int,
    )

    private data class FunctionHeader(val va: Long, val size: Long, val name: String?, val className: String?, val file: String)

    private data class CodeRange(val fileOffset: Int, val fileEnd: Int, val virtualAddress: Long)

    private fun arm64Functions(resultDir: File): List<Long> {
        val index = File(resultDir, ARM64_FUNCTION_INDEX)
        if (!index.isFile) return emptyList()
        val key = Arm64FunctionsCacheKey(index.absoluteFile.normalize().path, index.lastModified(), index.length())
        synchronized(this) { arm64FunctionsCache[key]?.let { return it } }
        val functions = index.useLines { lines -> lines.mapNotNull { runCatching { JSONObject(it).optString("va").toLongOrNull(16) }.getOrNull() }.sorted().toList() }
        synchronized(this) { arm64FunctionsCache[key] = functions }
        return functions
    }

    private fun arm64ExecutableRanges(bytes: ByteArray): List<CodeRange> {
        if (bytes.size < 64 || bytes[0] != 0x7f.toByte() || bytes[1] != 'E'.code.toByte() || bytes[2] != 'L'.code.toByte() || bytes[3] != 'F'.code.toByte()) return listOf(CodeRange(0, bytes.size, 0))
        val phoff = u64(bytes, 32).toInt()
        val entrySize = u16(bytes, 54)
        val count = u16(bytes, 56)
        if (entrySize < 56 || phoff < 0 || phoff + entrySize * count > bytes.size) return listOf(CodeRange(0, bytes.size, 0))
        return (0 until count).mapNotNull { index ->
            val at = phoff + index * entrySize
            val type = u32(bytes, at)
            val flags = u32(bytes, at + 4)
            val fileOffset = u64(bytes, at + 8).toInt()
            val virtualAddress = u64(bytes, at + 16)
            val fileSize = u64(bytes, at + 32).toInt()
            if (type == 1 && flags and 1 != 0 && fileOffset >= 0 && fileSize > 0 && fileOffset + fileSize <= bytes.size) CodeRange(fileOffset, fileOffset + fileSize, virtualAddress) else null
        }
    }

    private fun arm64ExecutableRanges(file: File): List<CodeRange> = runCatching {
        RandomAccessFile(file, "r").use { input ->
            val length = input.length()
            if (length < 64) return@use listOf(CodeRange(0, length.toInt(), 0))
            val header = ByteArray(64)
            input.readFully(header)
            if (header[0] != 0x7f.toByte() || header[1] != 'E'.code.toByte() || header[2] != 'L'.code.toByte() || header[3] != 'F'.code.toByte()) {
                return@use listOf(CodeRange(0, length.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(), 0))
            }
            val phoff = u64(header, 32).toInt()
            val entrySize = u16(header, 54)
            val count = u16(header, 56)
            val tableBytes = entrySize.toLong() * count
            if (entrySize < 56 || phoff < 0 || tableBytes > 8L * 1024 * 1024 || phoff.toLong() + tableBytes > length) {
                return@use listOf(CodeRange(0, length.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(), 0))
            }
            val table = ByteArray(tableBytes.toInt())
            input.seek(phoff.toLong())
            input.readFully(table)
            (0 until count).mapNotNull { index ->
                val at = index * entrySize
                val type = u32(table, at)
                val flags = u32(table, at + 4)
                val fileOffset = u64(table, at + 8).toInt()
                val virtualAddress = u64(table, at + 16)
                val fileSize = u64(table, at + 32).toInt()
                if (type == 1 && flags and 1 != 0 && fileOffset >= 0 && fileSize > 0 && fileOffset.toLong() + fileSize <= length) CodeRange(fileOffset, fileOffset + fileSize, virtualAddress) else null
            }
        }
    }.getOrElse {
        listOf(CodeRange(0, file.length().coerceAtMost(Int.MAX_VALUE.toLong()).toInt(), 0))
    }

    private fun isArm64FramePrologue(word: Int): Boolean = (word and 0xffc07c1f.toInt()) == 0xa980781d.toInt()

    private fun u16(bytes: ByteArray, offset: Int): Int = (bytes[offset].toInt() and 0xff) or ((bytes[offset + 1].toInt() and 0xff) shl 8)

    private fun u32(bytes: ByteArray, offset: Int): Int = arm64Word(bytes, offset)

    private fun u64(bytes: ByteArray, offset: Int): Long = (u32(bytes, offset).toLong() and 0xffffffffL) or ((u32(bytes, offset + 4).toLong() and 0xffffffffL) shl 32)

    private fun addressMap(resultDir: File): AddressMap {
        val result = runCatching { JSONObject(File(resultDir, "result.json").readText()) }.getOrNull() ?: return AddressMap.empty
        val segments = result.optJSONArray("libappLoadSegments") ?: return AddressMap.empty
        return AddressMap((0 until segments.length()).mapNotNull { index ->
            segments.optJSONObject(index)?.let { row ->
                val va = row.optString("virtualAddress").removePrefix("0x").toLongOrNull(16)
                val offset = row.optString("fileOffset").removePrefix("0x").toLongOrNull(16)
                val size = row.optString("fileSize").removePrefix("0x").toLongOrNull(16)
                if (va != null && offset != null && size != null) LoadSegment(va, offset, size) else null
            }
        })
    }

    private data class LoadSegment(val virtualAddress: Long, val fileOffset: Long, val fileSize: Long)

    private class AddressMap(private val segments: List<LoadSegment>) {
        // 地址体系说明：blutter asm 中的地址就是 libapp.so 的 ELF VA；
        // fileOffset 是经 PT_LOAD 段换算的 ELF 文件偏移，与 edit_asm/edit_hex
        // 的裸 VA 同体系，可直接作 locator 使用（edit 前先 hexdump 核对 oldHex）。
        val status: String = if (segments.isEmpty()) "unavailable" else "elf_load_segments:va=libapp_elf_va;fileOffset=elf_file_offset;patchLocator=elf_va_usable_as_edit_locator"

        fun fileOffset(va: Long): Long? = segments.firstOrNull {
            va >= it.virtualAddress && va - it.virtualAddress < it.fileSize
        }?.let { it.fileOffset + va - it.virtualAddress }

        companion object {
            val empty = AddressMap(emptyList())
        }
    }

    private fun className(line: String): String =
        line.removePrefix("class ").substringBefore('{').substringBefore("//")
            .substringBefore(" extends ").substringBefore(" implements ").substringBefore(" with ").substringBefore(" on ").trim()

    private fun parseImmediate(raw: String): Long =
        if (raw.startsWith("0x", true)) raw.substring(2).toLongOrNull(16) ?: 0L
        else raw.toLongOrNull() ?: 0L

    private fun registerNumber(raw: String): Int {
        val register = raw.trim().lowercase()
        if (register == "sp") return 32
        return register.dropWhile { it == 'x' || it == 'w' }.toIntOrNull() ?: 127
    }

    private fun arm64Word(bytes: ByteArray, offset: Int): Int =
        (bytes[offset].toInt() and 0xff) or
            ((bytes[offset + 1].toInt() and 0xff) shl 8) or
            ((bytes[offset + 2].toInt() and 0xff) shl 16) or
            ((bytes[offset + 3].toInt() and 0xff) shl 24)

    private fun contains(haystack: String, needle: String, caseInsensitive: Boolean): Boolean =
        if (caseInsensitive) haystack.lowercase().contains(needle) else haystack.contains(needle)


    /** 统计函数头二进制条目数（轻量流式读，用于 cacheHit 分支回填计数）。 */
    @Synchronized
    internal fun functionHeaderCount(resultDir: File): Int {
        val index = File(resultDir, FUNCTION_HEADER_INDEX)
        if (!index.isFile) return 0
        var n = 0
        runCatching {
            DataInputStream(index.inputStream().buffered()).use { inp ->
                if (inp.readInt() != FUNCTION_HEADER_INDEX_MAGIC) return 0
                while (true) {
                    inp.readLong(); inp.readLong(); inp.readUTF(); inp.readUTF(); inp.readUTF()
                    n++
                }
            }
        }
        return n
    }

    /** asm 函数头行 "// ** addr: 0x..., size: -0x..." → (va,size)；非头返回 null。供合并索引器复用。 */
    internal fun headerAddrSize(rawLine: String): Pair<Long, Long>? {
        val m = FUNC_ADDR.matchEntire(rawLine) ?: return null
        val sizeRaw = m.groupValues[2].lowercase()
        return m.groupValues[1].toLongOrNull(16)!! to (if (sizeRaw.startsWith("-")) 0L else sizeRaw.toLongOrNull(16) ?: 0L)
    }


    /**
     * 多词预过滤正则：任一词在文本中出现即命中。只作行级预筛（超集），
     * 精确匹配仍在调用方逐词执行，结果与无预筛完全一致：
     * 正则无命中 => 任何词都不在文本中出现（词面量经 Pattern.quote 转义）。
     */
    private fun anyOfRegex(needles: List<String>, ignoreCase: Boolean): Regex? {
        val literals = needles.filter(String::isNotEmpty)
            .map { java.util.regex.Pattern.quote(it) }
        if (literals.isEmpty()) return null
        return Regex(literals.joinToString("|"), if (ignoreCase) setOf(RegexOption.IGNORE_CASE) else emptySet())
    }

    /** 短词用词边界，避免 tun 命中 opportunity、ad 命中无关单词。 */
    private fun containsTerm(haystack: String, needle: String): Boolean {
        if (needle.any { it.code > 0x7f }) return haystack.contains(needle, ignoreCase = true)
        var start = haystack.indexOf(needle, ignoreCase = true)
        while (start >= 0) {
            val end = start + needle.length
            val leftOk = if (needle.length <= 3) {
                start == 0 || !haystack[start - 1].isLetter()
            } else {
                start == 0 || !haystack[start - 1].isLetterOrDigit() ||
                    (haystack[start].isUpperCase() && haystack[start - 1].isLowerCase())
            }
            val rightOk = if (needle.length <= 3) {
                end == haystack.length || !haystack[end].isLetter()
            } else {
                end == haystack.length || !haystack[end].isLetterOrDigit() ||
                    (haystack[end].isUpperCase() && haystack[end - 1].isLowerCase())
            }
            if (leftOk && rightOk) return true
            start = haystack.indexOf(needle, start + 1, ignoreCase = true)
        }
        return false
    }
}
