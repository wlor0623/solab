package zhou.solab.engine

import org.json.JSONArray
import org.json.JSONObject

/**
 * 加密相关情报：特征规则 + 扫描原语。
 *
 * 规则分两类：
 *  - BYTES：二进制常量（在 ELF 全文件字节里做子串搜索，天然覆盖 .rodata、
 *    .data.rel.ro 与指令池里的立即数拼接）；
 *  - TEXT：ASCII 文案（导入符号表/字符串表）。
 *
 * 每条规则带 severity 注记，输出按 kind 聚合计数，方便报告直接消费。
 */
object CryptoSig {

    private fun unhex(hex: String): ByteArray =
        ByteArray(hex.length / 2) { i ->
            ((Character.digit(hex[i * 2], 16) shl 4) + Character.digit(hex[i * 2 + 1], 16)).toByte()
        }

    data class Rule(
        val id: String,
        val name: String,
        val family: String,
        val bytes: ByteArray?,
        val text: String?,
        val caseInsensitive: Boolean = false,
    )

    private const val B64_STD =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    val RULES: List<Rule> = listOf(
        // 对称分组：S 盒前 16 字节即可唯一区分
        Rule(
            "aes_sbox", "AES S-box", "AES",
            unhex("637c777bf26b6fc53001672bfed7ab76"), null,
        ),
        Rule(
            "aes_inv_sbox", "AES inverse S-box", "AES",
            unhex("52096ad53036a538bf40a39e81f3d7fb"), null,
        ),
        // 哈希初始化向量（小端词序；哈希族共用前 4 向的以大端等价串再查一次）
        Rule(
            "md5_or_sha1_iv_le", "MD5/SHA-1 IV (LE)", "MD5/SHA-1",
            unhex("0123456789abcdeffedcba9876543210"), null,
        ),
        Rule(
            "md5_or_sha1_iv_be", "MD5/SHA-1 IV (BE)", "MD5/SHA-1",
            unhex("67452301efcdab8998badcfe10325476"), null,
        ),
        Rule(
            "sha256_h0_le", "SHA-256 H0 (LE)", "SHA-2",
            unhex("67e6096a85ae67bb72f36e3c3af54fa5"), null,
        ),
        Rule(
            "sha512_h0_le", "SHA-512 H0 (LE)", "SHA-2",
            unhex("f3bcc9086a09e667bb67ae853c6ef372"), null,
        ),
        // TEA / XTEA / XXTEA 共用 delta 0x9E3779B9：取 4 连重复降低误报
        Rule(
            "tea_delta_x4", "TEA/XTEA delta (x4)", "TEA family",
            unhex("79b9e39e79b9e39e79b9e39e79b9e39e"), null,
        ),
        Rule(
            "base64_std", "Base64 alphabet (std)", "Encoding",
            null, B64_STD,
        ),
        Rule(
            "base64_urlsafe", "Base64 alphabet (url)", "Encoding",
            null, B64_STD.substring(0, 62) + "-_",
        ),
        Rule(
            "chacha_sigma", "ChaCha/Salsa sigma", "Stream",
            null, "expand 32-byte k",
        ),
        Rule(
            "pem_public_key", "PEM public key marker", "PKI",
            null, "-----BEGIN PUBLIC KEY-----",
        ),
        Rule(
            "pem_rsa_private", "PEM RSA private marker", "PKI",
            null, "-----BEGIN RSA PRIVATE KEY-----",
        ),
    )

    /** 关键导入符号名片段（命中即列入 interestImports）。 */
    val INTEREST_IMPORT_PATTERNS: List<Regex> = listOf(
        Regex("(?i)\\baes"),
        Regex("(?i)\\brsa"),
        Regex("(?i)\\bmd5\\b|_md5|md5_"),
        Regex("(?i)sha1|sha256|sha512"),
        Regex("(?i)cipher"),
        Regex("(?i)hmac"),
        Regex("(?i)ccrypt|crypt_r|mcrypt"),
        Regex("(?i)xtea|\\btea_|blowfish"),
        Regex("(?i)evp_(encrypt|decrypt|get_cipher)"),
        Regex("(?i)secrandomrandom|rand_bytes"),
    )

