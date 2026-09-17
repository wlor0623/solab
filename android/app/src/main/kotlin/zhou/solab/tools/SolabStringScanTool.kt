package zhou.solab.tools

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.util.zip.ZipFile

/**
 * A9: 敏感信息扫描（移植自玄星逆核 StringScanTool.kt，纯 Kotlin 零依赖）。
 *
 * URL/IP/邮箱/JWT/私钥/云 AK-SK(AWS/Google/阿里云)/密钥字段 9 类正则；
 * APK/ZIP 逐条目扫描，单条目 >32MB 跳过。
 */
object SolabStringScanTool {

    private const val SCAN_CACHE_MAX = 8
    private val scanCache = object : LinkedHashMap<String, String>(SCAN_CACHE_MAX, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?): Boolean =
            size > SCAN_CACHE_MAX
    }

    private val skippedArchiveExtensions = setOf(
        "png", "jpg", "jpeg", "webp", "gif", "bmp", "ico",
        "mp3", "mp4", "m4a", "aac", "wav", "ogg", "flac", "webm",
        "ttf", "otf", "woff", "woff2",
    )

    internal fun shouldScanEntry(name: String): Boolean {
        val extension = name.substringAfterLast('.', "").lowercase()
        return extension !in skippedArchiveExtensions
    }

    // 每个正则的稳定字面锚点（预筛用：不含锚点的字符串直接跳过正则匹配，提速数倍）
    private val anchors: Map<String, List<String>> = mapOf(
        "url" to listOf("http"),
        "ip" to listOf("."),
        "email" to listOf("@"),
        "jwt" to listOf("eyJ"),
        "private_key" to listOf("-----BEGIN"),
        "aws_ak" to listOf("AKIA"),
        "google_api" to listOf("AIza"),
        "aliyun_ak" to listOf("LTAI"),
        "secret_field" to listOf("=", ":", "'", "\""),
    )

    // 敏感模式(类别 → 正则)
    private val patterns: List<Pair<String, Regex>> = listOf(
        "url" to Regex("""https?://[\w\-._~:/?#\[\]@!$&'()*+,;=%]+""", RegexOption.IGNORE_CASE),
        "ip" to Regex("""\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\b"""),
        "email" to Regex("""[\w.+\-]+@[\w\-]+\.[\w\-.]+"""),
        "jwt" to Regex("""eyJ[A-Za-z0-9_\-]+\.eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"""),
        "private_key" to Regex("""-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----"""),
        "aws_ak" to Regex("""AKIA[0-9A-Z]{16}"""),
        "google_api" to Regex("""AIza[0-9A-Za-z_\-]{35}"""),
        "aliyun_ak" to Regex("""LTAI[0-9A-Za-z]{12,22}"""),
        // 收紧：键后必须紧跟 = 或 :（可夹引号/空白），排除"password your_text_here"式纯文案误报
        "secret_field" to Regex("""(?i)(?:api[_-]?key|secret|password|passwd|pwd|token|access[_-]?key|app[_-]?secret|private[_-]?key)["']?\s*[:=]\s*["']?[A-Za-z0-9_\-./+=]{6,}"""),
    )

    /** ip 噪音过滤：本地回环/未指定/广播/链路本地地址恒排除；私网段默认排除（includePrivate=true 保留）。 */
    private fun isNoiseIp(ip: String, includePrivate: Boolean): Boolean {
        val seg = ip.split('.').map { it.toInt() }
        if (seg[0] == 0 || seg[0] == 127 || seg[0] == 255) return true          // 0.x / 127.x / 255.x（含 0.0.0.0、255.255.255.255）
        if (seg[0] == 169 && seg[1] == 254) return true                          // 链路本地
        if (!includePrivate) {
            if (seg[0] == 10) return true                                       // 10.0.0.0/8
            if (seg[0] == 192 && seg[1] == 168) return true                     // 192.168.0.0/16
            if (seg[0] == 172 && seg[1] in 16..31) return true                  // 172.16.0.0/12
        }
        return false
    }

    /** url 噪音过滤：主机名缺有效点分结构（如 "https://x" 这类截断片段）排除。
     *  保留 localhost 与 IP 字面量主机；TLD 须为 >=2 位纯字母。 */
    private fun isNoiseUrl(url: String): Boolean {
        val host = url.substringAfter("://", "").lowercase()
            .substringBefore('/').substringBefore('?').substringBefore('#')
            .substringBefore(':')
        if (host.isEmpty()) return true
        if (host == "localhost" || host.endsWith(".localhost")) return false
        if (host.matches(Regex("""\d{1,3}(\.\d{1,3}){3}"""))) return false // IP 主机保留
        if (!host.contains('.')) return true // 无点主机（https://x）= 截断/占位片段
        val tld = host.substringAfterLast('.')
        return tld.length < 2 || !tld.all { it.isLetter() } // TLD 过短或含非字母 = 截断
    }

    fun handle(context: Context, args: JSONObject): JSONObject {
        val (input, inputErr) = resolveInputFile(args)
        if (inputErr != null) return inputErr
        val inputPath = input!!.absolutePath

        val minLen = args.intValue("minLen", 5).coerceIn(3, 64)
        val limit = args.intValue("limit", 100).coerceIn(1, 5000)
        val onlyCat = args.str("category", "all").ifBlank { "all" }
        val includePrivate = args.optBoolean("includePrivate", false)
        val activePatterns = if (onlyCat == "all") patterns else patterns.filter { it.first == onlyCat }
        if (activePatterns.isEmpty()) return err("INVALID_ARGUMENT", "未知 category: $onlyCat", "category", onlyCat)

        val cacheKey = listOf(
            input.absolutePath,
            input.length(),
            input.lastModified(),
            minLen,
            limit,
            onlyCat,
            includePrivate,
        ).joinToString("|")
        synchronized(scanCache) {
            scanCache[cacheKey]?.let { cached ->
                return JSONObject(cached).put("cache", "hit").put("elapsedMs", 0)
            }
        }

        return runCatching {
            val startedAt = System.nanoTime()
            // 每类去重集合
            val hits = LinkedHashMap<String, LinkedHashSet<String>>()
            activePatterns.forEach { hits[it.first] = LinkedHashSet() }
            val locations = LinkedHashMap<String, JSONArray>()
            var scannedEntries = 0
            val maxBytesPerEntry = 32L * 1024 * 1024
            val activeAnchors = anchors.filterKeys { cat -> activePatterns.any { it.first == cat } }

            fun scanValue(s: String, entryName: String) {
                for ((cat, re) in activePatterns) {
                    val set = hits[cat] ?: continue
                    if (set.size >= limit) continue
                    val anchorsForCat = activeAnchors[cat].orEmpty()
                    if (anchorsForCat.isNotEmpty() && anchorsForCat.none { s.contains(it, ignoreCase = true) }) {
                        continue
                    }
                    re.findAll(s).forEach { m ->
                        val noise = (cat == "ip" && isNoiseIp(m.value, includePrivate)) ||
                            (cat == "url" && isNoiseUrl(m.value))
                        val value = m.value.take(300)
                        if (set.size < limit && !noise && set.add(value)) {
                            locations.getOrPut(cat) { JSONArray() }.put(
                                JSONObject().put("entry", entryName).put("value", value),
                            )
                        }
                    }
                }
            }

            fun scanInput(input: InputStream, entryName: String) {
                val bytes = ByteArray(64 * 1024)
                val text = StringBuilder(8192)
                fun flush(keepTail: Boolean) {
                    if (text.length >= minLen) scanValue(text.toString(), entryName)
                    if (keepTail) {
                        val tail = text.takeLast(512)
                        text.setLength(0)
                        text.append(tail)
                    } else {
                        text.setLength(0)
                    }
                }
                while (true) {
                    val count = input.read(bytes)
                    if (count < 0) break
                    for (index in 0 until count) {
                        val value = bytes[index].toInt() and 0xFF
                        if (value in 0x20..0x7E) {
                            text.append(value.toChar())
                            if (text.length >= 8192) flush(keepTail = true)
                        } else if (text.isNotEmpty()) {
                            flush(keepTail = false)
                        }
                    }
                }
                if (text.isNotEmpty()) flush(keepTail = false)
            }

            val isZip = input.name.endsWith(".apk", true) || input.name.endsWith(".jar", true) ||
                input.name.endsWith(".aar", true) || input.name.endsWith(".zip", true) ||
                input.name.endsWith(".xapk", true) || input.name.endsWith(".apks", true)

            if (isZip) {
                ZipFile(input).use { zip ->
                    val entries = zip.entries()
                    while (entries.hasMoreElements()) {
                        val e = entries.nextElement()
                        if (e.isDirectory) continue
                        if (!shouldScanEntry(e.name)) continue
                        if (e.size > maxBytesPerEntry) continue
                        runCatching {
                            zip.getInputStream(e).use { scanInput(it, e.name) }
                            scannedEntries++
                        }
                    }
                }
            } else {
                if (input.length() > maxBytesPerEntry) {
                    return@runCatching err("FILE_TOO_LARGE", "文件超过 32MB 扫描上限", "path", inputPath)
                }
                input.inputStream().use { scanInput(it, input.name) }
                scannedEntries = 1
            }

            val body = JSONObject()
                .put("tool", "string_scan")
                .put("path", inputPath)
                .put("scannedEntries", scannedEntries)
            var totalHits = 0
            val cats = JSONObject()
            hits.forEach { (cat, set) ->
                if (set.isNotEmpty()) {
                    cats.put(cat, JSONArray(set.toList()))
                    totalHits += set.size
                }
            }
            val locationJson = JSONObject()
            locations.forEach { (cat, entries) -> locationJson.put(cat, entries) }
            body.put("totalHits", totalHits).put("categories", cats).put("locations", locationJson)
                .put("cache", "miss")
                .put("elapsedMs", (System.nanoTime() - startedAt) / 1_000_000)
                .put("hint", if (totalHits == 0) "未命中敏感模式(可调小 minLen 或换 category)" else "locations 给出 APK 条目来源；DEX 命中再用 dex_search 反查方法")
            val response = ok(body)
            synchronized(scanCache) {
                scanCache[cacheKey] = response.toString()
            }
            response
        }.getOrElse { e ->
            err("SCAN_FAILED", "扫描失败: ${e.message ?: e.javaClass.simpleName}", "path", inputPath)
        }
    }
}
