package zhou.solab

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.ComponentInfo
import android.content.pm.PackageManager
import android.os.Build
import org.jf.dexlib2.DexFileFactory
import org.jf.dexlib2.Opcodes
import org.jf.dexlib2.iface.instruction.ReferenceInstruction
import org.jf.dexlib2.iface.reference.FieldReference
import zhou.solab.tools.DexIo
import zhou.solab.tools.ApkAdRules
import zhou.solab.tools.ApkRulesStore
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.util.Locale
import java.util.zip.ZipFile

/**
 * AI 按需分析模块：一次只分析一个模块（basics/manifest/shell/files/dex/resources），
 * 供 SoLab APK 助手现场调用，避免全量扫描。
 *
 * 独立于 SolabChannel，保持主通道文件精简；全量分析仍走 SolabChannel.analyzeApk。
 */
object ApkModuleAnalyzer {

    val MODULES = setOf("basics", "manifest", "shell", "files", "dex", "resources", "methods", "fields", "flutter_bridges")

    /** 按需模块分析的最大 APK 体积（与全量分析 SolabChannel.MAX_ANALYZE_BYTES 对齐）：
     *  超限直接拒绝，避免超大包在 dexlib2 全量加载下 OOM。 */
    private const val MAX_MODULE_ANALYZE_BYTES = 512L * 1024 * 1024

    /** 按模块分析：AI 需要哪个模块就现场分析哪个，避免全量扫描。
     *  [classPrefix]：methods 模块可选，只返回该业务包前缀下的方法。 */
    fun analyzeModule(
        context: Context,
        apk: File,
        module: String,
        classPrefix: String = "",
        offset: Int = 0,
        limit: Int = 500,
    ): Map<String, Any> {
        require(apk.isFile && apk.length() > 0) { "APK 文件不存在或为空" }
        if (apk.length() > MAX_MODULE_ANALYZE_BYTES) {
            throw IllegalArgumentException(
                "APK 超过 ${MAX_MODULE_ANALYZE_BYTES / 1024 / 1024} MiB 模块分析上限，请先精简 APK 或改用全量分析",
            )
        }
        return when (module) {
            "basics" -> basicsSection(context, apk)
            "manifest" -> manifestSection(context, apk)
            "shell" -> mapOf(
                "ok" to true,
                "module" to "shell",
                "shellPacking" to shellDetect(apk),
            )
            "files" -> filesSection(apk)
            "dex" -> dexSection(context, apk)
            "methods" -> methodsSection(context, apk, classPrefix, offset, limit)
            "fields" -> fieldsSection(context, apk)
            "flutter_bridges" -> flutterBridgesSection(apk, classPrefix, offset, limit)
            "resources" -> resourcesSection(apk)
            else -> mapOf("ok" to false, "error" to "invalid_module", "message" to "未知模块: $module")
        }
    }

    private fun basicsSection(context: Context, apk: File): Map<String, Any> {
        val packageInfo = packageArchiveInfo(context, apk)
        val appInfo = packageInfo?.applicationInfo?.apply {
            sourceDir = apk.absolutePath
            publicSourceDir = apk.absolutePath
        }
        return mapOf(
            "ok" to true,
            "module" to "basics",
            "fileName" to apk.name,
            "size" to apk.length(),
            "sha256" to sha256(apk),
            "packageName" to (packageInfo?.packageName ?: ""),
            "versionName" to (packageInfo?.versionName ?: ""),
            "versionCode" to versionCodeOf(packageInfo),
            "minSdk" to (appInfo?.minSdkVersion ?: 0),
            "targetSdk" to (appInfo?.targetSdkVersion ?: 0),
            "debuggable" to ((appInfo?.flags ?: 0) and ApplicationInfo.FLAG_DEBUGGABLE != 0),
            "allowBackup" to ((appInfo?.flags ?: 0) and ApplicationInfo.FLAG_ALLOW_BACKUP != 0),
            "certificateSha256" to signingCertificateSha256(packageInfo),
            "shellPacking" to shellDetect(apk),
        )
    }

