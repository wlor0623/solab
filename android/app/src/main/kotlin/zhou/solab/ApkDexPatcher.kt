package zhou.solab

import org.jf.dexlib2.DexFileFactory
import org.jf.dexlib2.Opcode
import org.jf.dexlib2.Opcodes
import org.jf.dexlib2.iface.ClassDef
import org.jf.dexlib2.iface.DexFile
import org.jf.dexlib2.iface.MethodImplementation
import org.jf.dexlib2.iface.instruction.Instruction
import org.jf.dexlib2.iface.instruction.NarrowLiteralInstruction
import org.jf.dexlib2.iface.instruction.OneRegisterInstruction
import org.jf.dexlib2.iface.instruction.ReferenceInstruction
import org.jf.dexlib2.iface.instruction.TwoRegisterInstruction
import org.jf.dexlib2.iface.instruction.WideLiteralInstruction
import org.jf.dexlib2.iface.instruction.formats.Instruction21c
import org.jf.dexlib2.iface.instruction.formats.Instruction31c
import org.jf.dexlib2.iface.instruction.formats.Instruction35c
import org.jf.dexlib2.iface.instruction.formats.Instruction3rc
import org.jf.dexlib2.iface.reference.MethodReference
import org.jf.dexlib2.iface.reference.StringReference
import org.jf.dexlib2.immutable.ImmutableClassDef
import org.jf.dexlib2.immutable.ImmutableDexFile
import org.jf.dexlib2.immutable.ImmutableMethod
import org.jf.dexlib2.immutable.ImmutableMethodImplementation
import org.jf.dexlib2.immutable.instruction.ImmutableInstruction
import org.jf.dexlib2.immutable.instruction.ImmutableInstruction10x
import org.jf.dexlib2.immutable.instruction.ImmutableInstruction11n
import org.jf.dexlib2.immutable.instruction.ImmutableInstruction11x
import org.jf.dexlib2.immutable.instruction.ImmutableInstruction21ih
import org.jf.dexlib2.immutable.instruction.ImmutableInstruction21s
import org.jf.dexlib2.immutable.instruction.ImmutableInstruction31i
import org.jf.dexlib2.immutable.instruction.ImmutableInstruction51l
import java.io.File
import java.util.Locale

/**
 * DEX 方法级处理引擎（B1/B2/B4 + B5）。
 * 基于 dexlib2 直改，不走 smali 回编译。
 * 规则：本文件注释一律使用单行 //（避免 Kotlin 嵌套注释陷阱）。
 */
internal object ApkDexPatcher {
    private const val FAR_FUTURE_EPOCH_MILLIS = 4909276800000L

    data class Result(
        val voidMethods: Int = 0,
        val forcedTrue: Int = 0,
        val forcedFalse: Int = 0,
        val nopLoadLibrary: Int = 0,
        val vpnNeutralized: Int = 0,
        val emulatorNeutralized: Int = 0,
        val forcedTime: Int = 0,
        val rootNeutralized: Int = 0,
        val debugNeutralized: Int = 0,
        val screenCaptureNeutralized: Int = 0,
        val flagSecureCleared: Int = 0,
        val nullStubbed: Int = 0,
        val classMethodsHandled: Int = 0,
        val classMethodsSkipped: Int = 0,
        val splashCountdownShortened: Int = 0,
    ) {
        val changed
            get() = voidMethods + forcedTrue + forcedFalse + nopLoadLibrary +
                vpnNeutralized + emulatorNeutralized + forcedTime +
                rootNeutralized + debugNeutralized + screenCaptureNeutralized +
                flagSecureCleared + nullStubbed +
                classMethodsHandled + splashCountdownShortened
    }

    /**
     * Root 检测方法关键词（contains 匹配，方法名含任一关键词即命中，强制 false）。
     * 借鉴逆向方法论关键词表（isRooted/checkRoot/su 等）。
     */
    internal val ROOT_DETECT_KEYWORDS = listOf(
        "isrooted", "checkroot", "checkrooted", "hasroot", "hasrooted",
        "rootaccess", "isrooteddevice", "detectroot", "rootdetected",
        "suavailable", "isrootgranted", "checkrootpermission", "rootcheck",
        "isrootavailable", "hasrootaccess", "isdevice_rooted", "isrootedphone",
    )

    /**
     * 反调试/调试器检测关键词（contains 匹配，强制 false）。
     * 借鉴逆向方法论关键词表（isDebuggable/ptrace/isDebuggerConnected 等）。
     */
    internal val DEBUG_DETECT_KEYWORDS = listOf(
        "isdebuggable", "checkdebug", "isdebugging", "isdebuggerconnected",
        "debuggerconnected", "isdebugactive", "detectdebug", "debugdetected",
        "isdebugmode", "isdebugenabled", "isbeingdebugged", "checkdebugger",
        "isdebugattached", "debugstatus", "antidebug", "ptrace", "tracerpid",
    )

    /**
     * VPN 检测方法关键词（contains 匹配，方法名含任一关键词即命中）。
     * 移植自参考项目 DexPatcher.VPN_DETECT_KEYWORDS。
     */
    internal val VPN_DETECT_KEYWORDS = listOf(
        "isvpn", "checkvpn", "vpnconnected", "isvpnconnected",
        "isvpnactive", "vpnactive", "isvpninuse", "vpninuse",
        "isvpnenabled", "isbehindvpn", "hasvpn", "detectvpn",
        "vpnstate", "vpn_connected", "isvpndetected", "isusingvpn",
        "vpninterfacename", "getvpnstate", "isvpnconnection",
        "isvpnused", "isvpnopen",
    )

    /**
     * 模拟器检测方法关键词（contains 匹配）。
     * 移植自参考项目 DexPatcher.EMULATOR_DETECT_KEYWORDS。
     */
    internal val EMULATOR_DETECT_KEYWORDS = listOf(
        "isemulator", "checkemulator", "emulatordetected", "isemulatordetected",
        "isrunningonemulator", "isone2emulator", "isvirtualdevice",
        "isvirtualmachine", "isvm", "detectemulator", "isgenymotion",
        "isbluestacks", "isnox", "ismumu", "isldplayer", "isremixos",
        "isemulatorusingbuild", "isemulatorstate", "isdeviceemulator",
        "isemulatorenv", "isemulatortest", "checkvm", "isvmware",
    )

