package zhou.solab

import java.io.File
import java.security.MessageDigest

/**
 * SolabChannel 与 ApkModuleAnalyzer 共用的纯 JVM 工具函数。
 * 此前两处各自私有复制（ApkModuleAnalyzer 曾注释"与 SolabChannel 同源，
 * 独立维护"）——同一实现两份维护必会漂移，统一收敛到这里。
 * 保持 top-level internal：同包内直接调用，不引入新依赖。
 */

/** 有界 top-N 维护：超过 [cap] 条时淘汰最小值，只保留最大的 N 条。 */
internal fun offerLargest(
    list: MutableList<Map<String, Any>>,
    item: Map<String, Any>,
    cap: Int = 20,
) {
    if (list.size < cap) {
        list += item
        return
    }
    var minIndex = 0
    var minSize = list[0]["size"] as Long
    for (index in 1 until list.size) {
        val size = list[index]["size"] as Long
        if (size < minSize) {
            minSize = size
            minIndex = index
        }
    }
    if ((item["size"] as Long) > minSize) list[minIndex] = item
}

/** 证书指纹（支持 P 及以上的 signingInfo，兼容旧 signatures）。 */
internal fun signingCertificateSha256(packageInfo: android.content.pm.PackageInfo?): String {
    if (packageInfo == null) return ""
    val bytes = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
        packageInfo.signingInfo?.apkContentsSigners?.firstOrNull()?.toByteArray()
    } else {
        @Suppress("DEPRECATION")
        packageInfo.signatures?.firstOrNull()?.toByteArray()
    } ?: return ""
    return sha256(bytes)
}

internal fun sha256(file: File): String = MessageDigest.getInstance("SHA-256").let { digest ->
    file.inputStream().use { input ->
        val buffer = ByteArray(8192)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            digest.update(buffer, 0, read)
        }
    }
    digest.digest().toHex()
}

internal fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
    .digest(bytes)
    .toHex()

internal fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }