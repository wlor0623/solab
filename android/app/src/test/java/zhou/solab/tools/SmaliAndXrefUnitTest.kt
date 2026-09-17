package zhou.solab.tools

import zhou.solab.ApkDexPatcher
import zhou.solab.ApkPatternScanner
import zhou.solab.engine.blutterLocateKeywords
import zhou.solab.engine.blutterMembershipGoal
import zhou.solab.engine.blutterPrimaryKeywords
import zhou.solab.engine.blutterIntentDomain
import android.content.ContextWrapper
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.File
import java.nio.file.Files
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** smaliRead / DexXrefEngine 纯函数单测（R4 基线格式 + 调用图匹配逻辑）。 */
class SmaliAndXrefUnitTest {

    @Test
    fun accessModifiers_publicStatic() {
        // ACC_PUBLIC(0x1) | ACC_STATIC(0x8) | ACC_FINAL(0x10)
        assertEquals("public static final", SmaliReadTool.accessModifiers(0x1 or 0x8 or 0x10))
    }

    @Test
    fun accessModifiers_privateVoid() {
        assertEquals("private", SmaliReadTool.accessModifiers(0x2))
    }

    @Test
    fun accessModifiers_constructor() {
        // ACC_PUBLIC | ACC_CONSTRUCTOR(0x8000, dex 特有)
        assertEquals("public constructor", SmaliReadTool.accessModifiers(0x1 or 0x8000))
    }

    @Test
    fun accessModifiers_emptyForZero() {
        assertEquals("", SmaliReadTool.accessModifiers(0))
    }

    @Test
    fun matchesNoSignature_exactPrefix() {
        assertTrue(
            DexXrefEngine.matchesNoSignature(
                "Lcom/foo/Bar;->isVip",
                "Lcom/foo/Bar;->isVip()Z",
            ),
        )
    }

    @Test
    fun matchesNoSignature_rejectsDifferentClass() {
        assertFalse(
            DexXrefEngine.matchesNoSignature(
                "Lcom/foo/Bar;->isVip",
                "Lcom/foo/Baz;->isVip()Z",
            ),
        )
    }

    @Test
    fun matchesNoSignature_rejectsNonCallSite() {
        // 目标后跟非 '('（如字段名前缀）不算命中
        assertFalse(
            DexXrefEngine.matchesNoSignature(
                "Lcom/foo/Bar;->isVip",
                "Lcom/foo/Bar;->isVipField()Ljava/lang/String;".let { it.replace("isVipField", "isVipField") },
            ),
        )
    }

    @Test
    fun matchesNoSignature_withSignatureTarget() {
        // 带签名的目标走精确匹配路径（本函数只服务无签名场景，返回 false 由调用方走精确分支）
        assertFalse(
            DexXrefEngine.matchesNoSignature(
                "Lcom/foo/Bar;->isVip()Z",
                "Lcom/foo/Bar;->isVip()Z",
            ),
        )
    }

    @Test
    fun fieldAccess_classifiesLowercaseStaticWrite() {
        assertEquals("WRITE_FIELD", DexXrefEngine.fieldRelation("sput-boolean"))
        assertEquals("WRITE_STATIC", DexXrefEngine.fieldAccessKind("sput-boolean"))
        assertEquals("READ_STATIC", DexXrefEngine.fieldAccessKind("sget-boolean"))
    }

    @Test
    fun normalizeMethodTarget_stripsQualifiedSignature() {
        assertEquals(
            "lcom/foo/bar;->isvip",
            ApkDexPatcher.normalizeMethodTarget("Lcom/foo/Bar;->isVip()Z"),
        )
    }

    @Test
    fun stringScan_skipsOnlyKnownMediaPayloads() {
        assertFalse(SolabStringScanTool.shouldScanEntry("res/drawable/banner.webp"))
        assertFalse(SolabStringScanTool.shouldScanEntry("assets/font.woff2"))
        assertTrue(SolabStringScanTool.shouldScanEntry("classes.dex"))
        assertTrue(SolabStringScanTool.shouldScanEntry("lib/arm64-v8a/libapp.so"))
        assertTrue(SolabStringScanTool.shouldScanEntry("resources.arsc"))
    }

