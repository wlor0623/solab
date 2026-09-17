import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

class ApkMutationPreviewService {
  ApkMutationPreviewService._();

  static const _key = 'apk_mod_mutation_previews_v1';
  static const _lifetime = Duration(minutes: 30);

  static Future<String> issue({
    required String operation,
    required String path,
    required Map<String, dynamic> args,
  }) async {
    final token =
        '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}';
    final previews = await _read();
    previews[token] = {
      'operation': operation,
      'path': path,
      'fingerprint': _fingerprint(args),
      'arguments': _canonical(_mutationArgs(args)),
      'expiresAt': DateTime.now().add(_lifetime).millisecondsSinceEpoch,
    };
    await _write(previews);
    return token;
  }

  static Future<bool> consume({
    required String token,
    required String operation,
    required String path,
    required Map<String, dynamic> args,
  }) => consumeResult(
    token: token,
    operation: operation,
    path: path,
    args: args,
  ).then((result) => result['ok'] == true);

  /// 仅校验预览，不提前消费。调用方应在实际写入成功后再通过
  /// [invalidatePath] 清理；写入失败时同一 token 可以直接重试。
  static Future<Map<String, dynamic>> validateResult({
    required String token,
    required String operation,
    required String path,
    required Map<String, dynamic> args,
  }) => _check(
    token: token,
    operation: operation,
    path: path,
    args: args,
    consume: false,
  );

  /// P1-A：修改执行成功后，清掉同 operation+path 的其余未消费 token
  /// （当前目标已变化，旧 token 即使未过期也不可能再用），返回被清除列表。
  static Future<List<String>> invalidatePath(
    String operation,
    String path,
  ) async {
    final previews = await _read();
    final removed = <String>[];
    previews.removeWhere((token, preview) {
      if (preview is Map &&
          preview['operation'] == operation &&
          preview['path'] == path) {
        removed.add(token);
        return true;
      }
      return false;
    });
    if (removed.isNotEmpty) await _write(previews);
    return removed;
  }

  /// 任一写操作成功后，原产物已不再是后续修改链的当前输入；清理该产物上
  /// 所有操作的预览，避免不同工具从同一旧 APK 分叉并覆盖前一步修改。
  static Future<List<String>> invalidateArtifact(String path) async {
    final previews = await _read();
    final removed = <String>[];
    previews.removeWhere((token, preview) {
      if (preview is Map && preview['path'] == path) {
        removed.add(token);
        return true;
      }
      return false;
    });
    if (removed.isNotEmpty) await _write(previews);
    return removed;
  }

  /// 详细版 consume：返回失败原因（invalid/expired/mismatch）与原过期时间，
  /// 供调用方在报错时给出「previewTokenExpiresAt + 重新 dryRun」指引（P1-4）。
  static Future<Map<String, dynamic>> consumeResult({
    required String token,
    required String operation,
    required String path,
    required Map<String, dynamic> args,
  }) => _check(
    token: token,
    operation: operation,
    path: path,
    args: args,
    consume: true,
  );

  static Future<Map<String, dynamic>> _check({
    required String token,
    required String operation,
    required String path,
    required Map<String, dynamic> args,
    required bool consume,
  }) async {
    final previews = await _read();
    final preview = previews[token];
    if (preview is! Map) {
      return {
        'ok': false,
        'reason': 'invalid',
        'message': '预览确认凭证不存在（从未 dryRun 或已被消费）。',
      };
    }
    final expiresAt = (preview['expiresAt'] as num?)?.toInt();
    if (expiresAt == null ||
        DateTime.now().millisecondsSinceEpoch > expiresAt) {
      previews.remove(token);
      await _write(previews);
      final expiredAtText = expiresAt == null
          ? '未知'
          : DateTime.fromMillisecondsSinceEpoch(expiresAt).toString();
      return {
        'ok': false,
        'reason': 'expired',
        'previewTokenExpiresAt': expiredAtText,
        'message': '预览确认凭证已于 $expiredAtText 过期（有效期 30 分钟）。',
      };
    }
    if (preview['operation'] != operation ||
        preview['path'] != path ||
        preview['fingerprint'] != _fingerprint(args)) {
      return {
        'ok': false,
        'reason': 'mismatch',
        if (preview['arguments'] is Map)
          'expectedArguments': Map<String, dynamic>.from(
            preview['arguments'] as Map,
          ),
        'expectedPath': preview['path'],
        'message':
            '预览确认凭证与当前修改不一致（operation/path/修改参数发生变化）。凭证尚未消费，请恢复预览时的修改参数后重试。',
      };
    }
    if (consume) {
      previews.remove(token);
      await _write(previews);
    }
    return {'ok': true, 'consumed': consume};
  }

  static Future<Map<String, dynamic>> _read() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_key);
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      // 过期 preview 随手清理，避免 SP 无限累积。
      final now = DateTime.now().millisecondsSinceEpoch;
      final before = decoded.length;
      decoded.removeWhere(
        (_, preview) =>
            preview is Map &&
            (preview['expiresAt'] as num?)?.toInt() is int &&
            now > (preview['expiresAt'] as num).toInt(),
      );
      if (decoded.length != before) {
        await preferences.setString(_key, jsonEncode(decoded));
      }
      return decoded;
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static Future<void> _write(Map<String, dynamic> previews) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_key, jsonEncode(previews));
  }

  static String _fingerprint(Map<String, dynamic> args) =>
      jsonEncode(_canonical(_mutationArgs(args)));

  static Map<String, dynamic> _mutationArgs(Map<String, dynamic> args) =>
      Map<String, dynamic>.from(args)
        ..remove('confirm')
        ..remove('dryRun')
        ..remove('previewToken')
        ..remove('sign')
        ..remove('applyAfterPreview')
        ..remove('apkPath')
        ..remove('fileName')
        ..remove('apkName')
        ..remove('outputDir');

  static Object? _canonical(Object? value) => switch (value) {
    Map map => () {
      final keys = map.keys.map((key) => key.toString()).toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: _canonical(map[key]),
      };
    }(),
    List list => [for (final item in list) _canonical(item)],
    _ => value,
  };
}
