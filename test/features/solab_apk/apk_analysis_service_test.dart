import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solab/features/solab_apk/services/apk_analysis_service.dart';
import 'package:solab/features/solab_apk/services/apk_workspace_binding_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('solab/workspace');
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tempDir;

  setUp(() async {
    // 模块缓存已迁到 AppData 文件存储（path_provider 指向临时目录）。
    tempDir = await Directory.systemTemp.createTemp('kelivo_apk_cache_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          return tempDir.path;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'unavailable', message: 'unavailable');
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('short cache SHA does not throw', () async {
    SharedPreferences.setMockInitialValues({});

    final result = await ApkAnalysisService.analyzeModule(
      path: '/tmp/app.apk',
      module: 'basics',
      cacheKeySha256: 'short',
    );

    expect(result['ok'], isFalse);
  });

  test('clearCache accepts short SHA', () async {
    SharedPreferences.setMockInitialValues({
      'solab_apk_module_cache_short_basics': '{}',
    });

    await ApkAnalysisService.clearCache('short');

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.containsKey('solab_apk_module_cache_short_basics'),
      isFalse,
    );
  });

  test('analyzeModule reuses a matching native analysis version cache', () async {
    SharedPreferences.setMockInitialValues({
      ApkWorkspaceBindingService.workDirKey: tempDir.path,
    });
    // 预写文件缓存（新存储介质：<appData>/solab_apk/cache/<key>.json）。
    final cacheDir = Directory('${tempDir.path}/SoLab/cache/analysis');
    await cacheDir.create(recursive: true);
    await File(
      '${cacheDir.path}/solab_apk_module_cache_aabbccddeeff0011_basics.json',
    ).writeAsString(
      '{"ok":true,"analysisVersion":${ApkAnalysisService.analysisVersion},"packageName":"com.example.cached"}',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          fail('matching cache should not invoke the native channel');
        });

    final result = await ApkAnalysisService.analyzeModule(
      path: '/tmp/app.apk',
      module: 'basics',
      cacheKeySha256: 'aabbccddeeff0011',
    );

    expect(result['packageName'], 'com.example.cached');
  });

  test('analyzeFull returns native report', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'analyzeApk');
          expect((call.arguments as Map)['path'], '/tmp/app.apk');
          return <String, Object?>{'packageName': 'com.example.app'};
        });

    final report = await ApkAnalysisService.analyzeFull('/tmp/app.apk');

    expect(report?['packageName'], 'com.example.app');
  });

  test('analyzeFull returns channel error instead of a report', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'missing_plugin',
            message: 'analyzeApk unavailable',
          );
        });

    final report = await ApkAnalysisService.analyzeFull('/tmp/app.apk');

    expect(report?['error'], 'missing_plugin');
    expect(report?['message'], 'analyzeApk unavailable');
  });

  test('analyzeFull explains a missing native APK channel', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw MissingPluginException('analyzeApk unavailable');
        });

    final report = await ApkAnalysisService.analyzeFull('/tmp/app.apk');

    expect(report?['error'], 'apk_channel_unavailable');
    expect(report?['message'], contains('完整重新安装'));
  });
}
