package zhou.solab

import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.io.InputStream

/**
 * Aho-Corasick 字节级多模式流式匹配器（移植自参考项目 AdVendor.kt）。
 * 一次扫描同时匹配全部模式，复杂度与模式数量无关；
 * 1MB 块 + 重叠窗口防跨块遗漏；ASCII 大写按小写语义匹配；
 * 模式按 UTF-8 字节匹配（DEX 中文字符串为 UTF-8，可正确命中）。
 * 规则：本文件注释一律使用单行 //（避免 Kotlin 嵌套注释陷阱）。
 */
internal class ApkAhoCorasick(patterns: List<String>) {

    private class Node {
        val next = HashMap<Int, Int>() // 小写字节 -> 子节点
        var fail = 0
        val outputs = ArrayList<Int>(1)
    }

    private val nodes = ArrayList<Node>()
    private val originalPatterns = patterns.toList()
    private val patternBytes = patterns.map { pattern ->
        pattern.toByteArray(Charsets.UTF_8).also { bytes ->
            for (index in bytes.indices) {
                val raw = bytes[index].toInt() and 0xFF
                if (raw in 65..90) bytes[index] = (raw + 32).toByte()
            }
        }
    }

    init {
        build()
    }

    private fun build() {
        nodes.add(Node())
        for ((pi, pb) in patternBytes.withIndex()) {
            var cur = 0
            for (byte in pb) {
                val key = byte.toInt() and 0xFF
                var ni = nodes[cur].next[key]
                if (ni == null) {
                    ni = nodes.size
                    nodes.add(Node())
                    nodes[cur].next[key] = ni
                }
                cur = ni
            }
            nodes[cur].outputs.add(pi)
        }
        val queue = ArrayList<Int>()
        for (ni in nodes[0].next.values.distinct()) {
            nodes[ni].fail = 0
            queue.add(ni)
        }
        var qi = 0
        while (qi < queue.size) {
            val v = queue[qi++]
            for ((b, ni) in nodes[v].next.entries) {
                var f = nodes[v].fail
                while (f != 0 && b !in nodes[f].next) f = nodes[f].fail
                nodes[ni].fail = nodes[f].next[b] ?: 0
                nodes[ni].outputs.addAll(nodes[nodes[ni].fail].outputs)
                queue.add(ni)
            }
        }
    }

    /** 扫描文件，返回命中的模式（去重）。 */
    fun scanFile(file: File): Set<String> {
        if (patternBytes.isEmpty()) return emptySet()
        val found = HashSet<Int>()
        try {
            FileInputStream(file).use { fis ->
                BufferedInputStream(fis, STREAM_BUF_SIZE).use { bis ->
                    scanStream(bis, found)
                }
            }
        } catch (_: Exception) {
            return emptySet()
        }
        return found.mapTo(LinkedHashSet()) { originalPatterns[it] }
    }

    /** 扫描输入流，返回命中的模式（去重）。 */
    fun scanStream(input: InputStream): Set<String> {
        if (patternBytes.isEmpty()) return emptySet()
        val found = HashSet<Int>()
        try {
            BufferedInputStream(input, STREAM_BUF_SIZE).use { bis ->
                scanStream(bis, found)
            }
        } catch (_: Exception) {
            return emptySet()
        }
        return found.mapTo(LinkedHashSet()) { originalPatterns[it] }
    }

    private fun scanStream(bis: BufferedInputStream, found: MutableSet<Int>) {
        val buf = ByteArray(STREAM_BUF_SIZE)
        var read: Int
        var state = 0
        while (bis.read(buf).also { read = it } > 0) {
            state = scanBlock(buf, read, found, state)
        }
    }

    private fun scanBlock(
        bytes: ByteArray,
        len: Int,
        found: MutableSet<Int>,
        initialState: Int,
    ): Int {
        var state = initialState
        for (i in 0 until len) {
            val raw = bytes[i].toInt() and 0xFF
            // ASCII 大写转小写（DEX 标识符匹配语义）
            val b = if (raw in 65..90) raw + 32 else raw
            var s = state
            while (s != 0 && b !in nodes[s].next) s = nodes[s].fail
            state = nodes[s].next[b] ?: 0
            nodes[state].outputs.forEach(found::add)
        }
        return state
    }

    private companion object {
        const val STREAM_BUF_SIZE = 1024 * 1024
    }
}
