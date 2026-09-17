package zhou.solab

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.ComponentInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.jf.dexlib2.DexFileFactory
import org.jf.dexlib2.Opcodes
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.util.Locale
import java.util.LinkedHashMap
import java.util.zip.ZipFile
import zhou.solab.tools.SolabJadxTool
import zhou.solab.tools.SolabApkBuildTool
import zhou.solab.tools.SolabApkEditorTool
import zhou.solab.tools.SolabDexKitTool
import zhou.solab.tools.SolabStringScanTool
import zhou.solab.tools.ApkArchiveTool
import zhou.solab.tools.ApkZipCache
import zhou.solab.tools.DexXrefEngine
import zhou.solab.tools.ClassOutlineEngine
import zhou.solab.tools.SmaliReadTool
import zhou.solab.engine.FieldRefsIndexStore
import zhou.solab.engine.NativeSoEngine
import zhou.solab.tools.err
import zhou.solab.tools.DexIo
import zhou.solab.tools.ApkAdRules
import zhou.solab.tools.ApkRulesStore

/** SoLab APK 的确定性本地分析入口；不上传 APK，也不执行未确认的删除。 */
class SolabChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    // ── APK ZipFile 进程级缓存 ────────────────────────────────────────────
    // 见 ApkZipCache：句柄按 path+mtime+size 指纹失效 + 引用计数 pin
    // （防 2 个 worker 轮转第 3 个 APK 时 LRU 驱逐 close 掉另一线程正在
    // 遍历的 ZipFile）。调用点一律 withApkZip，不再各自 use-close。
    @PublishedApi
    internal val apkZipCache = ApkZipCache()

    inline fun <R> withApkZip(source: File, block: (ZipFile) -> R): R =
        apkZipCache.withZip(source, block)
    private val channel = MethodChannel(messenger, "solab/workspace")
    private val mainHandler = Handler(Looper.getMainLooper())

    /** 共享工作线程池。重型 APK/SO 工具固定最多并行 2 个，避免多核手机同时
     *  展开多个 DEX/ELF 导致内存抖动和界面线程抢不到 CPU。 */
    private val workExecutor: java.util.concurrent.ExecutorService by lazy {
        java.util.concurrent.Executors.newFixedThreadPool(2)
    }

    /** 分析进度事件通道（Dart 侧监听进度条；analyze 线程内 emit）。 */
    private val progressChannel = EventChannel(messenger, "solab/progress")
    private var progressSink: EventChannel.EventSink? = null

    /** SO 引擎进度事件通道（so_analyze 长任务阶段上报）。 */
    private val soProgressChannel = EventChannel(messenger, "so_analyze/progress")
    private var soProgressSink: EventChannel.EventSink? = null

    init {
        channel.setMethodCallHandler(this)
        progressChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                progressSink = events
            }

            override fun onCancel(arguments: Any?) {
                progressSink = null
            }
        })
        soProgressChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                soProgressSink = events
            }

            override fun onCancel(arguments: Any?) {
                soProgressSink = null
            }
        })
    }

    /** 从工作线程发进度事件（主线程回调，避免线程竞争）。 */
    private fun emitProgress(percent: Int, stage: String) {
        val sink = progressSink ?: return
        mainHandler.post {
            try {
                sink.success(mapOf("percent" to percent, "stage" to stage))
            } catch (_: Exception) {}
        }
    }

    /** SO 引擎进度（阶段 + percent）。 */
    private fun emitSoProgress(percent: Int, stage: String) {
        val sink = soProgressSink ?: return
        mainHandler.post {
            try {
                sink.success(mapOf("percent" to percent, "stage" to stage, "channel" to "so"))
            } catch (_: Exception) {}
        }
    }

    /** UI 线程安全回复：通道已销毁或重复回复时吞掉异常，避免崩 App。 */
    private fun replySafely(result: MethodChannel.Result, block: () -> Unit) {
        mainHandler.post {
            try {
                block()
            } catch (_: IllegalStateException) {
                // 通道已回复或已销毁：无投递目标，静默丢弃。
            } catch (_: Exception) {
                // 陈旧回复的其它异常同样不得崩 UI 线程。
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // 打断：AI 对话停止 / 用户取消时置位；新任务入口自动 reset
            "cancelTask" -> {
                zhou.solab.tools.TaskCancel.cancel()
                result.success(mapOf("ok" to true, "cancelled" to true))
            }
            "analyzeApk" -> {
                val path = arg(call, "path") as? String
                if (path.isNullOrBlank()) {
                    result.error("invalid_args", "缺少 APK 路径", null)
                } else {
                    workExecutor.execute {
                        try {
                            // 分析保持零附加负担：字段引用索引改为惰性后台构建
                            // （首次 field_xref 时触发，不阻塞查询），见 FieldRefsIndexStore。
                            val report = analyze(File(path))
                            replySafely(result) { result.success(report) }
                        } catch (error: Exception) {
                            replySafely(result) {
                                result.error(
                                    "analyze_failed",
                                    "${error.javaClass.simpleName}: ${error.message ?: "未知分析错误"}",
                                    error.stackTraceToString(),
                                )
                            }
                        }
                    }
                }
            }

            "deleteZipEntries" -> runAsync(result) { deleteZipEntries(call) }

            "writeZipEntry" -> runAsync(result) { writeZipEntry(call) }

            "buildApk" -> runAsync(result) { buildApk(call) }

            "listLibEntries" -> runAsync(result) { listLibEntries(call) }

            "patchDexMethods" -> runAsync(result) { patchDexMethods(call) }

            "setUserRules" -> runAsync(result) { setUserRules(call) }

            "restoreSourceApk" -> runAsync(result) { restoreSourceApk(call) }

            "checkStoragePermission" -> result.success(checkStoragePermission())

            "requestStoragePermission" -> result.success(requestStoragePermission())

            "patchManifest" -> runAsync(result) { patchManifest(call) }

            "cleanAdAssets" -> runAsync(result) { cleanAdAssets(call) }

            // AI 按需分析：委托 ApkModuleAnalyzer（独立文件），一次只分析一个模块。
            "analyzeModule" -> {
                val path = arg(call, "path") as? String
                val module = arg(call, "module") as? String ?: ""
                val classPrefix = (arg(call, "classPrefix") as? String)?.trim() ?: ""
                // 问题2：methods 分页（36 dex 大包下 500 条上限配合 offset 取全量）
                val offset = (arg(call, "offset") as? Number)?.toInt() ?: 0
                val limit = (arg(call, "limit") as? Number)?.toInt() ?: 500
                if (path.isNullOrBlank()) {
                    result.error("invalid_args", "缺少 APK 路径", null)
                } else if (module !in ApkModuleAnalyzer.MODULES) {
                    result.error("invalid_module", "未知模块: $module（支持 ${ApkModuleAnalyzer.MODULES}）", null)
                } else {
                    workExecutor.execute {
                        try {
                            val payload = ApkModuleAnalyzer.analyzeModule(
                                context, File(path), module, classPrefix,
                                offset = offset, limit = limit,
                            )
                            replySafely(result) { result.success(payload) }
                        } catch (error: Exception) {
                            replySafely(result) {
                                result.error(
                                    "analyze_module_failed",
                                    "${error.javaClass.simpleName}: ${error.message ?: "分析失败"}",
                                    error.stackTraceToString(),
                                )
                            }
                        }
                    }
                }
            }

            // ===== M1: 玄星逆核工具链移植 =====
            // 信封契约：{ok:true,...} / {ok:false, error:{code,message,...}}，业务错误走 success
            "jadxDecompile" -> portedTool(call, result) { SolabJadxTool.handle(context, it) }
            "apkSign" -> portedTool(call, result) { SolabApkBuildTool.apkSign(context, it) }
            // APKEditor 长任务：劫持其日志转进度事件（分钟级 decode/build 工作台可见实时进度）
            "apkRebuild" -> {
                val args = (call.arguments as? Map<*, *>)?.let { JSONObject(it) } ?: JSONObject()
                runAsync(result) {
                    @Suppress("UNCHECKED_CAST")
                    jsonToMap(SolabApkEditorTool.handle(context, args) { pct, stage ->
                        emitProgress(pct.coerceIn(1, 100), "APKEditor: $stage")
                    }) as Map<String, Any>
                }
            }
            "dexSearch" -> cachedReadEngine(call, result, "dexSearch") { SolabDexKitTool.handle(context, it) }
            "stringScan" -> cachedReadEngine(call, result, "stringScan") { SolabStringScanTool.handle(context, it) }
            "apkArchive" -> cachedReadEngine(call, result, "apkArchive") { ApkArchiveTool.handle(it) }
            "scanSignatureCheck" -> cachedReadEngine(call, result, "scanSignatureCheck") {
                org.json.JSONObject().put("ok", true).put("hits", scanSignatureCheck(File(it.optString("path"))))
            }
            // ===== M2: 自研引擎 =====
            "dexXref" -> cachedReadEngine(call, result, "dexXref") {
                DexXrefEngine.xref(
                    context = context,
                    apkPath = it.optString("path"),
                    target = it.optString("target"),
                    direction = it.optString("direction", "to"),
                    callerPrefix = it.optString("callerPrefix").ifBlank { it.optString("classPrefix") },
                    offset = it.optInt("offset", 0),
                    limit = it.optInt("limit", 50),
                    includeGraph = it.optBoolean("includeGraph", false),
                    callSiteOffset = it.optInt("callSiteOffset", 0),
                    callSiteLimit = it.optInt("callSiteLimit", 300),
                )
            }
            "fieldXref" -> cachedReadEngine(call, result, "fieldXref") {
                DexXrefEngine.fieldXref(
                    context = context,
                    apkPath = it.optString("path"),
                    fieldTarget = it.optString("fieldTarget"),
                    offset = if (it.has("offset") && !it.isNull("offset")) it.optInt("offset") else null,
                    limit = if (it.has("limit") && !it.isNull("limit")) it.optInt("limit") else null,
                )
            }
            "classOutline" -> cachedReadEngine(call, result, "classOutline") {
                ClassOutlineEngine.outline(
                    context = context,
                    apkPath = it.optString("path"),
                    className = it.optString("className"),
                    offset = it.optInt("offset", 0),
                    limit = it.optInt("limit", 200),
                )
            }
            "smaliRead" -> portedTool(call, result) {
                SmaliReadTool.smali(
                    context = context,
                    apkPath = it.optString("path"),
                    qualifiedId = it.optString("qualifiedId"),
                )
            }
            // ===== M3: SO 引擎 =====
            "soAnalyze" -> portedTool(call, result) { soEngineDispatch(it) }
            // ===== 文件管理（读写工作目录任意格式/压缩解压）=====
            "fileOps" -> portedTool(call, result) { zhou.solab.tools.FileOpsTool.handle(it) }

            else -> result.notImplemented()
        }
    }

    private fun analyze(apk: File): Map<String, Any> {
        require(apk.isFile && apk.length() > 0) { "APK 文件不存在或为空" }
        // 输入防护（借鉴玄星 ApkAnalyzer）：超限直接拒绝，避免大包拖垮内存
        if (apk.length() > MAX_ANALYZE_BYTES) {
            throw IllegalArgumentException("APK 超过 ${MAX_ANALYZE_BYTES / 1024 / 1024} MiB 分析上限，请先精简或改用按需分析")
        }
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
        val packageInfo = context.packageManager.getPackageArchiveInfo(apk.absolutePath, flags)
        val appInfo = packageInfo?.applicationInfo?.apply {
            sourceDir = apk.absolutePath
            publicSourceDir = apk.absolutePath
        }
        // manifest 字节在主循环命中 AndroidManifest.xml 条目时顺手读入，
        // 摘要解析移到循环后（原先这里先整读一次 zip，循环后又开 ZipFile）。
        var manifestBytes: ByteArray? = null
        val rules = loadRules()
        val matchedPatterns = linkedSetOf<String>()
        val dexPatternMatches = linkedMapOf<String, List<String>>()
        val abis = linkedSetOf<String>()
        val candidates = mutableListOf<Map<String, Any>>()
        // 有界 top-20：10 万条目上限下全量累积 10 万个小 Map 再排序纯浪费。
        // （实现收敛到 ApkShared.offerLargest；调用处见下方 offerLargest(largestFiles, ...)）
        val largestFiles = mutableListOf<Map<String, Any>>()
        val nativeLibraryFiles = mutableListOf<Map<String, Any>>()
        val shellNames = linkedSetOf<String>()
        val shellLibs = mutableListOf<Map<String, Any>>()
        val fileTypeCounts = linkedMapOf<String, Int>()
        // v5 新增：DEX header 详情 / v1 签名文件 / Flutter 应用识别
        val dexDetails = mutableListOf<Map<String, Any>>()
        val v1SignatureFiles = mutableListOf<String>()
        val flutterAbis = linkedSetOf<String>()
        var flutterAssetCount = 0
        val runtimeEngines = linkedMapOf<String, MutableList<String>>()
        fun markEngine(engine: String, signal: String) {
            runtimeEngines.getOrPut(engine) { mutableListOf() }.add(signal)
        }
        var dex = 0
        var resources = 0
        var assets = 0
        var so = 0
        var totalFiles = 0
        var uncompressedBytes = 0L
        var compressedBytes = 0L

        withApkZip(apk) { zip ->
        val entryCount = zip.entries().asSequence().count { !it.isDirectory }
        emitProgress(5, "扫描 APK 结构")
        var processedEntries = 0
        zip.entries().asSequence().filterNot { it.isDirectory }.forEach { entry ->
            processedEntries++
            totalFiles++
            if (totalFiles > MAX_ANALYZE_ENTRIES) {
                throw IllegalArgumentException("APK 条目数超过 $MAX_ANALYZE_ENTRIES，超出安全分析上限")
            }
            // 进度：文件扫描 5%→85%（按条目数折算）
            if (entryCount > 0 && processedEntries % 20 == 0) {
                val percent = 5 + (80L * processedEntries / entryCount).toInt()
                emitProgress(percent.coerceIn(5, 85), "扫描文件 $processedEntries/$entryCount")
            }
                val name = entry.name
                val lower = name.lowercase(Locale.ROOT)
                val size = entry.size.coerceAtLeast(0L)
                val compressedSize = entry.compressedSize.coerceAtLeast(0L)
                uncompressedBytes += size
                compressedBytes += compressedSize
                val extension = name.substringAfterLast('.', "(none)").lowercase(Locale.ROOT)
                fileTypeCounts[extension] = (fileTypeCounts[extension] ?: 0) + 1
                offerLargest(
                    largestFiles,
                    mapOf(
                        "path" to name,
                        "size" to size,
                        "compressedSize" to compressedSize,
                    ),
                )
                when {
                    name == "AndroidManifest.xml" -> {
                        runCatching {
                            manifestBytes = zip.getInputStream(entry).use { it.readBytes() }
                        }
                    }

                    lower.endsWith(".dex") -> {
                        dex++
                        val stream = zip.getInputStream(entry)
                        try {
                            val headerBytes = ByteArray(0x70)
                            var headerOff = 0
                            while (headerOff < headerBytes.size) {
                                val r = stream.read(headerBytes, headerOff, headerBytes.size - headerOff)
                                if (r < 0) break
                                headerOff += r
                            }
                            dexDetails += parseDexHeaderBytes(headerBytes, name)
                            val entryMatches = ApkPatternScanner.scan(stream, rules.searchPatterns)
                            if (entryMatches.isNotEmpty()) {
                                matchedPatterns += entryMatches
                                dexPatternMatches[name] = entryMatches.sorted()
                            }
                        } finally {
                            stream.close()
                        }
                    }

                    lower.startsWith("assets/flutter_assets/") -> {
                        flutterAssetCount++
                        markEngine("Flutter", "assets/flutter_assets/")
                    }

                    lower.startsWith("assets/index.android.bundle") ->
                        markEngine("React Native", "assets/index.android.bundle")

                    lower.startsWith("assets/www/") -> markEngine("H5 Hybrid", "assets/www/")

                    lower.contains("global-metadata.dat") ->
                        markEngine("Unity IL2CPP", "global-metadata.dat")

                    lower.startsWith("assets/bin/data/managed/") && lower.endsWith(".dll") ->
                        markEngine("Unity Mono", "assets/bin/Data/Managed/*.dll")

                    lower.endsWith(".jsc") || lower.startsWith("assets/src/") ->
                        markEngine("Cocos Creator", "${entry.name}")

                    lower.startsWith("res/") -> resources++
                    lower.startsWith("assets/") -> assets++
                    lower.startsWith("lib/") && lower.endsWith(".so") -> {
                        so++
                        name.split('/').getOrNull(1)?.let(abis::add)
                        nativeLibraryFiles += mapOf("path" to name, "size" to size)
                        // Flutter 应用识别：libapp.so / libflutter.so 存在即 AOT 模式
                        val soName = name.substringAfterLast('/').lowercase(Locale.ROOT)
                        if (soName == "libapp.so" || soName == "libflutter.so") {
                            name.split('/').getOrNull(1)?.let(flutterAbis::add)
                            markEngine("Flutter", soName)
                        }
                        if (soName == "libil2cpp.so") {
                            markEngine("Unity IL2CPP", soName)
                        }
                        if (soName == "libmonodroid.so") {
                            markEngine("Xamarin/MAUI", soName)
                        }
                        if (soName == "libcocos2djs.so") {
                            markEngine("Cocos Creator", soName)
                        }
                        // 加固壳检测：lib/*/lib*.so 文件名子串匹配（大小写不敏感）
                        for ((signature, label) in mergedShellSignatures()) {
                            if (soName.contains(signature)) {
                                shellNames += label
                                shellLibs += mapOf("path" to name, "shell" to label, "size" to size)
                            }
                        }
                    }
                }
                // v1 签名文件枚举（JAR 签名：.RSA/.DSA/.EC/.SF/MANIFEST.MF）
                if (lower.startsWith("meta-inf/") &&
                    (lower.endsWith(".rsa") || lower.endsWith(".dsa") || lower.endsWith(".ec") ||
                        lower.endsWith(".sf") || lower.endsWith("manifest.mf"))
                ) {
                    v1SignatureFiles += name
                }
                val safety = when {
                    size == 0L -> "safe"
                    lower.endsWith(".proto") || lower.endsWith(".pb") ||
                        lower.endsWith(".bin") -> "review"
                    lower.startsWith("lib/") && lower.endsWith(".so") -> "high_risk"
                    lower.startsWith("../") || lower.contains("/../") ||
                        lower.startsWith('/') -> "high_risk"
                    else -> null
                }
                if (safety != null) {
                    candidates += mapOf(
                        "path" to name,
                        "size" to size,
                        "safety" to safety,
                        "reason" to when {
                            size == 0L -> "空文件"
                            lower.endsWith(".proto") || lower.endsWith(".pb") ||
                                lower.endsWith(".bin") -> "未知配置文件，需检查 DEX 和动态路径引用"
                            lower.endsWith(".so") -> "原生库可能由 JNI 或动态路径加载"
                            else -> "ZIP 路径异常，需检查打包安全性"
                        },
                    )
                }
            }
        }
        emitProgress(90, "解析组件与权限")
        val signatureCheckHits = scanSignatureCheck(apk)
        emitProgress(92, "扫描签名校验")
        val manifestSummary = manifestBytes?.let { bytes ->
            runCatching { ApkAxmlEditor.readManifestSummary(bytes) }.getOrNull()
        }

        val activities = packageInfo?.activities?.mapNotNull { it.name }
            ?: manifestSummary?.components
                ?.filter { it.tag == "activity" || it.tag == "activity-alias" }
                ?.map { it.name }
            ?: emptyList()
        val services = packageInfo?.services?.mapNotNull { it.name }
            ?: manifestSummary?.components?.filter { it.tag == "service" }?.map { it.name }
            ?: emptyList()
        val receivers = packageInfo?.receivers?.mapNotNull { it.name }
            ?: manifestSummary?.components?.filter { it.tag == "receiver" }?.map { it.name }
            ?: emptyList()
        val providers = packageInfo?.providers?.mapNotNull { it.name }
            ?: manifestSummary?.components?.filter { it.tag == "provider" }?.map { it.name }
            ?: emptyList()
        val exportedComponents = if (packageInfo != null) {
            buildList<Map<String, String>> {
                addExported("activity", packageInfo.activities)
                addExported("service", packageInfo.services)
                addExported("receiver", packageInfo.receivers)
                addExported("provider", packageInfo.providers)
            }
        } else {
            manifestSummary?.components
                ?.filter { it.exported == true }
                ?.map { mapOf("type" to it.tag, "name" to it.name) }
                ?: emptyList()
        }
        val permissions = packageInfo?.requestedPermissions?.toList()
            ?: manifestSummary?.permissions
            ?: emptyList()
        val dangerousPermissions = permissions.filter { it in ApkRulesStore.highRiskPermissions }
        val componentText = (activities + services + receivers + providers)
            .joinToString("\n")
            .lowercase(Locale.ROOT)
        val adSdkStringMatches = matchedPatterns.filter { it in rules.sdkPackageSet }.sorted()
        val dexSdkClassMatches = linkedSetOf<String>()
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
                            dexSdkClassMatches += rule
                        }
                    }
                }
            }
        }
        val componentSdkMatches = rules.sdkPackages.filter { componentText.contains(it) }
        val componentClassMatches = rules.classPatterns.filter { componentText.contains(it) }
        val adSdkMatches = (dexSdkClassMatches + componentSdkMatches)
            .distinct()
            .sorted()
        val adClassMatches = (matchedPatterns.filter { it in rules.classPatternSet } + componentClassMatches)
            .distinct()
            .sorted()
        // 入口方法（init*/register*/manager*）：改一处可杜绝一类，优先改。
        val adEntryMethodMatches = matchedPatterns.filter { it in rules.entryMethodSet }.sorted()
        // 普通方法命中（load/show 等调用点）：需逐个改，非入口。
        val adMethodMatches = matchedPatterns
            .filter { it in rules.methodPatternSet && it !in rules.entryMethodSet }
            .sorted()
        val adUrlMatches = matchedPatterns.filter { it in rules.urlPatternSet }.sorted()
        val vipMethodCandidates = matchedPatterns.filter { it in rules.forceTrueMethodSet }.sorted()
        val timeMethodCandidates = matchedPatterns.filter { it in rules.timeMethodSet }.sorted()
        val certificateSha256 = signingCertificateSha256(packageInfo)
        val metadata = appInfo?.metaData?.keySet()?.sorted()
            ?: manifestSummary?.metaData?.map { it.name }?.sorted()
            ?: emptyList()
        val appLabel = runCatching {
            appInfo?.loadLabel(context.packageManager)?.toString().orEmpty()
        }.getOrDefault("").ifEmpty { manifestSummary?.appLabel.orEmpty() }
        // 一次读文件解析 v2/v3 签名块（避免两次 RandomAccessFile 开销）。
        val signingSchemes = signingSchemeFlags(apk)
        val localSchemeUnreliable = signingSchemes[0] == false &&
            signingSchemes[1] == false && v1SignatureFiles.isNotEmpty()

        emitProgress(100, "分析完成")
        // sha256 整包流式读一遍只算一次（大包 IO 明显），两处共用。
        val apkSha256 = sha256(apk)
        return mapOf(
            "analysisVersion" to 18,
            "path" to apk.absolutePath,
            "fileName" to apk.name,
            "appLabel" to appLabel,
            "size" to apk.length(),
            "sha256" to apkSha256,
            // T1：sourceApk 供报告一致性核对（文件名 + sha256 + 分析时间）
            "sourceApk" to mapOf(
                "path" to apk.absolutePath,
                "fileName" to apk.name,
                "sha256" to apkSha256,
                "size" to apk.length(),
                "lastModified" to apk.lastModified(),
                "analyzedAt" to System.currentTimeMillis(),
            ),
            "certificateSha256" to certificateSha256,
            "packageName" to (packageInfo?.packageName ?: manifestSummary?.packageName.orEmpty()),
            "versionName" to (packageInfo?.versionName ?: manifestSummary?.versionName.orEmpty()),
            "versionCode" to if (packageInfo == null) manifestSummary?.versionCode ?: 0L else if (
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
            ) packageInfo.longVersionCode else {
                @Suppress("DEPRECATION")
                packageInfo.versionCode.toLong()
            },
            "minSdk" to (appInfo?.minSdkVersion ?: manifestSummary?.minSdk ?: 0),
            "targetSdk" to (appInfo?.targetSdkVersion ?: manifestSummary?.targetSdk ?: 0),
            "debuggable" to if (appInfo != null) {
                appInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
            } else {
                manifestSummary?.debuggable ?: false
            },
            "allowBackup" to if (appInfo != null) {
                appInfo.flags and ApplicationInfo.FLAG_ALLOW_BACKUP != 0
            } else {
                manifestSummary?.allowBackup ?: false
            },
            "metaData" to metadata,
            "permissions" to permissions,
            "dangerousPermissions" to dangerousPermissions,
            "activities" to activities,
            "services" to services,
            "receivers" to receivers,
            "providers" to providers,
            "exportedComponents" to exportedComponents,
            "totalFiles" to totalFiles,
            "uncompressedBytes" to uncompressedBytes,
            "compressedBytes" to compressedBytes,
            "compressionRatio" to if (uncompressedBytes == 0L) 1.0 else
                compressedBytes.toDouble() / uncompressedBytes.toDouble(),
            "dexFiles" to dex,
            "dexDetails" to dexDetails,
            "resourceFiles" to resources,
            "assetFiles" to assets,
            "nativeLibraries" to so,
            "abis" to abis.toList(),
            "flutterApp" to mapOf(
                "detected" to (flutterAbis.isNotEmpty() || flutterAssetCount > 0),
                "abis" to flutterAbis.toList(),
                "assetCount" to flutterAssetCount,
                "engine" to if (flutterAbis.isNotEmpty() || flutterAssetCount > 0) "aot" else "unknown",
                // P0-1 双轨道路由：Flutter=双层逻辑，按目标所属层选工具链
                // A. Dart 业务层（会员/VIP/播放器UI/业务判定）→ libapp.so（Dart AOT）
                // B. 原生层（广告SDK/下载/权限/系统调用）→ dex+assets+Manifest
                "dualTrackRouting" to if (flutterAbis.isNotEmpty() || flutterAssetCount > 0) mapOf(
                    "dartLayer" to "Dart 业务判定 → libapp.so：blutter locate 收敛语义键；字段名被混淆或判断函数脱钩时用 trace 追踪键引用→字段写入→读取→寄存器消费，只把进入比较、分支或返回的 high/medium 候选交给验证",
                    "nativeLayer" to "原生业务 → dex_search(auto) 自动组合并切换类、方法、字段、字符串、数字和指令证据 → 按 nextActions 验证真实代码与调用关系 → patch_apk_dex_methods / patch_apk_manifest",
                    "rule" to "修改位置因版本和混淆而异：名称与用户提示只作线索，工具必须用字段数据流、常量、返回语义和调用位置验证后再修改；Dart 业务在 dex 搜不到是正常现象",
                ) else emptyMap<String, String>(),
            ),
            "runtimeEngines" to runtimeEngines.map { (engine, signals) ->
                mapOf("engine" to engine, "signals" to signals.distinct())
            },
            "signingScheme" to mapOf(
                "v1" to v1SignatureFiles.isNotEmpty(),
                "v2" to if (localSchemeUnreliable) "unknown" else signingSchemes[0],
                "v3" to if (localSchemeUnreliable) "unknown" else signingSchemes[1],
                "v1SignatureFiles" to v1SignatureFiles,
                // B1 兜底：本地 v2/v3 均未检出而 v1 存在时，判定不可靠
                // （解析对异常布局可能漏检），标记后调用方应以 MT 验签为准
                "localSchemeUnreliable" to localSchemeUnreliable,
                "note" to if (localSchemeUnreliable) {
                    "本地无法可靠判断 v2/v3，已输出 unknown；以 MT 验签为准"
                } else {
                    "v1 由 META-INF JAR 签名文件枚举判定；v2/v3 由 APK Signing Block 头部解析（magic 'APK Sig Block 42' 下的 v2/v3 块）"
                },
            ),
            // 签名校验检测：命中说明重打包签名后可能闪退，修改时启用签名兼容注入。
            "signatureCheck" to mapOf(
                "detected" to false,
                "hits" to signatureCheckHits,
                "stringHints" to signatureCheckHits,
                "hitLevel" to "string_hint",
                "methodLevelConfirmed" to false,
                "requiresMethodVerification" to signatureCheckHits.isNotEmpty(),
                "note" to "字符串可能来自微信/支付等第三方 SDK，不能证明 App 自校验。交给 dex_search(auto) 自动定位使用者并验证真实代码；只有确认读取自身签名并参与放行/退出分支时才判定。",
                "risk" to if (signatureCheckHits.isNotEmpty()) {
                    "存在待验证字符串线索，尚未确认重打包风险"
                } else {
                    "未检测到常见签名校验特征"
                },
            ),
            "fileTypeCounts" to fileTypeCounts.entries
                .sortedByDescending { it.value }
                .associate { it.key to it.value },
            "largestFiles" to largestFiles.sortedByDescending { (it["size"] as Long) },
            "nativeLibraryFiles" to nativeLibraryFiles.sortedByDescending { (it["size"] as Long) },
            "shellPacking" to mapOf(
                "detected" to shellNames.isNotEmpty(),
                "shells" to shellNames.toList(),
                "libs" to shellLibs,
            ),
            "adSdkMatches" to adSdkMatches,
            "adSdkStringMatches" to adSdkStringMatches,
            "adClassMatches" to adClassMatches,
            "adEntryMethodMatches" to adEntryMethodMatches,
            "adMethodMatches" to adMethodMatches,
            "adUrlMatches" to adUrlMatches,
            "vipMethodCandidates" to vipMethodCandidates,
            "timeMethodCandidates" to timeMethodCandidates,
            "dexPatternMatches" to dexPatternMatches.map { (dexName, patterns) ->
                mapOf("dex" to dexName, "patterns" to patterns)
            },
            "ruleStats" to mapOf(
                "sdkPackages" to rules.sdkPackages.size,
                "classPatterns" to rules.classPatterns.size,
                "methodPatterns" to rules.methodPatterns.size,
                "urlPatterns" to rules.urlPatterns.size,
                "forceTrueMethods" to rules.forceTrueMethods.size,
                "timeMethods" to rules.timeMethods.size,
                "totalSearchPatterns" to rules.searchPatterns.size,
            ),
            "candidates" to candidates.sortedWith(
                compareBy<Map<String, Any>> { ApkRulesStore.safetyOrder[it["safety"]] ?: 9 }
                    .thenByDescending { it["size"] as Long },
            ),
        )
    }

    private fun MutableList<Map<String, String>>.addExported(
        type: String,
        components: Array<out ComponentInfo>?,
    ) {
        components?.filter { it.exported }?.forEach {
            add(mapOf("type" to type, "name" to it.name))
        }
    }

    private fun loadRules(): ApkAdRules = ApkRulesStore.load(context)

    /** 用户自定义规则的原生私有 SP（经 setUserRules 通道写入）。 */
    private fun userRulesPrefs() =
        context.getSharedPreferences("apk_mod_user_rules", Context.MODE_PRIVATE)

    /** 核心 SO 白名单：应用运行必需，精确删除也拦（广告 SDK 的 so 不在其中，可删）。 */
    private fun isCoreSo(name: String): Boolean {
        val soName = name.substringAfterLast('/').lowercase(Locale.ROOT)
        if (!name.startsWith("lib/") || !soName.endsWith(".so")) return false
        // Flutter 引擎 + 加固壳，删除必崩。
        if (soName == "libflutter.so" || soName == "libapp.so") return true
        for ((signature, _) in mergedShellSignatures()) {
            if (soName.contains(signature)) return true
        }
        return false
    }

    /** 检查是否有写公共存储的权限（Android 11+ 需「所有文件访问」）。 */
    private fun checkStoragePermission(): Map<String, Any> {
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            @Suppress("DEPRECATION")
            context.checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }
        return mapOf("granted" to granted)
    }

    /** 跳转系统设置页，引导用户授予「所有文件访问」权限。 */
    private fun requestStoragePermission(): Map<String, Any> {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val intent = Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.fromParts("package", context.packageName, null),
                )
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
            } else {
                @Suppress("DEPRECATION")
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                intent.data = Uri.fromParts("package", context.packageName, null)
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
            }
            mapOf("ok" to true)
        } catch (error: Exception) {
            mapOf("ok" to false, "error" to (error.message ?: "无法打开设置页"))
        }
    }

    /**
     * 一键回滚：把源 APK（已知良好的已签名原版）复制到输出目录，
     * 命名 <原名>_original.apk。源包从未被修改，这是最可靠的回滚方式。
     */
    private fun restoreSourceApk(call: MethodCall): Map<String, Any> {
        val source = resolveSource(call)
        // 输出目录必填：与 structuralOutput 一致，避免落到内部 cache。
        val outputDir = outputDirArg(call)
            ?: throw StructuralError(
                "output_dir_required",
                "请先在 APK 工作台设置「工作目录」（需与 MT 工作目录一致）",
            )
        val dirFile = File(outputDir)
        if (!dirFile.isDirectory) {
            throw StructuralError("invalid_output_dir", "输出目录不存在: $outputDir")
        }
        val name = "${source.nameWithoutExtension}_original.apk"
        val target = File(dirFile, name)
        source.copyTo(target, overwrite = true)
        return mapOf(
            "ok" to true,
            "outputPath" to target.absolutePath,
            "message" to "已把原版（已签名）复制到工作目录，可直接安装回滚",
        )
    }

    /** 用户自定义壳特征（so 文件名 → 壳名），经 setUserRules 的 shell_signatures 键写入。 */
    private fun userShellSignatures(): Map<String, String> {
        val custom = userRulesPrefs().getStringSet("shell_signatures", emptySet())
            ?: return emptyMap()
        val result = linkedMapOf<String, String>()
        for (raw in custom) {
            // 格式：so文件名=壳名（如 libmyshell.so=自研壳）
            val eq = raw.indexOf('=')
            if (eq > 0) {
                val so = raw.substring(0, eq).trim().lowercase(Locale.ROOT)
                val label = raw.substring(eq + 1).trim()
                if (so.isNotEmpty() && label.isNotEmpty()) result[so] = label
            }
        }
        return result
    }

    /** 合并后的壳特征（内置 + 用户自定义，用户优先同名覆盖）。 */
    private fun mergedShellSignatures(): Map<String, String> =
        ApkRulesStore.shellSignatures + userShellSignatures()

    /**
     * 用户规则同步入口：Dart 规则库在 syncRulesToPreferences 后调用，
     * 把启用中的规则全量推给原生（避免直接读 FlutterSharedPreferences 的
     * flutter. 前缀文件）。以 Set 存储，读侧统一小写去重。
     */
    private fun setUserRules(call: MethodCall): Map<String, Any> {
        val raw = arg(call, "rules") as? Map<*, *> ?: return mapOf(
            "ok" to false,
            "error" to "invalid_args",
            "message" to "缺少 rules 参数",
        )
        val prefs = userRulesPrefs()
        val editor = prefs.edit()
        for ((key, value) in raw) {
            val list = (value as? List<*>)?.mapNotNull { it as? String } ?: emptyList()
            editor.putStringSet(key.toString(), list.toSet())
        }
        editor.apply()
        // 用户规则变更 → 失效缓存，下次 loadRules 重新合并。
        ApkRulesStore.invalidate()
        return mapOf("ok" to true, "storedKeys" to raw.keys.size)
    }

    private val SIGNATURE_CHECK_KEYWORDS = listOf(
        "get_signatures", "getsignatures", "checksignature", "checkappsignature",
        "verifysignature", "signaturevalid", "appsignature", "signaturedigest",
        "signingcertificate", "signinginfo", "getpackagesignature", "packagesignature",
        "signature.tobytearray", "getsigningcertificates", "signaturecheck", "signatureverify",
    )

    private fun scanSignatureCheck(source: File): List<String> {
        val matched = linkedSetOf<String>()
        withApkZip(source) { zip ->
            zip.entries().asSequence().filterNot { it.isDirectory }
                .filter { it.name.lowercase(Locale.ROOT).endsWith(".dex") }
                .forEach { entry ->
                    val hits = zip.getInputStream(entry).use { input ->
                        ApkAhoCorasick(SIGNATURE_CHECK_KEYWORDS).scanStream(input)
                    }
                    matched += hits
                }
        }
        return matched.sorted()
    }

    /**
     * 解析 DEX 头部（借鉴玄星 ApkAnalyzer.parseDexHeader）：只读前 0x70 字节，
     * 解析 magic/版本/校验标志/各 id 表数量。零全量 IO、不加载 dexlib2。
     * 入参为已读入的头部字节（由调用方在流上先读 0x70，避免流二次打开）。
     */
    private fun parseDexHeaderBytes(header: ByteArray, entryName: String): Map<String, Any> {
        fun u32(at: Int): Long {
            if (at + 4 > header.size) return 0
            return (header[at].toLong() and 0xff) or
                ((header[at + 1].toLong() and 0xff) shl 8) or
                ((header[at + 2].toLong() and 0xff) shl 16) or
                ((header[at + 3].toLong() and 0xff) shl 24)
        }
        val magic = if (header.size >= 8) {
            String(header.copyOfRange(0, 8), Charsets.ISO_8859_1).replace("\u0000", "\\0")
        } else {
            ""
        }
        val valid = header.size >= 0x70 && header[0] == 'd'.code.toByte() &&
            header[1] == 'e'.code.toByte() && header[2] == 'x'.code.toByte() &&
            header[3] == '\n'.code.toByte()
        return mapOf(
            "entry" to entryName,
            "magic" to magic,
            "valid" to valid,
            "fileSize" to u32(0x20),
            "headerSize" to u32(0x24),
            "endianTag" to "0x${u32(0x28).toString(16)}",
            "stringIds" to u32(0x38),
            "typeIds" to u32(0x40),
            "protoIds" to u32(0x48),
            "fieldIds" to u32(0x50),
            "methodIds" to u32(0x58),
            "classDefs" to u32(0x60),
        )
    }

    // ---- 结构级操作执行器（deleteZipEntries / writeZipEntry / buildApk）----

    private data class EntryOp(
        val locator: String,
        val name: String,
        val action: String,
        val content: ByteArray?,
        val contentFile: File?,
        val contentSource: String,
    )

    private class StructuralError(val stage: String, message: String) : RuntimeException(message)

    /** 在后台线程执行结构操作；错误统一返回 {ok:false, error, message}，不产出半成品。 */
    private fun runAsync(result: MethodChannel.Result, block: () -> Map<String, Any>) {
        zhou.solab.tools.TaskCancel.reset()
        workExecutor.execute {
            try {
                val payload = block()
                replySafely(result) { result.success(payload) }
            } catch (error: java.util.concurrent.CancellationException) {
                replySafely(result) {
                    result.success(mapOf("ok" to false, "error" to "TASK_CANCELLED", "message" to "任务已被打断（对话停止或手动取消）"))
                }
            } catch (error: StructuralError) {
                replySafely(result) {
                    result.success(mapOf("ok" to false, "error" to error.stage, "message" to error.message))
                }
            } catch (error: Exception) {
                replySafely(result) {
                    result.success(
                        mapOf(
                            "ok" to false,
                            "error" to "structural_failed",
                            "message" to "${error.javaClass.simpleName}: ${error.message ?: "未知错误"}",
                        ),
                    )
                }
            }
        }
    }

    /** 从方法参数 Map 中取指定 key 的值（K2 对 Java 泛型方法 argument<T> 推断有缺陷，改用此模式）。 */
    private fun arg(call: MethodCall, key: String): Any? =
        (call.arguments as? Map<*, *>)?.get(key)

    /** M1 移植工具统一分发：参数转 JSONObject，返回信封 JSON 转 Map（MethodChannel 不支持 org.json 类型）。 */

    // ── 只读引擎结果缓存（dex 层） ────────────────────────────────────
    // dexSearch/stringScan/xref/outline 对同一 (参数, APK 状态) 的重复调用
    // （agent 收窄查询 / 重试 / 多轮追问）成本是整包扫描级。LRU=12，键含
    // path+mtime+size：任何补丁/重打包后自动失效。
    private val readEngineCache = LinkedHashMap<String, String>(16, 0.75f, true)

    private fun cacheKey(action: String, args: JSONObject, sourcePath: String?): String {
        val src = if (sourcePath.isNullOrBlank()) "" else {
            val f = java.io.File(sourcePath)
            "${f.canonicalPath}|${f.lastModified()}|${f.length()}"
        }
        return "$action|$src|${args}"
    }

    private fun cachedReadEngine(
        call: MethodCall,
        result: MethodChannel.Result,
        action: String,
        invoke: (JSONObject) -> JSONObject,
    ) {
        val args = (call.arguments as? Map<*, *>)?.let { JSONObject(it) } ?: JSONObject()
        val key = cacheKey("read:$action", args, args.optString("path"))
        synchronized(readEngineCache) { readEngineCache[key] }?.let { hit ->
            runAsync(result) { jsonToMap(JSONObject(hit)) as Map<String, Any> }
            return
        }
        runAsync(result) {
            val out = invoke(args).toString()
            synchronized(readEngineCache) {
                readEngineCache[key] = out
                while (readEngineCache.size > 12) readEngineCache.remove(readEngineCache.keys.first())
            }
            jsonToMap(JSONObject(out)) as Map<String, Any>
        }
    }

    private fun portedTool(
        call: MethodCall,
        result: MethodChannel.Result,
        invoke: (JSONObject) -> JSONObject,
    ) {
        val args = (call.arguments as? Map<*, *>)?.let { JSONObject(it) } ?: JSONObject()
        // 泛型擦除下 Any?→Any 转换运行时安全（值非空已由 jsonValue 归一）
        runAsync(result) { jsonToMap(invoke(args)) as Map<String, Any> }
    }

    /** M3: SO 引擎单例（工作区状态跨调用保持）。 */
    private val soEngine: NativeSoEngine by lazy { NativeSoEngine.shared(context) }

    /**
     * edit_* 的 edits 参数归一化：模型可能传 string[]（每项 JSON 文本）或 object[]，
     * 部分 Android 版本 JSONObject(Map) 也不递归 wrap 嵌套 List。统一转成
     * JSONArray[JSONObject]，非法元素返回结构化错误而不是抛 JSONException。
     */
    private fun normalizeEdits(args: JSONObject): JSONArray {
        fun wrapItem(item: Any?): Any = when (item) {
            is JSONObject, is String, is Number, is Boolean -> item
            is Map<*, *> -> JSONObject(item)
            is List<*> -> JSONArray(item)
            null -> JSONObject.NULL
            else -> item.toString()
        }
        val raw = args.opt("edits")
        if (raw == null) {
            val direct = JSONObject()
            listOf(
                "mode", "value", "returnType", "writeAsm", "newAsm", "asm",
                "assembly", "byteLength", "instructionCount", "instructionIndex",
                "byteOffset", "offset", "address", "overrideStackCheck",
            ).forEach { key -> if (args.has(key)) direct.put(key, args.opt(key)) }
            return if (direct.length() == 0) JSONArray() else JSONArray().put(direct)
        }
        val src: JSONArray = when (raw) {
            is JSONArray -> raw
            is List<*> -> JSONArray(raw.map(::wrapItem))
            is String -> runCatching { JSONArray(raw) }.getOrElse { return JSONArray() }
            else -> JSONArray()
        }
        val out = JSONArray()
        for (i in 0 until src.length()) {
            val item = src.opt(i)
            out.put(
                when (item) {
                    is JSONObject -> item
                    is String -> runCatching { JSONObject(item) }.getOrElse {
                        throw IllegalArgumentException("edits[$i] is a string but not a valid JSON object: ${item.take(120)}")
                    }
                    is Map<*, *> -> JSONObject(item)
                    else -> throw IllegalArgumentException("edits[$i] must be a JSON object, got ${item?.javaClass?.simpleName ?: "null"}")
                },
            )
        }
        return out
    }

    /** M3: SO 引擎分发（完整域：workspace/read/edit/emulate/backend/blutter）。 */
    private fun soEngineDispatch(args: JSONObject): JSONObject {
        val action = args.optString("action", "open")
        val start = System.nanoTime()
        zhou.solab.tools.TaskCancel.check()
        emitSoProgress(5, "so_analyze:$action")
        val result = dispatchSoAction(args, action)
        emitSoProgress(100, "so_analyze:$action:done")
        val micros = (System.nanoTime() - start) / 1000
        zhou.solab.tools.KotlinToolStats.record(
            "so_analyze:$action",
            result.optBoolean("ok"),
            micros,
            result.optJSONObject("error")?.optString("message").orEmpty(),
        )
        return result
    }

    private fun dispatchSoAction(args: JSONObject, action: String): JSONObject {
        val ws = args.optString("workspaceId")
        val es = args.optString("editSessionId")
        return when (action) {
            // workspace
            "set_work_dir" -> {
                // 统一工作路径：Dart 侧把 APK 工作目录同步给 SO 引擎（path 模式，免 SAF）
                val dir = args.optString("path").ifBlank { args.optString("workDir") }
                if (dir.isBlank()) err("INVALID_ARGUMENT", "缺少 path(工作目录)", "path", "")
                else {
                    soEngine.setWorkDirectoryPath(dir)
                    zhou.solab.tools.ok(JSONObject().put("workDir", dir).put("pathMode", true))
                }
            }
            "open" -> soEngine.open(args.optString("path"), args.optBoolean("temporary", true))
            // 下载远程 SO 到工作目录后打开（引擎 openUrl 一直有，此前分发层漏接）
            "open_url" -> soEngine.openUrl(args.optString("url"), args.optString("outputName"), args.optBoolean("temporary", false))
            "workspaces" -> soEngine.listWorkspaces()
            "close" -> soEngine.close(ws)
            "list_sources" -> soEngine.listAvailableSos(args.optString("prefix"), args.optInt("limit", 50), args.optString("cursor"))
            "analyze_apk" -> soEngine.analyzeApk(args.optString("path"), args.optInt("entryLimit", 500))
            // read
            "read_elf" -> soEngine.readElf(ws, es)
            "crypto_scan" -> soEngine.cryptoScan(ws, es)
            "jni_bridge" -> soEngine.jniBridge(ws, es)
            "read_stats" -> soEngine.readStats(ws, es)
            "disasm" -> soEngine.disasm(ws, es, locatorOrVa(args), args.optInt("limit", 100), args.optString("cursor"), args.optInt("instructionOffset"), args.optInt("byteOffset"), args.optInt("maxBytes", args.optInt("bytes", 4096)), args.optString("addr").ifBlank { args.optString("va") }, if (args.has("thumb")) args.optBoolean("thumb") else null, args.optString("mode", "auto"), args.optString("vaEnd"), args.optBoolean("includePseudocode", false))
            "hexdump" -> soEngine.hexdump(ws, es, locatorOrVa(args), args.optInt("byteOffset"), args.optInt("maxBytes", 512))
            "strings" -> soEngine.strings(ws, es, args.optString("locator"), args.optString("prefix"), args.optInt("limit", 100), cursor = args.optString("cursor"), regex = args.optBoolean("regex"), ignoreCase = args.optBoolean("ignoreCase", true), encoding = args.optString("encoding"), minConfidence = args.optDouble("minConfidence", 0.0))
            "search" -> soEngine.search(ws, es, args.optString("target", "overview"), args.optString("query"), args.optInt("limit", 50), args.optString("pathHint"), args.optString("cursor"))
            "list" -> soEngine.list(ws, es, args.optString("view", "sections"), args.optString("prefix"), args.optInt("limit", 100), args.optString("pathHint"), args.optString("cursor"))
            "overview" -> soEngine.overview(ws, es)
            "analysis_report" -> soEngine.analysisReport(ws, es, args.optBoolean("writeToFile", true))
            // edit session
            "edit_open" -> soEngine.editOpen(ws)
            "edit_snapshot" -> soEngine.editSnapshot(ws, es, args.optString("label"))
            "edit_rollback" -> args.optString("snapshotId").takeIf { it.isNotBlank() }
                ?.let { soEngine.editRollbackById(ws, es, it) }
                ?: soEngine.editRollback(ws, es, args.optInt("snapshotIndex", -1))
            "edit_undo" -> soEngine.editUndo(ws, es, args.optInt("count", 1))
            "edit_redo" -> soEngine.editRedo(ws, es, args.optInt("count", 1))
            "edit_reset" -> soEngine.editReset(ws, es)
            "edit_hex" -> {
                // VA 模式：va+patchHex 走会话内 VA 补丁（有 dryRun/审计/undo，比 lief_patch_address 更安全）
                val vaStr = args.optString("va")
                if (vaStr.isNotBlank()) {
                    val va = zhou.solab.tools.HexCodec.long(vaStr)
                        ?: return err("INVALID_ARGUMENT", "va must be a hex address", "va", vaStr)
                    val patch = zhou.solab.tools.HexCodec.bytes(args.optString("patchHex"))
                        ?: return err("INVALID_HEX", "patchHex must contain valid byte pairs", "patchHex", args.optString("patchHex"))
                    soEngine.editHexVa(ws, es, va, patch, args.optBoolean("dryRun", true), args.optString("targetVersion"))
                } else {
                    soEngine.editHex(ws, es, args.optString("locator"), normalizeEdits(args), args.optBoolean("dryRun", true), args.optString("targetVersion"))
                }
            }
            "edit_asm" -> soEngine.editAsm(ws, es, locatorOrVa(args), normalizeEdits(args), args.optBoolean("dryRun", true), args.optString("targetVersion"))
            "edit_symbol" -> soEngine.editSymbol(ws, es, args.optString("locator"), normalizeEdits(args), args.optBoolean("dryRun", true), args.optString("targetVersion"))
            "edit_check" -> soEngine.editCheck(ws, es)
            "fix_sections" -> soEngine.fixSections(ws, es)
            // build/diff/audit
            "build" -> soEngine.build(ws, es, args.optString("outputName", "patched.so"), args.optString("conflictStrategy"), if (args.has("writeReport")) args.optBoolean("writeReport") else null, if (args.has("writeToWorkDir")) args.optBoolean("writeToWorkDir") else null)
            // 多变体构建（一次输出多个补丁变体，引擎 buildMany 此前分发层漏接）
            "build_many" -> soEngine.buildMany(ws, es, args.optJSONArray("outputs") ?: JSONArray(), args.optString("conflictStrategy"), if (args.has("writeReport")) args.optBoolean("writeReport") else null, if (args.has("writeToWorkDir")) args.optBoolean("writeToWorkDir") else null)
            "list_builds" -> soEngine.listBuildOutputs(args.optString("prefix"), args.optInt("limit", 200))
            "diff" -> soEngine.diff(ws, es, args.optInt("limit", 200), args.optString("compareSessionId"), args.optString("compareWorkspaceId"))
            // 两个工作区结构化对比（Rizin 字节级 + 函数相似度，引擎 rzDiff 此前分发层漏接）
            "rz_diff" -> soEngine.rzDiff(ws, es, args.optString("workspaceIdB"), args.optString("editSessionIdB"))
            "audit" -> soEngine.editAudit(ws, es)
            // 审计持久化/回读（引擎 persistAudit/loadAudit 此前分发层漏接）
            "audit_persist" -> soEngine.persistAudit(ws, es)
            "audit_load" -> soEngine.loadAudit(args.optString("file"))
            "list_audits" -> soEngine.listAudits(args.optString("prefix"), args.optInt("limit", 100))
            // backend
            "rz_functions" -> soEngine.rzFunctions(ws, es, args.optInt("limit", 100), args.optString("cursor"), args.optInt("offset"))
            "rz_xrefs" -> soEngine.rzXrefs(ws, es, args.optString("locator").ifBlank { args.optString("target") }.ifBlank { args.optString("addr") }.ifBlank { args.optString("va") }, args.optString("direction", "to"))
            "rz_decompile" -> soEngine.rzDecompile(ws, es, args.optString("locator"), args.optBoolean("strict", true))
            "rz_crypto" -> soEngine.rzScanCrypto(ws, es)
            "rz_cfg" -> soEngine.rzCfg(ws, es, args.optString("locator"))
            "rz_esil" -> soEngine.rzEsilStep(ws, es, args.optString("locator"), args.optInt("stepCount", 1))
            "rz_search_bytes" -> soEngine.rzSearchBytes(ws, es, args.optString("pattern"), zhou.solab.tools.HexCodec.long(args.optString("fromVa")) ?: 0L, zhou.solab.tools.HexCodec.long(args.optString("toVa")) ?: 0L)
            "rz_command" -> soEngine.rzCommand(ws, es, args.optString("command"), args.optBoolean("unsafe", false))
            // 显式触发 Rizin 重新分析（引擎 rzAnalyze 此前分发层漏接；rz_* 结果稀疏/过期时先跑它）
            "rz_analyze" -> soEngine.rzAnalyze(ws, es)
            // 独立汇编（不在编辑会话内，引擎 assembleRaw 此前分发层漏接）
            "rz_asm" -> soEngine.assembleRaw(ws, es, args.optString("asm"), zhou.solab.tools.HexCodec.long(args.optString("addr")) ?: 0L, if (args.has("thumb")) args.optBoolean("thumb") else null, args.optString("mode", "auto"))
            "xanso_dispatch" -> soEngine.xansoDispatch(ws, es, args.optString("op", "status"))
            // xAnSo 节区头重建（引擎 xansoBuildSections 此前分发层漏接；fix_sections 走 LIEF，这里走 xAnSo 上游算法，force=true 可重建已有节表）
            "xanso_build_sections" -> soEngine.xansoBuildSections(ws, es, args.optBoolean("force", false))
            "lief_dispatch" -> soEngine.liefDispatch(ws, es, args.optString("op"), args.optString("objectPath"), args.optString("method"), args.optJSONArray("args") ?: JSONArray(), args.optBoolean("dryRun"))
            // LIEF 快捷 VA 补丁/导出管理（引擎方法此前分发层漏接；edit_hex 走偏移，这里走 VA）
            "lief_patch_address" -> {
                val va = zhou.solab.tools.HexCodec.long(args.optString("va"))
                    ?: return err("INVALID_ARGUMENT", "va must be a hex address", "va", args.optString("va"))
                val patch = zhou.solab.tools.HexCodec.bytes(args.optString("patchHex"))
                    ?: return err("INVALID_HEX", "patchHex must contain valid byte pairs", "patchHex", args.optString("patchHex"))
                soEngine.liefPatchAddress(ws, es, va, patch)
            }
            "lief_add_export" -> {
                val va = zhou.solab.tools.HexCodec.long(args.optString("va"))
                    ?: return err("INVALID_ARGUMENT", "va must be a hex address", "va", args.optString("va"))
                soEngine.liefAddExportedFunction(ws, es, va, args.optString("name"))
            }
            "lief_remove_symbol" -> soEngine.liefRemoveSymbol(ws, es, args.optString("name"))
            // emulate
            "emulate" -> soEngine.emulate(ws, es, args.optString("symbolName"), args.optJSONArray("args") ?: JSONArray(), args.optBoolean("trace"))
            "emulate_dump" -> soEngine.dumpMemory(ws, es, zhou.solab.tools.HexCodec.long(args.optString("addr")) ?: 0L, args.optInt("size", 256))
            "emulation_status" -> soEngine.emulationStatus()
            "unidbg_dispatch" -> soEngine.unidbgDispatch(ws, es, args.optString("op"), args.optString("method"), args.optJSONArray("args") ?: JSONArray())
            "unidbg_batch" -> soEngine.unidbgBatch(ws, es, args)
            // blutter
            // so_analyze(action=blutter) 的语义是"跑 Flutter 离线分析"，
            // coordinator 侧 action 命名空间不同（inspect/analyze/status/...），
            // 这里改写：默认 analyze，blutterAction 可选覆盖做 job 管理。
            "blutter" -> soEngine.flutterBlutter(
                JSONObject(args.toString()).put("action", args.optString("blutterAction", "analyze"))
            )
            // capability
            "capabilities" -> soEngine.capabilityRegistry()
            // 上下文感知建议（借鉴玄星逆核 meta_info action=suggest；任何 action 报错后带 workspaceId 重调拿替代路径）
            "suggest" -> soEngine.soSuggest(ws, es)
            // 按需下载（体积控制：lite 版重型资源按需拉取）
            "asset_status" -> {
                val names = args.optJSONArray("names")?.let { arr ->
                    (0 until arr.length()).map { arr.optString(it) }
                } ?: listOf("rizin/plugins/rz_ghidra_sleigh/.keep")
                zhou.solab.tools.AssetDownloader.status(context, names)
            }
            "asset_download" -> {
                val url = args.optString("url")
                val name = args.optString("name")
                val sha = args.optString("sha256")
                if (name.isBlank()) err("INVALID_ARGUMENT", "缺少 name(资源名)", "name", "")
                else zhou.solab.tools.AssetDownloader.download(context, url, name, sha)
                    ?: zhou.solab.tools.ok(JSONObject()
                        .put("tool", "asset_download")
                        .put("action", "download")
                        .put("name", name)
                        .put("downloaded", true)
                        .put("path", zhou.solab.tools.AssetDownloader.assetFile(context, name)?.absolutePath)
                        .put("hint", "资源已就绪，可立即使用（blutter/ghidra 运行时自动发现）"))
            }
            else -> err("UNKNOWN_ACTION", "未知 soAnalyze action: $action", "action", action)
        }
    }

    private fun locatorOrVa(args: JSONObject): String = args.optString("locator")
        .ifBlank { args.optString("va") }
        .ifBlank { args.optString("addr") }

    /** 递归把 org.json 结构转成 MethodChannel 可编码的 Map/List。 */
    private fun jsonToMap(obj: JSONObject): Map<String, Any?> {
        val map = LinkedHashMap<String, Any?>()
        obj.keys().forEach { k ->
            map[k] = jsonValue(obj.get(k))
        }
        return map
    }

    private fun jsonValue(v: Any?): Any? = when {
        v == null || v == JSONObject.NULL -> null
        v is JSONObject -> jsonToMap(v)
        v is JSONArray -> (0 until v.length()).map { jsonValue(v.get(it)) }
        else -> v
    }

    private fun resolveSource(call: MethodCall): File {
        val path = arg(call, "path") as? String
        if (path.isNullOrBlank()) throw StructuralError("invalid_args", "缺少 APK 路径")
        val file = File(path)
        if (!file.isFile || file.length() <= 0L) {
            throw StructuralError("invalid_path", "APK 文件不存在或为空: ${file.absolutePath}")
        }
        return file
    }

    /** 输出路径：优先用显式 outputDir（MT 工作目录等可访问位置），否则 APK 同目录。 */
    private fun structuralOutput(
        source: File,
        outputName: String? = null,
        outputDir: String? = null,
    ): File {
        // 输出目录必填：产物必须落用户选定的「工作目录」（与 MT 工作目录一致），
        // 否则会落到 FilePicker 的内部 cache，无 root 拿不到、MT 也索引不到。
        if (outputDir.isNullOrBlank()) {
            throw StructuralError(
                "output_dir_required",
                "请先在 APK 工作台设置「工作目录」（需与 MT 工作目录一致），产物才能落外部可访问位置",
            )
        }
        val dirFile = File(outputDir)
        if (dirFile.exists() && !dirFile.isDirectory) {
            throw StructuralError("invalid_output_dir", "工作目录不存在或不是目录: $outputDir")
        }
        if (!dirFile.exists() && !dirFile.mkdirs()) {
            throw StructuralError("invalid_output_dir", "无法创建工作目录: $outputDir")
        }
        if (outputName != null) {
            val cleaned = File(outputName).name
            if (cleaned.isBlank() || cleaned == "." || cleaned == "..") {
                throw StructuralError("invalid_args", "outputName 非法: $outputName")
            }
        }
        return File(dirFile, "${intermediateStem(source, dirFile)}_v${nextIntermediateVersion(source, dirFile)}.apk")
    }

    private fun intermediateStem(source: File, outputDir: File): String {
        val stem = source.nameWithoutExtension
        val match = Regex("^(.*)_v\\d+$", RegexOption.IGNORE_CASE).matchEntire(stem)
        val previous = match?.groupValues?.getOrNull(1).orEmpty()
        return if (previous.isNotBlank() && File(outputDir, "$previous.apk").isFile) previous else stem
    }

    private fun nextIntermediateVersion(source: File, outputDir: File): Int {
        val stem = intermediateStem(source, outputDir)
        val pattern = Regex("^${Regex.escape(stem)}_v(\\d+)\\.apk$", RegexOption.IGNORE_CASE)
        val maxVersion = outputDir.listFiles().orEmpty().mapNotNull { file ->
            pattern.matchEntire(file.name)?.groupValues?.getOrNull(1)?.toIntOrNull()
        }.maxOrNull() ?: 0
        return maxVersion + 1
    }

    private fun productStem(source: File, outputDir: File): String = intermediateStem(source, outputDir)

    /** 从调用参数取输出目录（可空）。 */
    private fun outputDirArg(call: MethodCall): String? =
        (arg(call, "outputDir") as? String)?.takeIf { it.isNotBlank() }

    // ---- APK Signing Block 解析（v2/v3 真伪检测，零依赖） ----

    /** 返回 [v2, v3] 两个布尔标志（一次读文件，避免两次 RandomAccessFile）。 */
    private fun signingSchemeFlags(apk: File): List<Boolean> {
        val ids = signingBlockIds(apk)
        return listOf(ids.contains(0x7109871aL), ids.contains(0xf05368c0L))
    }

    /**
     * 解析 APK Signing Block 中全部签名块 id。
     * 原理：EOCD 末尾找签名块大小 → 定位 'APK Sig Block 42' magic → 顺序读各 id+len 对。
     */
    private fun signingBlockIds(apk: File): Set<Long> {
        return try {
            val eocdSize = 22
            val reader = java.io.RandomAccessFile(apk, "r")
            try {
                val fileLen = reader.length()
                if (fileLen < eocdSize + 16) return emptySet()
                // B1：EOCD 不一定在 fileLen-22（ZIP 允许 comment，部分分发渠道会加）。
                // 从末尾向前最多扫描 64KB 找 EOCD 签名 0x06054b50，并用 commentLen
                // 字段校验位置正确（commentLen == fileLen - eocdOffset - 22）。
                val eocd = ByteArray(eocdSize)
                fun isEocd(bytes: ByteArray): Boolean =
                    (bytes[0].toInt() and 0xff) == 0x50 &&
                        (bytes[1].toInt() and 0xff) == 0x4b &&
                        (bytes[2].toInt() and 0xff) == 0x05 &&
                        (bytes[3].toInt() and 0xff) == 0x06
                var eocdOffset = fileLen - eocdSize
                var found = false
                if (eocdOffset >= 0) {
                    reader.seek(eocdOffset)
                    reader.readFully(eocd)
                    if (isEocd(eocd) && readU16(eocd, 20) == (fileLen - eocdOffset - eocdSize).toLong()) {
                        found = true
                    }
                }
                if (!found) {
                    val scanStart = maxOf(0L, fileLen - eocdSize - 65535L)
                    var off = fileLen - eocdSize - 1
                    while (off >= scanStart) {
                        reader.seek(off)
                        reader.readFully(eocd)
                        if (isEocd(eocd) && readU16(eocd, 20) == (fileLen - off - eocdSize).toLong()) {
                            eocdOffset = off
                            found = true
                            break
                        }
                        off--
                    }
                }
                if (!found) return emptySet()
                // EOCD 签名 0x06054b50 已在定位阶段校验
                val cdOffset = readU32(eocd, 16)
                val cdSize = readU32(eocd, 12)
                val signingBlockSizeFieldEnd = cdOffset
                if (signingBlockSizeFieldEnd < 8 || signingBlockSizeFieldEnd > fileLen - 16) {
                    return emptySet()
                }
                // 签名块 size 字段（8 字节，紧邻中央目录之前）
                reader.seek(signingBlockSizeFieldEnd - 8)
                val sizeField = ByteArray(8)
                reader.readFully(sizeField)
                val blockSize = readU64(sizeField)
                if (blockSize < 24 || blockSize > (fileLen - cdSize)) return emptySet()
                val blockStart = signingBlockSizeFieldEnd - blockSize
                if (blockStart < 0) return emptySet()
                // magic 'APK Sig Block 42' 在块尾 16 字节
                reader.seek(signingBlockSizeFieldEnd - 16)
                val magic = ByteArray(16)
                reader.readFully(magic)
                val expected = "APK Sig Block 42".toByteArray(Charsets.US_ASCII)
                if (!magic.contentEquals(expected)) return emptySet()
                // 从块头开始遍历 id+len 对（头 8 字节 = 块大小，跳过）
                val ids = mutableSetOf<Long>()
                var pos = blockStart + 8
                // 遍历终点 = magic 起点 = 块尾 - 16（不能用 -24：最后一个 pair
                // 紧邻 magic 前，-24 会把 v2 块（通常最后一个 pair）截掉，误判 v1-only）
                val end = signingBlockSizeFieldEnd - 16
                while (pos + 8 <= end) {
                    reader.seek(pos)
                    val lenBytes = ByteArray(8)
                    reader.readFully(lenBytes)
                    val len = readU64(lenBytes)
                    reader.seek(pos + 8)
                    val idBytes = ByteArray(4)
                    reader.readFully(idBytes)
                    ids += readU32(idBytes, 0).toLong() and 0xffffffffL
                    if (len <= 0 || pos + 8 + len > end) break
                    pos += 8 + len
                }
                ids
            } finally {
                reader.close()
            }
        } catch (_: Exception) {
            emptySet()
        }
    }

    private fun readU32(bytes: ByteArray, offset: Int): Long =
        ((bytes[offset].toLong() and 0xff)) or
            ((bytes[offset + 1].toLong() and 0xff) shl 8) or
            ((bytes[offset + 2].toLong() and 0xff) shl 16) or
            ((bytes[offset + 3].toLong() and 0xff) shl 24)

    private fun readU16(bytes: ByteArray, offset: Int): Long =
        ((bytes[offset].toLong() and 0xff)) or
            ((bytes[offset + 1].toLong() and 0xff) shl 8)

    private fun readU64(bytes: ByteArray): Long {
        var value = 0L
        for (i in 0 until 8) {
            value = value or ((bytes[i].toLong() and 0xff) shl (8 * i))
        }
        return value
    }

    /** A1: 精确条目 + 目录前缀删除，流式重打包为未签名中间包。 */
    private fun deleteZipEntries(call: MethodCall): Map<String, Any> {
        val source = resolveSource(call)
        val outputDir = outputDirArg(call)
        val entries = (arg(call, "entries") as? List<*>)
            ?.mapNotNull { it as? String } ?: emptyList()
        val prefixes = (arg(call, "prefixes") as? List<*>)
            ?.mapNotNull { it as? String } ?: emptyList()
        val dryRun = arg(call, "dryRun") as? Boolean ?: false

        entries.forEach { name ->
            if (ApkStructuralOps.normalizeEntryName(name) == null) {
                throw StructuralError("invalid_entry_name", "非法条目名: $name")
            }
        }
        prefixes.forEach { prefix ->
            val trimmed = prefix.trimEnd('/')
            if (trimmed.isEmpty() || ApkStructuralOps.normalizeEntryName(trimmed) == null) {
                throw StructuralError("invalid_entry_name", "非法目录前缀: $prefix")
            }
        }
        val exact = LinkedHashSet(entries)
        val protectedHit = exact.any { ApkStructuralOps.isProtected(it) } ||
            prefixes.any { p ->
                val trimmed = p.trimEnd('/')
                ApkStructuralOps.isProtected(trimmed) ||
                    ApkStructuralOps.isProtected(trimmed + "/") ||
                    // 只保护「整个 lib/」目录；lib/<abi>/ 单 ABI 目录删除是正当的（ABI 过滤），放行
                    trimmed == "lib"
            }
        // 核心 so 白名单：这些是应用运行必需的，精确删除也拦（防误删导致闪退）。
        val coreSoExact = exact.any { isCoreSo(it) }
        if (protectedHit || coreSoExact) {
            throw StructuralError(
                "protected_entry",
                "AndroidManifest.xml / resources.arsc / classes*.dex / 核心 SO（libflutter/libapp/壳）受保护，不可删除",
            )
        }

        if (dryRun) {
            val (prefixCount, prefixBytes) = countDropped(source, prefixes)
            // P1-1 previewCount 只统计实际可删条目：exact 逐个核对 zip 是否存在，
            // 不存在的明确提示（防「deleted 空 但 previewCount=请求数」虚高误导）
            var exactBytes = 0L
            val exactMissing = mutableListOf<String>()
            withApkZip(source) { zip ->
                val names = HashMap<String, Long>()
                zip.entries().asSequence().filterNot { it.isDirectory }.forEach { e ->
                    ApkStructuralOps.normalizeEntryName(e.name)?.let { names[it] = e.size }
                }
                exact.forEach { name ->
                    val size = names[name]
                    if (size == null) exactMissing += name else exactBytes += size
                }
            }
            return mapOf(
                "ok" to true,
                "dryRun" to true,
                "deleted" to emptyList<Map<String, Any>>(),
                "savedBytes" to (prefixBytes + exactBytes),
                "previewCount" to (prefixCount + (exact.size - exactMissing.size)),
                "missingEntries" to exactMissing,
                "message" to if (exactMissing.isEmpty()) ""
                else "以下 ${exactMissing.size} 个条目在 APK 中不存在，已从预览计数排除: ${exactMissing.joinToString(", ")}",
            )
        }

        val output = structuralOutput(source, outputDir = outputDir)
        if (output.absolutePath == source.absolutePath) {
            throw StructuralError("invalid_args", "输出路径不能等于源 APK 路径")
        }
        val result = ApkStructuralOps.repack(
            source,
            output,
            dropExact = exact,
            dropPrefixes = prefixes,
        )
        return mapOf(
            "ok" to true,
            "outputPath" to output.absolutePath,
            "dryRun" to false,
            "deleted" to result.dropped.map { mapOf("path" to it.name, "size" to it.size) },
            "savedBytes" to result.droppedBytes,
        )
    }

    private fun writeZipEntry(call: MethodCall): Map<String, Any> {
        val source = resolveSource(call)
        val outputDir = outputDirArg(call)
        val rawOps = (arg(call, "entries") as? List<*>) ?: emptyList<Any?>()
        val dryRun = arg(call, "dryRun") as? Boolean ?: false
        if (rawOps.isEmpty()) throw StructuralError("invalid_args", "缺少 entries 操作列表")

        val ops = ArrayList<EntryOp>()
        rawOps.forEachIndexed { index, raw ->
            val op = raw as? Map<*, *> ?: throw StructuralError("invalid_args", "第 $index 个操作不是对象")
            val locator = op["locator"] as? String
                ?: throw StructuralError("invalid_args", "第 $index 个操作缺少 locator")
            val action = (op["action"] as? String)?.lowercase(Locale.ROOT)
                ?: throw StructuralError("invalid_args", "第 $index 个操作缺少 action")
            if (action !in ENTRY_ACTIONS) {
                throw StructuralError("invalid_args", "第 $index 个操作 action 非法: $action")
            }
            val name = if (locator.startsWith("zip_entry:")) {
                locator.substringAfter("zip_entry:")
            } else {
                locator
            }
            if (ApkStructuralOps.normalizeEntryName(name) == null) {
                throw StructuralError("invalid_entry_name", "非法条目名: $name")
            }
            val contentFile = if (action == "delete") null else try {
                entryContentFile(op["content"])
            } catch (e: StructuralError) {
                throw e
            } catch (e: Exception) {
                throw StructuralError("invalid_content", "条目 $name 本地文件无效: ${e.message}")
            }
            val content = if (action == "delete" || contentFile != null) {
                null
            } else {
                try {
                    ApkStructuralOps.decodeContent(op["content"])
                } catch (e: Exception) {
                    throw StructuralError("invalid_content", "条目 $name 内容解码失败: ${e.message}")
                } ?: throw StructuralError("invalid_args", "条目 $name 缺少 content(base64/hex 或本地 path)")
            }
            ops += EntryOp(
                locator = locator,
                name = name,
                action = action,
                content = content,
                contentFile = contentFile,
                contentSource = if (contentFile != null) "local_file" else if (action == "delete") "none" else "inline_payload",
            )
        }
        if (ops.map { it.name }.distinct().size != ops.size) {
            throw StructuralError("duplicate_entry", "同一条目只能操作一次，请合并后重试")
        }

        // 硬保护：签名文件不可写入；Manifest/arsc/dex 不可删除
        ops.forEach { op ->
            if (ApkStructuralOps.isSignatureEntry(op.name)) {
                if (op.action != "delete") {
                    throw StructuralError("protected_entry", "META-INF 签名文件不可写入: ${op.name}")
                }
            } else if (op.action == "delete" && ApkStructuralOps.isProtected(op.name)) {
                throw StructuralError("protected_entry", "禁止删除受保护条目: ${op.name}")
            }
        }

        // 预扫描：源条目名集合（存在性 / 冲突校验）
        val sourceNames = LinkedHashSet<String>()
        withApkZip(source) { zip ->
            zip.entries().asSequence().filterNot { it.isDirectory }.forEach { entry ->
                ApkStructuralOps.normalizeEntryName(entry.name)?.let(sourceNames::add)
            }
        }

        val overrides = LinkedHashMap<String, ByteArray>()
        val overrideFiles = LinkedHashMap<String, File>()
        val additions = LinkedHashMap<String, ByteArray>()
        val additionFiles = LinkedHashMap<String, File>()
        val deletes = LinkedHashSet<String>()
        val hashTargets = LinkedHashSet<String>()
        ops.forEach { op ->
            when (op.action) {
                "overwrite" -> {
                    if (op.name !in sourceNames) {
                        throw StructuralError("entry_not_found", "条目不存在，无法覆盖: ${op.name}")
                    }
                    op.contentFile?.let { overrideFiles[op.name] = it }
                        ?: run { overrides[op.name] = op.content!! }
                    hashTargets += op.name
                }
                "add" -> {
                    if (op.name in sourceNames) {
                        throw StructuralError("entry_exists", "条目已存在，无法新增: ${op.name}")
                    }
                    op.contentFile?.let { additionFiles[op.name] = it }
                        ?: run { additions[op.name] = op.content!! }
                }
                "delete" -> {
                    if (op.name !in sourceNames) {
                        throw StructuralError("entry_not_found", "条目不存在，无法删除: ${op.name}")
                    }
                    if (!ApkStructuralOps.isSignatureEntry(op.name)) {
                        deletes += op.name
                    }
                    hashTargets += op.name
                }
            }
        }

        // before 哈希 + 源压缩元数据：一次 ZipFile 同时取两类信息
        // （原先 beforeHashes 和 dryRun 的压缩对比各开一次 zip 遍历同一批条目）。
        val beforeHashes = HashMap<String, ApkStructuralOps.SourceHash>()
        val sourceCompression = HashMap<String, Pair<Long, Int>>()
        if (hashTargets.isNotEmpty()) {
            withApkZip(source) { zip ->
                hashTargets.forEach { name ->
                    zip.getEntry(name)?.let { entry ->
                        beforeHashes[name] = ApkStructuralOps.readSourceHash(zip, entry)
                        sourceCompression[name] = entry.compressedSize to entry.method
                    }
                }
            }
        }

        val output = structuralOutput(source, outputDir = outputDir)
        val results = ops.map { op ->
            val before = beforeHashes[op.name]
            when (op.action) {
                "overwrite" -> resultEntry(
                    op, "overwrite",
                    before?.sha256 ?: "", entryContentSha256(op),
                    before?.size ?: 0L, entryContentSize(op),
                )
                "add" -> resultEntry(
                    op, "add",
                    "", entryContentSha256(op),
                    0L, entryContentSize(op),
                )
                "delete" -> if (op.name in deletes) {
                    resultEntry(op, "delete", before?.sha256 ?: "", "", before?.size ?: 0L, 0L)
                } else {
                    // META-INF 签名文件：自动跳过
                    resultEntry(op, "skipped", before?.sha256 ?: "", "", before?.size ?: 0L, 0L)
                }
                else -> throw IllegalStateException("unreachable action: ${op.action}")
            }
        }

        if (dryRun) {
            // P0 压缩体积对比：预览阶段暴露 STORED/DEFLATED 差异导致的体积膨胀
            // （sourceCompression 已在 beforeHashes 同一次 ZipFile 遍历中取得）
            val enriched = results.map { r ->
                val name = (r["locator"] as String).removePrefix("zip_entry:")
                if (r["action"] == "overwrite" || r["action"] == "add") {
                    val op = ops.firstOrNull { it.name == name }
                    val (beforeComp, method) = sourceCompression[name] ?: (0L to -1)
                    val afterEstimate = op?.let { runCatching { estimateDeflatedSize(it) }.getOrDefault(-1L) } ?: -1L
                    r + mapOf(
                        "beforeCompressedSize" to beforeComp,
                        "afterCompressedSizeEstimate" to afterEstimate,
                        "sourceCompressionMethod" to when (method) {
                            java.util.zip.ZipEntry.STORED -> "STORED"
                            java.util.zip.ZipEntry.DEFLATED -> "DEFLATED"
                            else -> "NEW"
                        },
                        "sizeNote" to "afterCompressedSizeEstimate 按 DEFLATED 预估；重打包会沿用源条目压缩方式，源 DEFLATED 不会被升级为 STORED",
                    )
                } else {
                    r
                }
            }
            return mapOf(
                "ok" to true,
                "dryRun" to true,
                "outputPath" to output.absolutePath,
                "results" to enriched,
            )
        }

        ApkStructuralOps.repack(
            source = source,
            output = output,
            dropExact = deletes,
            overrides = overrides,
            overrideFiles = overrideFiles,
            additions = additions,
            additionFiles = additionFiles,
        )
        return mapOf("ok" to true, "outputPath" to output.absolutePath, "results" to results)
    }

    /** T1: 列出 APK 内 lib 目录下各 ABI 的 so 条目（so_patch_into_apk 自动定位回填目标）。 */
    private fun listLibEntries(call: MethodCall): Map<String, Any> {
        val source = resolveSource(call)
        val libs = ArrayList<Map<String, Any>>()
        val abis = LinkedHashSet<String>()
        withApkZip(source) { zip ->
            zip.entries().asSequence().filterNot { it.isDirectory }.forEach { entry ->
                val name = ApkStructuralOps.normalizeEntryName(entry.name) ?: return@forEach
                if (!name.startsWith("lib/") || !name.endsWith(".so")) return@forEach
                val rest = name.removePrefix("lib/")
                if (!rest.contains('/')) return@forEach
                val abi = rest.substringBefore('/')
                if (abi.isEmpty()) return@forEach
                abis += abi
                libs.add(
                    mapOf(
                        "name" to name,
                        "abi" to abi,
                        "soName" to rest.substringAfter('/'),
                        "size" to entry.size,
                    )
                )
            }
        }
        return mapOf(
            "ok" to true,
            "count" to libs.size,
            "abis" to abis.toList(),
            "entries" to libs,
        )
    }

    /** A3: 只保留 keepAbis，过滤 lib/<其他 ABI>/ 全部条目后重打包。 */
    private fun buildApk(call: MethodCall): Map<String, Any> {
        val source = resolveSource(call)
        val outputDir = outputDirArg(call)
        val keepAbis = (arg(call, "keepAbis") as? List<*>)
            ?.map { it.toString().trim().lowercase(Locale.ROOT) }
            ?.filter { it.isNotEmpty() }
            ?.toSet() ?: emptySet()
        val outputName = (arg(call, "outputName") as? String)?.takeIf { it.isNotBlank() }
        val dryRun = arg(call, "dryRun") as? Boolean ?: false
        // M1: sign=true 时重打包后链式内置签名（玄星逆核 apk_sign），出可直接安装的签名包
        val sign = arg(call, "sign") as? Boolean ?: false
        keepAbis.forEach { abi ->
            if (abi.contains('/') || abi.contains('\\') || abi == "." || abi == "..") {
                throw StructuralError("invalid_args", "非法 ABI: $abi")
            }
        }

        // 预扫描：源包中实际存在的 ABI 目录
        val presentAbis = LinkedHashSet<String>()
        withApkZip(source) { zip ->
            zip.entries().asSequence().filterNot { it.isDirectory }.forEach { entry ->
                val name = ApkStructuralOps.normalizeEntryName(entry.name) ?: return@forEach
                if (name.startsWith("lib/")) {
                    val abi = name.removePrefix("lib/").substringBefore('/')
                    if (abi.isNotEmpty()) presentAbis += abi
                }
            }
        }
        val filteredAbis = presentAbis.filterNot { it in keepAbis }.sorted()
        val dropPrefixes = filteredAbis.map { "lib/$it/" }

        val output = structuralOutput(source, outputName, outputDir)
        if (output.absolutePath == source.absolutePath) {
            throw StructuralError("invalid_args", "输出文件名不能与源 APK 相同")
        }
        // 签名产物命名：统一「源名_成品.apk」，中间包只保留连续 v 号。
        val signedOutput = File(output.parentFile, "${productStem(source, output.parentFile)}_成品.apk")

        if (dryRun) {
            val (count, bytes) = countDropped(source, dropPrefixes)
            return mapOf(
                "ok" to true,
                "dryRun" to true,
                "outputPath" to output.absolutePath,
                "filteredAbis" to filteredAbis,
                "filteredEntries" to count,
                "savedBytes" to bytes,
                "sign" to sign,
                "signedPath" to signedOutput.absolutePath,
            )
        }

        val result = ApkStructuralOps.repack(source = source, output = output, dropPrefixes = dropPrefixes)
        val base = mapOf(
            "ok" to true,
            "outputPath" to output.absolutePath,
            "filteredAbis" to filteredAbis,
            "filteredEntries" to result.dropped.size,
            "savedBytes" to result.droppedBytes,
        )
        if (!sign) return base

        // M1: 链式内置签名
        signedOutput.delete()
        val signed = SolabApkBuildTool.apkSign(
            context,
            JSONObject()
                .put("inputApk", output.absolutePath)
                .put("outputApk", signedOutput.absolutePath),
        )
        if (signed.optBoolean("ok")) {
            return base + mapOf(
                "signed" to true,
                "signedPath" to signedOutput.absolutePath,
            )
        }
        val errObj = signed.optJSONObject("error")
        return mapOf(
            "ok" to false,
            "error" to (errObj?.optString("code") ?: "apk_sign_failed"),
            "message" to (errObj?.optString("message") ?: signed.optString("message", "签名失败")),
            "intermediatePath" to output.absolutePath,
        )
    }

    /** B1/B2/B3/B4 + B5：按明确方法名修改 DEX，NOP 广告库加载；原包不覆盖，产出未签名中间包。 */
    private fun patchDexMethods(call: MethodCall): Map<String, Any> {
        val source = resolveSource(call)
        val outputDir = outputDirArg(call)
        fun methodTargets(key: String): Set<String> =
            (arg(call, key) as? List<*>)
                ?.map { it.toString().trim().lowercase(Locale.ROOT) }
                ?.map(ApkDexPatcher::normalizeMethodTarget)
                ?.filter { it.isNotEmpty() }
                ?.toSet() ?: emptySet()
        val voidMethods = methodTargets("voidMethods")
        // B3：会员/VIP 状态方法强制返回 true（仅处理返回 boolean/int 的方法）
        val trueMethods = methodTargets("trueMethods")
        val falseMethods = methodTargets("falseMethods")
        // B5：SDK 包名 → so 加载关键词（NOP 目标）
        val sdkPackages = (arg(call, "sdkPackages") as? List<*>)
            ?.map { it.toString().trim().lowercase(Locale.ROOT) }
            ?.filter { it.isNotEmpty() }
            ?.toSet() ?: emptySet()
        val libKeywords = if (sdkPackages.isNotEmpty()) {
            ApkDexPatcher.buildSdkLibKeywords(sdkPackages)
        } else {
            emptySet()
        }
        // 检测规避：VPN/模拟器检测方法强制 false（方法名 contains 关键词）
        // 关键词 = 内置集合 ∪ 用户自定义（规则库 detection_* 类别）。
        val userRules = loadRules()
        val removeVpnDetection = arg(call, "removeVpnDetection") as? Boolean ?: false
        val removeEmulatorDetection = arg(call, "removeEmulatorDetection") as? Boolean ?: false
        val vpnKeywords = if (removeVpnDetection) {
            (ApkDexPatcher.VPN_DETECT_KEYWORDS + userRules.detectionVpn).toSet()
        } else {
            emptySet()
        }
        val emulatorKeywords = if (removeEmulatorDetection) {
            (ApkDexPatcher.EMULATOR_DETECT_KEYWORDS + userRules.detectionEmulator).toSet()
        } else {
            emptySet()
        }
        // Root/反调试检测规避（关键词 contains，强制 false）
        val removeRootDetection = arg(call, "removeRootDetection") as? Boolean ?: false
        val removeDebugDetection = arg(call, "removeDebugDetection") as? Boolean ?: false
        val rootKeywords = if (removeRootDetection) {
            (ApkDexPatcher.ROOT_DETECT_KEYWORDS + userRules.detectionRoot).toSet()
        } else {
            emptySet()
        }
        val debugKeywords = if (removeDebugDetection) {
            (ApkDexPatcher.DEBUG_DETECT_KEYWORDS + userRules.detectionDebug).toSet()
        } else {
            emptySet()
        }
        // 截屏/录屏检测规避（关键词 contains + 证据双条件，强制 false）
        val removeScreenCaptureDetection = arg(call, "removeScreenCaptureDetection") as? Boolean ?: false
        val screenCaptureKeywords = if (removeScreenCaptureDetection) {
            ApkDexPatcher.SCREEN_CAPTURE_DETECT_KEYWORDS.toSet()
        } else {
            emptySet()
        }
        // FLAG_SECURE 剥离：清除流入 Window.setFlags/addFlags 常量中的该位，
        // 恢复允许截屏/录屏；同常量其他 flag 位保留
        val removeFlagSecure = arg(call, "removeFlagSecure") as? Boolean ?: false
        // 时间劫持：到期/剩余时间方法（long 返回）强制远期 0xffffff
        val timeMethods = methodTargets("timeMethods")
        // REQ-06：对象返回方法存根返回 null（"nullMethods"）
        val nullMethods = methodTargets("nullMethods")
        // 方法级定位（缺陷 1/2）：按全限定标识定位任意方法。
        // 接受 Lpkg/Class;->name 或 pkg.Class.methodName；归一化为 lpkg/class;->name。
        val classMethods = (arg(call, "classMethods") as? List<*>)
            ?.mapNotNull { normalizeClassMethod(it.toString()) }
            ?.filter { it.isNotEmpty() }
            ?.toSet() ?: emptySet()
        // 开屏广告倒计时缩短：splash 类中 ≥1000ms 的延迟常量置 0
        val shortenSplashCountdown = arg(call, "shortenSplashCountdown") as? Boolean ?: false
        // 签名兼容：默认普通注入；普通模式实际失败后才允许升级为原包模式。
        val signatureBypass = arg(call, "signatureBypass") as? Boolean ?: true
        val signatureBypassMode = (arg(call, "signatureBypassMode") as? String)
            ?.takeIf { it.isNotBlank() } ?: ApkSignatureBypassInjector.MODE_NORMAL
        val originalApk = (arg(call, "originalApkPath") as? String)
            ?.takeIf { it.isNotBlank() }
            ?.let(::File)
        // 体积优化（借鉴 2.9）：写回时全量剥离 debug info（行号/局部变量表），
        // 减小 DEX 体积 5%~15%；仅对本次修改写回的 DEX 生效
        val stripDebugInfo = arg(call, "stripDebugInfo") as? Boolean ?: false
        val dryRun = arg(call, "dryRun") as? Boolean ?: false
        if (voidMethods.isEmpty() && trueMethods.isEmpty() && falseMethods.isEmpty() &&
            libKeywords.isEmpty() && vpnKeywords.isEmpty() && emulatorKeywords.isEmpty() &&
            rootKeywords.isEmpty() && debugKeywords.isEmpty() && screenCaptureKeywords.isEmpty() &&
            !removeFlagSecure && timeMethods.isEmpty() &&
            nullMethods.isEmpty() && classMethods.isEmpty() && !shortenSplashCountdown &&
            !signatureBypass
        ) {
            throw StructuralError("invalid_args", "至少提供一个 voidMethods、trueMethods、falseMethods、sdkPackages、检测移除开关、removeFlagSecure、timeMethods、nullMethods、classMethods、shortenSplashCountdown 或 signatureBypass 规则")
        }
        // T3 护栏：≤2 字符的短方法名存在爆炸风险（混淆短名 c/d/b 会命中数百个无关类），
        // 拒绝并强制走 classMethods 类限定定位。
        val shortNameTargets = (voidMethods + trueMethods + falseMethods).filter { it.length <= 2 }
        if (shortNameTargets.isNotEmpty()) {
            throw StructuralError(
                "name_too_short",
                "短方法名（≤2 字符）存在大规模误伤风险：${shortNameTargets.joinToString("、")}。" +
                    "请先用 dex_search → class_outline/dex_xref → smali_read 获取并验证真实 qualifiedId（Lpkg/Class;->name），" +
                    "再走 classMethods 类限定匹配。",
            )
        }
        if (dryRun) {
            val signaturePreview = if (signatureBypass) {
                val directory = Files.createTempDirectory("apk_signature_preview_").toFile()
                try {
                    prepareSignatureBypass(
                        source,
                        signatureBypassMode,
                        originalApk,
                        directory,
                    ).toMap()
                } finally {
                    directory.deleteRecursively()
                }
            } else {
                null
            }
            // 一次遍历收集全部预览命中（避免 6 次独立解压全量 dex 的开销）。
            val preview = scanPatchCandidates(
                source = source,
                voidMethods = voidMethods,
                trueMethods = trueMethods,
                falseMethods = falseMethods,
                libKeywords = libKeywords,
                vpnKeywords = vpnKeywords,
                emulatorKeywords = emulatorKeywords,
                rootKeywords = rootKeywords,
                debugKeywords = debugKeywords,
                screenCaptureKeywords = screenCaptureKeywords,
                removeFlagSecure = removeFlagSecure,
                timeMethods = timeMethods,
                nullMethods = nullMethods,
            )
            // classMethods 逐条解析：真实方法定义 resolved / 未找到 unresolved
            val classResolved = resolveClassMethods(source, classMethods)
            val anyHit = preview.voidMethods.isNotEmpty() || preview.matchedMethods.isNotEmpty() ||
                preview.falseMethods.isNotEmpty() || preview.literalLoadLibrary.isNotEmpty() ||
                preview.vpnDetection.isNotEmpty() || preview.emulatorDetection.isNotEmpty() ||
                preview.rootDetection.isNotEmpty() || preview.debugDetection.isNotEmpty() ||
                preview.screenCaptureDetection.isNotEmpty() || preview.flagSecureTargets.isNotEmpty() ||
                preview.timeMethods.isNotEmpty() || preview.nullMethods.isNotEmpty() ||
                classResolved.any { it["resolved"] == true } || signaturePreview != null
            val rulesProvided = voidMethods.isNotEmpty() || trueMethods.isNotEmpty() ||
                falseMethods.isNotEmpty() || classMethods.isNotEmpty()
            // 缺陷 3：0 命中不再静默——给出结构化 warning 并强制走定位流程
            val warning = if (!anyHit && rulesProvided) {
                mapOf(
                    "type" to "no_method_hits",
                    "suggestion" to "字符串/规则命中不等于真实方法定义。请先按 dex_search → class_outline/dex_xref → smali_read 获取真实 qualifiedId，再用全限定标识（Lpkg/Class;->name）重试",
                )
            } else {
                null
            }
            // T3 护栏：classMethods 裸输入（无 ->）命中类数过多 → 泛化警告，
            // 防止 contains 匹配误伤大量无关类。
            val resolvedClasses = classResolved
                .filter { it["resolved"] == true }
                .map { it["className"].toString() }
                .toSet()
            val genericWarning = if (resolvedClasses.size > 20) {
                mapOf(
                    "type" to "name_too_generic",
                    "matchedClasses" to resolvedClasses.size,
                    "suggestion" to "裸输入命中 ${resolvedClasses.size} 个类（>20），contains 匹配过于泛化。请改用完整 qualifiedId（Lpkg/Class;->name）精确限定目标类，再走 classMethods。",
                )
            } else {
                null
            }
            return buildMap<String, Any> {
                put("ok", true)
                put("dryRun", true)
                put("voidMethodRules", voidMethods.size)
                put("trueMethodRules", trueMethods.size)
                put("falseMethodRules", falseMethods.size)
                put("libKeywordRules", libKeywords.size)
                put("voidMethods", preview.voidMethods)
                put("literalLoadLibrary", preview.literalLoadLibrary)
                put("nullMethodRules", nullMethods.size)
                put("matchedMethods", preview.matchedMethods)
                put("falseMethods", preview.falseMethods)
                put("vpnDetection", preview.vpnDetection)
                put("emulatorDetection", preview.emulatorDetection)
                put("rootDetection", preview.rootDetection)
                put("debugDetection", preview.debugDetection)
                put("screenCaptureDetection", preview.screenCaptureDetection)
                put("flagSecureTargets", preview.flagSecureTargets)
                put("timeMethods", preview.timeMethods)
                put("nullMethods", preview.nullMethods)
                put("classMethods", classResolved)
                if (signaturePreview != null) put("signatureBypass", signaturePreview)
                if (warning != null) put("warning", warning)
                if (genericWarning != null) put("warning", genericWarning)
                put("message", "预览校验规则并统计命中。loadLibrary 只会修改能静态追踪到广告库字符串的调用；运行时参数调用不会修改，应改用已分析到的上游初始化方法。classMethods 中 resolved=false 的条目表示 DEX 中不存在该标识。")
            }
        }

        val temporaryDirectory = Files.createTempDirectory("solab_apk_dex_").toFile()
        try {
            // 内存优化：patched dex 留在临时目录，只记录文件映射——重打包时流式
            // 读取，多 dex 大包内存峰值从「所有修改 dex 字节总和」降为「单 dex」。
            val overrides = linkedMapOf<String, File>()
            val byteOverrides = linkedMapOf<String, ByteArray>()
            val additions = linkedMapOf<String, ByteArray>()
            val additionFiles = linkedMapOf<String, File>()
            val signaturePlan = if (signatureBypass) {
                prepareSignatureBypass(
                    source,
                    signatureBypassMode,
                    originalApk,
                    temporaryDirectory,
                ).also { plan ->
                    byteOverrides.putAll(plan.byteOverrides)
                    overrides.putAll(plan.overrides)
                    additions.putAll(plan.additions)
                    additionFiles.putAll(plan.additionFiles)
                }
            } else {
                null
            }
            var voidCount = 0
            var trueCount = 0
            var falseCount = 0
            var nopCount = 0
            var vpnCount = 0
            var emulatorCount = 0
            var rootCount = 0
            var debugCount = 0
            var screenCaptureCount = 0
            var flagSecureCount = 0
            var timeCount = 0
            var nullCount = 0
            var classHandled = 0
            var classSkipped = 0
            var splashCountdown = 0
            // AC 预检模式与自动机构建一次即够：原写在 per-dex 循环内，
            // 多 dex 大包每个 dex 重建数百模式的自动机纯属浪费。
            val precheckPatterns = (
                voidMethods + trueMethods + falseMethods +
                    libKeywords + vpnKeywords + emulatorKeywords +
                    rootKeywords + debugKeywords + screenCaptureKeywords + timeMethods +
                    nullMethods + classMethods +
                    (if (shortenSplashCountdown) setOf("splash") else emptySet()) +
                    (if (removeFlagSecure) setOf("setFlags", "addFlags") else emptySet())
                ).map { it.substringAfter("->", it) }.toSet()
            val precheckAutomaton =
                if (precheckPatterns.isEmpty()) null
                else ApkAhoCorasick(precheckPatterns.toList())
            withApkZip(source) { zip ->
                zip.entries().asSequence()
                    .filterNot { it.isDirectory }
                    .filter { it.name.matches(DexIo.classesDexRegex) }
                    .forEach { entry ->
                        // 性能优化：无广告 DEX 自动跳过。
                        // 先在 zip 流上做 AC 预检，未命中任何模式的 dex 直接跳过，
                        // 不落盘、不加载 dexlib2——多 dex 大包省下绝大部分 IO。
                        if (precheckAutomaton != null) {
                            val preHit = zip.getInputStream(entry).use { input ->
                                precheckAutomaton.scanStream(input)
                            }
                            if (preHit.isEmpty()) return@forEach
                        }
                        val dex = overrides[entry.name] ?: File(temporaryDirectory, File(entry.name).name).also { file ->
                            zip.getInputStream(entry).use { input -> file.outputStream().use(input::copyTo) }
                        }
                        val patched = ApkDexPatcher.patch(
                            dexFile = dex,
                            voidMethodNames = voidMethods,
                            trueMethodNames = trueMethods,
                            falseMethodNames = falseMethods,
                            libKeywords = libKeywords,
                            vpnDetectKeywords = vpnKeywords,
                            emulatorDetectKeywords = emulatorKeywords,
                            timeMethodNames = timeMethods,
                            rootDetectKeywords = rootKeywords,
                            debugDetectKeywords = debugKeywords,
                            screenCaptureDetectKeywords = screenCaptureKeywords,
                            removeFlagSecure = removeFlagSecure,
                            nullMethodNames = nullMethods,
                            exactClassMethods = classMethods,
                            shortenSplashCountdown = shortenSplashCountdown,
                            stripDebugInfo = stripDebugInfo,
                        )
                        if (patched.changed > 0) {
                            overrides[entry.name] = dex
                            voidCount += patched.voidMethods
                            trueCount += patched.forcedTrue
                            falseCount += patched.forcedFalse
                            nopCount += patched.nopLoadLibrary
                            vpnCount += patched.vpnNeutralized
                            emulatorCount += patched.emulatorNeutralized
                            rootCount += patched.rootNeutralized
                            debugCount += patched.debugNeutralized
                            screenCaptureCount += patched.screenCaptureNeutralized
                            flagSecureCount += patched.flagSecureCleared
                            timeCount += patched.forcedTime
                            nullCount += patched.nullStubbed
                            classHandled += patched.classMethodsHandled
                            classSkipped += patched.classMethodsSkipped
                            splashCountdown += patched.splashCountdownShortened
                        }
                        // 每个 DEX 处理后无条件 GC：下一个 DEX 的加载
                        // 与写回在干净的堆上进行，防多 dex 大包内存累积。
                        System.gc()
                    }
            }
            if (overrides.isEmpty() && byteOverrides.isEmpty() &&
                additions.isEmpty() && additionFiles.isEmpty()
            ) {
                val signatureVerification = signaturePlan?.let {
                    ApkSignatureBypassInjector.verifyPrepared(source, it)
                }
                return mapOf(
                    "ok" to true,
                    "dryRun" to false,
                    "changed" to false,
                    "voidMethods" to 0,
                    "trueMethods" to 0,
                    "falseMethods" to 0,
                    "nopLoadLibrary" to 0,
                    "vpnDetection" to 0,
                    "emulatorDetection" to 0,
                    "rootDetection" to 0,
                    "debugDetection" to 0,
                    "screenCaptureDetection" to 0,
                    "flagSecure" to 0,
                    "timeMethods" to 0,
                    "nullMethods" to 0,
                    "classMethods" to 0,
                    "classMethodsSkipped" to 0,
                    "splashCountdown" to 0,
                    "signatureBypass" to (signaturePlan?.toMap() ?: emptyMap<String, Any>()),
                    "signatureBypassVerification" to (signatureVerification ?: emptyMap<String, Any>()),
                    "message" to if (signaturePlan?.alreadyInjected == true) {
                        "签名兼容已处理，后续补丁直接复用，未重复生成 APK"
                    } else {
                        "未找到可安全修改的方法，未生成新 APK"
                    },
                )
            }
            val output = structuralOutput(source, outputDir = outputDir)
            ApkStructuralOps.repack(
                source = source,
                output = output,
                overrides = byteOverrides,
                overrideFiles = overrides,
                additions = additions,
                additionFiles = additionFiles,
            )
            if (signaturePlan?.mode == ApkSignatureBypassInjector.MODE_ORIGINAL_APK) {
                ApkSignatureBypassInjector.optimizeEmbeddedOriginalApk(output)
            }
            val signatureVerification = signaturePlan?.let {
                ApkSignatureBypassInjector.verifyPrepared(output, it)
            }
            return mapOf(
                "ok" to true,
                "dryRun" to false,
                "changed" to true,
                "outputPath" to output.absolutePath,
                "voidMethods" to voidCount,
                "trueMethods" to trueCount,
                "falseMethods" to falseCount,
                "nopLoadLibrary" to nopCount,
                "vpnDetection" to vpnCount,
                "emulatorDetection" to emulatorCount,
                "rootDetection" to rootCount,
                "debugDetection" to debugCount,
                "screenCaptureDetection" to screenCaptureCount,
                "flagSecure" to flagSecureCount,
                "timeMethods" to timeCount,
                "nullMethods" to nullCount,
                "classMethods" to classHandled,
                "classMethodsSkipped" to classSkipped,
                "splashCountdown" to splashCountdown,
                "signatureBypass" to (signaturePlan?.toMap() ?: emptyMap<String, Any>()),
                "signatureBypassVerification" to (signatureVerification ?: emptyMap<String, Any>()),
                "modifiedDexFiles" to overrides.keys.sorted(),
            )
        } finally {
            temporaryDirectory.deleteRecursively()
        }
    }

    private fun prepareSignatureBypass(
        source: File,
        mode: String,
        originalApk: File?,
        temporaryDirectory: File,
    ): ApkSignatureBypassInjector.Plan = try {
        ApkSignatureBypassInjector.prepare(
            context = context,
            source = source,
            requestedMode = mode,
            originalApk = originalApk,
            temporaryDirectory = temporaryDirectory,
        )
    } catch (error: IllegalArgumentException) {
        throw StructuralError("signature_bypass_failed", error.message ?: "签名兼容处理失败")
    }

    /** 预览结果：各修改类型命中的方法清单（按 dex 分组）。 */
    private data class PatchPreview(
        val voidMethods: List<Map<String, Any>>,
        val matchedMethods: List<Map<String, Any>>,
        val falseMethods: List<Map<String, Any>>,
        val literalLoadLibrary: List<Map<String, Any>>,
        val vpnDetection: List<Map<String, Any>>,
        val emulatorDetection: List<Map<String, Any>>,
        val rootDetection: List<Map<String, Any>>,
        val debugDetection: List<Map<String, Any>>,
        val screenCaptureDetection: List<Map<String, Any>>,
        val flagSecureTargets: List<Map<String, Any>>,
        val timeMethods: List<Map<String, Any>>,
        val nullMethods: List<Map<String, Any>>,
    )

    /**
     * 一次遍历扫描全部预览命中（会员 true / VPN / 模拟器 / Root / 反调试 / 时间）。
     * 只解压一次 dex、加载一次 dexlib2，替代原先 6 个各自全量解压的扫描函数。
     * AC 字节预检用全部 pattern 并集粗筛，未命中直接跳过不加载 dexlib2。
     */
    private fun scanPatchCandidates(
        source: File,
        voidMethods: Set<String>,
        trueMethods: Set<String>,
        falseMethods: Set<String>,
        libKeywords: Set<String>,
        vpnKeywords: Set<String>,
        emulatorKeywords: Set<String>,
        rootKeywords: Set<String>,
        debugKeywords: Set<String>,
        screenCaptureKeywords: Set<String>,
        removeFlagSecure: Boolean,
        timeMethods: Set<String>,
        nullMethods: Set<String>,
    ): PatchPreview {
        val allPatterns = (
            voidMethods + trueMethods + falseMethods + libKeywords + vpnKeywords + emulatorKeywords + rootKeywords +
                debugKeywords + screenCaptureKeywords + timeMethods + nullMethods +
                (if (removeFlagSecure) setOf("setFlags", "addFlags") else emptySet())
            ).map { it.substringAfter("->", it) }.distinct()
        if (allPatterns.isEmpty()) {
            return PatchPreview(
                voidMethods = emptyList(),
                matchedMethods = emptyList(),
                falseMethods = emptyList(),
                literalLoadLibrary = emptyList(),
                vpnDetection = emptyList(),
                emulatorDetection = emptyList(),
                rootDetection = emptyList(),
                debugDetection = emptyList(),
                screenCaptureDetection = emptyList(),
                flagSecureTargets = emptyList(),
                timeMethods = emptyList(),
                nullMethods = emptyList(),
            )
        }
        val voidMatched = mutableListOf<Map<String, Any>>()
        val trueMatched = mutableListOf<Map<String, Any>>()
        val falseMatched = mutableListOf<Map<String, Any>>()
        val literalLoadLibrary = mutableListOf<Map<String, Any>>()
        val vpnMatched = mutableListOf<Map<String, Any>>()
        val emulatorMatched = mutableListOf<Map<String, Any>>()
        val rootMatched = mutableListOf<Map<String, Any>>()
        val debugMatched = mutableListOf<Map<String, Any>>()
        val screenCaptureMatched = mutableListOf<Map<String, Any>>()
        val flagSecureMatched = mutableListOf<Map<String, Any>>()
        val timeMatched = mutableListOf<Map<String, Any>>()
        val nullMatched = mutableListOf<Map<String, Any>>()

        val temporaryDirectory = Files.createTempDirectory("solab_apk_preview_").toFile()
        try {
            withApkZip(source) { zip ->
                zip.entries().asSequence()
                    .filterNot { it.isDirectory }
                    .filter { it.name.matches(DexIo.classesDexRegex) }
                    .forEach { entry ->
                        // 性能优化：zip 流上先 AC 预检，未命中不落盘不加载 dexlib2。
                        if (ApkAhoCorasick(allPatterns).scanStream(zip.getInputStream(entry)).isEmpty()) {
                            return@forEach
                        }
                        val dex = File(temporaryDirectory, File(entry.name).name)
                        zip.getInputStream(entry).use { input -> dex.outputStream().use(input::copyTo) }
                        val dexFile = DexFileFactory.loadDexFile(dex, Opcodes.getDefault())
                        val libHit = ApkDexPatcher.literalLoadLibraryMatches(dexFile, libKeywords)
                        val flagSecureHit = if (removeFlagSecure) {
                            ApkDexPatcher.flagSecurePreviewTargets(dexFile)
                        } else {
                            emptySet()
                        }
                        // 匹配用小写，返回始终保留 DEX 原始方法标识，避免 getisvip
                        // 被误认为 APK 内确实存在的小写符号，也避免依赖猜测混淆类名。
                        val voidHit = linkedSetOf<String>()
                        val trueHit = linkedMapOf<String, String>()
                        val falseHit = linkedSetOf<String>()
                        val vpnHit = linkedMapOf<String, String>()
                        val emulatorHit = linkedMapOf<String, String>()
                        val rootHit = linkedMapOf<String, String>()
                        val debugHit = linkedMapOf<String, String>()
                        val screenCaptureHit = linkedMapOf<String, String>()
                        val timeHit = linkedMapOf<String, String>()
                        val nullHit = linkedMapOf<String, String>()
                        for (classDef in dexFile.classes) {
                            val classType = classDef.type.lowercase()
                            for (method in classDef.methods) {
                                val name = method.name.lowercase()
                                val target = "${classDef.type}->${method.name}"
                                val ret = method.returnType
                                val boolInt = ret == "Z" || ret == "I"
                                if (ret == "V" && ApkDexPatcher.matchesMethodTarget(name, classType, voidMethods)) {
                                    voidHit += target
                                }
                                if (boolInt && ApkDexPatcher.matchesMethodTarget(name, classType, trueMethods)) {
                                    trueHit[target.lowercase()] = target
                                }
                                if (boolInt && ApkDexPatcher.matchesMethodTarget(name, classType, falseMethods)) {
                                    falseHit += target
                                }
                                if (boolInt && vpnKeywords.any { name.contains(it) }) vpnHit[name] = method.name
                                if (boolInt && emulatorKeywords.any { name.contains(it) }) emulatorHit[name] = method.name
                                if (boolInt && rootKeywords.any { name.contains(it) }) rootHit[name] = method.name
                                if (boolInt && debugKeywords.any { name.contains(it) }) debugHit[name] = method.name
                                if (boolInt && screenCaptureKeywords.any { name.contains(it) }) screenCaptureHit[name] = method.name
                                if (ApkDexPatcher.matchesMethodTarget(name, classType, timeMethods) && ret == "J") timeHit[name] = method.name
                                if (ApkDexPatcher.matchesMethodTarget(name, classType, nullMethods) && ret.startsWith("L") && ret != "V") nullHit[name] = method.name
                            }
                        }
                        if (voidHit.isNotEmpty()) {
                            voidMatched += mapOf("dex" to entry.name, "methods" to voidHit.sorted())
                        }
                        if (trueHit.isNotEmpty()) {
                            trueMatched += mapOf("dex" to entry.name, "methods" to trueHit.values.sorted())
                        }
                        if (falseHit.isNotEmpty()) {
                            falseMatched += mapOf("dex" to entry.name, "methods" to falseHit.sorted())
                        }
                        if (libHit.isNotEmpty()) {
                            literalLoadLibrary += mapOf("dex" to entry.name, "methods" to libHit.sorted())
                        }
                        if (vpnHit.isNotEmpty()) {
                            vpnMatched += mapOf("dex" to entry.name, "methods" to vpnHit.values.sorted())
                        }
                        if (emulatorHit.isNotEmpty()) {
                            emulatorMatched += mapOf("dex" to entry.name, "methods" to emulatorHit.values.sorted())
                        }
                        if (rootHit.isNotEmpty()) {
                            rootMatched += mapOf("dex" to entry.name, "methods" to rootHit.values.sorted())
                        }
                        if (debugHit.isNotEmpty()) {
                            debugMatched += mapOf("dex" to entry.name, "methods" to debugHit.values.sorted())
                        }
                        if (screenCaptureHit.isNotEmpty()) {
                            screenCaptureMatched += mapOf("dex" to entry.name, "methods" to screenCaptureHit.values.sorted())
                        }
                        if (flagSecureHit.isNotEmpty()) {
                            flagSecureMatched += mapOf("dex" to entry.name, "methods" to flagSecureHit.sorted())
                        }
                        if (timeHit.isNotEmpty()) {
                            timeMatched += mapOf("dex" to entry.name, "methods" to timeHit.values.sorted())
                        }
                        if (nullHit.isNotEmpty()) {
                            nullMatched += mapOf("dex" to entry.name, "methods" to nullHit.values.sorted())
                        }
                    }
            }
        } finally {
            temporaryDirectory.deleteRecursively()
        }
        return PatchPreview(
            voidMatched, trueMatched, falseMatched, literalLoadLibrary, vpnMatched, emulatorMatched,
            rootMatched, debugMatched, screenCaptureMatched, flagSecureMatched, timeMatched, nullMatched,
        )
    }

    /**
     * 方法定位标识归一化：接受 Lpkg/Class;->name、pkg.Class->name、pkg.Class.methodName，
     * 统一为小写 lpkg/class;->name（与 ApkDexPatcher 匹配语义一致）。
     */
    private fun normalizeClassMethod(raw: String): String {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return ""
        val (classPart, methodPart) = if (trimmed.contains("->")) {
            trimmed.split("->", limit = 2).let { it[0] to it[1] }
        } else {
            val dot = trimmed.lastIndexOf('.')
            if (dot <= 0) return trimmed.lowercase(Locale.ROOT)
            trimmed.substring(0, dot) to trimmed.substring(dot + 1)
        }
        // 缺陷修复：描述符必须是大写 L 前缀 + 分号结尾（Lcom/x/Y;）。
        // 不能整体 lowercase，否则 L 变 l 生成非法描述符（lcom/x/y;），
        // 定位必然失败。这里先剥掉任意大小写的 L 前缀和 ; 后缀，
        // 再统一拼回大写 L + 小写类名 + ;。
        var cls = classPart.trim()
        if (cls.startsWith("l", ignoreCase = true)) cls = cls.substring(1)
        if (cls.endsWith(";")) cls = cls.dropLast(1)
        cls = cls.replace('.', '/').lowercase(Locale.ROOT)
        cls = "L$cls;"
        // A3：方法部分剥签名（A3 后 qualifiedId 为 ->name(params)ret；兼容
        // 旧的无签名传法——两者都归一为方法名，按名匹配）
        var name = methodPart.trim().lowercase(Locale.ROOT)
        val paren = name.indexOf('(')
        if (paren > 0) name = name.substring(0, paren)
        if (name.isEmpty()) return ""
        return "$cls->$name"
    }

    /** 解析 classMethods 每个标识在 DEX 中的真实定义（resolved/unresolved）。 */
    private fun resolveClassMethods(source: File, targets: Set<String>): List<Map<String, Any>> {
        if (targets.isEmpty()) return emptyList()
        val results = mutableListOf<Map<String, Any>>()
        val temporaryDirectory = Files.createTempDirectory("solab_apk_resolve_").toFile()
        try {
            withApkZip(source) { zip ->
                zip.entries().asSequence()
                    .filterNot { it.isDirectory }
                    .filter { it.name.matches(DexIo.classesDexRegex) }
                    .forEach { entry ->
                        // 性能优化：zip 流上先 AC 预检，未命中不落盘不加载 dexlib2。
                        val targetKeywords = targets.map { it.substringAfter("->", it) }
                        if (ApkAhoCorasick(targetKeywords).scanStream(zip.getInputStream(entry)).isEmpty()) {
                            return@forEach
                        }
                        val dex = File(temporaryDirectory, File(entry.name).name)
                        zip.getInputStream(entry).use { input -> dex.outputStream().use(input::copyTo) }
                        val dexFile = DexFileFactory.loadDexFile(dex, Opcodes.getDefault())
                        for (classDef in dexFile.classes) {
                            // 与 normalizeClassMethod 同规则归一化（大写 L + 小写类名 + ;）
                            val classType = ApkDexPatcher.classTypeForMatch(classDef.type)
                            for (method in classDef.methods) {
                                val name = method.name.lowercase()
                                // 精确匹配（全限定）或裸输入 contains 兜底（方法名或类名，
                                // 长度≥4）：ksadsdk/ttadsdk 类名片段也能命中
                                val matched = "$classType->$name" in targets ||
                                    (name.length >= 4 &&
                                        targets.any { !it.contains("->") && name.contains(it) }) ||
                                    (classType.length >= 6 &&
                                        targets.any { !it.contains("->") && classType.contains(it) })
                                if (matched) {
                                    results += mapOf(
                                        "target" to "${classDef.type}->${method.name}",
                                        "resolved" to true,
                                        "className" to classDef.type,
                                        "methodName" to method.name,
                                        "returnType" to method.returnType,
                                        "isVoid" to (method.returnType == "V"),
                                        "isCallback" to ApkDexPatcher.isCallbackOrListener(name),
                                        "dexFile" to entry.name,
                                    )
                                }
                            }
                        }
                    }
            }
        } finally {
            temporaryDirectory.deleteRecursively()
        }
        // 未解析的请求补全为 unresolved（保持与入参一一对应）
        val resolvedIds = results.map { it["target"].toString().lowercase(Locale.ROOT) }.toSet()
        for (target in targets) {
            val resolved = if (target.contains("->")) {
                target.lowercase(Locale.ROOT) in resolvedIds
            } else {
                // 裸输入：任一 resolved 结果的 methodName 或 className contains 即视为命中
                results.any {
                    it["methodName"].toString().lowercase(Locale.ROOT).contains(target) ||
                        it["className"].toString().lowercase(Locale.ROOT).contains(target)
                }
            }
            if (!resolved) {
                results += mapOf(
                    "target" to target,
                    "resolved" to false,
                    "className" to "",
                    "methodName" to "",
                    "returnType" to "",
                    "isVoid" to false,
                    "isCallback" to false,
                    "dexFile" to "",
                )
            }
        }
        return results
    }

    /** 读取 APK 内第一个 AndroidManifest.xml 条目字节（不区分大小写）。 */
    private fun readManifestBytes(source: File): ByteArray {        withApkZip(source) { zip ->
            val entry = zip.entries().asSequence()
                .firstOrNull { !it.isDirectory && it.name.equals("AndroidManifest.xml", ignoreCase = true) }
                ?: throw StructuralError("invalid_apk", "未找到 AndroidManifest.xml")
            return zip.getInputStream(entry).use { input -> input.readBytes() }
        }
    }

    /**
     * B6/B7：二进制 AXML 编辑 Manifest，移除广告组件（需用户显式确认，有跳转崩溃风险）
     * 与广告权限。dryRun 返回命中清单，确认后产出 <原名>_manifest.apk 未签名中间包。
     * auto=true 时按规则库自动计算命中（sdk_packages + 广告组件类 + ad_permissions），
     * 避免调用方手填完整组件名。
     */
    private fun patchManifest(call: MethodCall): Map<String, Any> {
        val source = resolveSource(call)
        val outputDir = outputDirArg(call)
        val removeComponents = (arg(call, "removeComponents") as? List<*>)
            ?.map { it.toString().trim().lowercase(Locale.ROOT) }
            ?.filter { it.isNotEmpty() }
            ?.toSet() ?: emptySet()
        val removePermissions = (arg(call, "removePermissions") as? List<*>)
            ?.map { it.toString().trim().lowercase(Locale.ROOT) }
            ?.filter { it.isNotEmpty() }
            ?.toSet() ?: emptySet()
        // 移除广告 SDK 的 meta-data 配置项（如 com.qq.e.comm.AppId）：SDK 初始化
        // 拿不到配置即不加载广告，比删组件更安全（无跳转崩溃风险）。值为配置键。
        val removeMetaData = (arg(call, "removeMetaData") as? List<*>)
            ?.map { it.toString().trim().lowercase(Locale.ROOT) }
            ?.filter { it.isNotEmpty() }
            ?.toSet() ?: emptySet()
        val auto = arg(call, "auto") as? Boolean ?: false
        val dryRun = arg(call, "dryRun") as? Boolean ?: false
        if (!auto && removeComponents.isEmpty() && removePermissions.isEmpty() && removeMetaData.isEmpty()) {
            throw StructuralError("invalid_args", "至少提供一个 removeComponents/removePermissions/removeMetaData，或 auto=true 按规则自动匹配")
        }

        val manifest = readManifestBytes(source)
        if (!ApkAxmlEditor.isAxml(manifest)) {
            throw StructuralError("invalid_manifest", "AndroidManifest.xml 不是二进制 AXML 格式，无法安全编辑")
        }

        val allComponents = ApkAxmlEditor.listComponents(manifest)
        val allPermissions = ApkAxmlEditor.listPermissions(manifest)
        val allMetaData = ApkAxmlEditor.listMetaData(manifest)

        // 目标集合：显式清单 + auto 规则命中（sdk 包前缀 / 广告组件关键词 / ad_permissions）
        var targetComponents = removeComponents
        var targetPermissions = removePermissions
        var targetMetaData = removeMetaData
        val excludedBusinessComponents = mutableListOf<String>()
        if (auto) {
            val rules = loadRules()
            val matchedComponents = allComponents
                .filter { ApkAxmlEditor.isAdComponentName(it.name, rules.sdkPackages, rules.classPatterns) }
                .map { it.name.lowercase() }
            targetComponents = targetComponents + matchedComponents
            targetPermissions = targetPermissions + rules.adPermissionSet
            // meta-data 配置键命中 SDK 包前缀/关键词（如 com.qq.e.comm.AppId 命中 com.qq.e 前缀）
            val matchedMetaData = allMetaData
                .filter { ApkAxmlEditor.isAdComponentName(it.name, rules.sdkPackages, rules.classPatterns) }
                .map { it.name.lowercase() }
            targetMetaData = targetMetaData + matchedMetaData
            // A1：含业务特征词（vpn/openvpn/ics 等）的组件默认不删除，标黄提示；
            // D2：distinct 去重（manifest 中同名组件多次声明时只提示一次）
            excludedBusinessComponents += allComponents
                .filter { ApkAxmlEditor.isBusinessExcludedComponent(it.name) }
                .map { it.name }
                .distinct()
        }

        val matchedComponents = allComponents
            .filter { it.name.lowercase() in targetComponents }
            .map { mapOf("tag" to it.tag, "name" to it.name) }
        val matchedPermissions = allPermissions
            .filter { it.lowercase() in targetPermissions }
        val matchedMetaData = allMetaData
            .filter { it.name.lowercase() in targetMetaData }
            .map { mapOf("name" to it.name, "value" to (it.value ?: "")) }

        if (dryRun) {
            return mapOf(
                "ok" to true,
                "dryRun" to true,
                "componentRules" to targetComponents.size,
                "permissionRules" to targetPermissions.size,
                "metaDataRules" to targetMetaData.size,
                "matchedComponents" to matchedComponents,
                "matchedPermissions" to matchedPermissions,
                "matchedMetaData" to matchedMetaData,
                // A1：疑似业务组件（含 vpn/openvpn/ics 等特征词）标黄提示，默认不删除
                "excludedBusinessComponents" to excludedBusinessComponents,
                "totalComponents" to allComponents.size,
                "totalPermissions" to allPermissions.size,
                "totalMetaData" to allMetaData.size,
                "message" to "预览仅校验命中；确认后才会重写 Manifest。excludedBusinessComponents 为疑似业务组件（默认不删），如需删除请显式传入 removeComponents",
            )
        }
        if (matchedComponents.isEmpty() && matchedPermissions.isEmpty() && matchedMetaData.isEmpty()) {
            return mapOf(
                "ok" to true,
                "dryRun" to false,
                "changed" to false,
                "removedComponents" to emptyList<Map<String, String>>(),
                "removedPermissions" to emptyList<String>(),
                "removedMetaData" to emptyList<Map<String, String>>(),
                "message" to "Manifest 中未命中任何待移除项，未生成新 APK",
            )
        }

        var edited = manifest
        if (targetComponents.isNotEmpty()) {
            edited = ApkAxmlEditor.removeComponents(edited, targetComponents)
        }
        if (targetPermissions.isNotEmpty()) {
            edited = ApkAxmlEditor.removePermissions(edited, targetPermissions)
        }
        if (targetMetaData.isNotEmpty()) {
            edited = ApkAxmlEditor.removeMetaData(edited, targetMetaData)
        }
        if (edited.contentEquals(manifest)) {
            return mapOf(
                "ok" to true,
                "dryRun" to false,
                "changed" to false,
                "removedComponents" to emptyList<Map<String, String>>(),
                "removedPermissions" to emptyList<String>(),
                "removedMetaData" to emptyList<Map<String, String>>(),
                "message" to "Manifest 编辑后无变化，未生成新 APK",
            )
        }

        val output = structuralOutput(source, outputDir = outputDir)
        ApkStructuralOps.repack(
            source = source,
            output = output,
            overrides = mapOf("AndroidManifest.xml" to edited),
        )
        return mapOf(
            "ok" to true,
            "dryRun" to false,
            "changed" to true,
            "outputPath" to output.absolutePath,
            "removedComponents" to matchedComponents,
            "removedPermissions" to matchedPermissions,
            "removedMetaData" to matchedMetaData,
            "message" to "Manifest 已编辑；删除组件后请实机验证跳转，避免 ActivityNotFoundException",
        )
    }

    /**
     * B8：清理广告 assets 资源。匹配规则（ad_asset_files + SDK 关键词）且未被 DEX 引用的删除；
     * 被引用的只报告不删（先查引用后删）。dryRun 返回候选清单，确认后产出 <原名>_assets.apk。
     */
    private fun cleanAdAssets(call: MethodCall): Map<String, Any> {
        val source = resolveSource(call)
        val outputDir = outputDirArg(call)
        val dryRun = arg(call, "dryRun") as? Boolean ?: false
        val rules = loadRules()
        if (rules.adAssetFiles.isEmpty() && rules.sdkPackages.isEmpty()) {
            throw StructuralError("invalid_args", "规则库缺少 ad_asset_files / sdk_packages，无法清理")
        }

        val configuredPatterns = rules.adAssetFiles.map { it.trim().lowercase() }.filter { it.isNotEmpty() }.toSet()
        val pkgKeywords = ApkAssetScanner.buildAssetKeywords(rules.sdkPackages)

        // 扫描 DEX 字符串引用（先查引用）
        val temporaryDirectory = Files.createTempDirectory("solab_apk_asset_").toFile()
        val dexReferencedAssets = try {
            val dexFiles = mutableListOf<File>()
            withApkZip(source) { zip ->
                zip.entries().asSequence()
                    .filterNot { it.isDirectory }
                    .filter { it.name.matches(DexIo.classesDexRegex) }
                    .forEach { entry ->
                        val dex = File(temporaryDirectory, File(entry.name).name)
                        zip.getInputStream(entry).use { input -> dex.outputStream().use(input::copyTo) }
                        dexFiles.add(dex)
                    }
            }
            ApkAssetScanner.collectDexReferencedAssets(dexFiles)
        } finally {
            temporaryDirectory.deleteRecursively()
        }

        // 收集候选：匹配 + 引用标记。规则命中（用户明确配置）允许直接删除；
        // 仅 SDK 关键词启发式命中的保留 DEX 引用保护（推断项可能误删）。
        data class AssetCandidate(val entryName: String, val relativePath: String, val size: Long, val referenced: Boolean, val matchedConfigured: Boolean, val reason: String)

        val candidates = mutableListOf<AssetCandidate>()
        withApkZip(source) { zip ->
            zip.entries().asSequence()
                .filterNot { it.isDirectory }
                .filter { it.name.startsWith("assets/") }
                .forEach { entry ->
                    val relativePath = entry.name.removePrefix("assets/")
                    val lowerPath = relativePath.lowercase()
                    val fileName = entry.name.substringAfterLast('/').lowercase()

                    val matchedConfigured = configuredPatterns.any { pattern ->
                        lowerPath == pattern || fileName.contains(pattern) || lowerPath.contains("/$pattern")
                    }
                    val matchedBySdk = pkgKeywords.any { kw ->
                        fileName.contains(kw) && fileName.containsAny(ApkAssetScanner.ASSET_AD_HINTS)
                    }
                    if (!matchedConfigured && !matchedBySdk) return@forEach

                    val isDexReferenced = fileName in dexReferencedAssets || lowerPath in dexReferencedAssets
                    val reason = when {
                        matchedConfigured && matchedBySdk -> "规则命中+SDK关键词"
                        matchedConfigured -> "规则命中"
                        else -> "SDK关键词"
                    }
                    candidates.add(
                        AssetCandidate(entry.name, relativePath, entry.size, isDexReferenced, matchedConfigured, reason),
                    )
                }
        }
        candidates.sortBy { it.relativePath }

        // 规则命中的直接删（用户已确认为广告）；仅 SDK 关键词命中且被 DEX 引用的跳过
        val deletable = candidates.filter { it.matchedConfigured || !it.referenced }
        val referenced = candidates.filter { !it.matchedConfigured && it.referenced }

        // C1：res/ 疑似广告资源统计（仅 dryRun 提示，不删除——res 被 R 类
        // 引用，删除有崩溃风险；assets 清理不覆盖 res/ 是刻意的边界）
        val resSuspected = mutableListOf<Map<String, Any>>()
        val resAdHints = listOf(
            "admob", "gdt", "baidu", "ttad", "ksad", "pangle", "ironsource",
            "applovin", "yandex", "mopub", "unityads", "vungle", "ad_", "advert",
        )
        withApkZip(source) { zip ->
            zip.entries().asSequence()
                .filterNot { it.isDirectory }
                .filter { it.name.startsWith("res/") }
                .forEach { entry ->
                    val fileName = entry.name.substringAfterLast('/').lowercase()
                    if (resAdHints.any { fileName.contains(it) }) {
                        resSuspected.add(mapOf("path" to entry.name, "size" to entry.size))
                    }
                }
        }
        resSuspected.sortBy { (it["path"] as String) }

        if (dryRun) {
            return mapOf(
                "ok" to true,
                "dryRun" to true,
                "candidates" to candidates.map {
                    mapOf("path" to it.relativePath, "size" to it.size, "referenced" to it.referenced, "reason" to it.reason)
                },
                "deletableCount" to deletable.size,
                "referencedCount" to referenced.size,
                "savedBytes" to deletable.sumOf { it.size },
                // C1：res/ 疑似广告资源（未纳入清理范围）
                "resSuspectedCount" to resSuspected.size,
                "resSuspected" to resSuspected.take(20),
                "message" to "预览仅统计；规则命中的广告资源直接删除（即使被 DEX 引用），仅 SDK 关键词命中且被 DEX 引用的跳过。确认后清理 assets。res/ 下疑似广告资源（${resSuspected.size} 个）未纳入清理：res 被 R 类引用，删除有崩溃风险，需人工评估",
            )
        }

        if (deletable.isEmpty()) {
            return mapOf(
                "ok" to true,
                "dryRun" to false,
                "changed" to false,
                "deleted" to emptyList<Map<String, Any>>(),
                "referenced" to referenced.map { it.relativePath },
                "message" to "没有可安全删除的广告资源（全部被引用或无命中），未生成新 APK",
            )
        }

        val output = structuralOutput(source, outputDir = outputDir)
        val dropExact = deletable.map { it.entryName }.toSet()
        val result = ApkStructuralOps.repack(source = source, output = output, dropExact = dropExact)
        return mapOf(
            "ok" to true,
            "dryRun" to false,
            "changed" to true,
            "outputPath" to output.absolutePath,
            "deleted" to result.dropped.map { mapOf("path" to it.name, "size" to it.size) },
            "referenced" to referenced.map { it.relativePath },
            "savedBytes" to result.droppedBytes,
        )
    }

    private fun countDropped(source: File, dropPrefixes: List<String>): Pair<Long, Long> {
        if (dropPrefixes.isEmpty()) return 0L to 0L
        var count = 0L
        var bytes = 0L
        withApkZip(source) { zip ->
            zip.entries().asSequence().filterNot { it.isDirectory }.forEach { entry ->
                val name = ApkStructuralOps.normalizeEntryName(entry.name) ?: return@forEach
                if (dropPrefixes.any { ApkStructuralOps.prefixMatches(name, it) }) {
                    count++
                    bytes += entry.size
                }
            }
        }
        return count to bytes
    }

    private fun entryContentFile(content: Any?): File? {
        val map = content as? Map<*, *> ?: return null
        val raw = map["path"] as? String ?: return null
        if (raw.isBlank()) {
            throw StructuralError("invalid_content", "本地 content.path 不能为空")
        }
        if (!File(raw).isAbsolute || raw.split('/', '\\').any { it == ".." }) {
            throw StructuralError("invalid_content", "本地 content.path 必须是合法的绝对路径")
        }
        val file = File(raw)
        if (!file.isFile || file.length() <= 0L) {
            throw StructuralError("invalid_content", "本地 content.path 不存在、不是文件或为空: ${file.absolutePath}")
        }
        return file
    }

    private fun entryContentSize(op: EntryOp): Long =
        op.contentFile?.length() ?: op.content?.size?.toLong()
        ?: throw IllegalStateException("缺少条目内容")

    private fun entryContentSha256(op: EntryOp): String =
        op.contentFile?.let(::sha256) ?: op.content?.let(::sha256)
        ?: throw IllegalStateException("缺少条目内容")

    /** dryRun 压缩体积预估：对新内容跑一次 DEFLATED，返回压缩后字节数（失败 -1）。 */
    private fun estimateDeflatedSize(op: EntryOp): Long {
        val deflater = java.util.zip.Deflater(java.util.zip.Deflater.DEFAULT_COMPRESSION, true)
        try {
            var total = 0L
            val buffer = ByteArray(64 * 1024)
            if (op.content != null) {
                deflater.setInput(op.content)
                deflater.finish()
                while (!deflater.finished()) {
                    total += deflater.deflate(buffer)
                }
            } else if (op.contentFile != null) {
                op.contentFile.inputStream().use { input ->
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) {
                            deflater.finish()
                            while (!deflater.finished()) {
                                total += deflater.deflate(buffer)
                            }
                            break
                        }
                        deflater.setInput(buffer, 0, read)
                        while (!deflater.needsInput() && !deflater.finished()) {
                            total += deflater.deflate(buffer)
                        }
                    }
                }
            } else {
                return -1L
            }
            return total
        } finally {
            deflater.end()
        }
    }

    private fun resultEntry(
        op: EntryOp,
        action: String,
        beforeSha256: String,
        afterSha256: String,
        beforeSize: Long,
        afterSize: Long,
    ): Map<String, Any> = mapOf(
        "locator" to op.locator,
        "action" to action,
        "beforeSha256" to beforeSha256,
        "afterSha256" to afterSha256,
        "beforeSize" to beforeSize,
        "afterSize" to afterSize,
        "contentSource" to op.contentSource,
        "afterSizeMeaning" to if (op.contentSource == "inline_payload") {
            "已传入 base64/hex payload 的真实解码大小；若要预览本地二进制大小，请使用 contentPath"
        } else {
            "本地文件真实大小"
        },
    )

    companion object {
        private val ENTRY_ACTIONS = setOf("overwrite", "add", "delete")

        /** 全量分析输入防护（借鉴玄星 ApkAnalyzer）：APK 大小与条目数上限。 */
        private const val MAX_ANALYZE_BYTES = 512L * 1024L * 1024L
        private const val MAX_ANALYZE_ENTRIES = 100_000

    }
}
