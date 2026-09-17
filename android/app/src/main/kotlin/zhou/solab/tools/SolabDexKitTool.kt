package zhou.solab.tools

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import org.luckypray.dexkit.DexKitBridge
import org.luckypray.dexkit.query.FindClass
import org.luckypray.dexkit.query.FindMethod
import org.luckypray.dexkit.query.enums.OpCodeMatchType
import org.luckypray.dexkit.query.enums.StringMatchType
import org.luckypray.dexkit.query.matchers.ClassMatcher
import org.luckypray.dexkit.query.matchers.FieldMatcher
import org.luckypray.dexkit.query.matchers.MethodMatcher
import java.io.File

/**
 * A8: DexKit 反混淆查找（移植自玄星逆核 DexKitTool.kt，C++ 高性能 dex 解析）。
 *
 * 混淆 App 里靠特征反查真实类/方法：method_by_string（最常用，如搜 sign/pay/vip）、
 * class_by_string、method_by_name、class_by_name。
 * DexKitBridge 用完即 close 释放 native 资源。
 */
object SolabDexKitTool {

    private data class MethodFeatures(
        val strings: List<String>,
        val numbers: List<Number>,
        val className: String,
        val methodName: String,
        val fieldNames: List<String>,
        val invokedMethodNames: List<String>,
        val opNames: List<String>,
    ) {
        fun isEmpty(): Boolean = strings.isEmpty() && numbers.isEmpty() && className.isBlank() &&
            methodName.isBlank() && fieldNames.isEmpty() && invokedMethodNames.isEmpty() && opNames.isEmpty()
    }

    private data class AutoCandidate(
        val className: String,
        val methodName: String,
        val descriptor: String,
        val returnType: String,
        val params: List<String>,
        val dimensions: MutableSet<String> = linkedSetOf(),
        val evidence: MutableSet<String> = linkedSetOf(),
    )

    // 依赖用的是 org.luckypray:dexkit 纯 JAR（非 dexkit-android AAR），
    // JAR 版没有自动 loadLibrary 的伴生初始化，libdexkit.so 由 jniLibs
    // 手工打包；不显式加载会抛 "No implementation found for nativeInitDexKit"。
    @Volatile
    private var nativeLibReady = false
    private fun ensureNativeLib() {
        if (nativeLibReady) return
        synchronized(this) {
            if (nativeLibReady) return
            System.loadLibrary("dexkit")
            nativeLibReady = true
        }
    }

