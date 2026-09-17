package zhou.solab.tools

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class KotlinToolStatsTest {
    @Before
    fun setUp() = KotlinToolStats.reset()

    @After
    fun tearDown() = KotlinToolStats.reset()

    @Test
    fun snapshotAggregatesCallsInsteadOfCountingToolNames() {
        KotlinToolStats.record("first", true, 1_000)
        KotlinToolStats.record("first", false, 2_000, "failed")
        KotlinToolStats.record("second", true, 3_000)

        val snapshot = KotlinToolStats.snapshot()
        assertEquals(2, snapshot.getInt("distinctTools"))
        assertEquals(3, snapshot.getInt("totalCalls"))
        assertEquals(2, snapshot.getInt("totalOk"))
        assertEquals(1, snapshot.getInt("totalFailed"))
    }

    @Test
    fun snapshotRanksToolsByRollingP95() {
        KotlinToolStats.record("mostly-fast", true, 1_000)
        KotlinToolStats.record("mostly-fast", true, 2_000)
        KotlinToolStats.record("mostly-fast", true, 100_000)
        KotlinToolStats.record("steady", true, 50_000)

        val snapshot = KotlinToolStats.snapshot()
        val slowest = snapshot.getJSONArray("slowestTools")
        val first = slowest.getJSONObject(0)

        assertEquals("mostly-fast", first.getString("tool"))
        assertEquals(100, first.getLong("p95Ms"))
        assertEquals(3, first.getInt("sampleCount"))
        assertTrue(first.getLong("p50Ms") <= first.getLong("p95Ms"))
    }
}
