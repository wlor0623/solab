package zhou.solab.engine

import org.json.JSONObject
import java.util.UUID

internal class PageStore {
    companion object {
        private const val MAX_PENDING_CURSORS = 16
    }

    internal data class PageSlice(
        val field: String,
        val items: List<JSONObject>,
        val hasMore: Boolean,
        val nextCursor: String?,
        val returnedCount: Int,
        val limit: Int,
        val totalCount: Int,
    )

    private data class PageState(
        val field: String,
        val items: List<JSONObject>,
        val offset: Int,
        val limit: Int,
    )

    private val pages = LinkedHashMap<String, PageState>()

    @Synchronized
    fun first(field: String, items: List<JSONObject>, limit: Int, offset: Int = 0): PageSlice =
        slice(PageState(field, items, offset.coerceIn(0, items.size.coerceAtLeast(1)), limit.coerceIn(1, 5000)))

    @Synchronized
    fun consume(cursor: String): PageSlice? = pages.remove(cursor)?.let(::slice)

    @Synchronized
    fun clear() {
        pages.clear()
    }

    private fun slice(state: PageState): PageSlice {
        val chunk = state.items.drop(state.offset).take(state.limit)
        val nextOffset = state.offset + chunk.size
        val nextCursor = if (nextOffset < state.items.size) {
            "page:${UUID.randomUUID()}".also {
                pages[it] = state.copy(offset = nextOffset)
                while (pages.size > MAX_PENDING_CURSORS) {
                    pages.remove(pages.keys.first())
                }
            }
        } else {
            null
        }
        return PageSlice(state.field, chunk, nextCursor != null, nextCursor, chunk.size, state.limit, state.items.size)
    }
}
