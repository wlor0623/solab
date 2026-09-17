package com.soreverse.mcp.nativecore

/**
 * librz_native.so 的 JNI 符号绑定层。
 *
 * 预编译产物 librz_native.so 的 JNI 导出符号为
 * Java_com_soreverse_mcp_nativecore_RizinNativeEngine_*；
 * JVM 按「调用 external 方法的类」的全限定名解析符号，因此这些方法
 * 必须声明在本包同名类上才能完成绑定（so 为二进制产物，符号名不可改）。
 *
 * 引擎调用统一走 zhou.solab.nativecore.RizinNativeEngine 委托，
 * 业务代码不应直接使用本类。
 */
object RizinNativeEngine {
    @Volatile
    var loaded: Boolean = false
        private set

    @Volatile
    var loadError: String = ""
        private set

    init {
        tryLoad()
    }

    fun tryLoad(): Boolean = runCatching { System.loadLibrary("rz_native") }
        .onSuccess { loaded = true }
        .onFailure {
            loaded = false
            loadError = it.message ?: "Unknown load error"
        }
        .isSuccess

    // 以下方法签名必须与 so 内 JNI 导出符号严格一致，不可重命名/改参。
    external fun rzDisassemble(bytes: ByteArray, arch: String, address: Long, thumb: Boolean, limit: Int): String
    external fun rzAssemble(asm: String, arch: String, address: Long, thumb: Boolean): ByteArray
    external fun rzXrefs(bytes: ByteArray, arch: String, atVa: Long, direction: String): String
    external fun rzAnalyze(bytes: ByteArray, arch: String): String
    external fun rzFunctions(bytes: ByteArray, arch: String): String
    external fun rzCfg(bytes: ByteArray, arch: String, funcVa: Long): String
    external fun rzSearchBytes(bytes: ByteArray, arch: String, pattern: String, fromVa: Long, toVa: Long): String
    external fun rzScanCrypto(bytes: ByteArray, arch: String): String
    external fun rzEsilStep(bytes: ByteArray, arch: String, startVa: Long, stepCount: Int): String
    external fun rzDiff(bytesA: ByteArray, bytesB: ByteArray): String
    external fun rzCommand(bytes: ByteArray, arch: String, command: String, unsafe: Boolean): String
    external fun rzDecompile(bytes: ByteArray, arch: String, funcVa: Long): String
    external fun rzConfigureGhidra(pluginDir: String, sleighHome: String): Boolean
}
