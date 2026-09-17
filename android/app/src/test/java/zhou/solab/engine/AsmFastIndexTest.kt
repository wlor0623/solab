package zhou.solab.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class AsmFastIndexTest {

    private fun newResult(): File {
        val dir = Files.createTempDirectory("asmscan").toFile()
        val a = dir.resolve("asm").resolve("com/app/Vip.dart")
        a.parentFile.mkdirs()
        // 签名行在 addr 注释之前（与语义索引消费顺序一致）；再带一个类与方法
        a.writeText(
            """
            // lib: url 'package:vip_app/vip.dart'
            class VipManager {
              VipManager._internal();

              // ** addr: 0x1000, size: 0x80（真实 blutter 格式：addr 即首指令 VA）
              static bool isVipUser(int level) {
                // 0x1000: stp x29, x30, [sp]
                // 0x1008: ldr w0, [x27]
                bx lr
              }
            }
            """.trimIndent().replace("return null;", "bx lr") + "\n",
        )
        val b = dir.resolve("asm").resolve("com/app/Util.dart")
        b.writeText(
            """
            // lib: url 'package:vip_app/util.dart'
            class Util {
              Util();
            }
            """.trimIndent() + "\n",
        )
        return dir
    }

    @Test
    fun `build emits headers inventory jsonl and remains readable`() {
        val dir = newResult()
        val fA = dir.resolve("asm/com/app/Util.dart")
        val libLineProbe = fA.useLines { it.firstOrNull { l -> l.startsWith("// lib:") } }
        println("PROBE libLine=" + libLineProbe)
        val probeExtract = libLineProbe?.substringAfter("url:")?.trim()?.removeSurrounding("'")
            ?.takeIf(String::isNotEmpty)
        println("PROBE extract=" + probeExtract)
        println("PROBE idx=" + (libLineProbe?.indexOf("url:") ?: -999))
        val uIdx = libLineProbe?.indexOf("url") ?: -999
        println("PROBE uIdx=$uIdx")
        if (uIdx >= 0) {
            libLineProbe!!.substring(uIdx).take(8).forEachIndexed { k, c ->
                println("PROBE ch[$k]=$c code=${c.code}")
            }
        }
        val counts = AsmFastIndex.build(dir)

        assertEquals(2, counts.libraries)
        assertEquals(2, counts.classes)
        assertEquals(3, counts.functions)
        assertEquals(1, counts.headerRecords)
        assertEquals(1, BlutterSearchIndex.functionHeaderCount(dir))

        val libs = File(dir, "libraries.jsonl").readLines()
        // 全局按相对路径排序：Util 排在 Vip 之前
        assertTrue(libs.first().contains("util.dart"))
        assertEquals(
            "package:vip_app/vip.dart",
            org.json.JSONObject(libs[1]).optString("name"),
        )

        // 函数头二进制能被既有读者按 cacheHit 消费，且计数正确。
        val meta = BlutterSearchIndex.ensureFunctionHeaderIndex(dir)
        assertTrue(meta.optBoolean("cacheHit"))
        assertEquals(1, meta.optInt("functions"))

        // disasmFunction 通过新写的紧凑索引直接命中函数体。
        val disasm = BlutterSearchIndex.disasmFunction(dir, 0x1000L, 50)
        assertTrue("disasm payload=$disasm", disasm.optBoolean("found"))
        PpPostings.invalidate(dir) // 与其他测试隔离句柄
        dir.deleteRecursively()
    }
}
