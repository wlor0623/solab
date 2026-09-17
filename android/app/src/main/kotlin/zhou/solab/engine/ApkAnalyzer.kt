package zhou.solab.engine

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.File
import java.util.zip.ZipFile
import java.util.zip.ZipInputStream

/**
 * APK 结构解析（移植自玄星逆核 ApkAnalyzer.kt 精简版）。
 *
 * 输入限制：512MiB；输出 ZIP 条目/ABI/SO 清单/DEX 头/v1 签名文件/Flutter 指纹。
 * 规则驱动的信号分析仍由 Solab 现有 ApkModuleAnalyzer 负责，两者互补。
 */
class ApkAnalysisLimitException(message: String) : RuntimeException(message)

object ApkAnalyzer {
    const val MAX_INPUT_BYTES = 512L * 1024 * 1024

    data class Limits(
        val maxEntries: Int = 100_000,
        val maxParsedEntryBytes: Int = 128 * 1024 * 1024,
        val maxParsedTotalBytes: Int = 256 * 1024 * 1024,
    )

    fun analyze(bytes: ByteArray, path: String, entryLimit: Int = 500, limits: Limits = Limits()): JSONObject {
        if (bytes.size.toLong() > MAX_INPUT_BYTES) throw ApkAnalysisLimitException("APK exceeds 512 MiB input limit")
        val entries = JSONArray()
        val abis = linkedSetOf<String>()
        val nativeLibraries = JSONArray()
        val dexFiles = JSONArray()
        var resourcesArsc = false
        var manifestPresent = false
        var manifestFormat = ""
        var manifestPreview: String? = null
        val v1SignatureFiles = JSONArray()
        var entryCount = 0
        var entriesTruncated = false
        var parsedTotal = 0L

        ZipInputStream(ByteArrayInputStream(bytes)).use { zis ->
            while (true) {
                val entry = zis.nextEntry ?: break
                if (entry.isDirectory) continue
                entryCount++
                if (entryCount > limits.maxEntries) throw ApkAnalysisLimitException("APK entry count exceeds ${limits.maxEntries}")
                val name = entry.name
                if (entries.length() < entryLimit) {
                    entries.put(JSONObject().put("name", name).put("size", entry.size).put("compressedSize", entry.compressedSize))
                } else {
                    entriesTruncated = true
                }
                // ABI / SO 清单
                val soMatch = Regex("^lib/([^/]+)/([^/]+)\\.so$").find(name)
                if (soMatch != null) {
                    val abi = soMatch.groupValues[1]
                    abis += abi
                    nativeLibraries.put(JSONObject().put("entry", name).put("abi", abi).put("name", soMatch.groupValues[2]).put("size", entry.size))
                }
                // DEX 头
                if (name.startsWith("classes") && name.endsWith(".dex") && entry.size in 0x70..(256 * 1024 * 1024).toLong()) {
                    val header = ByteArray(0x70)
                    var read = 0
                    while (read < header.size) {
                        val n = zis.read(header, read, header.size - read)
                        if (n < 0) break
                        read += n
                    }
                    parsedTotal += read
                    dexFiles.put(parseDexHeader(header, name))
                }
                if (name == "resources.arsc") resourcesArsc = true
                if (name == "AndroidManifest.xml") {
                    manifestPresent = true
                    val head = ByteArray(4096)
                    var read = 0
                    while (read < head.size) {
                        val n = zis.read(head, read, head.size - read)
                        if (n < 0) break
                        read += n
                    }
                    if (head.size >= 2 && (head[0].toInt() and 0xff) == 0x03 && head[1].toInt() == 0x00) {
                        manifestFormat = "android_binary_xml"
                    } else {
                        manifestFormat = "text"
                        manifestPreview = String(head, Charsets.UTF_8).take(4096)
                    }
                    parsedTotal += read
                }
                if (name.startsWith("META-INF/") && name.endsWith(".RSA", true) || name.startsWith("META-INF/") && name.endsWith(".DSA", true) ||
                    name.startsWith("META-INF/") && name.endsWith(".EC", true) || name.startsWith("META-INF/") && name.endsWith(".SF", true) ||
                    name == "META-INF/MANIFEST.MF") {
                    v1SignatureFiles.put(name)
                }
                if (parsedTotal > limits.maxParsedTotalBytes) throw ApkAnalysisLimitException("APK parsed bytes exceed ${limits.maxParsedTotalBytes}")
                zis.closeEntry()
            }
        }

        return JSONObject()
            .put("path", path)
            .put("size", bytes.size)
            .put("sha256", sha256Hex(bytes))
            .put("parser", "solab_builtin_apk_zip_dex_axml")
            .put("entryCount", entryCount)
            .put("entriesTruncated", entriesTruncated)
            .put("entries", entries)
            .put("abis", JSONArray(abis.toList()))
            .put("nativeLibraries", nativeLibraries)
            .put("dexFiles", dexFiles)
            .put("manifest", JSONObject().put("present", manifestPresent).put("format", manifestFormat).apply { if (manifestPreview != null) put("textPreview", manifestPreview) })
            .put("resourcesArsc", resourcesArsc)
            .put("v1SignatureFiles", v1SignatureFiles)
            .put("hasV1Signature", v1SignatureFiles.length() > 0)
            .put("limitations", JSONArray())
    }

