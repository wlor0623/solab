package zhou.solab.engine

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files

class BlutterSearchIndexTest {

    @Test
    fun parsePoolOffsetsAcceptsPipeSeparatedHexSlots() {
        assertEquals(listOf(0x21ad0L, 0x21ad8L), parseBlutterPoolOffsets("21ad0|21ad8"))
    }

    @Test
    fun arm64PoolIndexUsesCompactBinaryAndKeepsRawObfuscatedReferences() {
        val resultDir = Files.createTempDirectory("blutter-binary-xref-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "result.json").writeText("{}")
            val libapp = ByteBuffer.allocate(32)
                .order(ByteOrder.LITTLE_ENDIAN)
                .putInt(0x91406b69.toInt()) // add x9, x27, #0x1a, lsl #12
                .putInt(0xf945d520.toInt()) // ldr x0, [x9, #0xba8]
                .array()

            BlutterSearchIndex.buildArm64PoolIndex(libapp, resultDir)

            val binary = File(resultDir, "pp-xref-arm64-v2.bin")
            assertTrue(binary.isFile)
            assertEquals(25L, binary.length())
            assertFalse(File(resultDir, "pp-xref-arm64.jsonl").exists())
            val xref = BlutterSearchIndex.xrefMany(resultDir, listOf(0x1aba8), 4)
            assertEquals("compact_pool_index", xref.getString("lookupMode"))
            val refs = xref.getJSONObject("refsByOffset")
                .getJSONArray("0x1aba8")
            assertEquals(1, refs.length())
            assertEquals("0x0", refs.getJSONObject(0).getString("va"))
            assertEquals("arm64_raw_add_ldr", refs.getJSONObject(0).getString("referenceMode"))
            assertFalse(File(resultDir, "blutter-semantic-v2.jsonl.gz").exists())
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun arm64PoolIndexCoversLdpClosurePairs() {
        // Dart AOT 闭包+代码对是 ldp 成对池加载（缺陷 1 根因：旧索引只认 ldr，
        // 0x21ad0/0x21ad8 这类槽 xref 落空的根因）。构造 ldp x2, x3, [x27, #0x2a0]
        // 验证成对引用落索引且 xref 能查到两个槽。
        val resultDir = Files.createTempDirectory("blutter-ldp-xref-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "result.json").writeText("{}")
            // ldp x2, x3, [x27, #0x2a0]：
            //   imm7 = 0x2a0/8 = 0x54；编码 = 0xA9400362 | (imm7 << 15) | (rt2 << 10) | (rn << 5) | rt
            //   0xA9400362 基（ldp x2,x3,[x27,#0]）：opc=10, L=1, rn=27, rt2=3, rt=2
            // ldp x2, x3, [x27, #0x2a0]：正确编码 = 0xA9400362 | (3<<10) | (imm7<<15)
            //   （imm7=0x2a0/8=0x54；0xA9400362 = 64 位 LDP 家族基 + rn=27, rt=2）
            val imm7 = 0x1a0 / 8
            val ldp = 0xa9400362.toInt() or (3 shl 10) or (imm7 shl 15)
            // 扫描循环要求 >=28 字节（while offset+28<=end），补足 32 字节
            val libapp = ByteBuffer.allocate(32)
                .order(ByteOrder.LITTLE_ENDIAN)
                .putInt(ldp)
                .putInt(0xd503201f.toInt()) // nop
                .putInt(0xd503201f.toInt())
                .putInt(0xd503201f.toInt())
                .putInt(0xd503201f.toInt())
                .putInt(0xd503201f.toInt())
                .putInt(0xd503201f.toInt())
                .putInt(0xd503201f.toInt())
                .array()

            BlutterSearchIndex.buildArm64PoolIndex(libapp, resultDir)

            val xref = BlutterSearchIndex.xrefMany(
                resultDir,
                listOf(0x1a0L, 0x1a8L),
                4,
            )
            val byOffset = xref.getJSONObject("refsByOffset")
            val first = byOffset.getJSONArray("0x1a0")
            val second = byOffset.getJSONArray("0x1a8")
            assertEquals(1, first.length())
            assertEquals(1, second.length())
            assertEquals("arm64_raw_ldp_pp", first.getJSONObject(0).getString("referenceMode"))
            assertEquals("arm64_raw_ldp_pp", second.getJSONObject(0).getString("referenceMode"))
            assertEquals("0x0", first.getJSONObject(0).getString("va"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun arm64PoolIndexLinksClosurePoolPairToIndirectBlrCall() {
        val resultDir = Files.createTempDirectory("blutter-ldp-blr-xref-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "result.json").writeText("{}")
            val imm7 = 0x1a0 / 8
            val ldp = 0xa9400362.toInt() or (3 shl 10) or (imm7 shl 15)
            val libapp = ByteBuffer.allocate(32)
                .order(ByteOrder.LITTLE_ENDIAN)
                .putInt(ldp)
                .putInt(0xd503201f.toInt())
                .putInt(0xd63f0060.toInt())
                .putInt(0xd503201f.toInt())
                .putInt(0xd503201f.toInt())
                .putInt(0xd503201f.toInt())
                .putInt(0xd503201f.toInt())
                .putInt(0xd503201f.toInt())
                .array()

            BlutterSearchIndex.buildArm64PoolIndex(libapp, resultDir)

            val refs = BlutterSearchIndex.xrefMany(resultDir, listOf(0x1a0L, 0x1a8L), 4)
                .getJSONObject("refsByOffset")
            val first = refs.getJSONArray("0x1a0").getJSONObject(0)
            val second = refs.getJSONArray("0x1a8").getJSONObject(0)
            assertEquals("arm64_raw_ldp_pp_blr", first.getString("referenceMode"))
            assertEquals("arm64_raw_ldp_pp_blr", second.getString("referenceMode"))
            assertTrue(first.getBoolean("indirectCall"))
            assertEquals("0x8", first.getString("callVa"))
            assertEquals("x3", first.getString("callRegister"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun arm64PoolIndexLinksLargePoolOffsetThroughAddLdpAndBlr() {
        val resultDir = Files.createTempDirectory("blutter-add-ldp-blr-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "result.json").writeText("{}")
            val addHigh = 0x91408769.toInt()
            val addLow = 0x91236129.toInt()
            val ldp = 0xa95f8d22.toInt()
            val libapp = ByteBuffer.allocate(32)
                .order(ByteOrder.LITTLE_ENDIAN)
                .putInt(addHigh)
                .putInt(addLow)
                .putInt(ldp)
                .putInt(0xd63f0060.toInt())
                .putInt(0xd503201f.toInt())
                .putInt(0xd503201f.toInt())
                .putInt(0xd503201f.toInt())
                .putInt(0xd503201f.toInt())
                .array()

            BlutterSearchIndex.buildArm64PoolIndex(libapp, resultDir)

            val refs = BlutterSearchIndex.xrefMany(resultDir, listOf(0x21ad0L, 0x21ad8L), 4)
                .getJSONObject("refsByOffset")
            val first = refs.getJSONArray("0x21ad0").getJSONObject(0)
            val second = refs.getJSONArray("0x21ad8").getJSONObject(0)
            assertEquals("arm64_raw_add_ldp_pp_blr", first.getString("referenceMode"))
            assertEquals("arm64_raw_add_ldp_pp_blr", second.getString("referenceMode"))
            assertEquals("0xc", first.getString("callVa"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun arm64PoolIndexSignExtendsNegativeLdpOffsets() {
        val resultDir = Files.createTempDirectory("blutter-ldp-negative-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "result.json").writeText("{}")
            val ldp = 0xa9400362.toInt() or (3 shl 10) or (0x7f shl 15)
            val libapp = ByteBuffer.allocate(32)
                .order(ByteOrder.LITTLE_ENDIAN)
                .putInt(ldp)
                .putInt(0xd503201f.toInt())
                .putInt(0xd503201f.toInt())
                .putInt(0xd503201f.toInt())
                .putInt(0xd503201f.toInt())
                .putInt(0xd503201f.toInt())
                .putInt(0xd503201f.toInt())
                .putInt(0xd503201f.toInt())
                .array()

            BlutterSearchIndex.buildArm64PoolIndex(libapp, resultDir)

            val refs = BlutterSearchIndex.xrefMany(resultDir, listOf(-8L, 0L), 4)
                .getJSONObject("refsByOffset")
            assertEquals(1, refs.getJSONArray("0x-8").length())
            assertEquals(1, refs.getJSONArray("0x0").length())
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun arm64PoolIndexScansFileInputWithoutWholeLibraryBuffer() {
        val resultDir = Files.createTempDirectory("blutter-file-xref-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "result.json").writeText("{}")
            val libapp = File(resultDir, "libapp.so")
            libapp.writeBytes(ByteBuffer.allocate(32)
                .order(ByteOrder.LITTLE_ENDIAN)
                .putInt(0x91406b69.toInt())
                .putInt(0xf945d520.toInt())
                .array())

            BlutterSearchIndex.buildArm64PoolIndex(libapp, resultDir)

            val refs = BlutterSearchIndex.xrefMany(resultDir, listOf(0x1aba8L), 4)
                .getJSONObject("refsByOffset")
                .getJSONArray("0x1aba8")
            assertEquals(1, refs.length())
            assertEquals("arm64_raw_add_ldr", refs.getJSONObject(0).getString("referenceMode"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun filePoolIndexLinksLdpPairToIndirectBlrCall() {
        val resultDir = Files.createTempDirectory("blutter-file-ldp-blr-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "result.json").writeText("{}")
            val ldp = 0xa9400362.toInt() or (3 shl 10) or ((0x1a0 / 8) shl 15)
            val libapp = File(resultDir, "libapp.so")
            libapp.writeBytes(ByteBuffer.allocate(32)
                .order(ByteOrder.LITTLE_ENDIAN)
                .putInt(ldp)
                .putInt(0xd503201f.toInt())
                .putInt(0xd63f0060.toInt())
                .array())

            BlutterSearchIndex.buildArm64PoolIndex(libapp, resultDir)

            val ref = BlutterSearchIndex.xrefMany(resultDir, listOf(0x1a8L), 4)
                .getJSONObject("refsByOffset")
                .getJSONArray("0x1a8")
                .getJSONObject(0)
            assertEquals("arm64_raw_ldp_pp_blr", ref.getString("referenceMode"))
            assertEquals("0x8", ref.getString("callVa"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun callersIncludesPoolBackedClosureBlrCalls() {
        val resultDir = Files.createTempDirectory("blutter-callers-closure-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "result.json").writeText("{}")
            File(resultDir, "pp.txt").writeText("[pp+0x1a0] Code: 0x2000")
            val ldp = 0xa9400362.toInt() or (3 shl 10) or ((0x1a0 / 8) shl 15)
            val libapp = ByteBuffer.allocate(32)
                .order(ByteOrder.LITTLE_ENDIAN)
                .putInt(ldp)
                .putInt(0xd503201f.toInt())
                .putInt(0xd63f0060.toInt())
                .array()

            BlutterSearchIndex.buildArm64PoolIndex(libapp, resultDir)

            val result = BlutterSearchIndex.callersOf(resultDir, 0x2000, 10)
            assertEquals(1, result.getInt("count"))
            assertEquals(0, result.getInt("directCallersCount"))
            assertEquals(1, result.getInt("indirectClosureCallersCount"))
            val caller = result.getJSONArray("callers").getJSONObject(0)
            assertEquals("closure_indirect", caller.getString("callType"))
            assertEquals("0x8", caller.getString("callVa"))
            assertEquals("0x1a0", caller.getString("poolOffset"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun xrefMapsPoolReferenceToLibappFileOffset() {
        val resultDir = Files.createTempDirectory("blutter-index-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "asm/main.dart").writeText(
                """
                class App {
                  bool isVip() {
                  // ** addr: 0x10120, size: 0x20
                    //     0x10124: ldr x0, [pp, #0x1aba8] // [PP+0x1aba8]
                  }
                }
                """.trimIndent(),
            )
            File(resultDir, "result.json").writeText(
                JSONObject().put("libappLoadSegments", JSONArray().put(
                    JSONObject().put("virtualAddress", "0x10000").put("fileOffset", "0x2000").put("fileSize", "0x1000"),
                )).toString(),
            )

            val result = BlutterSearchIndex.xref(resultDir, 0x1aba8, 10)
            val ref = result.getJSONArray("refs").getJSONObject(0)
            assertEquals("0x10124", ref.getString("va"))
            assertEquals("0x2124", ref.getString("fileOffset"))
            assertEquals("0x10124", ref.getString("patchLocator"))
            assertTrue(result.getString("addressMapping").startsWith("elf_load_segments:"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun searchPpAcceptsIndentedUppercasePoolEntry() {
        val resultDir = Files.createTempDirectory("blutter-index-").toFile()
        try {
            File(resultDir, "pp.txt").writeText("  [PP+0x1AbA8] String: is_vip")
            val result = BlutterSearchIndex.searchPp(resultDir, "is_vip", true, 10)
            assertTrue(result.getJSONArray("matches").length() == 1)
            assertEquals("0x1aba8", result.getJSONArray("matches").getJSONObject(0).getString("offset"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun locatePpAndXrefManyKeepOnlyTargetedEvidence() {
        val resultDir = Files.createTempDirectory("blutter-locate-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "pp.txt").writeText(
                """
                [pp+0x1ab88] String:"vipAdExempt"
                [pp+0x1aba8] String:"is_vip"
                [pp+0x1abc0] String:"splashAdEnabled"
                """.trimIndent(),
            )
            File(resultDir, "asm/main.dart").writeText(
                """
                class Account {
                  bool isVip() {
                  // ** addr: 0x10120, size: 0x20
                    0x10124: ldr x0, [pp, #0x1aba8] // [pp+0x1aba8]
                  }
                }
                """.trimIndent(),
            )

            val pp = BlutterSearchIndex.locatePp(resultDir, listOf("is_vip", "vip"), 5)
            assertEquals(1, pp.getJSONArray("candidates").length())
            val refs = BlutterSearchIndex.xrefMany(resultDir, listOf(0x1aba8), 4)
            val rows = refs.getJSONObject("refsByOffset").getJSONArray("0x1aba8")
            assertEquals("0x10124", rows.getJSONObject(0).getString("va"))
            assertEquals("bool isVip()", rows.getJSONObject(0).getString("function"))
            // fallback 走流式语义索引 (与全量扫描 asm 等价但更快); 首次调用触发
            // ensureSemanticIndex 构建并持久化索引文件。
            assertEquals("semantic_index", refs.getString("lookupMode"))
            assertTrue(File(resultDir, "blutter-semantic-v2.jsonl.gz").exists())
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun xrefManyFallsBackToArm64PoolLoadPair() {
        val resultDir = Files.createTempDirectory("blutter-add-ldr-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "asm/main.dart").writeText(
                """
                class Guard {
                  bool checkProxy() {
                  // ** addr: 0x20000, size: 0x20
                    0x20004: add x9, x27, #0x1a, lsl #12
                    0x20008: ldr x0, [x9, #0xba8]
                  }
                }
                """.trimIndent(),
            )

            val refs = BlutterSearchIndex.xrefMany(resultDir, listOf(0x1aba8), 4)
            val row = refs.getJSONObject("refsByOffset").getJSONArray("0x1aba8").getJSONObject(0)
            assertEquals("0x20008", row.getString("va"))
            assertEquals("arm64_add_ldr_fallback", row.getString("referenceMode"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun locatePpDoesNotTreatTunAsPartOfAnotherWord() {
        val resultDir = Files.createTempDirectory("blutter-short-term-").toFile()
        try {
            File(resultDir, "pp.txt").writeText(
                """
                [pp+0x10] String: "opportunity"
                [pp+0x18] String: "tun0"
                """.trimIndent(),
            )

            val result = BlutterSearchIndex.locatePp(resultDir, listOf("tun"), 5)
            assertEquals(1, result.getInt("matched"))
            assertEquals("0x18", result.getJSONArray("candidates").getJSONObject(0).getString("offset"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun locatePpMatchesChineseShortTermsInsideText() {
        val resultDir = Files.createTempDirectory("blutter-chinese-term-").toFile()
        try {
            File(resultDir, "pp.txt").writeText("[pp+0x20] String: \"去领取会员\"")

            val result = BlutterSearchIndex.locatePp(resultDir, listOf("会员"), 5)
            assertEquals(1, result.getInt("matched"))
            assertEquals("0x20", result.getJSONArray("candidates").getJSONObject(0).getString("offset"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun profilePpClassifiesTierSystemBeforeUiAndPurchaseClues() {
        val resultDir = Files.createTempDirectory("blutter-membership-profile-").toFile()
        try {
            File(resultDir, "pp.txt").writeText(
                """
                [pp+0x10] String: "vipType"
                [pp+0x18] String: "memberLevel"
                [pp+0x20] String: "至尊会员"
                [pp+0x28] String: "diamond"
                [pp+0x30] String: "vip_badge"
                [pp+0x38] String: "purchase"
                """.trimIndent(),
            )

            val profile = BlutterSearchIndex.profilePp(
                resultDir,
                blutterIntentGroups("membership"),
            )
            assertEquals("clear", profile.getString("classificationStatus"))
            assertEquals("tier_level", profile.getJSONObject("selectedSystem").getString("id"))
            assertEquals(4, profile.getJSONObject("selectedSystem").getInt("hitCount"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun profilePpRecognizesChineseAndEnglishProSystem() {
        val resultDir = Files.createTempDirectory("blutter-pro-profile-").toFile()
        try {
            File(resultDir, "pp.txt").writeText(
                """
                [pp+0x10] String: "isPro"
                [pp+0x18] String: "fullVersion"
                [pp+0x20] String: "专业版"
                [pp+0x28] String: "解锁全部"
                """.trimIndent(),
            )

            val profile = BlutterSearchIndex.profilePp(
                resultDir,
                blutterIntentGroups("membership"),
            )
            assertEquals("pro_paid_unlock", profile.getJSONObject("selectedSystem").getString("id"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun profilePpSeparatesAdDisplayTriggersFromUiContainers() {
        val resultDir = Files.createTempDirectory("blutter-ads-profile-").toFile()
        try {
            File(resultDir, "pp.txt").writeText(
                """
                [pp+0x10] String: "showInterstitialAd"
                [pp+0x18] String: "shouldShowAd"
                [pp+0x20] String: "AdContainer"
                """.trimIndent(),
            )
            val profile = BlutterSearchIndex.profilePp(resultDir, blutterIntentGroups("ads"))
            assertEquals("clear", profile.getString("classificationStatus"))
            assertEquals("ad_display_trigger", profile.getJSONObject("selectedSystem").getString("id"))
            assertFalse(blutterCluesOnlySystem("ad_display_trigger"))
            assertTrue(blutterCluesOnlySystem("ad_ui_container"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun profilePpRejectsIdentifierSubstringFalsePositives() {
        val resultDir = Files.createTempDirectory("blutter-profile-boundary-").toFile()
        try {
            File(resultDir, "pp.txt").writeText(
                """
                [pp+0x10] String: "isProxy"
                [pp+0x18] String: "isProfile"
                [pp+0x20] String: "grid_goldenratio"
                [pp+0x28] String: "Moved Permanently"
                [pp+0x30] String: "isProUser"
                [pp+0x38] String: "goldMember"
                """.trimIndent(),
            )

            val profile = BlutterSearchIndex.profilePp(
                resultDir,
                blutterIntentGroups("membership"),
            )
            val systems = profile.getJSONArray("systems")
            val pro = (0 until systems.length())
                .map(systems::getJSONObject)
                .first { it.getString("id") == "pro_paid_unlock" }
            val tier = (0 until systems.length())
                .map(systems::getJSONObject)
                .first { it.getString("id") == "tier_level" }
            assertEquals(1, pro.getInt("hitCount"))
            assertEquals(1, tier.getInt("hitCount"))
            assertTrue((0 until systems.length()).map(systems::getJSONObject)
                .none { it.getString("id") == "expiry_lifetime" })
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun locatePpExcludesPresentationOnlyMembershipHits() {
        val resultDir = Files.createTempDirectory("blutter-profile-exclusion-").toFile()
        try {
            File(resultDir, "pp.txt").writeText(
                """
                [pp+0x10] String: "vip_badge_supreme_effect"
                [pp+0x18] String: "vipType"
                [pp+0x20] String: "userLevelItems"
                """.trimIndent(),
            )

            val result = BlutterSearchIndex.locatePp(
                resultDir,
                listOf("supreme", "vipType", "userLevel"),
                5,
                listOf("vip_badge", "badgeEffect"),
            )
            assertEquals(2, result.getInt("matched"))
            val texts = result.getJSONArray("candidates")
            assertTrue((0 until texts.length()).map(texts::getJSONObject)
                .none { it.getString("text").contains("badge") })
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun ppContextResolvesAdjacentTypeToSemanticClassMethod() {
        val resultDir = Files.createTempDirectory("blutter-context-outline-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "pp.txt").writeText(
                """
                [pp+0x10] TypeArguments: <kMb>
                [pp+0x18] String: "userLevelItems"
                [pp+0x20] Closure: () => kMb from Function 'gRc': static. (0x1234)
                """.trimIndent(),
            )
            File(resultDir, "asm/dir.dart").writeText(
                """
                class kMb extends Object {
                  int dyn:get:level(kMb) {
                    // ** addr: 0x12dc108, size: 0x60
                  }
                }
                """.trimIndent(),
            )

            val context = BlutterSearchIndex.ppContexts(resultDir, listOf(0x18), 2)
            assertEquals("kMb", context.getJSONArray("symbols").getString(0))
            val outline = BlutterSearchIndex.outlineClasses(
                resultDir,
                listOf("kMb"),
                listOf("level", "type"),
                10,
            )
            val method = outline.getJSONArray("methods").getJSONObject(0)
            assertTrue(method.getBoolean("semanticMatch"))
            assertEquals("0x12dc108", method.getString("functionVa"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun disasmStopsAtNegativeSizeFunctionAndIgnoresRuntimeGuards() {
        val resultDir = Files.createTempDirectory("blutter-disasm-guard-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "asm/main.dart").writeText(
                """
                class Account {
                  int dyn:get:level(Account) {
                    // ** addr: 0x1000, size: 0x30
                    // 0x1000: CheckStackOverflow
                    // 0x1004: cmp SP, x16
                    // 0x1008: b.ls #0x1020
                    // 0x100c: r0 = BoxInt64Instr(r2)
                    // 0x1010: cmp x2, x0, asr #1
                    // 0x1014: b.eq #0x101c
                    // 0x1018: ret
                  }
                  [closure] static Account make(dynamic) {
                    // ** addr: 0x1030, size: -0x1
                  }
                }
                class Other {
                }
                """.trimIndent(),
            )

            val result = BlutterSearchIndex.disasmFunction(resultDir, 0x1000, 100)
            assertTrue(result.getBoolean("found"))
            assertEquals(0, result.getInt("businessConditionalBranchCount"))
            assertEquals(2, result.getInt("ignoredGuardBranchCount"))
            assertTrue((0 until result.getJSONArray("lines").length())
                .map(result.getJSONArray("lines")::getString)
                .none { it.contains("size: -0x1") })
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun disasmRejectsUnknownSizeHeaderWithoutInstructions() {
        val resultDir = Files.createTempDirectory("blutter-disasm-unknown-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "asm/main.dart").writeText(
                """
                class Account {
                  int tier(Account) {
                    // ** addr: 0x1000, size: -0x1
                  }
                }
                """.trimIndent(),
            )

            val result = BlutterSearchIndex.disasmFunction(resultDir, 0x1000, 100)
            assertTrue(!result.getBoolean("found"))
            assertTrue(!result.getBoolean("usable"))
            assertEquals("FUNCTION_BODY_UNAVAILABLE", result.getString("reason"))
            assertEquals("0x1000", result.getString("rawDisasmVa"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun disasmRejectsReportedFunctionWhenItsInstructionsDoNotCoverRequestedVa() {
        val resultDir = Files.createTempDirectory("blutter-disasm-mismatch-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "asm/main.dart").writeText(
                """
                class Account {
                  bool tier(Account) {
                    // ** addr: 0x1000, size: 0x40
                    // 0x1000: mov x0, #0x1
                    // 0x1004: ret
                  }
                }
                """.trimIndent(),
            )

            val result = BlutterSearchIndex.disasmFunction(resultDir, 0x1020, 100)
            assertFalse(result.getBoolean("found"))
            assertFalse(result.getBoolean("usable"))
            assertEquals("VA_NOT_IN_FUNCTION_BODY", result.getString("reason"))
            assertEquals("0x1000", result.getJSONObject("observedRange").getString("startAddr"))
            assertEquals("0x1008", result.getJSONObject("observedRange").getString("endAddr"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun disasmRejectsNearestHeaderAsAnUnverifiedBoundary() {
        val resultDir = Files.createTempDirectory("blutter-disasm-nearest-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "asm/main.dart").writeText(
                """
                class Account {
                  bool tier(Account) {
                    // ** addr: 0x1000, size: 0x8
                    // 0x1000: mov x0, #0x1
                    // 0x1004: ret
                  }
                }
                """.trimIndent(),
            )

            val result = BlutterSearchIndex.disasmFunction(resultDir, 0x1020, 100)
            assertFalse(result.getBoolean("found"))
            assertFalse(result.getBoolean("usable"))
            assertEquals("FUNCTION_BOUNDARY_UNVERIFIED", result.getString("reason"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun directCandidateRankingRejectsTierUiClosuresButKeepsRealGettersAndAdMethods() {
        assertTrue(!blutterDirectCandidateEligible(blutterDirectCandidateScore(
            "membership",
            listOf("tier_level"),
            "[closure] void render(dynamic)",
            listOf("至尊永久VIP"),
        )))
        assertTrue(!blutterDirectCandidateEligible(blutterDirectCandidateScore(
            "membership",
            listOf("tier_level"),
            "[closure] static TLb gRc(dynamic)",
            listOf("userLevel"),
        )))
        assertTrue(blutterDirectCandidateEligible(blutterDirectCandidateScore(
            "membership",
            listOf("tier_level"),
            "int dyn:get:level(kMb)",
            listOf("userLevel"),
        )))
        assertTrue(blutterDirectCandidateEligible(blutterDirectCandidateScore(
            "ads",
            listOf("ad_display_trigger"),
            "void showInterstitialAd(dynamic)",
            listOf("showInterstitialAd"),
        )))
        assertTrue(blutterDirectCandidateEligible(blutterDirectCandidateScore(
            "ads",
            listOf("ad_display_trigger"),
            "bool shouldShowAd(dynamic)",
            listOf("shouldShowAd"),
        )))
        assertFalse(blutterDirectCandidateEligible(blutterDirectCandidateScore(
            "ads",
            listOf("ad_sdk_init"),
            "void initAdSdk(dynamic)",
            listOf("initAdSdk"),
        )))
        assertTrue(blutterSourceOwnershipScore("asm/mdiary2/user.dart", setOf("mdiary2")) > 0)
        assertTrue(blutterSourceOwnershipScore("asm/dio/response.dart", setOf("mdiary2")) < 0)
    }

    @Test
    fun firstPartyRootComesFromDartToolLibraryPath() {
        val resultDir = Files.createTempDirectory("blutter-first-party-").toFile()
        try {
            File(resultDir, "libraries.jsonl").writeText(
                """{"kind":"library","name":"file:///Users/dev/project/mdiary2/.dart_tool/flutter_build/dart_plugin_registrant.dart"}""",
            )
            assertEquals(setOf("mdiary2"), BlutterSearchIndex.firstPartyAsmRoots(resultDir))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun adIntentSupportsChineseAndEnglishDisplayTerms() {
        assertEquals("ads", blutterIntentDomain("移除信息流和原生广告"))
        assertEquals("ads", blutterIntentDomain("disable native ad and advertisement"))
        assertEquals("generic", blutterIntentDomain("adjust profile padding"))
    }

    @Test
    fun verificationWindowStartsBeforeTierStringReferences() {
        val (start, size) = blutterVerificationWindow(
            0xe0b550,
            listOf(0xe0bfa8, 0xe0bfe4, 0xe0c04c, 0xe0c0b4),
        )
        assertEquals(0xe0bea8, start)
        assertTrue(0xe0bf48 in start until start + size)
        assertTrue(0xe0c0b4 in start until start + size)
    }

    @Test
    fun valueSearchFindsDecimalAndHexBusinessValuesButExcludesFieldOffsets() {
        val resultDir = Files.createTempDirectory("blutter-value-search-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "pp.txt").writeText(
                """
                [pp+0x10] Mint: 0x37
                [pp+0x18] TypeArguments: <wMb>
                """.trimIndent(),
            )
            File(resultDir, "asm/main.dart").writeText(
                """
                class wMb {
                  int dyn:get:level(wMb) {
                    // ** addr: 0x1000, size: 0x20
                    //     0x1000: mov             x2, #5
                    //     0x1004: ldur            w1, [x0, #0x37]
                  }
                }
                class Other {
                  bool check(Other) {
                    // ** addr: 0x2000, size: 0x20
                    //     0x2000: cmp             x0, #0x37
                  }
                }
                """.trimIndent(),
            )

            val result = BlutterSearchIndex.searchImmediateValues(
                resultDir,
                listOf(5, 55),
                listOf("level"),
                listOf("wMb"),
                listOf(0x18),
                10,
            )
            val candidates = result.getJSONArray("candidates")
            assertEquals("int dyn:get:level(wMb)", candidates.getJSONObject(0).getString("function"))
            assertEquals(5, candidates.getJSONObject(0).getJSONArray("values").getLong(0))
            assertEquals(55, candidates.getJSONObject(1).getJSONArray("values").getLong(0))
            assertEquals(1, result.getInt("addressingOffsetsExcluded"))
            assertEquals(55, result.getJSONArray("poolIntegerMatches").getJSONObject(0).getLong("value"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun valueSearchDecodesDartSmiAndRanksTypeAndFileContext() {
        val resultDir = Files.createTempDirectory("blutter-smi-value-search-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "pp.txt").writeText("")
            File(resultDir, "asm/blr.dart").writeText(
                """
                class :: {
                  [closure] static bool <anonymous closure>(dynamic, iKb) {
                    // ** addr: 0x3000, size: 0x20
                    //     0x3000: cmp             x0, #0xa
                  }
                }
                """.trimIndent(),
            )
            File(resultDir, "asm/other.dart").writeText(
                """
                class Other {
                  void unrelated(Other) {
                    // ** addr: 0x4000, size: 0x20
                    //     0x4000: mov             x0, #5
                  }
                }
                """.trimIndent(),
            )

            val result = BlutterSearchIndex.searchImmediateValues(
                resultDir,
                listOf(5, 3),
                listOf("blr.dart"),
                listOf("iKb"),
                emptyList(),
                10,
            )
            val first = result.getJSONArray("candidates").getJSONObject(0)
            assertEquals("0x3000", first.getString("functionVa"))
            assertEquals(5, first.getJSONArray("values").getLong(0))
            assertEquals("dart_smi", first.getJSONArray("evidence").getJSONObject(0).getString("valueEncoding"))
            assertTrue(first.getBoolean("contextClass"))
            assertEquals(listOf(5L, 10L, 3L, 6L), (0 until result.getJSONArray("searchedImmediateValues").length())
                .map { result.getJSONArray("searchedImmediateValues").getLong(it) })
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun traceFieldFlowLinksArbitraryKeyWriteToTypedReaderAndEncodedValue() {
        val resultDir = Files.createTempDirectory("blutter-field-flow-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "pp.txt").writeText("[pp+0x10] String:\"accessCode\"")
            File(resultDir, "asm/parser.dart").writeText(
                """
                class Decoder {
                  static ModelRow decode(dynamic) {
                  // ** addr: 0x1000, size: 0x40
                    // 0x1004: ldr x0, [x27, #0x10] // [pp+0x10]
                    // 0x1014: stur w0, [x2, #0x17]
                  }
                }
                """.trimIndent(),
            )
            File(resultDir, "asm/feature.dart").writeText(
                """
                class Policy {
                  static bool permits(dynamic, ModelRow) {
                  // ** addr: 0x2000, size: 0x30
                    // 0x2004: ldur w0, [x1, #0x17]
                    // 0x2008: cmp w0, #0xa
                    // 0x200c: b.eq 0x2018
                  }
                }
                """.trimIndent(),
            )
            File(resultDir, "asm/decoy.dart").writeText(
                """
                class CacheRow {
                  static void copy(dynamic) {
                  // ** addr: 0x3000, size: 0x30
                    // 0x3004: ldur w4, [x1, #0x17]
                    // 0x3008: stur w4, [x2, #0x19]
                  }
                }
                """.trimIndent(),
            )

            val meta = BlutterSearchIndex.ensureSemanticIndex(resultDir)
            assertEquals(meta.toString(), 4, meta.getInt("memoryAccesses"))
            assertEquals(meta.toString(), 2, meta.getInt("fieldSliceSinks"))
            val result = BlutterSearchIndex.traceFieldFlow(
                resultDir,
                mapOf(0x1000L to listOf(0x1004L)),
                listOf(5),
                emptyList(),
                emptyList(),
                listOf("feature.dart"),
                10,
            )

            assertTrue(result.toString(), result.has("fieldOffsets"))
            assertEquals("0x17", result.getJSONArray("fieldOffsets").getString(0))
            val consumer = result.getJSONArray("consumers").getJSONObject(0)
            assertEquals("0x2000", consumer.getString("functionVa"))
            assertTrue(consumer.getJSONArray("matchedTypes").toString().contains("ModelRow"))
            assertEquals("feature.dart", consumer.getJSONArray("matchedFiles").getString(0))
            assertEquals(1, consumer.getJSONArray("valueEvidence").length())
            assertTrue(consumer.getBoolean("hasDecisionSink"))
            assertEquals("high", consumer.getString("sliceConfidence"))
            val decision = consumer.getJSONArray("decisionEvidence")
            assertEquals("comparison", decision.getJSONObject(0).getString("kind"))
            assertEquals(10, decision.getJSONObject(0).getLong("value"))
            assertEquals("dart_smi", decision.getJSONObject(0).getString("valueEncoding"))
            assertEquals("flags_conditional_branch", decision.getJSONObject(1).getString("kind"))
            assertEquals("semantic_field_data_flow_with_register_slice", result.getString("lookupMode"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun valueParserAcceptsMixedFormsWithoutTreatingTextAsEvidence() {
        assertEquals(listOf(5L, 55L, -2L), parseBlutterValues("#5 / 0x37, -0x2 至尊"))
        assertEquals(listOf(5L, 3L), extractBlutterGoalValues("咕噜 2.1.3: 5至尊, 3钻石会员, blr.dart"))
        val evidence = BlutterSearchIndex.functionValueEvidence(listOf(
            "// 0x1000: mov x2, #5",
            "// 0x1004: cmp x2, x0, asr #1",
            "// 0x1008: ldur w1, [x0, #0x37]",
        ))
        assertEquals(1, evidence.length())
        assertEquals(5, evidence.getJSONObject(0).getLong("value"))
    }

    @Test
    fun parserAndSerializerFunctionsAreNotBusinessPatchTargets() {
        assertTrue(blutterParserLikeFunction("VipInfo _\$VipInfoFromJson(Map json)"))
        assertTrue(blutterParserLikeFunction("Map<String, dynamic> toJson()"))
        assertFalse(blutterParserLikeFunction("bool isSupremeMember(User user)"))
    }

    @Test
    fun semanticIndexIsPersistentAndUsedByXrefAndDisasm() {
        val resultDir = Files.createTempDirectory("blutter-semantic-index-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "asm/main.dart").writeText(
                """
                class Account {
                  bool dyn:get:isVip(Account) {
                    // ** addr: 0x1000, size: 0x20
                    //     0x1000: ldr x0, [x27, #0x10] // [pp+0x10] String: \"isVip\"
                    //     0x1004: mov x0, #0x5
                  }
                }
                """.trimIndent(),
            )
            val first = BlutterSearchIndex.ensureSemanticIndex(resultDir)
            val second = BlutterSearchIndex.ensureSemanticIndex(resultDir)
            assertTrue(!first.getBoolean("cacheHit"))
            assertTrue(second.getBoolean("cacheHit"))
            val compressed = File(resultDir, "blutter-semantic-v2.jsonl.gz")
            assertTrue(compressed.isFile)
            assertTrue(File(resultDir, "blutter-function-headers-v2.bin").isFile)
            assertEquals(listOf(0x1f.toByte(), 0x8b.toByte()), compressed.readBytes().take(2))

            val xref = BlutterSearchIndex.xrefMany(resultDir, listOf(0x10), 5)
            assertEquals("semantic_index", xref.getString("lookupMode"))
            assertEquals(1, xref.getJSONObject("refsByOffset").getJSONArray("0x10").length())
            val disasm = BlutterSearchIndex.disasmFunction(resultDir, 0x1004, 20)
            assertTrue(disasm.getBoolean("found"))
            assertEquals("compact_function_index", disasm.getString("lookupMode"))
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun asmSearchBatchesTermsAndAvoidsRawDirectoryScanByDefault() {
        val resultDir = Files.createTempDirectory("blutter-search-index-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "asm/main.dart").writeText(
                """
                class Account {
                  bool isAppVip() {
                    // ** addr: 0x1000, size: 0x20
                    // 0x1000: ldr x0, [x27, #0x10] // [pp+0x10] String: "VipExpired"
                    // rawOnlyMarker
                  }
                }
                """.trimIndent(),
            )
            File(resultDir, "asm/package%3Aarchive%2Fzip.dart").writeText(
                "// rawOnlyMarker from dependency",
            )
            BlutterSearchIndex.ensureSemanticIndex(resultDir)

            val batched = BlutterSearchIndex.searchAsm(
                resultDir,
                "isAppVip|VipExpired",
                caseInsensitive = true,
                limit = 20,
            )
            assertEquals("semantic_index", batched.getString("lookupMode"))
            assertEquals(2, batched.getJSONArray("queries").length())
            assertTrue(batched.getJSONArray("matches").length() >= 2)

            val indexedMiss = BlutterSearchIndex.searchAsm(
                resultDir,
                "rawOnlyMarker",
                caseInsensitive = true,
                limit = 20,
            )
            assertEquals(0, indexedMiss.getJSONArray("matches").length())
            assertEquals("semantic_index", indexedMiss.getString("lookupMode"))

            val explicitRawScan = BlutterSearchIndex.searchAsm(
                resultDir,
                "rawOnlyMarker",
                caseInsensitive = true,
                limit = 20,
                fullScan = true,
            )
            assertEquals("asm_full_scan", explicitRawScan.getString("lookupMode"))
            assertEquals(1, explicitRawScan.getJSONArray("matches").length())
            assertEquals(1, explicitRawScan.getInt("skippedFiles"))

            val dependencyScan = BlutterSearchIndex.searchAsm(
                resultDir,
                "rawOnlyMarker",
                caseInsensitive = true,
                limit = 20,
                fullScan = true,
                includeThirdParty = true,
            )
            assertEquals(2, dependencyScan.getJSONArray("matches").length())
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun asmSearchWithIncludePathSkipsGlobalSemanticIndex() {
        val resultDir = Files.createTempDirectory("blutter-path-search-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "asm/package%3Aapp%2Fmodule_base_page.dart").writeText(
                "class MinePageViewModel {\n  bool mine_page_viewmodel() => true;\n}",
            )
            File(resultDir, "asm/package%3Aapp%2Funrelated.dart").writeText(
                "class MineViewModel {}",
            )

            val result = BlutterSearchIndex.searchAsm(
                resultDir,
                "mine_page_viewmodel|MinePageViewModel|MineViewModel",
                caseInsensitive = true,
                limit = 20,
                includePaths = listOf("module_base_page"),
            )

            assertEquals("asm_path_filtered_scan", result.getString("lookupMode"))
            assertEquals(1, result.getInt("scannedFiles"))
            assertEquals(1, result.getInt("skippedFiles"))
            assertEquals(2, result.getJSONArray("matches").length())
            assertFalse(File(resultDir, "blutter-semantic-v2.jsonl.gz").exists())
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun asmSearchCachesMatchingPathQueryAndInvalidatesChangedFile() {
        val resultDir = Files.createTempDirectory("blutter-path-cache-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            val target = File(resultDir, "asm/module_base_page.dart")
            target.writeText("class MinePageViewModel {}")

            val first = BlutterSearchIndex.searchAsm(
                resultDir,
                "MinePageViewModel",
                caseInsensitive = true,
                limit = 20,
                includePaths = listOf("module_base_page"),
            )
            val second = BlutterSearchIndex.searchAsm(
                resultDir,
                "MinePageViewModel",
                caseInsensitive = true,
                limit = 20,
                includePaths = listOf("module_base_page"),
            )
            target.writeText("class MineViewModel {}")
            target.setLastModified(target.lastModified() + 2_000)
            val changed = BlutterSearchIndex.searchAsm(
                resultDir,
                "MinePageViewModel",
                caseInsensitive = true,
                limit = 20,
                includePaths = listOf("module_base_page"),
            )

            assertFalse(first.getBoolean("cacheHit"))
            assertTrue(second.getBoolean("cacheHit"))
            assertEquals(0, second.getLong("scanElapsedMs"))
            assertFalse(changed.getBoolean("cacheHit"))
            assertEquals(0, changed.getJSONArray("matches").length())
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun semanticIndexAggregatesRepeatedAddressingOffsets() {
        val resultDir = Files.createTempDirectory("blutter-semantic-addressing-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "asm/main.dart").writeText(
                buildString {
                    appendLine("class Account {")
                    appendLine("  bool isVip(Account) {")
                    appendLine("// ** addr: 0x1000, size: 0x100")
                    repeat(1000) { appendLine("// 0x${(0x1000 + it * 4).toString(16)}: ldr x0, [x1, #0x18]") }
                    appendLine("  }")
                    appendLine("}")
                },
            )

            val meta = BlutterSearchIndex.ensureSemanticIndex(resultDir)

            assertEquals(1, meta.getInt("addressingImmediateValues"))
            assertTrue(meta.getLong("indexBytes") < 4096)
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun legacySemanticIndexRemainsReadable() {
        val resultDir = Files.createTempDirectory("blutter-semantic-legacy-").toFile()
        try {
            File(resultDir, "blutter-semantic-v1.meta.json").writeText("""{"version":1,"scannedFiles":1}""")
            File(resultDir, "blutter-semantic-v1.jsonl").writeText(
                """{"type":"reference","offset":"10","va":"1004","functionVa":"1000","function":"bool isVip()","file":"asm/main.dart","insn":"ldr x0, [x27, #0x10]"}""",
            )

            val result = BlutterSearchIndex.xrefMany(resultDir, listOf(0x10), 5)

            assertEquals(1, result.getJSONObject("refsByOffset").getJSONArray("0x10").length())
            assertFalse(File(resultDir, "blutter-semantic-v2.jsonl.gz").exists())
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun disasmOffsetReturnsNextPageInsteadOfRepeatingFirstPage() {
        val resultDir = Files.createTempDirectory("blutter-disasm-page-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "asm/main.dart").writeText(
                buildString {
                    appendLine("class Account {")
                    appendLine("  bool isVip(Account) {")
                    appendLine("// ** addr: 0x1000, size: 0x100")
                    repeat(12) { appendLine("// 0x${(0x1000 + it * 4).toString(16)}: mov x0, #$it") }
                    appendLine("  }")
                    appendLine("}")
                },
            )

            val first = BlutterSearchIndex.disasmFunction(resultDir, 0x1000, 5, 0)
            val second = BlutterSearchIndex.disasmFunction(resultDir, 0x1000, 5, 5)

            assertEquals(5, first.getInt("nextOffset"))
            assertEquals(5, second.getInt("offset"))
            assertTrue(first.getJSONArray("lines").toString() != second.getJSONArray("lines").toString())
        } finally {
            resultDir.deleteRecursively()
        }
    }

    @Test
    fun semanticQueriesStreamIndexAndStayConsistent() {
        val resultDir = Files.createTempDirectory("blutter-semantic-query-stream-").toFile()
        try {
            File(resultDir, "asm").mkdirs()
            File(resultDir, "result.json").writeText("{}")
            File(resultDir, "asm/main.dart").writeText(
                """
                class Account {
                  bool dyn:get:isVip(Account) {
                    // ** addr: 0x1000, size: 0x20
                    //     0x1000: ldr x0, [x27, #0x10] // [pp+0x10] String: "isVip"
                  }
                }
                """.trimIndent(),
            )
            BlutterSearchIndex.resetQueryCacheForTest()

            val firstXref = BlutterSearchIndex.xrefMany(resultDir, listOf(0x10), 5)
            val secondXref = BlutterSearchIndex.xrefMany(resultDir, listOf(0x10), 5)
            val firstDisasm = BlutterSearchIndex.disasmFunction(resultDir, 0x1000, 20)
            val secondDisasm = BlutterSearchIndex.disasmFunction(resultDir, 0x1000, 20)

            // 流式查询不驻留语义行，同一输入重复查询结果必须一致
            assertEquals(firstXref.toString(), secondXref.toString())
            assertEquals(firstDisasm.toString(), secondDisasm.toString())
            assertEquals(1, firstXref.getJSONObject("refsByOffset").getJSONArray("0x10").length())
            assertTrue(firstDisasm.getBoolean("found"))
        } finally {
            resultDir.deleteRecursively()
            BlutterSearchIndex.resetQueryCacheForTest()
        }
    }

    @Test
    fun ppQueriesReuseCachedResultsForSameInput() {
        val resultDir = Files.createTempDirectory("blutter-pp-query-cache-").toFile()
        try {
            File(resultDir, "pp.txt").writeText("[pp+0x10] String: \"isVip\"")
            BlutterSearchIndex.resetQueryCacheForTest()

            BlutterSearchIndex.profilePp(resultDir, blutterIntentGroups("membership"))
            BlutterSearchIndex.profilePp(resultDir, blutterIntentGroups("membership"))
            BlutterSearchIndex.locatePp(resultDir, listOf("isVip"), 5)
            BlutterSearchIndex.locatePp(resultDir, listOf("isVip"), 5)

            assertEquals(1, BlutterSearchIndex.ppScanCount)
        } finally {
            resultDir.deleteRecursively()
            BlutterSearchIndex.resetQueryCacheForTest()
        }
    }

    @Test
    fun locatePipelineProfilesAndRanksWithOnePpScan() {
        val resultDir = Files.createTempDirectory("blutter-pp-pipeline-").toFile()
        try {
            File(resultDir, "pp.txt").writeText(
                """
                [pp+0x10] String: "vipType"
                [pp+0x18] String: "至尊会员"
                [pp+0x20] String: "vip_badge"
                """.trimIndent(),
            )
            BlutterSearchIndex.resetQueryCacheForTest()

            val first = BlutterSearchIndex.profileAndLocatePp(
                resultDir,
                blutterIntentGroups("membership"),
                listOf("会员"),
                blutterLocateKeywords("定位会员判断"),
                8,
                "presentation_only",
            )
            val second = BlutterSearchIndex.profileAndLocatePp(
                resultDir,
                blutterIntentGroups("membership"),
                listOf("会员"),
                blutterLocateKeywords("定位会员判断"),
                8,
                "presentation_only",
            )

            assertEquals("tier_level", first.getJSONObject("profile")
                .getJSONObject("selectedSystem").getString("id"))
            assertEquals(2, first.getJSONObject("locate").getInt("matched"))
            assertFalse(first.getBoolean("cacheHit"))
            assertTrue(second.getBoolean("cacheHit"))
            assertEquals(1, BlutterSearchIndex.ppScanCount)
        } finally {
            resultDir.deleteRecursively()
            BlutterSearchIndex.resetQueryCacheForTest()
        }
    }

    @Test
    fun largePpFileCachesAndStaysConsistentAcrossQueries() {
        val resultDir = Files.createTempDirectory("blutter-pp-cache-big-").toFile()
        try {
            // 构造 ~11MB 的 pp.txt（< PP_CACHE_MAX_BYTES 128MB），混入填充行与目标行，
            // 验证缓存路径下结果正确且跨查询复用字节缓存（searchPp 首扫读盘驻留，
            // locatePp 首扫命中 ppLinesCache 不再读盘）。
            val target = "[pp+0x10] String: \"isVip\""
            val filler = "[pp+0x2000] String: \"padding_entry_text\""
            File(resultDir, "pp.txt").outputStream().use { out ->
                out.bufferedWriter().use { writer ->
                    repeat(220_000) { index ->
                        writer.write(filler)
                        writer.write(" #")
                        writer.write(index.toString())
                        writer.newLine()
                        if (index == 110_000) {
                            writer.write(target)
                            writer.newLine()
                        }
                    }
                }
            }
            val ppLen = File(resultDir, "pp.txt").length()
            assertTrue(ppLen > 8L * 1024L * 1024L && ppLen < 128L * 1024L * 1024L)
            BlutterSearchIndex.resetQueryCacheForTest()

            val firstSearch = BlutterSearchIndex.searchPp(resultDir, "isVip", caseInsensitive = true, limit = 5)
            val secondSearch = BlutterSearchIndex.searchPp(resultDir, "isVip", caseInsensitive = true, limit = 5)
            assertEquals(1, firstSearch.getInt("count"))
            assertEquals(firstSearch.toString(), secondSearch.toString())
            assertEquals(
                "0x10",
                firstSearch.getJSONArray("matches").getJSONObject(0).getString("offset"),
            )

            val firstLocate = BlutterSearchIndex.locatePp(resultDir, listOf("isVip"), 5)
            val secondLocate = BlutterSearchIndex.locatePp(resultDir, listOf("isVip"), 5)
            assertEquals(1, firstLocate.getInt("matched"))
            assertEquals(firstLocate.toString(), secondLocate.toString())
            // 缓存路径：searchPp 首扫 1 次（读盘驻留字节缓存 + ppScanCount++），
            // 二次命中 ppSearchCache；locatePp 首扫命中 ppLinesCache 不读盘（不计数），
            // 二次命中 ppLocateCache——共 1 次真实读盘扫描
            assertEquals(1, BlutterSearchIndex.ppScanCount)
        } finally {
            resultDir.deleteRecursively()
            BlutterSearchIndex.resetQueryCacheForTest()
        }
    }

    @Test
    fun rawStringSearchFindsEnglishAndChineseWithoutBlutterOutput() {
        val bytes = "noise\u0000Pro subscription\u0000至尊会员\u0000tail".toByteArray()
        val result = BlutterSearchIndex.rawStringSearch(bytes, listOf("pro", "会员"), 10)
        assertEquals(2, result.getInt("count"))
        assertTrue(result.has("elapsedMs"))
        assertEquals(bytes.size, result.getInt("scannedBytes"))
        val terms = (0 until result.getJSONArray("matches").length()).flatMap { index ->
            val row = result.getJSONArray("matches").getJSONObject(index).getJSONArray("matchedTerms")
            (0 until row.length()).map(row::getString)
        }
        assertTrue("pro" in terms)
        assertTrue("会员" in terms)
    }

    @Test
    fun compactProfileAndReportKeepTheDecisionEvidence() {
        val systems = JSONArray().put(JSONObject()
            .put("id", "tier_level")
            .put("label", "等级体系")
            .put("hitCount", 10)
            .put("uniqueKeywordCount", 4)
            .put("evidenceScore", 300)
            .put("matchedKeywords", JSONArray(listOf("VIP", "会员", "level", "tier")))
            .put("samples", JSONArray((0 until 8).map { JSONObject().put("offset", "0x$it").put("text", "sample-$it") })))
        val profile = blutterCompactIntentProfile(JSONObject()
            .put("scannedLines", 5000)
            .put("classificationStatus", "clear")
            .put("ambiguous", false)
            .put("systems", systems))
        assertEquals("tier_level", profile.getJSONObject("selectedSystem").getString("id"))
        assertEquals(3, profile.getJSONArray("systems").getJSONObject(0).getJSONArray("samples").length())

        val report = blutterBuildAnalysisReport(JSONObject()
            .put("jobId", "blutter-test")
            .put("goal", "定位会员")
            .put("intentDomain", "membership")
            .put("classificationStatus", "clear")
            .put("intentProfile", profile)
            .put("patchCandidates", JSONArray().put(JSONObject().put("functionVa", "0xe0bf48")))
            .put("verificationWindows", JSONArray())
            .put("poolMatches", JSONArray())
            .put("clueCandidates", JSONArray())
            .put("ppSummary", JSONObject().put("matched", 10))
            .put("readyForVerification", true)
            .put("nextStep", "verify"))
        assertEquals("membership_analysis", report.getString("reportType"))
        assertEquals("candidates_need_verification", report.getString("status"))
        assertEquals("0xe0bf48", report.getJSONArray("patchCandidates").getJSONObject(0).getString("functionVa"))
    }

    @Test
    fun rawDecisionFlowJoinsTierLabelCallAndReturnValue() {
        val bytes = ByteBuffer.allocate(0x100).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(0x00, 0xa9bf79fd.toInt())
            putInt(0x04, 0x9400000f.toInt())
            putInt(0x08, 0xf100141f.toInt())
            putInt(0x0c, 0xd503201f.toInt())
            putInt(0x10, 0xd65f03c0.toInt())
            putInt(0x40, 0xa9bf79fd.toInt())
            putInt(0x44, 0xd28000a0.toInt())
            putInt(0x48, 0xd65f03c0.toInt())
            putInt(0x4c, 0xd2800080.toInt())
            putInt(0x50, 0xd65f03c0.toInt())
            putInt(0x54, 0xd2800060.toInt())
            putInt(0x58, 0xd65f03c0.toInt())
        }.array()
        val windows = JSONArray().put(JSONObject()
            .put("verificationVa", "0x0")
            .put("maxBytes", 0x80))
        val refs = JSONObject().put("0x10", JSONArray().put(JSONObject()
            .put("va", "0xc")
            .put("functionVa", "0x0")))

        val result = BlutterSearchIndex.rawDecisionFlow(
            bytes,
            windows,
            refs,
            mapOf("0x10" to "至尊会员"),
            listOf(5),
        )

        assertEquals("decision_flow_found", result.getString("status"))
        val candidate = result.getJSONArray("candidates").getJSONObject(0)
        assertEquals("0x40", candidate.getString("functionVa"))
        assertEquals("high", candidate.getString("confidence"))
        assertEquals(5, candidate.getJSONArray("targetMappings").getJSONObject(0).getLong("value"))
        assertEquals("至尊会员", candidate.getJSONArray("targetMappings").getJSONObject(0)
            .getJSONArray("labels").getString(0))
        assertEquals("native", candidate.getJSONObject("patchHint").getString("valueEncoding"))
    }

}
