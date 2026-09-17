package zhou.solab.engine

import org.json.JSONArray
import zhou.solab.tools.ok
import org.json.JSONObject

/**
 * 情报型只读动作：crypto_scan（密码学常量/导入符号识别）与 jni_bridge
 * （Java_* 导出符号 → 点分 JNI 类方法配对）。
 *
 * 两者都是纯读：不改工作区/编辑会话状态，也不参与 diff 流水。
 * crypto_scan 在 ELF 全文件字节上做规则搜索——覆盖 rodata、data.rel.ro
 * 与指令流中的立即数；导入符号另按兴趣模式列出，双通道互为佐证。
 */

internal fun EngineRuntime.cryptoScan(
    workspaceId: String,
    editSessionId: String,
    maxHits: Int = 128,
): JSONObject = guarded {
    val bytes = dataFor(workspaceId, editSessionId)

    // 合并 BYTES / TEXT 两类规则：ASCII 文案按字节等价处理，走同一扫描器。
    val byteRules = CryptoSig.RULES.map { rule ->
        rule.id to (rule.bytes ?: rule.text!!.map(Char::toByte).toByteArray())
    }

    val hitsByRule = HashMap<String, Int>()
    val hits = JSONArray()
    var overflow = false
    outer@ for ((id, pat) in byteRules) {
        val rule = CryptoSig.RULES.first { it.id == id }
        var idx = indexOfBytes(bytes, pat, 0)
        var count = 0
        while (idx >= 0) {
            if (hits.length() < maxHits) {
                hits.put(
                    JSONObject()
                        .put("rule", id)
                        .put("name", rule.name)
                        .put("family", rule.family)
                        .put("kind", if (rule.bytes != null) "bytes" else "text")
                        .put("offset", "0x${idx.toString(16)}"),
                )
            } else {
                overflow = true
            }
            count++
            idx = indexOfBytes(bytes, pat, idx + 1)
        }
        if (count > 0) hitsByRule[rule.name] = count
    }

    // 导入符号里的加密相关 API（crypto 库即使静态链接也常留动态依赖）
    val elf = runCatching { ElfParser(bytes).parse() }.getOrNull()
    val imports = JSONArray()
    if (elf != null) {
        val seen = linkedSetOf<String>()
        for (sym in elf.dynSymbols) {
            if (!sym.imported) continue
            if (!CryptoSig.matchesInterest(sym.name)) continue
            if (seen.add(sym.name)) imports.put(sym.name)
            if (imports.length() >= 64) break
        }
    }

    ok(
        JSONObject()
            .put("action", "crypto_scan")
            .put("scannedBytes", bytes.size)
            .put("hitCount", hitsByRule.values.sum())
            .put("countsByRule", JSONObject(hitsByRule as Map<*, *>))
            .put("truncated", overflow)
            .put("hits", hits)
            .put("interestImports", imports),
    )
}

internal fun EngineRuntime.jniBridge(
    workspaceId: String,
    editSessionId: String,
    limit: Int = 200,
): JSONObject = guarded {
    val bytes = dataFor(workspaceId, editSessionId)
    val elf = ElfParser(bytes).parse()

    val entries = JniBridge.build(elf.dynSymbols)
    val classes = linkedSetOf<String>()
    val rows = JSONArray()
    var ambiguousCount = 0
    for (e in entries.take(limit)) {
        classes.add(e.classPath.replace('/', '.'))
        if (e.ambiguous) ambiguousCount++
        rows.put(
            JSONObject()
                .put("symbol", e.symbol)
                .put("address", "0x${e.address.toString(16)}")
                .put("classPath", e.classPath.replace('/', '.'))
                .put("method", e.method.ifEmpty { JSONObject.NULL })
                .put("form", if (e.shortForm) "short" else "long/escaped")
                .put("ambiguousName", e.ambiguous),
        )
    }

    ok(
        JSONObject()
            .put("action", "jni_bridge")
            .put("bridgeCount", entries.size)
            .put("classes", JSONArray(classes.toList().take(limit)))
            .put("bridges", rows)
            .put("ambiguousNameCount", ambiguousCount)
            .put(
                "hint",
                "classes 表与 DEX native 声明求交集即桥接点；含 _1/__ 的符号为长名转义，配对需人工核对。",
            ),
    )
}

private fun indexOfBytes(data: ByteArray, pat: ByteArray, from: Int): Int {
    if (pat.isEmpty()) return -1
    var i = from.coerceAtLeast(0)
    val last = data.size - pat.size
    if (last < 0) return -1
    val first = pat[0]
    while (i <= last) {
        if (data[i] == first) {
            var j = 1
            while (j < pat.size && data[i + j] == pat[j]) j++
            if (j == pat.size) return i
        }
        i++
    }
    return -1
}
