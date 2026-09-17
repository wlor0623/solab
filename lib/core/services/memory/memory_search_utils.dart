/// 共享的搜索分词（复用：memory_tools 的 searchTokens 与 chat_search 内联
/// 分词曾各写一份）。
class MemorySearchUtils {
  MemorySearchUtils._();

  static final RegExp _whitespace = RegExp(r'\s+');

  /// Whitespace-split + lowercase；[escapeLike]=true 时转义 LIKE 通配符。
  static List<String> tokenize(String query, {bool escapeLike = false}) {
    final tokens = query
        .trim()
        .toLowerCase()
        .split(_whitespace)
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
    if (!escapeLike) return tokens;
    return tokens.map(_escapeLike).toList(growable: false);
  }

  static String _escapeLike(String token) => token
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');
}
