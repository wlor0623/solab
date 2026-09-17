package zhou.solab.tools

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class ApkArchiveToolTest {
    @Test
    fun listsAndReadsArchiveEntriesInBoundedWindows() {
        val dir = kotlin.io.path.createTempDirectory("apk-archive-test").toFile()
        try {
            val apk = File(dir, "sample.apk")
            ZipOutputStream(apk.outputStream()).use { zip ->
                zip.putNextEntry(ZipEntry("assets/first.txt"))
                zip.write("first entry".toByteArray())
                zip.closeEntry()
                zip.putNextEntry(ZipEntry("assets/second.bin"))
                zip.write(byteArrayOf(0, 1, 2, 3))
                zip.closeEntry()
                zip.putNextEntry(ZipEntry("res/raw/third.txt"))
                zip.write("third entry resource_value".toByteArray())
                zip.closeEntry()
            }

            val list = ApkArchiveTool.handle(
                JSONObject().put("path", apk.absolutePath).put("action", "list").put("query", "assets/").put("limit", 1),
            )
            assertTrue(list.getBoolean("ok"))
            assertEquals(2, list.getInt("total"))
            assertEquals(1, list.getJSONArray("entries").length())
            assertEquals(1, list.getInt("nextOffset"))

            val text = ApkArchiveTool.handle(
                JSONObject().put("path", apk.absolutePath).put("action", "read").put("entry", "assets/first.txt").put("limit", 5),
            )
            assertTrue(text.getBoolean("ok"))
            assertEquals("UTF-8", text.getString("encoding"))
            assertEquals("first", text.getString("content"))
            assertTrue(text.getBoolean("truncated"))

            val binary = ApkArchiveTool.handle(
                JSONObject().put("path", apk.absolutePath).put("action", "read").put("entry", "assets/second.bin"),
            )
            assertTrue(binary.getBoolean("ok"))
            assertEquals("binary", binary.getString("encoding"))
            assertEquals("00 01 02 03", binary.getString("hexPreview"))
            assertFalse(binary.getBoolean("truncated"))

            val strings = ApkArchiveTool.handle(
                JSONObject().put("path", apk.absolutePath).put("action", "strings").put("entry", "res/raw/third.txt").put("minLen", 8),
            )
            assertTrue(strings.getBoolean("ok"))
            assertTrue(strings.getJSONArray("strings").toString().contains("resource_value"))
        } finally {
            dir.deleteRecursively()
        }
    }
}
