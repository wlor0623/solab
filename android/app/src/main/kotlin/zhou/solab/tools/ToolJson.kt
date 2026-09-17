package zhou.solab.tools

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 移植自玄星逆核 JsonUtil。
 *
 * 信封：成功 {ok:true, nextActions:[], ...业务字段}；
 *      失败 {ok:false, error:{code, message, severity, recoverable,
 *            retrySameArguments, diagnostics, argument?, badValue?}, message, nextActions:[]}
 * 顶层 message 为 Solab 旧格式兼容字段（旧 Dart 解析 {ok,error,message}）。
 */

fun JSONObject.str(name: String, default: String = ""): String = optString(name, default)

fun JSONObject.intValue(name: String, default: Int = 0): Int =
    if (has(name)) optInt(name, default) else default

fun JSONObject.bool(name: String, default: Boolean = false): Boolean =
    if (has(name)) optBoolean(name, default) else default

fun JSONObject.doubleValue(name: String, default: Double = 0.0): Double =
    if (has(name)) optDouble(name, default) else default

fun ok(payload: JSONObject = JSONObject()): JSONObject {
    payload.put("ok", true)
    if (!payload.has("nextActions")) payload.put("nextActions", JSONArray())
    return payload
}

fun JSONObject.obj(name: String): JSONObject = optJSONObject(name) ?: JSONObject()

fun Iterable<Any?>.toJsonArray(): JSONArray {
    val arr = JSONArray()
    forEach { arr.put(it) }
    return arr
}

fun err(code: String, message: String, argument: String? = null, badValue: Any? = null): JSONObject {
    val error = JSONObject()
        .put("code", code)
        .put("message", message)
        .put("severity", "error")
        .put("recoverable", true)
        .put("retrySameArguments", false)
        .put("diagnostics", JSONObject())
    if (argument != null) error.put("argument", argument)
    if (badValue != null) error.put("badValue", badValue)
    return JSONObject()
        .put("ok", false)
        .put("error", error)
        .put("message", message)
        .put("nextActions", JSONArray())
}

fun err(code: String, message: String, argument: String?, badValue: Any?, vararg extra: Pair<String, Any?>): JSONObject {
    val result = err(code, message, argument, badValue)
    val diag = result.getJSONObject("error").getJSONObject("diagnostics")
    extra.forEach { (k, v) -> if (v != null) diag.put(k, v) }
    return result
}

/**
 * 统一输入文件校验（复用：消除各工具重复的
 * `ifBlank → INVALID_ARGUMENT → FILE_NOT_FOUND` 三段模式）。
 *
 * @return first=校验通过的 File；second=失败时的错误信封（此时 first 为 null）。
 */
fun resolveInputFile(
    args: JSONObject,
    key: String = "path",
    alias: String = "filePath",
): Pair<File?, JSONObject?> {
    val raw = args.str(key).ifBlank { args.str(alias) }
    if (raw.isBlank()) {
        return null to err("INVALID_ARGUMENT", "缺少参数 $key（或 $alias）", key, "")
    }
    val file = File(raw)
    if (!file.isFile) {
        return null to err("FILE_NOT_FOUND", "文件不存在: $raw", key, raw)
    }
    return file to null
}

/**
 * 工具产物输出根目录：优先用户设定的统一工作目录（Dart 侧 dispatch 注入的
 * workDir 参数，与 APK 补丁类产物同根）。未提供时直接拒绝写入，避免产物
 * 落进应用内部目录后不可见、难清理。
 * 子目录名 [sub] 沿用原内部布局（jadx-out / apkeditor-out / extracted / ...），
 * 保证文件列表一眼可见、用户文件管理器可直接访问。
 */
fun outputRoot(context: android.content.Context, args: JSONObject, sub: String): File {
    val wd = args.str("workDir")
    if (wd.isBlank()) error("WORK_DIRECTORY_REQUIRED: 请先设置工作目录")
    return File(wd, "SoLab/$sub")
}

fun safeArtifactName(raw: String, fallback: String = "artifact"): String {
    val clean = raw.replace(Regex("""[\\/:*?"<>|\p{Cntrl}]"""), "_").trim()
    return clean.ifBlank { fallback }
}

// 与旧 BlutterExecBackend.isFunctionLine 1:1 的清单行判定（单一定义源）。
private val ASM_NON_FUNCTION_PREFIXES =
    arrayOf("//", "/*", "*", "class ", "[Error]", "[unknown]")

internal fun asmInventoryFunctionLine(line: String): Boolean {
    if (ASM_NON_FUNCTION_PREFIXES.any { line.startsWith(it) }) return false
    val open = line.indexOf('(')
    if (open <= 0 || line.indexOf(')', open) < 0) return false
    return line.endsWith("{") || line.endsWith(";") || line.endsWith("){") || line.endsWith(");")
}
