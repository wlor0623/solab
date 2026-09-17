package zhou.solab.tools

import android.content.Context
import com.android.tools.smali.dexlib2.iface.ClassDef
import com.android.tools.smali.dexlib2.iface.Field
import com.android.tools.smali.dexlib2.iface.Method
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * M2: 类大纲引擎（自研，替代 MT 的 outline_class）。
 *
 * 按类名列出方法/字段签名。用途：混淆类（短名 b/c/d 无规则关键字）
 * 浏览兜底通道——规则匹配不到时用本工具看类里有什么。
 */
object ClassOutlineEngine {

    private const val MAX_APK_BYTES = 512L * 1024 * 1024

    private fun qidOf(m: Method): String =
        "${m.definingClass}->${m.name}(${m.parameterTypes.joinToString("")})${m.returnType}"

    fun outline(
        context: Context,
        apkPath: String,
        className: String,
        offset: Int = 0,
        limit: Int = 200,
    ): JSONObject {
        val apk = File(apkPath)
        if (!apk.isFile) return err("FILE_NOT_FOUND", "APK 不存在: $apkPath", "apkPath", apkPath)
        if (apk.length() > MAX_APK_BYTES) return err("APK_LIMIT_EXCEEDED", "APK 超过 512MiB 上限", "apkPath", apkPath)
        val target = className.trim()
            .substringBefore("->") // 兼容 qualifiedId（Lpkg/C;->method）直接喂入
            .let { if (!it.contains('/') && it.contains('.')) it.replace('.', '/') else it } // 点分 → 斜杠
            .trim()
        if (target.isBlank()) return err("INVALID_ARGUMENT", "缺少 className", "className", "")

        val wantExact = target.startsWith("L") && target.endsWith(";")

        return runCatching {
            var found = false
            var sourceFile = ""
            var totalMethods = 0
            var totalFields = 0
            val methods = JSONArray()
            val fields = JSONArray()
            // T4: offset 作用于跨 dex 聚合后的方法序列（跳过前 offset 个再取
            // limit 个）；字段不参与分页，始终从头取 limit 条。修复此前
            // offset 声明未生效——大方法数类翻页读到同一页/计数溢出。
            var methodIndex = 0

            DexIo.eachDex(context, apk) { dexName, dexFile ->
                for (cls: ClassDef in dexFile.classes) {
                    val matches = if (wantExact) cls.type == target
                    else cls.type.contains(target, ignoreCase = true) ||
                        cls.type.removePrefix("L").removeSuffix(";").substringAfterLast('/').contains(target, ignoreCase = true)
                    if (!matches) continue
                    found = true
                    if (sourceFile.isEmpty()) sourceFile = cls.sourceFile ?: ""
                    totalMethods += cls.methods.count()
                    totalFields += cls.fields.count()
                    if (methodIndex < offset + limit && methods.length() < limit) {
                        cls.methods.forEach { m ->
                            methodIndex++
                            if (methodIndex <= offset) return@forEach
                            if (methods.length() >= limit) return@forEach
                            val flags = m.accessFlags
                            methods.put(JSONObject()
                                .put("name", m.name)
                                .put("signature", "(${m.parameterTypes.joinToString("")})${m.returnType}")
                                .put("qualifiedId", qidOf(m))
                                .put("returnType", m.returnType)
                                .put("isStatic", flags and 0x8 != 0)
                                .put("isPrivate", flags and 0x2 != 0)
                                .put("isConstructor", m.name == "<init>" || m.name == "<clinit>")
                                .put("dexFile", dexName))
                        }
                    } else {
                        // 已越过当前页窗口：仅累计计数保证 offset 连续
                        methodIndex += cls.methods.count()
                    }
                    if (fields.length() < limit) {
                        cls.fields.forEach { f: Field ->
                            if (fields.length() >= limit) return@forEach
                            fields.put(JSONObject()
                                .put("name", f.name)
                                .put("type", f.type)
                                .put("isStatic", f.accessFlags and 0x8 != 0)
                                .put("isPrivate", f.accessFlags and 0x2 != 0)
                                .put("dexFile", dexName))
                        }
                    }
                    // 命中后继续扫描其余 dex（同名类可能多 dex 分布），不 break
                }
                System.gc()
            }

            if (!found) {
                return@runCatching err(
                    "CLASS_NOT_FOUND", "未在 DEX 中找到类: $target（可尝试短名/子串，或先用 dex_search 反查真实类名）",
                    "className", className,
                )
            }

            val hasMoreMethods = offset + methods.length() < totalMethods
            ok(JSONObject()
                .put("tool", "class_outline")
                .put("className", target)
                .put("sourceFile", sourceFile)
                .put("methods", methods)
                .put("fields", fields)
                .put("totalMethods", totalMethods)
                .put("totalFields", totalFields)
                .put("offset", offset)
                .put("returnedMethods", methods.length())
                .put("hasMore", hasMoreMethods)
                .put("nextOffset", if (hasMoreMethods) offset + methods.length() else JSONObject.NULL)
                .put("truncated", hasMoreMethods)
                .put("hint", "混淆类定位: 拿到方法 qualifiedId 后可喂给 dex_xref 查调用者,或 patch_apk_dex_methods.classMethods 精确补丁; 方法多时用 offset/limit 翻页"))
        }.getOrElse { e ->
            err("XREF_INDEX_FAILED", "类大纲构建失败: ${e.message ?: e.javaClass.simpleName}", "apkPath", apkPath)
        }
    }
}