    fun handle(context: Context, args: JSONObject): JSONObject {
        val (input, inputErr) = resolveInputFile(args)
        if (inputErr != null) return inputErr
        val inputPath = input!!.absolutePath

        val action = args.str("action", "auto").ifBlank { "auto" }
        val keywords = parseKeywords(args.str("keyword"))
        val numbers = parseNumbers(args)
        val features = MethodFeatures(
            keywords,
            numbers,
            args.str("className").trim(),
            args.str("methodName").trim(),
            parseFeatureTerms(args, "fieldNames", "fieldName"),
            parseFeatureTerms(args, "invokedMethodNames", "invokedMethodName"),
            parseFeatureTerms(args, "opNames"),
        )
        if (action == "method_by_numbers" && numbers.isEmpty()) {
            return err("INVALID_ARGUMENT", "method_by_numbers 缺少 numbers", "numbers", "")
        }
        if (action in setOf("auto", "method_by_features") && features.isEmpty()) {
            return err("INVALID_ARGUMENT", "$action 至少需要一种代码特征", "keyword", "")
        }
        if (action !in setOf("auto", "method_by_numbers", "method_by_features") && keywords.isEmpty()) {
            return err("INVALID_ARGUMENT", "缺少参数 keyword(要查的字符串/名字)", "keyword", "")
        }
        val matchType = when (args.str("matchType", "Contains")) {
            "Equals" -> StringMatchType.Equals
            "StartsWith" -> StringMatchType.StartsWith
            "EndsWith" -> StringMatchType.EndsWith
            else -> StringMatchType.Contains
        }
        val ignoreCase = args.optBoolean("ignoreCase", false)
        val pkgPrefix = args.str("packagePrefix")
        val limit = args.intValue("limit", 100).coerceIn(1, 2000)

        return runCatching {
            // DexKit 加载 APK 是耗时操作，用完即 close 释放 native 资源
            // 裸 dex（外部重组或 dump 产物）DexKitBridge.create 只认
            // APK/zip（直接喂会抛 "Open zip file failed"），先包成临时 zip。
            val bareDexWrap = if (DexIo.isBareDex(input)) {
                runCatching { DexIo.wrapBareDexAsApk(context, input) }.getOrElse { e ->
                    return err("DEXKIT_FAILED", "裸 dex 临时包装失败: ${e.message ?: e.javaClass.simpleName}", "path", inputPath)
                }
            } else null
            // 自检：libdexkit.so 缺失/ABI 不匹配时给出可诊断的结构化错误，而非笼统失败
            val bridge = runCatching {
                ensureNativeLib()
                DexKitBridge.create(bareDexWrap?.absolutePath ?: input.absolutePath)
            }.getOrElse { e ->
                // 早退路径同样要回收临时包装 zip，否则每次失败漏一个 dex 体积文件。
                bareDexWrap?.let { runCatching { it.delete() } }
                if (e is UnsatisfiedLinkError || e.cause is UnsatisfiedLinkError) {
                    return err(
                        "DEXKIT_UNAVAILABLE",
                        "DexKit native 库不可用（libdexkit.so 未随当前设备 ABI 打包或加载失败）：" +
                            "${e.message}。请确认 APK 安装包包含设备 ABI（如 arm64-v8a）的 libdexkit.so，或改用 class_outline + smali_read 链路定位",
                        "path", inputPath,
                    )
                }
                throw e
            }
            try {
                bridge.use { b -> dispatch(b, action, features, matchType, ignoreCase, pkgPrefix, limit) }
            } finally {
                bareDexWrap?.let { runCatching { it.delete() } }
            }
        }.getOrElse { e ->
            err("DEXKIT_FAILED", "DexKit 查找失败: ${e.message ?: e.javaClass.simpleName}", "path", inputPath)
        }
    }