    fun analyze(file: File, path: String = file.absolutePath, entryLimit: Int = 500, limits: Limits = Limits()): JSONObject {
        if (file.length() > MAX_INPUT_BYTES) throw ApkAnalysisLimitException("APK exceeds 512 MiB input limit")
        val entries = JSONArray()
        val abis = linkedSetOf<String>()
        val nativeLibraries = JSONArray()
        val dexFiles = JSONArray()
        var resourcesArsc = false
        var manifestPresent = false
        var manifestFormat = ""
        var manifestPreview: String? = null
        val v1SignatureFiles = JSONArray()
        var entryCount = 0
        var entriesTruncated = false
        var parsedTotal = 0L

        ZipFile(file).use { zip ->
            val iterator = zip.entries()
            while (iterator.hasMoreElements()) {
                val entry = iterator.nextElement()
                if (entry.isDirectory) continue
                entryCount++
                if (entryCount > limits.maxEntries) throw ApkAnalysisLimitException("APK entry count exceeds ${limits.maxEntries}")
                val name = entry.name
                if (entries.length() < entryLimit) {
                    entries.put(JSONObject().put("name", name).put("size", entry.size).put("compressedSize", entry.compressedSize))
                } else {
                    entriesTruncated = true
                }
                val soMatch = Regex("^lib/([^/]+)/([^/]+)\\.so$").find(name)
                if (soMatch != null) {
                    val abi = soMatch.groupValues[1]
                    abis += abi
                    nativeLibraries.put(JSONObject().put("entry", name).put("abi", abi).put("name", soMatch.groupValues[2]).put("size", entry.size))
                }
                if (name.startsWith("classes") && name.endsWith(".dex") && entry.size in 0x70..(256 * 1024 * 1024).toLong()) {
                    val header = ByteArray(0x70)
                    zip.getInputStream(entry).use { input ->
                        var read = 0
                        while (read < header.size) {
                            val n = input.read(header, read, header.size - read)
                            if (n < 0) break
                            read += n
                        }
                        parsedTotal += read
                    }
                    dexFiles.put(parseDexHeader(header, name))
                }
                if (name == "resources.arsc") resourcesArsc = true
                if (name == "AndroidManifest.xml") {
                    manifestPresent = true
                    val head = ByteArray(4096)
                    zip.getInputStream(entry).use { input ->
                        var read = 0
                        while (read < head.size) {
                            val n = input.read(head, read, head.size - read)
                            if (n < 0) break
                            read += n
                        }
                        parsedTotal += read
                    }
                    if (head.size >= 2 && (head[0].toInt() and 0xff) == 0x03 && head[1].toInt() == 0x00) {
                        manifestFormat = "android_binary_xml"
                    } else {
                        manifestFormat = "text"
                        manifestPreview = String(head, Charsets.UTF_8).take(4096)
                    }
                }
                if (name.startsWith("META-INF/") && name.endsWith(".RSA", true) || name.startsWith("META-INF/") && name.endsWith(".DSA", true) ||
                    name.startsWith("META-INF/") && name.endsWith(".EC", true) || name.startsWith("META-INF/") && name.endsWith(".SF", true) ||
                    name == "META-INF/MANIFEST.MF") {
                    v1SignatureFiles.put(name)
                }
                if (parsedTotal > limits.maxParsedTotalBytes) throw ApkAnalysisLimitException("APK parsed bytes exceed ${limits.maxParsedTotalBytes}")
            }
        }

        return JSONObject()
            .put("path", path)
            .put("size", file.length())
            .put("sha256", sha256Hex(file))
            .put("parser", "solab_builtin_apk_zip_dex_axml")
            .put("entryCount", entryCount)
            .put("entriesTruncated", entriesTruncated)
            .put("entries", entries)
            .put("abis", JSONArray(abis.toList()))
            .put("nativeLibraries", nativeLibraries)
            .put("dexFiles", dexFiles)
            .put("manifest", JSONObject().put("present", manifestPresent).put("format", manifestFormat).apply { if (manifestPreview != null) put("textPreview", manifestPreview) })
            .put("resourcesArsc", resourcesArsc)
            .put("v1SignatureFiles", v1SignatureFiles)
            .put("hasV1Signature", v1SignatureFiles.length() > 0)
            .put("limitations", JSONArray())
    }

    private fun parseDexHeader(header: ByteArray, entryName: String): JSONObject {
        fun u32(off: Int): Long {
            if (off + 4 > header.size) return 0
            return (header[off].toLong() and 0xff) or ((header[off + 1].toLong() and 0xff) shl 8) or
                ((header[off + 2].toLong() and 0xff) shl 16) or ((header[off + 3].toLong() and 0xff) shl 24)
        }
        val valid = header.size >= 0x70 && header[0] == 'd'.code.toByte() && header[1] == 'e'.code.toByte() &&
            header[2] == 'x'.code.toByte() && header[3] == '\n'.code.toByte()
        return JSONObject()
            .put("entry", entryName)
            .put("valid", valid)
            .put("fileSize", u32(0x20))
            .put("headerSize", u32(0x24))
            .put("endianTag", u32(0x28))
            .put("stringIds", u32(0x38))
            .put("typeIds", u32(0x40))
            .put("protoIds", u32(0x48))
            .put("fieldIds", u32(0x50))
            .put("methodIds", u32(0x58))
            .put("classDefs", u32(0x60))
    }

    private fun sha256Hex(bytes: ByteArray): String =
        java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun sha256Hex(file: File): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
