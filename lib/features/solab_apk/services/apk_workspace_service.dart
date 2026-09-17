import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../utils/app_directories.dart';
import 'apk_analysis_service.dart';
import 'apk_workspace_binding_service.dart';

class ApkWorkspaceService {
  const ApkWorkspaceService._();

  /// 旧版 SharedPreferences key（迁移后删除）。
  static const _legacyReportKey = 'apk_mod_current_report_v2';
  static const _reportFileName = 'report_current.json';
  static const _dirName = 'solab_apk';
  static const _legacyDirName = 'apk_mod';

  /// 报告体积可达数百 KB~MB 级，SP 是整文件 XML、读写全量且无上限，
  /// 迁到 AppData 独立文件（旧 SP key 读取后自动迁移并删除）。
  static Future<Directory> _reportDirectory() async {
    final appData = await AppDirectories.getAppDataDirectory();
    final dir = Directory('${appData.path}/$_dirName');
    await dir.create(recursive: true);
    final legacy = Directory('${appData.path}/$_legacyDirName');
    if (await legacy.exists()) {
      await for (final entity in legacy.list()) {
        if (entity is! File) continue;
        final target = File('${dir.path}/${entity.uri.pathSegments.last}');
        if (!await target.exists()) await entity.copy(target.path);
      }
    }
    return dir;
  }

  static Future<File> _reportFile({String? conversationId}) async {
    final scope = conversationId?.trim().isNotEmpty == true
        ? conversationId!.trim()
        : ApkWorkspaceBindingService.currentScopeId;
    final fileName = scope == null
        ? _reportFileName
        : 'report_${base64Url.encode(utf8.encode(scope)).replaceAll('=', '')}.json';
    return File('${(await _reportDirectory()).path}/$fileName');
  }

  static Future<void> saveReport(
    Map<Object?, Object?> report, {
    String? conversationId,
  }) async {
    final enriched = Map<Object?, Object?>.from(report);
    enriched['reportSavedAt'] = DateTime.now().millisecondsSinceEpoch;
    final scopeId = conversationId?.trim().isNotEmpty == true
        ? conversationId!.trim()
        : ApkWorkspaceBindingService.currentScopeId;
    if (scopeId != null) {
      enriched['reportConversationId'] = scopeId;
    }
    final file = await _reportFile(conversationId: scopeId);
    await file.writeAsString(jsonEncode(_normalize(enriched)));
    _invalidateReportCache();
    final preferences = await SharedPreferences.getInstance();
    if (preferences.containsKey(_legacyReportKey)) {
      await preferences.remove(_legacyReportKey);
    }
  }

