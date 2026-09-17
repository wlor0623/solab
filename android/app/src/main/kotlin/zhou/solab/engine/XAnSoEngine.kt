package zhou.solab.engine

import android.content.Context

class XAnSoEngine(context: Context) {
    private val delegate = com.soreverse.mcp.engine.XAnSoEngine(context)

    fun available(): Boolean = delegate.available()

    fun buildSections(data: ByteArray): ByteArray? {
        if (!available()) return null
        if (data.size < 5 || data[4].toInt() != 1) return null
        return delegate.buildSections(data)
    }

    fun recoverElf64Sections(data: ByteArray): ByteArray? {
        if (!available() || data.size < 5 || data[4].toInt() != 2) return null
        return delegate.recoverElf64Sections(data)
    }
}