    private fun manifestSection(context: Context, apk: File): Map<String, Any> {
        val packageInfo = packageArchiveInfo(context, apk)
        val appInfo = packageInfo?.applicationInfo?.apply {
            sourceDir = apk.absolutePath
            publicSourceDir = apk.absolutePath
        }
        val activities = packageInfo?.activities?.mapNotNull { it.name } ?: emptyList()
        val services = packageInfo?.services?.mapNotNull { it.name } ?: emptyList()
        val receivers = packageInfo?.receivers?.mapNotNull { it.name } ?: emptyList()
        val providers = packageInfo?.providers?.mapNotNull { it.name } ?: emptyList()
        val exportedComponents = buildList<Map<String, String>> {
            addExported("activity", packageInfo?.activities)
            addExported("service", packageInfo?.services)
            addExported("receiver", packageInfo?.receivers)
            addExported("provider", packageInfo?.providers)
        }
        val permissions = packageInfo?.requestedPermissions?.toList() ?: emptyList()
        val dangerous = permissions.filter { it in ApkRulesStore.highRiskPermissions }
        val rules = loadRules(context)
        val componentText = (activities + services + receivers + providers)
            .joinToString("\n")
            .lowercase(Locale.ROOT)
        val componentRuleMatches = rules.componentPatterns.filter { componentText.contains(it) }
        return mapOf(
            "ok" to true,
            "module" to "manifest",
            "packageName" to (packageInfo?.packageName ?: ""),
            "activities" to activities,
            "services" to services,
            "receivers" to receivers,
            "providers" to providers,
            "exportedComponents" to exportedComponents,
            "permissions" to permissions,
            "dangerousPermissions" to dangerous,
            "componentRuleMatches" to componentRuleMatches,
            "metaData" to (appInfo?.metaData?.keySet()?.sorted() ?: emptyList()),
        )
    }

    /** 壳检测：只遍历 zip 的 lib/xxx/libxxx.so 条目名（轻量，不读内容）。 */
    private fun shellDetect(apk: File): Map<String, Any> {
        val shellNames = linkedSetOf<String>()
        val shellLibs = mutableListOf<Map<String, Any>>()
        ZipFile(apk).use { zip ->
            zip.entries().asSequence().filterNot { it.isDirectory }.forEach { entry ->
                val name = entry.name
                if (name.startsWith("lib/") && name.endsWith(".so")) {
                    val soName = name.substringAfterLast('/').lowercase(Locale.ROOT)
                    for ((signature, label) in ApkRulesStore.shellSignatures) {
                        if (soName.contains(signature)) {
                            shellNames += label
                            shellLibs += mapOf("path" to name, "shell" to label, "size" to entry.size)
                        }
                    }
                }
            }
        }
        return mapOf(
            "detected" to shellNames.isNotEmpty(),
            "shells" to shellNames.toList(),
            "libs" to shellLibs,
        )
    }

    private fun filesSection(apk: File): Map<String, Any> {
        val abis = linkedSetOf<String>()
        val candidates = mutableListOf<Map<String, Any>>()
        // 有界 top-20（与 SolabChannel.analyze 同策略，避免 10 万条目全量累积）；
        // 实现收敛到 ApkShared.offerLargest 共享，不再各自维护副本。
        val largestFiles = mutableListOf<Map<String, Any>>()
        val nativeLibraryFiles = mutableListOf<Map<String, Any>>()
        val fileTypeCounts = linkedMapOf<String, Int>()
        var dex = 0
        var resources = 0
        var assets = 0
        var so = 0
        var totalFiles = 0
        var uncompressedBytes = 0L
        var compressedBytes = 0L
        ZipFile(apk).use { zip ->
            zip.entries().asSequence().filterNot { it.isDirectory }.forEach { entry ->
                totalFiles++
                val name = entry.name
                val lower = name.lowercase(Locale.ROOT)
                val size = entry.size.coerceAtLeast(0L)
                uncompressedBytes += size
                compressedBytes += entry.compressedSize.coerceAtLeast(0L)
                val extension = name.substringAfterLast('.', "(none)").lowercase(Locale.ROOT)
                fileTypeCounts[extension] = (fileTypeCounts[extension] ?: 0) + 1
                offerLargest(largestFiles, mapOf("path" to name, "size" to size, "compressedSize" to entry.compressedSize))
                when {
                    lower.endsWith(".dex") -> dex++
                    lower.startsWith("res/") -> resources++
                    lower.startsWith("assets/") -> assets++
                    lower.startsWith("lib/") && lower.endsWith(".so") -> {
                        so++
                        name.split('/').getOrNull(1)?.let(abis::add)
                        nativeLibraryFiles += mapOf("path" to name, "size" to size)
                    }
                }
                val safety = when {
                    size == 0L -> "safe"
                    lower.endsWith(".proto") || lower.endsWith(".pb") || lower.endsWith(".bin") -> "review"
                    lower.startsWith("lib/") && lower.endsWith(".so") -> "high_risk"
                    lower.startsWith("../") || lower.contains("/../") || lower.startsWith('/') -> "high_risk"
                    else -> null
                }
                if (safety != null) {
                    candidates += mapOf(
                        "path" to name,
                        "size" to size,
                        "safety" to safety,
                        "reason" to when {
                            size == 0L -> "空文件"
                            lower.endsWith(".proto") || lower.endsWith(".pb") || lower.endsWith(".bin") ->
                                "未知配置文件，需检查 DEX 和动态路径引用"
                            lower.endsWith(".so") -> "原生库可能由 JNI 或动态路径加载"
                            else -> "ZIP 路径异常，需检查打包安全性"
                        },
                    )
                }
            }
        }
        return mapOf(
            "ok" to true,
            "module" to "files",
            "totalFiles" to totalFiles,
            "uncompressedBytes" to uncompressedBytes,
            "compressedBytes" to compressedBytes,
            "compressionRatio" to if (uncompressedBytes == 0L) 1.0 else
                compressedBytes.toDouble() / uncompressedBytes.toDouble(),
            "dexFiles" to dex,
            "resourceFiles" to resources,
            "assetFiles" to assets,
            "nativeLibraries" to so,
            "abis" to abis.toList(),
            "fileTypeCounts" to fileTypeCounts.entries
                .sortedByDescending { it.value }
                .associate { it.key to it.value },
            "largestFiles" to largestFiles.sortedByDescending { (it["size"] as Long) },
            "nativeLibraryFiles" to nativeLibraryFiles.sortedByDescending { (it["size"] as Long) },
            "candidates" to candidates.sortedWith(
                compareBy<Map<String, Any>> { ApkRulesStore.safetyOrder[it["safety"]] ?: 9 }
                    .thenByDescending { it["size"] as Long },
            ),
        )
    }

