package zhou.solab.engine

import org.json.JSONObject

/**
 * P0 栈帧平衡守卫（问题复盘 2026-08-18）：
 * 拦截「删除函数 prologue（stp fp,lr / sub sp）却保留 epilogue（ldp fp,lr / add sp / mov reg,fp）」
 * 这类会破坏调用者栈帧、导致运行时闪退的补丁。
 *
 * 同时提供 [forceReturnConstant] 无栈最小桩生成器（恒返回常量只写 mov+ret，绝不碰 fp/sp），
 * 以及 Flutter AOT 快照检测（提示模型使用无栈最小桩）。
 *
 * ARM64 编码参考（小端字节序，以下用大端 word 表示）：
 * - stp x29,x30,[sp,#-16]!  = 0xA9BF7BFD（prologue push）
 * - ldp x29,x30,[sp],#16    = 0xA8C17BFD（epilogue pop, post-index）
 * - ldp x29,x30,[sp,#16]    = 0xA9577BFD（epilogue pop, signed-offset）
 * - mov w0,#5               = 0x528000A0（movz）
 * - ret                     = 0xD65F03C0
 * - mov x0,xzr              = 0xAA1F03E0
 * Flutter AOT 使用 x15 作为 frame pointer，同时识别 x29/x15。
 */
internal object StackGuard {

    private const val FP_STANDARD = 29 // x29 标准 frame pointer
    private const val FP_DART = 15     // x15 Dart/Flutter AOT frame pointer
    private const val LR = 30          // x30 link register

    /** 校验结论。 */
    data class Verdict(
        val ok: Boolean,
        val code: String,
        val message: String,
        val details: JSONObject = JSONObject(),
    )

    private val OK = Verdict(true, "STACK_OK", "")

    private fun u32(b: ByteArray, i: Int): Long {
        if (i + 4 > b.size) return -1L
        return ((b[i].toLong() and 0xff) or
            ((b[i + 1].toLong() and 0xff) shl 8) or
            ((b[i + 2].toLong() and 0xff) shl 16) or
            ((b[i + 3].toLong() and 0xff) shl 24)) and 0xffffffffL
    }

    private fun u16(b: ByteArray, i: Int): Int {
        if (i + 2 > b.size) return -1
        return ((b[i].toInt() and 0xff) or ((b[i + 1].toInt() and 0xff) shl 8))
    }

    // —— ARM64 指令分类 ——

    private fun isPairFpLr(word: Long): Boolean {
        val rt = (word and 0x1F).toInt()
        val rt2 = ((word shr 10) and 0x1F).toInt()
        val fpSet = intArrayOf(FP_STANDARD, FP_DART)
        return (rt == LR && rt2 in fpSet) || (rt in fpSet && rt2 == LR)
    }

    private fun stpFpLr(bytes: ByteArray): Boolean {
        var i = 0
        while (i + 4 <= bytes.size) {
            val w = u32(bytes, i)
            if (w >= 0) {
                val preIndex = (w and 0xFFC00000u.toLong()) == 0xA9800000u.toLong()
                val signedOff = (w and 0xFFC00000u.toLong()) == 0xA9100000u.toLong()
                if ((preIndex || signedOff) && isPairFpLr(w)) return true
            }
            i += 4
        }
        return false
    }

    private fun ldpFpLr(bytes: ByteArray): Boolean {
        var i = 0
        while (i + 4 <= bytes.size) {
            val w = u32(bytes, i)
            if (w >= 0) {
                val postIndex = (w and 0xFFC00000u.toLong()) == 0xA8C00000u.toLong()
                val signedOff = (w and 0xFFC00000u.toLong()) == 0xA9400000u.toLong()
                if ((postIndex || signedOff) && isPairFpLr(w)) return true
            }
            i += 4
        }
        return false
    }

    private fun hasSubSp(bytes: ByteArray): Boolean {
        var i = 0
        while (i + 4 <= bytes.size) {
            val w = u32(bytes, i)
            // SUB SP, SP, #imm ：mask 覆盖 imm12 与 Rd/Rn=SP
            if (w >= 0 && (w and 0xFFC003FFu.toLong()) == 0xD10003FFu.toLong()) return true
            i += 4
        }
        return false
    }

    private fun hasAddSp(bytes: ByteArray): Boolean {
        var i = 0
        while (i + 4 <= bytes.size) {
            val w = u32(bytes, i)
            // ADD SP, SP, #imm
            if (w >= 0 && (w and 0xFFC003FFu.toLong()) == 0x910003FFu.toLong()) return true
            i += 4
        }
        return false
    }