    private fun dispatch(
        bridge: DexKitBridge,
        action: String,
        features: MethodFeatures,
        matchType: StringMatchType,
        ignoreCase: Boolean,
        pkgPrefix: String,
        limit: Int,
    ): JSONObject {
        val keywords = features.strings
        val numbers = features.numbers
        return when (action) {
            "auto" -> autoSearch(bridge, features, matchType, ignoreCase, pkgPrefix, limit)

            "method_by_string", "method_by_strings" -> {
                val find = FindMethod.create().apply {
                    if (pkgPrefix.isNotBlank()) searchPackages(pkgPrefix)
                    matcher(
                        MethodMatcher.create()
                            .usingStrings(keywords, matchType, ignoreCase),
                    )
                }
                val results = bridge.findMethod(find)
                val arr = JSONArray()
                results.take(limit).forEach { m ->
                    arr.put(JSONObject()
                        .put("class", m.className)
                        .put("method", m.methodName)
                        .put("descriptor", m.descriptor)
                        .put("qualifiedId", canonicalMethodQid(m.className, m.methodName, m.descriptor))
                        .put("returnType", m.returnTypeName)
                        .put("params", JSONArray(m.paramTypeNames)))
                }
                resultJson(action, features, results.size, arr)
            }

            "class_by_string", "class_by_strings" -> {
                val find = FindClass.create().apply {
                    if (pkgPrefix.isNotBlank()) searchPackages(pkgPrefix)
                    matcher(
                        ClassMatcher.create()
                            .usingStrings(keywords, matchType, ignoreCase),
                    )
                }
                val results = bridge.findClass(find)
                val arr = JSONArray()
                results.take(limit).forEach { c ->
                    arr.put(JSONObject()
                        .put("class", c.name)
                        .put("simpleName", c.simpleName)
                        .put("sourceFile", c.sourceFile ?: ""))
                }
                resultJson(action, features, results.size, arr)
            }

            "method_by_numbers", "method_by_features" -> {
                val find = FindMethod.create().apply {
                    if (pkgPrefix.isNotBlank()) searchPackages(pkgPrefix)
                    matcher(methodFeatureMatcher(features, matchType, ignoreCase))
                }
                val results = bridge.findMethod(find)
                val arr = JSONArray(results.take(limit).map { m -> methodJson(
                    m.className, m.methodName, m.descriptor, m.returnTypeName, m.paramTypeNames,
                ) })
                resultJson(action, features, results.size, arr)
            }

            "method_by_name" -> {
                val find = FindMethod.create().apply {
                    if (pkgPrefix.isNotBlank()) searchPackages(pkgPrefix)
                    matcher(
                        MethodMatcher.create()
                            .name(keywords.first(), matchType, ignoreCase),
                    )
                }
                val results = bridge.findMethod(find)
                val arr = JSONArray()
                results.take(limit).forEach { m ->
                    arr.put(JSONObject()
                        .put("class", m.className)
                        .put("method", m.methodName)
                        .put("descriptor", m.descriptor)
                        .put("qualifiedId", canonicalMethodQid(m.className, m.methodName, m.descriptor)))
                }
                resultJson(action, features, results.size, arr)
            }

            "class_by_name" -> {
                val find = FindClass.create().apply {
                    if (pkgPrefix.isNotBlank()) searchPackages(pkgPrefix)
                    matcher(
                        ClassMatcher.create()
                            .className(keywords.first(), matchType, ignoreCase),
                    )
                }
                val results = bridge.findClass(find)
                val arr = JSONArray()
                results.take(limit).forEach { c ->
                    arr.put(JSONObject()
                        .put("class", c.name)
                        .put("simpleName", c.simpleName)
                        .put("sourceFile", c.sourceFile ?: ""))
                }
                resultJson(action, features, results.size, arr)
            }

            else -> err("UNKNOWN_ACTION", "未知 action: $action", "action", action)
        }
    }

