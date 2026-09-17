package zhou.solab

import org.jf.dexlib2.DexFileFactory
import org.jf.dexlib2.Opcodes
import org.jf.dexlib2.iface.instruction.ReferenceInstruction
import org.jf.dexlib2.iface.instruction.formats.Instruction21c
import org.jf.dexlib2.iface.instruction.formats.Instruction31c
import org.jf.dexlib2.iface.reference.StringReference
import java.io.File

/**
 * B8 广告 assets 资源清理的扫描辅助：DEX 字符串引用扫描 + 资源关键词映射。
 * 安全纪律：先查引用后删；被 DEX 引用的资源只报告不删除。
 * 规则：本文件注释一律使用单行 //（避免 Kotlin 嵌套注释陷阱）。
 */
internal object ApkAssetScanner {

    private val RESOURCE_EXTENSIONS = setOf(
        "xml", "json", "plist", "png", "jpg", "jpeg", "gif", "webp",
        "js", "txt", "dat", "bin", "db", "sqlite", "zip", "mp3", "mp4",
    )

    internal val ASSET_AD_HINTS = listOf("config", "setting", "sdk", "ad", "android", "json", "xml")

    /** 判断字符串常量是否疑似 assets 资源引用。 */
    internal fun isAssetLikeRef(value: String): Boolean {
        if (value.startsWith("assets/")) return true
        val ext = value.substringAfterLast('.')
        return ext.length in 2..4 && ext.all { it.isLetter() } && ext in RESOURCE_EXTENSIONS
    }

    /** 按 SDK 包名推导 assets 文件名关键词（比 so 关键词更全，含 pangolin/ksad 等）。 */
    internal fun buildAssetKeywords(sdkPackages: Collection<String>): Set<String> {
        val keywords = mutableSetOf<String>()
        val joined = sdkPackages.joinToString(" ").lowercase()

        val knownMappings = mapOf(
            "bytedance" to listOf("ttad", "pangle", "openadsdk", "bytedance", "pangolin"),
            "pangle" to listOf("pangle", "ttad", "pangolin"),
            "qq.e" to listOf("gdt", "qqad", "gdtad"),
            "gdt" to listOf("gdt"),
            "baidu" to listOf("baidu", "mobads", "mobad"),
            "kuaishou" to listOf("kuaishou", "gdfp", "ksad"),
            "unity3d" to listOf("unityads", "unity_ad"),
            "mintegral" to listOf("mintegral", "mbridge", "mtg"),
            "mobvista" to listOf("mobvista", "mtg"),
            "vungle" to listOf("vungle"),
            "chartboost" to listOf("chartboost"),
            "appnext" to listOf("appnext"),
            "inmobi" to listOf("inmobi"),
            "flurry" to listOf("flurry"),
            "adcolony" to listOf("adcolony"),
            "applovin" to listOf("applovin", "applvn"),
            "ironsource" to listOf("ironsource"),
            "startapp" to listOf("startapp"),
            "smaato" to listOf("smaato"),
            "pubmatic" to listOf("pubmatic"),
            "amazon" to listOf("amazon", "amoad"),
            "yandex" to listOf("yandex"),
            "mytarget" to listOf("mytarget"),
            "huawei" to listOf("huawei", "hms_ads"),
            "sigmob" to listOf("sigmob"),
            "anythink" to listOf("anythink", "topon"),
            "topon" to listOf("topon"),
            "facebook" to listOf("facebook", "fb_ads", "audiencenetwork"),
            "admob" to listOf("admob"),
            "appodeal" to listOf("appodeal"),
            "tapjoy" to listOf("tapjoy"),
            "mopub" to listOf("mopub"),
            "pubnative" to listOf("pubnative"),
            "fyber" to listOf("fyber", "inneractive"),
            "oneway" to listOf("oneway"),
            "beizi" to listOf("beizi"),
            "mobisage" to listOf("mobisage"),
            "zhangyue" to listOf("zyad"),
            "heytap" to listOf("heytap"),
            "oppo" to listOf("oppo"),
            "vivo" to listOf("vivo"),
            "xiaomi" to listOf("xiaomi", "mimo"),
            "miui" to listOf("miui", "mimo"),
        )

        for ((pkgFragment, names) in knownMappings) {
            if (joined.contains(pkgFragment)) {
                keywords.addAll(names)
            }
        }
        return keywords
    }

    /**
     * 扫描全部 DEX 的字符串常量，收集疑似 assets 引用的值（含文件名部分）。
     * 单个 DEX 扫描失败只记警告，不中断整体扫描。
     */
    internal fun collectDexReferencedAssets(dexFiles: List<File>): Set<String> {
        val refs = mutableSetOf<String>()
        for ((index, dexFile) in dexFiles.withIndex()) {
            try {
                val dex = DexFileFactory.loadDexFile(dexFile, Opcodes.getDefault())
                for (classDef in dex.classes) {
                    for (method in classDef.methods) {
                        val impl = method.implementation ?: continue
                        for (ins in impl.instructions) {
                            val value = when (ins) {
                                is Instruction21c -> (ins.reference as? StringReference)?.string
                                is Instruction31c -> (ins.reference as? StringReference)?.string
                                else -> null
                            } ?: continue
                            val lower = value.lowercase()
                            if (isAssetLikeRef(lower)) {
                                refs.add(lower)
                                if (lower.contains("/")) {
                                    refs.add(lower.substringAfterLast('/'))
                                }
                            }
                        }
                    }
                }
            } catch (_: Exception) {
                // 单个 dex 损坏不影响其余
            }
            // 多 dex 大包：每扫完一个释放 dexlib2 引用，避免 OOM
            if (index < dexFiles.size - 1) {
                System.gc()
            }
        }
        return refs
    }
}

/** 判断字符串是否包含任一 needle（B8 assets 命中用）。 */
internal fun String.containsAny(needles: List<String>): Boolean {
    for (needle in needles) {
        if (this.contains(needle)) return true
    }
    return false
}
