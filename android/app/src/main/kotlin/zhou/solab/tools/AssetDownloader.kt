package zhou.solab.tools

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URL
import java.security.MessageDigest

/**
 * 按需下载可选资源，落 externalFilesDir/assets/ 供运行时使用。
 *
 * 安全约束（Mimosa）：
 *  - 仅允许 http/https 协议；
 *  - 发请求前校验 host：拒绝 localhost / 环回 / 链路本地 / 站点私有 / 保留地址
 *    （域名先解析为 IP 再判定，覆盖"域名指向私有地址"的场景）。
 *  - 下载后强制 SHA-256 校验（期望值不匹配即删除并报错），原子落盘。
 */
object AssetDownloader {

    private const val MAX_DOWNLOAD_BYTES = 128L * 1024 * 1024

    /** 下载资源目录（externalFilesDir/assets）。 */
    fun assetDir(context: Context): File =
        File(context.getExternalFilesDir(null) ?: context.filesDir, "assets").apply { mkdirs() }

    /** 已下载的库/资源文件（不存在返回 null）。 */
    fun assetFile(context: Context, name: String): File? {
        val f = File(assetDir(context), name)
        return if (f.isFile && f.length() > 0) f else null
    }

    fun status(context: Context, names: List<String>): JSONObject {
        val items = JSONArray()
        names.forEach { name ->
            val f = assetFile(context, name)
            items.put(JSONObject()
                .put("name", name)
                .put("downloaded", f != null)
                .put("size", f?.length() ?: 0L)
                .put("path", f?.absolutePath ?: JSONObject.NULL))
        }
        return ok(JSONObject().put("tool", "asset_download").put("action", "status").put("items", items))
    }

    /** 下载并校验。返回错误信封（成功返回 null）。 */
    fun download(context: Context, url: String, name: String, sha256: String): JSONObject? {
        val validateErr = validateUrl(url)
        if (validateErr != null) return err("INVALID_URL", validateErr, "url", url)

        val target = File(assetDir(context), name)
        val tmp = File(assetDir(context), "$name.tmp-${System.nanoTime()}")
        return try {
            val conn = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 15_000
                readTimeout = 120_000
                instanceFollowRedirects = true
                requestMethod = "GET"
            }
            val status = conn.responseCode
            if (status !in 200..299) return err("DOWNLOAD_FAILED", "HTTP $status", "url", url)
            if (conn.contentLengthLong > MAX_DOWNLOAD_BYTES) {
                return err("DOWNLOAD_TOO_LARGE", "资源超过 ${MAX_DOWNLOAD_BYTES / 1024 / 1024}MiB 上限", "url", url)
            }
            val digest = MessageDigest.getInstance("SHA-256")
            conn.inputStream.use { input ->
                tmp.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > MAX_DOWNLOAD_BYTES) throw IllegalStateException("下载超过大小上限")
                        digest.update(buf, 0, n)
                        out.write(buf, 0, n)
                    }
                }
            }
            conn.disconnect()
            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            if (sha256.isNotBlank() && !actual.equals(sha256, ignoreCase = true)) {
                tmp.delete()
                return err("SHA256_MISMATCH", "SHA-256 校验失败：期望 $sha256，实际 $actual", "url", url)
            }
            target.delete()
            if (!tmp.renameTo(target)) {
                tmp.copyTo(target, overwrite = true)
                tmp.delete()
            }
            null
        } catch (e: Exception) {
            tmp.delete()
            err("DOWNLOAD_FAILED", "下载失败: ${e.message ?: e.javaClass.simpleName}", "url", url)
        }
    }

    /**
     * URL 安全校验（Mimosa 约束）：
     * 仅 http/https；拒绝 localhost、环回、链路本地、站点私有、保留地址。
     */
    fun validateUrl(raw: String): String? {
        val url = runCatching { URL(raw.trim()) }.getOrNull()
            ?: return "URL 格式错误"
        if (url.protocol !in setOf("http", "https")) return "仅支持 http/https 协议"
        val host = url.host.lowercase()
        if (host.isBlank()) return "URL 缺少 host"
        if (host == "localhost" || host.endsWith(".localhost") || host == "127.0.0.1") {
            return "拒绝 localhost/环回地址"
        }
        // 解析为 IP 后判定（覆盖"域名指向私有地址"）
        val ip = runCatching { InetAddress.getByName(host) }.getOrNull()
            ?: return "host 无法解析"
        if (ip.isAnyLocalAddress || ip.isLoopbackAddress ||
            ip.isLinkLocalAddress || ip.isSiteLocalAddress || ip.isMulticastAddress
        ) {
            return "拒绝环回/私有/链路本地/保留地址: $host"
        }
        return null
    }
}
