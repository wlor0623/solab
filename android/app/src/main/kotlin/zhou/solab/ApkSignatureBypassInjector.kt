package zhou.solab

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Base64
import com.reandroid.arsc.chunk.xml.AndroidManifestBlock
import org.jf.dexlib2.AccessFlags
import org.jf.dexlib2.DexFileFactory
import org.jf.dexlib2.Opcodes
import org.jf.dexlib2.iface.ClassDef
import org.jf.dexlib2.iface.Method
import org.jf.dexlib2.iface.instruction.formats.Instruction35c
import org.jf.dexlib2.iface.reference.MethodReference
import org.jf.dexlib2.immutable.ImmutableClassDef
import org.jf.dexlib2.immutable.ImmutableDexFile
import org.jf.dexlib2.immutable.ImmutableField
import org.jf.dexlib2.immutable.ImmutableMethod
import org.jf.dexlib2.immutable.ImmutableMethodImplementation
import org.jf.dexlib2.immutable.instruction.ImmutableInstruction
import org.jf.dexlib2.immutable.instruction.ImmutableInstruction35c
import org.jf.dexlib2.immutable.reference.ImmutableMethodReference
import org.jf.dexlib2.immutable.value.ImmutableStringEncodedValue
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.zip.ZipFile

internal object ApkSignatureBypassInjector {
    const val MODE_NORMAL = "normal"
    const val MODE_ORIGINAL_APK = "original_apk"
    const val MODE_DPATCH = "dpatch"

