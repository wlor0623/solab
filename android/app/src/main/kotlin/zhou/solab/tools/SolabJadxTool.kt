package zhou.solab.tools

import android.content.Context
import jadx.api.JadxArgs
import jadx.api.JadxDecompiler
import jadx.api.impl.SimpleCodeWriter
import jadx.core.plugins.files.IJadxFilesGetter
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.file.Path

/**
 * A1: jadx DEX→Java 反编译（移植自玄星逆核 JadxTool.kt）。
 *
 * 关键点：jadx 的 config/cache/temp 目录必须重定向到 app 私有 cacheDir
 * （Android 系统 temp 不可写）；NoOpCodeCache + SimpleCodeWriter 降低内存。
 */
object SolabJadxTool {

    // 整包 load/save 的 dex 总量闸门：超过则禁止整包路径（jadx 内存模型对 dex
    // 有约 10 倍膨胀，App 进程堆 512MB 上限下 16MB dex 展开已 160MB+，再叠
    // 加 Flutter 引擎驻留就会把堆压穿——堆耗尽后任何线程分配 16 字节都会
    // FATAL（runCatching 兜不住其他线程的 OOM），必须入口预检拦截）。
    private const val MAX_WHOLE_APK_DEX_BYTES = 16L * 1024 * 1024

    private fun buildArgs(input: File, outDir: File, appCache: File): JadxArgs {
        return JadxArgs().apply {
            setInputFile(input)
            this.outDir = outDir
            // OOM 防护：限线程数压内存峰值；跳过资源解码（代码场景不需要 res/arsc）。
            threadsCount = 2
            isSkipResources = true
            codeWriterProvider = java.util.function.Function { jadxArgs -> SimpleCodeWriter(jadxArgs) }
            // 调研结论（GitHub jadx 官方）：NoOpCodeCache 每次全量重算、处理完即释放，
            // 内存占用最低。曾试过 InMemoryCodeCache 加速重复查询，但它是内存黑洞
            // （全量类驻留缓存），在 App 进程 512MB 堆下把堆压穿导致其他线程 FATAL
            // OOM 闪退——全部路径统一 NoOp，稳定性优先于重复查询速度。
            codeCache = jadx.api.impl.NoOpCodeCache()
            setFilesGetter(object : IJadxFilesGetter {
                override fun getConfigDir(): Path = File(appCache, "jadx-config").apply { mkdirs() }.toPath()
                override fun getCacheDir(): Path = File(appCache, "jadx-cache").apply { mkdirs() }.toPath()
                override fun getTempDir(): Path = File(appCache, "jadx-tmp").apply { mkdirs() }.toPath()
            })
        }
    }

    /** APK 输入的 classesN.dex 总字节量；非 zip/读取失败返回 0（不设闸，走原路径）。 */
    private fun dexTotalBytes(input: File): Long = runCatching {
        java.util.zip.ZipFile(input).use { zip ->
            zip.entries().asSequence()
                .filter { !it.isDirectory && it.name.matches(Regex("classes\\d*\\.dex", RegexOption.IGNORE_CASE)) }
                .sumOf { it.size }
        }
    }.getOrDefault(0L)

    /**
     * 闸门超限时的 list 降级：逐个提取 classesN.dex 单独 load 只收集类名
     * （不反编译，NoOpCodeCache 用完即释放），聚合排序后分页。
     */
    private fun listClassNamesByDex(context: Context, input: File): List<String> {
        val names = sortedSetOf<String>()
        DexIo.eachDex(context, input) { _, dex ->
            dex.classes.forEach { classDef ->
                names.add(
                    classDef.type.removePrefix("L").removeSuffix(";").replace('/', '.'),
                )
            }
        }
        return names.toList()
    }