    private fun hasMovRegFp(bytes: ByteArray): Boolean {
        var i = 0
        while (i + 4 <= bytes.size) {
            val w = u32(bytes, i)
            if (w >= 0) {
                // ADD Rd, Xn(fp), #0 == mov Rd, fp；imm12=0，Rn ∈ {x29, x15}
                val masked = w and 0xFFC003E0u.toLong()
                if (masked == 0x910003A0u.toLong() || masked == 0x910001E0u.toLong()) return true
            }
            i += 4
        }
        return false
    }

    private fun hasRet(bytes: ByteArray): Boolean {
        var i = 0
        while (i + 4 <= bytes.size) {
            val w = u32(bytes, i)
            if (w >= 0) {
                if (w == 0xD65F03C0u.toLong()) return true            // ret
                if ((w and 0xFFFFFC1Fu.toLong()) == 0xD61F03C0u.toLong()) return true // br x30
                if (w == 0xD65F0FFFu.toLong() || w == 0xD65F0BFFu.toLong()) return true // retaa/retab
            }
            i += 4
        }
        return false
    }

    /**
     * 栈帧平衡校验：仅 arm64 深检，其余架构直接放行。
     *
     * @param oldBytes 被覆盖前的原始字节（含原 prologue 时才能判定）
     * @param newBytes 补丁新字节
     */
    fun check(oldBytes: ByteArray, newBytes: ByteArray, architecture: String): Verdict {
        if (architecture != "arm64") return OK
        val oldPrologue = stpFpLr(oldBytes) || hasSubSp(oldBytes)
        if (!oldPrologue) return OK // 原字节无 prologue 可判，放行
        val newPrologue = stpFpLr(newBytes) || hasSubSp(newBytes)
        if (newPrologue) return OK // 新字节保留/重建了 prologue，平衡
        val newEpilogue = ldpFpLr(newBytes) || hasAddSp(newBytes) || hasMovRegFp(newBytes)
        if (!newEpilogue) return OK // 无 epilogue 操作，未触碰栈帧
        return Verdict(
            ok = false,
            code = "STACK_IMBALANCE",
            message = "补丁删除了函数 prologue（stp fp,lr / sub sp）却保留了 epilogue（ldp fp,lr / add sp / mov reg,fp）。" +
                "弹栈会读到并覆写调用者保存的 fp/lr，栈指针被错误前移，运行时必然闪退。" +
                "修复：恒返回常量请改用无栈最小桩（如 mode=force_return_constant，生成 mov w0,#N; ret，8 字节）；" +
                "确需自定义时保留 prologue/epilogue 配对。确信无误可对单条 edit 设置 overrideStackCheck=true 跳过本检查。",
            details = JSONObject()
                .put("oldPrologue", true)
                .put("newPrologue", false)
                .put("newEpilogue", true)
                .put("arch", architecture),
        )
    }

    // —— force_return_constant 无栈最小桩 ——

