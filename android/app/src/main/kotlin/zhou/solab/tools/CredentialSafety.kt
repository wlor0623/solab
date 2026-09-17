package zhou.solab.tools

/** 凭证清洗：剔除 CR/LF/DEL，防 header 注入（原 HttpHeaderSafety 精简版，无 okhttp 依赖）。 */
internal fun sanitizeCredential(value: String): String =
    value.filterNot { it == '\r' || it == '\n' || it.code == 0x7f }.trim()