    /**
     * 截屏/录屏检测方法关键词（contains 匹配 + 检测证据双条件）。
     * 覆盖：API34 ScreenCaptureCallback（onScreenCapture）、自研截图监听、
     * MediaProjection 投屏/录屏状态检测。isrecording 语义偏宽，靠
     * dryRun 预览让调用方确认命中列表后再应用。
     */
    internal val SCREEN_CAPTURE_DETECT_KEYWORDS = listOf(
        "onscreencapture", "screencapturecallback", "onscreenshot",
        "screenshotdetected", "screencapturedetected", "isscreencapture",
        "screencaptureblocked", "isrecording", "isscreenrecording",
        "screenrecordingdetected", "isprojection", "isprojecting",
        "projectionactive", "ismediaprojecting", "iscapturing",
    )

    /**
     * B5：按 SDK 包名推导 so 加载关键词（广告库 so 名 → NOP 目标）。
     * 移植自参考项目 buildSdkLibKeywords。
     */
    internal fun buildSdkLibKeywords(sdkPackages: Collection<String>): Set<String> {
        val keywords = mutableSetOf<String>()
        val joined = sdkPackages.joinToString(" ").lowercase()

        val knownMappings = mapOf(
            "bytedance" to listOf("ttad", "pangle", "openadsdk", "bytedance"),
            "pangle" to listOf("pangle", "ttad"),
            "qq.e" to listOf("gdt", "qqad", "gdtad"),
            "gdt" to listOf("gdt"),
            "baidu" to listOf("baidu", "mobads", "mobad"),
            "kuaishou" to listOf("kuaishou", "gdfp"),
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
            "ironsource" to listOf("ironsource", "is_adapt"),
            "startapp" to listOf("startapp"),
            "smaato" to listOf("smaato"),
            "pubmatic" to listOf("pubmatic"),
            "amazon" to listOf("amazon", "amoad"),
            "yandex" to listOf("yandex"),
            "mytarget" to listOf("mytarget"),
            "huawei" to listOf("huawei_hms", "hms_ads"),
            "sigmob" to listOf("sigmob"),
            "anythink" to listOf("anythink", "topon"),
            "topon" to listOf("topon"),
            "facebook" to listOf("facebook", "fb_ads", "audience"),
            "admob" to listOf("admob", "gms"),
            "googleadb" to listOf("gms"),
            "appodeal" to listOf("appodeal"),
            "pollfish" to listOf("pollfish"),
            "tapjoy" to listOf("tapjoy"),
            "mopub" to listOf("mopub"),
            "pubnative" to listOf("pubnative"),
            "fyber" to listOf("fyber", "inneractive"),
            "oneway" to listOf("oneway"),
        )

        for ((pkgFragment, libNames) in knownMappings) {
            if (joined.contains(pkgFragment)) {
                keywords.addAll(libNames)
            }
        }

        if (joined.contains("adsdk") || joined.contains("_ads")) {
            keywords.add("adsdk")
        }
        return keywords
    }

