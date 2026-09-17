package zhou.solab.tools

import android.content.Context
import org.json.JSONObject
import java.util.Locale

internal data class ApkAdRules(
    val sdkPackages: List<String>,
    val classPatterns: List<String>,
    val methodPatterns: List<String>,
    val urlPatterns: List<String>,
    val forceTrueMethods: List<String>,
    val forceFalseMethods: List<String> = emptyList(),
    val flutterStringPatterns: List<String> = emptyList(),
    val timeMethods: List<String> = emptyList(),
    val detectionVpn: List<String> = emptyList(),
    val detectionEmulator: List<String> = emptyList(),
    val detectionRoot: List<String> = emptyList(),
    val detectionDebug: List<String> = emptyList(),
    val adAssetFiles: List<String> = emptyList(),
    val adPermissions: List<String> = emptyList(),
    val libFileKeywords: List<String> = emptyList(),
) {
    val sdkPackageSet = sdkPackages.toSet()
    val classPatternSet = classPatterns.toSet()
    val methodPatternSet = methodPatterns.toSet()
    val entryMethodSet = methodPatterns.filter {
        it.startsWith("init") || it.startsWith("register") || it.startsWith("manager")
    }.toSet()
    val urlPatternSet = urlPatterns.toSet()
    val forceTrueMethodSet = forceTrueMethods.toSet()
    val forceFalseMethodSet = forceFalseMethods.toSet()
    val flutterStringPatternSet = flutterStringPatterns.toSet()
    val timeMethodSet = timeMethods.toSet()
    val adAssetFileSet = adAssetFiles.toSet()
    val adPermissionSet = adPermissions.toSet()
    val componentPatterns = (sdkPackages + classPatterns).distinct()
    val searchPatterns = (sdkPackages + classPatterns + methodPatterns + urlPatterns + forceTrueMethods + timeMethods).distinct()
}

internal object ApkRulesStore {
    val shellSignatures = linkedMapOf(
        "libjiagu.so" to "360", "libprotectclass.so" to "360", "libdexhelper.so" to "腾讯乐固",
        "libshella.so" to "shella", "libshell.so" to "shell", "libexec.so" to "梆梆",
        "libsecshell.so" to "梆梆", "libnesec.so" to "爱加密", "libnqshield.so" to "娜迦",
        "libapkprotect.so" to "APKProtect", "libtup.so" to "腾讯御安全", "libkwscmm.so" to "阿里聚安全",
        "libkwscr.so" to "阿里聚安全", "libegis.so" to "egis", "libbaiduprotect.so" to "百度",
        "libddog.so" to "ddog", "libx3g.so" to "网易易盾", "libcainiao.so" to "cainiao",
        "libsecmain.so" to "secmain", "libchaosvmp.so" to "chaosvmp",
    )
    val safetyOrder = mapOf("high_risk" to 0, "review" to 1, "safe" to 2)
    val highRiskPermissions = setOf(
        "android.permission.ACCESS_FINE_LOCATION", "android.permission.ACCESS_COARSE_LOCATION",
        "android.permission.RECORD_AUDIO", "android.permission.CAMERA", "android.permission.READ_CONTACTS",
        "android.permission.WRITE_CONTACTS", "android.permission.READ_SMS", "android.permission.SEND_SMS",
        "android.permission.READ_CALL_LOG", "android.permission.WRITE_CALL_LOG",
        "android.permission.MANAGE_EXTERNAL_STORAGE", "android.permission.REQUEST_INSTALL_PACKAGES",
        "android.permission.SYSTEM_ALERT_WINDOW", "android.permission.QUERY_ALL_PACKAGES",
    )

    @Volatile private var cachedRules: ApkAdRules? = null

    fun load(context: Context): ApkAdRules {
        cachedRules?.let { return it }
        val json = context.assets.open("ad_patterns_default.json").bufferedReader().use { JSONObject(it.readText()) }
        fun values(key: String): List<String> = (json.optJSONArray(key)?.let { array ->
            (0 until array.length()).map { array.optString(it).trim().lowercase(Locale.ROOT) }.filter { it.length >= 4 }
        } ?: emptyList()).distinct()
        val prefs = context.getSharedPreferences("apk_mod_user_rules", Context.MODE_PRIVATE)
        fun custom(key: String): List<String> = prefs.getStringSet(key, emptySet())
            ?.map { it.trim().lowercase(Locale.ROOT) }?.filter { it.length >= 4 }?.distinct().orEmpty()
        fun merged(vararg lists: List<String>) = lists.flatMap { it }.distinct()
        return ApkAdRules(
            sdkPackages = merged(values("sdk_packages"), custom("sdk_packages")),
            classPatterns = merged(values("class_keywords"), values("ad_view_names"), values("ad_activities"), values("ad_services"), values("ad_receivers"), custom("class_patterns")),
            methodPatterns = merged(values("method_patterns"), custom("method_patterns")),
            urlPatterns = merged(values("url_patterns"), custom("url_patterns")),
            forceTrueMethods = merged(values("force_true_methods"), custom("force_true_methods")),
            forceFalseMethods = merged(values("force_false_methods"), custom("force_false_methods")),
            flutterStringPatterns = merged(values("flutter_string_patterns"), custom("flutter_string_patterns")),
            timeMethods = merged(values("force_true_time_methods"), custom("time_methods")),
            detectionVpn = custom("detection_vpn"), detectionEmulator = custom("detection_emulator"),
            detectionRoot = custom("detection_root"), detectionDebug = custom("detection_debug"),
            adAssetFiles = merged(values("ad_asset_files"), custom("ad_asset_files")),
            adPermissions = merged(values("ad_permissions"), custom("ad_permissions")),
            libFileKeywords = merged(values("lib_file_keywords"), custom("lib_file_keywords")),
        ).also { cachedRules = it }
    }

    fun invalidate() { cachedRules = null }
}
