package zhou.solab

import org.jf.dexlib2.DexFileFactory
import org.jf.dexlib2.Opcodes
import org.jf.dexlib2.iface.Method
import java.io.File
import java.util.Locale
import java.util.zip.ZipFile

/**
 * 方法级定位器（缺陷 1/2/4/5/6 修复的根基）。
 * 用 dexlib2 遍历真实方法定义，把"字符串命中"升级为"真实方法定义命中"：
 * 返回可 patch 的方法清单（含全限定标识 Lpkg/Class;->name、返回类型、是否回调、所在 dex）。
 * 过滤语义与检测端一致（contains 子串），但结果全部是真实定义，可直接回传执行端。
 * 规则：本文件注释一律使用单行 //（避免 Kotlin 嵌套注释陷阱）。
 */
internal object ApkMethodLocator {

    /** 默认噪声前缀：未传 classPrefix 时跳过系统/框架类（方法名级误命中源）。 */
    private val noisePrefixes = listOf(
        "androidx/", "android/", "java/", "javax/",
        "kotlin/", "kotlinx/", "com/google/", "org/apache/",
    )

    /** 定位输入：与 SolabChannel.AdRules 同源的规则子集。 */
    data class LocatorRules(
        val sdkPackages: Set<String>,
        val classPatterns: Set<String>,
        val methodPatterns: Set<String>,
        val entryMethods: Set<String>,
        val forceTrueMethods: Set<String>,
    ) {
        companion object {
            val EMPTY = LocatorRules(emptySet(), emptySet(), emptySet(), emptySet(), emptySet())
        }
    }

    data class MethodLocation(
        val className: String,      // 原始类型描述符 Lcom/.../TTAdSdk;
        val methodName: String,     // 原始方法名
        val qualifiedId: String,    // Lcom/.../TTAdSdk;->init(参数)返回类型（A3：补全签名，
                                    // 可直接 mt_apk_read_text；patch 端剥签名按方法名匹配，兼容旧传法）
        val signature: String,      // (参数)返回类型，如 (Landroid/os/Bundle;)V
        val returnType: String,     // V/Z/I/L...;
        val isVoid: Boolean,
        val isStatic: Boolean,
        val isCallback: Boolean,    // 回调方法：patch 时会跳过，仅提示
        val isObjectGetter: Boolean, // C4：getXxx 形态且返回对象（非基础类型）——按 void/forceTrue 处理会 NPE，候选排除
        val dexFile: String,
        val sdkHits: List<String>,      // 命中的 sdk_packages 规则词
        val classHits: List<String>,    // 命中的 class_keywords 规则词
        val methodRuleHits: List<String>, // 命中的 method_patterns / entry / force_true 规则词
        val exactMatch: Boolean,        // true=方法名与规则词精确全等；false=仅子串包含
    )

    data class LocateResult(
        val locations: List<MethodLocation>,
        val totalMatches: Int,      // 未截断前的命中总数
        val truncated: Boolean,
        val suggestedPrefixes: List<String> = emptyList(), // 问题3：classPrefix 0 命中时的类前缀建议
    )