    fun patch(
        dexFile: File,
        voidMethodNames: Set<String>,
        trueMethodNames: Set<String>,
        falseMethodNames: Set<String>,
        libKeywords: Set<String> = emptySet(),
        vpnDetectKeywords: Set<String> = emptySet(),
        emulatorDetectKeywords: Set<String> = emptySet(),
        timeMethodNames: Set<String> = emptySet(),
        rootDetectKeywords: Set<String> = emptySet(),
        debugDetectKeywords: Set<String> = emptySet(),
        screenCaptureDetectKeywords: Set<String> = emptySet(),
        removeFlagSecure: Boolean = false,
        nullMethodNames: Set<String> = emptySet(),
        exactClassMethods: Set<String> = emptySet(),
        shortenSplashCountdown: Boolean = false,
        stripDebugInfo: Boolean = false,
    ): Result {
        if (voidMethodNames.isEmpty() && trueMethodNames.isEmpty() &&
            falseMethodNames.isEmpty() && libKeywords.isEmpty() &&
            vpnDetectKeywords.isEmpty() && emulatorDetectKeywords.isEmpty() &&
            timeMethodNames.isEmpty() && rootDetectKeywords.isEmpty() &&
            debugDetectKeywords.isEmpty() && screenCaptureDetectKeywords.isEmpty() &&
            !removeFlagSecure && nullMethodNames.isEmpty() &&
            exactClassMethods.isEmpty() && !shortenSplashCountdown
        ) {
            return Result()
        }
        // 性能三件套之一：流式字节预检。方法名与库名在 DEX 中以明文字节存在，
        // 未命中任何模式则跳过 dexlib2 全量加载（大包多 dex 时省下绝大部分 IO）。
        val precheckPatterns = buildSet {
            addAll(voidMethodNames)
            addAll(trueMethodNames)
            addAll(falseMethodNames)
            addAll(libKeywords)
            addAll(vpnDetectKeywords)
            addAll(emulatorDetectKeywords)
            addAll(timeMethodNames)
            addAll(rootDetectKeywords)
            addAll(debugDetectKeywords)
            addAll(screenCaptureDetectKeywords)
            addAll(nullMethodNames)
            addAll(exactClassMethods)
            if (shortenSplashCountdown) add("splash")
            // Window.setFlags/addFlags 的引用名是明文字符串，可作 FLAG_SECURE 预检
            if (removeFlagSecure) {
                add("setFlags")
                add("addFlags")
            }
        }.map { it.substringAfter("->", it) }.toSet()
        if (precheckPatterns.isNotEmpty() &&
            ApkAhoCorasick(precheckPatterns.toList()).scanFile(dexFile).isEmpty()
        ) {
            return Result()
        }
        val dex = DexFileFactory.loadDexFile(dexFile, Opcodes.getDefault())
        var voidCount = 0
        var trueCount = 0
        var falseCount = 0
        var nopCount = 0
        var vpnCount = 0
        var emulatorCount = 0
        var timeCount = 0
        var rootCount = 0
        var debugCount = 0
        var screenCaptureCount = 0
        var flagSecureCount = 0
        var nullCount = 0
        var classHandled = 0
        var classSkipped = 0
        var splashCountdownShortened = 0
        val classes = dex.classes.map { classDef ->
            try {
            var classChanged = false
            // 缺陷回归修复：匹配端归一化必须与 normalizeClassMethod 完全一致
            // （大写 L + 小写类名 + ;），不能整体 lowercase（会把 L 变 l 导致
            // 与合法描述符 Lcom/x/y; 精确匹配失败 → 0 命中）。
            val classType = classDef.type.lowercase()
            val exactClass = classTypeForMatch(classDef.type)
            val methods = classDef.methods.map { method ->
                val implementation = method.implementation
                val name = method.name.lowercase()
                if (implementation == null || name == "<init>" || name == "<clinit>") {
                    ImmutableMethod.of(method)
                } else {
                    // 方法级定位（classMethods）：全限定标识精确匹配，按返回类型自动分发
                    // 兜底（大小写不敏感）：裸输入（无 ->，如 ksadsdk/ttadsdk 类名片段
                    // 或方法名）做 contains 匹配（长度≥4），方法名或类名命中皆可。
                    val exactHit = "$exactClass->$name" in exactClassMethods ||
                        (name.length >= 4 &&
                            exactClassMethods.any { !it.contains("->") && name.contains(it) }) ||
                        (exactClass.length >= 6 &&
                            exactClassMethods.any { !it.contains("->") && exactClass.contains(it) })
                    val replacement = when {
                        libKeywords.isNotEmpty() -> {
                            // B5：优先尝试 NOP 广告库加载调用（保留 tryBlocks/debugItems）
                            val nopPatch = nopOutAdLibLoadLibrary(implementation, libKeywords)
                            if (nopPatch != null) {
                                nopCount += nopPatch.count
                                classChanged = true
                                buildMethod(method, nopPatch.implementation)
                            } else {
                                null
                            }
                        }
                        // FLAG_SECURE 剥离：清除流入 Window.setFlags/addFlags 常量中的
                        // FLAG_SECURE 位（保留同常量其他 flag），命中即改写并短路后续规则
                        removeFlagSecure -> stripFlagSecureImpl(implementation)?.let {
                            flagSecureCount++
                            classChanged = true
                            buildMethod(method, it)
                        }
                        else -> null
                    }
                    if (replacement != null) {
                        replacement
                    } else {
                        when {
                            exactHit && !isCallbackOrListener(name) && method.returnType == "V" -> {
                                classHandled++
                                classChanged = true
                                buildMethod(
                                    method,
                                    ImmutableMethodImplementation(
                                        implementation.registerCount.coerceAtLeast(1),
                                        listOf(ImmutableInstruction10x(Opcode.RETURN_VOID)),
                                        emptyList(),
                                        emptyList(),
                                    ),
                                )
                            }
                            exactHit && !isCallbackOrListener(name) &&
                                (method.returnType == "Z" || method.returnType == "I") -> {
                                classHandled++
                                classChanged = true
                                buildMethod(
                                    method,
                                    ImmutableMethodImplementation(
                                        implementation.registerCount.coerceAtLeast(1),
                                        listOf(
                                            ImmutableInstruction11n(Opcode.CONST_4, 0, 0),
                                            ImmutableInstruction11x(Opcode.RETURN, 0),
                                        ),
                                        emptyList(),
                                        emptyList(),
                                    ),
                                )
                            }
                            exactHit -> {
                                // 回调方法或返回类型不支持（L/J/数组）：跳过并计数
                                classSkipped++
                                ImmutableMethod.of(method)
                            }
                            method.returnType == "V" &&
                                matchesMethodTarget(name, classType, voidMethodNames) &&
                                !isCallbackOrListener(name) -> {
                                voidCount++
                                classChanged = true
                                buildMethod(
                                    method,
                                    ImmutableMethodImplementation(
                                        implementation.registerCount.coerceAtLeast(1),
                                        listOf(ImmutableInstruction10x(Opcode.RETURN_VOID)),
                                        emptyList(),
                                        emptyList(),
                                    ),
                                )
                            }
                            method.returnType == "Z" || method.returnType == "I" -> when {
                                matchesMethodTarget(name, classType, trueMethodNames) -> {
                                    trueCount++
                                    classChanged = true
                                    buildMethod(
                                        method,
                                        ImmutableMethodImplementation(
                                            implementation.registerCount.coerceAtLeast(1),
                                            listOf(
                                                ImmutableInstruction11n(Opcode.CONST_4, 0, 1),
                                                ImmutableInstruction11x(Opcode.RETURN, 0),
                                            ),
                                            emptyList(),
                                            emptyList(),
                                        ),
                                    )
                                }
                                // 检测规避：VPN/模拟器/Root/反调试/截屏录屏检测方法强制 false（= 未检测到）。
                                // v3.0.1 借鉴：名字命中 + 方法体证据 双条件，防误伤业务方法。
                                (isDetectionMethod(name, vpnDetectKeywords) ||
                                    isDetectionMethod(name, emulatorDetectKeywords) ||
                                    isDetectionMethod(name, rootDetectKeywords) ||
                                    isDetectionMethod(name, debugDetectKeywords) ||
                                    isDetectionMethod(name, screenCaptureDetectKeywords)) &&
                                    methodHasDetectionEvidence(implementation) -> {
                                    when {
                                        isDetectionMethod(name, vpnDetectKeywords) -> vpnCount++
                                        isDetectionMethod(name, emulatorDetectKeywords) -> emulatorCount++
                                        isDetectionMethod(name, rootDetectKeywords) -> rootCount++
                                        isDetectionMethod(name, debugDetectKeywords) -> debugCount++
                                        else -> screenCaptureCount++
                                    }
                                    classChanged = true
                                    buildMethod(
                                        method,
                                        ImmutableMethodImplementation(
                                            implementation.registerCount.coerceAtLeast(1),
                                            listOf(
                                                ImmutableInstruction11n(Opcode.CONST_4, 0, 0),
                                                ImmutableInstruction11x(Opcode.RETURN, 0),
                                            ),
                                            emptyList(),
                                            emptyList(),
                                        ),
                                    )
                                }
                                matchesMethodTarget(name, classType, falseMethodNames) -> {
                                    falseCount++
                                    classChanged = true
                                    buildMethod(
                                        method,
                                        ImmutableMethodImplementation(
                                            implementation.registerCount.coerceAtLeast(1),
                                            listOf(
                                                ImmutableInstruction11n(Opcode.CONST_4, 0, 0),
                                                ImmutableInstruction11x(Opcode.RETURN, 0),
                                            ),
                                            emptyList(),
                                            emptyList(),
                                        ),
                                    )
                                }
                                else -> ImmutableMethod.of(method)
                            }
                            // 时间劫持：到期/剩余时间方法（long 返回）强制到 2125 年。
                    method.returnType == "J" && matchesMethodTarget(name, classType, timeMethodNames) -> {
                                timeCount++
                                classChanged = true
                                buildMethod(
                                    method,
                                    ImmutableMethodImplementation(
                                        implementation.registerCount.coerceAtLeast(2),
                                        listOf(
                                            ImmutableInstruction51l(Opcode.CONST_WIDE, 0, FAR_FUTURE_EPOCH_MILLIS),
                                            ImmutableInstruction11x(Opcode.RETURN_WIDE, 0),
                                        ),
                                        emptyList(),
                                        emptyList(),
                                    ),
                                )
                            }
                            // REQ-06：对象返回方法存根返回 null
                            method.returnType.startsWith("L") &&
                                method.returnType != "V" &&
                    matchesMethodTarget(name, classType, nullMethodNames) -> {
                                nullCount++
                                classChanged = true
                                buildMethod(
                                    method,
                                    ImmutableMethodImplementation(
                                        implementation.registerCount.coerceAtLeast(1),
                                        listOf(
                                            ImmutableInstruction11n(Opcode.CONST_4, 0, 0),
                                            ImmutableInstruction11x(Opcode.RETURN_OBJECT, 0),
                                        ),
                                        emptyList(),
                                        emptyList(),
                                    ),
                                )
                            }
                            else -> ImmutableMethod.of(method)
                        }
                    }
                }
            }
            if (!classChanged) {
                // 开屏倒计时缩短：类名含 splash 的类，即使其它规则未命中也尝试缩短倒计时
                if (shortenSplashCountdown) {
                    val splash = shortenSplashCountdown(classDef)
                    if (splash != null) {
                        splashCountdownShortened += splash.second
                        splash.first
                    } else {
                        classDef
                    }
                } else {
                    classDef
                }
            } else {
                // 已修改的类：也应用倒计时缩短（splash 类）
                val rebuilt = ImmutableClassDef(
                    classDef.type,
                    classDef.accessFlags,
                    classDef.superclass,
                    classDef.interfaces.toList(),
                    classDef.sourceFile,
                    classDef.annotations.toSet(),
                    classDef.fields.toList(),
                    methods,
                )
                if (shortenSplashCountdown) {
                    val splash = shortenSplashCountdown(rebuilt)
                    if (splash != null) {
                        splashCountdownShortened += splash.second
                        splash.first
                    } else {
                        rebuilt
                    }
                } else {
                    rebuilt
                }
            }
            } catch (e: Exception) {
                // D1：类内方法指令损坏（截断/畸形，如 fastjson2 反序列化类）——
                // 跳过该类原样保留，不拖垮整个 dex 的修改；其余类照常写回。
                classSkipped++
                classDef
            }
        }
        val result = Result(
            voidCount, trueCount, falseCount, nopCount, vpnCount,
            emulatorCount, timeCount, rootCount, debugCount,
            screenCaptureCount, flagSecureCount, nullCount,
            classHandled, classSkipped, splashCountdownShortened,
        )
        if (result.changed == 0) return result
        // 写回：先 .bak 备份（OOM/写盘失败可恢复）→ .tmp 写入 → rename 原子替换 → 删备份
        val backup = File(dexFile.parentFile, "${dexFile.name}.bak")
        val temporary = File(dexFile.parentFile, "${dexFile.name}.tmp")
        try {
            if (dexFile.exists()) dexFile.copyTo(backup, overwrite = true)
            // 性能优化：classes 已全部 Immutable 重建，这里显式释放
            // dex-backed 引用并 GC，写盘前降低堆占用，防大包 OOM。
            System.gc()
            // 体积优化（借鉴 2.9）：写回前全量剥离 debug info（行号/局部变量表/参数名），
            // 减小 DEX 体积 5%~15%，不影响运行功能；仅对本次已修改的 DEX 生效。
            val finalClasses = if (stripDebugInfo) {
                stripDebugInfoFromClasses(classes)
            } else {
                classes
            }
            DexFileFactory.writeDexFile(temporary.absolutePath, ImmutableDexFile(Opcodes.getDefault(), finalClasses))
            if (!temporary.renameTo(dexFile)) {
                temporary.copyTo(dexFile, overwrite = true)
                temporary.delete()
            }
            backup.delete()
        } catch (error: Throwable) {
            temporary.delete()
            if (backup.exists() && dexFile.exists()) {
                dexFile.delete()
                backup.copyTo(dexFile, overwrite = true)
            }
            backup.delete()
            throw error
        }
        return result
    }