  static Future<void> clearReport({String? conversationId}) async {
    try {
      final file = await _reportFile(conversationId: conversationId);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    _invalidateReportCache();
    if (conversationId == null &&
        ApkWorkspaceBindingService.currentScopeId == null) {
      final preferences = await SharedPreferences.getInstance();
      if (preferences.containsKey(_legacyReportKey)) {
        await preferences.remove(_legacyReportKey);
      }
    }
  }

  /// readReport 进程内缓存：报告 JSON 可达数百 KB~MB，一次任务内多处重复
  /// 全量读盘+解码（project_info / route_task / 记忆保存 / 笔记…每次补丁
  /// 流程触发 2-4 次）。按 (路径|大小|mtime) 失效，saveReport/clearReport
  /// 写时主动失效；返回浅拷贝防止调用方突变污染缓存。
  static Map<String, dynamic>? _reportCache;
  static String? _reportCacheKey;

  static String? _reportCacheKeyOf(File file) {
    try {
      final stat = file.statSync();
      if (stat.type != FileSystemEntityType.file) return null;
      return '${file.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    } catch (_) {
      return null;
    }
  }

  static void _invalidateReportCache() {
    _reportCache = null;
    _reportCacheKey = null;
  }

  static Future<Map<String, dynamic>?> readReport({
    String? conversationId,
  }) async {
    final scopeId = conversationId?.trim().isNotEmpty == true
        ? conversationId!.trim()
        : ApkWorkspaceBindingService.currentScopeId;
    final file = await _reportFile(conversationId: scopeId);
    final cacheKey = _reportCacheKeyOf(file);
    if (cacheKey != null &&
        cacheKey == _reportCacheKey &&
        _reportCache != null) {
      return Map<String, dynamic>.from(_reportCache!);
    }
    if (cacheKey != null && await file.exists()) {
      try {
        final raw = await file.readAsString();
        if (raw.isNotEmpty) {
          final decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
          _reportCache = decoded;
          _reportCacheKey = cacheKey;
          return Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        // 文件损坏按无报告处理（下次保存覆盖）。
        _invalidateReportCache();
      }
    }
    if (scopeId != null) {
      final globalFile = File(
        '${(await _reportDirectory()).path}/$_reportFileName',
      );
      if (await globalFile.exists()) {
        try {
          final decoded = Map<String, dynamic>.from(
            jsonDecode(await globalFile.readAsString()) as Map,
          );
          if (decoded['reportConversationId'] == scopeId) {
            await file.writeAsString(jsonEncode(decoded));
            _invalidateReportCache();
            return decoded;
          }
        } catch (_) {}
      }
      return null;
    }
    // 兼容旧版 SP key：读到则迁移到文件并删除。
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_legacyReportKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      try {
        await file.writeAsString(raw);
        await preferences.remove(_legacyReportKey);
      } catch (_) {}
      return decoded;
    } catch (_) {
      return null;
    }
  }

  /// 从其他会话的只读快照中复用同一份、未变化 APK 的报告。
  /// 命中后由调用方另存到当前会话， mutable 状态仍保持会话隔离。
  static Future<Map<String, dynamic>?> findFreshReportForPath(
    String apkPath,
  ) async {
    final target = File(apkPath);
    if (!await target.exists()) return null;
    final targetStat = await target.stat();
    String normalizePath(String value) =>
        File(value).absolute.path.replaceAll('\\', '/').toLowerCase();
    final normalizedTarget = normalizePath(target.path);
    final directory = await _reportDirectory();
    await for (final entity in directory.list()) {
      if (entity is! File ||
          !entity.uri.pathSegments.last.startsWith('report_') ||
          !entity.path.endsWith('.json')) {
        continue;
      }
      try {
        final decoded = Map<String, dynamic>.from(
          jsonDecode(await entity.readAsString()) as Map,
        );
        final source = decoded['sourceApk'];
        if (source is! Map) continue;
        final sourcePath = source['path']?.toString() ?? '';
        if (normalizePath(sourcePath) != normalizedTarget) {
          continue;
        }
        if ((decoded['analysisVersion'] as num?)?.toInt() !=
            ApkAnalysisService.analysisVersion) {
          continue;
        }
        if ((source['size'] as num?)?.toInt() != targetStat.size ||
            (source['lastModified'] as num?)?.toInt() !=
                targetStat.modified.millisecondsSinceEpoch) {
          continue;
        }
        return decoded;
      } catch (_) {}
    }
    return null;
  }

  static Future<bool> refreshSourceFingerprint(
    String path, {
    String? replacesPath,
  }) async {
    final report = await readReport();
    if (report == null) return false;
    final source = report['sourceApk'];
    if (source is! Map) return false;
    final sourcePath = source['path']?.toString() ?? '';
    if (sourcePath != path && sourcePath != replacesPath) return false;
    final file = File(path);
    if (!await file.exists()) return false;
    final stat = await file.stat();
    report['fileName'] = file.uri.pathSegments.last;
    report['sourceApk'] = {
      ...Map<String, dynamic>.from(source),
      'path': path,
      'size': stat.size,
      'lastModified': stat.modified.millisecondsSinceEpoch,
    };
    report['artifactRegeneratedAt'] = DateTime.now().millisecondsSinceEpoch;
    await saveReport(report);
    return true;
  }

  /// 从完整报告提取已有模块结果，避免 Agent 为同一个 APK 再次扫描 ZIP/DEX。
  /// 仅在调用方未要求 forceRefresh 时使用。
  static Map<String, dynamic>? moduleFromReport(
    Map<String, dynamic> report,
    String module,
  ) {
    final payload = switch (module) {
      'basics' => {
        'packageName': report['packageName'],
        'appLabel': report['appLabel'],
        'versionName': report['versionName'],
        'versionCode': report['versionCode'],
        'sha256': report['sha256'],
        'certificateSha256': report['certificateSha256'],
        'minSdk': report['minSdk'],
        'targetSdk': report['targetSdk'],
        'debuggable': report['debuggable'],
        'allowBackup': report['allowBackup'],
        'signingScheme': report['signingScheme'],
        'runtimeEngines': report['runtimeEngines'],
      },
      'manifest' => {
        'packageName': report['packageName'],
        'activities': report['activities'],
        'services': report['services'],
        'receivers': report['receivers'],
        'providers': report['providers'],
        'exportedComponents': report['exportedComponents'],
        'permissions': report['permissions'],
        'dangerousPermissions': report['dangerousPermissions'],
        'metaData': report['metaData'],
      },
      'shell' => {'shellPacking': report['shellPacking']},
      'files' => {
        'totalFiles': report['totalFiles'],
        'uncompressedBytes': report['uncompressedBytes'],
        'compressedBytes': report['compressedBytes'],
        'compressionRatio': report['compressionRatio'],
        'dexFiles': report['dexFiles'],
        'resourceFiles': report['resourceFiles'],
        'assetFiles': report['assetFiles'],
        'nativeLibraries': report['nativeLibraries'],
        'abis': report['abis'],
        'fileTypeCounts': report['fileTypeCounts'],
        'largestFiles': report['largestFiles'],
        'nativeLibraryFiles': report['nativeLibraryFiles'],
        'candidates': report['candidates'],
        'runtimeEngines': report['runtimeEngines'],
      },
      'dex' => {
        'dexFiles': report['dexFiles'],
        'dexDetails': report['dexDetails'],
        'adSdkMatches': report['adSdkMatches'],
        'adSdkStringMatches': report['adSdkStringMatches'],
        'adClassMatches': report['adClassMatches'],
        'adEntryMethodMatches': report['adEntryMethodMatches'],
        'adMethodMatches': report['adMethodMatches'],
        'adUrlMatches': report['adUrlMatches'],
        'vipMethodCandidates': report['vipMethodCandidates'],
        'timeMethodCandidates': report['timeMethodCandidates'],
        'dexPatternMatches': report['dexPatternMatches'],
        'ruleStats': report['ruleStats'],
      },
      _ => null,
    };
    if (payload == null) return null;
    return {
      'ok': true,
      'module': module,
      'source': 'full_report_cache',
      ...payload,
    };
  }

  static Future<String> readForAi(
    String section, {
    String? currentConversationId,
  }) async {
    final requestedScope = currentConversationId?.trim() ?? '';
    if (requestedScope.isNotEmpty &&
        ApkWorkspaceBindingService.currentScopeId != requestedScope) {
      return ApkWorkspaceBindingService.runInScope(
        requestedScope,
        () => readForAi(section, currentConversationId: requestedScope),
      );
    }
    var report = await readReport(conversationId: currentConversationId);
    if (report == null && currentConversationId?.trim().isNotEmpty == true) {
      var activePath = await ApkWorkspaceBindingService.activeApkPath();
      if (activePath == null || !await File(activePath).exists()) {
        final apks = await ApkWorkspaceBindingService.listApks();
        if (apks.length == 1) activePath = apks.single['path']?.toString();
      }
      if (activePath != null) {
        final reusable = await findFreshReportForPath(activePath);
        if (reusable != null) {
          await ApkWorkspaceBindingService.setActiveApkPath(activePath);
          await saveReport(reusable, conversationId: currentConversationId);
          report = reusable;
        }
      }
    }
    if (report == null) {
      return jsonEncode({
        'error': 'no_apk_selected',
        'message': '当前没有 APK 报告，请让用户先到设置 > APK 工作台选择 APK。',
      });
    }
    final scopedActive = await ApkWorkspaceBindingService.activeApkPath();
    if (scopedActive == null || !await File(scopedActive).exists()) {
      final source = report['sourceApk'];
      final sourcePath = source is Map
          ? (source['path'] ?? '').toString().trim()
          : '';
      if (sourcePath.isNotEmpty && await File(sourcePath).exists()) {
        await ApkWorkspaceBindingService.setActiveApkPath(sourcePath);
      }
    }
    // stale 短路（新对话体验）：旧报告（APK 已更换/文件已变/引擎升级）在
    // AI 读取入口直接丢弃清理，省掉「读旧报告 → 比对指纹 → 发现不是
    // 同一个 APK → 提示重新分析」的循环，AI 直接进入 analyze 路径。
    final freshness = await reportFreshnessOf(report);
    if (freshness['status'] == 'stale') {
      await clearReport(conversationId: currentConversationId);
      return jsonEncode({
        'error': 'stale_report_discarded',
        'message':
            '旧分析报告已失效并自动清理（原因: ${freshness['fileReason'] ?? '引擎规则版本升级'}）。请直接 analyze_apk_workspace 分析当前 APK，禁止沿用旧报告结论。',
        'discardReason': freshness['fileReason'],
      });
    }
    final meta = _reportMeta(report, currentConversationId);
    final payload = switch (section) {
      'decision' => await _decisionContext(report, meta),
      'components' => {
        'packageName': report['packageName'],
        'activities': report['activities'],
        'services': report['services'],
        'receivers': report['receivers'],
        'providers': report['providers'],
        'exportedComponents': report['exportedComponents'],
      },
      'permissions' => {
        'packageName': report['packageName'],
        'permissions': report['permissions'],
        'dangerousPermissions': report['dangerousPermissions'],
      },
      'ads' => {
        'packageName': report['packageName'],
        'adSdkMatches': report['adSdkMatches'],
        'adSdkMatchesSemantics': '已由 DEX 类定义或 Manifest 组件确认的广告 SDK 包名。',
        'adSdkStringMatches': report['adSdkStringMatches'],
        'adSdkStringMatchesSemantics': '仅字符串命中，可能是应用市场包名、文档或常量，不得单独判定广告 SDK。',
        'adUrlMatches': report['adUrlMatches'],
        'adClassMatches': report['adClassMatches'],
        'adMethodMatches': report['adMethodMatches'],
        'adEntryMethodMatches': report['adEntryMethodMatches'],
        'vipMethodCandidates': report['vipMethodCandidates'],
        'timeMethodCandidates': report['timeMethodCandidates'],
        'dexPatternMatches': report['dexPatternMatches'],
        'ruleStats': report['ruleStats'],
        'dexDetails': report['dexDetails'],
      },
      'files' => {
        'packageName': report['packageName'],
        'fileTypeCounts': report['fileTypeCounts'],
        'largestFiles': report['largestFiles'],
        'nativeLibraryFiles': report['nativeLibraryFiles'],
        'candidates': report['candidates'],
      },
      'full' => report,
      _ => _summary(report, meta),
    };
    return jsonEncode(payload);
  }

  static Future<Map<String, dynamic>> _decisionContext(
    Map<String, dynamic> report,
    Map<String, dynamic> meta,
  ) async => {
    'facts': _summary(report, meta),
    // 命中信号取前 12 条（全量在 ads/files 分区按需读取，避免大包刷爆上下文）。
    // 缺陷 5 修复：字符串扫描词明确标注为 candidates（非可执行目标），
    // 真实方法定义必须通过定位工具获取并验证。
    'topSignals': {
      // 厂商命中只给样本+总数（全量明细在 ads 分区按需读取）；
      // dex pattern 只给 per-dex 计数（明细在 ads 分区），
      // 避免 decision 上下文被几百条 pattern 字符串撑爆。
      'adSdkMatchSample': _take(report['adSdkMatches'], 12),
      'adSdkMatchTotal': ((report['adSdkMatches'] as List?) ?? const []).length,
      'adSdkMatchesSemantics':
          '由 DEX 类定义或 Manifest 组件确认的 SDK 包名；全量用 section=ads 读取。',
      'adSdkStringCandidateSample': _take(report['adSdkStringMatches'], 12),
      'adEntryMethodStringCandidates': _take(
        report['adEntryMethodMatches'],
        12,
      ),
      'adMethodStringCandidates': _take(report['adMethodMatches'], 12),
      'vipMethodStringCandidates': _take(report['vipMethodCandidates'], 12),
      'timeMethodStringCandidates': _take(report['timeMethodCandidates'], 12),
      'dexPatternMatchCounts': [
        for (final e in ((report['dexPatternMatches'] as List?) ?? const []))
          if (e is Map)
            {
              'dex': e['dex'],
              'patternCount': ((e['patterns'] as List?) ?? const []).length,
            },
      ],
      'dexPatternMatchesSemantics':
          'per-dex 规则命中计数；pattern 明细用 section=ads 读取（dexPatternMatches 字段）。',
      'dangerousPermissions': _take(report['dangerousPermissions'], 8),
      // 签名校验检测：命中说明重打包签名后可能闪退，修改前必须预警。
      if (report['signatureCheck'] is Map)
        'signatureCheck': report['signatureCheck'],
    },
    // R1：报告新鲜度——引擎/规则升级（analysisVersion bump）后，旧缓存报告
    // 识别为 stale 并强制重新分析，禁止把过期口径当新鲜数据采信
    'reportFreshness': await reportFreshnessOf(report),
    // 语义标注（缺陷 5/6 修复）：字符串/规则命中 ≠ 可执行的目标，执行前必须方法级定位。
    'signalSemantics': [
      '所有 *StringCandidates（adEntryMethodMatches/adMethodMatches/vipMethodCandidates/timeMethodCandidates）来自字符串扫描（规则词命中），不代表真实方法定义，不可直接作为 patch 目标。',
      '执行前的定位依据：先用 dex_search 找候选类，再用 class_outline 或 dex_xref 获取 qualifiedId，并以 smali_read 验证；把 qualifiedId 原样传给 patch_apk_dex_methods（不要改写大小写，L 前缀必须大写）。',
      'candidateCount 是文件级精简候选数量（字符串命中），与广告方法命中无关；真实可修改目标数需 methods 模块确认。',
      'patch_apk_dex_methods 的 dryRun 返回 warning(type=no_method_hits) 时，必须先完成方法定位再执行，禁止猜测方法名。',
      'signatureCheck.detected=true 时，修改前必须向用户预警：重打包签名后可能闪退（签名校验），确认可接受风险再继续。',
    ],
    'decisionRules': const [
      '先以命中 DEX、规则命中、权限、组件和候选文件为目标，禁止没有依据地逐个文件猜测。',
      '需要具体细节时只读取对应报告分段；报告没有证据时，明确标为待验证。',
      '修改建议必须写出分析依据、目标范围、风险和验证方法。',
      '所有修改类工具必须先 dryRun=true 预览；dryRun 返回 no_method_hits warning 时必须先按 dex_search → class_outline/dex_xref → smali_read 完成方法定位再重试。',
      '报告按当前对话隔离；只补当前任务缺少的分区或产物，不读取其他对话的旧结论。',
    ],
  };

  /// R1：报告新鲜度判定必须同时满足引擎版本与当前文件指纹一致。
  static Future<Map<String, dynamic>> reportFreshnessOf(
    Map<String, dynamic> report,
  ) async {
    final reportVersion = (report['analysisVersion'] as num?)?.toInt() ?? 0;
    final current = ApkAnalysisService.analysisVersion;
    final source = report['sourceApk'];
    final sourceMap = source is Map
        ? Map<String, dynamic>.from(source)
        : const <String, dynamic>{};
    final sourcePath = (sourceMap['path'] ?? report['path'] ?? '')
        .toString()
        .trim();
    final activePath = await ApkWorkspaceBindingService.activeApkPath();
    final currentPath = (activePath?.trim().isNotEmpty == true)
        ? activePath!.trim()
        : sourcePath;
    String? fileReason;
    Map<String, dynamic>? fileFingerprint;
    final normalizedSourcePath = sourcePath.replaceAll('\\', '/').toLowerCase();
    final normalizedCurrentPath = currentPath
        .replaceAll('\\', '/')
        .toLowerCase();
    if (sourcePath.isEmpty || sourceMap['lastModified'] is! num) {
      fileReason = 'missing_file_fingerprint';
    } else if (normalizedCurrentPath != normalizedSourcePath) {
      Map<String, dynamic>? lineageArtifact;
      for (final build in await ApkWorkspaceBindingService.readBuilds()) {
        final output = (build['output'] ?? '')
            .toString()
            .replaceAll('\\', '/')
            .toLowerCase();
        final roots = <String>{
          for (final key in const ['rootSource', 'source'])
            (build[key] ?? '').toString().replaceAll('\\', '/').toLowerCase(),
        }..remove('');
        if (output == normalizedCurrentPath &&
            roots.contains(normalizedSourcePath)) {
          lineageArtifact = build;
          break;
        }
      }
      final activeFile = File(currentPath);
      final sourceFile = File(sourcePath);
      if (lineageArtifact == null) {
        fileReason = 'active_apk_changed';
      } else if (!await activeFile.exists()) {
        fileReason = 'active_artifact_missing';
      } else if (!await sourceFile.exists()) {
        fileReason = 'source_file_missing';
      } else {
        final stat = await sourceFile.stat();
        final expectedModified = (sourceMap['lastModified'] as num).toInt();
        final expectedSize = (sourceMap['size'] as num?)?.toInt();
        fileFingerprint = {
          'path': sourcePath,
          'activeArtifactPath': currentPath,
          'lineageOperation': lineageArtifact['operation'],
          'lineageKind': lineageArtifact['kind'],
          'reportLastModified': expectedModified,
          'currentLastModified': stat.modified.millisecondsSinceEpoch,
          if (expectedSize != null) 'reportSize': expectedSize,
          'currentSize': stat.size,
        };
        if (stat.modified.millisecondsSinceEpoch != expectedModified ||
            (expectedSize != null && stat.size != expectedSize)) {
          fileReason = 'source_file_changed';
        }
      }
    } else {
      final file = File(currentPath);
      if (!await file.exists()) {
        fileReason = 'source_file_missing';
      } else {
        final stat = await file.stat();
        final expectedModified = (sourceMap['lastModified'] as num).toInt();
        final expectedSize = (sourceMap['size'] as num?)?.toInt();
        fileFingerprint = {
          'path': currentPath,
          'reportLastModified': expectedModified,
          'currentLastModified': stat.modified.millisecondsSinceEpoch,
          if (expectedSize != null) 'reportSize': expectedSize,
          'currentSize': stat.size,
        };
        if (stat.modified.millisecondsSinceEpoch != expectedModified ||
            (expectedSize != null && stat.size != expectedSize)) {
          fileReason = 'source_file_changed';
        }
      }
    }
    final status = reportVersion == 0
        ? 'unknown'
        : (reportVersion < current || fileReason != null ? 'stale' : 'fresh');
    return {
      'status': status,
      'reportAnalysisVersion': reportVersion,
      'currentAnalysisVersion': current,
      'fileReason': fileReason,
      if (fileFingerprint != null) 'fileFingerprint': fileFingerprint,
      if (status == 'stale')
        'action':
            '报告引擎版本或 APK 文件指纹已变化。必须先 analyze_apk_workspace 重新分析后再执行任何修改，禁止采信旧报告结论。',
      if (fileReason == null && normalizedCurrentPath != normalizedSourcePath)
        'resumableLineage': true,
    };
  }

  static Map<String, dynamic> _reportMeta(
    Map<String, dynamic> report,
    String? currentConversationId,
  ) {
    final savedAt = (report['reportSavedAt'] as num?)?.toInt();
    final sourceId = (report['reportConversationId'] as String?)?.trim();
    return {
      if (savedAt != null) 'reportSavedAt': savedAt,
      if (savedAt != null)
        'reportSavedAtHuman': DateTime.fromMillisecondsSinceEpoch(
          savedAt,
        ).toLocal().toString().substring(0, 19),
      if (sourceId != null) 'reportConversationId': sourceId,
    };
  }

  static Map<String, dynamic> _summary(
    Map<String, dynamic> report, [
    Map<String, dynamic>? meta,
  ]) => {
    'fileName': report['fileName'],
    'packageName': report['packageName'],
    'appLabel': report['appLabel'],
    'versionName': report['versionName'],
    'versionCode': report['versionCode'],
    'size': report['size'],
    'sha256': report['sha256'],
    'certificateSha256': report['certificateSha256'],
    'minSdk': report['minSdk'],
    'targetSdk': report['targetSdk'],
    'debuggable': report['debuggable'],
    'allowBackup': report['allowBackup'],
    ...?meta,
    'totalFiles': report['totalFiles'],
    'dexFiles': report['dexFiles'],
    'resourceFiles': report['resourceFiles'],
    'assetFiles': report['assetFiles'],
    'nativeLibraries': report['nativeLibraries'],
    'abis': report['abis'],
    'componentCounts': {
      'activities': _length(report['activities']),
      'services': _length(report['services']),
      'receivers': _length(report['receivers']),
      'providers': _length(report['providers']),
      'exported': _length(report['exportedComponents']),
    },
    'permissionCount': _length(report['permissions']),
    'dangerousPermissions': report['dangerousPermissions'],
    // 摘要只带前 12 条 SDK 命中 + 总数；完整列表在 ads 分区按需读取，
    // 避免每条消息注入时决策上下文携带全量列表。
    'adSdkMatches': _take(report['adSdkMatches'], 12),
    'adSdkMatchCount': _length(report['adSdkMatches']),
    'adSdkMatchesSemantics':
        '由 DEX 类定义或 Manifest 组件确认的广告 SDK 包名。'
        '摘要仅含前 12 条，全量用 get_current_apk_report(section=ads) 读取。',
    'adSdkStringMatches': _take(report['adSdkStringMatches'], 12),
    'adClassMatches': _take(report['adClassMatches'], 12),
    'adEntryMethodMatches': _take(report['adEntryMethodMatches'], 12),
    'adMethodMatches': _take(report['adMethodMatches'], 12),
    'adUrlMatches': _take(report['adUrlMatches'], 12),
    'vipMethodCandidates': _take(report['vipMethodCandidates'], 12),
    'timeMethodCandidates': _take(report['timeMethodCandidates'], 12),
    // 缺陷 6 修复：candidateCount 明确为文件级精简候选（字符串命中），
    // 与广告方法命中无关；真实可修改目标数需 methods 模块确认。
    'candidateCount': _length(report['candidates']),
    'candidateCountKind': 'file_level_string_hits',
    'analysisVersion': report['analysisVersion'],
    // 加固壳检测：有壳时修改无效，必须先确认脱壳状态。
    'shellPacking': report['shellPacking'],
    // v5：Flutter 应用识别、签名方案、DEX 头部详情（AI 判断修改方式与风险）。
    'flutterApp': report['flutterApp'],
    'runtimeEngines': report['runtimeEngines'],
    'signingScheme': report['signingScheme'],
    'signatureCheck': report['signatureCheck'],
    'dexDetails': report['dexDetails'],
  };

  static int _length(Object? value) => value is List ? value.length : 0;

  static List<dynamic> _take(Object? value, [int limit = 20]) {
    if (value is! List) return const [];
    return value.take(limit).toList(growable: false);
  }

  static Object? _normalize(Object? value) {
    if (value is Map) {
      return value.map(
        (key, item) => MapEntry(key.toString(), _normalize(item)),
      );
    }
    if (value is Iterable) return value.map(_normalize).toList();
    return value;
  }
}