    private fun autoSearch(
        bridge: DexKitBridge,
        features: MethodFeatures,
        matchType: StringMatchType,
        ignoreCase: Boolean,
        pkgPrefix: String,
        limit: Int,
    ): JSONObject {
        val strictFind = FindMethod.create().apply {
            if (pkgPrefix.isNotBlank()) searchPackages(pkgPrefix)
            matcher(methodFeatureMatcher(features, matchType, ignoreCase))
        }
        val strict = bridge.findMethod(strictFind)
        if (strict.isNotEmpty()) {
            val rows = JSONArray(strict.take(limit).map { method -> methodJson(
                method.className,
                method.methodName,
                method.descriptor,
                method.returnTypeName,
                method.paramTypeNames,
            ).put("matchedDimensions", JSONArray(featureDimensions(features)))
                .put("candidateStatus", "strict_match")
            })
            return resultJson(
                "auto", features, strict.size, rows,
                resolution = "strict_intersection", strictMatch = true,
            )
        }

        val probes = mutableListOf<Triple<String, String, MethodMatcher>>()
        fun addProbe(dimension: String, evidence: String, matcher: MethodMatcher) {
            if (probes.size < AUTO_PROBE_BUDGET) probes += Triple(dimension, evidence, matcher)
        }
        if (features.className.isNotBlank()) addProbe(
            "class_name", features.className,
            MethodMatcher.create().declaredClass(features.className, matchType, ignoreCase),
        )
        if (features.methodName.isNotBlank()) addProbe(
            "method_name", features.methodName,
            MethodMatcher.create().name(features.methodName, matchType, ignoreCase),
        )
        features.fieldNames.take(1).forEach { value -> addProbe(
            "used_fields", value,
            MethodMatcher.create().addUsingField(FieldMatcher.create().name(value, matchType, ignoreCase)),
        ) }
        features.invokedMethodNames.take(1).forEach { value -> addProbe(
            "invoked_methods", value,
            MethodMatcher.create().addInvoke(MethodMatcher.create().name(value, matchType, ignoreCase)),
        ) }
        features.strings.take(1).forEach { value -> addProbe(
            "used_strings", value,
            MethodMatcher.create().usingStrings(listOf(value), matchType, ignoreCase),
        ) }
        features.numbers.take(1).forEach { value -> addProbe(
            "used_numbers", value.toString(),
            MethodMatcher.create().usingNumbers(listOf(value)),
        ) }
        if (features.opNames.isNotEmpty()) addProbe(
            "opcode_sequence", features.opNames.joinToString("|"),
            MethodMatcher.create().opNames(features.opNames, OpCodeMatchType.Contains),
        )
        features.fieldNames.drop(1).forEach { value -> addProbe(
            "used_fields", value,
            MethodMatcher.create().addUsingField(FieldMatcher.create().name(value, matchType, ignoreCase)),
        ) }
        features.invokedMethodNames.drop(1).forEach { value -> addProbe(
            "invoked_methods", value,
            MethodMatcher.create().addInvoke(MethodMatcher.create().name(value, matchType, ignoreCase)),
        ) }
        features.strings.drop(1).forEach { value -> addProbe(
            "used_strings", value,
            MethodMatcher.create().usingStrings(listOf(value), matchType, ignoreCase),
        ) }
        features.numbers.drop(1).forEach { value -> addProbe(
            "used_numbers", value.toString(),
            MethodMatcher.create().usingNumbers(listOf(value)),
        ) }

        val candidates = linkedMapOf<String, AutoCandidate>()
        probes.forEach { (dimension, evidence, matcher) ->
            val find = FindMethod.create().apply {
                if (pkgPrefix.isNotBlank()) searchPackages(pkgPrefix)
                matcher(matcher)
            }
            bridge.findMethod(find).take(AUTO_RESULTS_PER_PROBE).forEach { method ->
                val qid = canonicalMethodQid(method.className, method.methodName, method.descriptor)
                val candidate = candidates.getOrPut(qid) {
                    AutoCandidate(
                        method.className,
                        method.methodName,
                        method.descriptor,
                        method.returnTypeName,
                        method.paramTypeNames,
                    )
                }
                candidate.dimensions += dimension
                candidate.evidence += "$dimension:$evidence"
            }
        }
        val ranked = candidates.values.sortedWith(
            compareByDescending<AutoCandidate> { it.dimensions.size }
                .thenByDescending { it.evidence.size }
                .thenBy { canonicalMethodQid(it.className, it.methodName, it.descriptor) },
        )
        val rows = JSONArray(ranked.take(limit).map { candidate ->
            val crossEvidence = candidate.dimensions.size >= 2
            methodJson(
                candidate.className,
                candidate.methodName,
                candidate.descriptor,
                candidate.returnType,
                candidate.params,
            ).put("matchedDimensions", JSONArray(candidate.dimensions.toList()))
                .put("matchedEvidence", JSONArray(candidate.evidence.toList()))
                .put("evidenceScore", autoCandidateScore(candidate.dimensions.size, candidate.evidence.size))
                .put("candidateStatus", if (crossEvidence) "cross_evidence_candidate" else "single_evidence_clue")
        })
        return resultJson(
            "auto", features, ranked.size, rows,
            resolution = if (ranked.isEmpty()) "not_found" else "ranked_partial_evidence",
            strictMatch = false,
        )
    }

    private fun methodFeatureMatcher(
        features: MethodFeatures,
        matchType: StringMatchType,
        ignoreCase: Boolean,
    ): MethodMatcher = MethodMatcher.create().apply {
        if (features.strings.isNotEmpty()) usingStrings(features.strings, matchType, ignoreCase)
        if (features.numbers.isNotEmpty()) usingNumbers(features.numbers)
        if (features.className.isNotBlank()) declaredClass(features.className, matchType, ignoreCase)
        if (features.methodName.isNotBlank()) name(features.methodName, matchType, ignoreCase)
        features.fieldNames.forEach { fieldName ->
            addUsingField(FieldMatcher.create().name(fieldName, matchType, ignoreCase))
        }
        features.invokedMethodNames.forEach { invokedName ->
            addInvoke(MethodMatcher.create().name(invokedName, matchType, ignoreCase))
        }
        if (features.opNames.isNotEmpty()) opNames(features.opNames, OpCodeMatchType.Contains)
    }

