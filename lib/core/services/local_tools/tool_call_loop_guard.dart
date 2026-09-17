import 'dart:collection';
import 'dart:convert';

class ToolCallLoopDecision {
  const ToolCallLoopDecision._({required this.allowed, this.message = ''});

  const ToolCallLoopDecision.allowed() : this._(allowed: true);

  const ToolCallLoopDecision.blocked(String message)
    : this._(allowed: false, message: message);

  final bool allowed;
  final String message;
}

/// Detects repeated tool calls inside a short sliding window.
///
/// A window catches both consecutive repeats and short cycles such as A-B-C-A.
/// Polling calls are ignored because their result can legitimately change.
class ToolCallLoopGuard {
  ToolCallLoopGuard({this.windowSize = 12}) : assert(windowSize > 0);

  final int windowSize;
  final Queue<String> _recent = Queue<String>();

  ToolCallLoopDecision check(
    String name,
    Map<String, dynamic> arguments, {
    bool polling = false,
  }) {
    if (polling) return const ToolCallLoopDecision.allowed();

    final fingerprint = _fingerprint(name, arguments);
    if (_recent.contains(fingerprint)) {
      return ToolCallLoopDecision.blocked(
        'LOOP_DETECTED: $name 已在最近的工具调用中用相同参数执行过。'
        '请使用已有结果，或更换参数、地址、分页游标或分析路径；不要重复验证同一证据。',
      );
    }

    _recent.addLast(fingerprint);
    while (_recent.length > windowSize) {
      _recent.removeFirst();
    }
    return const ToolCallLoopDecision.allowed();
  }

  void reset() => _recent.clear();

  /// 移除一次调用的指纹（超时/异常/网络中断后调用）：
  /// 失败的调用没有可信结果，客户端网络恢复后的相同参数重试是合理恢复
  /// 路径，不应被 LOOP_DETECTED 拦截。
  void forget(String name, Map<String, dynamic> arguments) {
    _recent.remove(_fingerprint(name, arguments));
  }

  /// A successful write makes earlier read fingerprints stale. Keep the write
  /// itself so an immediate duplicate mutation is still blocked.
  void advanceState(String name, Map<String, dynamic> arguments) {
    final fingerprint = _fingerprint(name, arguments);
    _recent
      ..clear()
      ..addLast(fingerprint);
  }

  static bool changesState(String name, Map<String, dynamic> arguments) {
    if (const <String>{
      'analyze_apk_workspace',
      'patch_apk_dex_methods',
      'signature_bypass',
      'patch_apk_manifest',
      'apk_rebuild',
      'apk_sign',
      'so_patch_into_apk',
      'cleanup_apk_builds',
      'apk_note_write',
      'save_apk_patch_memory',
      'record_apk_patch_verification',
      'ask_user_input_v0',
    }.contains(name)) {
      return true;
    }
    if (name == 'file') {
      return const <String>{
        'write',
        'copy',
        'move',
        'rename',
        'delete',
        'mkdir',
      }.contains(arguments['action']?.toString());
    }
    if (name != 'so_analyze') return false;
    final action = arguments['action']?.toString();
    if (action == 'blutter') {
      return const <String>{
        'analyze',
        'cancel',
        'locate',
        'prune',
      }.contains(arguments['blutterAction']?.toString());
    }
    return const <String>{
      'set_work_dir',
      'open',
      'open_url',
      'close',
      'analyze_apk',
      'edit_open',
      'edit_snapshot',
      'edit_rollback',
      'edit_undo',
      'edit_redo',
      'edit_reset',
      'edit_hex',
      'edit_asm',
      'edit_symbol',
      'fix_sections',
      'build',
      'build_many',
      'lief_patch_address',
      'lief_add_export',
      'lief_remove_symbol',
    }.contains(action);
  }

  static bool succeeded(String output) {
    try {
      final decoded = jsonDecode(output);
      if (decoded is! Map) return false;
      if (decoded['ok'] == false) return false;
      if (decoded['success'] == false) return false;
      final error = decoded['error'];
      if (error != null && error != false && error != '') return false;
      final status = decoded['status']?.toString().toLowerCase();
      return !const {'error', 'failed', 'failure', 'invalid'}.contains(status);
    } catch (_) {
      return false;
    }
  }

  String _fingerprint(String name, Map<String, dynamic> arguments) =>
      '$name|${jsonEncode(_canonicalize(arguments))}';

  dynamic _canonicalize(dynamic value) {
    if (value is Map) {
      final entries =
          value.entries
              .map((entry) => MapEntry(entry.key.toString(), entry.value))
              .toList()
            ..sort((a, b) => a.key.compareTo(b.key));
      return <String, dynamic>{
        for (final entry in entries) entry.key: _canonicalize(entry.value),
      };
    }
    if (value is List) return value.map(_canonicalize).toList();
    return value;
  }
}
