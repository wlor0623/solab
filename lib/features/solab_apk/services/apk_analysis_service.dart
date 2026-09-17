import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'apk_workspace_binding_service.dart';

/// AI 按需分析服务：一次只分析一个模块
/// （basics/manifest/shell/files/dex/resources/methods）。
///
/// 与全量 analyzeApk 不同，这里按需调用原生 `analyzeModule`，并按
/// apkSha256 + module + 分析版本缓存结果（相同 APK 相同模块不重复分析）。
///
/// 缓存写入工作目录，旧 SP key 仅由 clearCache 清理，不再读取。
class ApkAnalysisService {
  const ApkAnalysisService._();

  static const _channel = MethodChannel('solab/workspace');
  static const _cachePrefix = 'solab_apk_module_cache';
  static const _maxCacheFiles = 30;
  static const _maxCacheBytes = 300 * 1024 * 1024; // 300 MiB
  static const analysisVersion =
      18; // 与原生 report 的 analysisVersion 对齐；引擎能力变更时 bump，旧缓存自动失效

  static const supportedModules = [
    'basics',
    'manifest',
    'shell',
    'files',
    'dex',
    'resources',
    'methods',
    'fields',
  ];

  /// 按需分析单个模块。命中缓存（同 APK + 同模块 + 同分析版本）时直接返回缓存。
  /// [classPrefix] 仅 methods 模块使用：只返回该业务包前缀下的方法（T2 包过滤）。
  /// [offset]/[limit]：问题2 methods 分页（36 dex 大包 500 条上限配合 offset 取全量）。
  static Future<Map<String, dynamic>> analyzeModule({
    required String path,
    required String module,
    String? cacheKeySha256,
    bool useCache = true,
    String classPrefix = '',
    int offset = 0,
    int limit = 500,
  }) async {
    final normalized = module.trim().toLowerCase();
    if (!supportedModules.contains(normalized)) {
      return {
        'ok': false,
        'error': 'invalid_module',
        'message': '未知模块: $module（支持 ${supportedModules.join('/')}）',
      };
    }

    // T2 修复：cacheKey 并入 classPrefix——否则先分析全量（缓存）再传 classPrefix
    // 会命中旧缓存返回全量，过滤形同虚设。
    final prefixTag = classPrefix.isEmpty
        ? ''
        : '_cp${classPrefix.hashCode.toRadixString(16)}';
    // 问题2：分页参数并入 cacheKey——否则 offset=0 的结果被缓存，offset=500
    // 命中同一缓存返回相同前 500 条（翻页失效）
    final pageTag = (offset == 0 && limit == 500) ? '' : '_o${offset}_l$limit';
    final cacheKey = cacheKeySha256 == null || cacheKeySha256.isEmpty
        ? null
        : '${_cachePrefix}_${cacheKeySha256.substring(0, cacheKeySha256.length.clamp(0, 16))}_$normalized$prefixTag$pageTag';
    if (useCache && cacheKey != null) {
      final cached = await _readCache(cacheKey);
      if (cached != null) return cached;
    }

    try {
      final raw = await _channel.invokeMethod<Object?>('analyzeModule', {
        'path': path,
        'module': normalized,
        if (classPrefix.isNotEmpty) 'classPrefix': classPrefix,
        'offset': offset,
        'limit': limit,
      });
      final data = raw is Map
          ? Map<String, dynamic>.from(
              raw.map((key, value) => MapEntry(key.toString(), value)),
            )
          : <String, dynamic>{};
      if (data['ok'] == true && cacheKey != null) {
        data['analysisVersion'] = analysisVersion;
        await _writeCache(cacheKey, data);
      }
      return data;
    } on PlatformException catch (error) {
      return {
        'ok': false,
        'error': error.code,
        'message': error.message ?? '调用 analyzeModule 失败',
      };
    } on MissingPluginException {
      return _missingPluginResult();
    } catch (error) {
      return {'ok': false, 'error': 'exception', 'message': error.toString()};
    }
  }

