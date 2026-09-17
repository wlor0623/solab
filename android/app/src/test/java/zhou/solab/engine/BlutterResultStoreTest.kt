package zhou.solab.engine

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class BlutterResultStoreTest {

    @Test
    fun objectInventoryPagesDirectlyFromRawObjsWithoutDuplicateJsonl() {
        val root = Files.createTempDirectory("blutter-objects-").toFile()
        try {
            val store = BlutterResultStore(root, true)
            val key = "a".repeat(64)
            val job = "blutter-object-page"
            val jobDir = File(root, "jobs/$job").apply { mkdirs() }
            File(jobDir, "state.json").writeText(JSONObject()
                .put("jobId", job)
                .put("status", "succeeded")
                .put("resultKey", key)
                .toString())
            val resultDir = File(root, "results/$key").apply { mkdirs() }
            File(resultDir, "result.json").writeText(JSONObject()
                .put("status", "succeeded")
                .put("summary", JSONObject().put("counts", JSONObject().put("objects", 3)))
                .toString())
            File(resultDir, "objs.txt").writeText("first\nsecond\nthird\n")

            val page = store.result(job, "objects", null, 2)!!
                .getJSONObject("objects")

            assertEquals(3, page.getInt("total"))
            assertTrue(page.getBoolean("hasMore"))
            assertEquals("first", page.getJSONArray("items").getJSONObject(0).getString("name"))
            assertFalse(File(resultDir, "objects.jsonl").exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun analysisCacheOptionsIgnoreSchedulingAndQueryArguments() {
        val first = JSONObject()
            .put("action", "analyze")
            .put("path", "/storage/emulated/0/Ai/first.apk")
            .put("wait", true)
            .put("timeoutMs", 90000)
            .put("goal", "定位会员")
        val second = JSONObject()
            .put("action", "analyze")
            .put("path", "/storage/emulated/0/Ai/renamed.apk")
            .put("wait", false)
            .put("timeoutMs", 5000)
            .put("goal", "定位广告")

        assertEquals(
            BlutterResultStore.analysisCacheOptions(first),
            BlutterResultStore.analysisCacheOptions(second),
        )
        assertFalse(
            BlutterResultStore.analysisCacheOptions(first) ==
                BlutterResultStore.analysisCacheOptions(JSONObject(second.toString()).put("abi", "armeabi-v7a")),
        )
    }

    @Test
    fun reapOrphanJobsInterruptsOnlyStaleJobsAndDeletesTheirInputs() {
        val noBackupDir = Files.createTempDirectory("blutter-store-").toFile()
        try {
            val root = File(noBackupDir, "blutter/v1")
            val store = BlutterResultStore(root, true)
            val jobsDir = File(root, "jobs")
            val stale = File(jobsDir, "blutter-stale-job").apply { mkdirs() }
            val fresh = File(jobsDir, "blutter-fresh-job").apply { mkdirs() }
            writeState(stale, "running", System.currentTimeMillis() - 10 * 60 * 1000L)
            writeState(fresh, "queued", System.currentTimeMillis())
            File(stale, "input/libapp.so").apply { parentFile!!.mkdirs(); writeText("old") }
            File(fresh, "input/libapp.so").apply { parentFile!!.mkdirs(); writeText("new") }

            store.reapOrphanJobs()

            assertEquals("interrupted", JSONObject(File(stale, "state.json").readText()).getString("status"))
            assertFalse(File(stale, "input").exists())
            assertEquals("queued", JSONObject(File(fresh, "state.json").readText()).getString("status"))
            assertTrue(File(fresh, "input/libapp.so").isFile)
        } finally {
            noBackupDir.deleteRecursively()
        }
    }

    @Test
    fun prunePreviewReportsBytesWithoutDeletingThenPruneReclaimsThem() {
        val root = Files.createTempDirectory("blutter-prune-").toFile()
        try {
            val store = BlutterResultStore(root, true)
            val key = "b".repeat(64)
            val job = File(root, "jobs/blutter-old-result-job").apply { mkdirs() }
            val old = System.currentTimeMillis() - 10_000
            File(job, "state.json").writeText(JSONObject()
                .put("jobId", job.name)
                .put("status", "succeeded")
                .put("updatedAt", old)
                .put("resultKey", key)
                .toString())
            File(job, "input.bin").writeBytes(ByteArray(11))
            val result = File(root, "results/$key").apply { mkdirs() }
            File(result, "result.json").writeBytes(ByteArray(17))
            result.setLastModified(old)

            val preview = store.prunePreview(1_000)
            assertTrue(preview.getBoolean("dryRun"))
            assertEquals(1, preview.getInt("candidateJobs"))
            assertEquals(1, preview.getInt("candidateResults"))
            assertTrue(preview.getLong("freedBytes") >= 28)
            assertTrue(job.exists())
            assertTrue(result.exists())

            val pruned = store.prune(1_000)
            assertFalse(pruned.getBoolean("dryRun"))
            assertEquals(1, pruned.getInt("removedJobs"))
            assertEquals(1, pruned.getInt("removedResults"))
            assertFalse(job.exists())
            assertFalse(result.exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun runningStatusIncludesHeartbeatStageAndArtifactGrowth() {
        val root = Files.createTempDirectory("blutter-progress-").toFile()
        try {
            val store = BlutterResultStore(root, true)
            val jobId = store.create(JSONObject().put("action", "analyze"))

            store.progress(jobId, "writing_indexes", "正在生成反汇编", 4096, 12)
            val state = store.get(jobId)!!

            assertEquals("running", state.getString("status"))
            assertEquals("生成对象池与反汇编", state.getString("stageLabel"))
            assertEquals("正在生成反汇编", state.getString("progressMessage"))
            assertEquals(4096, state.getLong("outputBytes"))
            assertEquals(12, state.getInt("outputFiles"))
            assertTrue(state.getLong("elapsedMillis") >= 0)
            assertTrue(state.getLong("heartbeatAgeMillis") >= 0)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun identicalRunningAnalysisReusesExistingJob() {
        val root = Files.createTempDirectory("blutter-dedupe-").toFile()
        try {
            val store = BlutterResultStore(root, true)
            val first = store.create(JSONObject().put("path", "same.apk"))
            val second = store.create(JSONObject().put("path", "same.apk"))

            assertEquals(null, store.claimAnalysisKey(first, "same-key"))
            assertEquals(first, store.claimAnalysisKey(second, "same-key"))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun cacheHitReturnsCompactSummaryInsteadOfFullInventories() {
        val root = Files.createTempDirectory("blutter-cache-").toFile()
        try {
            val store = BlutterResultStore(root, true)
            val jobId = store.create(JSONObject().put("path", "same.apk"))
            val key = "c".repeat(64)
            val resultDir = File(root, "results/$key").apply { mkdirs() }
            File(resultDir, "result.json").writeText(JSONObject()
                .put("status", "succeeded")
                .put("backend", "exec")
                .put("summary", JSONObject().put("counts", JSONObject().put("functions", 100)))
                .put("functions", JSONObject().put("items", org.json.JSONArray().put("large inventory")))
                .toString())

            val reused = store.reuse(jobId, key)!!

            assertTrue(reused.getBoolean("cacheHit"))
            assertEquals(100, reused.getJSONObject("summary").getJSONObject("counts").getInt("functions"))
            assertFalse(reused.has("functions"))
            assertEquals("cache_hit", store.get(jobId)!!.getString("stage"))
        } finally {
            root.deleteRecursively()
        }
    }

    private fun writeState(dir: File, status: String, updatedAt: Long) {
        File(dir, "state.json").writeText(
            JSONObject()
                .put("jobId", dir.name)
                .put("status", status)
                .put("updatedAt", updatedAt)
                .toString(),
        )
    }
}
