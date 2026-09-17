-dontwarn com.gemalto.jp2.**
-dontwarn com.tom_roush.pdfbox.filter.JPXFilter

# ===== M1: 玄星逆核工具链 =====
# jadx: Android 无 AWT，Res9patchStreamDecoder 运行时不走（玄星逆核同款规则）
-dontwarn java.awt.**
-dontwarn javax.imageio.**
# APKEditor 可选后端：jcommand 参数解析 / DexProfile / JesusFreke smali 备选。
# 真机验证（2026-08-16 全工具实测）：decode 硬依赖 DexProfileDecoder，无内置
# 降级；-dontwarn 只压警告不阻止 tree-shake，release 下类被裁导致
# NoClassDefFoundError。必须整库 keep（CLI 反射风格，无法静态溯源）。
-keep class com.reandroid.** { *; }
-dontwarn com.reandroid.jcommand.**
# ARSCLib 1.3.x dex 模块对 apkeditor 的可选引用（InfoWriterText/DexProfile/protect 路径，运行时可选）
-dontwarn com.reandroid.dex.**
# APKEditor V1.4.9 引用的 ARSCLib 1.3.6+ 可选类（1.3.5 无此类，运行时可选路径，
# 规则来源 = R8 自动生成的 missing_rules.txt）
-dontwarn com.reandroid.apk.DexProfileDecoder
-dontwarn com.reandroid.apk.DexProfileEncoder
-dontwarn com.reandroid.arsc.chunk.xml.ResXmlAttributeArray
-dontwarn com.reandroid.arsc.chunk.xml.ResXmlElementApi
-dontwarn com.reandroid.arsc.chunk.xml.UnknownResXmlNode
-dontwarn org.jf.baksmali.**
-dontwarn org.jf.smali.**
# apksig 签名链（unidbg CertificateMeta 曾被误裁，同类防护）
-keep class com.android.apksig.** { *; }
-keep class org.bouncycastle.** { *; }
# keep BC 全库后其 JNDI/dane 可选路径引用缺失类（Android 无 javax.naming）
-dontwarn javax.naming.**
# DexKit：JNI native 绑定，防混淆
-keep class org.luckypray.dexkit.** { *; }

# ===== M5: Blutter（JNI dlopen + AIDL，防混淆破坏绑定）=====
-keep class zhou.solab.blutter.** { *; }
-keep class zhou.solab.engine.Blutter** { *; }
-keep class com.soreverse.mcp.engine.XAnSoEngine { *; }
-keep class zhou.solab.signature.** { *; }

# ===== M3: SO 引擎 =====
# unidbg/JNA 全反射驱动，防混淆
-keep class com.github.unidbg.** { *; }
-keep class unicorn.** { *; }
-keep class com.sun.jna.** { *; }
-keep class com.sun.jna.ptr.** { *; }
-keep class net.fornwall.jelf.** { *; }
-keep class capstone.** { *; }
-keep class com.github.zhkl0228.demumble.** { *; }
-dontwarn com.github.unidbg.**
-dontwarn unicorn.**
-dontwarn com.sun.jna.**
-dontwarn net.fornwall.jelf.**
-dontwarn capstone.**
-dontwarn com.github.zhkl0228.demumble.**
-dontwarn com.google.common.collect.ArrayListMultimap
-dontwarn com.google.common.collect.Multimap
# fastjson 可选集成（jaxrs/joda/money/springfox 缺失时 R8 误报）
-dontwarn javax.annotation.**
-dontwarn javax.money.**
-dontwarn javax.ws.rs.**
-dontwarn org.glassfish.**
-dontwarn org.javamoney.**
-dontwarn org.joda.time.**
-dontwarn springfox.**