  /// 全量分析 APK（调用原生 analyzeApk），返回完整报告。
  /// 供 AI 工具直接使用，无需用户在 UI 点「分析」按钮。
  static Future<Map<Object?, Object?>?> analyzeFull(String path) async {
    try {
      final raw = await _channel.invokeMethod<Object?>('analyzeApk', {
        'path': path,
      });
      if (raw is Map) return Map<Object?, Object?>.from(raw);
      return null;
    } on PlatformException catch (error) {
      return {'error': error.code, 'message': error.message ?? '分析失败'};
    } on MissingPluginException {
      return _missingPluginResult();
    } catch (error) {
      return {'error': 'exception', 'message': error.toString()};
    }
  }

  static Map<String, dynamic> _missingPluginResult() => {
    'error': 'apk_channel_unavailable',
    'message': 'APK 分析组件未加载。请完整重新安装当前 APK 后再试，热重载不会注册原生通道。',
  };

  /// 清理指定 APK 的模块缓存（换包/重新分析时调用）。
  /// 同时清理历史版本的 SP 缓存 key。
  static Future<void> clearCache(String apkSha256) async {
    if (apkSha256.isEmpty) return;
    final prefix =
        '${_cachePrefix}_${apkSha256.substring(0, apkSha256.length.clamp(0, 16))}_';
    try {
      final dir = await _cacheDirectory();
      if (dir != null && await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is File &&
              entity.path
                  .split(Platform.pathSeparator)
                  .last
                  .startsWith(prefix)) {
            await entity.delete();
          }
        }
      }
    } catch (_) {}
    // 旧版 SP 缓存（兼容历史版本，删除即可）。
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs
          .getKeys()
          .where((key) => key.startsWith('${_cachePrefix}_'))
          .toList();
      for (final key in keys) {
        await prefs.remove(key);
      }
    } catch (_) {}
  }

  // ---- 文件缓存（LRU：上限 30 个文件 / 300 MiB，按最后访问时间淘汰） ----

  static Future<Directory?> _cacheDirectory() async {
    final workDir = await ApkWorkspaceBindingService.workDir();
    if (workDir == null || workDir.trim().isEmpty) return null;
    final dir = Directory(
      '$workDir${Platform.pathSeparator}SoLab${Platform.pathSeparator}cache${Platform.pathSeparator}analysis',
    );
    await dir.create(recursive: true);
    return dir;
  }

  static Future<File?> _cacheFile(String cacheKey) async {
    final dir = await _cacheDirectory();
    return dir == null ? null : File('${dir.path}/$cacheKey.json');
  }

  static Future<Map<String, dynamic>?> _readCache(String cacheKey) async {
    final file = await _cacheFile(cacheKey);
    if (file == null || !await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['analysisVersion'] == analysisVersion) {
        // 命中即刷新 LRU 时间戳。
        try {
          await file.setLastModified(DateTime.now());
        } catch (_) {}
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _writeCache(
    String cacheKey,
    Map<String, dynamic> data,
  ) async {
    final file = await _cacheFile(cacheKey);
    if (file == null) return;
    await file.writeAsString(jsonEncode(data));
    await _evictIfNeeded();
  }

  static Future<void> _evictIfNeeded() async {
    try {
      final dir = await _cacheDirectory();
      if (dir == null) return;
      final files = <File>[];
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          files.add(entity);
        }
      }
      if (files.length <= _maxCacheFiles) {
        var total = 0;
        for (final file in files) {
          total += await file.length();
        }
        if (total <= _maxCacheBytes) return;
      }
      files.sort(
        (a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()),
      );
      var count = files.length;
      for (final file in files) {
        if (count <= _maxCacheFiles) break;
        try {
          await file.delete();
          count--;
        } catch (_) {}
      }
      var total = 0;
      for (final file in files) {
        if (!await file.exists()) continue;
        total += await file.length();
      }
      if (total > _maxCacheBytes) {
        files.sort(
          (a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()),
        );
        for (final file in files) {
          if (total <= _maxCacheBytes) break;
          try {
            final size = await file.length();
            await file.delete();
            total -= size;
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}