    private fun extractDexEntry(input: File, appCache: File, dexName: String): File? {
        if (!dexName.matches(Regex("classes\\d*\\.dex", RegexOption.IGNORE_CASE))) return null
        val cacheDir = File(
            appCache,
            "jadx-target/${input.nameWithoutExtension}-${input.length()}-${input.lastModified()}",
        ).apply { mkdirs() }
        return java.util.zip.ZipFile(input).use { zip ->
            val entry = zip.getEntry(dexName) ?: return@use null
            val output = File(cacheDir, dexName)
            if (!output.isFile || output.length() != entry.size) {
                zip.getInputStream(entry).use { ins -> output.outputStream().use { ins.copyTo(it) } }
            }
            output
        }
    }

    fun handle(context: Context, args: JSONObject): JSONObject {
        val (input, inputErr) = resolveInputFile(args)
        if (inputErr != null) return inputErr
        val inputPath = input!!.absolutePath
        val action = args.str("action", "save").ifBlank { "save" }
        val workDir = args.str("workDir")
        if (action == "save" && workDir.isBlank()) {
            return err("WORK_DIRECTORY_REQUIRED", "反编译产物必须写入工作目录，请先设置工作目录", "workDir", workDir)
        }
        val usesInternalCache = workDir.isBlank()
        val appCache = if (usesInternalCache) {
            listOf("jadx-config", "jadx-cache", "jadx-tmp", "jadx-scan", "jadx-target", "jadx-dex-fallback")
                .forEach { runCatching { File(context.cacheDir, it).deleteRecursively() } }
            File(context.cacheDir, "jadx-runtime").apply {
                deleteRecursively()
                mkdirs()
            }
        } else {
            File(workDir, "SoLab/cache/jadx").apply { mkdirs() }
        }

        val result = runCatching {
            when (action) {
                "list" -> {
                    val limit = args.intValue("limit", 500).coerceIn(1, 20000)
                    val offset = args.intValue("offset", 0).coerceAtLeast(0)
                    val outDir = File(appCache, "jadx-scan").apply { mkdirs() }
                    val wholeApk = input.extension.equals("apk", true)
                    if (wholeApk) {
                        // 类名目录不需要 Jadx 反编译。APK 一律直接读取 DEX，避免
                        // 小包也因 Android 宿主的 Jadx 静态初始化失败而误报限制。
                        val all = listClassNamesByDex(context, input)
                        val names = JSONArray()
                        all.drop(offset).take(limit).forEach { names.put(it) }
                        val returned = minOf(limit, maxOf(0, all.size - offset))
                        ok(JSONObject()
                            .put("action", "list")
                            .put("totalClasses", all.size)
                            .put("offset", offset)
                            .put("returned", returned)
                            .put("hasMore", offset + returned < all.size)
                            .put("nextOffset", if (offset + returned < all.size) offset + returned else JSONObject.NULL)
                            .put("note", "已直接读取全部 DEX 类名（排序聚合，未启动整包 Jadx）")
                            .put("classes", names))
                    } else {
                        JadxDecompiler(buildArgs(input, outDir, appCache)).use { jadx ->
                            jadx.load()
                            val names = JSONArray()
                            var skipped = 0
                            var count = 0
                            for (cls in jadx.classes) {
                                if (skipped < offset) { skipped++; continue }
                                if (count >= limit) break
                                names.put(cls.fullName)
                                count++
                            }
                            ok(JSONObject()
                                .put("action", "list")
                                .put("totalClasses", jadx.classes.size)
                                .put("offset", offset)
                                .put("returned", count)
                                .put("hasMore", offset + count < jadx.classes.size)
                                .put("nextOffset", if (offset + count < jadx.classes.size) offset + count else JSONObject.NULL)
                                .put("classes", names))
                        }
                    }
                }

                "class" -> {
                    val className = args.str("className")
                    if (className.isBlank()) {
                        return@runCatching err("INVALID_ARGUMENT", "action=class 需要 className", "className", "")
                    }
                    val outDir = File(appCache, "jadx-scan").apply { mkdirs() }
                    val dexName = args.str("dexName")
                    // 整包 load 在 App 进程下可能 OOM/初始化失败；超闸门或失败时自动降级：
                    // 逐个提取 classesN.dex 到临时文件再找类（单 dex 负载小，已验证可行）
                    val wholeApk = input.extension.equals("apk", true)
                    if (wholeApk && dexName.isNotBlank()) {
                        val dexFile = extractDexEntry(input, appCache, dexName)
                            ?: return@runCatching err(
                                "DEX_NOT_FOUND",
                                "APK 中未找到 dexName: $dexName",
                                "dexName",
                                dexName,
                            )
                        return@runCatching decompileClass(
                            buildArgs(dexFile, outDir, appCache),
                            className,
                        ).put("sourceDex", dexName)
                    }
                    val overLimit = wholeApk && dexTotalBytes(input) > MAX_WHOLE_APK_DEX_BYTES
                    val direct = if (wholeApk && !overLimit) {
                        runCatching {
                            decompileClass(buildArgs(input, outDir, appCache), className)
                        }.getOrNull()
                    } else {
                        null // 超/非 APK 输入走降级路径（异常直接抛给外层 handler）
                    }
                    if (direct != null) return@runCatching direct
                    if (!wholeApk) {
                        JadxDecompiler(buildArgs(input, outDir, appCache)).use { jadx ->
                            jadx.load()
                            val cls = jadx.classes.firstOrNull { it.fullName == className || it.name == className }
                                ?: return@use err("CLASS_NOT_FOUND", "未找到类: $className", "className", className)
                            return@use ok(JSONObject()
                                .put("action", "class")
                                .put("className", cls.fullName)
                                .put("code", cls.code))
                        }
                    }
                    // 降级：逐 dex 找类
                    val fallback = decompileClassFromDexes(input, appCache, className)
                    if (fallback != null) return@runCatching fallback
                    err("CLASS_NOT_FOUND",
                        "未找到类: $className（整包 load 失败后已逐 dex 降级查找仍未命中）。" +
                            "可先用 jadx_decompile(action=list) 确认真实类名（支持 offset 分页），或 dex_search 反查",
                        "className", className)
                }

                else -> { // save
                    // 预检：dex 总量超阈值直接拒绝整包导出（load 阶段就把堆压穿），
                    // 引导分 dex 降级路径，而不是炸掉宿主进程。
                    val dexTotal = dexTotalBytes(input)
                    if (dexTotal > MAX_WHOLE_APK_DEX_BYTES) {
                        return@runCatching err("APK_SAVE_LIMIT_EXCEEDED",
                            "dex 总量 ${dexTotal / 1024 / 1024}MB 超过整包导出上限 ${MAX_WHOLE_APK_DEX_BYTES / 1024 / 1024}MB（App 进程堆有限，" +
                                "load 阶段即 OOM）。降级路径：改用 jadx_decompile(action=class) 只读目标类；" +
                                "或用 action=class 只反编译目标类。", "path", inputPath)
                    }
                    val baseName = safeArtifactName(input.nameWithoutExtension, "jadx")
                    val outDir = File(outputRoot(context, args, "output/jadx"), baseName).apply {
                        if (exists()) deleteRecursively()
                        mkdirs()
                    }
                    JadxDecompiler(buildArgs(input, outDir, appCache)).use { jadx ->
                        jadx.load()
                        val total = jadx.classes.size
                        jadx.save()
                        ok(JSONObject()
                            .put("action", "save")
                            .put("outputDir", outDir.absolutePath)
                            .put("totalClasses", total)
                            .put("hint", "反编译源码已导出到 outputDir,可用文件工具读取具体 .java 文件"))
                    }
                }
            }
        }.getOrElse { e ->
            // save 半途失败会留下不完整的 jadx-out 目录，清掉防止后续误读残件
            runCatching { File(outputRoot(context, args, "output/jadx"), safeArtifactName(input.nameWithoutExtension, "jadx")).deleteRecursively() }
            val causeChain = generateSequence<Throwable>(e) { it.cause }
            val oom = e is OutOfMemoryError || causeChain.any { it is OutOfMemoryError }
            if (oom) {
                err("JADX_OOM",
                    "jadx 内存不足（App 进程堆上限，无法 JVM 提堆）。降级路径：整包不要直接 save，" +
                        "改用 jadx_decompile(action=class) 只读目标类；" +
                        "或用 action=class 只反编译目标类。", "path", inputPath)
            } else {
                // ExceptionInInitializerError 等 jadx 内部静态初始化失败：Android 宿主下
                // 整包 load 常见（线程/内存受限触发），单 dex 可绕过——归为可降级的限制
                val initFailure = causeChain.any { it is ExceptionInInitializerError }
                val code = if (initFailure) "JADX_LIMIT" else "JADX_FAILED"
                val wholeApk = input.extension.equals("apk", true)
                val workaround = if (wholeApk)
                    "整包加载触发 jadx 内部初始化失败（App 进程限制，非 APK 损坏）。按需精准反编译：" +
                        "① dex_search/class_outline/dex_xref 定位目标类所在 dex → ② 对目标类 jadx action=class 精准反编译；" +
                        "仅确需全量源码时才使用 save。勿逐个全量反编译（Flutter 包业务逻辑在 libapp.so，dex 里主要是广告 SDK/原生层）。"
                else
                    "可尝试 action=class 只反编译目标类。"
                err(code, "jadx 反编译失败: ${e.message ?: e.javaClass.simpleName}。$workaround", "path", inputPath)
            }
        }
        if (usesInternalCache) runCatching { appCache.deleteRecursively() }
        return result
    }