    /**
     * 定位 APK 中与规则相关的方法定义。
     * 过滤：类路径命中 sdk/class 规则，或方法名命中方法规则（精确或 >=4 的模糊词）。
     * 上限 limit 防爆；按 dex 条目顺序、类内方法顺序返回。
     * [offset]：分页偏移（问题2：36 dex 大包下 500 条上限配合 offset 分页取全量）。
     */
    fun locate(
        source: File,
        rules: LocatorRules,
        limit: Int = 500,
        classPrefix: String = "",
        offset: Int = 0,
    ): LocateResult {
        if (rules.sdkPackages.isEmpty() && rules.classPatterns.isEmpty() &&
            rules.methodPatterns.isEmpty() && rules.entryMethods.isEmpty() &&
            rules.forceTrueMethods.isEmpty() && classPrefix.isEmpty()
        ) {
            return LocateResult(emptyList(), 0, false)
        }
        val sdkSlash = rules.sdkPackages.map { it.replace('.', '/') }
        // T2：业务包前缀过滤（如 com.platovpn / Lxa/l / lxa/l），只保留该类下的方法。
        // 归一化与 classTypeLower 一致：剥 L/; 前缀后缀后小写，避免 Lxa/l 与 xa/l 失配。
        var prefixLower = classPrefix.trim().lowercase(Locale.ROOT).replace('.', '/')
        if (prefixLower.startsWith("l")) prefixLower = prefixLower.substring(1)
        if (prefixLower.endsWith(";")) prefixLower = prefixLower.dropLast(1)

        val locations = mutableListOf<MethodLocation>()
        var totalMatches = 0
        var skipped = 0
        val temporaryDirectory = File(source.parentFile, "SoLab/cache/locator/${System.nanoTime()}").apply { mkdirs() }
        try {
            ZipFile(source).use { zip ->
                zip.entries().asSequence()
                    .filterNot { it.isDirectory }
                    .filter { it.name.matches(Regex("classes(\\d*)\\.dex", RegexOption.IGNORE_CASE)) }
                    .forEach { entry ->
                        if (locations.size >= limit) return@forEach
                        val dex = File(temporaryDirectory, File(entry.name).name)
                        zip.getInputStream(entry).use { input -> dex.outputStream().use(input::copyTo) }
                        val dexFile = DexFileFactory.loadDexFile(dex, Opcodes.getDefault())
                        for (classDef in dexFile.classes) {
                            if (locations.size >= limit) break
                            val classLower = classTypeLower(classDef.type)
                            // 默认噪声过滤：系统/框架类的方法名级命中（isFull/
                            // hasProfile 等 toString 式命名）会淹没真实 SDK 定位。
                            // 显式传 classPrefix 时不过滤（可能就是查框架本身）。
                            if (prefixLower.isEmpty() &&
                                noisePrefixes.any { classLower.startsWith(it) }
                            ) {
                                continue
                            }
                            // T2：前缀过滤——非业务包直接跳过
                            if (prefixLower.isNotEmpty() && !classLower.contains(prefixLower)) {
                                continue
                            }
                            // 类级命中：sdk 包（点/斜杠格式子串）或类关键词
                            val sdkHits = sdkSlash.filter { classLower.contains(it) }
                            val classHits = rules.classPatterns.filter { classLower.contains(it) }
                            val classHit = sdkHits.isNotEmpty() || classHits.isNotEmpty()
                            for (method in classDef.methods) {
                                if (locations.size >= limit) break
                                val name = method.name.lowercase(Locale.ROOT)
                                val (ruleHits, isExact) = methodRuleHits(name, rules)
                                if (!classHit && ruleHits.isEmpty()) continue
                                totalMatches++
                                // 问题2：分页偏移——跳过前 offset 个命中
                                if (skipped < offset) {
                                    skipped++
                                    continue
                                }
                                locations += toLocation(entry.name, classDef.type, method, ruleHits, isExact, sdkHits, classHits)
                            }
                        }
                    }
            }
        } finally {
            temporaryDirectory.deleteRecursively()
        }
        val truncated = totalMatches > offset + limit
        // 问题3：classPrefix 过滤 0 命中时，返回 dex 实际类前缀建议（报告
        // packageName 可能与真实业务包不同——如 com.yize.yzqns.cn 壳包 vs
        // com.lindu.* 业务代码），避免换前缀盲试浪费一轮定位
        val suggested = if (locations.isEmpty() && prefixLower.isNotEmpty()) {
            suggestPrefixes(source)
        } else {
            emptyList()
        }
        return LocateResult(locations, totalMatches, truncated, suggested)
    }

