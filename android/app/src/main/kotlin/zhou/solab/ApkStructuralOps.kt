package zhou.solab

import android.util.Base64
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.Locale
import java.util.zip.CRC32
import java.util.zip.Deflater
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/**
 * APK 结构级重打包引擎。
 *
 * 职责：对源 APK 做结构操作（删条目 / 改条目 / 过滤 ABI），产出「未签名中间包」，
 * 最终签名由 MT Manager MCP 完成（mt_apk_build sign=true）。
 *
 * 打包规则（与 Android 安装要求对齐）：
 * - STORED（不压缩）：so / arsc / png / jpg / jpeg / gif / webp / ttf / otf / 媒体；
 *   dex 走 DEFLATED（避免重打包体积翻倍，参考 APKEditor v2.0）；
 *   其余 DEFLATED 压缩。
 * - 对齐：lib/xxx.so → 4096 字节页对齐；resources.arsc → 4 字节对齐；
 *   通过手写 0xd935 Android Alignment extra 字段实现（与 zipalign 同思路）。
 * - META-INF/xxx.SF/.RSA/.DSA/.EC 签名文件一律剔除（改造后签名必然失效，由 MT 重新签名）。
 * - zip-slip 防护：条目名规范化校验，非法名称（绝对路径 / 反斜杠 / ".." 段）直接跳过不还原。
 * - 事务性：先写 <output>.tmp，成功后原子 rename 到目标；任何失败删除 tmp，不产出半成品。
 */
object ApkStructuralOps {

    private const val ALIGNMENT_FIELD_ID = 0xd935
    private const val ALIGN_ARSC = 4
    private const val ALIGN_SO_PAGE = 4096
    /** 1980-01-01T00:00:00Z：早于此时间的条目会被 ZipOutputStream 追加 0x5455 extra，破坏对齐计算。 */
    private const val TIME_1980 = 315532800000L
    /** 源条目时间缺失 / 非法时的兜底时间。 */
    private const val FIXED_TIME = 946684800000L // 2000-01-01T00:00:00Z

    /** STORED（不压缩）扩展名：已压缩格式 + Android 要求不压缩 / 对齐的格式。 */
    // dex 走 DEFLATED（参考 APKEditor v2.0 修复：dex STORED 会导致重打包体积翻倍）。
    private val STORED_EXTENSIONS = setOf(
        "apk", "arsc", "so",
        "png", "jpg", "jpeg", "gif", "webp",
        "ttf", "otf",
        "wav", "mp3", "mp4", "ogg", "m4a", "aac", "flac",
        "mkv", "webm", "mov", "3gp", "amr", "opus", "mid",
    )

    /** 重打包结果统计。 */
    class RepackResult(
        val entryCount: Int,
        val dropped: List<DroppedEntry>,
        val droppedBytes: Long,
    )

    class DroppedEntry(val name: String, val size: Long)

    /** 源条目哈希（before 值）。 */
    class SourceHash(val sha256: String, val size: Long)

    /** META-INF 签名文件：重打包时一律剔除（产物为未签名包）。 */
    fun isSignatureEntry(name: String): Boolean =
        name.startsWith("META-INF/") && (
            name.endsWith(".SF", ignoreCase = true) ||
                name.endsWith(".RSA", ignoreCase = true) ||
                name.endsWith(".DSA", ignoreCase = true) ||
                name.endsWith(".EC", ignoreCase = true)
        )

    /** 硬保护：Manifest / resources.arsc / 任意 dex 不可删除。 */
    fun isProtected(name: String): Boolean {
        val lower = name.lowercase(Locale.ROOT)
        return lower == "androidmanifest.xml" || lower == "resources.arsc" || lower.endsWith(".dex")
    }

    /** zip-slip 防护：规范化条目名，非法（空 / 绝对路径 / 反斜杠 / "." 或 ".." 段）返回 null。 */
    fun normalizeEntryName(name: String): String? {
        if (name.isEmpty() || name.startsWith('/') || name.contains('\\')) return null
        for (segment in name.split('/')) {
            if (segment.isEmpty() || segment == "." || segment == "..") return null
        }
        return name
    }

    /** 前缀匹配：prefix 以 '/' 结尾则整目录匹配，否则按目录段边界匹配。 */
    fun prefixMatches(name: String, prefix: String): Boolean {
        if (prefix.isEmpty()) return false
        return if (prefix.endsWith('/')) {
            name.startsWith(prefix)
        } else {
            name == prefix || name.startsWith("$prefix/")
        }
    }

    /** content 解码：{hex: "..."} / {base64: "..."}；纯字符串按 base64 处理。 */
    fun decodeContent(content: Any?): ByteArray? {
        return when (content) {
            is String -> decodeBase64(content)
            is Map<*, *> -> {
                val hex = content["hex"]
                if (hex is String) return decodeHex(hex)
                val base64 = content["base64"]
                if (base64 is String) return decodeBase64(base64)
                null
            }
            else -> null
        }
    }

