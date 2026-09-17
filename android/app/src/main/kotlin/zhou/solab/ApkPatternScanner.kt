package zhou.solab

import java.io.InputStream
import java.util.Locale

internal object ApkPatternScanner {
    fun scan(input: InputStream, patterns: Collection<String>): Set<String> {
        if (patterns.isEmpty()) return emptySet()
        val originals = linkedMapOf<String, String>()
        for (pattern in patterns) {
            val original = pattern.trim().lowercase(Locale.ROOT)
            if (original.isEmpty()) continue
            originals.putIfAbsent(original, original)
            originals.putIfAbsent(original.replace('.', '/'), original)
        }
        if (originals.isEmpty()) return emptySet()
        return ApkAhoCorasick(originals.keys.toList())
            .scanStream(input)
            .mapNotNull(originals::get)
            .toCollection(linkedSetOf())
    }

    /**
     * 单遍双模式扫描：两个模式族共用一次流式解压（各自动机构建后合并为
     * 一个自动机跑一遍），分别归类返回。用于 analyze 主循环把签名校验
     * 检测并入 DEX 规则扫描，避免同一批 dex 解压两遍。
     */
    fun scanDual(
        input: InputStream,
        patterns: Collection<String>,
        extraPatterns: Collection<String>,
    ): Pair<Set<String>, Set<String>> {
        fun normalize(source: Collection<String>): LinkedHashMap<String, String> {
            val originals = linkedMapOf<String, String>()
            for (pattern in source) {
                val original = pattern.trim().lowercase(Locale.ROOT)
                if (original.isEmpty()) continue
                originals.putIfAbsent(original, original)
                originals.putIfAbsent(original.replace('.', '/'), original)
            }
            return originals
        }
        val primary = normalize(patterns)
        val extra = normalize(extraPatterns)
        if (primary.isEmpty() && extra.isEmpty()) return emptySet<String>() to emptySet()
        val hits = ApkAhoCorasick((primary.keys + extra.keys).toList()).scanStream(input)
        val primaryHits = hits.mapNotNull(primary::get).toCollection(linkedSetOf())
        val extraHits = hits.mapNotNull(extra::get).toCollection(linkedSetOf())
        return primaryHits to extraHits
    }
}
