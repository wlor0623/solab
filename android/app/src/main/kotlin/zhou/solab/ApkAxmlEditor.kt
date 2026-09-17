package zhou.solab

import java.io.ByteArrayOutputStream

/**
 * 二进制 AXML 编辑引擎（B6/B7）。
 * 移植自参考项目 AxmlEditor.kt：纯字节 chunk 级手术，无文本处理、无 aapt。
 * 规则：本文件注释一律使用单行 //（避免 Kotlin 嵌套注释陷阱）。
 */
internal object ApkAxmlEditor {

    // AXML chunk 类型
    private const val CHUNK_STRING_POOL = 0x0001
    private const val CHUNK_RES_XML = 0x0003
    private const val CHUNK_START_ELEMENT = 0x0102
    private const val CHUNK_END_ELEMENT = 0x0103
    private const val CHUNK_CDATA = 0x0104

    private const val FLAG_UTF8 = 0x100
    private const val TYPE_STRING = 0x03
    private const val TYPE_INT_DEC = 0x10
    private const val TYPE_INT_HEX = 0x11
    private const val TYPE_INT_BOOLEAN = 0x12
    private const val NO_INDEX = 0xFFFFFFFF.toInt()

    // 需要按组件类型筛选的 Manifest 声明
    private val COMPONENT_TAGS = setOf(
        "activity", "activity-alias", "service", "receiver", "provider"
    )

    data class AttributeInfo(
        val value: String?,
        val dataType: Int,
        val data: Int,
    ) {
        fun intValue(): Long? = when (dataType) {
            TYPE_INT_DEC, TYPE_INT_HEX -> data.toLong() and 0xffffffffL
            else -> value?.toLongOrNull()
        }

        fun booleanValue(): Boolean? = when (dataType) {
            TYPE_INT_BOOLEAN -> data != 0
            else -> when (value?.lowercase()) {
                "true", "1" -> true
                "false", "0" -> false
                else -> null
            }
        }
    }

    data class ElementInfo(
        val tag: String,
        val androidName: String?,
        val offset: Int,
        val size: Int,
        val androidValue: String? = null,
        val attributes: Map<String, AttributeInfo> = emptyMap(),
    ) {
        val androidNameLower: String get() = androidName?.lowercase() ?: ""
    }

    data class ComponentInfo(
        val tag: String,
        val name: String,
        val exported: Boolean? = null,
    )

    // meta-data 条目：name 为 SDK 配置键（如 com.qq.e.comm.AppId），value 为配置值
    data class MetaDataInfo(
        val name: String,
        val value: String?,
    )

    data class ManifestSummary(
        val packageName: String?,
        val versionName: String?,
        val versionCode: Long?,
        val minSdk: Int?,
        val targetSdk: Int?,
        val appLabel: String?,
        val debuggable: Boolean?,
        val allowBackup: Boolean?,
        val permissions: List<String>,
        val components: List<ComponentInfo>,
        val metaData: List<MetaDataInfo>,
    )

    fun readManifestSummary(bytes: ByteArray): ManifestSummary {
        var packageName: String? = null
        var versionName: String? = null
        var versionCode: Long? = null
        var minSdk: Int? = null
        var targetSdk: Int? = null
        var appLabel: String? = null
        var debuggable: Boolean? = null
        var allowBackup: Boolean? = null
        val permissions = mutableListOf<String>()
        val components = mutableListOf<ComponentInfo>()
        val metaData = mutableListOf<MetaDataInfo>()
        parseElements(bytes) { elem ->
            when (elem.tag) {
                "manifest" -> {
                    packageName = elem.attributes["package"]?.value
                    versionName = elem.attributes["versionName"]?.value
                    versionCode = elem.attributes["versionCode"]?.intValue()
                }
                "uses-sdk" -> {
                    minSdk = elem.attributes["minSdkVersion"]?.intValue()?.toInt()
                    targetSdk = elem.attributes["targetSdkVersion"]?.intValue()?.toInt()
                }
                "application" -> {
                    appLabel = elem.attributes["label"]?.value
                    debuggable = elem.attributes["debuggable"]?.booleanValue()
                    allowBackup = elem.attributes["allowBackup"]?.booleanValue()
                }
                "uses-permission", "uses-permission-sdk-23" -> {
                    elem.androidName?.let(permissions::add)
                }
                in COMPONENT_TAGS -> {
                    elem.androidName?.let {
                        components += ComponentInfo(
                            tag = elem.tag,
                            name = it,
                            exported = elem.attributes["exported"]?.booleanValue(),
                        )
                    }
                }
                "meta-data" -> {
                    elem.androidName?.let {
                        metaData += MetaDataInfo(it, elem.androidValue)
                    }
                }
            }
        }
        return ManifestSummary(
            packageName = packageName,
            versionName = versionName,
            versionCode = versionCode,
            minSdk = minSdk,
            targetSdk = targetSdk,
            appLabel = appLabel,
            debuggable = debuggable,
            allowBackup = allowBackup,
            permissions = permissions.distinct(),
            components = components,
            metaData = metaData,
        )
    }