    fun decodeHex(hex: String): ByteArray {
        val clean = hex.replace(" ", "").replace("\t", "")
            .replace("\r", "").replace("\n", "")
        require(clean.length % 2 == 0) { "hex 字符串长度必须为偶数" }
        return ByteArray(clean.length / 2) { index ->
            clean.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }

    private fun decodeBase64(base64: String): ByteArray = Base64.decode(base64, Base64.DEFAULT)

    fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).toHex()

    /** 读取源条目数据的 SHA-256 与字节数（用于 before 值）。 */
    fun readSourceHash(zip: ZipFile, entry: ZipEntry): SourceHash {
        val digest = MessageDigest.getInstance("SHA-256")
        var size = 0L
        zip.getInputStream(entry).use { input ->
            val buffer = ByteArray(128 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
                size += count
            }
        }
        return SourceHash(digest.digest().toHex(), size)
    }

    /**
     * 流式重打包：源 APK → <output>.tmp → 原子 rename 为 output。
     *
     * @param dropExact 精确剔除的条目名（调用方须已校验存在性与硬保护）。
     * @param dropPrefixes 剔除的目录前缀（如 lib/x86_64/）。
     * @param overrides 覆盖内容（条目名 → bytes）。
     * @param overrideFiles 覆盖内容（条目名 → 已修改文件，重打包时流式读取，
     *   避免大 dex 全量字节驻留内存；与 [overrides] 同优先级，先查 bytes 再查文件）。
     * @param additions 新增条目（条目名 → bytes，追加在末尾）。
     * @param additionFiles 新增条目（条目名 → 已修改文件，追加时流式读取）。
     */
    fun repack(
        source: File,
        output: File,
        dropExact: Set<String> = emptySet(),
        dropPrefixes: List<String> = emptyList(),
        overrides: Map<String, ByteArray> = emptyMap(),
        overrideFiles: Map<String, File> = emptyMap(),
        additions: Map<String, ByteArray> = emptyMap(),
        additionFiles: Map<String, File> = emptyMap(),
    ): RepackResult {
        require(source.isFile && source.length() > 0L) { "源 APK 不存在或为空: $source" }
        val outputDir = output.parentFile ?: throw IllegalStateException("无法确定输出目录")
        require(outputDir.isDirectory) { "输出目录不存在: ${outputDir.absolutePath}" }
        val tmp = File(outputDir, output.name + ".tmp")
        tmp.delete() // 清理上次失败残留

        val dropped = ArrayList<DroppedEntry>()
        var droppedBytes = 0L
        var entryCount = 0
        try {
            ZipFile(source).use { zip ->
                FileOutputStream(tmp).use { fos ->
                    ZipOutputStream(fos).use { zos ->
                        zos.setLevel(Deflater.DEFAULT_COMPRESSION)
                        zip.entries().asSequence().forEach { sourceEntry ->
                            if (sourceEntry.isDirectory) return@forEach
                            val name = normalizeEntryName(sourceEntry.name) ?: return@forEach
                            if (isSignatureEntry(name)) return@forEach
                            if (name in dropExact || dropPrefixes.any { prefixMatches(name, it) }) {
                                dropped += DroppedEntry(name, sourceEntry.size)
                                droppedBytes += sourceEntry.size
                                return@forEach
                            }
                            val replacement = overrides[name]
                            if (replacement != null) {
                                writeEntry(zos, fos, name, replacement, sourceEntry.method)
                                entryCount++
                                return@forEach
                            }
                            val replacementFile = overrideFiles[name]
                            if (replacementFile != null) {
                                writeEntryFromFile(zos, fos, name, replacementFile, sourceEntry.method)
                                entryCount++
                                return@forEach
                            }
                            copyEntry(zip, zos, fos, sourceEntry, name)
                            entryCount++
                        }
                        additions.forEach { (name, content) ->
                            writeEntry(zos, fos, name, content)
                            entryCount++
                        }
                        additionFiles.forEach { (name, file) ->
                            writeEntryFromFile(zos, fos, name, file)
                            entryCount++
                        }
                    }
                }
            }
            atomicMove(tmp, output)
            return RepackResult(entryCount, dropped, droppedBytes)
        } catch (t: Throwable) {
            tmp.delete()
            throw t
        }
    }