    @Test
    fun blutterLocate_preservesExactMembershipTierFirst() {
        assertTrue(blutterMembershipGoal("至尊"))
        assertTrue(blutterMembershipGoal("钻石"))
        assertEquals("至尊", blutterLocateKeywords("至尊").first())
        assertEquals("钻石", blutterLocateKeywords("钻石").first())
        assertEquals("至尊永久VIP", blutterLocateKeywords("至尊永久VIP").first())
        assertTrue(blutterLocateKeywords("至尊").contains("vipType"))
        assertEquals(listOf("至尊"), blutterPrimaryKeywords("至尊"))
        assertEquals(listOf("定位会员判断", "会员"), blutterPrimaryKeywords("定位会员判断"))
        assertEquals("membership", blutterIntentDomain("unlock Pro membership"))
        assertEquals("capture", blutterIntentDomain("绕过 SSL pinning 抓包"))
        assertEquals("ads", blutterIntentDomain("remove rewarded ads"))
    }

    @Test
    fun xrefPageSlicesCallersAndNormalizesNegativeOffset() {
        val callers = (0 until 120).map { listOf("Lx;->m$it()V", "", "1").joinToString("\u0001") }
        val snapshot = DexXrefEngine.XrefSnapshot(
            directCallers = callers,
            summary = JSONObject().put("totalCallers", 120),
        )

        val page = DexXrefEngine.xrefPage(snapshot, "Lt;->m()V", "to", 50, 50)
        assertEquals(50, page.getJSONArray("directCallers").length())
        assertEquals("Lx;->m50()V", page.getJSONArray("directCallers").getJSONObject(0).getString("qualifiedId"))
        assertTrue(page.getBoolean("truncated"))
        assertEquals("100", page.getString("nextCursor"))

        val first = DexXrefEngine.xrefPage(snapshot, "Lt;->m()V", "to", -1, 50)
        assertEquals("Lx;->m0()V", first.getJSONArray("directCallers").getJSONObject(0).getString("qualifiedId"))
    }

    @Test
    fun xrefPageReachesDeepOffsetsWithoutCap() {
        // 1200 个调用方远超旧版 500 封顶：任何 offset 都必须可达
        val callers = (0 until 1200).map { listOf("Lx;->m$it()V", "classes.dex", "2").joinToString("\u0001") }
        val snapshot = DexXrefEngine.XrefSnapshot(
            directCallers = callers,
            summary = JSONObject().put("totalCallers", 1200),
        )

        val tail = DexXrefEngine.xrefPage(snapshot, "Lt;->m()V", "to", 1150, 50)
        assertEquals(50, tail.getJSONArray("directCallers").length())
        assertEquals("Lx;->m1150()V", tail.getJSONArray("directCallers").getJSONObject(0).getString("qualifiedId"))
        assertEquals("Lx;->m1199()V", tail.getJSONArray("directCallers").getJSONObject(49).getString("qualifiedId"))
        assertFalse(tail.getBoolean("truncated"))
        assertEquals("", tail.getString("nextCursor"))
        assertEquals(1200, tail.getJSONObject("summary").getInt("totalCallers"))
    }

    @Test
    fun callSitesPageBeyondLegacyDefaultWindow() {
        // 旧版 callSites 截断在前 300 条且不可达；现在默认窗口 300 可继续翻页
        val sites = (0 until 350).map {
            listOf("Lc;->caller$it()V", "$it", "INVOKE_VIRTUAL", "virtual", "classes.dex").joinToString("\u0001")
        }
        val snapshot = DexXrefEngine.XrefSnapshot(
            callSites = sites,
            summary = JSONObject().put("totalCallSites", 350),
        )

        val firstPage = DexXrefEngine.xrefPage(snapshot, "Lt;->m()V", "to", 0, 50)
        assertEquals(300, firstPage.getJSONArray("callSites").length())
        assertTrue(firstPage.getBoolean("callSitesTruncated"))
        assertEquals("300", firstPage.getString("callSitesNextCursor"))

        val secondPage = DexXrefEngine.xrefPage(
            snapshot, "Lt;->m()V", "to", 0, 50, callSiteOffset = 300, callSiteLimit = 300,
        )
        assertEquals(50, secondPage.getJSONArray("callSites").length())
        assertEquals("Lc;->caller300()V", secondPage.getJSONArray("callSites").getJSONObject(0).getString("caller"))
        assertFalse(secondPage.getBoolean("callSitesTruncated"))
    }

