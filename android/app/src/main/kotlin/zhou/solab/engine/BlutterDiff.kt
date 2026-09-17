package zhou.solab.engine

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 跨版本差分（v1）：对两个 blutter 结果目录做"函数级锚定指纹"匹配，
 * 输出旧→新的 VA 迁移候选，用于把旧对话的 pendingChanges 快速移植到新包。
 *
 * 指纹 = 函数体内引用的对象池偏移集合（[pp+0x..] 注释）。混淆改名不影响
 * 锚点集合，因此 similarity 对改名免疫；函数完全对应时 sim=1。
 */
object BlutterDiff {

    data class FuncRec(
        val va: Long,
        val size: Long,
        val name: String,
        val className: String,
        val rel: String,
        val anchors: Set<Long>,
    )

    private val PP_REF = Regex("\\[pp\\+0x([0-9a-fA-F]+)]", RegexOption.IGNORE_CASE)

    private class Builder(
        val va: Long,
        val size: Long,
        val rel: String,
        var className: String,
    ) {
        var name: String = ""
        val anchors = linkedSetOf<Long>()
        fun commit(into: MutableList<FuncRec>) {
            into.add(FuncRec(va, size, name, className, rel, anchors.toSet()))
        }
    }

    /** 单次遍历一个结果目录，产出函数记录列表（按文件相对路径稳定排序）。 */
    fun buildIndex(resultDir: File): List<FuncRec> {
        val asmDir = File(resultDir, "asm")
        require(asmDir.isDirectory) { "ASM_RESULT_NOT_FOUND:${resultDir.name}" }

        val sortedFiles = asmDir.walkTopDown()
            .filter { it.isFile && it.extension == "dart" }
            .toList()
            .sortedBy { it.relativeTo(asmDir).path }

        val out = ArrayList<FuncRec>(1024)

        for (file in sortedFiles) {
            val rel = "asm/${file.relativeTo(asmDir).path}"
            var cur: Builder? = null
            var currentClass: String? = null
            var pendingSig: String? = null

            fun commit() {
                cur?.commit(out)
                cur = null
                pendingSig = null
            }

            file.useLines { seq ->
                for (raw in seq) {
                    val trimmed = raw.trim()

                    // 新函数头：闭合上一个，开启下一个
                    val header = BlutterSearchIndex.headerAddrSize(raw)
                    if (header != null) {
                        commit()
                        cur = Builder(
                            header.first,
                            header.second,
                            rel,
                            currentClass.orEmpty(),
                        )
                        continue
                    }

                    // 缩进两行的签名行：挂到当前（或即将到来的）函数名上
                    if (raw.startsWith("  ") && !trimmed.startsWith("//") &&
                        BlutterSearchIndex.isFunctionSignature(trimmed)
                    ) {
                        pendingSig = trimmed.trimEnd('{', ' ', ';')
                        cur?.name = pendingSig ?: ""
                        continue
                    }

                    // 类声明更新归属
                    if (trimmed.startsWith("class ") && trimmed.endsWith("{")) {
                        currentClass = trimmed.removePrefix("class ")
                            .substringBefore('{').substringBefore("//").trim()
                        cur?.className = currentClass!!
                        continue
                    }

                    // 函数体池引用 → 锚点集合（只在当前函数有效范围内收集）
                    cur?.let { b ->
                        for (m in PP_REF.findAll(raw)) {
                            m.groupValues[1].lowercase().toLongOrNull(16)?.let { b.anchors.add(it) }
                        }
                    }
                }
            }
            commit()
        }
        return out.distinctBy { Triple(it.rel, it.va, it.name) }
    }

    /**
     * 匹配旧索引中类/路径含 [oldPrefix] 的函数到新索引；返回映射行
     * （oldVa/newVa/similarity/sharedAnchors），升序 by oldVa。
     */
    fun match(
        oldIdx: List<FuncRec>,
        newIdx: List<FuncRec>,
        oldPrefix: String,
        minSimilarity: Double,
        limit: Int,
    ): JSONArray {
        val inv = HashMap<Long, MutableList<Int>>()
        newIdx.forEachIndexed { i, f ->
            f.anchors.forEach { a -> inv.getOrPut(a) { mutableListOf() }.add(i) }
        }

        val rows = ArrayList<JSONObject>()
        val prefix = oldPrefix.lowercase()
        for (oldFn in oldIdx.sortedBy { it.va }) {
            if (rows.size >= limit) break
            if (prefix.isNotEmpty()) {
                val hay = "${oldFn.className} ${oldFn.rel} ${oldFn.name}".lowercase()
                if (!hay.contains(prefix)) continue
            }
            if (oldFn.anchors.isEmpty()) continue

            val candCounts = HashMap<Int, Int>()
            for (a in oldFn.anchors) {
                inv[a]?.forEach { candCounts[it] = (candCounts[it] ?: 0) + 1 }
            }
            var bestI = -1
            var bestSim = 0.0
            var bestShared = 0
            for ((i, shared) in candCounts) {
                val needMin = if (oldFn.anchors.size > 2) 2 else 1
                if (shared < needMin) continue
                val union = (oldFn.anchors.size + newIdx[i].anchors.size - shared).coerceAtLeast(1)
                val sim = shared.toDouble() / union
                if (sim > bestSim ||
                    (sim == bestSim && (shared > bestShared ||
                        (shared == bestShared && (bestI < 0 || newIdx[i].va < newIdx[bestI].va))))) {
                    bestSim = sim; bestI = i; bestShared = shared
                }
            }
            if (bestI < 0 || bestSim < minSimilarity) continue
            val nf = newIdx[bestI]
            rows.add(
                JSONObject()
                    .put("oldVa", "0x${oldFn.va.toString(16)}")
                    .put("oldName", oldFn.name.ifEmpty { JSONObject.NULL })
                    .put("oldClass", oldFn.className.ifEmpty { JSONObject.NULL })
                    .put("newVa", "0x${nf.va.toString(16)}")
                    .put("newName", nf.name.ifEmpty { JSONObject.NULL })
                    .put("newClass", nf.className.ifEmpty { JSONObject.NULL })
                    .put("similarity", Math.round(bestSim * 1000) / 1000.0)
                    .put("sharedAnchors", bestShared),
            )
        }
        return JSONArray(rows)
    }
}
