import 'dart:convert';

/// 共享的 LLM JSON 响应提取（复用：MemorySmartAdd.extractJson 与
/// MemoryProfileDistiller.extractJsonObject 曾各自实现一份）。
///
/// 支持 ```json fenced 代码块 / 裸 JSON 对象 / 数组，容错首尾噪声。
class MemoryJsonUtils {
  MemoryJsonUtils._();

  static final RegExp _fenceRe = RegExp(
    r'```(?:json)?\s*([\s\S]*?)```',
    caseSensitive: false,
  );

  /// 从模型响应中提取第一个 JSON 对象或数组；失败返回 null。
  static Object? extractJson(String response) {
    var text = response.trim();
    final fence = _fenceRe.firstMatch(text);
    if (fence != null) {
      text = fence.group(1)!.trim();
    }
    final startObj = text.indexOf('{');
    final startArr = text.indexOf('[');
    int start;
    if (startObj < 0 && startArr < 0) return null;
    if (startObj < 0) {
      start = startArr;
    } else if (startArr < 0) {
      start = startObj;
    } else {
      start = startObj < startArr ? startObj : startArr;
    }
    final endObj = text.lastIndexOf('}');
    final endArr = text.lastIndexOf(']');
    final end = endObj > endArr ? endObj : endArr;
    if (end <= start) return null;
    try {
      return jsonDecode(text.substring(start, end + 1));
    } catch (_) {
      return null;
    }
  }

  /// 仅提取 JSON 对象（profile 场景；内部转发 extractJson）。
  static Map<String, dynamic>? extractJsonObject(String response) {
    final decoded = extractJson(response);
    return decoded is Map<String, dynamic> ? decoded : null;
  }
}
