package zhou.solab.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class EngineIntelTest {

    @Test
    fun `apk analyzer reads local archive without materializing the apk`() {
        val root = Files.createTempDirectory("apk-analyzer-").toFile()
        try {
            val apk = File(root, "sample.apk")
            ZipOutputStream(apk.outputStream()).use { zip ->
                zip.putNextEntry(ZipEntry("AndroidManifest.xml"))
                zip.write("<manifest package=\"sample\"/>".toByteArray())
                zip.closeEntry()
                zip.putNextEntry(ZipEntry("classes.dex"))
                zip.write(ByteArray(0x70).also { it[0] = 'd'.code.toByte(); it[1] = 'e'.code.toByte(); it[2] = 'x'.code.toByte(); it[3] = '\n'.code.toByte() })
                zip.closeEntry()
                zip.putNextEntry(ZipEntry("lib/arm64-v8a/libsample.so"))
                zip.write(ByteArray(32))
                zip.closeEntry()
            }

            val report = ApkAnalyzer.analyze(apk)
            assertEquals(3, report.getInt("entryCount"))
            assertTrue(report.getJSONArray("dexFiles").getJSONObject(0).getBoolean("valid"))
            assertEquals("arm64-v8a", report.getJSONArray("abis").getString(0))
        } finally {
            root.deleteRecursively()
        }
    }

    private fun hex(s: String): ByteArray =
        ByteArray(s.length / 2) { i ->
            ((Character.digit(s[i * 2], 16) shl 4) + Character.digit(s[i * 2 + 1], 16)).toByte()
        }

    @Test
    fun `crypto rules hit sbox iv delta and base64`() {
        val buf = ByteArray(64)
        System.arraycopy(hex("637c777bf26b6fc53001672bfed7ab76"), 0, buf, 8, 16)
        System.arraycopy(hex("0123456789abcdeffedcba9876543210"), 0, buf, 32, 16)
        // TEA delta 单次出现：x4 规则不得误报
        buf[56] = hex("79")[0]; buf[57] = hex("b9")[0]; buf[58] = hex("e3")[0]; buf[59] = hex("9e")[0]

        val ids = CryptoSig.scanBytes(buf).map { it.first.id }.toSet()
        assertTrue("aes_sbox" in ids)
        assertTrue("md5_or_sha1_iv_le" in ids)
        assertFalse("tea_delta_x4" in ids)

        // 四连 delta 命中
        val big = hex("79b9e39e79b9e39e79b9e39e79b9e39e")
        assertTrue(CryptoSig.scanBytes(big).any { it.first.id == "tea_delta_x4" })

        // 文本规则：标准 Base64 表
        val texts = CryptoSig.scanText(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/",
        )
        assertTrue(texts.any { it.id == "base64_std" })
    }

    @Test
    fun `jni mangle short form pairs class and method`() {
        val (cls, method, amb) = JniBridge.mangle("com_example_app_Main_checkVip")
        assertEquals("com/example/app/Main", cls)
        assertEquals("checkVip", method)
        assertFalse(amb)
    }

    private fun sym(n: String, exp: Boolean, v: Long) = SymbolInfo(
        name = n,
        bind = "global",
        type = "func",
        visibility = "default",
        sectionIndex = 1,
        value = v,
        size = 16,
        imported = false,
        exported = exp,
    )

    @Test
    fun `jni build filters exports and flags escapes`() {
        val entries = JniBridge.build(
            listOf(
                sym("Java_com_app_Main_checkVip", true, 0x1000),
                sym("Imported_AES_encrypt", true, 0x10),
                sym("Java_com_app_Util_init__I", true, 0x2000),
                sym("Java_hidden_secret", false, 0x3000),
            ),
        )
        assertEquals(2, entries.size)
        assertEquals("com/app/Main", entries[0].classPath)
        assertEquals("checkVip", entries[0].method)
        assertEquals(0x1000L, entries[0].address)
        // 长名转义（__）标记为歧义
        assertEquals(true, entries[1].ambiguous)
    }

    /** 两结果根 + 指定锚点集合，产出可 diff 的最小树。 */
    private fun makeTree(root: File, klass: String, va: Long, anchors: List<Long>) {
        val body = anchors.joinToString("\n") { "        // ldr x0, [pp+0x${it.toString(16)}]" }
        val f = File(root, "asm/com/app/$klass.dart")
        f.parentFile.mkdirs()
        f.writeText(
            """
            // lib: url 'package:x/t.dart'
            class $klass {

              // ** addr: 0x${va.toString(16)}, size: 0x40
              void check(int lvl) {
            $body
              }
            }
            """.trimIndent() + "\n",
        )
    }

    @Test
    fun `diff exact anchor match yields similarity one across rename`() {
        val root = Files.createTempDirectory("difftest").toFile()
        makeTree(File(root, "old"), "OldCls_7", 0x100, listOf(0x11, 0x22))
        makeTree(File(root, "new"), "NewCls_9", 0x900, listOf(0x11, 0x22))

        val rows = BlutterDiff.match(
            BlutterDiff.buildIndex(File(root, "old")),
            BlutterDiff.buildIndex(File(root, "new")),
            "OldCls_7", 0.9, 10,
        )
        assertEquals(1, rows.length())
        assertEquals("0x100", rows.getJSONObject(0).getString("oldVa"))
        assertEquals("0x900", rows.getJSONObject(0).getString("newVa"))
        assertEquals("OldCls_7", rows.getJSONObject(0).getString("oldClass"))
        assertEquals("NewCls_9", rows.getJSONObject(0).getString("newClass"))
        assertEquals(1.0, rows.getJSONObject(0).getDouble("similarity"), 1e-9)
        root.deleteRecursively()
    }

    @Test
    fun `diff partial anchors land below threshold case`() {
        val root = Files.createTempDirectory("difftest2").toFile()
        makeTree(File(root, "old"), "A_7", 0x100, listOf(0x11, 0x22, 0x33))
        // 新包仅保留两锚点：Jaccard=2/3≈0.667 ≥ 默认 0.45
        makeTree(File(root, "new"), "B_9", 0x200, listOf(0x11, 0x33))

        val rows = BlutterDiff.match(
            BlutterDiff.buildIndex(File(root, "old")),
            BlutterDiff.buildIndex(File(root, "new")),
            "", 0.45, 10,
        )
        assertNotNull(rows)
        org.junit.Assert.assertEquals(1, rows.length())
        org.junit.Assert.assertEquals(0.667, rows.getJSONObject(0).getDouble("similarity"), 0.01)
        root.deleteRecursively()
    }

    @Test
    fun `diff duplicate anchors choose the lowest new va deterministically`() {
        val root = Files.createTempDirectory("difftest3").toFile()
        makeTree(File(root, "old"), "OldClass", 0x100, listOf(0x11, 0x22))
        makeTree(File(root, "new"), "NewHigh", 0x900, listOf(0x11, 0x22))
        makeTree(File(root, "new"), "NewLow", 0x800, listOf(0x11, 0x22))

        val rows = BlutterDiff.match(
            BlutterDiff.buildIndex(File(root, "old")),
            BlutterDiff.buildIndex(File(root, "new")),
            "OldClass", 0.9, 10,
        )
        assertEquals(1, rows.length())
        assertEquals("0x800", rows.getJSONObject(0).getString("newVa"))
        assertEquals("NewLow", rows.getJSONObject(0).getString("newClass"))
        root.deleteRecursively()
    }
}
