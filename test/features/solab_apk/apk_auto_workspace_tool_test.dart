import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solab/core/models/assistant.dart';
import 'package:solab/core/services/local_tools/local_tool_names.dart';
import 'package:solab/features/solab_apk/services/apk_analysis_service.dart';
import 'package:solab/features/solab_apk/services/apk_workspace_binding_service.dart';
import 'package:solab/features/solab_apk/services/apk_workspace_service.dart';
import 'package:solab/features/home/services/local_tools_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('solab/workspace');
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const assistant = Assistant(
    id: 'apk',
    name: 'APK Mod',
    localToolIds: [LocalToolNames.apkAnalyzeWorkspace],
  );

  late Directory appDataDir;

  setUp(() async {
    // 报告存 AppData 文件（path_provider 指向临时目录）。
    appDataDir = await Directory.systemTemp.createTemp('kelivo_auto_apk_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          return appDataDir.path;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
  });

  test('automatically analyzes the only APK in the workspace', () async {
    final directory = await Directory.systemTemp.createTemp('kelivo_auto_apk_');
    addTearDown(() => directory.delete(recursive: true));
    final apk = File('${directory.path}${Platform.pathSeparator}only.apk');
    await apk.writeAsBytes([0x50, 0x4b]);
    SharedPreferences.setMockInitialValues({
      ApkWorkspaceBindingService.workDirKey: directory.path,
    });
    var analyzeCalls = 0;
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'patchDexMethods') {
            expect((call.arguments as Map)['signatureBypassMode'], 'normal');
            if ((call.arguments as Map)['path'].toString().endsWith(
              'only_dexpatch.apk',
            )) {
              return <String, Object?>{'ok': true};
            }
            final prepared = File(
              '${directory.path}${Platform.pathSeparator}only_dexpatch.apk',
            );
            await prepared.writeAsBytes([0x50, 0x4b]);
            return <String, Object?>{'ok': true, 'outputPath': prepared.path};
          }
          expect(call.method, 'analyzeApk');
          analyzeCalls++;
          expect(
            (call.arguments as Map)['path'],
            contains('only_dexpatch.apk'),
          );
          final analyzedFile = File((call.arguments as Map)['path'].toString());
          final stat = await analyzedFile.stat();
          return <String, Object?>{
            'fileName': 'only_dexpatch.apk',
            'analysisVersion': ApkAnalysisService.analysisVersion,
            'sourceApk': <String, Object?>{
              'path': analyzedFile.path,
              'size': stat.size,
              'lastModified': stat.modified.millisecondsSinceEpoch,
            },
            'packageName': 'com.example.only',
            'versionName': '1.0',
            'shellPacking': <String, Object?>{},
            'adSdkMatches': <Object?>[],
          };
        });

    final result = await LocalToolsService.tryHandleToolCall(
      LocalToolNames.apkAnalyzeWorkspace,
      const <String, dynamic>{},
      assistant,
    );

    expect(jsonDecode(result!)['ok'], isTrue);
    expect(jsonDecode(result)['shellDetected'], isFalse);
    expect(jsonDecode(result)['signatureCompatibility'], 'normal_prepared');
    expect(analyzeCalls, 1);
    expect(calls, ['patchDexMethods', 'analyzeApk']);
    expect(
      (await ApkWorkspaceService.readReport())?['fileName'],
      'only_dexpatch.apk',
    );
    expect(
      (await ApkWorkspaceService.readReport())?['packageName'],
      'com.example.only',
    );

    calls.clear();
    final repeated = await LocalToolsService.tryHandleToolCall(
      LocalToolNames.apkAnalyzeWorkspace,
      const <String, dynamic>{'fileName': 'only_dexpatch.apk'},
      assistant,
    );
    expect(jsonDecode(repeated!)['signatureCompatibility'], 'already_prepared');
    expect(analyzeCalls, 1);
    expect(calls, ['patchDexMethods']);
  });

  test(
    'returns choices instead of analyzing when the workspace has many APKs',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'kelivo_many_apk_',
      );
      addTearDown(() => directory.delete(recursive: true));
      await File(
        '${directory.path}${Platform.pathSeparator}first.apk',
      ).writeAsBytes([0x50]);
      await File(
        '${directory.path}${Platform.pathSeparator}second.apk',
      ).writeAsBytes([0x50]);
      SharedPreferences.setMockInitialValues({
        ApkWorkspaceBindingService.workDirKey: directory.path,
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            fail('multiple APKs must be selected before native analysis');
          });

      final result = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.apkAnalyzeWorkspace,
        const <String, dynamic>{},
        assistant,
      );
      final payload = jsonDecode(result!) as Map<String, dynamic>;

      expect(payload['error'], 'apk_selection_required');
      expect(payload['apks'], hasLength(2));
    },
  );

  test(
    'explicit skip analyzes the original APK without signature preparation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'kelivo_skip_sig_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final apk = File('${directory.path}${Platform.pathSeparator}plain.apk');
      await apk.writeAsBytes([0x50, 0x4b]);
      SharedPreferences.setMockInitialValues({
        ApkWorkspaceBindingService.workDirKey: directory.path,
      });
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            expect(call.method, 'analyzeApk');
            final analyzedFile = File(
              (call.arguments as Map)['path'].toString(),
            );
            final stat = await analyzedFile.stat();
            return <String, Object?>{
              'fileName': 'plain.apk',
              'analysisVersion': ApkAnalysisService.analysisVersion,
              'sourceApk': <String, Object?>{
                'path': analyzedFile.path,
                'size': stat.size,
                'lastModified': stat.modified.millisecondsSinceEpoch,
              },
              'packageName': 'com.example.plain',
              'versionName': '1.0',
              'shellPacking': <String, Object?>{},
              'adSdkMatches': <Object?>[],
            };
          });

      final result = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.apkAnalyzeWorkspace,
        const <String, dynamic>{
          'fileName': 'plain.apk',
          'signatureMode': 'skip',
        },
        assistant,
      );

      expect(
        jsonDecode(result!)['signatureCompatibility'],
        'skipped_by_request',
      );
      expect(calls, ['analyzeApk']);
    },
  );
}