    /** 列出全部 uses-permission 权限名。 */
    fun listPermissions(bytes: ByteArray): List<String> {
        val result = mutableListOf<String>()
        parseElements(bytes) { elem ->
            if (elem.tag == "uses-permission") {
                elem.androidName?.let { result.add(it) }
            }
        }
        return result
    }

    /** 列出全部组件（activity/activity-alias/service/receiver/provider）。 */
    fun listComponents(bytes: ByteArray): List<ComponentInfo> {
        val result = mutableListOf<ComponentInfo>()
        parseElements(bytes) { elem ->
            val androidName = elem.androidName
            if (elem.tag in COMPONENT_TAGS && androidName != null) {
                result.add(
                    ComponentInfo(
                        elem.tag,
                        androidName,
                        elem.attributes["exported"]?.booleanValue(),
                    )
                )
            }
        }
        return result
    }

    /** 列出全部 meta-data 条目（name=SDK 配置键，value=配置值）。 */
    fun listMetaData(bytes: ByteArray): List<MetaDataInfo> {
        val result = mutableListOf<MetaDataInfo>()
        parseElements(bytes) { elem ->
            val androidName = elem.androidName
            if (elem.tag == "meta-data" && !androidName.isNullOrEmpty()) {
                result.add(MetaDataInfo(androidName, elem.androidValue))
            }
        }
        return result
    }

    /** 按精确权限名移除 uses-permission 声明。 */
    fun removePermissions(bytes: ByteArray, permissionsToRemove: Set<String>): ByteArray {
        if (permissionsToRemove.isEmpty()) return bytes
        val targets = permissionsToRemove.map { it.lowercase() }.toSet()
        return filterElements(bytes) { elem ->
            elem.tag == "uses-permission" && elem.androidNameLower in targets
        }
    }

    /** 按精确组件名移除组件声明（含其内部子元素）。 */
    fun removeComponents(bytes: ByteArray, componentNames: Set<String>): ByteArray {
        if (componentNames.isEmpty()) return bytes
        val targets = componentNames.map { it.lowercase() }.toSet()
        return filterElements(bytes) { elem ->
            elem.tag in COMPONENT_TAGS && elem.androidNameLower in targets
        }
    }

    /** 按精确配置键移除 meta-data 声明（广告 SDK 配置项，删除后 SDK 初始化失败即不加载广告）。 */
    fun removeMetaData(bytes: ByteArray, names: Set<String>): ByteArray {
        if (names.isEmpty()) return bytes
        val targets = names.map { it.lowercase() }.toSet()
        return filterElements(bytes) { elem ->
            elem.tag == "meta-data" && elem.androidNameLower in targets
        }
    }

    /** 按 SDK 包名前缀 + 关键词移除广告组件；被移除的组件追加到 removed。 */
    fun removeAdComponents(
        bytes: ByteArray,
        sdkPackages: List<String>,
        adComponents: List<String>,
        removed: MutableList<ComponentInfo> = mutableListOf(),
    ): ByteArray {
        if (sdkPackages.isEmpty() && adComponents.isEmpty()) return bytes

        return filterElements(bytes) { elem ->
            val androidName = elem.androidName
            if (elem.tag !in COMPONENT_TAGS || androidName == null) return@filterElements false

            val isAd = isAdComponentName(androidName, sdkPackages, adComponents)
            if (isAd) {
                removed.add(ComponentInfo(elem.tag, androidName))
            }
            isAd
        }
    }

