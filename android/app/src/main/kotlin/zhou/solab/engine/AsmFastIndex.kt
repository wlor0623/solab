package zhou.solab.engine

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.Callable
import java.util.concurrent.Executors

/**
 * 分析产物"快速索引"构建器：原先 inventory 三类 jsonl 与函数头二进制是两次
 * 独立的全量 asm 走读；这里合并为 **一次排序后并行分片扫描**，墙钟时间约
 * ÷分片数。每行同时喂给两套原口径谓词（ExecBackend.isFunctionLine 与
 * SearchIndex.isFunctionSignature + FUNC_ADDR 头），输出与旧实现逐字段兼容：
 *
 *  - blutter-function-headers-v2.bin：MAGIC + (va,size,signature,class,file)；
 *  - libraries/classes/functions.jsonl：行为全局按相对路径排序的确定性顺序，
 *    id 在合并阶段连续重编号（旧 walkTopDown 顺序依赖文件系统，此版更稳）。
 */
internal object AsmFastIndex {

    private const val HEADER_BIN = "blutter-function-headers-v2.bin"
    private const val HEADER_MAGIC = 0x42464832 // = FUNCTION_HEADER_INDEX_MAGIC
    private const val PATH_INDEX = "blutter-asm-paths-v1.txt"

    class Counts(
        val libraries: Int,
        val classes: Int,
        val functions: Int,
        val headerRecords: Int,
        val scannedFiles: Int,
        val elapsedMs: Long,
    )

    // 清单行判定走 tools.ToolJson 的单一定义源。
    private fun isInventoryFunctionLine(line: String): Boolean =
        zhou.solab.tools.asmInventoryFunctionLine(line)

    fun build(resultDir: File): Counts {
        val started = System.nanoTime()
        val asmDir = File(resultDir, "asm")
        require(asmDir.isDirectory) { "ASM_RESULT_NOT_FOUND" }

        val sortedFiles = asmDir.walkTopDown()
            .filter { it.isFile && it.extension == "dart" }
            .toList()
            .sortedBy { it.relativeTo(asmDir).path }
        if (sortedFiles.isEmpty()) {
            writeAllEmpty(resultDir)
            return Counts(0, 0, 0, 0, 0, elapsed(started))
        }
        writePathIndex(resultDir, asmDir, sortedFiles)

        val threads = Runtime.getRuntime().availableProcessors().coerceIn(2, 6)
            .coerceAtMost(sortedFiles.size)
        val perChunk = (sortedFiles.size + threads - 1) / threads
        val pool = Executors.newFixedThreadPool(threads)

        val futures = (sortedFiles.indices step perChunk).map { start ->
            pool.submit(
                Callable {
                    scanChunk(sortedFiles.subList(start, minOf(start + perChunk, sortedFiles.size)), asmDir)
                },
            )
        }
        val chunks = futures.map { it.get() }
        pool.shutdown()

        var libTotal = 0; var clsTotal = 0; var fnTotal = 0; var headerCount = 0
        val libsSb = StringBuilder(); val clsSb = StringBuilder(); val fnSb = StringBuilder()
        val bin = ByteArrayOutputStream(1 shl 16)

        for (chunk in chunks) {
            chunk.headerBytes.forEach(bin::write)
            headerCount += chunk.headerCount
            for (n in chunk.libNames) libsSb.append(row("library", "library-${libTotal++}", n))
            for (n in chunk.classNames) clsSb.append(row("class", "class-${clsTotal++}", n))
            for (n in chunk.fnNames) fnSb.append(row("function", "function-${fnTotal++}", n))
        }

        writeHeaderBin(resultDir, bin.toByteArray())
        writeText(File(resultDir, "libraries.jsonl"), libsSb.toString())
        writeText(File(resultDir, "classes.jsonl"), clsSb.toString())
        writeText(File(resultDir, "functions.jsonl"), fnSb.toString())

        return Counts(libTotal, clsTotal, fnTotal, headerCount, sortedFiles.size, elapsed(started))
    }

