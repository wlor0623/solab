import 'dart:convert';

/// 记忆质量硬校验（非 LLM 依赖）：所有写入路径的统一闸门。
///
/// 解决"无用信息记录"问题：仅靠 Gatekeeper/SmartAdd 的 prompt 软约束
/// 拦不住噪音，这里用确定性规则拒绝：
///  - 长度越界（过短无信息量、过长 token 炸弹）
///  - 工具调用/中间状态噪音（workspaceId/dryRun/预览令牌等）
///  - 一次性操作指令模式（时间点/单次任务措辞）
///  - 非文本垃圾（控制字符、纯标点）
class MemoryQuality {
  MemoryQuality._();

  static const int minLength = 4;
  static const int maxLength = 2000;

  /// 噪音模式：命中即拒绝写入。覆盖工具调用痕迹与一次性中间状态。
  static final List<RegExp> noisePatterns = [
    RegExp(
      r'workspaceId|editSessionId|previewToken|TASK_CANCELLED|targetVersion',
      caseSensitive: false,
    ),
    RegExp(
      r'dryRun|confirm\s*=\s*true|nextCursor|hasMore',
      caseSensitive: false,
    ),
    RegExp(r'调用工具|工具执行|工具结果', caseSensitive: false),
    RegExp(r'^\[?\d{4}-\d{2}-\d{2}[ T]?\d{2}:\d{2}', caseSensitive: false),
  ];

  /// 返回 null 表示通过；否则为拒绝原因（面向用户/日志的文案）。
  static String? validate(String content) {
    final text = content.trim();
    if (text.isEmpty) return '记忆内容不能为空';
    if (text.length < minLength) return '记忆内容过短（< $minLength 字符），无信息量';
    if (text.length > maxLength) return '记忆内容过长（> $maxLength 字符），请拆分或精简';
    // 控制字符 / 纯标点垃圾
    final printable = text.runes.where((r) => r >= 0x20 && r != 0x7f).length;
    if (printable < text.runes.length * 3 ~/ 4) return '记忆内容包含大量控制字符，疑似垃圾';
    if (!RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(text)) {
      return '记忆内容无可读文字（纯符号/标点）';
    }
    for (final pattern in noisePatterns) {
      if (pattern.hasMatch(text)) {
        return '命中噪音模式：${pattern.pattern}（工具调用痕迹/中间状态不写入记忆）';
      }
    }
    return null;
  }

  /// 尝试解码 JSON 内容（payload 序列化场景），失败返回原文。
  static String fromJsonPayload(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map && decoded['content'] is String) {
        return decoded['content'] as String;
      }
      return payload;
    } catch (_) {
      return payload;
    }
  }
}
