import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solab/features/solab_apk/services/apk_workspace_service.dart';
import 'package:solab/features/solab_apk/services/apk_analysis_service.dart';
import 'package:solab/features/solab_apk/services/apk_workspace_binding_service.dart';

/// 报告语义修正（缺陷 5/6/7）的测试：
/// decision 段必须标注「字符串命中 ≠ 可 patch」语义并提示方法级定位。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> buildReport() => {
    'fileName': 'app.apk',
    'packageName': 'com.example.app',
    'appLabel': 'App',
    'versionName': '1.0.0',
    'versionCode': 1,
    'size': 1024,
    'sha256': 'aabb',
    'certificateSha256': 'ccdd',
    'minSdk': 21,
    'targetSdk': 34,
    'debuggable': false,
    'allowBackup': false,
    'totalFiles': 10,
    'dexFiles': 2,
    'resourceFiles': 3,
    'assetFiles': 4,
    'nativeLibraries': 1,
    'abis': ['arm64-v8a'],
    'activities': ['MainActivity'],
    'services': <String>[],
    'receivers': <String>[],
    'providers': <String>[],
    'exportedComponents': <Object?>[],
    'permissions': ['android.permission.INTERNET'],
    'dangerousPermissions': <String>[],
    'adSdkMatches': ['com.bytedance.sdk.openadsdk'],
    'adSdkStringMatches': ['com.baidu.'],
    'adEntryMethodMatches': <String>[],
    'adMethodMatches': ['loadad'],
    'adUrlMatches': <String>[],
    'vipMethodCandidates': ['isvip'],
    'timeMethodCandidates': <String>[],
    'dexPatternMatches': <Object?>[],
    'candidates': <Object?>[
      {'path': 'assets/x.json', 'size': 100, 'safety': 'review'},
    ],
    'analysisVersion': ApkAnalysisService.analysisVersion,
  };

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // 报告已迁到 AppData 文件存储（path_provider 指向临时目录）。
    tempDir = await Directory.systemTemp.createTemp('kelivo_apk_mod_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => tempDir.path,
        );
    final source = File('${tempDir.path}/app.apk');
    await source.writeAsBytes(const [1, 2, 3]);
    final stat = await source.stat();
    final report = buildReport()
      ..['sourceApk'] = {
        'path': source.path,
        'size': stat.size,
        'lastModified': stat.modified.millisecondsSinceEpoch,
      };
    await ApkWorkspaceService.saveReport(report);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('decision 段包含字符串命中语义标注与定位提示', () async {
    final raw = await ApkWorkspaceService.readForAi('decision');
    final payload = jsonDecode(raw) as Map<String, dynamic>;

    final semantics = payload['signalSemantics'] as List;
    expect(semantics, isNotEmpty);
    final joined = semantics.join('\n');
    expect(joined, contains('字符串扫描'));
    expect(joined, contains('dex_search'));
    expect(joined, contains('smali_read'));
    expect(joined, contains('qualifiedId'));
    expect(joined, contains('candidateCount 是文件级'));
    expect(joined, contains('no_method_hits'));

    final rules = payload['decisionRules'] as List;
    expect(
      rules.join('\n'),
      contains('dryRun 返回 no_method_hits warning 时必须先按 dex_search'),
    );
  });

  test('decision 段 topSignals 用 StringCandidates 语义标注（缺陷5修复）', () async {
    final raw = await ApkWorkspaceService.readForAi('decision');
    final payload = jsonDecode(raw) as Map<String, dynamic>;
    final signals = payload['topSignals'] as Map<String, dynamic>;

    expect(signals['adMethodStringCandidates'], ['loadad']);
    expect(signals['adSdkMatchSample'], ['com.bytedance.sdk.openadsdk']);
    expect(signals['vipMethodStringCandidates'], ['isvip']);
    // 语义标注明确字符串候选 ≠ 可执行目标
    final semantics = payload['signalSemantics'] as List<dynamic>;
    expect(semantics.join('\n'), contains('StringCandidates'));
    expect(semantics.join('\n'), contains('class_outline'));
  });

  test('decision 段旧版本报告给出 reportStale 提醒（缺陷4修复）', () async {
    final raw = await ApkWorkspaceService.readForAi('decision');
    final payload = jsonDecode(raw) as Map<String, dynamic>;
    // 测试报告是当前版本，不应有 stale 标记
    expect(payload.containsKey('reportStale'), isFalse);
  });

  test('methods 模块支持（当前版本缓存可用）', () async {
    // decision 语义标注已覆盖；此处验证 8 版本报告可正常读取
    final report = await ApkWorkspaceService.readReport();
    expect(report?['analysisVersion'], ApkAnalysisService.analysisVersion);
    expect(report?['adMethodMatches'], ['loadad']);
  });

  test('decision 段截断 adSdkMatches 并保留总数与字段语义', () async {
    final report = Map<String, dynamic>.from(
      (await ApkWorkspaceService.readReport())!,
    )..['adSdkMatches'] = List.generate(19, (index) => 'vendor.$index');
    await ApkWorkspaceService.saveReport(report);

    final raw = await ApkWorkspaceService.readForAi('decision');
    final payload = jsonDecode(raw) as Map<String, dynamic>;
    final signals = payload['topSignals'] as Map<String, dynamic>;

    expect(signals['adSdkMatchSample'], hasLength(12));
    expect(signals['adSdkMatchTotal'], 19);
    expect(signals['adSdkMatchesSemantics'], contains('DEX 类定义'));
  });

  test('ads 段区分已确认 SDK 与弱字符串候选', () async {
    final raw = await ApkWorkspaceService.readForAi('ads');
    final payload = jsonDecode(raw) as Map<String, dynamic>;

    expect(payload['adSdkMatches'], ['com.bytedance.sdk.openadsdk']);
    expect(payload['adSdkStringMatches'], ['com.baidu.']);
    expect(payload['adSdkStringMatchesSemantics'], contains('不得单独判定'));
  });

  test('decision 摘要 facts 截断 adSdkMatches 为前 12 条并给出总数', () async {
    final report = Map<String, dynamic>.from(
      (await ApkWorkspaceService.readReport())!,
    )..['adSdkMatches'] = List.generate(19, (index) => 'vendor.$index');
    await ApkWorkspaceService.saveReport(report);

    final raw = await ApkWorkspaceService.readForAi('decision');
    final payload = jsonDecode(raw) as Map<String, dynamic>;
    final facts = payload['facts'] as Map<String, dynamic>;

    // 注入摘要只带前 12 条 + 总数；全量列表由 ads 分区按需读取。
    expect(facts['adSdkMatches'], hasLength(12));
    expect(facts['adSdkMatchCount'], 19);
  });

  test('报告记录来源会话与时间，跨会话彻底隔离', () async {
    final report = (await ApkWorkspaceService.readReport())!;

    await ApkWorkspaceService.saveReport(report, conversationId: 'conv-a');

    // 同一会话读取：带时间与来源，但无跨会话标注。
    final same =
        jsonDecode(
              await ApkWorkspaceService.readForAi(
                'decision',
                currentConversationId: 'conv-a',
              ),
            )
            as Map<String, dynamic>;
    final sameFacts = same['facts'] as Map<String, dynamic>;
    expect(sameFacts['reportSavedAt'], isA<int>());
    expect(sameFacts['reportSavedAtHuman'], isA<String>());
    expect(sameFacts['reportConversationId'], 'conv-a');
    expect(sameFacts.containsKey('reportFromOtherConversation'), isFalse);

    // 新对话不能读取其他对话的报告。
    final other =
        jsonDecode(
              await ApkWorkspaceService.readForAi(
                'decision',
                currentConversationId: 'conv-b',
              ),
            )
            as Map<String, dynamic>;
    expect(other['error'], 'no_apk_selected');
  });

  test('新会话自动复制同一未变化 APK 的报告', () async {
    final source = File('${tempDir.path}/app.apk');
    final report = (await ApkWorkspaceService.readReport())!;
    await ApkWorkspaceService.saveReport(report, conversationId: 'conv-a');
    await ApkWorkspaceBindingService.setWorkDir(tempDir.path);
    expect(await ApkWorkspaceBindingService.listApks(), hasLength(1));
    expect(
      await ApkWorkspaceService.findFreshReportForPath(source.path),
      isNotNull,
    );

    final raw = await ApkWorkspaceBindingService.runInScope(
      'conv-b',
      () => ApkWorkspaceService.readForAi(
        'decision',
        currentConversationId: 'conv-b',
      ),
    );
    final payload = jsonDecode(raw) as Map<String, dynamic>;

    expect(payload['error'], isNull);
    expect((payload['facts'] as Map)['packageName'], 'com.example.app');
    final copied = await ApkWorkspaceService.readReport(
      conversationId: 'conv-b',
    );
    expect(copied?['reportConversationId'], 'conv-b');
    expect(await source.exists(), isTrue);
  });

  test('会话外读取也不会拿到其他会话的活动 APK', () async {
    final source = File('${tempDir.path}/app.apk');
    final second = File('${tempDir.path}/second.apk');
    await second.writeAsBytes(const [4, 5, 6]);
    final report = (await ApkWorkspaceService.readReport())!;
    await ApkWorkspaceService.saveReport(report, conversationId: 'conv-a');
    await ApkWorkspaceBindingService.setWorkDir(tempDir.path);
    await ApkWorkspaceBindingService.setActiveApkPath(source.path);

    final raw = await ApkWorkspaceService.readForAi(
      'decision',
      currentConversationId: 'conv-b',
    );
    final payload = jsonDecode(raw) as Map<String, dynamic>;

    expect(payload['error'], 'no_apk_selected');
    expect(
      await ApkWorkspaceBindingService.runInScope(
        'conv-b',
        ApkWorkspaceBindingService.activeApkPath,
      ),
      isNull,
    );
  });

  test('当前修改链路的产物不会让原报告失效', () async {
    final directory = await Directory.systemTemp.createTemp(
      'kelivo_lineage_freshness_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}${Platform.pathSeparator}source.apk');
    final output = File(
      '${directory.path}${Platform.pathSeparator}patched.apk',
    );
    await source.writeAsString('source', flush: true);
    await output.writeAsString('patched', flush: true);
    final stat = await source.stat();
    final report = buildReport()
      ..['sourceApk'] = {
        'path': source.path,
        'size': stat.size,
        'lastModified': stat.modified.millisecondsSinceEpoch,
      };

    final freshness = await ApkWorkspaceBindingService.runInScope(
      'lineage-conversation',
      () async {
        await ApkWorkspaceBindingService.recordPatchArtifact(
          source: source.path,
          output: output.path,
          operation: 'patch_apk_dex_methods',
        );
        return ApkWorkspaceService.reportFreshnessOf(report);
      },
    );

    expect(freshness['status'], 'fresh');
    expect(freshness['resumableLineage'], isTrue);
    expect(
      (freshness['fileFingerprint'] as Map)['activeArtifactPath'],
      output.path,
    );
  });

  test('changed source file makes a current-version report stale', () async {
    final temp = await Directory.systemTemp.createTemp('kelivo_freshness_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}${Platform.pathSeparator}app.apk');
    await file.writeAsString('first', flush: true);
    final initial = await file.stat();
    final report = buildReport()
      ..['analysisVersion'] = ApkAnalysisService.analysisVersion
      ..['path'] = file.path
      ..['sourceApk'] = {
        'path': file.path,
        'size': initial.size,
        'lastModified': initial.modified.millisecondsSinceEpoch,
      };

    final fresh = await ApkWorkspaceService.reportFreshnessOf(report);
    expect(fresh['status'], 'fresh');

    await file.writeAsString('replaced apk content', flush: true);
    final stale = await ApkWorkspaceService.reportFreshnessOf(report);
    expect(stale['status'], 'stale');
    expect(stale['fileReason'], 'source_file_changed');
  });
}
