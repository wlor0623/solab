package zhou.solab.engine

import org.json.JSONObject
import java.io.BufferedReader
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.InputStreamReader
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.LinkedHashMap

/**
 * pp.txt 倒排索引：把"百万行全文扫"变成"词表候选集 + 原语义逐行复核"。
 *
 * 覆盖范围：只索引真实池项行（以 [pp+0x..] 开头的行）——与三个消费方
 * （searchPp / profileAndLocatePp / locatePp）的命中域一致，非池项行在旧
 * 路径中也从不参与匹配。
 *
 * 词条规则（全部小写），确保对纯 ASCII 字母数字词条构成 containsTerm
 * （\b 词边界 + 驼峰内部判定的超集）：
 *   按 [^A-Za-z0-9]+ 分段 → 每段按 小写→大写 切 camel 片段 → 输出所有
 *   连续片段拼接变体。查询时任何词条不满足 纯[a-z0-9]{2,} / 词缺失 /
 *   热词溢出，一律回退旧全量扫描——快路径永不做错，只做少。
 */
internal object PpPostings {
    private const val BIN = "blutter-pp-postings-v1.bin"
    private const val MAGIC = 0x50504931 // IPP1
    private const val MAX_TOKEN_POSTINGS = 20_000
    private const val MAX_LOADED = 2
    private val PP_HEADER = Regex("^\\s*\\[pp\\+0x([0-9a-fA-F]+)]", RegexOption.IGNORE_CASE)
    internal val EXACT_TERM = Regex("[a-z0-9]{2,}")
    private val SEGMENT_RE = Regex("[A-Za-z0-9]+")
    private val CAMEL_SPLIT = Regex("(?<=[a-z0-9])(?=[A-Z])")

    class Loaded(
        val ppMtime: Long,
        val ppSize: Long,
        val lineCount: Int,
        /** 行号 → 行起始字节偏移（pp.txt 为 LF 单字节，偏移即字节计数）。 */
        val lineOffsets: LongArray,
        val tokens: HashMap<String, IntArray>,
        internal val dir: File,
    ) {
        val raf: RandomAccessFile by lazy { RandomAccessFile(File(dir, "pp.txt"), "r") }
        fun close() = runCatching { raf.close() }
    }

    private val cache = LinkedHashMap<File, Loaded>(4, 0.75f, true)

    @Synchronized
    fun invalidate(resultDir: File) {
        val key = resultDir.absoluteFile.normalize()
        cache.remove(key)?.close()
    }

    fun sidecar(resultDir: File): File = File(resultDir, BIN)

    /**
     * 单行词条集合：提取有序的字母数字段（段内再切 camel 片段），然后对
     * "有序片段列表的全部连续区间拼接"生成变体——覆盖 containsTerm 的
     * 词边界规则，包括跨 `_`/数字等分隔符邻接的情形（如 x_vip_z 命中 vipz）。
     */
    internal fun tokensForLine(line: String): HashSet<String> {
        val out = HashSet<String>(8)
        val pieces = ArrayList<String>(16)
        for (segMatch in SEGMENT_RE.findAll(line)) {
            val seg = segMatch.value
            if (seg.any { it.isUpperCase() }) pieces += seg.split(CAMEL_SPLIT) else pieces += seg
        }
        if (pieces.isEmpty()) return out
        var i = 0
        while (i < pieces.size) {
            var acc = ""
            var j = i
            while (j < pieces.size && j - i < 10) {
                acc += pieces[j]
                if (acc.length >= 2) out.add(acc.lowercase())
                j++
            }
            i++
            if (i > 4000) break // 极端长行的防御性上限
        }
        return out
    }

    /**
     * 单遍流式构建：ISO-8859-1 读行（单字节字符集，char==byte，行号与
     * 字节偏移严格一致；词法仅消费 ASCII 词段，非 ASCII 字节自动落入
     * 分段器之外）。构建成本 ≈ 一次旧式全量扫描，由分析提交后的后台
     * 任务预热。
     */
    fun build(resultDir: File): JSONObject {
        val pp = File(resultDir, "pp.txt")
        require(pp.isFile) { "PP_NOT_FOUND" }
        val started = System.nanoTime()
        val offsets = ArrayList<Long>(1 shl 16)
        val dict = HashMap<String, GrowableInts>(1 shl 16)
        val hotTokens = HashSet<String>()
        var bytePos = 0L
        var entryLines = 0L

        fun processLine(line: String, lineStart: Long) {
            val lineId = offsets.size
            offsets.add(lineStart)
            if (PP_HEADER.containsMatchIn(line)) entryLines++
            for (tok in tokensForLine(line)) {
                if (!hotTokens.contains(tok)) {
                val list = dict.getOrPut(tok) { GrowableInts() }
                list.add(lineId)
                if (list.size > MAX_TOKEN_POSTINGS) {
                    dict.remove(tok)
                    hotTokens.add(tok)
                }
                }
            }
        }

        BufferedReader(InputStreamReader(pp.inputStream().buffered(1 shl 20), Charsets.ISO_8859_1), 1 shl 17).use { reader ->
            while (true) {
                val raw = reader.readLine() ?: break
                val lineStart = bytePos
                processLine(raw, lineStart)
                // readLine 已剥离 \n 或 \r\n；统一 +1 与写入侧假设一致（pp.txt 恒为 LF）
                bytePos += raw.length + 1L
            }
        }

        val temp = File(resultDir, "$BIN.tmp")
        DataOutputStream(temp.outputStream().buffered(1 shl 20)).use { out ->
            out.writeInt(MAGIC)
            out.writeInt(1)
            out.writeLong(pp.lastModified())
            out.writeLong(pp.length())
            out.writeInt(offsets.size)
            offsets.forEach { out.writeLong(it) }
            out.writeInt(dict.size)
            for ((tok, list) in dict) {
                out.writeUTF(tok)
                val arr = list.toArray()
                out.writeInt(arr.size)
                var acc = 0
                for (v in arr) {
                    out.writeInt(v - acc)
                    acc = v
                }
            }
        }
        Files.move(
            temp.toPath(), sidecar(resultDir).toPath(),
            StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING,
        )
        invalidate(resultDir)
        return JSONObject()
            .put("lineIds", offsets.size)
            .put("entryLines", entryLines)
            .put("tokens", dict.size)
            .put("hotTokens", hotTokens.size)
            .put("elapsedMs", (System.nanoTime() - started) / 1_000_000)
    }

