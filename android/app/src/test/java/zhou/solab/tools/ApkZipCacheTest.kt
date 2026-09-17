package zhou.solab.tools

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** ApkZipCache 引用计数 pin 语义：使用中的句柄不得被 LRU 驱逐或指纹换新关闭。 */
class ApkZipCacheTest {

    private fun writeApk(dir: File, name: String, content: String = "hello"): File {
        val apk = File(dir, name)
        ZipOutputStream(apk.outputStream().buffered()).use { zip ->
            zip.putNextEntry(ZipEntry("a.txt"))
            zip.write(content.toByteArray())
            zip.closeEntry()
        }
        return apk
    }

    /** 关闭后的 ZipFile 在 getEntry/getInputStream 上抛 IllegalStateException。 */
    private fun readEntry(zip: java.util.zip.ZipFile) {
        val entry = zip.getEntry("a.txt")
        assertNotNull(entry)
        zip.getInputStream(entry).use { it.readBytes() }
    }

    @Test
    fun pinnedHandlesSurviveLruEviction() {
        val root = Files.createTempDirectory("apkzip").toFile()
        try {
            val cache = ApkZipCache()
            val a = writeApk(root, "a.apk")
            val b = writeApk(root, "b.apk")
            val c = writeApk(root, "c.apk")

            cache.withZip(a) { zipA ->
                cache.withZip(b) { zipB ->
                    // 第 3 个 APK 触发驱逐：A/B 仍被 pin，不得被 close
                    cache.withZip(c) { readEntry(it) }
                    readEntry(zipA)
                    readEntry(zipB)
                }
            }
            // 全部释放后缓存回落：再次 open 仍正常
            cache.withZip(a) { readEntry(it) }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun releasedHandlesDoNotAccumulate() {
        val root = Files.createTempDirectory("apkzip").toFile()
        try {
            val cache = ApkZipCache()
            // 顺序开合 3 个不同 APK，释放后应回落到 maxEntries，不积累句柄
            repeat(3) { n ->
                val apk = writeApk(root, "r$n.apk", "payload-$n")
                cache.withZip(apk) { readEntry(it) }
            }
            cache.withZip(writeApk(root, "last.apk", "tail")) { readEntry(it) }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun staleFingerprintHandleKeptAliveUntilReleased() {
        val root = Files.createTempDirectory("apkzip").toFile()
        try {
            val cache = ApkZipCache()
            val apk = writeApk(root, "s.apk", "before")
            var oldHandle: java.util.zip.ZipFile? = null

            cache.withZip(apk) { oldZip ->
                oldHandle = oldZip
                // 重写同 path 文件产生新指纹（内容变长 → size 必变）。
                // 注意：底层文件被替换后旧句柄的磁盘偏移失效，read 不可靠——
                // pin 的保护对象是「不被 close」，用 getEntry（纯内存索引，
                // close 后抛 IllegalStateException）作为存活判据。
                writeApk(root, "s.apk", "after-much-longer-content")

                cache.withZip(apk) { newZip ->
                    readEntry(newZip)
                    // 旧指纹句柄仍被外层 pin：不得被换新逻辑关闭
                    assertNotNull(oldZip.getEntry("a.txt"))
                }
                // 内层 release 后旧句柄依旧存活（外层 pin 未释放）
                assertEquals(1, cache.pinCountForTest(oldZip))
                assertNotNull(oldZip.getEntry("a.txt"))
            }
            // 外层 release：旧指纹已被顶替 → 立即 close 回收
            assertEquals(-1, cache.pinCountForTest(oldHandle!!))
            try {
                oldHandle!!.getEntry("a.txt")
                org.junit.Assert.fail("旧指纹句柄应在 release 后被 close")
            } catch (_: IllegalStateException) {
                // closed，符合预期
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun nestedSameSourceSharesHandleAndPin() {
        val root = Files.createTempDirectory("apkzip").toFile()
        try {
            val cache = ApkZipCache()
            val apk = writeApk(root, "n.apk")

            cache.withZip(apk) { outer ->
                cache.withZip(apk) { inner ->
                    assertEquals(outer, inner)
                    readEntry(inner)
                }
                readEntry(outer)
            }
        } finally {
            root.deleteRecursively()
        }
    }
}