    /**
     * 全量剥离 debug info（借鉴参考项目 2.9 stripDebugInfoFromClasses）：
     * 重建方法体并传空 debug items，dexlib2 写回时 debug_info_off 置 0，
     * 对应数据段被丢弃；tryBlocks 原样保留（异常处理链不受影响）。
     */
    private fun stripDebugInfoFromClasses(classes: List<ClassDef>): List<ImmutableClassDef> {
        val result = ArrayList<ImmutableClassDef>(classes.size)
        for (classDef in classes) {
            // 快速路径：类内没有任何带方法体的方法，直接 Immutable 包装复用
            var hasImpl = false
            for (m in classDef.methods) {
                if (m.implementation != null) {
                    hasImpl = true
                    break
                }
            }
            if (!hasImpl) {
                result.add(ImmutableClassDef.of(classDef))
                continue
            }
            val newMethods = ArrayList<ImmutableMethod>(classDef.methods.count())
            for (method in classDef.methods) {
                val impl = method.implementation
                if (impl == null) {
                    newMethods.add(ImmutableMethod.of(method))
                    continue
                }
                // 重建方法体：instructions/tryBlocks 保留，debug items 置空
                newMethods.add(
                    ImmutableMethod(
                        method.definingClass,
                        method.name,
                        method.parameters.toList(),
                        method.returnType,
                        method.accessFlags,
                        method.annotations.toSet(),
                        method.hiddenApiRestrictions.toSet(),
                        ImmutableMethodImplementation(
                            impl.registerCount,
                            impl.instructions,
                            impl.tryBlocks.toList(),
                            emptyList(),
                        ),
                    ),
                )
            }
            result.add(
                ImmutableClassDef(
                    classDef.type,
                    classDef.accessFlags,
                    classDef.superclass,
                    classDef.interfaces.toList(),
                    classDef.sourceFile,
                    classDef.annotations.toSet(),
                    classDef.fields.toList(),
                    newMethods,
                ),
            )
        }
        return result
    }