    /**
     * 恒返回常量安全桩。只写寄存器与 ret，不触碰 fp/sp，天然栈安全。
     *
     * @param returnType int/bool/enum → movz w0,#v; ret（值 >0xFFFF 自动扩 movz+movk 12 字节桩，
     * 上限 32 位）；object/null/reference → mov x0,xzr; ret
     * @return 补丁字节（arm64 8/12 字节 / thumb 4 字节 / arm32 8 字节）
     */
    fun forceReturnConstant(
        architecture: String,
        returnType: String,
        value: Long,
        thumb: Boolean = false,
        valueEncoding: String = "native",
    ): ByteArray {
        val type = returnType.lowercase()
        if (valueEncoding.lowercase() == "dart_aot") {
            if (architecture != "arm64") {
                throw IllegalArgumentException("Dart AOT 常量编码目前仅支持 arm64，当前 architecture=$architecture")
            }
            return when (type) {
                "bool" -> dartAotObjectFromNull(if (value == 0L) 0x30 else 0x20)
                "null", "object", "reference" -> dartAotObjectFromNull(0)
                "string" -> throw IllegalArgumentException("Dart AOT 字符串不能由立即数安全构造；请返回已定位的池对象，不能使用 force_return_constant")
                "int", "enum" -> {
                    if (value < 0 || value > 0x7FFFFFFFL) {
                        throw IllegalArgumentException("Dart AOT Smi 仅支持 0..2147483647，当前 value=$value")
                    }
                    forceReturnConstant(architecture, "int", value shl 1, thumb, "native")
                }
                else -> throw IllegalArgumentException("Dart AOT returnType 仅支持 int|enum|bool|null|object|reference|string，当前 returnType=$returnType")
            }
        }
        if (valueEncoding.lowercase() !in setOf("native", "auto", "")) {
            throw IllegalArgumentException("valueEncoding 仅支持 auto|native|dart_aot，当前 valueEncoding=$valueEncoding")
        }
        return when (architecture) {
            "arm64" -> {
                if (type in setOf("object", "null", "reference", "string")) {
                    // mov x0, xzr ; ret
                    byteArrayOf(
                        0xE0.toByte(), 0x03, 0x1F, 0xAA.toByte(),
                        0xC0.toByte(), 0x03, 0x5F, 0xD6.toByte(),
                    )
                } else {
                    if (value < 0 || value > 0xFFFFFFFFL) {
                        throw IllegalArgumentException(
                            "arm64 安全桩仅支持 0..4294967295（movz / movz+movk），当前 value=$value。" +
                                "64 位或更大值需字面量池方案：改用 edit_asm writeAsm 手写（如 ldr x0, =#imm）")
                    }
                    if (value <= 0xFFFF) {
                        // movz w0, #imm16 ; ret
                        val movz = 0x52800000u.toLong() or (value shl 5)
                        byteArrayOf(
                            (movz and 0xff).toByte(), ((movz shr 8) and 0xff).toByte(),
                            ((movz shr 16) and 0xff).toByte(), ((movz shr 24) and 0xff).toByte(),
                            0xC0.toByte(), 0x03, 0x5F, 0xD6.toByte(), // ret
                        )
                    } else {
                        // movz w0, #low16 ; movk w0, #high16, lsl #16 ; ret（12 字节，仍无栈操作）
                        val movz = 0x52800000u.toLong() or (value and 0xFFFF shl 5)
                        val movk = 0x72A00000u.toLong() or ((value shr 16) and 0xFFFF shl 5)
                        byteArrayOf(
                            (movz and 0xff).toByte(), ((movz shr 8) and 0xff).toByte(),
                            ((movz shr 16) and 0xff).toByte(), ((movz shr 24) and 0xff).toByte(),
                            (movk and 0xff).toByte(), ((movk shr 8) and 0xff).toByte(),
                            ((movk shr 16) and 0xff).toByte(), ((movk shr 24) and 0xff).toByte(),
                            0xC0.toByte(), 0x03, 0x5F, 0xD6.toByte(), // ret
                        )
                    }
                }
            }
            "arm32" -> {
                if (value < 0 || value > 0xFF) {
                    throw IllegalArgumentException("arm32 立即数只支持 0..255，当前 value=$value")
                }
                if (thumb) {
                    // movs r0, #v (0x2000|v) ; bx lr (0x4770)
                    val movs = (0x2000 or value.toInt())
                    byteArrayOf(
                        (movs and 0xff).toByte(), ((movs shr 8) and 0xff).toByte(),
                        0x70, 0x47,
                    )
                } else {
                    // mov r0, #v (0xE3A00000|v) ; bx lr (0xE12FFF1E)
                    val mov = 0xE3A00000u.toInt() or value.toInt()
                    val bx = 0xE12FFF1Eu.toInt()
                    byteArrayOf(
                        (mov and 0xff).toByte(), ((mov shr 8) and 0xff).toByte(),
                        ((mov shr 16) and 0xff).toByte(), ((mov shr 24) and 0xff).toByte(),
                        (bx and 0xff).toByte(), ((bx shr 8) and 0xff).toByte(),
                        ((bx shr 16) and 0xff).toByte(), ((bx shr 24) and 0xff).toByte(),
                    )
                }
            }
            else -> throw IllegalArgumentException("force_return_constant 暂不支持 $architecture")
        }
    }

    private fun dartAotObjectFromNull(offset: Int): ByteArray {
        val add = 0x91000000u.toLong() or (offset.toLong() shl 10) or (22L shl 5)
        return byteArrayOf(
            (add and 0xff).toByte(), ((add shr 8) and 0xff).toByte(),
            ((add shr 16) and 0xff).toByte(), ((add shr 24) and 0xff).toByte(),
            0xC0.toByte(), 0x03, 0x5F, 0xD6.toByte(),
        )
    }

    /** 桩字节长度（调用方预留覆盖范围用）。 */
    fun stubSize(architecture: String, returnType: String, thumb: Boolean = false): Int =
        forceReturnConstant(architecture, returnType, if (returnType.lowercase() in setOf("object", "null", "reference", "string")) 0 else 0, thumb).size
}
