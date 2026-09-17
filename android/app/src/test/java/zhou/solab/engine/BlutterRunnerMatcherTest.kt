package zhou.solab.engine

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BlutterRunnerMatcherTest {
    private val runner = BlutterRunnerDescriptor(
        runnerId = "dart-3.12",
        dartVersion = "3.12",
        engineRevision = "engine-exact",
        abi = "arm64-v8a",
        compressedPointers = false,
        analysis = true,
        sha256 = "a".repeat(64),
        source = "fixture",
        libraryName = "blutter_3_12",
        snapshotAliases = listOf("snapshot-exact"),
        backend = "exec",
    )

    @Test
    fun exactSnapshotIsVerified() {
        val selected = BlutterRunnerMatcher.selectWithEvidence(
            BlutterRunnerRequirement(null, "3.12.2", "snapshot-exact", "arm64-v8a", true, true),
            listOf(runner),
        )!!
        assertEquals("exact_snapshot", selected.strategy)
        assertTrue(selected.verified)
    }

    @Test
    fun minorFallbackIsExplicitlyUnverified() {
        val selected = BlutterRunnerMatcher.selectWithEvidence(
            BlutterRunnerRequirement(null, "3.12.2", "unknown", "arm64-v8a", false, true),
            listOf(runner.copy(engineRevision = null, snapshotAliases = emptyList())),
        )!!
        assertEquals("dart_minor_fallback", selected.strategy)
        assertFalse(selected.verified)
    }

    @Test
    fun capabilitiesAreCompactByDefaultAndCoverageIsPagedOnDemand() {
        val manifest = JSONObject()
            .put("schemaVersion", 2)
            .put("matrixVersion", "test")
            .put("coverage", JSONArray()
                .put(JSONObject().put("status", "supported").put("supported", true).put("flutterVersion", "3.22.0"))
                .put(JSONObject().put("status", "source_resolvable").put("supported", false).put("flutterVersion", "3.19.0")))
        val integrity = mapOf(runner.runnerId to BlutterRunnerIntegrity("ready", 1234))

        val compact = BlutterCapabilityFormatter.format(manifest, listOf(runner), integrity)
        assertFalse(compact.has("coverage"))
        assertEquals(2, compact.getJSONObject("summary").getInt("coverageTotal"))
        assertEquals("ready", compact.getJSONArray("runners").getJSONObject(0).getString("integrityStatus"))

        val paged = BlutterCapabilityFormatter.format(
            manifest,
            listOf(runner),
            integrity,
            JSONObject().put("fullInventory", true).put("offset", 1).put("limit", 1),
        ).getJSONObject("coverage")
        assertEquals(1, paged.getJSONArray("items").length())
        assertEquals(1, paged.getInt("offset"))
        assertFalse(paged.getBoolean("hasMore"))
    }
}