    private fun scanChunk(files: List<File>, asmDir: File): ChunkOut {
        val out = ChunkOut()
        for (file in files) {
            out.files++
            val rel = "asm/${file.relativeTo(asmDir).path}"

            // 库 URL 行固定在文件首部注释中。兼容 url: / url= / 无分隔符写法，
            // 引号内为权威值；无匹配时退回相对路径。
            val libLine = file.useLines { it.firstOrNull { l -> l.startsWith("// lib:") } }
            val urlMatch = libLine?.let { Regex("url\\s*[:=]?\\s*'([^']+)'").find(it) }
            out.libNames.add(
                urlMatch?.groupValues?.get(1)
                    ?.takeIf(String::isNotEmpty) ?: file.relativeTo(asmDir).path.replace('\\', '/'),
            )

            var currentClass: String? = null
            var pendingSignature: String? = null

            file.useLines { seq ->
                for (raw in seq) {
                    val trimmed = raw.trim()

                    // ── 口径 A：SearchIndex 函数头注释 → 二进制记录 ──
                    BlutterSearchIndex.headerAddrSize(raw)?.let { (va, size) ->
                        out.addHeader(va, size, pendingSignature ?: "", currentClass ?: "", rel)
                        pendingSignature = null
                    }
                    if (raw.startsWith("  ") && !trimmed.startsWith("//") &&
                        !trimmed.startsWith("class ") && BlutterSearchIndex.isFunctionSignature(trimmed)
                    ) {
                        pendingSignature = trimmed.trimEnd('{', ' ', ';')
                    }

                    // ── 口径 B：inventory 清单行（与旧 ExecBackend 判定一致） ──
                    if (trimmed.startsWith("class ") && trimmed.endsWith("{")) {
                        currentClass = trimmed.removePrefix("class ")
                            .substringBefore('{').substringBefore("//").trim()
                        out.classNames.add(currentClass!!)
                    } else if (isInventoryFunctionLine(trimmed)) {
                        out.fnNames.add(trimmed)
                    }
                }
            }
        }
        return out
    }

    private class ChunkOut {
        val headerBytes = ArrayList<ByteArray>(64)
        var headerCount = 0
        val libNames = ArrayList<String>()
        val classNames = ArrayList<String>()
        val fnNames = ArrayList<String>()
        var files = 0
        fun addHeader(va: Long, size: Long, signature: String, className: String, rel: String) {
            val bos = ByteArrayOutputStream(48)
            DataOutputStream(bos).use { o ->
                o.writeLong(va)
                o.writeLong(size)
                o.writeUTF(signature)
                o.writeUTF(className)
                o.writeUTF(rel)
            }
            headerBytes.add(bos.toByteArray())
            headerCount++
        }
    }

    private fun row(kind: String, id: String, name: String): String =
        org.json.JSONObject().put("kind", kind).put("id", id).put("name", name).toString() + "\n"

    private fun writeHeaderBin(resultDir: File, records: ByteArray) {
        val tmp = File(resultDir, "$HEADER_BIN.tmp")
        DataOutputStream(tmp.outputStream().buffered(1 shl 16)).use {
            it.writeInt(HEADER_MAGIC)
            it.write(records)
        }
        Files.move(tmp.toPath(), File(resultDir, HEADER_BIN).toPath(),
            StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    }

    private fun writeText(target: File, content: String) {
        val tmp = File(target.parentFile, target.name + ".tmp")
        tmp.writeText(content)
        Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
    }

    private fun writePathIndex(resultDir: File, asmDir: File, files: List<File>) {
        writeText(
            File(resultDir, PATH_INDEX),
            files.joinToString(separator = "\n", postfix = "\n") {
                "asm/${it.relativeTo(asmDir).path.replace('\\', '/')}"
            },
        )
    }

    private fun writeAllEmpty(resultDir: File) {
        writeHeaderBin(resultDir, ByteArray(0))
        writeText(File(resultDir, PATH_INDEX), "")
        writeText(File(resultDir, "libraries.jsonl"), "")
        writeText(File(resultDir, "classes.jsonl"), "")
        writeText(File(resultDir, "functions.jsonl"), "")
    }

    private fun elapsed(startedNs: Long) = (System.nanoTime() - startedNs) / 1_000_000
}