    /** 问题3：扫描全部 dex 类名，统计出现最多的顶层包前缀（前两段），供 classPrefix 换前缀参考。 */
    private fun suggestPrefixes(source: File): List<String> {
        val counts = mutableMapOf<String, Int>()
        val temporaryDirectory = File(source.parentFile, "SoLab/cache/locator/${System.nanoTime()}").apply { mkdirs() }
        try {
            ZipFile(source).use { zip ->
                zip.entries().asSequence()
                    .filterNot { it.isDirectory }
                    .filter { it.name.matches(Regex("classes(\\d*)\\.dex", RegexOption.IGNORE_CASE)) }
                    .forEach { entry ->
                        val dex = File(temporaryDirectory, File(entry.name).name)
                        zip.getInputStream(entry).use { input -> dex.outputStream().use(input::copyTo) }
                        val dexFile = DexFileFactory.loadDexFile(dex, Opcodes.getDefault())
                        for (classDef in dexFile.classes) {
                            val name = classTypeLower(classDef.type)
                            val parts = name.split('/')
                            if (parts.size >= 2) {
                                val prefix = parts.take(2).joinToString("/")
                                counts[prefix] = (counts[prefix] ?: 0) + 1
                            }
                        }
                    }
            }
        } finally {
            temporaryDirectory.deleteRecursively()
        }
        return counts.entries
            .sortedByDescending { it.value }
            .take(10)
            .map { it.key }
    }

    /** 类型描述符去 L/; 前缀后缀并小写（Lcom/qq/e/ads/AdSdk; -> com/qq/e/ads/adsdk）。 */
    private fun classTypeLower(type: String): String {
        var t = type
        if (t.startsWith("L") && t.endsWith(";")) t = t.substring(1, t.length - 1)
        return t.lowercase(Locale.ROOT)
    }

    /** 方法规则命中：精确（全等）优先，其次 >=4 长度的模糊词（子串）。 */
    private fun methodRuleHits(name: String, rules: LocatorRules): Pair<List<String>, Boolean> {
        val hits = mutableListOf<String>()
        var exact = false
        for (rule in rules.entryMethods) {
            if (name == rule) {
                hits += "entry:$rule"
                exact = true
            } else if (!exact && rule.length >= 4 && name.contains(rule)) {
                hits += "entry:$rule"
            }
        }
        for (rule in rules.methodPatterns) {
            if (name == rule) {
                hits += "method:$rule"
                exact = true
            } else if (!exact && rule.length >= 4 && name.contains(rule)) {
                hits += "method:$rule"
            }
        }
        for (rule in rules.forceTrueMethods) {
            if (name == rule) {
                hits += "forceTrue:$rule"
                exact = true
            } else if (!exact && rule.length >= 4 && name.contains(rule)) {
                hits += "forceTrue:$rule"
            }
        }
        return hits.distinct() to exact
    }

    private fun toLocation(
        dexName: String,
        classType: String,
        method: Method,
        ruleHits: List<String>,
        exactMatch: Boolean,
        sdkHits: List<String>,
        classHits: List<String>,
    ): MethodLocation {
        val signature = "(${method.parameterTypes.joinToString("")})${method.returnType}"
        val name = method.name
        // C4：getXxx 形态且返回对象（非基础类型）的数据 getter——按 void 置空会 NPE
        val isObjectGetter = name.length > 3 &&
            name.startsWith("get") &&
            name[3].isUpperCase() &&
            method.returnType !in OBJECT_GETTER_SAFE_RETURNS
        return MethodLocation(
            className = classType,
            methodName = name,
            qualifiedId = "$classType->$name$signature",
            signature = signature,
            returnType = method.returnType,
            isVoid = method.returnType == "V",
            isStatic = method.accessFlags and org.jf.dexlib2.AccessFlags.STATIC.value != 0,
            isCallback = ApkDexPatcher.isCallbackOrListener(name.lowercase(Locale.ROOT)),
            isObjectGetter = isObjectGetter,
            dexFile = dexName,
            sdkHits = sdkHits,
            classHits = classHits,
            methodRuleHits = ruleHits,
            exactMatch = exactMatch,
        )
    }

    /** C4：getXxx 返回这些类型时不是对象 getter（可安全按值处理）。 */
    private val OBJECT_GETTER_SAFE_RETURNS = setOf(
        "V", "Z", "I", "J", "S", "B", "C", "F", "D",
        "Ljava/lang/Boolean;", "Ljava/lang/Integer;", "Ljava/lang/Long;",
        "Ljava/lang/Short;", "Ljava/lang/Byte;", "Ljava/lang/Character;",
        "Ljava/lang/Float;", "Ljava/lang/Double;",
    )
}