    private fun methodJson(
        className: String,
        methodName: String,
        descriptor: String,
        returnType: String,
        params: List<String>,
    ): JSONObject = JSONObject()
        .put("class", className)
        .put("method", methodName)
        .put("descriptor", descriptor)
        .put("qualifiedId", canonicalMethodQid(className, methodName, descriptor))
        .put("returnType", returnType)
        .put("params", JSONArray(params))

    private fun featureDimensions(features: MethodFeatures): List<String> = buildList {
        if (features.className.isNotBlank()) add("class_name")
        if (features.methodName.isNotBlank()) add("method_name")
        if (features.fieldNames.isNotEmpty()) add("used_fields")
        if (features.strings.isNotEmpty()) add("used_strings")
        if (features.numbers.isNotEmpty()) add("used_numbers")
        if (features.opNames.isNotEmpty()) add("opcode_sequence")
        if (features.invokedMethodNames.isNotEmpty()) add("invoked_methods")
    }

    internal fun autoCandidateScore(dimensionCount: Int, evidenceCount: Int): Int =
        dimensionCount.coerceAtLeast(0) * 100 + evidenceCount.coerceAtLeast(0)

    /** 点分类名 + 方法描述符 → 权威 qualifiedId（Lpkg/Class;->name(params)ret），
     *  下游 dex_xref/smali_read/patch 均可直接原样消费，消除模型手工拼签名。 */
    internal fun canonicalMethodQid(className: String, methodName: String, descriptor: String): String {
        val normalized = descriptor.trim()
        if (normalized.startsWith("L") && normalized.contains(";->")) return normalized
        return "L${className.replace('.', '/')};->$methodName$normalized"
    }

    internal fun parseKeywords(raw: String): List<String> = raw
        .split('|', '\n')
        .map(String::trim)
        .filter(String::isNotBlank)
        .distinct()
        .take(16)

    internal fun parseFeatureTerms(raw: String): List<String> = raw
        .split('|', ',', '\n')
        .map(String::trim)
        .filter(String::isNotBlank)
        .distinct()
        .take(16)

    private fun parseFeatureTerms(args: JSONObject, vararg keys: String): List<String> {
        val values = mutableListOf<String>()
        keys.forEach { key ->
            args.optJSONArray(key)?.let { array ->
                (0 until array.length()).forEach { index -> values += array.optString(index) }
            }
            if (args.opt(key) is String) values += args.optString(key)
        }
        return parseFeatureTerms(values.joinToString("|"))
    }

    internal fun parseNumbers(args: JSONObject): List<Number> {
        val values = mutableListOf<Any?>()
        val array = args.optJSONArray("numbers") ?: args.optJSONArray("values")
        if (array != null) (0 until array.length()).forEach { values += array.opt(it) }
        val raw = args.optString("numbers").ifBlank { args.optString("values") }
        if (raw.isNotBlank()) values.addAll(raw.split('|', ',', ';', '\n'))
        return values.mapNotNull { value -> when (value) {
            is Number -> value
            else -> parseNumber(value?.toString().orEmpty())
        } }.distinctBy(Number::toString).take(16)
    }

    private fun parseNumber(raw: String): Number? {
        val value = raw.trim().lowercase()
        return when {
            value.startsWith("-0x") -> value.removePrefix("-0x").toLongOrNull(16)?.let { -it }
            value.startsWith("0x") -> value.removePrefix("0x").toLongOrNull(16)
            value.contains('.') || value.contains('e') -> value.toDoubleOrNull()
            else -> value.toLongOrNull()
        }
    }