    /** A1：业务上下文排除词（组件类名/包名含这些词时不判为广告组件，防误删
     * 开机自启/网络相关业务 receiver，如 VPN/代理/隧道类应用的 BootReceiver）。 */
    private val BUSINESS_EXCLUDE_WORDS = listOf(
        "vpn", "openvpn", "ics", "wireguard", "trojan", "ssr", "shadowsocks",
        "proxy", "tunnel", "socks", "httpdns", "dnsproxy",
    )

    /** A1：组件是否含业务上下文特征词（供 dryRun 标黄提示，不参与广告判定）。 */
    internal fun isBusinessExcludedComponent(name: String): Boolean {
        val lower = name.trim().lowercase()
        return lower.isNotEmpty() && BUSINESS_EXCLUDE_WORDS.any { lower.contains(it) }
    }

    internal fun isAdComponentName(
        name: String,
        sdkPackages: List<String>,
        adComponents: List<String>,
    ): Boolean {
        val lower = name.trim().lowercase()
        if (lower.isEmpty()) return false
        // A1：业务上下文排除——含 VPN/代理/隧道等业务特征词的组件不判为广告
        if (BUSINESS_EXCLUDE_WORDS.any { lower.contains(it) }) return false

        val dot = lower.lastIndexOf('.')
        val simpleName = if (dot >= 0 && dot < lower.length - 1) lower.substring(dot + 1) else lower
        val pkg = if (dot > 0) lower.substring(0, dot) else lower

        // 规则1：包名命中 SDK 包前缀（pkg == sdk 或 pkg 以 sdk. 开头）则整包组件删除
        val sdkPrefixes = sdkPackages
            .map { it.trim().lowercase().removeSuffix(".") }
            .filter { p -> p.isNotEmpty() && !p.startsWith(".") && !p.endsWith(".") && p.contains('.') }
        for (sdk in sdkPrefixes) {
            if (pkg == sdk) return true
            if (pkg.startsWith("$sdk.")) return true
        }

        // 规则2：simpleName 与关键词完全相等或以关键词结尾（关键词长度 >= 4 防误删）
        val keywords = adComponents
            .map { it.trim().lowercase() }
            .filter { it.length >= 4 }
            .toSet()
        for (kw in keywords) {
            if (simpleName == kw) return true
            if (simpleName.length > kw.length && simpleName.endsWith(kw)) return true
        }
        return false
    }

    /**
     * 核心：按谓词过滤元素。删除某 START_ELEMENT 时其内部所有子元素连带丢弃
     * （dropStack 父子链保证闭合配对）。字符串池原样保留不重建。
     * 有删除时重写文件头 fileSize 字段（bytes[4..7]），否则原样返回。
     */
    fun filterElements(
        bytes: ByteArray,
        predicate: (ElementInfo) -> Boolean,
    ): ByteArray {
        if (!isAxml(bytes)) return bytes

        val pool = locateStringPool(bytes)
        val out = ByteArrayOutputStream(bytes.size)
        val dropStack = ArrayDeque<Boolean>()
        var offset = 0
        val length = bytes.size
        var removedCount = 0

        // 复制 RES_XML 文件头（前 headerSize 字节）
        if (length >= 8) {
            val headerType = u16(bytes, 0)
            val headerSize = u16(bytes, 2)
            if (headerType == CHUNK_RES_XML) {
                val copyLen = minOf(headerSize, length)
                out.write(bytes, 0, copyLen)
                offset = copyLen
            }
        }

        while (offset < length) {
            if (length - offset < 8) {
                out.write(bytes, offset, length - offset)
                break
            }
            val type = u16(bytes, offset)
            val chunkSize = u32(bytes, offset + 4)
            if (chunkSize < 8 || offset + chunkSize > length) {
                // 损坏兜底：透传剩余字节
                out.write(bytes, offset, length - offset)
                break
            }

            when (type) {
                CHUNK_START_ELEMENT -> {
                    val elem = parseStartElement(bytes, offset, chunkSize, pool.strings)
                    val parentDrop = dropStack.lastOrNull() == true
                    val drop = if (parentDrop) true else {
                        try {
                            predicate(elem)
                        } catch (_: Exception) {
                            false
                        }
                    }
                    if (drop) removedCount++
                    dropStack.add(drop)
                    if (!drop) out.write(bytes, offset, chunkSize)
                }

                CHUNK_END_ELEMENT -> {
                    val drop = dropStack.removeLastOrNull() ?: false
                    if (!drop) out.write(bytes, offset, chunkSize)
                }

                CHUNK_CDATA -> {
                    if (dropStack.lastOrNull() != true) out.write(bytes, offset, chunkSize)
                }

                else -> {
                    if (dropStack.lastOrNull() != true) out.write(bytes, offset, chunkSize)
                }
            }
            offset += chunkSize
        }

        return if (removedCount > 0) {
            val result = out.toByteArray()
            // 重写 RES_XML 文件头 fileSize 字段为新的总长
            if (result.size >= 8 && u16(result, 0) == CHUNK_RES_XML) {
                val total = result.size
                result[4] = (total and 0xFF).toByte()
                result[5] = ((total shr 8) and 0xFF).toByte()
                result[6] = ((total shr 16) and 0xFF).toByte()
                result[7] = ((total shr 24) and 0xFF).toByte()
            }
            result
        } else {
            bytes
        }
    }