    /** DEX 模块：只对 dex 条目做流式规则匹配（重量模块，AI 查广告/规则时才调）。 */
    private fun dexSection(context: Context, apk: File): Map<String, Any> {
        val rules = loadRules(context)
        val dexPatternMatches = linkedMapOf<String, List<String>>()
        val bypassCandidates = mutableListOf<Map<String, Any>>()
        val sourceChainHits = mutableMapOf<String, MutableSet<String>>()
        val sourceChainStages = linkedMapOf(
            "LoadConfig" to listOf("initconfig", "loadconfig", "readconfig", "parseconfig"),
            "InitSDK" to listOf("initsdk", "initad", "registerad", "register", "initialize"),
            "AdRequest" to listOf("requestad", "loadad", "fetchad", "loadsplashad", "loadbannerad"),
            "AdShow" to listOf("showad", "showads", "showinterstitial", "showsplash", "displayad"),
        )
        val permissionTrue = listOf("checkselfpermission", "haspermission")
        val directShow = listOf("showad", "showads", "showinterstitial", "showsplash")
        val scanPatterns = rules.searchPatterns + rules.sdkPackages + permissionTrue + directShow +
            listOf("const/4", "const/4 v", "iput", "sput", "if-") + sourceChainStages.values.flatten()
        var dex = 0
        ZipFile(apk).use { zip ->
            zip.entries().asSequence().filterNot { it.isDirectory }.forEach { entry ->
                if (entry.name.lowercase(Locale.ROOT).endsWith(".dex")) {
                    dex++
                    val entryMatches = zip.getInputStream(entry).use { input ->
                        ApkPatternScanner.scan(input, scanPatterns)
                    }
                    val sortedMatches = entryMatches.sorted()
                    val ruleMatches = sortedMatches.filter { it in rules.searchPatterns }
                    if (ruleMatches.isNotEmpty()) {
                        dexPatternMatches[entry.name] = ruleMatches
                    }
                    if (sortedMatches.any { it in rules.sdkPackageSet }) {
                        val hits = mutableListOf<Map<String, Any>>()
                        if (sortedMatches.any { it in permissionTrue } && "const/4 v" in sortedMatches) {
                            hits += mapOf("mode" to "permission_forced_true", "confidence" to "medium", "note" to "权限检查方法附近出现 const 赋值，疑似强制 true")
                        }
                        if (sortedMatches.any { it in directShow } && "if-" !in sortedMatches) {
                            hits += mapOf("mode" to "show_without_gate", "confidence" to "low", "note" to "展示方法体未见 if 分支，疑似无开关直接 show")
                        }
                        if ("const/4" in sortedMatches && ("iput" in sortedMatches || "sput" in sortedMatches)) {
                            hits += mapOf("mode" to "bool_field_hardcoded", "confidence" to "low", "note" to "const 赋值后写入字段，疑似广告状态字段写死")
                        }
                        if (hits.isNotEmpty()) bypassCandidates += mapOf("dex" to entry.name, "candidates" to hits)
                        sourceChainStages.forEach { (stage, keywords) ->
                            sortedMatches.filter { it in keywords }.forEach { keyword ->
                                sourceChainHits.getOrPut(stage) { linkedSetOf() }.add(keyword)
                            }
                        }
                    }
                }
            }
        }
        val sdkStringMatches = dexPatternMatches.values.flatten()
            .filter { it in rules.sdkPackageSet }.distinct().sorted()
        val sdkClassMatches = linkedSetOf<String>()
        runCatching {
            val prefixes = rules.sdkPackages.associateWith {
                it.trim().trimEnd('.').replace('.', '/').lowercase(Locale.ROOT)
            }
            DexIo.eachDex(context, apk) { _, dexFile ->
                for (classDef in dexFile.classes) {
                    val type = classDef.type
                        .removePrefix("L")
                        .removeSuffix(";")
                        .lowercase(Locale.ROOT)
                    for ((rule, prefix) in prefixes) {
                        if (type == prefix || type.startsWith("$prefix/")) {
                            sdkClassMatches += rule
                        }
                    }
                }
            }
        }
        return mapOf(
            "ok" to true,
            "module" to "dex",
            "dexFiles" to dex,
            // R2：单一事实源——顶层命中数组全部从 dexPatternMatches 派生
            // （跨 dex 合并去重），保证"证据存在于 dexPatternMatches 则顶层
            // 必有"，杜绝同一报告内口径分裂
            "adSdkMatches" to sdkClassMatches.sorted(),
            "adSdkStringMatches" to sdkStringMatches,
            "adClassMatches" to dexPatternMatches.values.flatten()
                .filter { it in rules.classPatternSet }.distinct().sorted(),
            "adEntryMethodMatches" to dexPatternMatches.values.flatten()
                .filter { it in rules.entryMethodSet }.distinct().sorted(),
            "adMethodMatches" to dexPatternMatches.values.flatten()
                .filter { it in rules.methodPatternSet }.distinct().sorted(),
            "adUrlMatches" to dexPatternMatches.values.flatten()
                .filter { it in rules.urlPatternSet }.distinct().sorted(),
            "vipMethodCandidates" to dexPatternMatches.values.flatten()
                .filter { it in rules.forceTrueMethodSet }.distinct().sorted(),
            // REQ-04：绕过型代码扫描（权限传 true / 开关写死 等模式）
            "bypassCandidates" to bypassCandidates,
            // REQ-05：源头链路定位（按阶段分组）
            "sourceChain" to mapOf(
                "stages" to sourceChainStages.keys.toList(),
                "hits" to sourceChainHits.mapValues { it.value.sorted() },
                "hint" to "优先看 InitSDK 阶段的初始化入口（initsdk/initad/registerad），源头短路优先，一次改对；AdRequest/AdShow 是调用点，降级才逐个改。",
            ),
            "dexPatternMatches" to dexPatternMatches.map { (dexName, patterns) ->
                mapOf("dex" to dexName, "patterns" to patterns)
            },
            "ruleStats" to mapOf(
                "sdkPackages" to rules.sdkPackages.size,
                "classPatterns" to rules.classPatterns.size,
                "methodPatterns" to rules.methodPatterns.size,
                "urlPatterns" to rules.urlPatterns.size,
                "forceTrueMethods" to rules.forceTrueMethods.size,
                "totalSearchPatterns" to rules.searchPatterns.size,
            ),
        )
    }