    @Test
    fun fieldPageKeepsWritersFirstAndReachesAllRows() {
        val writers = (0 until 3).map {
            listOf("Lf;->x:Z", "Lw;->w$it()V", "WRITE_FIELD", "WRITE_INSTANCE", "IPUT", "$it", "0", "classes.dex")
                .joinToString("\u0001")
        }
        val readers = (0 until 600).map {
            listOf("Lf;->x:Z", "Lr;->r$it()V", "READ_FIELD", "READ_INSTANCE", "IGET", "$it", "0", "classes.dex")
                .joinToString("\u0001")
        }
        val snapshot = DexXrefEngine.XrefSnapshot(
            fieldRefs = writers + readers,
            summary = JSONObject().put("totalRefs", 603).put("totalWrites", 3).put("totalReads", 600),
        )

        // 缺省 = 全量兼容路径（Dart 网关全量消费，写入方仍在前）
        val full = DexXrefEngine.fieldPage(snapshot, "Lf;->x:Z", null, null)
        assertEquals(603, full.getJSONArray("fieldRefs").length())
        assertEquals("WRITE_FIELD", full.getJSONArray("fieldRefs").getJSONObject(0).getString("relation"))
        assertEquals("Lw;->w2()V", full.getJSONArray("fieldRefs").getJSONObject(2).getString("method"))
        assertEquals("Lr;->r0()V", full.getJSONArray("fieldRefs").getJSONObject(3).getString("method"))

        // 分页：深 offset 可达，且不打乱写入方优先序
        val tail = DexXrefEngine.fieldPage(snapshot, "Lf;->x:Z", 600, 500)
        assertEquals(3, tail.getJSONArray("fieldRefs").length())
        assertEquals("Lr;->r597()V", tail.getJSONArray("fieldRefs").getJSONObject(0).getString("method"))
        assertFalse(tail.getBoolean("truncated"))
        assertEquals("", tail.getString("nextCursor"))
    }

    @Test
    fun callGraphKeepsCallerTargetAndCalleeDirections() {
        val graph = DexXrefEngine.buildCallGraph(
            "Lx/Target;->run()V",
            JSONArray().put(JSONObject().put("qualifiedId", "Lx/Caller;->go()V").put("callSiteCount", 2)),
            JSONArray(),
            JSONArray().put(JSONObject().put("qualifiedId", "Lx/Callee;->work()V").put("callSiteCount", 1)),
        )

        assertEquals(3, graph.getJSONArray("nodes").length())
        val edges = graph.getJSONArray("edges")
        assertEquals("Lx/Caller;->go()V", edges.getJSONObject(0).getString("from"))
        assertEquals("Lx/Target;->run()V", edges.getJSONObject(0).getString("to"))
        assertEquals("Lx/Target;->run()V", edges.getJSONObject(1).getString("from"))
        assertEquals("Lx/Callee;->work()V", edges.getJSONObject(1).getString("to"))
    }

    @Test
    fun inheritancePathFindsIndirectOverrideOwner() {
        val path = DexXrefEngine.inheritancePath(
            "Lapp/Child;",
            "Lapi/Contract;",
            mapOf(
                "Lapp/Child;" to listOf("Lapp/Base;"),
                "Lapp/Base;" to listOf("Ljava/lang/Object;", "Lapi/Contract;"),
            ),
        )

        assertEquals(listOf("Lapp/Child;", "Lapp/Base;", "Lapi/Contract;"), path)
    }

