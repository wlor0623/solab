package zhou.solab

import org.jf.dexlib2.AccessFlags
import org.jf.dexlib2.DexFileFactory
import org.jf.dexlib2.Opcode
import org.jf.dexlib2.Opcodes
import org.jf.dexlib2.iface.instruction.NarrowLiteralInstruction
import org.jf.dexlib2.immutable.ImmutableClassDef
import org.jf.dexlib2.immutable.ImmutableDexFile
import org.jf.dexlib2.immutable.ImmutableMethod
import org.jf.dexlib2.immutable.ImmutableMethodImplementation
import org.jf.dexlib2.immutable.ImmutableMethodParameter
import org.jf.dexlib2.immutable.instruction.ImmutableInstruction10x
import org.jf.dexlib2.immutable.instruction.ImmutableInstruction31i
import org.jf.dexlib2.immutable.instruction.ImmutableInstruction35c
import org.jf.dexlib2.immutable.reference.ImmutableMethodReference
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * FLAG_SECURE 剥离的硬证据测试：真实构建 DEX → patch → 重读验证。
 * 场景：addFlags(FLAG_SECURE|FLAG_FULLSCREEN=0x2008)——
 * 补丁必须只清 FLAG_SECURE 位（0x2008 → 0x0008），不能误伤同常量的其他位。
 */
class ApkDexPatcherFlagSecureTest {

    private fun buildDexWithAddFlags(constValue: Int, methodName: String): File {
        val insns = listOf(
            ImmutableInstruction31i(Opcode.CONST, 0, constValue),
            ImmutableInstruction35c(
                Opcode.INVOKE_VIRTUAL,
                2, 1, 0, 0, 0, 0,
                ImmutableMethodReference(
                    "Landroid/view/Window;",
                    "addFlags",
                    listOf("I"),
                    "Landroid/view/Window;",
                ),
            ),
            ImmutableInstruction10x(Opcode.RETURN_VOID),
        )
        val method = ImmutableMethod(
            "Lcom/x/MainActivity;",
            methodName,
            listOf(
                ImmutableMethodParameter(
                    "Landroid/view/Window;",
                    emptySet<org.jf.dexlib2.iface.Annotation>(),
                    "p0",
                ),
            ),
            "V",
            AccessFlags.PUBLIC.value,
            emptySet<org.jf.dexlib2.iface.Annotation>(),
            emptySet<org.jf.dexlib2.HiddenApiRestriction>(),
            ImmutableMethodImplementation(2, insns, emptyList(), emptyList()),
        )
        val classDef = ImmutableClassDef(
            "Lcom/x/MainActivity;",
            AccessFlags.PUBLIC.value,
            "Ljava/lang/Object;",
            emptyList(),
            null,
            emptySet(),
            emptyList(),
            listOf(method),
        )
        val root = Files.createTempDirectory("flagsecure").toFile()
        val out = File(root, "classes.dex")
        DexFileFactory.writeDexFile(out.absolutePath, ImmutableDexFile(Opcodes.getDefault(), listOf(classDef)))
        return out
    }

    private fun readConstValue(dexFile: File): Int {
        val dex = DexFileFactory.loadDexFile(dexFile, Opcodes.getDefault())
        val impl = dex.classes.first().methods.first().implementation!!
        val const = impl.instructions.first() as NarrowLiteralInstruction
        return const.narrowLiteral
    }

    @Test
    fun stripClearsOnlyFlagSecureBit() {
        val root = buildDexWithAddFlags(0x2008, "setupWindow")
        try {
            val result = ApkDexPatcher.patch(
                dexFile = root,
                voidMethodNames = emptySet(),
                trueMethodNames = emptySet(),
                falseMethodNames = emptySet(),
                removeFlagSecure = true,
            )
            assertEquals(1, result.flagSecureCleared)
            // FLAG_SECURE 位被清除，FLAG_FULLSCREEN(0x8) 位保留
            assertEquals(0x8, readConstValue(root))
        } finally {
            root.parentFile.deleteRecursively()
        }
    }

    @Test
    fun stripSkipsMethodsWithoutFlagSecureBit() {
        val root = buildDexWithAddFlags(0x8, "setupWindowFullscreenOnly")
        try {
            val result = ApkDexPatcher.patch(
                dexFile = root,
                voidMethodNames = emptySet(),
                trueMethodNames = emptySet(),
                falseMethodNames = emptySet(),
                removeFlagSecure = true,
            )
            assertEquals(0, result.flagSecureCleared)
            assertEquals(0x8, readConstValue(root))
        } finally {
            root.parentFile.deleteRecursively()
        }
    }

    @Test
    fun previewTargetsReportOnlyAffectedMethods() {
        val root = buildDexWithAddFlags(0x2008, "setupWindow")
        try {
            val dex = DexFileFactory.loadDexFile(root, Opcodes.getDefault())
            val targets = ApkDexPatcher.flagSecurePreviewTargets(dex)
            assertTrue(targets.contains("Lcom/x/MainActivity;->setupWindow"))
        } finally {
            root.parentFile.deleteRecursively()
        }
    }
}