    private fun buildMethod(method: org.jf.dexlib2.iface.Method, impl: ImmutableMethodImplementation): ImmutableMethod =
        ImmutableMethod(
            method.definingClass,
            method.name,
            method.parameters.toList(),
            method.returnType,
            method.accessFlags,
            method.annotations.toSet(),
            method.hiddenApiRestrictions.toSet(),
            impl,
        )

    /** 回调/监听/观察者方法永不置空：on* / setXxxListener / callback / observer / vpaid。 */
    internal fun isCallbackOrListener(name: String): Boolean {
        if (name.startsWith("on")) return true
        if (name.startsWith("set") && name.contains("listener")) return true
        return name.contains("callback") || name.contains("observer") || name.contains("vpaid")
    }

    // ---------- VPN/模拟器检测误伤修复 ----------

    /** 检测证据字符串：方法体引用这些字符串/类型才算真正的环境检测方法，
     * 仅名字 contains 会误伤业务方法（如 isVpnService 只是业务逻辑）。 */
    private val DETECTION_EVIDENCE = listOf(
        "java/net/networkinterface", "networkinterface", "getnetworkinterfaces",
        "getinetaddresses", "java/net/socket",
        "android/os/build", "build.fingerprint",
        "getproperty", "systemproperties", "getprop",
        "java/lang/system", "java/util/vector",
        "java/lang/runtime", "java/io/file", "java/io/bufferedreader",
        "java/io/inputstream", "exec(",
        "getsystemservice", "connectivitymanager", "ethernetmanager",
        "settings.secure", "contentresolver", "wifiinfo",
        "net/eth", "dev/qemu", "microsoft/windows", "genymotion", "bluestacks",
    )

    /** 方法体是否引用检测证据（名字命中 + 证据命中的双条件才算检测方法）。 */
    internal fun methodHasDetectionEvidence(impl: MethodImplementation): Boolean {
        for (ins in impl.instructions) {
            val ref = (ins as? ReferenceInstruction)?.reference ?: continue
            val s = ref.toString().lowercase()
            for (keyword in DETECTION_EVIDENCE) {
                if (s.contains(keyword)) return true
            }
        }
        return false
    }

    /**
     * 类型描述符归一化（与 SolabChannel.normalizeClassMethod 同规则）：
     * 剥任意大小写 L 前缀和 ; 后缀 → 内部小写 → 拼回大写 L + ;。
     * Lcom/x/Y; -> Lcom/x/y;。用于与 classMethods（qualifiedId）精确匹配。
     */
    internal fun classTypeForMatch(type: String): String {
        var t = type
        if (t.startsWith("l", ignoreCase = true)) t = t.substring(1)
        if (t.endsWith(";")) t = t.dropLast(1)
        t = t.replace('.', '/').lowercase(Locale.ROOT)
        return "L$t;"
    }

    /** 检测方法判定：方法名 contains 任一关键词（VPN/模拟器检测）。 */
    private fun isDetectionMethod(name: String, keywords: Set<String>): Boolean {
        if (keywords.isEmpty()) return false
        return keywords.any { name.contains(it) }
    }

    // ---------- 开屏广告倒计时缩短 ----------

    /**
     * 开屏广告倒计时缩短：类名含 splash 的类中，追踪 CONST 常量写入寄存器的值，
     * 命中 Handler.postDelayed / sendEmptyMessageDelayed / sendMessageDelayed /
     * CountDownTimer.<init> 且延迟 ≥1000ms 时，把最近写入该延迟寄存器的 const 置 0
     * → 倒计时立即结束、直接进入主界面。
     */
    internal fun shortenSplashCountdown(
        classDef: ClassDef,
    ): Pair<ImmutableClassDef, Int>? {
        val lowerType = classDef.type.lowercase()
        if (!lowerType.contains("splash")) return null
        if (classDef.methods.none { it.implementation != null }) return null
        var shortened = 0
        var changed = false
        val newMethods = ArrayList<org.jf.dexlib2.iface.Method>(classDef.methods.count())
        for (method in classDef.methods) {
            val impl = method.implementation
            if (impl == null) {
                newMethods.add(ImmutableMethod.of(method))
                continue
            }
            val newImpl = shortenSplashCountdownImpl(impl)
            if (newImpl != null) {
                newMethods.add(buildMethod(method, newImpl))
                shortened++
                changed = true
            } else {
                // 未修改方法也深拷贝并丢弃 debug_info（与性能策略一致：写盘快、体积小）
                try {
                    newMethods.add(
                        ImmutableMethod(
                            method.definingClass, method.name, method.parameters.toList(),
                            method.returnType, method.accessFlags,
                            method.annotations.toSet(), method.hiddenApiRestrictions.toSet(),
                            ImmutableMethodImplementation(
                                impl.registerCount.coerceAtLeast(1),
                                impl.instructions,
                                impl.tryBlocks.toList(),
                                emptyList(),
                            ),
                        ),
                    )
                } catch (_: Exception) {
                    newMethods.add(method)
                }
            }
        }
        if (!changed) return null
        val newClass = ImmutableClassDef(
            classDef.type, classDef.accessFlags, classDef.superclass,
            classDef.interfaces.toList(), classDef.sourceFile,
            classDef.annotations.toSet(), classDef.fields.toList(), newMethods,
        )
        return Pair(newClass, shortened)
    }

