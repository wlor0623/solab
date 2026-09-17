package com.soreverse.mcp.engine

import android.content.Context

class XAnSoEngine(context: Context) {
    private val cacheDir = context.cacheDir.absolutePath
    private val loaded = runCatching { System.loadLibrary("xanso_native") }.isSuccess

    fun available(): Boolean = loaded && runCatching { nativeAvailable() }.getOrDefault(false)

    fun buildSections(data: ByteArray): ByteArray? =
        if (!available()) null else runCatching { nativeBuildSections(data, cacheDir) }.getOrNull()

    fun recoverElf64Sections(data: ByteArray): ByteArray? =
        if (!available()) null else runCatching { nativeRecoverElf64Sections(data) }.getOrNull()

    private external fun nativeBuildSections(data: ByteArray, cacheDir: String): ByteArray?
    private external fun nativeRecoverElf64Sections(data: ByteArray): ByteArray?
    private external fun nativeAvailable(): Boolean
}
