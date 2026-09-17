package zhou.solab.tools

import android.content.Context
import com.android.tools.smali.dexlib2.DexFileFactory
import com.android.tools.smali.dexlib2.Opcodes
import com.android.tools.smali.dexlib2.iface.DexFile
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/**
 * M2: DEX 遍历辅助。APK 内的 classes*.dex 解压到 cacheDir 后用
 * loadDexFile(File, ...) 加载。
 * 跨调用复用：同一 APK（按 路径+大小+mtime 指纹）的解压产物缓存在
 * SoLab/cache/dexio/<指纹>/ 下，连续的 dex_xref/class_outline/smali_read
 * 调用不再重复解压；LRU 保留最近 [MAX_CACHED_APKS] 个 APK，超出自动清理。
 * 用 Google fork smali 3.0.9 的 dexlib2（支持 dex 040；org.jf 2.5.2 最高 039，
 * 读外部重组产物会抛 "Dex version 040 is not supported"）。
 *
 * 输入同时兼容 APK/zip 与裸 .dex（外部重组/dump 产物）：
 * 裸 dex 跳过解压直接加载。
 */
object DexIo {

    /** classes*.dex 条目名匹配（共享编译一次；原先在 filter lambda 内逐条目重编译）。 */
    val classesDexRegex = Regex("classes(\\d*)\\.dex", RegexOption.IGNORE_CASE)

    /** dex 解压缓存最多保留的 APK 数（按最近使用淘汰）。 */
    private const val MAX_CACHED_APKS = 2

    /** 缓存目录就绪标记：完整解压成功后写入；存在即视为可复用。 */
    private const val READY_MARKER = ".ready"

    private val ioLock = Any()

    @JvmField
    internal var cacheHits = 0

    @Synchronized
    internal fun resetCacheStatsForTest() {
        cacheHits = 0
    }

    private fun cacheDirectory(context: Context, input: File): File {
        val parent = input.parentFile ?: context.filesDir
        val workspace = if (parent.name in setOf("output", "cache") && parent.parentFile?.name == "SoLab") {
            parent.parentFile?.parentFile ?: parent
        } else {
            parent
        }
        return File(workspace, "SoLab/cache/dexio").apply { mkdirs() }
    }

    /** APK 指纹目录名：SHA-256(canonicalPath|length|lastModified)，APK 变更即失效。 */
    private fun fingerprintDirName(apk: File): String {
        val raw = "${apk.canonicalPath}|${apk.length()}|${apk.lastModified()}"
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(raw.toByteArray())
        return digest.take(12).joinToString("") { "%02x".format(it) }
    }

    /**
     * 解压 APK 内全部 classes*.dex 到指纹目录（已就绪则直接复用）。
     * 返回 dexName → 解压文件 的映射（按名称排序）。
     */
    private fun extractDexFiles(context: Context, apk: File): Map<String, File> {
        val root = cacheDirectory(context, apk)
        val dir = File(root, fingerprintDirName(apk))
        val marker = File(dir, READY_MARKER)
        synchronized(ioLock) {
            if (marker.isFile) {
                marker.setLastModified(System.currentTimeMillis()) // touch：LRU 依据
                val cached = dir.listFiles { f -> f.name.endsWith(".dex") }
                    ?.associateBy { it.name }
                if (cached != null && cached.isNotEmpty()) {
                    cacheHits++
                    return cached
                }
            }
            dir.deleteRecursively() // 半成品（中途取消/失败）重抽
            dir.mkdirs()
            val extracted = LinkedHashMap<String, File>()
            ZipFile(apk).use { zip ->
                val names = zip.entries().asSequence()
                    .mapNotNull { e -> if (e.isDirectory) null else e.name }
                    .filter { it.startsWith("classes") && it.endsWith(".dex") }
                    .sorted().toList()
                for (dexName in names) {
                    TaskCancel.check() // 可打断检查点（对话停止时终止遍历）
                    val out = File(dir, dexName)
                    zip.getInputStream(zip.getEntry(dexName)).use { input ->
                        out.outputStream().use { input.copyTo(it) }
                    }
                    extracted[dexName] = out
                }
            }
            marker.outputStream().use { /* 只需存在 */ }
            evictStaleApkCaches(root, keepDir = dir)
            return extracted
        }
    }

    /** LRU 淘汰：只保留最近使用的 [MAX_CACHED_APKS] 个 APK 指纹目录。 */
    private fun evictStaleApkCaches(root: File, keepDir: File) {
        runCatching {
            val dirs = root.listFiles { f -> f.isDirectory } ?: return
            for (stale in dirs
                .filter { it != keepDir }
                .sortedByDescending { File(it, READY_MARKER).lastModified() }
                .drop(MAX_CACHED_APKS - 1)) {
                stale.deleteRecursively()
            }
        }
    }

    /** 裸 dex 检测（文件头 "dex\n"）：APK 是 "PK\x03\x04"。 */
    fun isBareDex(file: File): Boolean {
        if (!file.isFile) return false
        file.inputStream().use { input ->
            val magic = ByteArray(4)
            if (input.read(magic) != 4) return false
            return magic[0] == 'd'.code.toByte() &&
                magic[1] == 'e'.code.toByte() &&
                magic[2] == 'x'.code.toByte() &&
                magic[3] == 0x0A.toByte()
        }
    }

    /**
     * 裸 dex 包装为单 classes.dex 的临时 zip（cacheDir 下），供只认
     * APK/zip 的加载方（DexKitBridge.create）使用；调用方负责删除。
     */
    fun wrapBareDexAsApk(context: Context, dex: File): File {
        val cacheDir = cacheDirectory(context, dex)
        val tmp = File(cacheDir, "${System.nanoTime()}-wrap-${dex.name}.zip")
        ZipOutputStream(tmp.outputStream().buffered()).use { zip ->
            zip.putNextEntry(ZipEntry("classes.dex"))
            dex.inputStream().use { it.copyTo(zip) }
            zip.closeEntry()
        }
        return tmp
    }

    fun eachDex(context: Context, apk: File, block: (dexName: String, dexFile: DexFile) -> Unit) {
        // 裸 dex：本身就是 dex 文件，直接加载（ZipFile 会抛 "zip END header not found"）
        if (isBareDex(apk)) {
            block(apk.name, DexFileFactory.loadDexFile(apk, Opcodes.getDefault()))
            return
        }
        val extracted = extractDexFiles(context, apk)
        for ((dexName, file) in extracted) {
            TaskCancel.check()
            block(dexName, DexFileFactory.loadDexFile(file, Opcodes.getDefault()))
        }
    }

    internal fun cachedDexNamesForTest(context: Context, apk: File): Set<String> =
        extractDexFiles(context, apk).keys
}