    private fun parseElements(bytes: ByteArray, visitor: (ElementInfo) -> Unit) {
        if (!isAxml(bytes)) return
        val pool = locateStringPool(bytes)
        var offset = 0
        val length = bytes.size

        if (length >= 8 && u16(bytes, 0) == CHUNK_RES_XML) {
            offset = minOf(u16(bytes, 2), length)
        }

        while (offset < length) {
            if (length - offset < 8) break
            val type = u16(bytes, offset)
            val chunkSize = u32(bytes, offset + 4)
            if (chunkSize < 8 || offset + chunkSize > length) break

            if (type == CHUNK_START_ELEMENT) {
                try {
                    val elem = parseStartElement(bytes, offset, chunkSize, pool.strings)
                    visitor(elem)
                } catch (_: Exception) {
                    // 单个元素解析失败不影响其余
                }
            }
            offset += chunkSize
        }
    }

    private data class StringPool(
        val strings: MutableList<String>,
        @Suppress("unused") val isUtf8: Boolean,
        @Suppress("unused") val poolOffset: Int,
    ) {
        companion object {
            val EMPTY = StringPool(mutableListOf(), false, -1)
        }
    }

    private fun locateStringPool(bytes: ByteArray): StringPool {
        if (!isAxml(bytes)) {
            return StringPool.EMPTY
        }
        val poolOffset = u16(bytes, 2) // RES_XML 头里 headerSize，通常字符串池紧随其后
        if (poolOffset + 8 > bytes.size) {
            return StringPool.EMPTY
        }
        val type = u16(bytes, poolOffset)
        if (type != CHUNK_STRING_POOL) {
            return StringPool.EMPTY
        }
        val poolSize = u32(bytes, poolOffset + 4)
        if (poolSize < 8 || poolOffset + poolSize > bytes.size) {
            return StringPool.EMPTY
        }
        return parseStringPool(bytes, poolOffset, poolSize)
    }

    private fun parseStringPool(bytes: ByteArray, offset: Int, size: Int): StringPool {
        val stringCount = u32(bytes, offset + 8)
        val flags = u32(bytes, offset + 16)
        val stringsStart = u32(bytes, offset + 20)
        val isUtf8 = (flags and FLAG_UTF8) != 0

        val strings = mutableListOf<String>()
        if (stringCount == 0 || stringCount > 1_000_000) return StringPool(strings, isUtf8, offset)
        if (stringCount.toLong() * 4 + offset + 28 > bytes.size) return StringPool(strings, isUtf8, offset)

        var poolBase = offset + 28
        val poolEnd = offset + size
        val dataBase = offset + stringsStart

        for (i in 0 until stringCount) {
            val strOffset = u32(bytes, poolBase + i * 4)
            if (strOffset < 0) {
                strings.add("")
                continue
            }
            val pos = dataBase + strOffset
            if (pos < 0 || pos >= poolEnd) {
                strings.add("")
                continue
            }
            try {
                strings.add(
                    if (isUtf8) readUtf8String(bytes, pos, poolEnd)
                    else readUtf16String(bytes, pos, poolEnd)
                )
            } catch (_: Exception) {
                strings.add("")
            }
        }
        return StringPool(strings, isUtf8, offset)
    }