    /**
     * 方法级定位（缺陷 1/2/4/5/6 修复）：dexlib2 遍历真实方法定义，
     * 返回可 patch 的方法清单（含全限定标识），供执行端直接使用。
     * 字符串扫描的命中 ≠ 真实方法定义；本模块才是执行前的定位依据。
     */
    private fun methodsSection(
        context: Context,
        apk: File,
        classPrefix: String = "",
        offset: Int = 0,
        limit: Int = 500,
    ): Map<String, Any> {
        val rules = loadRules(context)
        val locatorRules = ApkMethodLocator.LocatorRules(
            sdkPackages = rules.sdkPackageSet,
            classPatterns = rules.classPatternSet,
            methodPatterns = rules.methodPatternSet,
            entryMethods = rules.entryMethodSet,
            forceTrueMethods = rules.forceTrueMethodSet,
        )
        // 问题2：大 dex（36 dex/单 dex 6.5 万方法）500 条上限配合 offset 分页取全量
        var result = ApkMethodLocator.locate(
            apk, locatorRules,
            classPrefix = classPrefix,
            offset = offset,
            limit = limit,
        )
        // 增强建议：classPrefix 0 命中时自动用 dex 内最大类前缀重试一次，省一轮
        // 「看 suggestedPrefixes → 换前缀再调」的往返；仅首页（offset=0）重试，
        // 分页场景保持原语义（0 命中仍返回建议由调用方决策）
        var autoRetriedPrefix: String? = null
        val originalSuggestions = result.suggestedPrefixes
        if (offset == 0 && result.locations.isEmpty() && originalSuggestions.isNotEmpty()) {
            val top = originalSuggestions.first()
            val retry = ApkMethodLocator.locate(
                apk, locatorRules,
                classPrefix = top,
                offset = 0,
                limit = limit,
            )
            if (retry.locations.isNotEmpty()) {
                result = retry
                autoRetriedPrefix = top
            }
        }
        // A4：按（类+方法名+签名）去重——补签名前重载（<init>()V 与 <init>(I)V）生成
        // 相同 qualifiedId 造成重复，补签名后 distinctBy qualifiedId 即可消重
        val distinctLocations = result.locations.distinctBy { it.qualifiedId }
        return mapOf(
            "ok" to true,
            "module" to "methods",
            "classPrefix" to classPrefix,
            "methodLocations" to distinctLocations.map {
                val forceTrueHit = it.methodRuleHits.any { h -> h.startsWith("forceTrue:") }
                // D3：业务上下文类（含 vpn/openvpn/ics 等特征词）——classHits 仅为
                // 规则词命中，按 classHits 引导 patch 可能误伤业务方法，需标注谨慎
                val businessContext = ApkAxmlEditor.isBusinessExcludedComponent(it.className)
                mapOf(
                    "className" to it.className,
                    "methodName" to it.methodName,
                    "qualifiedId" to it.qualifiedId,
                    "signature" to it.signature,
                    "returnType" to it.returnType,
                    "isVoid" to it.isVoid,
                    "isStatic" to it.isStatic,
                    "isCallback" to it.isCallback,
                    "isObjectGetter" to it.isObjectGetter,
                    "businessContext" to businessContext,
                    "businessContextNote" to if (businessContext) {
                        "该类为业务组件（含 vpn/proxy 等特征词）：classHits 仅为规则词命中，patch 前必须确认目标方法确实是广告/会员逻辑，避免误伤业务方法"
                    } else {
                        null
                    },
                    // A2：forceTrue 只对返回 boolean(Z) 的方法适用；包装类型/基础类型
                    // 不适用并在 forceTrueBlocked 说明原因
                    "forceTrueApplicable" to (forceTrueHit && it.returnType == "Z"),
                    "forceTrueBlocked" to if (forceTrueHit && it.returnType != "Z") {
                        mapOf(
                            "reason" to "returnType=${it.returnType} 非 boolean",
                            "hint" to if (
                                it.returnType == "Ljava/lang/Boolean;" ||
                                it.returnType == "Ljava/lang/Integer;"
                            ) {
                                "包装类型：需 sget-object TRUE 改写（引擎未实现，跳过）"
                            } else {
                                "基础类型/对象返回（如错误码、状态码语义），禁止 forceTrue"
                            },
                        )
                    } else {
                        null
                    },
                    "dexFile" to it.dexFile,
                    "sdkHits" to it.sdkHits,
                    "classHits" to it.classHits,
                    "methodRuleHits" to it.methodRuleHits,
                    "exactMatch" to it.exactMatch,
                )
            },
            "totalMatches" to result.totalMatches,
            "truncated" to result.truncated,
            // 问题2：分页信息（offset/limit 继续取下一页；totalMatches 为全量命中数）
            "offset" to offset,
            "limit" to limit,
            // 问题3：classPrefix 0 命中时的 dex 实际类前缀建议
            "suggestedPrefixes" to originalSuggestions,
            // 自动重试标记：本次结果是换用 top 前缀后的命中（空串=未重试），调用方无需再换前缀
            "autoRetriedClassPrefix" to (autoRetriedPrefix ?: ""),
            "message" to if (result.truncated) {
                "命中数 ${result.totalMatches} 超过本页上限，已返回第 ${offset + 1}~${offset + result.locations.size} 条；"
                    .let { it + "用 offset=${offset + result.locations.size} 取下一页（或传更大 limit，如 2000）" }
            } else if (autoRetriedPrefix != null) {
                "原 classPrefix '$classPrefix' 0 命中（报告 packageName 疑似壳包/入口包）；已自动改用 dex 内最大类前缀 '$autoRetriedPrefix' 重试并命中 ${result.totalMatches} 条。如目标在其他业务包，请显式换前缀重试"
            } else if (result.suggestedPrefixes.isNotEmpty()) {
                "classPrefix 过滤 0 命中：报告 packageName 可能是壳包/入口包，业务代码前缀见 suggestedPrefixes（如 com/lindu）；换前缀后重试"
            } else {
                ""
            },
        )
    }

