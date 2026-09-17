import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// APK 工作区状态 + 产物索引（自闭环，不依赖任何外部 MCP）。
///
/// 职责：
/// - 统一工作目录（APK/SO/文件工具共用；相对路径据此解析）；
/// - 当前连续修改目标 [activeApkPath]（每次成功写入自动前移，P3 一致性核对
///   以它对照报告 sourceApk）；
/// - 产物索引（未签名中间包 kind=patch / 签名成品 kind=build），支持
///   「成品即净」自动清理。
///
/// MT Manager 若需要，由用户自行配置为普通外部 MCP 直接服务 agent；
/// 本服务与其零耦合。
class ApkWorkspaceBindingService {
  ApkWorkspaceBindingService._();

  static const _buildsKey = 'apk_mod_build_index_v1';
  static const _activeApkKey = 'apk_mod_active_apk_v1';
  static const _fileArtifactsKey = 'apk_mod_file_artifacts_v1';
  static const _taskCheckpointsKey = 'apk_mod_task_checkpoints_v1';
  static const _signatureBypassDefaultKey =
      'apk_mod_signature_bypass_default_v1';
  static final Object _scopeZoneKey = Object();

  /// 工作目录（与输出目录共用同一 key）：用户在 APK 工作台选定的统一目录。
  /// 相对 apkPath / 文件名据此解析为绝对路径。
  static const workDirKey = 'apk_mod_output_dir';
  static String? _cachedWorkDir;
  static String? _cachedWorkDirRaw;
  static bool _workDirLoaded = false;
  static List<Map<String, dynamic>>? _cachedBuilds;
  static String? _cachedBuildsRaw;
  static String? _cachedBuildsStorageKey;

  static String? get currentScopeId {
    final value = Zone.current[_scopeZoneKey]?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  static Future<T> runInScope<T>(String? scopeId, Future<T> Function() action) {
    final normalized = scopeId?.trim() ?? '';
    if (normalized.isEmpty) return action();
    return runZoned(action, zoneValues: {_scopeZoneKey: normalized});
  }

  static String _scopedKey(String base) {
    final scope = currentScopeId;
    if (scope == null) return base;
    final suffix = base64Url.encode(utf8.encode(scope)).replaceAll('=', '');
    return '${base}_$suffix';
  }

  /// 读取用户选定的工作目录（未设置返回 null）。
  static Future<String?> workDir() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(workDirKey);
    if (_workDirLoaded && v == _cachedWorkDirRaw) {
      return _cachedWorkDir;
    }
    _cachedWorkDirRaw = v;
    _cachedWorkDir = (v != null && v.isNotEmpty) ? v : null;
    _workDirLoaded = true;
    return _cachedWorkDir;
  }

  static Future<void> setWorkDir(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(workDirKey, path);
    _cachedWorkDir = path;
    _cachedWorkDirRaw = path;
    _workDirLoaded = true;
  }

