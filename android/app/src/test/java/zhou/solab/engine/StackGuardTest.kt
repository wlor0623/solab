package zhou.solab.engine

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class StackGuardTest {
    @Test
    fun dartAotBoolUsesNullRelativeObjects() {
        val trueStub = StackGuard.forceReturnConstant("arm64", "bool", 1, valueEncoding = "dart_aot")
        val falseStub = StackGuard.forceReturnConstant("arm64", "bool", 0, valueEncoding = "dart_aot")

        assertArrayEquals(hex("c0820091c0035fd6"), trueStub)
        assertArrayEquals(hex("c0c20091c0035fd6"), falseStub)
    }

    @Test
    fun dartAotNullAndSmiUseDartEncoding() {
        val nullStub = StackGuard.forceReturnConstant("arm64", "null", 0, valueEncoding = "dart_aot")
        val smiStub = StackGuard.forceReturnConstant("arm64", "int", 1, valueEncoding = "dart_aot")

        assertArrayEquals(hex("c0020091c0035fd6"), nullStub)
        assertArrayEquals(hex("40008052c0035fd6"), smiStub)
    }

    @Test
    fun dartAotStringIsRejected() {
        val error = runCatching {
            StackGuard.forceReturnConstant("arm64", "string", 0, valueEncoding = "dart_aot")
        }.exceptionOrNull()

        assertTrue(error is IllegalArgumentException)
    }

    private fun hex(value: String): ByteArray = value.chunked(2)
        .map { it.toInt(16).toByte() }
        .toByteArray()
}
