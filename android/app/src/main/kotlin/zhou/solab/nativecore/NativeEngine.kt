package zhou.solab.nativecore

import android.content.Context
import zhou.solab.tools.AppLog
import java.io.File

/**
 * Abstraction over the native disassembly / assembly / analysis backend.
 *
 * The MCP protocol layer and [zhou.solab.engine.NativeSoEngine] depend
 * on this interface (Dependency Inversion), never on a concrete engine. The
 * active backend is resolved at runtime through [active] and can be swapped at
 * any time via [select] — this is the single, clean seam that lets the project
 * migrate backends without touching any call site or recompiling the Kotlin
 * layer.
 *
 * Contract guarantees every backend must honour:
 *  - [disassemble] returns a multi-line text where each line is
 *    `0xADDR: BB BB ...    mnemonic op_str` (the downstream pager in
 *    NativeSoEngine.disasm parses this exact shape). On failure return "".
 *  - [assemble] returns the encoded machine bytes, or an empty array on
 *    failure (the Kotlin caller then falls back to architecture NOPs).
 *  - [available] must be cheap and side-effect free; it is probed before
 *    the backend is selected as active.
 *
 * Backend: [RizinNativeEngine] — Rizin (librz_asm/librz_analysis/librz_bin)
 * via JNI, statically linked into librz_native.so. Capstone/Keystone have been
 * fully removed from the project.
 */
interface NativeEngine {
    val backendName: String

    fun disassemble(bytes: ByteArray, arch: String, address: Long, thumb: Boolean, limit: Int): String

    fun assemble(asm: String, arch: String, address: Long, thumb: Boolean): ByteArray

    fun available(): Boolean

    fun loadStatus(): String

    fun analyze(bytes: ByteArray, arch: String): String

    fun functions(bytes: ByteArray, arch: String): String

    fun cfg(bytes: ByteArray, arch: String, funcVa: Long): String

    fun xrefs(bytes: ByteArray, arch: String, atVa: Long, direction: String = "to"): String

    fun searchBytes(bytes: ByteArray, arch: String, pattern: String, fromVa: Long = 0, toVa: Long = 0): String

    fun scanCrypto(bytes: ByteArray, arch: String): String

    fun esilStep(bytes: ByteArray, arch: String, startVa: Long, stepCount: Int): String

    fun diff(bytesA: ByteArray, bytesB: ByteArray): String

    fun command(bytes: ByteArray, arch: String, command: String, unsafe: Boolean = false): String

    fun decompile(bytes: ByteArray, arch: String, funcVa: Long): String

    companion object {
        @Volatile
        private var instance: NativeEngine = resolveDefault()

        fun active(): NativeEngine = instance

        /**
         * Select a backend by name. Returns true when the named backend exists
         * and reports [available]; otherwise the previous backend is kept and
         * false is returned. Unknown names are logged and rejected so a
         * misconfigured setting never silently downgrades to a no-op backend.
         */
        fun select(name: String): Boolean {
            val candidate = when (name.lowercase()) {
                "rizin", "" -> RizinNativeEngine
                else -> {
                    AppLog.w("NativeEngine: unknown backend '$name'; keeping ${instance.backendName}")
                    return false
                }
            }
            if (!candidate.available()) {
                AppLog.w("NativeEngine: backend '${candidate.backendName}' not available on this ABI; disasm/asm will degrade to pseudo/NOP")
                return false
            }
            instance = candidate
            AppLog.i("NativeEngine backend -> ${candidate.backendName}")
            return true
        }

        private fun resolveDefault(): NativeEngine {
            if (RizinNativeEngine.available()) return RizinNativeEngine
            AppLog.w("NativeEngine: Rizin backend unavailable on this ABI; disasm/asm degrade to pseudo/NOP until librz_native.so is built")
            return RizinNativeEngine
        }
    }
}

/**
 * Rizin backend (librz_arch/librz_analysis/librz_asm/librz_bin) exposed through
 * a dedicated JNI surface in librz_native.so. This is the sole native backend
 * now that Capstone/Keystone have been removed.
 *
 * librz_native.so is a prebuilt binary whose JNI export symbols are bound to
 * the class name com.soreverse.mcp.nativecore.RizinNativeEngine (see the
 * bridge). All rz* calls are delegated to that bridge object; this class keeps
 * the project-local API surface and load bookkeeping.
 */
object RizinNativeEngine : NativeEngine {
    override val backendName: String = "rizin"

    // JNI 绑定层：external 方法必须声明在与 so 导出符号一致的包/类上。
    private val bridge get() = com.soreverse.mcp.nativecore.RizinNativeEngine

    init {
        if (bridge.loaded) {
            AppLog.i("RizinNativeEngine: librz_native load OK")
        } else {
            AppLog.w("RizinNativeEngine: librz_native load FAILED: ${bridge.loadError}")
        }
    }

