package zhou.solab

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream

class ApkAhoCorasickTest {
    @Test
    fun keepsStateAcrossBlocksAndReturnsSuffixPatterns() {
        val prefix = ByteArray(1024 * 1024 - 2) { 'x'.code.toByte() }
        val input = prefix + "IsVip至尊".toByteArray()

        val hits = ApkAhoCorasick(listOf("isvip", "vip", "至尊"))
            .scanStream(ByteArrayInputStream(input))

        assertEquals(setOf("isvip", "vip", "至尊"), hits)
    }

    @Test
    fun emptyPatternSetIsSafe() {
        val hits = ApkAhoCorasick(emptyList())
            .scanStream(ByteArrayInputStream("vip".toByteArray()))

        assertTrue(hits.isEmpty())
    }

    @Test
    fun matchesUppercaseDexDescriptorCaseInsensitively() {
        val descriptor = "Lmark/via/BrowserApp;"

        val hits = ApkAhoCorasick(listOf(descriptor))
            .scanStream(ByteArrayInputStream(descriptor.toByteArray()))

        assertEquals(setOf(descriptor), hits)
    }
}