    /** T5: Flutter MethodChannel 桥接类特征识别——Dart ↔ 原生间接调用链的
     *  自动定位（此前靠人工从类名猜桥接类）。识别实现 Flutter 消息接口的类
     *  并列出 onMethodCall 等入口方法，AI 直接拿类名走 class_outline/dex_xref。 */
    private fun flutterBridgesSection(
        apk: File,
        classPrefix: String = "",
        offset: Int = 0,
        limit: Int = 200,
    ): Map<String, Any> {
        val handlerIface = "Lio/flutter/plugin/common/MethodChannel\$MethodCallHandler;"
        val messageHandlerIface = "Lio/flutter/plugin/common/BasicMessageChannel\$MessageHandler;"
        val streamHandlerIface = "Lio/flutter/plugin/common/EventChannel\$StreamHandler;"
        val pluginIface = "Lio/flutter/embedding/engine/plugins/FlutterPlugin;"
        val methodCallType = "Lio/flutter/plugin/common/MethodCall;"
        val resultType = "Lio/flutter/plugin/common/MethodChannel\$Result;"

        val temporaryDirectory = Files.createTempDirectory("solab_apk_bridges_").toFile()
        val bridges = mutableListOf<Map<String, Any>>()
        var totalBridges = 0
        try {
            ZipFile(apk).use { zip ->
                zip.entries().asSequence()
                    .filterNot { it.isDirectory }
                    .filter { it.name.matches(DexIo.classesDexRegex) }
                    .forEach { entry ->
                        val dex = File(temporaryDirectory, File(entry.name).name)
                        zip.getInputStream(entry).use { input -> dex.outputStream().use(input::copyTo) }
                        val dexFile = DexFileFactory.loadDexFile(dex, Opcodes.getDefault())
                        for (cls in dexFile.classes) {
                            if (classPrefix.isNotEmpty() && !cls.type.contains(classPrefix, ignoreCase = true)) continue
                            val interfaces = cls.interfaces
                            val kind = when {
                                handlerIface in interfaces -> "method_channel"
                                messageHandlerIface in interfaces -> "basic_message_channel"
                                streamHandlerIface in interfaces -> "event_channel"
                                pluginIface in interfaces -> "flutter_plugin"
                                else -> continue
                            }
                            val entryMethods = cls.methods.filter { m ->
                                val params = m.parameterTypes
                                methodCallType in params || resultType in params
                            }.map { m ->
                                "${m.name}(${m.parameterTypes.joinToString("")})${m.returnType}"
                            }
                            if (totalBridges >= offset && bridges.size < limit) {
                                bridges.add(
                                    mapOf(
                                        "className" to cls.type,
                                        "kind" to kind,
                                        "entryMethods" to entryMethods,
                                        "methodCount" to cls.methods.count(),
                                        "dexFile" to entry.name,
                                    )
                                )
                            }
                            totalBridges++
                        }
                        System.gc()
                    }
            }
        } finally {
            temporaryDirectory.deleteRecursively()
        }
        val hasMore = offset + bridges.size < totalBridges
        return mapOf(
            "ok" to true,
            "module" to "flutter_bridges",
            "totalBridges" to totalBridges,
            "offset" to offset,
            "returned" to bridges.size,
            "hasMore" to hasMore,
            "nextOffset" to if (hasMore) offset + bridges.size else -1,
            "bridges" to bridges,
            "hint" to if (totalBridges == 0) {
                "未发现 Flutter 桥接类（目标可能非 Flutter 包或桥接被混淆剥壳）；可改用 dex_search 搜 methodCall/onMethodCall 关键词"
            } else {
                "MethodChannel 桥接类 = Dart 层调原生 SDK 的入口（onMethodCall 是消息分发点）：拿 className → class_outline 看方法 → dex_xref 查调用链；桥接内再调广告/会员 SDK init 的就是原生层修改点"
            },
        )
    }