    /** 复制源条目（沿用源压缩方式；源 STORED 才做对齐，源 DEFLATED 保持 DEFLATED 防体积膨胀）。 */
    private fun copyEntry(
        zip: ZipFile,
        zos: ZipOutputStream,
        fos: FileOutputStream,
        sourceEntry: ZipEntry,
        name: String,
    ) {
        val (store, align) = storagePlan(name)
        val entry = ZipEntry(name)
        entry.time = if (sourceEntry.time >= TIME_1980) sourceEntry.time else FIXED_TIME
        // P0 压缩保留：源条目 DEFLATED 时禁止升级为 STORED（libapp.so 20MB store 会让 APK 体积膨胀数倍）
        val canStore = store && sourceEntry.method != ZipEntry.DEFLATED &&
            sourceEntry.size >= 0L && sourceEntry.crc >= 0L
        if (canStore) {
            entry.method = ZipEntry.STORED
            entry.size = sourceEntry.size
            entry.compressedSize = sourceEntry.size
            entry.crc = sourceEntry.crc
            if (align > 1) applyAlignment(zos, fos, entry, align)
        } else {
            entry.method = ZipEntry.DEFLATED
        }
        zos.putNextEntry(entry)
        val buffer = ByteArray(128 * 1024)
        zip.getInputStream(sourceEntry).use { input ->
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                zos.write(buffer, 0, count)
            }
        }
        zos.closeEntry()
    }

    /** 从内存内容写新条目（覆盖 / 新增）。覆盖时 [sourceMethod] 沿用源条目压缩方式。 */
    private fun writeEntry(
        zos: ZipOutputStream,
        fos: FileOutputStream,
        name: String,
        content: ByteArray,
        sourceMethod: Int = -1,
    ) {
        val (store, align) = storagePlan(name)
        val entry = ZipEntry(name)
        entry.time = FIXED_TIME
        val canStore = if (sourceMethod >= 0) store && sourceMethod != ZipEntry.DEFLATED else store
        if (canStore) {
            entry.method = ZipEntry.STORED
            entry.size = content.size.toLong()
            entry.compressedSize = content.size.toLong()
            entry.crc = CRC32().apply { update(content) }.value
            if (align > 1) applyAlignment(zos, fos, entry, align)
        } else {
            entry.method = ZipEntry.DEFLATED
        }
        zos.putNextEntry(entry)
        zos.write(content)
        zos.closeEntry()
    }

    /** 从已修改文件流式写新条目（覆盖；内存峰值 = 单条目大小）。覆盖时 [sourceMethod] 沿用源条目压缩方式。 */
    private fun writeEntryFromFile(
        zos: ZipOutputStream,
        fos: FileOutputStream,
        name: String,
        file: File,
        sourceMethod: Int = -1,
    ) {
        val (store, align) = storagePlan(name)
        val entry = ZipEntry(name)
        entry.time = FIXED_TIME
        val canStore = if (sourceMethod >= 0) store && sourceMethod != ZipEntry.DEFLATED else store
        if (canStore) {
            entry.method = ZipEntry.STORED
            entry.size = file.length()
            entry.compressedSize = file.length()
            entry.crc = crc32(file)
            if (align > 1) applyAlignment(zos, fos, entry, align)
        } else {
            entry.method = ZipEntry.DEFLATED
        }
        zos.putNextEntry(entry)
        file.inputStream().use { input ->
            val buffer = ByteArray(128 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                zos.write(buffer, 0, count)
            }
        }
        zos.closeEntry()
    }

    private fun crc32(file: File): Long {
        val crc = CRC32()
        file.inputStream().use { input ->
            val buffer = ByteArray(128 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                crc.update(buffer, 0, count)
            }
        }
        return crc.value
    }

    /** 压缩 / 对齐决策：STORED 扩展名 + 需要的对齐值。 */
    private fun storagePlan(name: String): Pair<Boolean, Int> {
        val lower = name.lowercase(Locale.ROOT)
        val ext = lower.substringAfterLast('.', "")
        if (ext !in STORED_EXTENSIONS) return false to 0
        val align = when {
            ext == "so" && lower.startsWith("lib/") -> ALIGN_SO_PAGE
            ext == "arsc" -> ALIGN_ARSC
            else -> 0
        }
        return true to align
    }

    /**
     * 0xd935 Android 对齐 extra：计算 padding 使条目数据区落在 align 边界。
     * local header = 30 字节 + 名称 + extra；extra = id(2) + dataSize(2) + align(2) + pad。
     */
    private fun applyAlignment(zos: ZipOutputStream, fos: FileOutputStream, entry: ZipEntry, align: Int) {
        zos.flush() // 确保 deflater 缓冲已写入底层流，channel.position() 即下一个 local header 起始
        val nameLen = entry.name.toByteArray(StandardCharsets.UTF_8).size
        val base = fos.channel.position() + 30 + nameLen
        val fieldSize = 6
        val pad = ((align - (base + fieldSize) % align) % align).toInt()
        entry.extra = buildAlignExtra(pad, align)
    }

    private fun buildAlignExtra(pad: Int, align: Int): ByteArray {
        val dataSize = 2 + pad
        val extra = ByteArray(6 + pad)
        extra[0] = (ALIGNMENT_FIELD_ID and 0xff).toByte()
        extra[1] = ((ALIGNMENT_FIELD_ID shr 8) and 0xff).toByte()
        extra[2] = (dataSize and 0xff).toByte()
        extra[3] = ((dataSize shr 8) and 0xff).toByte()
        extra[4] = (align and 0xff).toByte()
        extra[5] = ((align shr 8) and 0xff).toByte()
        return extra
    }

    private fun atomicMove(tmp: File, output: File) {
        try {
            Files.move(
                tmp.toPath(), output.toPath(),
                StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE,
            )
        } catch (e: Exception) {
            Files.move(tmp.toPath(), output.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
