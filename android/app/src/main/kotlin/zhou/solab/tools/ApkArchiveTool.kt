package zhou.solab.tools

import com.android.apksig.ApkVerifier
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.util.Locale
import java.util.zip.ZipFile

object ApkArchiveTool {
    private const val DEFAULT_LIST_LIMIT = 100
    private const val MAX_LIST_LIMIT = 500
    private const val DEFAULT_READ_LIMIT = 4096
    private const val MAX_READ_LIMIT = 64 * 1024
    private const val TEXT_SAMPLE_LIMIT = 8192
    private const val DEFAULT_STRING_LIMIT = 100
    private const val MAX_STRING_LIMIT = 1000

    fun handle(args: JSONObject): JSONObject {
        val (apk, inputError) = resolveInputFile(args)
        if (inputError != null) return inputError
        if (!apk!!.name.endsWith(".apk", ignoreCase = true)) {
            return err("INVALID_ARGUMENT", "path 必须指向 APK 文件", "path", apk.absolutePath)
        }
        return when (args.str("action", "list").lowercase(Locale.ROOT)) {
            "list" -> list(apk, args)
            "read" -> read(apk, args)
            "strings" -> strings(apk, args)
            "certificates" -> certificates(apk)
            else -> err("UNKNOWN_ACTION", "未知 action（支持 list/read/strings/certificates）", "action", args.str("action"))
        }
    }

    private fun list(apk: File, args: JSONObject): JSONObject = runCatching {
        val query = args.str("query").trim().lowercase(Locale.ROOT)
        val offset = args.intValue("offset", 0).coerceAtLeast(0)
        val limit = args.intValue("limit", DEFAULT_LIST_LIMIT).coerceIn(1, MAX_LIST_LIMIT)
        val entries = JSONArray()
        var total = 0
        ZipFile(apk).use { zip ->
            zip.entries().asSequence().filterNot { it.isDirectory }.forEach { entry ->
                if (query.isNotEmpty() && !entry.name.lowercase(Locale.ROOT).contains(query)) return@forEach
                if (total >= offset && entries.length() < limit) {
                    entries.put(
                        JSONObject()
                            .put("path", entry.name)
                            .put("size", entry.size.coerceAtLeast(0L))
                            .put("compressedSize", entry.compressedSize.coerceAtLeast(0L))
                            .put("compressionMethod", if (entry.method == 0) "stored" else "deflated"),
                    )
                }
                total++
            }
        }
        ok(
            JSONObject()
                .put("tool", "apk_archive")
                .put("action", "list")
                .put("path", apk.absolutePath)
                .put("query", query)
                .put("offset", offset)
                .put("limit", limit)
                .put("total", total)
                .put("entries", entries)
                .put("nextOffset", if (offset + entries.length() < total) offset + entries.length() else JSONObject.NULL),
        )
    }.getOrElse { error ->
        err("ARCHIVE_READ_FAILED", error.message ?: "无法读取 APK 条目")
    }

    private fun read(apk: File, args: JSONObject): JSONObject {
        val name = args.str("entry").trim()
        if (name.isEmpty() || name.startsWith('/') || name.split('/').any { it == ".." }) {
            return err("INVALID_ARGUMENT", "entry 必须是 APK 内的合法文件路径", "entry", name)
        }
        val offset = args.optLong("offset", 0L).coerceAtLeast(0L)
        val limit = args.intValue("limit", DEFAULT_READ_LIMIT).coerceIn(1, MAX_READ_LIMIT)
        return runCatching {
            ZipFile(apk).use { zip ->
                val entry = zip.getEntry(name) ?: return@use err("ENTRY_NOT_FOUND", "APK 内不存在条目: $name", "entry", name)
                if (entry.isDirectory) return@use err("INVALID_ARGUMENT", "entry 必须是文件，不能是目录", "entry", name)
                val size = entry.size.coerceAtLeast(0L)
                if (offset > size) return@use err("INVALID_ARGUMENT", "offset 超出条目大小 $size", "offset", offset)
                val window = zip.getInputStream(entry).use { input ->
                    skipFully(input, offset)
                    readUpTo(input, minOf(limit.toLong(), size - offset).toInt())
                }
                val sample = zip.getInputStream(entry).use { input ->
                    readUpTo(input, minOf(TEXT_SAMPLE_LIMIT.toLong(), size).toInt())
                }
                val text = isText(sample)
                ok(
                    JSONObject()
                        .put("tool", "apk_archive")
                        .put("action", "read")
                        .put("path", apk.absolutePath)
                        .put("entry", name)
                        .put("size", size)
                        .put("compressedSize", entry.compressedSize.coerceAtLeast(0L))
                        .put("offset", offset)
                        .put("bytes", window.size)
                        .put("truncated", offset + window.size < size)
                        .put("encoding", if (text) "UTF-8" else "binary")
                        .put("content", if (text) String(window, Charsets.UTF_8) else JSONObject.NULL)
                        .put("hexPreview", if (text) JSONObject.NULL else window.joinToString(" ") { "%02X".format(it) })
                        .put("nextOffset", if (offset + window.size < size) offset + window.size else JSONObject.NULL),
                )
            }
        }.getOrElse { error ->
            err("ARCHIVE_READ_FAILED", error.message ?: "无法读取 APK 条目")
        }
    }

