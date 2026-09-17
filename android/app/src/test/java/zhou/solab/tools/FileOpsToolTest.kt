package zhou.solab.tools

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class FileOpsToolTest {
    @Test
    fun extractsUtf16StringsFromBinaryResource() {
        val file = File.createTempFile("solab_strings_", ".arsc")
        try {
            file.writeBytes(byteArrayOf(1, 2, 3, 4) + "Via\u0000google_app_id\u0000".toByteArray(Charsets.UTF_16LE))

            val result = FileOpsTool.handle(JSONObject()
                .put("action", "strings")
                .put("path", file.absolutePath)
                .put("encoding", "utf16le"))

            val text = result.toString()
            assertTrue(text.contains("Via"))
            assertTrue(text.contains("google_app_id"))
        } finally {
            file.delete()
        }
    }

    private fun writeSampleApk(root: File): File {
        val zip = File(root, "sample.apk")
        ZipOutputStream(zip.outputStream().buffered()).use { out ->
            for (name in listOf(
                "classes.dex",
                "classes2.dex",
                "res/a.xml",
                "res/b.xml",
                "lib/arm64-v8a/libapp.so",
                "META-INF/MANIFEST.MF",
            )) {
                out.putNextEntry(ZipEntry(name))
                out.write(name.toByteArray())
                out.closeEntry()
            }
        }
        return zip
    }

    @Test
    fun listsZipEntriesWithPaginationAndPrefix() {
        val root = Files.createTempDirectory("fileops_zip").toFile()
        try {
            val zip = writeSampleApk(root)

            // 全量：包内条目清单（此前 DIR_NOT_FOUND 的场景）
            val all = FileOpsTool.handle(
                JSONObject().put("action", "list").put("path", zip.absolutePath),
            )
            assertTrue(all.getBoolean("ok"))
            assertEquals("zip_entries", all.getString("kind"))
            assertEquals(6, all.getInt("total"))
            assertEquals(6, all.getInt("returned"))
            assertFalse(all.getBoolean("hasMore"))
            assertTrue(all.getJSONArray("items").getJSONObject(0).getString("name") == "META-INF/MANIFEST.MF")

            // 分页：排序稳定、offset 可达任意位置
            val page1 = FileOpsTool.handle(
                JSONObject()
                    .put("action", "list")
                    .put("path", zip.absolutePath)
                    .put("limit", 2),
            )
            assertEquals(2, page1.getInt("returned"))
            assertTrue(page1.getBoolean("hasMore"))
            assertEquals(2, page1.getInt("nextOffset"))
            assertEquals("META-INF/MANIFEST.MF", page1.getJSONArray("items").getJSONObject(0).getString("name"))

            val page2 = FileOpsTool.handle(
                JSONObject()
                    .put("action", "list")
                    .put("path", zip.absolutePath)
                    .put("limit", 2)
                    .put("offset", 2),
            )
            assertEquals("classes2.dex", page2.getJSONArray("items").getJSONObject(0).getString("name"))

            // 前缀过滤：包体差异排查入口
            val filtered = FileOpsTool.handle(
                JSONObject()
                    .put("action", "list")
                    .put("path", zip.absolutePath)
                    .put("entryPrefix", "res/"),
            )
            assertEquals(2, filtered.getInt("total"))
            assertEquals("res/a.xml", filtered.getJSONArray("items").getJSONObject(0).getString("name"))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun listStillRejectsNonArchiveFile() {
        val file = File.createTempFile("plain_", ".txt")
        try {
            file.writeText("hello")
            val result = FileOpsTool.handle(
                JSONObject().put("action", "list").put("path", file.absolutePath),
            )
            // 非 APK/ZIP 的普通文件仍报 DIR_NOT_FOUND（语义不变）
            assertFalse(result.getBoolean("ok"))
            assertEquals("DIR_NOT_FOUND", result.getJSONObject("error").getString("code"))
        } finally {
            file.delete()
        }
    }
}