    private fun readUtf8String(bytes: ByteArray, pos: Int, poolEnd: Int): String {
        var p = pos
        var byteLen = bytes[p].toInt() and 0xFF
        p++
        if (byteLen and 0x80 != 0) {
            byteLen = ((byteLen and 0x7F) shl 8) or (bytes[p].toInt() and 0xFF)
            p++
        }
        // 跳过字符长度（UTF-8 存储两段长度，第二段对读取无影响）
        val charLen = bytes[p].toInt() and 0xFF
        p++
        if (charLen and 0x80 != 0) {
            p++
        }
        if (p + byteLen > poolEnd || p + byteLen > bytes.size) return ""
        if (byteLen <= 0) return ""
        return String(bytes, p, byteLen, Charsets.UTF_8)
    }

    private fun readUtf16String(bytes: ByteArray, pos: Int, poolEnd: Int): String {
        var p = pos
        var len = u16(bytes, p) and 0x7FFF
        p += 2
        if ((u16(bytes, p - 2) and 0x8000) != 0) {
            // 长字符串：长度拆成两段
            len = ((u16(bytes, p - 2) and 0x7FFF) shl 16) or u16(bytes, p)
            p += 2
        }
        if (p + len * 2 > poolEnd || p + len * 2 > bytes.size) return ""
        if (len <= 0) return ""
        return String(bytes, p, len * 2, Charsets.UTF_16LE)
    }

    private fun parseStartElement(
        bytes: ByteArray,
        offset: Int,
        chunkSize: Int,
        strings: List<String>,
    ): ElementInfo {
        val elemNameIdx = u32(bytes, offset + 20)
        val name = getString(strings, elemNameIdx)
        if (name.isNullOrEmpty()) return ElementInfo("", null, offset, chunkSize)

        var androidName: String? = null
        var androidValue: String? = null
        val attributes = linkedMapOf<String, AttributeInfo>()

        val attrStart = u16(bytes, offset + 24)
        val attrSize = u16(bytes, offset + 26)
        val attrCount = u16(bytes, offset + 28)

        fun attributeString(ab: Int): String? {
            val rawIdx = u32(bytes, ab + 8)
            val typedType = bytes[ab + 15].toInt() and 0xFF
            val typedData = u32(bytes, ab + 16)
            // 属性值可能是 raw 字符串索引，也可能是 typed string 数据
            val valueIdx = if (rawIdx != NO_INDEX && rawIdx >= 0 && rawIdx < strings.size) {
                rawIdx
            } else if (typedType == TYPE_STRING && typedData != NO_INDEX && typedData >= 0 && typedData < strings.size) {
                typedData
            } else {
                NO_INDEX
            }
            return getString(strings, valueIdx)
        }

        val attrBase = offset + 16 + attrStart
        if (attrSize >= 20 && attrCount > 0 && attrBase + attrCount * attrSize <= offset + chunkSize) {
            for (i in 0 until attrCount) {
                val ab = attrBase + i * attrSize
                val attrNameIdx = u32(bytes, ab + 4)
                val attrName = getString(strings, attrNameIdx) ?: continue
                val value = attributeString(ab)
                val attribute = AttributeInfo(
                    value = value,
                    dataType = bytes[ab + 15].toInt() and 0xFF,
                    data = u32(bytes, ab + 16),
                )
                attributes[attrName] = attribute
                if (attrName == "name") {
                    androidName = value
                } else if (attrName == "value") {
                    // meta-data 的配置值（字面量字符串；资源引用时不可读，天然为 null）
                    androidValue = value
                }
            }
        }

        return ElementInfo(name, androidName, offset, chunkSize, androidValue, attributes)
    }

    private fun getString(strings: List<String>, idx: Int): String? {
        return if (idx != NO_INDEX && idx >= 0 && idx < strings.size) strings[idx] else null
    }

    fun isAxml(bytes: ByteArray): Boolean {
        return bytes.size >= 8 && u16(bytes, 0) == CHUNK_RES_XML
    }

    private fun u16(bytes: ByteArray, offset: Int): Int {
        if (offset < 0 || offset + 2 > bytes.size) return 0
        return (bytes[offset].toInt() and 0xFF) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 8)
    }

    private fun u32(bytes: ByteArray, offset: Int): Int {
        if (offset < 0 || offset + 4 > bytes.size) return NO_INDEX
        return (bytes[offset].toInt() and 0xFF) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 8) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 16) or
            ((bytes[offset + 3].toInt() and 0xFF) shl 24)
    }
}