    /** 单方法倒计时缩短：返回新 impl（有修改）或 null（无修改）。 */
    private fun shortenSplashCountdownImpl(impl: MethodImplementation): ImmutableMethodImplementation? {
        // 寄存器号 -> (指令下标, 常量值, 原指令)
        val recentConsts = HashMap<Int, Triple<Int, Long, org.jf.dexlib2.iface.instruction.Instruction>>()
        val newInstructions = mutableListOf<ImmutableInstruction>()
        // ImmutableInstruction 未重写 equals（identity 语义），不能靠逐条比较
        // 判断是否有修改；显式计数真实改写次数（否则 splash 类里所有方法
        // 都会被误判为已修改并重复重编码）。
        var rewritten = 0

        for (ins in impl.instructions) {
            if (isConstLiteral(ins)) {
                val reg = (ins as? OneRegisterInstruction)?.registerA ?: -1
                val value = constLiteralValue(ins)
                if (reg >= 0 && value != null) {
                    recentConsts[reg] = Triple(newInstructions.size, value, ins)
                }
                newInstructions.add(ImmutableInstruction.of(ins))
                continue
            }
            clearTrackedRegister(ins, recentConsts)
            if (isCountdownInvoke(ins)) {
                val delayReg = countdownDelayRegister(ins)
                val tracked = recentConsts[delayReg]
                if (delayReg >= 0 && tracked != null && tracked.second >= 1000L) {
                    // 把延迟常量置 0 → 倒计时立即结束进入主界面
                    newInstructions[tracked.first] = makeZeroConst(tracked.third)
                    rewritten++
                }
            }
            newInstructions.add(ImmutableInstruction.of(ins))
        }

        if (rewritten == 0) return null
        // 丢弃 debug_info（与性能策略一致：写盘更快、体积更小）
        return ImmutableMethodImplementation(
            impl.registerCount.coerceAtLeast(1),
            newInstructions,
            impl.tryBlocks.toList(),
            emptyList(),
        )
    }

    private fun makeZeroConst(ins: org.jf.dexlib2.iface.instruction.Instruction): ImmutableInstruction {
        val reg = (ins as? OneRegisterInstruction)?.registerA ?: 0
        return when (ins.opcode) {
            Opcode.CONST_4 -> ImmutableInstruction11n(Opcode.CONST_4, reg, 0)
            Opcode.CONST_16 -> ImmutableInstruction21s(Opcode.CONST_16, reg, 0)
            Opcode.CONST -> ImmutableInstruction31i(Opcode.CONST, reg, 0)
            Opcode.CONST_HIGH16 -> ImmutableInstruction21ih(Opcode.CONST_HIGH16, reg, 0)
            Opcode.CONST_WIDE_16 -> ImmutableInstruction21s(Opcode.CONST_WIDE_16, reg, 0)
            Opcode.CONST_WIDE_32 -> ImmutableInstruction31i(Opcode.CONST_WIDE_32, reg, 0)
            Opcode.CONST_WIDE -> ImmutableInstruction51l(Opcode.CONST_WIDE, reg, 0)
            Opcode.CONST_WIDE_HIGH16 -> ImmutableInstruction21ih(Opcode.CONST_WIDE_HIGH16, reg, 0)
            else -> ImmutableInstruction.of(ins)
        }
    }

    private fun isConstLiteral(ins: org.jf.dexlib2.iface.instruction.Instruction): Boolean {
        val op = ins.opcode
        return op == Opcode.CONST_4 || op == Opcode.CONST_16 || op == Opcode.CONST ||
            op == Opcode.CONST_HIGH16 || op == Opcode.CONST_WIDE_16 ||
            op == Opcode.CONST_WIDE_32 || op == Opcode.CONST_WIDE || op == Opcode.CONST_WIDE_HIGH16
    }

    private fun constLiteralValue(ins: org.jf.dexlib2.iface.instruction.Instruction): Long? {
        return when (ins) {
            is WideLiteralInstruction -> ins.wideLiteral
            is NarrowLiteralInstruction -> ins.narrowLiteral.toLong()
            else -> null
        }
    }

    private fun clearTrackedRegister(
        ins: org.jf.dexlib2.iface.instruction.Instruction,
        recentConsts: HashMap<Int, Triple<Int, Long, org.jf.dexlib2.iface.instruction.Instruction>>,
    ) {
        // invoke 指令只读不写，不清理（延迟常量常在 invoke 前写入该寄存器）
        if (ins is Instruction35c || ins is Instruction3rc) return
        val writtenReg: Int = when (ins) {
            is OneRegisterInstruction -> ins.registerA
            is TwoRegisterInstruction -> ins.registerA
            else -> -1
        }
        if (writtenReg >= 0) recentConsts.remove(writtenReg)
    }

    private fun isCountdownInvoke(ins: org.jf.dexlib2.iface.instruction.Instruction): Boolean {
        val ref = (ins as? ReferenceInstruction)?.reference as? MethodReference ?: return false
        val clazz = ref.definingClass
        val name = ref.name
        return when {
            clazz == "Landroid/os/Handler;" && (name == "postDelayed" ||
                name == "sendEmptyMessageDelayed" || name == "sendMessageDelayed") -> true
            clazz == "Landroid/os/CountDownTimer;" && name == "<init>" -> true
            else -> false
        }
    }

    private fun countdownDelayRegister(ins: org.jf.dexlib2.iface.instruction.Instruction): Int {
        val ref = (ins as? ReferenceInstruction)?.reference as? MethodReference ?: return -1
        return when {
            // Handler.postDelayed(runnable, delay)：35c 寄存器 E 为第 5 参数；3rc start+2 为第 3 参数
            ref.definingClass == "Landroid/os/Handler;" && ins is Instruction35c -> ins.registerE
            ref.definingClass == "Landroid/os/Handler;" && ins is Instruction3rc -> ins.startRegister + 2
            // CountDownTimer(millisInFuture, countDownInterval)：35c 寄存器 D 为第 4 参数
            ref.definingClass == "Landroid/os/CountDownTimer;" && ins is Instruction35c -> ins.registerD
            ref.definingClass == "Landroid/os/CountDownTimer;" && ins is Instruction3rc -> ins.startRegister + 1
            else -> -1
        }
    }

    // ---------- FLAG_SECURE（禁止截屏）剥离 ----------