    private fun certificates(apk: File): JSONObject = runCatching {
        val result = ApkVerifier.Builder(apk).build().verify()
        val certificates = JSONArray()
        result.signerCertificates.forEach { certificates.put(certificateJson(it)) }
        ok(
            JSONObject()
                .put("tool", "apk_archive")
                .put("action", "certificates")
                .put("path", apk.absolutePath)
                .put("verified", result.isVerified)
                .put("verifiedUsingV1", result.isVerifiedUsingV1Scheme)
                .put("verifiedUsingV2", result.isVerifiedUsingV2Scheme)
                .put("verifiedUsingV3", result.isVerifiedUsingV3Scheme)
                .put("certificates", certificates),
        )
    }.getOrElse { error ->
        err("CERTIFICATE_READ_FAILED", error.message ?: "无法读取 APK 签名证书")
    }

    private fun strings(apk: File, args: JSONObject): JSONObject {
        val name = args.str("entry").trim()
        if (name.isEmpty() || name.startsWith('/') || name.split('/').any { it == ".." }) {
            return err("INVALID_ARGUMENT", "entry 必须是 APK 内的合法文件路径", "entry", name)
        }
        val minLen = args.intValue("minLen", 4).coerceIn(3, 64)
        val limit = args.intValue("limit", DEFAULT_STRING_LIMIT).coerceIn(1, MAX_STRING_LIMIT)
        return runCatching {
            ZipFile(apk).use { zip ->
                val entry = zip.getEntry(name) ?: return@use err("ENTRY_NOT_FOUND", "APK 内不存在条目: $name", "entry", name)
                if (entry.isDirectory) return@use err("INVALID_ARGUMENT", "entry 必须是文件，不能是目录", "entry", name)
                val values = LinkedHashSet<String>()
                fun add(value: StringBuilder) {
                    if (value.length >= minLen && values.size < limit) values += value.toString().take(512)
                    value.clear()
                }
                zip.getInputStream(entry).use { input ->
                    val buffer = ByteArray(64 * 1024)
                    val ascii = StringBuilder()
                    val utf16 = StringBuilder()
                    var lowByte = -1
                    while (values.size < limit) {
                        val count = input.read(buffer)
                        if (count <= 0) break
                        for (index in 0 until count) {
                            val value = buffer[index].toInt() and 0xff
                            if (value in 0x20..0x7e) ascii.append(value.toChar()) else add(ascii)
                            if (lowByte < 0) {
                                lowByte = value
                            } else {
                                if (value == 0 && lowByte in 0x20..0x7e) utf16.append(lowByte.toChar()) else add(utf16)
                                lowByte = -1
                            }
                        }
                    }
                    add(ascii)
                    add(utf16)
                }
                ok(
                    JSONObject()
                        .put("tool", "apk_archive")
                        .put("action", "strings")
                        .put("path", apk.absolutePath)
                        .put("entry", name)
                        .put("minLen", minLen)
                        .put("limit", limit)
                        .put("returned", values.size)
                        .put("truncated", values.size >= limit)
                        .put("strings", JSONArray(values.toList())),
                )
            }
        }.getOrElse { error ->
            err("ARCHIVE_READ_FAILED", error.message ?: "无法读取 APK 条目")
        }
    }

    private fun certificateJson(certificate: X509Certificate): JSONObject = JSONObject()
        .put("subject", certificate.subjectX500Principal.name)
        .put("issuer", certificate.issuerX500Principal.name)
        .put("serialNumber", certificate.serialNumber.toString(16).uppercase(Locale.ROOT))
        .put("signatureAlgorithm", certificate.sigAlgName)
        .put("publicKeyAlgorithm", certificate.publicKey.algorithm)
        .put("validFrom", certificate.notBefore.time)
        .put("validTo", certificate.notAfter.time)
        .put("sha256", fingerprint(certificate, "SHA-256"))
        .put("sha1", fingerprint(certificate, "SHA-1"))

    private fun fingerprint(certificate: X509Certificate, algorithm: String): String =
        MessageDigest.getInstance(algorithm).digest(certificate.encoded)
            .joinToString(":") { "%02X".format(it) }

    private fun isText(bytes: ByteArray): Boolean {
        if (bytes.isEmpty() || bytes.any { it == 0.toByte() }) return false
        val printable = bytes.count { byte ->
            val value = byte.toInt() and 0xff
            value in 0x09..0x0d || value in 0x20..0x7e || value >= 0x80
        }
        return printable * 5 >= bytes.size * 4
    }

    private fun skipFully(input: InputStream, offset: Long) {
        var skipped = 0L
        while (skipped < offset) {
            val count = input.skip(offset - skipped)
            if (count > 0) {
                skipped += count
            } else if (input.read() == -1) {
                break
            } else {
                skipped++
            }
        }
    }

    private fun readUpTo(input: InputStream, size: Int): ByteArray {
        val output = ByteArray(size)
        var offset = 0
        while (offset < size) {
            val count = input.read(output, offset, size - offset)
            if (count <= 0) break
            offset += count
        }
        return if (offset == size) output else output.copyOf(offset)
    }
}
