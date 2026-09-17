package zhou.solab.engine

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import com.android.tools.smali.dexlib2.iface.ClassDef
import com.android.tools.smali.dexlib2.iface.Method
import com.android.tools.smali.dexlib2.iface.instruction.Instruction
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction
import com.android.tools.smali.dexlib2.iface.reference.FieldReference
import com.android.tools.smali.dexlib2.iface.reference.Reference
import org.jf.dexlib2.iface.reference.MethodReference
import zhou.solab.tools.DexIo
import zhou.solab.tools.DexXrefEngine
import java.io.File

/**
 * P0：字段引用预建索引（Analyzer 判定：Dart 假索引被否决，必须 Kotlin
 * 一次解析 → SQLite 预建 field_refs；READY 只绑真实建成）。
 *
 * 构建：analyze 完成后追加一遍单次解析，把全部 iget/iput/sget/sput 引用
 * 落库（事务内：清旧行 → 分批插入 → meta built=1；失败整体回滚，查询自动
 * 回退全量扫描，不影响分析成功）。
 *
 * 查询：field_xref 先查 meta（built=1 且 schema 匹配）→ 单条 SELECT 按
 * field_qid 或 field_owner 取行，SQL 保证写入方优先（WRITE_FIELD 先、
 * 其余按 seq 扫描序）——行格式与 DexXrefEngine 全量扫描完全同构
 * （\u0001 紧凑串），分页/响应构建直接复用，索引与扫描结果天然等价。
 *
 * 失效：键 = APK 内容 sha256（不依赖 mtime/size，避免指纹漂移）；
 * 新建索引后清理无 meta 的孤儿行（防表无限增长）。
 */