    /** 规则1/2：字段直读模式——敏感状态字段（isVip/isPro/vipExpire 等）的
     * 消费方扫描。会员状态字段常由 Gson 反射填充（无 setter/iput 写入点），
     * 所有页面直接 iget 读取判断——只 patch 一个消费点会漏改（会员点亮 =
     * 全消费方覆盖）。输出全部 iget 消费方法，供逐读取点条件翻转。
     * 规则5：多 dex 全量扫描，消费方跨 dex 聚合（不只看命中 dex）。 */
    private fun fieldsSection(context: Context, apk: File): Map<String, Any> {
        // 缺陷1 修复：类型不限（int/long 的 isVip/vipExpire 是 B3 主场景，
        // 不只收 boolean）；词表覆盖 is*/vip*/expire*/deadline 等驼峰拆分段
        val keywords = listOf(
            "isvip", "ispro", "isforever", "vipexpire", "vipmember", "viptype",
            "viplevel", "ispremium", "isvipmember", "vipendtime", "viptime",
            "memberexpire", "expiretime", "expireat", "expireend",
            "deadline", "ispaid", "ismember", "ispermanent", "authlevel",
            "usertype", "vipperiod", "vipstatus", "vipflag",
        )
        val temporaryDirectory = Files.createTempDirectory("solab_apk_fields_").toFile()
        try {
            // 阶段1：跨全部 dex 收集敏感字段（classType -> fieldNames）。
            // 解压产物保留到阶段2 复用——原先两阶段各自解压+加载一遍，
            // 该重量级模块耗时严格翻倍。
            val sensitiveFields = mutableMapOf<String, MutableMap<String, String>>()
            val extractedDexes = mutableListOf<File>()
            ZipFile(apk).use { zip ->
                zip.entries().asSequence()
                    .filterNot { it.isDirectory }
                    .filter { it.name.matches(DexIo.classesDexRegex) }
                    .forEach { entry ->
                        val dex = File(temporaryDirectory, File(entry.name).name)
                        if (!dex.isFile) {
                            zip.getInputStream(entry).use { input -> dex.outputStream().use(input::copyTo) }
                        }
                        extractedDexes += dex
                        val dexFile = DexFileFactory.loadDexFile(dex, Opcodes.getDefault())
                        for (classDef in dexFile.classes) {
                            for (field in classDef.fields) {
                                val n = field.name.lowercase(Locale.ROOT)
                                if (keywords.any { n.contains(it) }) {
                                    sensitiveFields
                                        .getOrPut(classDef.type) { linkedMapOf() }
                                        .put(field.name, field.type)
                                }
                            }
                        }
                    }
            }
            if (sensitiveFields.isEmpty()) {
                return mapOf(
                    "ok" to true,
                    "module" to "fields",
                    "fieldCandidates" to emptyList<Map<String, Any>>(),
                    "fieldReadCandidates" to emptyList<Map<String, Any>>(),
                    "keywordCount" to keywords.size,
                    "hint" to "未发现敏感状态字段（isVip/isPro/vipExpire/deadline 等词表）",
                )
            }
            // 阶段2：单遍方法扫描，引用敏感字段的指令 → 消费点（跨 dex 聚合）。
            // 缺陷1 修复：FieldReference 直判（iget/sget/iput/sput 均为此类型，
            // invoke 是 MethodReference 天然排除）；记录 opcode 供调用方区分读写
            val consumersByField = mutableMapOf<String, MutableList<Map<String, String>>>()
            var methodsScanned = 0
            for (dex in extractedDexes) {
                val dexFile = DexFileFactory.loadDexFile(dex, Opcodes.getDefault())
                for (classDef in dexFile.classes) {
                    for (method in classDef.methods) {
                        val impl = method.implementation ?: continue
                        methodsScanned++
                        try {
                            for (insn in impl.instructions) {
                                // 字段消费方：所有引用该字段的指令（iget/sget/iput/sput
                                // 均为 FieldReference；invoke 是 MethodReference 已排除）。
                                // 不依赖 opcode.name 前缀（枚举名大小写不确定，
                                // 此前 startsWith("IGET") 造成假阴性漏报全部消费方）。
                                if (insn !is ReferenceInstruction) continue
                                val ref = insn.reference
                                if (ref !is FieldReference) continue
                                val fieldNames = sensitiveFields[ref.definingClass] ?: continue
                                if (fieldNames[ref.name] != ref.type) continue
                                // 每条指令记一次（consumerCount=消费点指令数，
                                // 与 xref 真值一致）；opcode 区分读写
                                consumersByField
                                    .getOrPut("${ref.definingClass}->${ref.name}:${ref.type}") { mutableListOf() }
                                    .add(
                                        mapOf(
                                            "method" to "${classDef.type}->${method.name}",
                                            "opcode" to insn.opcode.name,
                                        ),
                                    )
                            }
                        } catch (e: Exception) {
                            // D1：单方法指令损坏（截断/畸形）——跳过该方法，
                            // 不拖垮整个 dex 的消费点聚合。
                        }
                    }
                }
            }
            // 缺陷1 修复：输出结构分离——fieldCandidates（字段存在是事实，
            // 即使消费点聚合失败也可见）+ consumers（消费点，含 opcode）
            val fieldCandidates = sensitiveFields.flatMap { (classType, fields) ->
                fields.map { (name, type) ->
                    mapOf("field" to "$classType->$name:$type", "class" to classType, "name" to name)
                }
            }.sortedBy { it["field"] as String }
            val results = consumersByField.map { (field, consumers) ->
                mapOf(
                    "field" to field,
                    // consumerCount = 消费点指令条数（与 xref 真值一致）
                    "consumerCount" to consumers.size,
                    // consumers = 消费点明细（方法 + opcode）
                    "consumers" to consumers.take(100),
                    // methods = 方法级去重（patch 目标）
                    "methods" to consumers.map { it["method"] }.distinct().take(50),
                    "hint" to "字段直读模式：状态字段由反射填充（无 setter/iput 写入点），需逐读取点修改——consumerCount 为该字段引用指令总条数，methods 为方法级去重后的 patch 目标，条件判断处 flip 才完整生效（会员点亮=全消费方覆盖）",
                )
            }.sortedByDescending { (it["consumerCount"] as Int) }
            return mapOf(
                "ok" to true,
                "module" to "fields",
                "fieldCandidates" to fieldCandidates.take(200),
                "fieldReadCandidates" to results.take(50),
                "keywordCount" to keywords.size,
                "diagnostics" to mapOf(
                    "phase1FieldCount" to fieldCandidates.size,
                    "phase2MethodsScanned" to methodsScanned,
                    "phase2ConsumerFields" to results.size,
                ),
                "hint" to if (results.isEmpty()) {
                    "已发现 ${fieldCandidates.size} 个敏感字段（见 fieldCandidates），但未找到任何引用它们的指令消费点——" +
                        "字段存在是事实；消费点缺失可能因字段仅被反射/序列化使用（无 iget/sget/iput/sput 指令），" +
                        "或需扩大词表。请用 mt_apk_dex_xref 交叉核对目标字段"
                } else {
                    "多 dex 已全量扫描（规则5）：同一字段的引用指令跨全部 dex 聚合，methods 可作候选，需经 smali_read 验证后再修改"
                },
            )
        } finally {
            temporaryDirectory.deleteRecursively()
        }
    }

