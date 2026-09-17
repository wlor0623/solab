package zhou.solab.engine

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class BlutterPpPostingsTest {

    private val PP_LINES = listOf(
        """[pp+0x1] string: "isVipUser" failed""",
        """[pp+0x2] token x_vip_z ok""",
        """[pp+0x3] SetVipX mapper VIP vip23 premium_member""",
        """[pp+0x4] 普通中文行 vip""",
        "[pp+0x5] plain filler line nothing here",
        "[pp+0x6] Is_Vip paywall gate",
    )

    private fun newResultDir(): File {
        val dir = Files.createTempDirectory("pppost").toFile()
        val body = (listOf("// metadata searchOnly") + PP_LINES).joinToString("\n") + "\n"
        File(dir, "pp.txt").writeText(body)
        return dir
    }

    /** 排序键的规范化序列化，剔除扫描方式相关易变字段后做确定比较。 */
    private fun canon(value: Any?): String = when (value) {
        is JSONObject -> {
            val keys = value.keys().asSequence()
                .filter { it !in setOf("scannedLines", "scanElapsedMs", "fastPath") }
                .toList().sorted()
            "{" + keys.joinToString(",") { "\"" + it + "\"=" + canon(value.opt(it)) + "" } + "}"
        }
        is org.json.JSONArray -> "[" + (0 until value.length()).joinToString(",") { canon(value.get(it)) } + "]"
        else -> value.toString() + ":" + (value?.javaClass?.simpleName ?: "null")
    }

    private fun assertEquivalent(legacy: JSONObject, fast: JSONObject, tag: String) {
        val a = canon(legacy)
        val b = canon(fast)
        if (a != b) assertEquals(tag, a, b)
    }

    @Test
    fun `tokens cover underscore boundary and camel interior`() {
        val t = PpPostings.tokensForLine("token x_vip_z SetVipX Is_Vip")
        assertTrue("vip" in t)
        assertTrue("vipz" in t)          // x_vip_z 中段拼接覆盖 _
        assertTrue("set" in t && "setvip" in t && "setvipx" in t)
        assertTrue("is" in t && "isvip" in t && "is_vip" !in t) // 下划线本身不进词条
    }

    @Test
    fun `locatePp fast equals legacy across vip style queries`() {
        val dir = newResultDir()
        BlutterSearchIndex.resetQueryCacheForTest()

        val legacy = BlutterSearchIndex.locatePp(
            dir,
            queries = listOf("vip"),
            limit = 10,
        )
        assertFalse(legacy.optBoolean("fastPath"))

        PpPostings.build(dir)
        BlutterSearchIndex.resetQueryCacheForTest()

        val fast = BlutterSearchIndex.locatePp(
            dir,
            queries = listOf("vip"),
            limit = 10,
        )
        assertEquivalent(legacy, fast, "locatePp(vip)")

        // camel 内部命中的查询同样等价（SetVipX 场景）
        BlutterSearchIndex.resetQueryCacheForTest()
        val legacyCamel = BlutterSearchIndex.locatePp(dir, listOf("setvipx"), 10)
        BlutterSearchIndex.resetQueryCacheForTest()
        val fastCamel = BlutterSearchIndex.locatePp(dir, listOf("setvipx"), 10)
        assertEquivalent(legacyCamel, fastCamel, "locatePp(setvipx)")
    }

    @Test
    fun `searchPp multiword falls back yet single word goes fast`() {
        val dir = newResultDir()
        BlutterSearchIndex.resetQueryCacheForTest()
        val legacyMulti = BlutterSearchIndex.searchPp(dir, "nothing here", true, 10)
        val legacyMetadata = BlutterSearchIndex.searchPp(dir, "searchonly", true, 10)

        PpPostings.build(dir)
        BlutterSearchIndex.resetQueryCacheForTest()
        val fastMulti = BlutterSearchIndex.searchPp(dir, "nothing here", true, 10)
        assertEquivalent(legacyMulti, fastMulti, "searchPp(multiword)")
        BlutterSearchIndex.resetQueryCacheForTest()
        val fastMetadata = BlutterSearchIndex.searchPp(dir, "searchonly", true, 10)
        assertEquivalent(legacyMetadata, fastMetadata, "searchPp(non-pool line)")

        BlutterSearchIndex.resetQueryCacheForTest()
        val fastSingle = BlutterSearchIndex.searchPp(dir, "paywall", true, 10)
        assertEquals(1, fastSingle.optInt("count"))
        assertEquals("0x6", fastSingle.getJSONArray("matches")
            .getJSONObject(0).getString("offset"))
    }

    @Test
    fun `multiword candidates intersect while alternatives union`() {
        val dir = newResultDir()
        File(dir, "pp.txt").appendText("[pp+0x8] nothing elsewhere\n[pp+0x9] here unrelated\n")
        PpPostings.build(dir)
        val loaded = PpPostings.get(dir)!!

        val phrase = PpPostings.candidateIdsForAny(loaded, listOf(listOf("nothing", "here")))
        assertEquals(1, phrase!!.size)
        assertTrue(PpPostings.readLine(loaded, phrase[0])!!.contains("nothing here"))

        val alternatives = PpPostings.candidateIdsForAny(loaded, listOf(listOf("nothing", "here"), listOf("paywall")))
        assertEquals(2, alternatives!!.size)
        PpPostings.invalidate(dir)
    }

    @Test
    fun `profileAndLocatePp fast matches legacy systems`() {
        val groups = listOf(
            PpFeatureGroup(id = "vip", label = "会员体系", keywords = listOf("vip"), weight = 30),
            PpFeatureGroup(id = "other", label = "其他", keywords = listOf("filler"), weight = 5),
        )
        val dir = newResultDir()
        BlutterSearchIndex.resetQueryCacheForTest()
        val legacy = BlutterSearchIndex.profileAndLocatePp(
            dir, groups, primaryQueries = listOf("vip"), fallbackQueries = emptyList(), limit = 8,
        )

        PpPostings.build(dir)
        BlutterSearchIndex.resetQueryCacheForTest()
        val fast = BlutterSearchIndex.profileAndLocatePp(
            dir, groups, primaryQueries = listOf("vip"), fallbackQueries = emptyList(), limit = 8,
        )
        assertEquivalent(legacy, fast, "profileAndLocatePp(systems)")
        assertEquals(
            "vip",
            fast.getJSONObject("profile").getJSONObject("selectedSystem").optString("id"),
        )
    }

    @Test
    fun `mtime change invalidates until rebuild`() {
        val dir = newResultDir()
        assertNull(PpPostings.get(dir))
        PpPostings.build(dir)
        assertNotNull(PpPostings.get(dir))
        Thread.sleep(5)
        File(dir, "pp.txt").appendText("[pp+0x9] extra vip entry\n")
        assertNull(PpPostings.get(dir)) // header mtime 不匹配 → 需要重建

        PpPostings.build(dir)
        val loaded = PpPostings.get(dir)
        assertNotNull(loaded)
        val ids = PpPostings.candidateIds(loaded!!, listOf("extra"))
        assertNotNull(ids)
        assertEquals(1, ids!!.size)
        assertTrue(PpPostings.readLine(loaded, ids.first())!!.contains("extra vip"))
        // 清理 RAF 句柄避免 Windows 目录锁定
        PpPostings.invalidate(dir)
    }
}