    private const val CONFIG_ENTRY = "assets/solab/signature-bypass.json"
    private const val DPATCH_CONFIG_ENTRY = "assets/dpatch/metadata.json"
    const val ORIGINAL_APK_ENTRY = "assets/solab/original.apk"
    private const val NATIVE_LIB_ENTRY = "lib/arm64-v8a/libsolab_signature.so"
    private const val DPATCH_ORIGINAL_APK_ENTRY = "assets/base.apk"
    private const val DPATCH_NATIVE_ASSET_ENTRY = "assets/libpandora.so"
    private const val DPATCH_DEX_ASSET = "dpatch/pandora_loader.dex"
    private const val DPATCH_STRATEGY = "dpatch_component_factory_native_redirect"
    private const val PROXY_CLASS = "zhou.solab.signature.SignatureProxyApplication"
    private const val PROXY_TYPE = "Lzhou/solab/signature/SignatureProxyApplication;"
    private const val DPATCH_FACTORY_CLASS = "com.pandora.core.AppFactory"
    private const val APPLICATION_TYPE = "Landroid/app/Application;"
    private val COMMON_TEMPLATE_TYPES = setOf(
        "Lzhou/solab/signature/SignatureBypass;",
        "Lzhou/solab/signature/PackageInfoCreator;",
    )
    private val verifiedArtifacts = object : LinkedHashMap<String, Map<String, Any>>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Map<String, Any>>?): Boolean =
            size > 8
    }

    data class Plan(
        val mode: String,
        val changed: Boolean,
        val alreadyInjected: Boolean,
        val originalApplication: String,
        val originalComponentFactory: String?,
        val originalSignatureSha256: String,
        val sourceSha256: String,
        val dexEntry: String?,
        val byteOverrides: Map<String, ByteArray>,
        val overrides: Map<String, File>,
        val additions: Map<String, ByteArray>,
        val additionFiles: Map<String, File>,
    ) {
        fun toMap(): Map<String, Any> = buildMap {
            put("mode", mode)
            put("changed", changed)
            put("alreadyInjected", alreadyInjected)
            put("originalApplication", originalApplication)
            if (originalComponentFactory != null) {
                put("originalComponentFactory", originalComponentFactory)
            }
            put("originalSignatureSha256", originalSignatureSha256)
            put("sourceSha256", sourceSha256)
            if (dexEntry != null) put("dexEntry", dexEntry)
            put("usesEmbeddedOriginalApk", usesEmbeddedOriginalApk(mode))
            put(
                "strategy",
                when (mode) {
                    MODE_DPATCH -> DPATCH_STRATEGY
                    MODE_ORIGINAL_APK -> "embedded_original_apk_data_multiplexing"
                    else -> "package_info_proxy"
                },
            )
        }
    }

    fun prepare(
        context: Context,
        source: File,
        requestedMode: String,
        originalApk: File?,
        temporaryDirectory: File,
    ): Plan {
        val mode = normalizeMode(requestedMode)
        ZipFile(source).use { zip ->
            val existing = (zip.getEntry(CONFIG_ENTRY) ?: zip.getEntry(DPATCH_CONFIG_ENTRY))?.let { entry ->
                zip.getInputStream(entry).use { JSONObject(it.reader().readText()) }
            }
            if (existing != null) {
                return prepareExisting(zip, existing, mode)
            }
            val forbiddenClass = if (mode == MODE_DPATCH) {
                "com/pandora/core/AppFactory"
            } else {
                "zhou/solab/signature"
            }
            require(zip.entries().asSequence().none { entry ->
                entry.name.matches(Regex("classes(\\d*)\\.dex", RegexOption.IGNORE_CASE)) &&
                    ApkAhoCorasick(listOf(forbiddenClass))
                        .scanStream(zip.getInputStream(entry)).isNotEmpty()
            }) {
                "SIGNATURE_BYPASS_CLASS_CONFLICT: target APK already contains $forbiddenClass classes"
            }
        }

        val signatureSource = originalApk ?: source
        require(signatureSource.isFile) { "ORIGINAL_APK_REQUIRED: originalApkPath does not exist" }
        val archive = archiveIdentity(context, signatureSource)
        val manifestPlan = rewriteManifest(source, mode, temporaryDirectory)
        val originalApplication = manifestPlan.originalApplication
        val dexEntry = nextDexEntry(source)
        val dexFile = File(temporaryDirectory, dexEntry)
        val superclassOverrides = if (mode == MODE_DPATCH) {
            writeDpatchDex(
                context,
                Base64.encodeToString(archive.signature, Base64.NO_WRAP),
                dexFile,
            )
            emptyMap()
        } else {
            val applicationOverrides = prepareSubclassableSuperclass(
                source,
                originalApplication,
                "APPLICATION",
                temporaryDirectory,
            )
            writeInjectorDex(context, PROXY_TYPE, originalApplication, APPLICATION_TYPE, dexFile, temporaryDirectory)
            applicationOverrides
        }
        val sourceSha = sha256(signatureSource)
        val nativeLib = if (mode == MODE_DPATCH) {
            extractAssetToTemp(context, "dpatch/libpandora.so", temporaryDirectory)
        } else if (mode == MODE_ORIGINAL_APK) {
            extractHostNativeLib(context, source, temporaryDirectory)
        } else {
            null
        }
        if (mode == MODE_DPATCH) {
            requireNotNull(nativeLib) {
                "SIGNATURE_BYPASS_DPATCH_ABI_UNSUPPORTED: DPatch currently requires an arm64-v8a target"
            }
        }
        val marker = marker(
            mode = mode,
            packageName = archive.packageName,
            signature = archive.signature,
            originalApplication = originalApplication,
            originalComponentFactory = manifestPlan.originalComponentFactory,
            sourceSha256 = sourceSha,
            dexEntry = dexEntry,
        )
        return Plan(
            mode = mode,
            changed = true,
            alreadyInjected = false,
            originalApplication = originalApplication,
            originalComponentFactory = manifestPlan.originalComponentFactory,
            originalSignatureSha256 = sha256(archive.signature),
            sourceSha256 = sourceSha,
            dexEntry = dexEntry,
            byteOverrides = emptyMap(),
            overrides = mapOf("AndroidManifest.xml" to manifestPlan.file) + superclassOverrides,
            additions = mapOf(markerEntry(mode) to marker.toString().toByteArray()),
            additionFiles = buildMap {
                put(dexEntry, dexFile)
                if (mode == MODE_DPATCH) {
                    put(DPATCH_ORIGINAL_APK_ENTRY, signatureSource)
                    nativeLib?.let { put(DPATCH_NATIVE_ASSET_ENTRY, it) }
                } else if (mode == MODE_ORIGINAL_APK) {
                    put(ORIGINAL_APK_ENTRY, signatureSource)
                    nativeLib?.let { put(NATIVE_LIB_ENTRY, it) }
                }
            },
        )
    }

    private fun prepareExisting(
        zip: ZipFile,
        marker: JSONObject,
        requestedMode: String,
    ): Plan {
        val currentMode = normalizeMode(marker.optString("mode", MODE_NORMAL))
        require(currentMode == requestedMode) {
            "SIGNATURE_BYPASS_MODE_SWITCH_REQUIRES_ORIGINAL: run the requested mode against the unchanged original APK"
        }
        if (currentMode == MODE_DPATCH) {
            require(marker.optInt("version", 1) >= 3 &&
                marker.optString("strategy") == DPATCH_STRATEGY
            ) {
                "SIGNATURE_BYPASS_LEGACY_DPATCH_REQUIRES_ORIGINAL: rebuild DPatch from the unchanged original APK"
            }
        }
        val originalApplication = marker.getString("originalApplication")
        val originalComponentFactory = marker.optString("originalComponentFactory")
            .takeIf(String::isNotBlank)
        val signatureBytes = Base64.decode(marker.getString("signatureBase64"), Base64.DEFAULT)
        val sourceSha = marker.getString("sourceSha256")
        val dexEntry = marker.optString("dexEntry").takeIf(String::isNotBlank)
        require(dexEntry != null && zip.getEntry(dexEntry) != null) {
            "SIGNATURE_BYPASS_INCOMPLETE: injected DEX is missing"
        }
        if (currentMode == MODE_DPATCH) {
            require(zip.getEntry(DPATCH_ORIGINAL_APK_ENTRY) != null &&
                zip.getEntry(DPATCH_NATIVE_ASSET_ENTRY) != null
            ) {
                "SIGNATURE_BYPASS_INCOMPLETE: DPatch payload is missing"
            }
        } else if (usesEmbeddedOriginalApk(currentMode)) {
            require(zip.getEntry(ORIGINAL_APK_ENTRY) != null) {
                "SIGNATURE_BYPASS_INCOMPLETE: embedded original APK is missing"
            }
        }
        return Plan(
            mode = currentMode,
            changed = false,
            alreadyInjected = true,
            originalApplication = originalApplication,
            originalComponentFactory = originalComponentFactory,
            originalSignatureSha256 = sha256(signatureBytes),
            sourceSha256 = sourceSha,
            dexEntry = dexEntry,
            byteOverrides = emptyMap(),
            overrides = emptyMap(),
            additions = emptyMap(),
            additionFiles = emptyMap(),
        )
    }

    fun optimizeEmbeddedOriginalApk(apk: File) {
        val optimized = File(apk.parentFile, apk.name + ".multiplex.tmp")
        optimized.delete()
        try {
            bin.zip.DataMultiplexing.optimize(apk, optimized, ORIGINAL_APK_ENTRY, false)
            Files.move(
                optimized.toPath(),
                apk.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE,
            )
        } catch (error: Throwable) {
            optimized.delete()
            throw error
        }
    }

    fun verifyPrepared(apk: File, plan: Plan): Map<String, Any> {
        val cacheKey = "${apk.canonicalPath}|${apk.length()}|${apk.lastModified()}|${plan.mode}"
        synchronized(verifiedArtifacts) {
            verifiedArtifacts[cacheKey]?.let { return it }
        }
        val result = ZipFile(apk).use { zip ->
            val marker = zip.getEntry(markerEntry(plan.mode))?.let { entry ->
                zip.getInputStream(entry).use { JSONObject(it.reader().readText()) }
            } ?: error("SIGNATURE_BYPASS_VERIFY_FAILED: marker is missing")
            require(marker.optString("mode") == plan.mode) {
                "SIGNATURE_BYPASS_VERIFY_FAILED: mode mismatch"
            }
            val dexEntry = requireNotNull(plan.dexEntry) {
                "SIGNATURE_BYPASS_VERIFY_FAILED: injector dex is unknown"
            }
            val dex = zip.getEntry(dexEntry)
                ?: error("SIGNATURE_BYPASS_VERIFY_FAILED: injector dex is missing")
            val expectedRuntime = if (plan.mode == MODE_DPATCH) {
                "com/pandora/core/AppFactory"
            } else {
                "zhou/solab/signature"
            }
            require(
                ApkAhoCorasick(listOf(expectedRuntime))
                    .scanStream(zip.getInputStream(dex)).isNotEmpty(),
            ) { "SIGNATURE_BYPASS_VERIFY_FAILED: injector classes are missing" }
            require(zip.entries().asSequence().none { isSignatureEntry(it.name) }) {
                "SIGNATURE_BYPASS_VERIFY_FAILED: old signature entries remain"
            }
            val manifestEntry = zip.getEntry("AndroidManifest.xml")
                ?: error("SIGNATURE_BYPASS_VERIFY_FAILED: manifest is missing")
            val manifest = zip.getInputStream(manifestEntry).use(AndroidManifestBlock::load)
            val application = manifest.applicationClassName
                ?.takeIf(String::isNotBlank)
                ?.let(manifest::fullClassName)
                ?: "android.app.Application"
            val componentFactory = componentFactory(manifest)
            if (plan.mode == MODE_DPATCH) {
                require(componentFactory == DPATCH_FACTORY_CLASS) {
                    "SIGNATURE_BYPASS_VERIFY_FAILED: DPatch component factory is not active"
                }
            } else {
                require(application == PROXY_CLASS) {
                    "SIGNATURE_BYPASS_VERIFY_FAILED: proxy Application is not active"
                }
            }
            if (plan.mode == MODE_DPATCH) {
                require(zip.getEntry(DPATCH_ORIGINAL_APK_ENTRY) != null &&
                    zip.getEntry(DPATCH_NATIVE_ASSET_ENTRY) != null
                ) {
                    "SIGNATURE_BYPASS_VERIFY_FAILED: DPatch payload is missing"
                }
            } else if (usesEmbeddedOriginalApk(plan.mode)) {
                require(zip.getEntry(ORIGINAL_APK_ENTRY) != null) {
                    "SIGNATURE_BYPASS_VERIFY_FAILED: original APK is missing"
                }
                // 目标含 arm64 ABI 时必须注入 native hook 库；缺失会在真机上
                // 表现为 installNativeHook 加载失败 → 整包校验仍被原始签名校验拦截
                if (zip.entries().asSequence().any { it.name.startsWith("lib/arm64-v8a/") }) {
                    require(zip.getEntry(NATIVE_LIB_ENTRY) != null) {
                        "SIGNATURE_BYPASS_VERIFY_FAILED: libsolab_signature.so is missing for arm64 target"
                    }
                }
            }
            mapOf(
                "verified" to true,
                "mode" to plan.mode,
                "manifestApplication" to application,
                "manifestComponentFactory" to componentFactory,
                "injectorDex" to dexEntry,
                "oldSignatureEntriesRemoved" to true,
            )
        }
        synchronized(verifiedArtifacts) {
            verifiedArtifacts[cacheKey] = result
        }
        return result
    }

    private fun isSignatureEntry(name: String): Boolean =
        name.startsWith("META-INF/") && (
            name.endsWith(".SF", ignoreCase = true) ||
                name.endsWith(".RSA", ignoreCase = true) ||
                name.endsWith(".DSA", ignoreCase = true) ||
                name.endsWith(".EC", ignoreCase = true)
            )

    private data class ArchiveIdentity(val packageName: String, val signature: ByteArray)

    private fun archiveIdentity(context: Context, apk: File): ArchiveIdentity {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
        val info = context.packageManager.getPackageArchiveInfo(apk.absolutePath, flags)
            ?: error("ORIGINAL_SIGNATURE_REQUIRED: cannot read package information from original APK")
        val signature = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners?.firstOrNull()?.toByteArray()
        } else {
            @Suppress("DEPRECATION")
            info.signatures?.firstOrNull()?.toByteArray()
        } ?: error("ORIGINAL_SIGNATURE_REQUIRED: original APK has no readable signing certificate")
        return ArchiveIdentity(info.packageName, signature)
    }

    private data class ManifestPlan(
        val file: File,
        val originalApplication: String,
        val originalComponentFactory: String?,
    )

    private fun rewriteManifest(
        source: File,
        mode: String,
        temporaryDirectory: File,
    ): ManifestPlan {
        val output = File(temporaryDirectory, "AndroidManifest.xml")
        ZipFile(source).use { zip ->
            val entry = zip.getEntry("AndroidManifest.xml") ?: error("MANIFEST_NOT_FOUND")
            val manifest = zip.getInputStream(entry).use(AndroidManifestBlock::load)
            val rawApplication = manifest.applicationClassName
            val originalApplication = rawApplication?.takeIf(String::isNotBlank)
                ?.let(manifest::fullClassName)
                ?: "android.app.Application"
            val originalComponentFactory = componentFactory(manifest)
                .ifBlank { "android.app.AppComponentFactory" }
            if (mode == MODE_DPATCH) {
                require(originalComponentFactory != DPATCH_FACTORY_CLASS) {
                    "SIGNATURE_BYPASS_MARKER_MISSING: DPatch component factory already active"
                }
                manifest.applicationElement
                    .getOrCreateAndroidAttribute(
                        "appComponentFactory",
                        android.R.attr.appComponentFactory,
                    )
                    .setValueAsString(DPATCH_FACTORY_CLASS)
            } else {
                require(originalApplication != PROXY_CLASS) {
                    "SIGNATURE_BYPASS_MARKER_MISSING: proxy Application already active"
                }
                manifest.applicationClassName = PROXY_CLASS
            }
            manifest.refreshFull()
            manifest.writeBytes(output)
            return ManifestPlan(
                file = output,
                originalApplication = originalApplication,
                originalComponentFactory = originalComponentFactory.takeIf { mode == MODE_DPATCH },
            )
        }
    }

    private fun componentFactory(manifest: AndroidManifestBlock): String {
        val raw = manifest.applicationElement
            .searchAttributeByResourceId(android.R.attr.appComponentFactory)
            ?.valueAsString
            ?.takeIf(String::isNotBlank)
            ?: return ""
        return manifest.fullClassName(raw)
    }

    private fun nextDexEntry(source: File): String {
        val max = ZipFile(source).use { zip ->
            zip.entries().asSequence().mapNotNull { entry ->
                Regex("classes(\\d*)\\.dex", RegexOption.IGNORE_CASE).matchEntire(entry.name)
                    ?.groupValues?.get(1)?.ifBlank { "1" }?.toIntOrNull()
            }.maxOrNull() ?: 0
        }
        return "classes${max + 1}.dex"
    }

    private fun prepareSubclassableSuperclass(
        source: File,
        className: String,
        kind: String,
        temporaryDirectory: File,
    ): Map<String, File> {
        if (className == "android.app.Application" ||
            className == "android.app.AppComponentFactory"
        ) {
            return emptyMap()
        }
        val type = descriptor(className)
        ZipFile(source).use { zip ->
            zip.entries().asSequence()
                .filter { it.name.matches(Regex("classes(\\d*)\\.dex", RegexOption.IGNORE_CASE)) }
                .forEach { entry ->
                    if (ApkAhoCorasick(listOf(type)).scanStream(zip.getInputStream(entry)).isEmpty()) {
                        return@forEach
                    }
                    val dexFile = File(
                        temporaryDirectory,
                        "${kind.lowercase()}-${File(entry.name).name}",
                    )
                    zip.getInputStream(entry).use { input -> dexFile.outputStream().use(input::copyTo) }
                    val dex = DexFileFactory.loadDexFile(dexFile, Opcodes.getDefault())
                    val target = dex.classes.firstOrNull { it.type == type } ?: return@forEach
                    require(target.accessFlags and AccessFlags.ABSTRACT.value == 0) {
                        "SIGNATURE_BYPASS_${kind}_UNSUPPORTED: original class is abstract"
                    }
                    require(target.methods.any { method ->
                        method.name == "<init>" && method.parameterTypes.isEmpty()
                    }) {
                        "SIGNATURE_BYPASS_${kind}_UNSUPPORTED: original class has no empty constructor"
                    }
                    val classFlags = (target.accessFlags and AccessFlags.FINAL.value.inv()) or
                        AccessFlags.PUBLIC.value
                    val methods = target.methods.map { method ->
                        if (method.name == "<init>" && method.parameterTypes.isEmpty() &&
                            method.accessFlags and AccessFlags.PRIVATE.value != 0
                        ) {
                            ImmutableMethod(
                                method.definingClass,
                                method.name,
                                method.parameters,
                                method.returnType,
                                (method.accessFlags and AccessFlags.PRIVATE.value.inv()) or
                                    AccessFlags.PROTECTED.value,
                                method.annotations,
                                method.hiddenApiRestrictions,
                                method.implementation,
                            )
                        } else {
                            ImmutableMethod.of(method)
                        }
                    }
                    if (classFlags == target.accessFlags && methods.zip(target.methods).all { (left, right) ->
                            left.accessFlags == right.accessFlags
                        }
                    ) {
                        return emptyMap()
                    }
                    val classes = dex.classes.map { classDef ->
                        if (classDef.type == type) {
                            ImmutableClassDef(
                                classDef.type,
                                classFlags,
                                classDef.superclass,
                                classDef.interfaces,
                                classDef.sourceFile,
                                classDef.annotations,
                                classDef.fields,
                                methods,
                            )
                        } else {
                            ImmutableClassDef.of(classDef)
                        }
                    }
                    DexFileFactory.writeDexFile(
                        dexFile.absolutePath,
                        ImmutableDexFile(Opcodes.getDefault(), classes),
                    )
                    return mapOf(entry.name to dexFile)
                }
        }
        error("SIGNATURE_BYPASS_${kind}_NOT_FOUND: $className")
    }

    private fun extractAssetToTemp(
        context: Context,
        assetPath: String,
        temporaryDirectory: File,
    ): File {
        val output = File(temporaryDirectory, assetPath.substringAfterLast('/'))
        context.assets.open(assetPath).use { input ->
            output.outputStream().use { input.copyTo(it) }
        }
        return output
    }

    private fun writeDpatchDex(context: Context, signatureBase64: String, output: File) {
        context.assets.open(DPATCH_DEX_ASSET).use { input ->
            output.outputStream().use(input::copyTo)
        }
        val dex = DexFileFactory.loadDexFile(output, Opcodes.getDefault())
        var signatureFieldFound = false
        val classes = dex.classes.map { classDef ->
            if (classDef.type != "Lcom/pandora/core/AppFactory\$DATA;") {
                ImmutableClassDef.of(classDef)
            } else {
                val fields = classDef.fields.map { field ->
                    if (field.name == "signatureData" && field.type == "Ljava/lang/String;") {
                        signatureFieldFound = true
                        ImmutableField(
                            field.definingClass,
                            field.name,
                            field.type,
                            field.accessFlags,
                            ImmutableStringEncodedValue(signatureBase64),
                            field.annotations,
                            field.hiddenApiRestrictions,
                        )
                    } else {
                        ImmutableField.of(field)
                    }
                }
                ImmutableClassDef(
                    classDef.type,
                    classDef.accessFlags,
                    classDef.superclass,
                    classDef.interfaces,
                    classDef.sourceFile,
                    classDef.annotations,
                    fields,
                    classDef.methods,
                )
            }
        }
        require(signatureFieldFound) {
            "SIGNATURE_BYPASS_DPATCH_PAYLOAD_INVALID: signatureData field is missing"
        }
        DexFileFactory.writeDexFile(output.absolutePath, ImmutableDexFile(Opcodes.getDefault(), classes))
    }

    private fun extractHostNativeLib(
        context: Context,
        source: File,
        temporaryDirectory: File,
    ): File? {
        val supportsArm64 = ZipFile(source).use { zip ->
            val nativeEntries = zip.entries().asSequence()
                .filter { it.name.startsWith("lib/") && it.name.endsWith(".so") }
                .map { it.name }
                .toList()
            nativeEntries.isEmpty() || nativeEntries.any { it.startsWith("lib/arm64-v8a/") }
        }
        if (!supportsArm64) return null
        val output = File(temporaryDirectory, "libsolab_signature.so")
        return runCatching {
            ZipFile(context.applicationInfo.sourceDir).use { zip ->
                val entry = zip.getEntry(NATIVE_LIB_ENTRY) ?: return@runCatching null
                zip.getInputStream(entry).use { input ->
                    output.outputStream().use(input::copyTo)
                }
            }
            output
        }.getOrNull()
    }

    private fun writeInjectorDex(
        context: Context,
        proxyType: String,
        originalSuperclass: String,
        baseType: String,
        output: File,
        temporaryDirectory: File,
    ) {
        val templateTypes = COMMON_TEMPLATE_TYPES + proxyType
        val templates = linkedMapOf<String, ClassDef>()
        ZipFile(context.applicationInfo.sourceDir).use { zip ->
            zip.entries().asSequence()
                .filter { it.name.matches(Regex("classes(\\d*)\\.dex")) }
                .forEach { entry ->
                    val dex = File(temporaryDirectory, "host-${File(entry.name).name}")
                    zip.getInputStream(entry).use { input -> dex.outputStream().use(input::copyTo) }
                    DexFileFactory.loadDexFile(dex, Opcodes.getDefault()).classes.forEach { classDef ->
                        if (classDef.type in templateTypes) templates[classDef.type] = classDef
                    }
                }
        }
        require(templates.keys.containsAll(templateTypes)) {
            "SIGNATURE_BYPASS_TEMPLATE_MISSING: ${templateTypes - templates.keys}"
        }
        val superclass = descriptor(originalSuperclass)
        val classes = templateTypes.map { type ->
            val classDef = requireNotNull(templates[type])
            if (type == proxyType) {
                retargetProxy(classDef, superclass, baseType)
            } else {
                ImmutableClassDef.of(classDef)
            }
        }
        DexFileFactory.writeDexFile(output.absolutePath, ImmutableDexFile(Opcodes.getDefault(), classes))
    }

    private fun retargetProxy(
        classDef: ClassDef,
        superclass: String,
        baseType: String,
    ): ImmutableClassDef {
        val methods = classDef.methods.map { method ->
            retargetProxyMethod(method, superclass, baseType)
        }
        return ImmutableClassDef(
            classDef.type,
            classDef.accessFlags,
            superclass,
            classDef.interfaces,
            classDef.sourceFile,
            classDef.annotations,
            classDef.fields,
            methods,
        )
    }

    private fun retargetProxyMethod(
        method: Method,
        superclass: String,
        baseType: String,
    ): ImmutableMethod {
        val implementation = method.implementation ?: return ImmutableMethod.of(method)
        val instructions = implementation.instructions.map { instruction ->
            retargetInstruction(instruction, superclass, baseType)
        }
        return ImmutableMethod(
            method.definingClass,
            method.name,
            method.parameters,
            method.returnType,
            method.accessFlags,
            method.annotations,
            method.hiddenApiRestrictions,
            ImmutableMethodImplementation(
                implementation.registerCount,
                instructions,
                implementation.tryBlocks,
                implementation.debugItems,
            ),
        )
    }

    private fun retargetInstruction(
        instruction: org.jf.dexlib2.iface.instruction.Instruction,
        superclass: String,
        baseType: String,
    ): ImmutableInstruction {
        if (instruction !is Instruction35c) return ImmutableInstruction.of(instruction)
        val reference = instruction.reference as? MethodReference
            ?: return ImmutableInstruction.of(instruction)
        if (reference.definingClass != baseType) return ImmutableInstruction.of(instruction)
        val replaced = ImmutableMethodReference(
            superclass,
            reference.name,
            reference.parameterTypes,
            reference.returnType,
        )
        return ImmutableInstruction35c(
            instruction.opcode,
            instruction.registerCount,
            instruction.registerC,
            instruction.registerD,
            instruction.registerE,
            instruction.registerF,
            instruction.registerG,
            replaced,
        )
    }

    private fun marker(
        mode: String,
        packageName: String,
        signature: ByteArray,
        originalApplication: String,
        originalComponentFactory: String?,
        sourceSha256: String,
        dexEntry: String,
    ): JSONObject = JSONObject()
        .put("version", 3)
        .put("mode", mode)
        .put("packageName", packageName)
        .put("signatureBase64", Base64.encodeToString(signature, Base64.NO_WRAP))
        .put("signatureSha256", sha256(signature))
        .put("originalApplication", originalApplication)
        .apply {
            if (originalComponentFactory != null) {
                put("originalComponentFactory", originalComponentFactory)
            }
        }
        .put("sourceSha256", sourceSha256)
        .put("dexEntry", dexEntry)
        .put(
            "strategy",
            if (mode == MODE_DPATCH) {
                DPATCH_STRATEGY
            } else if (mode == MODE_ORIGINAL_APK) {
                "embedded_original_apk_data_multiplexing"
            } else {
                "package_info_proxy"
            },
        )

    private fun normalizeMode(value: String): String = when (value.trim().lowercase()) {
        "", MODE_NORMAL, "ordinary", "proxy" -> MODE_NORMAL
        MODE_ORIGINAL_APK, "original", "original-apk" -> MODE_ORIGINAL_APK
        MODE_DPATCH, "dexpatch" -> MODE_DPATCH
        else -> error("SIGNATURE_BYPASS_MODE_INVALID: use normal, original_apk or dpatch")
    }

    private fun usesEmbeddedOriginalApk(mode: String): Boolean =
        mode == MODE_ORIGINAL_APK

    private fun markerEntry(mode: String): String =
        if (mode == MODE_DPATCH) DPATCH_CONFIG_ENTRY else CONFIG_ENTRY

    private fun descriptor(className: String): String =
        "L${className.removePrefix("L").removeSuffix(";").replace('.', '/')};"

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(128 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().toHex()
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).toHex()

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
