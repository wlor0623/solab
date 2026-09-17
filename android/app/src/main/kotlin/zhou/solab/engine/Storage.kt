package zhou.solab.engine

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import zhou.solab.tools.AppLog
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.zip.ZipInputStream

data class SoSource(
    val path: String,
    val source: String,
    val name: String,
    val size: Long,
    val modified: Long,
    val treeDocumentUri: Uri?,
    val apkPath: String? = null,
    val apkEntry: String? = null,
    val abi: String? = null,
) {
    override fun equals(other: Any?): Boolean = other is SoSource && other.path == path
    override fun hashCode(): Int = path.hashCode()
}

data class ScanOptions(
    val scanApks: Boolean = true,
    val scanSubdirectories: Boolean = true,
    val maxDepth: Int = 8,
    val skipFilesLargerThanBytes: Long = 512L * 1024L * 1024L,
)

data class FileFingerprint(
    val path: String,
    val size: Long,
    val modified: Long,
)

class WorkDirectory(
    private val context: Context,
    private val treeUri: Uri? = null,
    val rootPath: String? = null,
) {
    /** path 模式（非 SAF）：直接以文件系统路径访问（需 MANAGE_EXTERNAL_STORAGE）。 */
    val isPathMode: Boolean get() = rootPath != null
    private val resolver: ContentResolver = context.contentResolver
    private val cache = ScanCacheStore(context.applicationContext)
    private val treeKey = treeUri?.toString() ?: rootPath.orEmpty()
    private val documentUris = ConcurrentHashMap<String, Uri>()

    fun fingerprint(options: ScanOptions): List<FileFingerprint> {
        if (isPathMode) {
            val out = mutableListOf<FileFingerprint>()
            walkPath(File(rootPath), "", 0, options) { displayName, relativePath, size, modified ->
                if (displayName.endsWith(".so", ignoreCase = true) || (options.scanApks && displayName.endsWith(".apk", ignoreCase = true))) {
                    out += FileFingerprint(relativePath, size, modified)
                }
            }
            return out.sortedWith(compareBy<FileFingerprint> { it.path }.thenBy { it.modified }.thenBy { it.size })
        }
        val out = mutableListOf<FileFingerprint>()
        runCatching { walk(treeUri!!, "", 0, options) { _, displayName, relativePath, size, modified ->
            if (displayName.endsWith(".so", ignoreCase = true) || (options.scanApks && displayName.endsWith(".apk", ignoreCase = true))) {
                out += FileFingerprint(relativePath, size, modified)
            }
        } }.onFailure { AppLog.w("Failed to fingerprint work directory: ${it.message}") }
        return out.sortedWith(compareBy<FileFingerprint> { it.path }.thenBy { it.modified }.thenBy { it.size })
    }

    fun listSos(options: ScanOptions = ScanOptions()): List<SoSource> {
        val out = mutableListOf<SoSource>()
        if (isPathMode) {
            walkPath(File(rootPath), "", 0, options) { displayName, relativePath, size, modified ->
                if (displayName.endsWith(".so", ignoreCase = true)) {
                    out += SoSource(relativePath, "filesystem", displayName, size, modified, null)
                } else if (options.scanApks && displayName.endsWith(".apk", ignoreCase = true)) {
                    runCatching {
                        val f = File(rootPath, relativePath)
                        out += listApkSosFromFile(f)
                    }
                }
            }
            return out.sortedBy { it.path }
        }
        runCatching { walk(treeUri!!, "", 0, options) { docUri, displayName, relativePath, size, modified ->
            if (displayName.endsWith(".so", ignoreCase = true)) {
                out += SoSource(relativePath, "filesystem", displayName, size, modified, docUri)
            } else if (options.scanApks && displayName.endsWith(".apk", ignoreCase = true)) {
                runCatching {
                    val cached = runCatching { cache.apkEntries(treeKey, relativePath, size, modified) }.getOrElse {
                        AppLog.w("Failed to read scan cache for $relativePath: ${it.message}")
                        emptyList()
                    }
                    if (cached.isNotEmpty()) {
                        out += cached.map {
                            SoSource(
                                path = "apk:$relativePath!${it.entry}",
                                source = "apk",
                                name = it.name,
                                size = it.size,
                                modified = modified,
                                treeDocumentUri = docUri,
                                apkPath = relativePath,
                                apkEntry = it.entry,
                                abi = it.abi,
                            )
                        }
                    } else {
                        val entries = listApkSos(relativePath, docUri, modified)
                        runCatching { cache.putApkEntries(
                            treeKey,
                            relativePath,
                            size,
                            modified,
                            entries.map { CachedApkSo(relativePath, it.apkEntry.orEmpty(), it.name, it.abi.orEmpty(), it.size) },
                        ) }.onFailure { AppLog.w("Failed to update scan cache for $relativePath: ${it.message}") }
                        out += entries
                    }
                }.onFailure { AppLog.w("Failed to scan APK $relativePath: ${it.message}") }
            }
        } }.onFailure { AppLog.w("Failed to scan work directory: ${it.message}") }
        return out.sortedBy { it.path }
    }

    fun cachedSummary(source: SoSource): CachedSourceSummary? =
        cache.sourceSummary(treeKey, source.path, source.size, source.modified)

    fun putCachedSummary(source: SoSource, summary: CachedSourceSummary) {
        cache.putSourceSummary(treeKey, source.path, source.size, source.modified, summary)
    }

    fun clearPersistentCache() {
        cache.clear()
        documentUris.clear()
    }

    fun readSource(source: SoSource): ByteArray {
        if (isPathMode && source.source != "apk" && source.treeDocumentUri == null) {
            val heapBudget = (Runtime.getRuntime().maxMemory() / 8L)
                .coerceIn(8L * 1024 * 1024, 64L * 1024 * 1024)
            return readPathFile(File(source.path), heapBudget)
        }
        return if (source.source == "apk") {
            val heapBudget = (Runtime.getRuntime().maxMemory() / 8L).coerceIn(8L * 1024 * 1024, 64L * 1024 * 1024)
            val declaredLimit = source.size.takeIf { it > 0 }?.plus(1L) ?: heapBudget
            val entry = source.apkEntry ?: error("Missing APK entry")
            // path 模式：apk: URI 指向本地 APK 文件（无 SAF document uri），直接 ZipFile 读取
            if (source.treeDocumentUri == null && source.apkPath != null) {
                val apkFile = File(source.apkPath!!)
                if (!apkFile.isFile) error("APK file not found: ${source.apkPath}")
                val maxBytes = minOf(declaredLimit, heapBudget)
                java.util.zip.ZipFile(apkFile).use { zip ->
                    val zipEntry = zip.getEntry(entry) ?: error("Entry not found in APK: $entry")
                    if (zipEntry.size > maxBytes) throw ApkAnalysisLimitException("APK entry exceeds $maxBytes byte limit")
                    zip.getInputStream(zipEntry).use { it.readBytes() }
                }
            } else {
                extractZipEntry(
                    source.treeDocumentUri ?: error("Missing APK document uri"),
                    entry,
                    minOf(declaredLimit, heapBudget),
                )
            }
        } else {
            readBytes(source.treeDocumentUri ?: error("Missing document uri"))
        }
    }

    fun readFile(relativePath: String, maxBytes: Long = Long.MAX_VALUE): ByteArray {
        if (isPathMode) {
            val f = File(rootPath, relativePath)
            if (!f.isFile) error("File not found in work directory: $relativePath")
            return readPathFile(f, maxBytes)
        }
        var found = documentUris[relativePath]
        if (found == null) {
            walk(treeUri!!, "", 0, ScanOptions(scanApks = true, scanSubdirectories = true, maxDepth = 32)) { uri, _, path, _, _ ->
                if (path == relativePath) found = uri
            }
        }
        return readBytes(found ?: error("File not found in work directory: $relativePath"), maxBytes)
    }

    fun writeRootFile(displayName: String, bytes: ByteArray, mimeType: String = "application/octet-stream"): SoSource {
        val safeName = displayName.substringAfterLast('/').substringAfterLast('\\').ifBlank { "downloaded.so" }
        if (isPathMode) {
            val dir = File(rootPath).apply { mkdirs() }
            val f = File(dir, safeName)
            f.writeBytes(bytes)
            return SoSource(f.absolutePath, "filesystem", safeName, bytes.size.toLong(), System.currentTimeMillis(), null)
        }
        val parent = documentUriForTree()
        val uri = DocumentsContract.createDocument(resolver, parent, mimeType, safeName)
            ?: error("Cannot create file in work directory parent=$parent tree=$treeUri")
        resolver.openOutputStream(uri, "wt").use { out ->
            requireNotNull(out) { "Cannot open output stream for $safeName" }
            out.write(bytes)
        }
        documentUris[safeName] = uri
        return SoSource(safeName, "filesystem", safeName, bytes.size.toLong(), System.currentTimeMillis(), uri)
    }

    /** 写入工作目录内任意相对路径（自动创建父目录）；返回相对路径。SAF 模式按需逐级建目录。 */
    fun writeFile(relativePath: String, bytes: ByteArray, mimeType: String = "application/octet-stream"): String {
        val parts = relativePath.split('/').map { it.trim() }.filter { it.isNotEmpty() && it != "." && it != ".." }
        require(parts.isNotEmpty()) { "Invalid relative path: $relativePath" }
        if (isPathMode) {
            val f = File(rootPath, parts.joinToString("/")).apply { parentFile?.mkdirs() }
            f.writeBytes(bytes)
            return f.relativeTo(File(rootPath)).path
        }
        var node = documentUriForTree()
        for (i in parts.indices) {
            val last = i == parts.lastIndex
            node = findChild(node, parts[i], last)
                ?: runCatching {
                    DocumentsContract.createDocument(resolver, node, if (last) mimeType else DocumentsContract.Document.MIME_TYPE_DIR, parts[i])
                }.getOrNull()
                ?: error("Cannot create '${parts[i]}' in work directory (parent=$node)")
        }
        resolver.openOutputStream(node, "wt").use { out ->
            requireNotNull(out) { "Cannot open output stream for $relativePath" }
            out.write(bytes)
        }
        val writtenPath = parts.joinToString("/")
        documentUris[writtenPath] = node
        return writtenPath
    }

    private fun findChild(dirUri: Uri, name: String, isFile: Boolean): Uri? {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, DocumentsContract.getDocumentId(dirUri))
        return resolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            ),
            null, null, null,
        )?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
            while (cursor.moveToNext()) {
                val mime = cursor.getString(mimeCol).orEmpty()
                val matchesType = if (isFile) mime != DocumentsContract.Document.MIME_TYPE_DIR else mime == DocumentsContract.Document.MIME_TYPE_DIR
                if (matchesType && cursor.getString(nameCol) == name) {
                    return DocumentsContract.buildDocumentUriUsingTree(treeUri, cursor.getString(idCol))
                }
            }
            null
        }
    }

    fun documentUriForTree(): Uri {
        if (isPathMode) return Uri.fromFile(File(rootPath))
        val treeDocumentId = runCatching { DocumentsContract.getTreeDocumentId(treeUri) }.getOrElse {
            error("Invalid work directory tree URI: $treeUri (${it.message})")
        }
        return DocumentsContract.buildDocumentUriUsingTree(treeUri, treeDocumentId)
    }

    fun isAccessible(): Boolean = runCatching {
        if (isPathMode) return File(rootPath).isDirectory
        val doc = documentUriForTree()
        resolver.query(doc, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)?.use { it.count >= 0 } == true
    }.getOrDefault(false)

    private fun listApkSos(apkPath: String, apkUri: Uri, modified: Long): List<SoSource> {
        val items = mutableListOf<SoSource>()
        resolver.openInputStream(apkUri).use { input ->
            requireNotNull(input) { "Cannot open $apkUri" }
            ZipInputStream(input).use { zis ->
                while (true) {
                    val entry = zis.nextEntry ?: break
                    if (!entry.isDirectory && entry.name.matches(Regex("^lib/[^/]+/[^/]+\\.so$"))) {
                        val abi = entry.name.split('/')[1]
                        items += SoSource(
                            path = "apk:$apkPath!${entry.name}",
                            source = "apk",
                            name = entry.name.substringAfterLast('/'),
                            size = entry.size.takeIf { it >= 0 } ?: 0L,
                            modified = modified,
                            treeDocumentUri = apkUri,
                            apkPath = apkPath,
                            apkEntry = entry.name,
                            abi = abi,
                        )
                    }
                    zis.closeEntry()
                }
            }
        }
        return items
    }

    private fun extractZipEntry(apkUri: Uri, entryName: String, maxBytes: Long): ByteArray {
        resolver.openInputStream(apkUri).use { input ->
            requireNotNull(input) { "Cannot open $apkUri" }
            ZipInputStream(input).use { zis ->
                while (true) {
                    val entry = zis.nextEntry ?: break
                    if (!entry.isDirectory && entry.name == entryName) {
                        if (entry.size > maxBytes) throw ApkAnalysisLimitException("APK entry exceeds $maxBytes byte heap budget")
                        val out = ByteArrayOutputStream(32 * 1024)
                        val buffer = ByteArray(64 * 1024)
                        var total = 0L
                        while (true) {
                            val count = zis.read(buffer)
                            if (count < 0) break
                            total += count
                            if (total > maxBytes) throw ApkAnalysisLimitException("APK entry exceeds $maxBytes byte limit")
                            out.write(buffer, 0, count)
                        }
                        return out.toByteArray()
                    }
                    zis.closeEntry()
                }
            }
        }
        error("Entry not found: $entryName")
    }

    private fun walk(dirUri: Uri, prefix: String, depth: Int, options: ScanOptions, onFile: (Uri, String, String, Long, Long) -> Unit) {
        val treeDocumentId = DocumentsContract.getTreeDocumentId(treeUri)
        val documentId = if (dirUri == treeUri) {
            treeDocumentId
        } else {
            DocumentsContract.getDocumentId(dirUri).ifEmpty { treeDocumentId }
        }
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, documentId)
        resolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val sizeCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE)
            val modifiedCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            while (cursor.moveToNext()) {
                val id = cursor.getString(idCol)
                val name = cursor.getString(nameCol) ?: continue
                val mime = cursor.getString(mimeCol).orEmpty()
                val size = if (cursor.isNull(sizeCol)) 0L else cursor.getLong(sizeCol)
                val modified = if (modifiedCol >= 0 && !cursor.isNull(modifiedCol)) cursor.getLong(modifiedCol) else 0L
                val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
                val rel = if (prefix.isBlank()) name else "$prefix/$name"
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    if (options.scanSubdirectories && depth < options.maxDepth) {
                        runCatching { walk(docUri, rel, depth + 1, options, onFile) }
                            .onFailure { AppLog.w("Failed to scan directory $rel: ${it.message}") }
                    }
                } else if (size <= options.skipFilesLargerThanBytes || name.endsWith(".so", ignoreCase = true)) {
                    documentUris[rel] = docUri
                    onFile(docUri, name, rel, size, modified)
                }
            }
        }
    }

    private fun readBytes(uri: Uri, maxBytes: Long = Long.MAX_VALUE): ByteArray {
        resolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "Cannot open $uri" }
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                total += count
                if (total > maxBytes) throw ApkAnalysisLimitException("Input exceeds $maxBytes byte limit")
                out.write(buffer, 0, count)
            }
            return out.toByteArray()
        }
    }

    private fun readPathFile(file: File, maxBytes: Long): ByteArray {
        if (file.length() > maxBytes) throw ApkAnalysisLimitException("Input exceeds $maxBytes byte limit")
        return file.inputStream().use { input ->
            val out = ByteArrayOutputStream(file.length().coerceAtMost(64L * 1024).toInt())
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                out.write(buffer, 0, count)
            }
            out.toByteArray()
        }
    }

    /** path 模式：递归扫描目录（.so / .apk）。 */
    private fun walkPath(
        dir: File,
        prefix: String,
        depth: Int,
        options: ScanOptions,
        onFile: (String, String, Long, Long) -> Unit,
    ) {
        if (depth > options.maxDepth) return
        val children = runCatching { dir.listFiles() }.getOrNull() ?: return
        for (child in children.sortedBy { it.name }) {
            val rel = if (prefix.isBlank()) child.name else "$prefix/${child.name}"
            if (child.isDirectory) {
                if (options.scanSubdirectories) walkPath(child, rel, depth + 1, options, onFile)
            } else if (child.length() <= options.skipFilesLargerThanBytes || child.name.endsWith(".so", ignoreCase = true)) {
                onFile(child.name, rel, child.length(), child.lastModified())
            }
        }
    }

    /** path 模式：从本地 APK 文件列出内部 SO 条目。 */
    private fun listApkSosFromFile(apkFile: File): List<SoSource> {
        val items = mutableListOf<SoSource>()
        runCatching {
            java.util.zip.ZipFile(apkFile).use { zip ->
                val entries = zip.entries()
                while (entries.hasMoreElements()) {
                    val entry = entries.nextElement()
                    if (!entry.isDirectory && entry.name.matches(Regex("^lib/[^/]+/[^/]+\\.so$"))) {
                        val abi = entry.name.split('/')[1]
                        items += SoSource(
                            path = "apk:${apkFile.absolutePath}!${entry.name}",
                            source = "apk",
                            name = entry.name.substringAfterLast('/'),
                            size = entry.size.takeIf { it >= 0 } ?: 0L,
                            modified = apkFile.lastModified(),
                            treeDocumentUri = null,
                            apkPath = apkFile.absolutePath,
                            apkEntry = entry.name,
                            abi = abi,
                        )
                    }
                }
            }
        }
        return items
    }

    companion object {
        fun displayPath(uri: Uri): String {
            val id = runCatching { DocumentsContract.getTreeDocumentId(uri) }.getOrNull().orEmpty()
            if (id.startsWith("primary:")) {
                val rel = id.substringAfter("primary:").trim('/')
                return if (rel.isBlank()) "/storage/emulated/0" else "/storage/emulated/0/$rel"
            }
            if (id.startsWith("home:")) {
                val rel = id.substringAfter("home:").trim('/')
                return if (rel.isBlank()) "/storage/emulated/0/Documents" else "/storage/emulated/0/Documents/$rel"
            }
            val volume = id.substringBefore(':', "")
            val rel = id.substringAfter(':', "").trim('/')
            if (volume.isNotBlank()) return if (rel.isBlank()) "/storage/$volume" else "/storage/$volume/$rel"
            return uri.toString()
        }
    }
}