    /** 可用则返回加载实例；sidecar 缺失/pp 变更/损坏返回 null。 */
    @Synchronized
    fun get(resultDir: File): Loaded? {
        val key = resultDir.absoluteFile.normalize()
        cache[key]?.let { l ->
            val pp = File(key, "pp.txt")
            return if (l.ppMtime == pp.lastModified() && l.ppSize == pp.length()) l
            else {
                l.close()
                cache.remove(key)
                null
            }
        }
        val bin = sidecar(key)
        val pp = File(key, "pp.txt")
        if (!bin.isFile || !pp.isFile) return null
        val l = runCatching {
            DataInputStream(bin.inputStream().buffered()).use { inp ->
                if (inp.readInt() != MAGIC || inp.readInt() != 1) return@runCatching null
                val mtime = inp.readLong()
                val size = inp.readLong()
                if (mtime != pp.lastModified() || size != pp.length()) return@runCatching null
                val n = inp.readInt()
                val offsets = LongArray(n) { inp.readLong() }
                val dictSize = inp.readInt()
                val tokens = HashMap<String, IntArray>(dictSize * 2)
                repeat(dictSize) {
                    val tok = inp.readUTF()
                    val cnt = inp.readInt()
                    var acc = 0
                    tokens[tok] = IntArray(cnt) { j ->
                        acc += inp.readInt()
                        acc
                    }
                }
                Loaded(mtime, size, n, offsets, tokens, key)
            }
        }.getOrNull() ?: return null
        cache[key] = l
        while (cache.size > MAX_LOADED) {
            val eldest = cache.entries.iterator()
            val e = eldest.next()
            e.value.close()
            eldest.remove()
        }
        return l
    }

    /**
     * 候选行号并集（升序）。任一词条无法精确映射则返回 null，调用方必须
     * 回退旧全量路径。
     */
    fun candidateIds(l: Loaded, termsLower: Collection<String>): IntArray? {
        if (termsLower.isEmpty()) return null
        val merged = HashSet<Int>()
        for (raw in termsLower) {
            val t = raw.trim().lowercase()
            if (!EXACT_TERM.matches(t)) return null
            val ids = l.tokens[t] ?: return null
            for (id in ids) merged.add(id)
        }
        val arr = merged.toIntArray()
        arr.sort()
        return arr
    }

    fun candidateIdsForAny(l: Loaded, termGroups: Collection<Collection<String>>): IntArray? {
        if (termGroups.isEmpty()) return null
        val merged = HashSet<Int>()
        for (group in termGroups) {
            val terms = group.map { it.trim().lowercase() }.distinct()
            if (terms.isEmpty() || terms.any { !EXACT_TERM.matches(it) }) return null
            var common = l.tokens[terms.first()] ?: return null
            for (term in terms.drop(1)) {
                val ids = l.tokens[term] ?: return null
                val intersection = IntArray(minOf(common.size, ids.size))
                var left = 0
                var right = 0
                var size = 0
                while (left < common.size && right < ids.size) {
                    when {
                        common[left] < ids[right] -> left++
                        common[left] > ids[right] -> right++
                        else -> {
                            intersection[size++] = common[left]
                            left++
                            right++
                        }
                    }
                }
                common = intersection.copyOf(size)
                if (common.isEmpty()) break
            }
            for (id in common) merged.add(id)
        }
        val arr = merged.toIntArray()
        arr.sort()
        return arr
    }

    /** 读单行原文（不含换行）。越界返回 null。 */
    fun readLine(l: Loaded, lineId: Int): String? {
        if (lineId < 0 || lineId >= l.lineCount) return null
        val start = l.lineOffsets[lineId]
        val end = if (lineId + 1 < l.lineCount) l.lineOffsets[lineId + 1] else File(l.dir, "pp.txt").length()
        val len = (end - start).toInt()
        if (len <= 0) return ""
        val bytes = ByteArray(len)
        synchronized(l.raf) {
            l.raf.seek(start)
            l.raf.readFully(bytes)
        }
        // 行内容按 UTF-8 解码；偏移计数与解码无关（始终字节）
        var s = String(bytes, Charsets.UTF_8)
        while (s.endsWith("\n") || s.endsWith("\r")) s = s.substring(0, s.length - 1)
        return s
    }

    class GrowableInts(capacity: Int = 4) {
        private var data = IntArray(capacity)
        var size = 0
            private set
        fun add(v: Int) {
            if (size == data.size) data = data.copyOf(data.size * 2)
            data[size++] = v
        }

        fun toArray(): IntArray = data.copyOf(size)
    }
}
