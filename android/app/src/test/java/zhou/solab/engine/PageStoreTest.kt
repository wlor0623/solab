package zhou.solab.engine

import org.json.JSONObject
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class PageStoreTest {
    @Test
    fun pendingCursorsAreBounded() {
        val store = PageStore()
        val rows = listOf(JSONObject(), JSONObject())
        val cursors = (0 until 17).map {
            store.first("rows", rows, 1).nextCursor!!
        }

        assertNull(store.consume(cursors.first()))
        assertNotNull(store.consume(cursors.last()))
    }
}