    /** WindowManager.LayoutParams.FLAG_SECURE。 */
    private const val FLAG_SECURE_BITS = 0x2000L

    /**
     * 单方法 FLAG_SECURE 剥离：把流入 Window.setFlags/addFlags 的常量中的
     * FLAG_SECURE 位清零，同常量里的其他 flag 位保留（0x2008 → 0x0008）。
     * 相比 void 掉 onCreate 或 NOP 整条 invoke，这里只动 flag 位本身，
     * 不会破坏同一调用里的 FLAG_FULLSCREEN 等其他窗口行为。
     * 返回新 impl（有修改）或 null（无修改）。
     */
    private fun stripFlagSecureImpl(impl: MethodImplementation): ImmutableMethodImplementation? {
        val recentConsts = HashMap<Int, Triple<Int, Long, org.jf.dexlib2.iface.instruction.Instruction>>()
        val newInstructions = mutableListOf<ImmutableInstruction>()
        // ImmutableInstruction 未重写 equals（identity 语义），不能靠逐条比较
        // 判断是否有修改；显式计数真实改写次数。
        var rewritten = 0

        for (ins in impl.instructions) {
            if (isConstLiteral(ins)) {
                val reg = (ins as? OneRegisterInstruction)?.registerA ?: -1
                val value = constLiteralValue(ins)
                if (reg >= 0 && value != null) {
                    recentConsts[reg] = Triple(newInstructions.size, value, ins)
                }
                newInstructions.add(ImmutableInstruction.of(ins))
                continue
            }
            clearTrackedRegister(ins, recentConsts)
            if (isWindowFlagsInvoke(ins)) {
                for (reg in windowFlagsArgumentRegisters(ins)) {
                    val tracked = recentConsts[reg] ?: continue
                    if (tracked.second and FLAG_SECURE_BITS != 0L) {
                        newInstructions[tracked.first] = makeMaskedConst(tracked.third, FLAG_SECURE_BITS.inv())
                        rewritten++
                    }
                }
            }
            newInstructions.add(ImmutableInstruction.of(ins))
        }

        if (rewritten == 0) return null
        return ImmutableMethodImplementation(
            impl.registerCount.coerceAtLeast(1),
            newInstructions,
            impl.tryBlocks.toList(),
            emptyList(),
        )
    }

    /** 预览辅助：DEX 内会被 FLAG_SECURE 剥离改写的方法 qualifiedId。 */
    internal fun flagSecurePreviewTargets(dex: DexFile): Set<String> {
        val matches = linkedSetOf<String>()
        for (classDef in dex.classes.asSequence()) {
            for (method in classDef.methods.asSequence()) {
                val impl = method.implementation ?: continue
                // 快速预筛：只有引用 Window.setFlags/addFlags 的方法才走完整改写模拟
                if (impl.instructions.none { isWindowFlagsInvoke(it) }) continue
                if (stripFlagSecureImpl(impl) != null) {
                    matches += "${classDef.type}->${method.name}"
                }
            }
        }
        return matches
    }

    private fun isWindowFlagsInvoke(ins: org.jf.dexlib2.iface.instruction.Instruction): Boolean {
        val ref = (ins as? ReferenceInstruction)?.reference as? MethodReference ?: return false
        if (ref.definingClass != "Landroid/view/Window;") return false
        return ref.name == "setFlags" || ref.name == "addFlags"
    }

    /** Window.setFlags(flags, mask) / addFlags(flags) 的 int 参数寄存器（跳过 this）。 */
    private fun windowFlagsArgumentRegisters(ins: org.jf.dexlib2.iface.instruction.Instruction): List<Int> {
        val ref = (ins as? ReferenceInstruction)?.reference as? MethodReference ?: return emptyList()
        val paramCount = if (ref.name == "setFlags") 2 else 1
        return when (ins) {
            is Instruction35c -> when (paramCount) {
                // 35c 参数序：C=this, D=第1参数, E=第2参数
                1 -> listOf(ins.registerD)
                else -> listOf(ins.registerD, ins.registerE)
            }
            is Instruction3rc -> (1..paramCount).map { ins.startRegister + it }
            else -> emptyList()
        }
    }

    /** 清除常量中的 FLAG_SECURE 位并按原操作码重新编码（保留其他 flag 位）。 */
    private fun makeMaskedConst(
        ins: org.jf.dexlib2.iface.instruction.Instruction,
        clearMask: Long,
    ): ImmutableInstruction {
        val reg = (ins as? OneRegisterInstruction)?.registerA ?: 0
        val masked = (constLiteralValue(ins) ?: 0L) and clearMask
        return when (ins.opcode) {
            Opcode.CONST_4 -> ImmutableInstruction11n(Opcode.CONST_4, reg, masked.toInt())
            Opcode.CONST_16 -> ImmutableInstruction21s(Opcode.CONST_16, reg, masked.toInt())
            Opcode.CONST -> ImmutableInstruction31i(Opcode.CONST, reg, masked.toInt())
            // HIGH16 编码的是 value >> 12 的立即数，需先移位
            Opcode.CONST_HIGH16 -> ImmutableInstruction21ih(Opcode.CONST_HIGH16, reg, (masked ushr 12).toInt())
            Opcode.CONST_WIDE_16 -> ImmutableInstruction21s(Opcode.CONST_WIDE_16, reg, masked.toInt())
            Opcode.CONST_WIDE_32 -> ImmutableInstruction31i(Opcode.CONST_WIDE_32, reg, masked.toInt())
            Opcode.CONST_WIDE -> ImmutableInstruction51l(Opcode.CONST_WIDE, reg, masked)
            Opcode.CONST_WIDE_HIGH16 -> ImmutableInstruction21ih(Opcode.CONST_WIDE_HIGH16, reg, (masked ushr 48).toInt())
            else -> ImmutableInstruction.of(ins)
        }
    }

    /** 方法规则可用短名（isVip）或类限定 DEX 标识（Lpkg/Class;->isVip）。 */
    internal fun matchesMethodTarget(
        methodName: String,
        classType: String,
        targets: Set<String>,
    ): Boolean = methodName in targets || "$classType->$methodName" in targets

    internal fun normalizeMethodTarget(raw: String): String {
        val value = raw.trim().lowercase()
        return if (value.contains("->") && value.contains("(")) value.substringBefore("(") else value
    }

