package zhou.solab.tools

import java.io.File
import java.util.LinkedHashMap
import java.util.zip.ZipFile

/**
 * APK ZipFile 进程级缓存（maxEntries 槽 LRU + 引用计数 pin）。
 *
 * 背景：每个工具调用各自 ZipFile(source) 重开 APK 要重新解析 central
 * directory（大包几十~几百 ms），agent 一轮连调多个 dex/smali/manifest
 * 工具时是纯重复开销。句柄按 path+mtime+size 指纹失效：补丁/重打包产生
 * 新文件时自动换新。
 *
 * 并发契约：调用方一律 withZip { } 配对使用。使用中的句柄带 pin，LRU
 * 驱逐与同 path 旧指纹回收都不得关闭 pinned 句柄——否则两个 worker 轮转
 * 第 3 个 APK 时会 close 掉另一线程正在遍历的 ZipFile（偶发
 * "Zip file closed"）。全部被 pin 时暂缓驱逐，fd 上界 = 并发数 + 槽数，
 * release 时补收。
 */
class ApkZipCache(private val maxEntries: Int = 2) {

    private class PinnedZip(val zip: ZipFile, val source: File) {
        var pins = 0
    }

    private val cache = LinkedHashMap<String, PinnedZip>(4, 0.75f, true)

    /** 使用期间句柄保证存活；退出（含异常/non-local return）必释放。 */
    inline fun <R> withZip(source: File, block: (ZipFile) -> R): R {
        val zip = open(source)
        try {
            return block(zip)
        } finally {
            release(zip)
        }
    }

    @PublishedApi
    internal fun apkZipKey(source: File): String =
        source.canonicalPath + "|" + source.lastModified() + "|" + source.length()

    @PublishedApi
    internal fun open(source: File): ZipFile {
        val pathKey = source.canonicalPath + "|"
        val key = apkZipKey(source)
        synchronized(cache) {
            // 同 path 旧指纹：无人使用立即回收；仍被 pin 的留给 release 补收
            cache.entries.filter { it.key.startsWith(pathKey) && it.key != key }.forEach { stale ->
                if (stale.value.pins == 0) {
                    cache.remove(stale.key)
                    runCatching { stale.value.zip.close() }
                }
            }
            cache[key]?.let {
                it.pins++
                return it.zip
            }
        }
        val fresh = ZipFile(source)
        synchronized(cache) {
            cache[key]?.let { existing ->
                // 并发同指纹：共用已有句柄，关掉自己刚开的那份
                existing.pins++
                runCatching { fresh.close() }
                return existing.zip
            }
            cache[key] = PinnedZip(fresh, source).also { it.pins = 1 }
            evictLocked()
        }
        return fresh
    }

    @PublishedApi
    internal fun release(zip: ZipFile) {
        synchronized(cache) {
            // 按句柄身份定位：open 与 release 之间文件可能被改写（指纹漂移），
            // 用 apkZipKey(source) 重算键会找不到自己的条目致 pin 泄漏
            val entryEntry = cache.entries.firstOrNull { it.value.zip === zip } ?: return
            val entry = entryEntry.value
            if (entry.pins > 0) entry.pins--
            if (entry.pins > 0) return
            entry.pins = 0
            // 回收时机：被新指纹顶替 / 文件已被改写（句柄已无用）/ 补驱逐欠账
            val superseded = cache.keys.any { it != entryEntry.key && it.startsWith(entry.source.canonicalPath + "|") }
            val stale = apkZipKey(entry.source) != entryEntry.key
            if (superseded || stale || cache.size > maxEntries) {
                cache.remove(entryEntry.key)
                runCatching { zip.close() }
            }
        }
    }

    /** LRU 驱逐：跳过使用中的句柄；全被 pin 时暂缓。 */
    private fun evictLocked() {
        while (cache.size > maxEntries) {
            val victim = cache.entries.firstOrNull { it.value.pins == 0 } ?: break
            cache.remove(victim.key)
            runCatching { victim.value.zip.close() }
        }
    }

    /** 测试钩子：观察 pin 与缓存状态（仅单测使用）。 */
    internal fun pinCountForTest(zip: ZipFile): Int = synchronized(cache) {
        cache.values.firstOrNull { it.zip === zip }?.pins ?: -1
    }

    internal fun sizeForTest(): Int = synchronized(cache) { cache.size }
}
