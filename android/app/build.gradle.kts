import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "zhou.solab"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "zhou.solab"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters.clear()
            abiFilters += "arm64-v8a"
        }
        externalNativeBuild {
            cmake {
                abiFilters += "arm64-v8a"
            }
        }
    }

    buildFeatures {
        // M5: Blutter isolated process 服务（IBlutterRunner AIDL）
        aidl = true
    }

    // 签名兼容注入原生库（原包模式）：xhook 移植，仅 arm64
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/signature/CMakeLists.txt")
        }
    }

    val keystorePropertiesFile = rootProject.file("key.properties")
    val keystoreProperties = Properties()
    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(keystorePropertiesFile.inputStream())
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                // v4 签名：adb --incremental 增量安装依赖（覆盖安装提速）
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
                enableV4Signing = true
            }
        }
    }

    buildTypes {
        // debug 与 release 统一使用 release 签名，debug 包可直接覆盖安装正式版
        getByName("debug") {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
        getByName("release") {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
            // 不显式配置时 R8 不加载 proguard-rules.pro，reandroid keep/dontwarn 全部失效
            // （玄星逆核同款配置）
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    packaging {
        // so 压缩存储（同"Flutter 解析工具"手法）：20 个 exec blutter runner
        // + ICU 共约 124MB 未压缩，legacy packaging 压缩后 APK 仅增约 40MB
        jniLibs {
            useLegacyPackaging = true
            keepDebugSymbols += "**/libblutter_*.so"
            keepDebugSymbols += "**/libicu*.so"
        }
        resources {
            // bouncycastle 多 jar + jspecify 的 OSGI 元数据路径重复
            excludes += "META-INF/versions/**/OSGI-INF/**"
            excludes += "META-INF/OSGI-INF/**"
            // Android 只使用 arm64 的 JNI 库；JVM 依赖附带的 Windows/macOS
            // 原生文件不会被 Android 加载，避免把桌面运行时一起塞进 APK。
            excludes += "natives/**"
        }
    }

    // 体积开关：heavyLibs=false 时剔除重型可选库（
    // 20 个 Blutter exec runner + ICU 约 124MB、Ghidra 伪代码插件 13MB）。
    // 用法：gradle.properties 改 heavyLibs=false 后重新构建（或 -PheavyLibs=false）。
    // lite 版：SO 引擎基础（Rizin/LIEF/xAnSo/Unidbg）保留，
    // Flutter 专项分析降级为不可用（工具返回明确错误）。
    val heavyLibs = (project.findProperty("heavyLibs") as String?)?.toBoolean() ?: true
    if (!heavyLibs) {
        packaging {
            jniLibs {
                excludes += "lib/arm64-v8a/libblutter_bridge.so"
                excludes += "lib/arm64-v8a/libblutter_2_*.so"
                excludes += "lib/arm64-v8a/libblutter_3_*.so"
                excludes += "lib/arm64-v8a/libicudata.so"
                excludes += "lib/arm64-v8a/libicuuc.so"
            }
            resources {
                excludes += "assets/rizin/**"
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11
    }
}

flutter {
    source = "../.."
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20180813")
    implementation("androidx.browser:browser:1.9.0")
    implementation("org.smali:dexlib2:2.5.2")
    // ===== M1: 玄星逆核工具链移植 =====
    // 反编译（A1）
    implementation("io.github.skylot:jadx-core:1.5.1")
    implementation("io.github.skylot:jadx-dex-input:1.5.1")
    // DEX 读取
    implementation("com.android.tools.smali:smali-dexlib2:3.0.9")
    // 签名/验签（A4/A5）
    implementation("com.android.tools.build:apksig:8.7.3")
    implementation(files("libs/apk-data-multiplexing.jar"))
    implementation("org.bouncycastle:bcpkix-jdk18on:1.78.1")
    // APK 回编/资源解析（A6/A7）
    implementation("com.github.REAndroid:APKEditor:V1.4.9")
    // 1.4.0+ 才有 com.reandroid.apk.DexProfileDecoder 与 dex.dexopt（APKEditor
    // decode 的 dexProfile 路径硬依赖）；1.3.5 会被 R8 按 dontwarn 裁掉导致
    // apk_rebuild decode 运行时 NoClassDefFoundError
    implementation("io.github.reandroid:ARSCLib:1.4.0")
    // 反混淆反查（A8）
    implementation("org.luckypray:dexkit:2.2.0")
    // ===== M3: SO 引擎 =====
    implementation("net.java.dev.jna:jna:5.10.0@aar")
    implementation("com.github.zhkl0228:unidbg-unicorn2:0.9.9") {
        exclude(group = "com.github.zhkl0228", module = "unidbg-api")
        exclude(group = "com.github.zhkl0228", module = "unidbg-android")
        exclude(group = "com.github.zhkl0228", module = "capstone")
        exclude(group = "com.github.zhkl0228", module = "keystone")
    }
    implementation("com.alibaba:fastjson:1.2.83")
    implementation("com.github.zhkl0228:demumble:1.0.4")
    implementation(files("libs/unidbg-api-0.9.9-android-patched.jar"))
    implementation(files("libs/unidbg-android-0.9.9-android-patched.jar"))
    implementation(files("libs/capstone-3.1.8-android-patched.jar"))
    implementation(files("libs/keystone-0.9.7-android-patched.jar"))
    // Required for core library desugaring (used by flutter_local_notifications)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}