class FieldRefsIndexStore(context: Context) :
    SQLiteOpenHelper(context, "solab_field_refs.db", null, SCHEMA_VERSION) {

    // SQLiteOpenHelper 的 getContext() 在 Kotlin 里被折叠为 property，
    // 显式保留构造 Context（getContext()/context 两个名字都有歧义）。
    private val appContext: Context = context

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE field_refs (
                apk_sha256 TEXT NOT NULL,
                seq INTEGER NOT NULL,
                field_qid TEXT NOT NULL,
                field_owner TEXT NOT NULL,
                relation TEXT NOT NULL,
                access_kind TEXT NOT NULL,
                opcode TEXT NOT NULL,
                method_qid TEXT NOT NULL,
                insn_index INTEGER NOT NULL,
                dex_id INTEGER NOT NULL,
                dex_file TEXT NOT NULL
            )
            """.trimIndent(),
        )
        db.execSQL("CREATE INDEX idx_refs_qid ON field_refs(apk_sha256, field_qid)")
        db.execSQL("CREATE INDEX idx_refs_owner ON field_refs(apk_sha256, field_owner)")
        db.execSQL(
            """
            CREATE TABLE index_meta (
                apk_sha256 TEXT PRIMARY KEY,
                built INTEGER NOT NULL,
                schema_version INTEGER NOT NULL,
                dex_count INTEGER NOT NULL,
                scanned_methods INTEGER NOT NULL,
                reference_instructions INTEGER NOT NULL,
                field_references INTEGER NOT NULL,
                built_at_ms INTEGER NOT NULL
            )
            """.trimIndent(),
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        db.execSQL("DROP TABLE IF EXISTS field_refs")
        db.execSQL("DROP TABLE IF EXISTS index_meta")
        onCreate(db)
    }

    /** 一次解析构建索引；返回是否成功落库（meta built=1）。 */
    fun build(apk: File, apkSha256: String): Boolean {
        if (apkSha256.isBlank() || !apk.isFile) return false
        val db = writableDatabase
        var seq = 0L
        var dexCount = 0
        var scannedMethods = 0
        var referenceInstructions = 0
        var fieldReferences = 0
        val batch = ArrayList<android.content.ContentValues>(500)
        var failed = false
        db.beginTransaction()
        try {
            db.delete("field_refs", "apk_sha256=?", arrayOf(apkSha256))
            DexIo.eachDex(appContext, apk) { dexName, dexFile ->
                dexCount++
                for (cls: ClassDef in dexFile.classes) {
                    for (m: Method in cls.methods) {
                        val impl = m.implementation ?: continue
                        scannedMethods++
                        var insnIdx = 0
                        for (insn: Instruction in impl.instructions) {
                            if (insn !is ReferenceInstruction) { insnIdx++; continue }
                            referenceInstructions++
                            val ref: Reference = insn.reference
                            if (ref !is FieldReference) { insnIdx++; continue }
                            fieldReferences++
                            val values = android.content.ContentValues().apply {
                                put("apk_sha256", apkSha256)
                                put("seq", seq++)
                                put("field_qid", "${ref.definingClass}->${ref.name}:${ref.type}")
                                put("field_owner", "${ref.definingClass}->${ref.name}")
                                put("relation", DexXrefEngine.fieldRelation(insn.opcode.name))
                                put("access_kind", DexXrefEngine.fieldAccessKind(insn.opcode.name))
                                put("opcode", insn.opcode.name)
                                put(
                                    "method_qid",
                                    "${m.definingClass}->${m.name}(${m.parameterTypes.joinToString("")})${m.returnType}",
                                )
                                put("insn_index", insnIdx)
                                put("dex_id", dexCount - 1)
                                put("dex_file", dexName)
                            }
                            batch.add(values)
                            if (batch.size >= 500) {
                                flushBatch(db, batch)
                            }
                            insnIdx++
                        }
                    }
                }
            }
            flushBatch(db, batch)
            db.insertWithOnConflict(
                "index_meta",
                null,
                android.content.ContentValues().apply {
                    put("apk_sha256", apkSha256)
                    put("built", 1)
                    put("schema_version", SCHEMA_VERSION)
                    put("dex_count", dexCount)
                    put("scanned_methods", scannedMethods)
                    put("reference_instructions", referenceInstructions)
                    put("field_references", fieldReferences)
                    put("built_at_ms", System.currentTimeMillis())
                },
                SQLiteDatabase.CONFLICT_REPLACE,
            )
            db.setTransactionSuccessful()
        } catch (error: Exception) {
            failed = true
        } finally {
            db.endTransaction()
        }
        if (!failed) {
            // 保留窗口：只保留最近 RETAIN_SHAS 个包的索引，防止换包分析时
            // DB 无限膨胀（每个大包的 refs 可达几十上百 MB）。被挤出窗口的
            // 包下次 field_xref 会自动走扫描回退并重建索引；VACUUM 归还磁盘。
            runCatching {
                db.execSQL(
                    "DELETE FROM index_meta WHERE apk_sha256 NOT IN (" +
                        "SELECT apk_sha256 FROM index_meta ORDER BY built_at_ms DESC LIMIT $RETAIN_SHAS)",
                )
                db.execSQL(
                    "DELETE FROM field_refs WHERE apk_sha256 NOT IN (SELECT apk_sha256 FROM index_meta)",
                )
                db.execSQL("VACUUM")
            }
        }
        return !failed
    }

    /** 惰性触发：READY 门未建成时后台构建（不阻塞调用方查询）。
     *  幂等：已建成或已在构建中则直接返回。构建期间查询走全量扫描回退，
     *  完成后自动切换 SELECT——零等待、零劣化。 */
    fun triggerBuild(apk: File, apkSha256: String) {
        if (apkSha256.isBlank() || isReady(apkSha256)) return
        synchronized(inFlight) {
            if (apkSha256 in inFlight) return
            inFlight.add(apkSha256)
        }
        builderExecutor.execute {
            try {
                build(apk, apkSha256)
            } finally {
                inFlight.remove(apkSha256)
            }
        }
    }

    private fun flushBatch(db: SQLiteDatabase, batch: ArrayList<android.content.ContentValues>) {
        if (batch.isEmpty()) return
        for (values in batch) db.insert("field_refs", null, values)
        batch.clear()
    }

    /** READY 门：真实建成（built=1 + schema 匹配）才算可用。 */
    fun isReady(apkSha256: String): Boolean {
        if (apkSha256.isBlank()) return false
        readableDatabase.rawQuery(
            "SELECT built, schema_version FROM index_meta WHERE apk_sha256=?",
            arrayOf(apkSha256),
        ).use { cursor ->
            if (!cursor.moveToFirst()) return false
            return cursor.getInt(0) == 1 && cursor.getInt(1) == SCHEMA_VERSION
        }
    }

    /** 索引命中信息（构建期统计，供响应 summary 与扫描模式保形）。 */
    data class IndexMeta(
        val dexCount: Int,
        val scannedMethods: Int,
        val referenceInstructions: Int,
        val fieldReferences: Int,
    )

    fun metaOf(apkSha256: String): IndexMeta? {
        readableDatabase.rawQuery(
            "SELECT dex_count, scanned_methods, reference_instructions, field_references FROM index_meta WHERE apk_sha256=?",
            arrayOf(apkSha256),
        ).use { cursor ->
            if (!cursor.moveToFirst()) return null
            return IndexMeta(
                cursor.getInt(0),
                cursor.getInt(1),
                cursor.getInt(2),
                cursor.getInt(3),
            )
        }
    }

    /**
     * 查询字段引用：写入方优先（WRITE_FIELD 先），其余按构建扫描序。
     * 返回与 DexXrefEngine 全量扫描完全同构的紧凑行（\u0001 分隔），
     * 调用方直接走既有 fieldPage/fieldRowJson，索引/扫描结果天然等价。
     */
    fun fieldRows(
        apkSha256: String,
        fieldQid: String,
        fieldOwner: String,
    ): List<String> {
        val out = ArrayList<String>()
        readableDatabase.query(
            "field_refs",
            arrayOf(
                "field_qid", "method_qid", "relation", "access_kind",
                "opcode", "insn_index", "dex_id", "dex_file",
            ),
            "apk_sha256=? AND (field_qid=? OR field_owner=?)",
            arrayOf(apkSha256, fieldQid, fieldOwner),
            null,
            null,
            "CASE WHEN relation='WRITE_FIELD' THEN 0 ELSE 1 END, seq",
        ).use { cursor ->
            while (cursor.moveToNext()) {
                out += DexXrefEngine.fieldRefRow(
                    fieldQid = cursor.getString(0),
                    methodQid = cursor.getString(1),
                    relation = cursor.getString(2),
                    accessKind = cursor.getString(3),
                    opcode = cursor.getString(4),
                    insnIndex = cursor.getInt(5),
                    dexId = cursor.getInt(6),
                    dexFile = cursor.getString(7),
                )
            }
        }
        return out
    }

    companion object {
        private const val SCHEMA_VERSION = 1

        /** 索引保留窗口：最近 N 个包（超出自动清除并 VACUUM 归还磁盘）。 */
        private const val RETAIN_SHAS = 2

        // 单线程构建队列：一次只建一个包；daemon 线程不阻碍退出。
        private val builderExecutor = java.util.concurrent.Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "solab-fields-index-builder").apply { isDaemon = true }
        }
        private val inFlight = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

        @Volatile
        private var instance: FieldRefsIndexStore? = null

        /** 进程级单例（SQLiteOpenHelper 线程安全；构建经单线程队列串行化）。 */
        fun of(context: Context): FieldRefsIndexStore =
            instance ?: synchronized(this) {
                instance ?: FieldRefsIndexStore(context.applicationContext).also { instance = it }
            }
    }
}