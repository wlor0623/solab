package zhou.solab.tools

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class SolabDexKitToolTest {

    @Test
    fun parsesBoundedDistinctMultiStringQuery() {
        assertEquals(
            listOf("token", "signature", "endpoint"),
            SolabDexKitTool.parseKeywords("token|signature\nendpoint|token"),
        )
    }

    @Test
    fun canonicalMethodQidAppendsSignatureDescriptor() {
        assertEquals(
            "Lp4/a;->j(LH4/l;LQ1/a;)V",
            SolabDexKitTool.canonicalMethodQid("p4.a", "j", "(LH4/l;LQ1/a;)V"),
        )
    }

    @Test
    fun canonicalMethodQidPreservesFullDescriptor() {
        assertEquals(
            "Lp4/a;->j(LH4/l;LQ1/a;)V",
            SolabDexKitTool.canonicalMethodQid(
                "p4.a",
                "j",
                "Lp4/a;->j(LH4/l;LQ1/a;)V",
            ),
        )
    }

    @Test
    fun parsesBoundedMixedNumericFeatures() {
        val parsed = SolabDexKitTool.parseNumbers(JSONObject()
            .put("numbers", JSONArray().put(5).put("0x37").put(-2).put(3.5).put(5)))

        assertEquals(listOf<Number>(5, 55L, -2, 3.5), parsed)
    }

    @Test
    fun parsesDistinctCodeAndSymbolTerms() {
        assertEquals(
            listOf("fieldA", "fieldB", "if-eq"),
            SolabDexKitTool.parseFeatureTerms("fieldA|fieldB,if-eq|fieldA"),
        )
    }

    @Test
    fun ranksIndependentDimensionsBeforeRepeatedSameKindEvidence() {
        assertEquals(201, SolabDexKitTool.autoCandidateScore(2, 1))
        assertEquals(103, SolabDexKitTool.autoCandidateScore(1, 3))
    }
}