    private fun resourcesSection(apk: File): Map<String, Any> {
        var resources = 0
        var assets = 0
        val largestRes = mutableListOf<Map<String, Any>>()
        ZipFile(apk).use { zip ->
            zip.entries().asSequence().filterNot { it.isDirectory }.forEach { entry ->
                val name = entry.name
                when {
                    name.startsWith("res/") -> {
                        resources++
                        offerLargest(largestRes, mapOf("path" to name, "size" to entry.size.coerceAtLeast(0L)))
                    }
                    name.startsWith("assets/") -> assets++
                }
            }
        }
        return mapOf(
            "ok" to true,
            "module" to "resources",
            "resourceFiles" to resources,
            "assetFiles" to assets,
            "largestResources" to largestRes.sortedByDescending { (it["size"] as Long) },
        )
    }

    // ---- 辅助（packageArchiveInfo/versionCodeOf 为 ApkModuleAnalyzer 独有；
    //      sha256/toHex/signingCertificateSha256 已收敛到 ApkShared） ----

    private fun packageArchiveInfo(
        context: Context,
        apk: File,
    ): android.content.pm.PackageInfo? {
        val flags = PackageManager.GET_ACTIVITIES or PackageManager.GET_SERVICES or
            PackageManager.GET_RECEIVERS or PackageManager.GET_PROVIDERS or
            PackageManager.GET_PERMISSIONS or PackageManager.GET_META_DATA or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                PackageManager.GET_SIGNING_CERTIFICATES
            } else {
                @Suppress("DEPRECATION")
                PackageManager.GET_SIGNATURES
            }
        @Suppress("DEPRECATION")
        return context.packageManager.getPackageArchiveInfo(apk.absolutePath, flags)
    }

    private fun versionCodeOf(packageInfo: android.content.pm.PackageInfo?): Long {
        if (packageInfo == null) return 0L
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            packageInfo.versionCode.toLong()
        }
    }

    private fun MutableList<Map<String, String>>.addExported(
        type: String,
        components: Array<out ComponentInfo>?,
    ) {
        components?.filter { it.exported }?.forEach {
            add(mapOf("type" to type, "name" to it.name))
        }
    }

    private fun loadRules(context: Context): ApkAdRules = ApkRulesStore.load(context)
}
