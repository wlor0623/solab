package zhou.solab.engine

import org.junit.Assert.assertEquals
import org.junit.Test

class EngineRuntimeReadTest {
    @Test
    fun rawExecutableWindowIgnoresIncorrectAnalysisFunctionSize() {
        val elf = ElfFile(
            data = ByteArray(0x3000),
            bits = 64,
            littleEndian = true,
            type = 3,
            machine = 183,
            entry = 0x1000,
            sections = listOf(SectionInfo(".text", 1, 4, 0x1000, 0x100, 0x2000, 0, 0, 4, 0)),
            symbols = emptyList(),
            dynSymbols = emptyList(),
            relocations = emptyList(),
            strings = emptyList(),
        )

        assertEquals(0x1ff0, rawExecutableWindowSize(elf, 0x1010, 0x110, elf.data.size))
    }

    @Test
    fun disasmVaEndCapsTheWindowWithoutChangingTheRequestedStart() {
        assertEquals(0x120, disasmVaWindowBytes(0x8ee1c0, 0x1000, 0x8ee2e0))
        assertEquals(0x1000, disasmVaWindowBytes(0x8ee1c0, 0x1000, 0))
    }

    @Test
    fun coveredBytesUsesInstructionCountWhenOnlyFirstLineHasAddress() {
        val lines = buildList {
            add("0xe0f34c: stp x29, x30, [sp, #-0x10]!")
            repeat(99) { add("nop") }
        }

        assertEquals(400, disasmCoveredBytes(lines, 0xe0f34c, "arm64", false, 2048))
    }

    @Test
    fun coveredBytesUsesAddressSpanWhenEveryLineHasAddress() {
        val lines = listOf(
            "0xe0f34c: stp x29, x30, [sp, #-0x10]!",
            "0xe0f350: mov x29, sp",
            "0xe0f354: ret",
        )

        assertEquals(12, disasmCoveredBytes(lines, 0xe0f34c, "arm64", false, 2048))
    }

    @Test
    fun coveredBytesDoesNotExceedWindow() {
        val lines = List(100) { "nop" }

        assertEquals(136, disasmCoveredBytes(lines, 0xe0f34c, "arm64", false, 136))
    }
}
