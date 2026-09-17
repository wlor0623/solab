package zhou.solab.tools

import android.content.Context
import com.android.tools.smali.dexlib2.iface.ClassDef
import com.android.tools.smali.dexlib2.iface.Method
import com.android.tools.smali.dexlib2.iface.instruction.Instruction
import com.android.tools.smali.dexlib2.iface.instruction.NarrowLiteralInstruction
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction
import com.android.tools.smali.dexlib2.iface.instruction.WideLiteralInstruction
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * M2: smaliRead（自研，替代 mt_apk_read_text）。
 *
 * 按 qualifiedId（Lpkg/Class;->name 或带签名）输出方法 smali 文本
 * （.method 头 + 指令 + .end method），多 dex 命中按 dex 分组。
 * 这是 AGENTS R4 的新验收基准格式。
 */
object SmaliReadTool {

    private const val MAX_APK_BYTES = 512L * 1024 * 1024

    private fun qidOf(m: Method): String =
        "${m.definingClass}->${m.name}(${m.parameterTypes.joinToString("")})${m.returnType}"

    /// 可读指令格式化：opcode + 引用/字面量 + 代码偏移。
    /// dexlib2 的 DexBackedInstruction 未重写 toString（输出对象引用串），
    /// 这里手写轻量 formatter——寄存器编号对逻辑分析非必需，关键是
    /// 指令名 + 调用目标（method/field/string 引用）+ 常量。
    private fun formatInsn(insn: Instruction, codeOffset: Int): String {
        val sb = StringBuilder(insn.opcode.name)
        when (insn) {
            is ReferenceInstruction -> sb.append(' ').append(insn.reference)
            is NarrowLiteralInstruction -> sb.append(" #").append(insn.narrowLiteral)
            is WideLiteralInstruction -> sb.append(" #").append(insn.wideLiteral).append('L')
            else -> {}
        }
        sb.append("  # +").append(codeOffset).append('x')
        return sb.toString()
    }

    internal fun accessModifiers(flags: Int): String {
        val sb = StringBuilder()
        if (flags and 0x1 != 0) sb.append("public ")
        if (flags and 0x2 != 0) sb.append("private ")
        if (flags and 0x4 != 0) sb.append("protected ")
        if (flags and 0x8 != 0) sb.append("static ")
        if (flags and 0x10 != 0) sb.append("final ")
        if (flags and 0x20 != 0) sb.append("synchronized ")
        if (flags and 0x40 != 0) sb.append("bridge ")
        if (flags and 0x100 != 0) sb.append("native ")
        if (flags and 0x200 != 0) sb.append("interface ")
        if (flags and 0x400 != 0) sb.append("abstract ")
        if (flags and 0x800 != 0) sb.append("strictfp ")
        if (flags and 0x1000 != 0) sb.append("synthetic ")
        if (flags and 0x2000 != 0) sb.append("annotation ")
        if (flags and 0x4000 != 0) sb.append("enum ")
        if (flags and 0x8000 != 0) sb.append("constructor ")
        return sb.toString().trimEnd()
    }

    fun smali(context: Context, apkPath: String, qualifiedId: String): JSONObject {
        val apk = File(apkPath)
        if (!apk.isFile) return err("FILE_NOT_FOUND", "APK 不存在: $apkPath", "apkPath", apkPath)
        if (apk.length() > MAX_APK_BYTES) return err("APK_LIMIT_EXCEEDED", "APK 超过 512MiB 上限", "apkPath", apkPath)
        val target = qualifiedId.trim()
        if (target.isBlank()) return err("INVALID_ARGUMENT", "缺少 qualifiedId", "qualifiedId", "")

        val wantSignature = target.contains('(')

        fun hit(qid: String): Boolean =
            if (wantSignature) qid == target
            else qid.startsWith(target) && qid.getOrNull(target.length) == '('

        return runCatching {
            val matches = JSONArray()
            var total = 0

            DexIo.eachDex(context, apk) { dexName, dexFile ->
                for (cls: ClassDef in dexFile.classes) {
                    for (m: Method in cls.methods) {
                        if (!hit(qidOf(m))) continue
                        total++
                        val sb = StringBuilder()
                        sb.append(".method ")
                            .append(accessModifiers(m.accessFlags))
                            .append(' ')
                            .append(m.name)
                            .append('(')
                            .append(m.parameterTypes.joinToString(""))
                            .append(')')
                            .append(m.returnType)
                            .append('\n')
                        val impl = m.implementation
                        if (impl != null) {
                            var insnCount = 0
                            var codeOffset = 0
                            for (insn in impl.instructions) {
                                sb.append("    ")
                                    .append(formatInsn(insn, codeOffset))
                                    .append('\n')
                                codeOffset += insn.codeUnits * 2
                                insnCount++
                            }
                            sb.append("    # registers: ").append(impl.registerCount)
                                .append(", instructions: ").append(insnCount)
                                .append('\n')
                        } else {
                            sb.append("    # abstract or native (no implementation)\n")
                        }
                        sb.append(".end method")
                        matches.put(JSONObject()
                            .put("dexFile", dexName)
                            .put("qualifiedId", qidOf(m))
                            .put("smali", sb.toString()))
                    }
                }
                System.gc()
            }

            if (total == 0) {
                return@runCatching err(
                    "METHOD_NOT_FOUND", "未在 DEX 中找到方法: $target（可先用 dex_search 或 class_outline 拿真实 qualifiedId）",
                    "qualifiedId", qualifiedId,
                )
            }

            ok(JSONObject()
                .put("tool", "smali_read")
                .put("qualifiedId", target)
                .put("matches", matches)
                .put("totalMatches", total)
                .put("hint", "smali 为方法级视图; 需要完整类成员时使用 class_outline"))
        }.getOrElse { e ->
            err("BAKSMALI_FAILED", "smali 读取失败: ${e.message ?: e.javaClass.simpleName}", "apkPath", apkPath)
        }
    }
}