    private fun resultJson(
        action: String,
        features: MethodFeatures,
        total: Int,
        arr: JSONArray,
        resolution: String = "direct_query",
        strictMatch: Boolean = true,
    ): JSONObject {
        val keywords = features.strings
        val numbers = features.numbers
        val dimensions = featureDimensions(features)
        // 空结果给结构化引导：0 命中 ≠ 方法不存在（混淆/Flutter 场景常态），
        // 原先返回的固定 hint 与命中场景绑定，对空结果零指引。
        val hint = if (total > 0) {
            "method 结果的 qualifiedId 可原样传给 dex_xref / class_outline / smali_read / patch_apk_dex_methods，不要手工改写或重拼签名"
        } else {
            "0 命中不等于目标不存在。按序换路径：1) 用更短/更通用的关键词重试 dex_search" +
                "（matchType=Contains + ignoreCase=true，并去掉 packagePrefix 限制）；" +
                "2) 换 action（method_by_string ↔ class_by_string ↔ method_by_name/class_by_name）；" +
                "3) 界面文案类线索先 string_scan 拿真实字节串；" +
                "4) 报告 flutterApp.detected=true 时改走 so_analyze(action=blutter)——" +
                "Flutter 业务在 dex 搜不到是正常现象；5) 已知类名时用 class_outline 浏览结构。"
        }
        val firstQualifiedId = arr.optJSONObject(0)?.optString("qualifiedId").orEmpty()
        val nextActions = JSONArray()
        if (firstQualifiedId.isNotBlank()) {
            nextActions.put(JSONObject().put("tool", "dex_xref").put("purpose", "调用处与流程图")
                .put("arguments", JSONObject().put("target", firstQualifiedId)
                    .put("direction", "both").put("includeGraph", true)))
            nextActions.put(JSONObject().put("tool", "dex_xref").put("purpose", "重写实现")
                .put("arguments", JSONObject().put("target", firstQualifiedId)
                    .put("direction", "overrides").put("includeGraph", true)))
            nextActions.put(JSONObject().put("tool", "smali_read").put("purpose", "真实代码验证")
                .put("arguments", JSONObject().put("qualifiedId", firstQualifiedId)))
        }
        return ok(JSONObject()
            .put("tool", "dex_search")
            .put("action", action)
            .put("keyword", keywords.firstOrNull() ?: JSONObject.NULL)
            .put("keywords", JSONArray(keywords))
            .put("numbers", JSONArray(numbers))
            .put("className", features.className.takeIf(String::isNotBlank) ?: JSONObject.NULL)
            .put("methodName", features.methodName.takeIf(String::isNotBlank) ?: JSONObject.NULL)
            .put("fieldNames", JSONArray(features.fieldNames))
            .put("invokedMethodNames", JSONArray(features.invokedMethodNames))
            .put("opNames", JSONArray(features.opNames))
            .put("featureDimensions", JSONArray(dimensions))
            .put("featureDimensionCount", dimensions.size)
            .put("resolution", resolution)
            .put("strictMatch", strictMatch)
            .put("querySpecificity", when {
                dimensions.size >= 4 -> "high"
                dimensions.size >= 2 -> "medium"
                else -> "low"
            })
            .put("needsCodeAndXrefVerification", true)
            .put("matchLogic", when {
                action == "auto" && strictMatch -> "all_supplied_features_in_same_method"
                action == "auto" -> "ranked_by_independent_evidence_dimensions"
                action == "method_by_features" -> "all_supplied_features_in_same_method"
                keywords.size > 1 -> "all_strings_in_same_candidate"
                numbers.isNotEmpty() -> "all_numbers_in_same_method"
                else -> "single_string"
            })
            .put("total", total)
            .put("returned", arr.length())
            .put("results", arr)
            .put("nextActions", nextActions)
            .put("hint", hint))
    }

    private const val AUTO_PROBE_BUDGET = 24
    private const val AUTO_RESULTS_PER_PROBE = 200
}