  static Future<void> clearWorkDir() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(workDirKey);
    _cachedWorkDir = null;
    _cachedWorkDirRaw = null;
    _workDirLoaded = true;
  }

  static Future<String?> managedOutputDir() async {
    return workDir();
  }

  static Future<String> signatureBypassDefaultMode() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString(_signatureBypassDefaultKey);
    return switch (mode) {
      'off' || 'normal' || 'original_apk' || 'dpatch' => mode!,
      _ => 'normal',
    };
  }

  static Future<void> setSignatureBypassDefaultMode(String mode) async {
    if (mode != 'off' &&
        mode != 'normal' &&
        mode != 'original_apk' &&
        mode != 'dpatch') {
      throw ArgumentError.value(mode, 'mode');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_signatureBypassDefaultKey, mode);
  }

  /// 当前连续修改的输入 APK。每次成功写入后自动更新，下一步无需重复传路径。
  static Future<String?> activeApkPath() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_scopedKey(_activeApkKey));
    return path == null || path.isEmpty ? null : path;
  }

  static Future<void> setActiveApkPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_scopedKey(_activeApkKey), path);
  }

  static Future<void> clearActiveApkPath() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_scopedKey(_activeApkKey));
  }

  static Future<List<Map<String, dynamic>>> listApks() async {
    final path = await workDir();
    if (path == null) return <Map<String, dynamic>>[];
    final directory = Directory(path);
    if (!await directory.exists()) return <Map<String, dynamic>>[];
    final apks = <Map<String, dynamic>>[];
    try {
      // handleError：跳过不可读条目（scoped storage 下部分条目枚举会抛
      // 权限异常），不能让单个坏条目炸掉整个列表。
      await for (final entry in directory.list().handleError((_) {})) {
        if (entry is File && entry.path.toLowerCase().endsWith('.apk')) {
          try {
            apks.add({
              'name': entry.uri.pathSegments.last,
              'path': entry.path,
              'size': await entry.length(),
            });
          } catch (_) {}
        }
      }
    } catch (_) {
      // 目录整体不可读（如未授予「所有文件访问」）：返回已收集部分，
      // 由调用方结合 dirReadable 诊断给出可操作的提示。
    }
    apks.sort((a, b) => (b['size'] as num).compareTo(a['size'] as num));
    return apks;
  }

  /// 目录是否真正可枚举（区分「目录为空」与「权限被拒」）。
  static Future<bool> dirReadable(String path) async {
    try {
      await Directory(path).list().first;
      return true;
    } on FileSystemException {
      return false;
    } catch (_) {
      return true; // 空目录（No element）等：可读
    }
  }

  /// 登记一个已签名产物（内置 apk_sign / buildApk(sign=true)）并预存待验证记录。
  /// 工作目录只在用户安装验证并选择清理方式后删除。
  static Future<List<String>> recordSignedBuild({
    required String? source,
    required String? output,
  }) async {
    if (output == null || output.isEmpty) return const <String>[];
    final builds = await readBuilds();
    Map<String, dynamic>? inputArtifact;
    for (final build in builds) {
      if (build['output'] == source) {
        inputArtifact = build;
        break;
      }
    }
    final pendingChanges = <Map<String, dynamic>>[
      for (final change
          in (inputArtifact?['pendingChanges'] as List? ?? const []))
        if (change is Map) Map<String, dynamic>.from(change),
    ];
    final pendingDraft = inputArtifact?['pendingMemoryDraft'] is Map
        ? Map<String, dynamic>.from(inputArtifact!['pendingMemoryDraft'] as Map)
        : {
            'title': pendingChanges.isEmpty
                ? '待验证 APK 修改'
                : '待验证 APK 修改: ${pendingChanges.map((e) => e['operation']).whereType<String>().toSet().join('、')}',
            'solution': pendingChanges.isEmpty
                ? '签名成品已生成，等待用户安装验证。'
                : pendingChanges
                      .map((e) {
                        final locators = (e['locators'] as List? ?? const [])
                            .map((value) => value.toString())
                            .where((value) => value.isNotEmpty)
                            .join('、');
                        return '${e['operation']}${locators.isEmpty ? '' : ': $locators'}';
                      })
                      .join('\n'),
            'targets': <String>[
              for (final change in pendingChanges)
                for (final locator in (change['locators'] as List? ?? const []))
                  if (locator.toString().isNotEmpty) locator.toString(),
            ],
            'createdAt': DateTime.now().millisecondsSinceEpoch,
          };
    await _appendBuild({
      'output': output,
      'kind': 'build',
      'source': source, // C3：源 APK（清理按源分组，防跨包混删）
      if (source != null && source.isNotEmpty) 'input': source,
      'rootSource':
          inputArtifact?['rootSource'] ??
          inputArtifact?['source'] ??
          inputArtifact?['input'] ??
          source,
      'signed': true, // 签名成品
      'pendingChanges': pendingChanges,
      'pendingMemoryDraft': pendingDraft,
      'pendingMemoryStatus': 'awaiting_user_verification',
      if (inputArtifact?['signatureCompatibility'] != null)
        'signatureCompatibility': inputArtifact!['signatureCompatibility'],
      if (inputArtifact?['signatureCompatibility'] != null)
        'modificationInputReady': true,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    await setActiveApkPath(output);
    return const <String>[];
  }

  /// 记录自研 patch 产物并更新连续修改的当前输入包。
  /// 历史中间包一律保留，由用户确认后通过清理工具回收。
  static Future<List<String>> recordPatchArtifact({
    required String source,
    required String output,
    required String operation,
    List<String> locators = const <String>[],
    Map<String, dynamic>? evidence,
  }) async {
    final builds = await readBuilds();
    final now = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic>? inputArtifact;
    for (final build in builds) {
      if (build['output'] == source) {
        inputArtifact = build;
        break;
      }
    }
    final rootSource =
        inputArtifact?['rootSource']?.toString() ??
        inputArtifact?['source']?.toString() ??
        source;
    final signatureCompatibility =
        operation.startsWith('signature_compatibility_')
        ? operation.substring('signature_compatibility_'.length)
        : inputArtifact?['signatureCompatibility']?.toString();
    final pendingChanges = <Map<String, dynamic>>[
      for (final change
          in (inputArtifact?['pendingChanges'] as List? ?? const []))
        if (change is Map) Map<String, dynamic>.from(change),
    ];
    if (!operation.startsWith('signature_compatibility_')) {
      pendingChanges.add({
        'operation': operation,
        if (locators.isNotEmpty) 'locators': locators,
        if (evidence != null && evidence.isNotEmpty) 'evidence': evidence,
        'timestamp': now,
      });
    }
    builds.removeWhere((entry) => entry['output'] == output);
    builds.insert(0, {
      'output': output,
      'input': source,
      'source': rootSource,
      'rootSource': rootSource,
      'kind': 'patch',
      'operation': operation,
      'pendingChanges': pendingChanges,
      if (inputArtifact?['pendingMemoryDraft'] is Map)
        'pendingMemoryDraft': inputArtifact!['pendingMemoryDraft'],
      'signed': false,
      if (signatureCompatibility != null && signatureCompatibility.isNotEmpty)
        'signatureCompatibility': signatureCompatibility,
      if (signatureCompatibility != null && signatureCompatibility.isNotEmpty)
        'modificationInputReady': true,
      if (operation.startsWith('signature_compatibility_'))
        'chainRole': 'signature_compatibility_base',
      'timestamp': now,
    });

    final autoCleaned = <String>[];
    if (inputArtifact != null &&
        inputArtifact['keep'] != true &&
        p.normalize(p.absolute(source)) !=
            p.normalize(p.absolute(rootSource))) {
      final outputDir = await managedOutputDir();
      if (outputDir != null && p.isWithin(outputDir, source)) {
        final input = File(source);
        if (await input.exists()) {
          await input.delete();
          builds.removeWhere((entry) => entry['output'] == source);
          autoCleaned.add(source);
        }
      }
    }

    await _writeBuilds(builds);
    await setActiveApkPath(output);
    return autoCleaned;
  }

  static Future<void> replaceBuilds(List<Map<String, dynamic>> builds) async {
    await _writeBuilds(builds);
  }

  static Future<bool> stagePendingMemoryDraft(
    Map<String, dynamic> draft,
  ) async {
    final active = await activeApkPath();
    if (active == null || active.isEmpty) return false;
    final builds = await readBuilds();
    final index = builds.indexWhere((build) => build['output'] == active);
    if (index == -1 || builds[index]['signed'] != true) return false;
    builds[index]['pendingMemoryDraft'] = Map<String, dynamic>.from(draft);
    builds[index]['pendingMemoryStatus'] = 'awaiting_user_verification';
    await _writeBuilds(builds);
    return true;
  }

  static Future<bool> stagePendingChange(Map<String, dynamic> change) async {
    final active = await activeApkPath();
    if (active == null || active.isEmpty) return false;
    final builds = await readBuilds();
    final index = builds.indexWhere((build) => build['output'] == active);
    if (index == -1) return false;
    final changes = <Map<String, dynamic>>[
      for (final item in (builds[index]['pendingChanges'] as List? ?? const []))
        if (item is Map) Map<String, dynamic>.from(item),
    ];
    final locator = (change['locator'] ?? '').toString();
    if (locator.isNotEmpty) {
      changes.removeWhere((item) => item['locator']?.toString() == locator);
    }
    changes.add(Map<String, dynamic>.from(change));
    builds[index]['pendingChanges'] = changes;
    await _writeBuilds(builds);
    return true;
  }

  /// 用户确认最终成品有效后收尾：只保留原 APK 与当前签名成品。
  static Future<Map<String, dynamic>> cleanupAfterVerifiedSuccess() async {
    final dir = await workDir();
    final active = await activeApkPath();
    if (dir == null || active == null) {
      return {'ok': false, 'error': 'workspace_or_final_missing'};
    }
    final builds = await readBuilds();
    final finalIndex = builds.indexWhere(
      (build) => build['output'] == active && build['signed'] == true,
    );
    if (finalIndex == -1) {
      return {'ok': false, 'error': 'signed_final_missing'};
    }
    final finalBuild = builds[finalIndex];
    final original = await _resolveOriginalPath(
      builds: builds,
      finalBuild: finalBuild,
      finalPath: active,
      workDir: dir,
    );
    final root = Directory(dir);
    if (!await root.exists()) {
      return {'ok': false, 'error': 'work_dir_not_found'};
    }
    if (original == null) {
      return {
        'ok': false,
        'error': 'original_apk_missing',
        'message': '没有找到可确认的原包，已停止清理，避免误删当前工作区。',
      };
    }

    String normalized(String path) => p.normalize(p.absolute(path));
    final kept = <String>{normalized(active)};
    kept.add(normalized(original));
    final deleted = <String>[];
    final failed = <String>[];

    Future<void> clean(FileSystemEntity entity) async {
      final path = normalized(entity.path);
      if (kept.contains(path)) return;
      if (entity is Directory && kept.any((keep) => p.isWithin(path, keep))) {
        await for (final child in entity.list().handleError((_) {})) {
          await clean(child);
        }
        try {
          if (await entity.list().isEmpty) {
            await entity.delete();
            deleted.add(entity.path);
          }
        } catch (_) {}
        return;
      }
      try {
        if (entity is Directory) {
          await entity.delete(recursive: true);
        } else {
          await entity.delete();
        }
        deleted.add(entity.path);
      } catch (_) {
        failed.add(entity.path);
      }
    }

    await for (final entry in root.list().handleError((_) {})) {
      await clean(entry);
    }
    await replaceBuilds([finalBuild]);
    await pruneMissingArtifacts();
    return {
      'ok': failed.isEmpty,
      'deletedCount': deleted.length,
      'deleted': deleted,
      'kept': [original, active],
      if (failed.isNotEmpty) 'failed': failed,
    };
  }

  /// 一级自动清理（改完即清，无需用户确认）：签名成品落地后，删除工作
  /// 目录内所有生成型中间包（_v1/_v2 命名），保留：原包、当前成品、
  /// 分析目录与其他文件。
  /// 修改无效时上一版成品即下一轮基底（基底=原包语义），因此绝不删
  /// 原包链与当前成品。
  static Future<List<String>> cleanupIntermediateArtifacts({
    required String outputPath,
  }) async {
    final dir = await workDir();
    if (dir == null || dir.isEmpty) return const <String>[];
    final root = Directory(dir);
    if (!await root.exists()) return const <String>[];
    final builds = await readBuilds();
    final keeps = <String>{p.normalize(p.absolute(outputPath))};
    // 原包：成品链上的 rootSource 候选（与确认后清理同一判定口径）
    final active = await activeApkPath();
    final finalBuild = builds.cast<Map<String, dynamic>?>().lastWhere(
      (build) => build?['output'] == active,
      orElse: () => null,
    );
    if (finalBuild != null) {
      for (final key in const ['rootSource', 'source', 'input']) {
        final value = (finalBuild[key] ?? '').toString();
        if (value.isNotEmpty) keeps.add(p.normalize(p.absolute(value)));
      }
    }
    final deleted = <String>[];
    await for (final entry in root.list().handleError((_) {})) {
      if (entry is! File) continue;
      final path = p.normalize(p.absolute(entry.path));
      if (keeps.contains(path)) continue;
      if (!isGeneratedArtifactName(entry.uri.pathSegments.last)) continue;
      try {
        await entry.delete();
        deleted.add(entry.path);
      } catch (_) {}
    }
    return deleted;
  }

  /// 生成型中间包命名判定（_v1/_v2 等后缀 apk）。兼容识别旧命名，
  /// 原包/当前成品/普通文件不受影响。
  static bool isGeneratedArtifactName(String fileName) => RegExp(
    r'(_v\d+|_signed|_structural|_dexpatch|_manifest|_assets|_abi)\.apk$',
    caseSensitive: false,
  ).hasMatch(fileName);

  static Future<String?> _resolveOriginalPath({
    required List<Map<String, dynamic>> builds,
    required Map<String, dynamic> finalBuild,
    required String finalPath,
    required String workDir,
  }) async {
    final candidates = <String>[];
    void add(Object? value) {
      final path = value?.toString().trim() ?? '';
      if (path.isNotEmpty && !candidates.contains(path)) candidates.add(path);
    }

    add(finalBuild['rootSource']);
    add(finalBuild['source']);
    add(finalBuild['input']);
    var cursor = (finalBuild['input'] ?? finalBuild['source'] ?? '').toString();
    final visited = <String>{};
    while (cursor.isNotEmpty && visited.add(cursor)) {
      final parent = builds.cast<Map<String, dynamic>?>().firstWhere(
        (build) => build?['output'] == cursor,
        orElse: () => null,
      );
      if (parent == null) break;
      add(parent['rootSource']);
      add(parent['source']);
      add(parent['input']);
      cursor = (parent['input'] ?? parent['source'] ?? '').toString();
    }
    final normalizedFinal = p.normalize(p.absolute(finalPath));
    final indexedOutputs = {
      for (final build in builds)
        p.normalize(p.absolute((build['output'] ?? '').toString())),
    };
    bool generatedName(String path) =>
        isGeneratedArtifactName(p.basename(path));
    for (final candidate in candidates) {
      final normalized = p.normalize(p.absolute(candidate));
      if (normalized != normalizedFinal &&
          p.isWithin(p.normalize(p.absolute(workDir)), normalized) &&
          !indexedOutputs.contains(normalized) &&
          !generatedName(candidate) &&
          await File(candidate).exists()) {
        return candidate;
      }
    }

    String baseStem(String path) => p
        .basenameWithoutExtension(path)
        .replaceFirst(
          RegExp(
            r'(_v\d+|_signed|_structural|_dexpatch|_manifest|_assets|_abi)+$',
            caseSensitive: false,
          ),
          '',
        );
    final finalStem = baseStem(finalPath);
    final root = Directory(workDir);
    await for (final entity in root.list().handleError((_) {})) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.apk')) {
        continue;
      }
      if (p.normalize(p.absolute(entity.path)) == normalizedFinal) continue;
      if (baseStem(entity.path) == finalStem &&
          p.basenameWithoutExtension(entity.path) == finalStem) {
        return entity.path;
      }
    }
    return null;
  }

  static Future<void> recordFileArtifact({
    required String path,
    required String operation,
    String? source,
    Map<String, dynamic>? metadata,
  }) async {
    if (path.isEmpty) return;
    final artifacts = await readFileArtifacts();
    artifacts.removeWhere((entry) => entry['path'] == path);
    artifacts.insert(0, {
      'path': path,
      'operation': operation,
      if (source != null && source.isNotEmpty) 'source': source,
      if (metadata != null && metadata.isNotEmpty)
        'metadata': Map<String, dynamic>.from(metadata),
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    if (artifacts.length > 100) artifacts.removeRange(100, artifacts.length);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _scopedKey(_fileArtifactsKey),
      jsonEncode([
        for (final item in artifacts)
          Map<String, dynamic>.from(item)
            ..remove('exists')
            ..remove('type')
            ..remove('size'),
      ]),
    );
  }

  static Future<List<Map<String, dynamic>>> readFileArtifacts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_scopedKey(_fileArtifactsKey));
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw) as List;
      final result = <Map<String, dynamic>>[];
      for (final value in decoded.whereType<Map>()) {
        final item = Map<String, dynamic>.from(value);
        final path = item['path']?.toString() ?? '';
        final type = path.isEmpty
            ? FileSystemEntityType.notFound
            : await FileSystemEntity.type(path);
        item['exists'] = type != FileSystemEntityType.notFound;
        item['type'] = type == FileSystemEntityType.directory
            ? 'directory'
            : type == FileSystemEntityType.file
            ? 'file'
            : 'missing';
        if (type == FileSystemEntityType.file) {
          try {
            item['size'] = await File(path).length();
          } catch (_) {}
        }
        result.add(item);
      }
      return result;
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  /// 保存当前会话最近的关键工具结果。打断或进程重启后,下一轮可直接恢复
  /// 已完成步骤,不依赖模型是否还能看到被截断的工具卡片。
  static Future<void> recordToolCheckpoint({
    required String tool,
    required Map<String, dynamic> arguments,
    required String result,
  }) async {
    final scope = currentScopeId;
    if (scope == null || tool.isEmpty || result.isEmpty) return;
    Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(result);
      if (decoded is! Map) return;
      payload = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }
    // 记录服务端实际收到的全部参数（逐值压缩），不再按白名单裁剪：
    // 剪裁后的 {} 会把「agent 没传参」和「传输层丢参」混为一谈。
    // 大字符串仍截断，敏感字段由各工具自身避免放入参数。
    const resultKeys = <String>{
      'ok',
      'error',
      'message',
      'action',
      'status',
      'stage',
      'stageLabel',
      'jobId',
      'workspaceId',
      'outputPath',
      'outputApk',
      'nextInputPath',
      'sourceEntry',
      'qualifiedId',
      'target',
      'resolution',
      'strictMatch',
      'returned',
      'total',
      'results',
      'nextActions',
      'modifiedLocators',
      'pendingChanges',
      'appliedAfterPreview',
      'taskId',
    };
    final selectedArguments = <String, dynamic>{
      for (final entry in arguments.entries.take(24))
        entry.key: _compactCheckpointValue(entry.value),
    };
    final selectedResult = <String, dynamic>{
      for (final entry in payload.entries)
        if (resultKeys.contains(entry.key))
          entry.key: _compactCheckpointValue(entry.value),
    };
    final active = await activeApkPath();
    final checkpoint = <String, dynamic>{
      'tool': tool,
      'arguments': selectedArguments,
      'result': selectedResult,
      if (active != null && active.isNotEmpty) 'activeApk': active,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    final prefs = await SharedPreferences.getInstance();
    final key = _scopedKey(_taskCheckpointsKey);
    final checkpoints = <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(prefs.getString(key) ?? '[]') as List;
      checkpoints.addAll([
        for (final item in decoded)
          if (item is Map) Map<String, dynamic>.from(item),
      ]);
    } catch (_) {}
    String signature(Map<String, dynamic> item) {
      final args = item['arguments'] is Map
          ? Map<String, dynamic>.from(item['arguments'] as Map)
          : const <String, dynamic>{};
      return '${item['tool']}|${args['action']}|${args['blutterAction']}|'
          '${args['jobId']}|${args['qualifiedId']}|${args['target']}';
    }

    final checkpointSignature = signature(checkpoint);
    checkpoints.removeWhere((item) => signature(item) == checkpointSignature);
    checkpoints.insert(0, checkpoint);
    if (checkpoints.length > 16) {
      checkpoints.removeRange(16, checkpoints.length);
    }
    await prefs.setString(key, jsonEncode(checkpoints));
  }

  static Object? _compactCheckpointValue(Object? value, [int depth = 0]) {
    if (value == null || value is num || value is bool) return value;
    if (value is String) {
      return value.length <= 800 ? value : '${value.substring(0, 800)}…';
    }
    if (depth >= 3) return value.toString();
    if (value is List) {
      return [
        for (final item in value.take(8))
          _compactCheckpointValue(item, depth + 1),
      ];
    }
    if (value is Map) {
      final entries = value.entries.take(24);
      return <String, dynamic>{
        for (final entry in entries)
          entry.key.toString(): _compactCheckpointValue(entry.value, depth + 1),
      };
    }
    return value.toString();
  }

  static Future<List<Map<String, dynamic>>> readToolCheckpoints() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_scopedKey(_taskCheckpointsKey));
    if (raw == null || raw.isEmpty) return const <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw) as List;
      return [
        for (final item in decoded)
          if (item is Map) Map<String, dynamic>.from(item),
      ];
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  /// 当前会话的轻量续接快照。若 active 丢失,从本会话现存产物索引恢复,
  /// 不读取全局或其他会话状态。
  static Future<Map<String, dynamic>> taskResumeState() async {
    var active = await activeApkPath();
    final builds = await readBuilds();
    if (active == null || !await File(active).exists()) {
      active = builds
          .where((build) => build['exists'] == true)
          .map((build) => build['output']?.toString() ?? '')
          .firstWhere((path) => path.isNotEmpty, orElse: () => '');
      if (active.isEmpty) active = null;
      if (active != null) await setActiveApkPath(active);
    }
    final activeBuild = active == null
        ? null
        : builds.cast<Map<String, dynamic>?>().firstWhere(
            (build) => build?['output'] == active,
            orElse: () => null,
          );
    final files = await readFileArtifacts();
    final latestSo = files.cast<Map<String, dynamic>?>().firstWhere(
      (item) => item?['operation'] == 'so_build' && item?['exists'] == true,
      orElse: () => null,
    );
    final checkpoints = await readToolCheckpoints();
    return <String, dynamic>{
      'scope': currentScopeId ?? 'global',
      'activeApk': active,
      'activeApkExists': active != null && await File(active).exists(),
      if (activeBuild != null)
        'activeArtifact': {
          for (final key in const [
            'output',
            'input',
            'source',
            'rootSource',
            'kind',
            'operation',
            'signed',
            'pendingChanges',
            'pendingMemoryStatus',
            'verification',
          ])
            if (activeBuild[key] != null) key: activeBuild[key],
        },
      if (latestSo != null)
        'latestSoArtifact': {
          'path': latestSo['path'],
          'source': latestSo['source'],
          if (latestSo['metadata'] != null) 'metadata': latestSo['metadata'],
        },
      'recentToolCheckpoints': checkpoints.take(8).toList(growable: false),
      'hasResumableState':
          active != null || activeBuild != null || checkpoints.isNotEmpty,
    };
  }

  static Future<Map<String, int>> countMissingArtifacts() async {
    final builds = await readBuilds();
    final files = await readFileArtifacts();
    return <String, int>{
      'builds': builds.where((item) => item['exists'] != true).length,
      'files': files.where((item) => item['exists'] != true).length,
    };
  }

  static Future<Map<String, int>> pruneMissingArtifacts() async {
    final builds = await readBuilds();
    final keptBuilds = builds
        .where((item) => item['exists'] == true || item['keep'] == true)
        .toList(growable: false);
    final files = await readFileArtifacts();
    final keptFiles = files
        .where((item) => item['exists'] == true)
        .toList(growable: false);
    await _writeBuilds(keptBuilds);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _scopedKey(_fileArtifactsKey),
      jsonEncode([
        for (final item in keptFiles)
          Map<String, dynamic>.from(item)
            ..remove('exists')
            ..remove('type')
            ..remove('size'),
      ]),
    );
    return <String, int>{
      'builds': builds.length - keptBuilds.length,
      'files': files.length - keptFiles.length,
    };
  }

  static Future<void> reconcileMovedPath(
    String source,
    String target, {
    bool copy = false,
  }) async {
    String rewrite(String value) {
      if (value == source) return target;
      if (p.isWithin(source, value)) {
        return p.join(target, p.relative(value, from: source));
      }
      return value;
    }

    final builds = await readBuilds();
    final additions = <Map<String, dynamic>>[];
    for (final build in builds) {
      final output = build['output']?.toString() ?? '';
      if (copy && (output == source || p.isWithin(source, output))) {
        additions.add({
          ...build,
          'output': rewrite(output),
          'input': output,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
      } else if (!copy) {
        for (final key in const ['output', 'input', 'source', 'rootSource']) {
          final value = build[key]?.toString() ?? '';
          if (value.isNotEmpty) build[key] = rewrite(value);
        }
      }
    }
    if (additions.isNotEmpty) builds.insertAll(0, additions);
    await _writeBuilds(builds);
    final active = await activeApkPath();
    if (!copy && active != null) await setActiveApkPath(rewrite(active));
  }

  /// 产物索引（最近产物在前，倒序）。
  static Future<List<Map<String, dynamic>>> readBuilds() async {
    final prefs = await SharedPreferences.getInstance();
    final storageKey = _scopedKey(_buildsKey);
    final cached = _cachedBuilds;
    final raw = prefs.getString(storageKey);
    if (cached != null &&
        raw == _cachedBuildsRaw &&
        storageKey == _cachedBuildsStorageKey) {
      return _annotateBuilds(cached);
    }
    _cachedBuildsStorageKey = storageKey;
    _cachedBuildsRaw = raw;
    if (raw == null || raw.isEmpty) {
      _cachedBuilds = <Map<String, dynamic>>[];
      return <Map<String, dynamic>>[];
    }
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      _cachedBuilds = [
        for (final e in decoded)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
      return await _annotateBuilds(_cachedBuilds!);
    } catch (_) {
      _cachedBuilds = <Map<String, dynamic>>[];
      return <Map<String, dynamic>>[];
    }
  }

  static Future<List<Map<String, dynamic>>> _annotateBuilds(
    List<Map<String, dynamic>> builds,
  ) async {
    final annotated = <Map<String, dynamic>>[];
    for (final build in builds) {
      final item = Map<String, dynamic>.from(build);
      final output = item['output']?.toString() ?? '';
      final exists = output.isNotEmpty && await File(output).exists();
      item['exists'] = exists;
      item['state'] = exists ? 'ready' : 'missing';
      item['eligibleAsNextInput'] =
          exists && item['modificationInputReady'] == true;
      annotated.add(item);
    }
    return annotated;
  }

  static Future<void> _appendBuild(Map<String, dynamic> entry) async {
    final builds = await readBuilds();
    builds.insert(0, entry);
    if (builds.length > 50) {
      builds.removeRange(50, builds.length);
    }
    await _writeBuilds(builds);
  }

  /// 标记某个产物为「保留」，回收时跳过。
  static Future<void> keepBuild(String output) async {
    final builds = await readBuilds();
    for (final b in builds) {
      if (b['output'] == output) b['keep'] = true;
    }
    await _writeBuilds(builds);
  }

  static Future<void> _writeBuilds(List<Map<String, dynamic>> builds) async {
    final prefs = await SharedPreferences.getInstance();
    final storageKey = _scopedKey(_buildsKey);
    final persisted = [
      for (final build in builds)
        Map<String, dynamic>.from(build)
          ..remove('exists')
          ..remove('state')
          ..remove('eligibleAsNextInput'),
    ];
    final raw = jsonEncode(persisted);
    await prefs.setString(storageKey, raw);
    _cachedBuildsStorageKey = storageKey;
    _cachedBuildsRaw = raw;
    _cachedBuilds = persisted;
  }

  /// 流程图②：任务收尾把工作目录恢复成干净基线。
  ///
  /// 只保留：
  /// - 最终签名成品（索引 kind=build 或 keep=true 的产物）；
  /// - 原始 APK（索引里的 source/rootSource/input，若位于工作区内）；
  /// - 当前连续修改目标 activeApkPath。
  /// 其余（解包目录、DEX/SO/Blutter 工作文件、索引/临时文件、旧中间包）
  /// 全部删除。返回被清理的路径列表。
  static Future<List<String>> cleanupToBaseline() async {
    final dir = await workDir();
    if (dir == null) return const <String>[];
    final d = Directory(dir);
    if (!await d.exists()) return const <String>[];

    final keep = <String>{};
    final active = await activeApkPath();
    if (active != null && active.isNotEmpty) keep.add(active);
    for (final b in await readBuilds()) {
      final out = b['output']?.toString();
      if (out != null &&
          out.isNotEmpty &&
          (b['kind'] == 'build' || b['keep'] == true)) {
        keep.add(out);
      }
      // 原始 APK（只保留工作区内的输入源文件）。
      for (final key in const ['source', 'rootSource', 'input']) {
        final src = b[key]?.toString();
        if (src != null && src.isNotEmpty && p.isWithin(dir, src)) {
          keep.add(src);
        }
      }
    }

    final deleted = <String>[];
    try {
      await for (final entry in d.list().handleError((_) {})) {
        final path = entry.path;
        if (keep.contains(path)) continue;
        try {
          if (entry is File) {
            await entry.delete();
          } else if (entry is Directory) {
            await entry.delete(recursive: true);
          }
          deleted.add(path);
        } catch (_) {}
      }
    } catch (_) {
      // 目录不可枚举（如未授予「所有文件访问」）时返回已清理部分。
    }
    return deleted;
  }
}