    // ---------- B5：loadLibrary NOP ----------

    /**
     * 把方法体内对广告库的 System.loadLibrary / Runtime.load 调用替换为 NOP。
     * 通过 CONST_STRING 数据流跟踪定位库名字符串；SO 文件全部保留不删。
     */
    private data class NopPatch(
        val implementation: ImmutableMethodImplementation,
        val count: Int,
    )

    internal fun literalLoadLibraryMatches(
        dex: DexFile,
        libKeywords: Set<String>,
    ): Set<String> {
        if (libKeywords.isEmpty()) return emptySet()
        val matches = linkedSetOf<String>()
        for (method in dex.classes.asSequence().flatMap { it.methods.asSequence() }) {
            val implementation = method.implementation ?: continue
            val count = countLiteralAdLibLoads(implementation, libKeywords)
            if (count > 0) matches += method.name.lowercase()
        }
        return matches
    }

    private fun nopOutAdLibLoadLibrary(
        impl: MethodImplementation,
        libKeywords: Set<String>,
    ): NopPatch? {
        // 快速预检：只有同时出现 CONST_STRING 与 loadLibrary 调用才继续
        var hasConstString = false
        var hasLoadLibrary = false
        for (ins in impl.instructions) {
            val op = ins.opcode
            if (op == Opcode.CONST_STRING || op == Opcode.CONST_STRING_JUMBO) {
                hasConstString = true
            } else if (hasConstString && isLoadLibraryInvoke(ins)) {
                hasLoadLibrary = true
                break
            }
        }
        if (!hasLoadLibrary) return null

        var changed = false
        var matchedCount = 0
        val newInstructions = mutableListOf<ImmutableInstruction>()
        val recentStrings = HashMap<Int, String>()

        for (ins in impl.instructions) {
            when {
                ins.opcode == Opcode.CONST_STRING || ins.opcode == Opcode.CONST_STRING_JUMBO -> {
                    val reg = when (ins) {
                        is Instruction21c -> ins.registerA
                        is Instruction31c -> ins.registerA
                        else -> -1
                    }
                    val str = (ins as? ReferenceInstruction)?.reference as? StringReference
                    if (reg >= 0 && str != null) recentStrings[reg] = str.string
                    newInstructions.add(ImmutableInstruction.of(ins))
                }
                isLoadLibraryInvoke(ins) -> {
                    val reg = loadLibraryArgumentRegister(ins)
                    val libName = recentStrings[reg].orEmpty()
                    if (isAdLibName(libName, libKeywords)) {
                        newInstructions.addAll(nopPaddingFor(ins))
                        changed = true
                        matchedCount++
                    } else {
                        newInstructions.add(ImmutableInstruction.of(ins))
                    }
                }
                else -> newInstructions.add(ImmutableInstruction.of(ins))
            }
        }
        if (!changed) return null

        // 与置空路径不同：tryBlocks/debugItems 原样保留，避免异常处理链断裂
        return NopPatch(
            ImmutableMethodImplementation(
                impl.registerCount.coerceAtLeast(1),
                newInstructions,
                impl.tryBlocks.toList(),
                impl.debugItems.toList(),
            ),
            matchedCount,
        )
    }

    private fun countLiteralAdLibLoads(
        impl: MethodImplementation,
        libKeywords: Set<String>,
    ): Int {
        val recentStrings = HashMap<Int, String>()
        var count = 0
        for (ins in impl.instructions) {
            when {
                ins.opcode == Opcode.CONST_STRING || ins.opcode == Opcode.CONST_STRING_JUMBO -> {
                    val reg = when (ins) {
                        is Instruction21c -> ins.registerA
                        is Instruction31c -> ins.registerA
                        else -> -1
                    }
                    val str = (ins as? ReferenceInstruction)?.reference as? StringReference
                    if (reg >= 0 && str != null) recentStrings[reg] = str.string
                }
                isLoadLibraryInvoke(ins) &&
                    isAdLibName(
                        recentStrings[loadLibraryArgumentRegister(ins)].orEmpty(),
                        libKeywords,
                    ) -> count++
            }
        }
        return count
    }

    private fun isLoadLibraryInvoke(ins: Instruction): Boolean {
        if (ins !is Instruction35c && ins !is Instruction3rc) return false
        val opcode = ins.opcode
        if (opcode != Opcode.INVOKE_STATIC && opcode != Opcode.INVOKE_VIRTUAL &&
            opcode != Opcode.INVOKE_DIRECT && opcode != Opcode.INVOKE_SUPER &&
            opcode != Opcode.INVOKE_INTERFACE
        ) {
            return false
        }
        val ref = (ins as? ReferenceInstruction)?.reference as? MethodReference ?: return false
        val name = ref.name
        if (name != "loadLibrary" && name != "load") return false
        val clazz = ref.definingClass
        return clazz == "Ljava/lang/System;" || clazz == "Ljava/lang/Runtime;"
    }

    private fun loadLibraryArgumentRegister(ins: Instruction): Int {
        val first = when (ins) {
            is Instruction35c -> ins.registerC
            is Instruction3rc -> ins.startRegister
            else -> return -1
        }
        val ref = (ins as? ReferenceInstruction)?.reference as? MethodReference
            ?: return -1
        return if (ref.definingClass == "Ljava/lang/Runtime;" &&
            ins.opcode != Opcode.INVOKE_STATIC
        ) {
            first + 1
        } else {
            first
        }
    }

    // 保持指令数不变：invoke-xxx/range 占 5 字节，普通 invoke 占 3 字节
    private fun nopPaddingFor(ins: Instruction): List<ImmutableInstruction10x> {
        val count = if (ins is Instruction3rc) 5 else 3
        return List(count) { ImmutableInstruction10x(Opcode.NOP) }
    }

    private fun isAdLibName(libName: String, libKeywords: Set<String>): Boolean {
        if (libName.isEmpty() || libKeywords.isEmpty()) return false
        var name = libName.lowercase()
        name = name.substringAfterLast('/')
        if (name.startsWith("lib")) name = name.removePrefix("lib")
        if (name.endsWith(".so")) name = name.dropLast(3)
        if (name.isEmpty()) return false
        return libKeywords.any { name.contains(it) }
    }
}