    /** 扫描核心：返回按偏移升序的命中列表（上限 [maxHits] 防爆炸）。 */
    fun scanBytes(data: ByteArray, maxHits: Int = 128): List<Pair<Rule, Int>> {
        val out = ArrayList<Pair<Rule, Int>>()
        for (rule in RULES) {
            if (rule.bytes == null) continue
            val pat = rule.bytes
            var idx = indexOf(data, pat, 0)
            while (idx >= 0) {
                out += rule to idx
                if (out.size >= maxHits) return out
                idx = indexOf(data, pat, idx + 1)
            }
        }
        return out.sortedBy { it.second }
    }

    /** 文本扫描（字符串表/导入名上使用，忽略大小写时由调用方预转小写双方一致）。 */
    fun scanText(text: String, maxHits: Int = 64): List<Rule> {
        val hay = if (text.any { it.code > 126 }) text else text.lowercase()
        val out = ArrayList<Rule>()
        for (rule in RULES) {
            if (rule.text == null) continue
            val needle = if (rule.caseInsensitive || hay != text) rule.text.lowercase() else rule.text
            if (hay.contains(needle)) {
                out += rule
                if (out.size >= maxHits) break
            }
        }
        return out
    }

    fun matchesInterest(symbol: String): Boolean =
        INTEREST_IMPORT_PATTERNS.any { it.containsMatchIn(symbol) }

    private fun indexOf(data: ByteArray, pat: ByteArray, from: Int): Int {
        if (pat.isEmpty()) return -1
        var i = from.coerceAtLeast(0)
        val last = data.size - pat.size
        val first = pat[0]
        while (i <= last) {
            if (data[i] == first) {
                var j = 1
                while (j < pat.size && data[i + j] == pat[j]) j++
                if (j == pat.size) return i
            }
            i++
        }
        return -1
    }
}

/**
 * JNI 桥接配对 v1：从 ELF 动态符号表提取 `Java_*` 导出符号，还原
 * JNI 短名到点分包类路径，并标注歧义（长名 `_1` 与双重下划线场景）。
 * DEX 侧的 native 声明由既有 dex 工具链检索；本表负责给出 SO 层证据，
 * 双端交集即桥接点候选。
 */
object JniBridge {

    data class BridgeEntry(
        val symbol: String,
        val address: Long,
        val classPath: String,
        val method: String,
        val shortForm: Boolean,
        val ambiguous: Boolean,
    )

    /**
     * 纯函数：把单个 `Java_<mangled>` 符号映射为 (classPath, method)。
     * 规则：最后一个裸 `_` 前为类路径段（'_'→'/'），其后为方法名；
     * 含 `_1` 或连续下划线视为长名/转义歧义。
     */
    fun mangle(shortSymbolNoJavaPrefix: String): Triple<String, String, Boolean> {
        val s = shortSymbolNoJavaPrefix
        val escapeSeen = s.contains("_1") || s.contains("__") || s.contains("_2")
        // 方法名 = 最后一段
        val lastSep = s.lastIndexOf('_')
        if (lastSep <= 0 || lastSep == s.length - 1) {
            return Triple(s.replace('_', '/'), "", escapeSeen)
        }
        val cls = s.substring(0, lastSep).replace('_', '/')
        val method = s.substring(lastSep + 1)
        return Triple(cls, method, escapeSeen)
    }

    /** 从已解析动态符号集合构建桥接条目（无匹配返回空数组）。 */
    fun build(dynSymbols: List<SymbolInfo>): List<BridgeEntry> {
        val out = ArrayList<BridgeEntry>()
        for (sym in dynSymbols) {
            if (!sym.exported) continue
            if (!sym.name.startsWith("Java_")) continue
            val body = sym.name.removePrefix("Java_")
            if (body.isEmpty()) continue
            val (cls, method, amb) = mangle(body)
            out.add(
                BridgeEntry(sym.name, sym.value, cls, method, !amb, amb),
            )
        }
        return out
    }
}