    @Test
    fun overrideSignatureAllowsCovariantReturnButRejectsDifferentParameters() {
        assertTrue(DexXrefEngine.overrideSignatureMatches(
            "(Ljava/lang/String;)Ljava/lang/Object;",
            "(Ljava/lang/String;)Ljava/lang/String;",
        ))
        assertFalse(DexXrefEngine.overrideSignatureMatches("(I)V", "(J)V"))
    }

    @Test
    fun xrefRejectsUnknownDirectionBeforeScanningDex() {
        val apk = Files.createTempFile("xref-invalid-direction-", ".apk").toFile()
        try {
            val result = DexXrefEngine.xref(
                ContextWrapper(null),
                apk.absolutePath,
                "Lx/Target;->run()V",
                direction = "sideways",
            )
            assertFalse(result.getBoolean("ok"))
            assertEquals("INVALID_ARGUMENT", result.getJSONObject("error").getString("code"))
        } finally {
            apk.delete()
        }
    }

    @Test
    fun scanDualReportsOverlappingPatternsToBothGroups() {
        val input = ByteArrayInputStream("com.example.ads.showAd".toByteArray())

        val (primary, extra) = ApkPatternScanner.scanDual(
            input,
            listOf("example.ads", "showad"),
            listOf("showad", "ads.show"),
        )

        assertTrue("showad" in primary)
        assertTrue("showad" in extra)
        assertTrue("ads.show" in extra)
    }

    @Test
    fun dexIoReusesExtractedDexCache() {
        val root = Files.createTempDirectory("dexio-cache-").toFile()
        try {
            val apk = File(root, "sample.apk")
            ZipOutputStream(apk.outputStream()).use { zip ->
                listOf("classes.dex", "classes2.dex").forEach { name ->
                    zip.putNextEntry(ZipEntry(name))
                    zip.write(byteArrayOf(0x64, 0x65, 0x78, 0x0a))
                    zip.closeEntry()
                }
            }
            DexIo.resetCacheStatsForTest()
            val context = ContextWrapper(null)

            assertEquals(setOf("classes.dex", "classes2.dex"), DexIo.cachedDexNamesForTest(context, apk))
            assertEquals(setOf("classes.dex", "classes2.dex"), DexIo.cachedDexNamesForTest(context, apk))
            assertEquals(1, DexIo.cacheHits)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun indexFieldRowsAreInterchangeableWithScanRows() {
        // P0 契约：SQLite 索引产出的紧凑行必须与全量扫描行完全同构，
        // 才能直接复用 fieldPage/fieldRowJson（索引=扫描等价性的构造保证）。
        val scanRow = DexXrefEngine.fieldRefRow(
            fieldQid = "Lcom/x/A;->isVip:Z",
            methodQid = "Lcom/x/B;->setVip(Z)V",
            relation = "WRITE_FIELD",
            accessKind = "WRITE_INSTANCE",
            opcode = "IPUT",
            insnIndex = 7,
            dexId = 1,
            dexFile = "classes2.dex",
        )
        // 行格式 = 8 段 \u0001 分隔，顺序与扫描响应契约一致
        val parts = scanRow.split('\u0001')
        assertEquals(8, parts.size)
        assertEquals("Lcom/x/A;->isVip:Z", parts[0])
        assertEquals("Lcom/x/B;->setVip(Z)V", parts[1])
        assertEquals("WRITE_FIELD", parts[2])
        assertEquals("7", parts[5])

        // 同一行喂给分页响应构建器，字段/指令/关系不丢
        val snapshot = DexXrefEngine.XrefSnapshot(
            fieldRefs = listOf(scanRow),
            summary = JSONObject().put("totalRefs", 1).put("totalWrites", 1).put("totalReads", 0),
        )
        val page = DexXrefEngine.fieldPage(snapshot, "Lcom/x/A;->isVip:Z", null, null)
        val row = page.getJSONArray("fieldRefs").getJSONObject(0)
        assertEquals("Lcom/x/A;->isVip:Z", row.getString("field"))
        assertEquals("Lcom/x/B;->setVip(Z)V", row.getString("method"))
        assertEquals("WRITE_FIELD", row.getString("relation"))
        assertEquals(7, row.getInt("instructionIndex"))
        assertEquals("classes2.dex", row.getString("dexFile"))
    }
}