    fun configureGhidra(context: Context): Boolean {
        if (!available()) return false
        return runCatching {
            val root = File(context.filesDir, "rizin")
            val plugins = File(context.applicationInfo.nativeLibraryDir)
            val sleigh = File(root, "plugins/rz_ghidra_sleigh")
            if (sleigh.exists()) sleigh.deleteRecursively()
            // 全量包：assets 内置；lite 包：按需下载目录（externalFilesDir/assets/rizin）
            val assetRoot = File(context.filesDir, "rizin")
            val fromDownload = zhou.solab.tools.AssetDownloader.assetFile(context, "rizin/plugins/rz_ghidra_sleigh/.keep") != null
            if (fromDownload) {
                val downloaded = File(zhou.solab.tools.AssetDownloader.assetDir(context), "rizin")
                copyDir(downloaded, sleigh)
            } else {
                copyAssetDir(context, "rizin/plugins/rz_ghidra_sleigh", sleigh)
            }
            val slaCount = sleigh.walkTopDown().count { it.isFile && it.extension == "sla" }
            val ldefsCount = sleigh.walkTopDown().count { it.isFile && it.extension == "ldefs" }
            val ok = bridge.rzConfigureGhidra(plugins.absolutePath, sleigh.absolutePath)
            AppLog.i("RizinNativeEngine: ghidra pluginDir=${plugins.absolutePath} sleighHome=${sleigh.absolutePath} sla=$slaCount ldefs=$ldefsCount ok=$ok")
            ok
        }.onFailure { AppLog.w("RizinNativeEngine: ghidra configure failed: ${it.message}") }.getOrDefault(false)
    }

    override fun available(): Boolean = bridge.loaded

    override fun loadStatus(): String = if (bridge.loaded) "loaded" else "failed: ${bridge.loadError}"

    override fun disassemble(bytes: ByteArray, arch: String, address: Long, thumb: Boolean, limit: Int): String {
        if (!available()) return ""
        return runCatching { bridge.rzDisassemble(bytes, arch, address, thumb, limit) }.getOrDefault("")
    }

    override fun assemble(asm: String, arch: String, address: Long, thumb: Boolean): ByteArray {
        if (!available()) return ByteArray(0)
        return runCatching { bridge.rzAssemble(asm, arch, address, thumb) }.getOrDefault(ByteArray(0))
    }

    override fun xrefs(bytes: ByteArray, arch: String, atVa: Long, direction: String): String {
        if (!available()) return "{\"xrefs\":[]}"
        return runCatching { bridge.rzXrefs(bytes, arch, atVa, direction) }.getOrDefault("{\"xrefs\":[]}")
    }

    override fun analyze(bytes: ByteArray, arch: String): String {
        if (!available()) return "{\"error\":\"unavailable\"}"
        return runCatching { bridge.rzAnalyze(bytes, arch) }.getOrDefault("{\"error\":\"failed\"}")
    }

    override fun functions(bytes: ByteArray, arch: String): String {
        if (!available()) return "[]"
        return runCatching { bridge.rzFunctions(bytes, arch) }.getOrDefault("[]")
    }

    override fun cfg(bytes: ByteArray, arch: String, funcVa: Long): String {
        if (!available()) return "{\"error\":\"unavailable\"}"
        return runCatching { bridge.rzCfg(bytes, arch, funcVa) }.getOrDefault("{\"error\":\"failed\"}")
    }

    override fun searchBytes(bytes: ByteArray, arch: String, pattern: String, fromVa: Long, toVa: Long): String {
        if (!available()) return "{\"hits\":[]}"
        return runCatching { bridge.rzSearchBytes(bytes, arch, pattern, fromVa, toVa) }.getOrDefault("{\"hits\":[]}")
    }

    override fun scanCrypto(bytes: ByteArray, arch: String): String {
        if (!available()) return "{\"hits\":[]}"
        return runCatching { bridge.rzScanCrypto(bytes, arch) }.getOrDefault("{\"hits\":[]}")
    }

    override fun esilStep(bytes: ByteArray, arch: String, startVa: Long, stepCount: Int): String {
        if (!available()) return "{\"error\":\"unavailable\"}"
        return runCatching { bridge.rzEsilStep(bytes, arch, startVa, stepCount) }.getOrDefault("{\"error\":\"failed\"}")
    }

    override fun diff(bytesA: ByteArray, bytesB: ByteArray): String {
        if (!available()) return "{\"error\":\"unavailable\"}"
        return runCatching { bridge.rzDiff(bytesA, bytesB) }.getOrDefault("{\"error\":\"failed\"}")
    }

    override fun command(bytes: ByteArray, arch: String, command: String, unsafe: Boolean): String {
        if (!available()) return "{\"error\":\"unavailable\"}"
        return runCatching { bridge.rzCommand(bytes, arch, command, unsafe) }.getOrDefault("{\"error\":\"failed\"}")
    }

    override fun decompile(bytes: ByteArray, arch: String, funcVa: Long): String {
        if (!available()) return "{\"error\":\"unavailable\"}"
        return runCatching { bridge.rzDecompile(bytes, arch, funcVa) }
            .onSuccess { AppLog.i("RizinNativeEngine: rzDecompile returned ${it.take(160)}") }
            .onFailure { AppLog.e("RizinNativeEngine: rzDecompile failed", it) }
            .getOrDefault("{\"error\":\"failed\"}")
    }
}

private fun copyDir(src: File, outDir: File) {
    if (!src.isDirectory) return
    outDir.mkdirs()
    src.listFiles().orEmpty().forEach { child ->
        val out = File(outDir, child.name)
        if (child.isDirectory) copyDir(child, out)
        else child.copyTo(out, overwrite = true)
    }
}

private fun copyAssetDir(context: Context, assetPath: String, outDir: File) {
    val names = context.assets.list(assetPath).orEmpty()
    outDir.mkdirs()
    for (name in names) {
        val childAsset = "$assetPath/$name"
        val listed = context.assets.list(childAsset).orEmpty()
        val out = File(outDir, name)
        if (listed.isNotEmpty()) {
            copyAssetDir(context, childAsset, out)
        } else if (!out.exists() || out.length() == 0L) {
            out.parentFile?.mkdirs()
            context.assets.open(childAsset).use { input -> out.outputStream().use { input.copyTo(it) } }
        }
    }
}