    /** 在给定 [args] 配置下 load 并反编译单个类；任何异常向上抛（由调用方决定降级）。 */
    private fun decompileClass(args: JadxArgs, className: String): JSONObject {
        JadxDecompiler(args).use { jadx ->
            jadx.load()
            val cls = jadx.classes.firstOrNull { it.fullName == className || it.name == className }
                ?: return err("CLASS_NOT_FOUND", "未找到类: $className", "className", className)
            return ok(JSONObject()
                .put("action", "class")
                .put("className", cls.fullName)
                .put("code", cls.code))
        }
    }

    /**
     * 整包 load 失败后的降级路径：逐个提取 classesN.dex 到临时文件，
     * 对每个 dex 单独 load 找目标类（单 dex 负载小，可绕过整包 OOM/初始化失败）。
     * 返回 null 表示所有 dex 都没找到（或全部 load 失败）。
     */
    private fun decompileClassFromDexes(input: File, appCache: File, className: String): JSONObject? {
        val dexDir = File(appCache, "jadx-dex-fallback/${input.nameWithoutExtension}").apply {
            deleteRecursively()
            mkdirs()
        }
        return try {
            java.util.zip.ZipFile(input).use { zip ->
                val dexEntries = zip.entries().asSequence()
                    .filter { !it.isDirectory && it.name.matches(Regex("classes\\d*\\.dex", RegexOption.IGNORE_CASE)) }
                    .sortedBy { it.name }
                    .toList()
                for ((index, entry) in dexEntries.withIndex()) {
                    val dexFile = File(dexDir, entry.name)
                    zip.getInputStream(entry).use { ins -> dexFile.outputStream().use { ins.copyTo(it) } }
                    val result = runCatching {
                        decompileClass(
                            buildArgs(dexFile, dexDir, appCache),
                            className,
                        )
                    }.getOrNull()
                    if (result != null && result.optBoolean("ok", false)) {
                        return result.put("sourceDex", entry.name)
                            .put("note", "整包 load 失败，已自动降级为逐 dex 反编译（源自 $entry，第 ${index + 1}/${dexEntries.size} 个）")
                    }
                }
            }
            null
        } finally {
            runCatching { dexDir.deleteRecursively() }
        }
    }
}
