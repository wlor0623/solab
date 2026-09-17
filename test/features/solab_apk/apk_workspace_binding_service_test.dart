import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solab/features/solab_apk/services/apk_workspace_binding_service.dart';
import 'package:solab/features/solab_apk/services/apk_workspace_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory appDataDir;

  setUp(() async {
    // 报告存 AppData 文件（path_provider 指向临时目录）。
    appDataDir = await Directory.systemTemp.createTemp('kelivo_binding_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          return appDataDir.path;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
  });

  test('work directory uses one shared binding value', () async {
    SharedPreferences.setMockInitialValues({});

    await ApkWorkspaceBindingService.setWorkDir('/storage/emulated/0/MT2');
    expect(
      await ApkWorkspaceBindingService.workDir(),
      '/storage/emulated/0/MT2',
    );

    await ApkWorkspaceBindingService.clearWorkDir();
    expect(await ApkWorkspaceBindingService.workDir(), isNull);
  });

  test('build index registers signed builds directly', () async {
    SharedPreferences.setMockInitialValues({});

    await ApkWorkspaceBindingService.recordSignedBuild(
      source: 'input.apk',
      output: '/storage/emulated/0/MT2/会员修改.apk',
    );

    final builds = await ApkWorkspaceBindingService.readBuilds();
    expect(builds.single['output'], '/storage/emulated/0/MT2/会员修改.apk');
    expect(builds.single['signed'], isTrue);
    expect(builds.single['kind'], 'build');
  });

  test('signed build keeps the patch lineage root source', () async {
    final directory = await Directory.systemTemp.createTemp('kelivo_signed_');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}${Platform.pathSeparator}source.apk');
    final patched = File(
      '${directory.path}${Platform.pathSeparator}patched.apk',
    );
    final signed = File('${directory.path}${Platform.pathSeparator}signed.apk');
    await source.writeAsBytes([0x50]);
    await patched.writeAsBytes([0x50]);
    await signed.writeAsBytes([0x50]);
    SharedPreferences.setMockInitialValues({
      ApkWorkspaceBindingService.workDirKey: directory.path,
    });

    await ApkWorkspaceBindingService.recordPatchArtifact(
      source: source.path,
      output: patched.path,
      operation: 'so_patch_into_apk',
    );
    await ApkWorkspaceBindingService.recordSignedBuild(
      source: patched.path,
      output: signed.path,
    );

    final builds = await ApkWorkspaceBindingService.readBuilds();
    final build = builds.firstWhere((item) => item['output'] == signed.path);
    expect(build['rootSource'], source.path);
    expect(build['input'], patched.path);
    expect(build['pendingMemoryStatus'], 'awaiting_user_verification');
    expect(await patched.exists(), isTrue);
  });

  test('verified success cleanup keeps only original and final artifact', () async {
    final directory = await Directory.systemTemp.createTemp('solab_verified_');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final source = File('${directory.path}${Platform.pathSeparator}source.apk');
    final patched = File(
      '${directory.path}${Platform.pathSeparator}temp${Platform.pathSeparator}patched.apk',
    );
    final signed = File(
      '${directory.path}${Platform.pathSeparator}out${Platform.pathSeparator}signed.apk',
    );
    final noise = File(
      '${directory.path}${Platform.pathSeparator}SoLab${Platform.pathSeparator}cache.bin',
    );
    for (final file in [source, patched, signed, noise]) {
      await file.parent.create(recursive: true);
      await file.writeAsBytes([0x50]);
    }
    SharedPreferences.setMockInitialValues({
      ApkWorkspaceBindingService.workDirKey: directory.path,
    });
    await ApkWorkspaceBindingService.recordPatchArtifact(
      source: source.path,
      output: patched.path,
      operation: 'so_patch_into_apk',
    );
    await ApkWorkspaceBindingService.recordSignedBuild(
      source: patched.path,
      output: signed.path,
    );

    final result =
        await ApkWorkspaceBindingService.cleanupAfterVerifiedSuccess();
    expect(result['ok'], isTrue);
    expect(await source.exists(), isTrue);
    expect(await signed.exists(), isTrue);
    expect(await patched.exists(), isFalse);
    expect(await noise.exists(), isFalse);
    final builds = await ApkWorkspaceBindingService.readBuilds();
    expect(builds, hasLength(1));
    expect(builds.single['output'], signed.path);
  });

  test(
    'SO write-back signing preserves the original across intermediate cleanup',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'solab_so_chain_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final source = File('${directory.path}${Platform.pathSeparator}demo.apk');
      final prepared = File(
        '${directory.path}${Platform.pathSeparator}demo_dexpatch.apk',
      );
      final structural = File(
        '${directory.path}${Platform.pathSeparator}demo_structural.apk',
      );
      final signed = File(
        '${directory.path}${Platform.pathSeparator}demo_signed.apk',
      );
      for (final file in [source, prepared, structural, signed]) {
        await file.writeAsBytes([0x50]);
      }
      SharedPreferences.setMockInitialValues({
        ApkWorkspaceBindingService.workDirKey: directory.path,
      });

      await ApkWorkspaceBindingService.recordPatchArtifact(
        source: source.path,
        output: prepared.path,
        operation: 'signature_compatibility_normal',
      );
      await ApkWorkspaceBindingService.recordPatchArtifact(
        source: prepared.path,
        output: structural.path,
        operation: 'so_patch_into_apk',
      );
      await ApkWorkspaceBindingService.recordSignedBuild(
        source: structural.path,
        output: signed.path,
      );
      final result =
          await ApkWorkspaceBindingService.cleanupAfterVerifiedSuccess();

      expect(result['ok'], isTrue);
      expect(result['kept'], containsAll([source.path, signed.path]));
      expect(await source.exists(), isTrue);
      expect(await signed.exists(), isTrue);
      expect(await prepared.exists(), isFalse);
      expect(await structural.exists(), isFalse);
    },
  );

  test('missing build and file records can be pruned', () async {
    SharedPreferences.setMockInitialValues({});
    await ApkWorkspaceBindingService.recordSignedBuild(
      source: 'input.apk',
      output: '/storage/emulated/0/MT2/missing.apk',
    );
    await ApkWorkspaceBindingService.recordFileArtifact(
      path: '/storage/emulated/0/MT2/missing.txt',
      operation: 'delete',
    );

    expect(
      await ApkWorkspaceBindingService.countMissingArtifacts(),
      <String, int>{'builds': 1, 'files': 1},
    );
    expect(
      await ApkWorkspaceBindingService.pruneMissingArtifacts(),
      <String, int>{'builds': 1, 'files': 1},
    );
    expect(await ApkWorkspaceBindingService.readBuilds(), isEmpty);
    expect(await ApkWorkspaceBindingService.readFileArtifacts(), isEmpty);
  });

  test(
    'active APK, builds and file artifacts are isolated by conversation',
    () async {
      final directory = await Directory.systemTemp.createTemp('kelivo_scope_');
      addTearDown(() => directory.delete(recursive: true));
      final first = File('${directory.path}${Platform.pathSeparator}first.apk');
      final second = File(
        '${directory.path}${Platform.pathSeparator}second.apk',
      );
      await first.writeAsBytes([0x50]);
      await second.writeAsBytes([0x50]);
      SharedPreferences.setMockInitialValues({
        ApkWorkspaceBindingService.workDirKey: directory.path,
      });

      await ApkWorkspaceBindingService.runInScope('conv-a', () async {
        await ApkWorkspaceBindingService.setActiveApkPath(first.path);
        await ApkWorkspaceBindingService.recordFileArtifact(
          path: first.path,
          operation: 'write',
        );
      });
      await ApkWorkspaceBindingService.runInScope('conv-b', () async {
        expect(await ApkWorkspaceBindingService.activeApkPath(), isNull);
        expect(await ApkWorkspaceBindingService.readFileArtifacts(), isEmpty);
        await ApkWorkspaceBindingService.setActiveApkPath(second.path);
      });
      await ApkWorkspaceBindingService.runInScope('conv-a', () async {
        expect(await ApkWorkspaceBindingService.activeApkPath(), first.path);
        expect(
          (await ApkWorkspaceBindingService.readFileArtifacts())
              .single['exists'],
          isTrue,
        );
        await first.delete();
        expect(
          (await ApkWorkspaceBindingService.readFileArtifacts())
              .single['exists'],
          isFalse,
        );
      });
    },
  );

  test('工具进度和 SO 产物可续接且按会话隔离', () async {
    final directory = await Directory.systemTemp.createTemp('kelivo_resume_');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}${Platform.pathSeparator}source.apk');
    final patched = File(
      '${directory.path}${Platform.pathSeparator}patched.apk',
    );
    final so = File('${directory.path}${Platform.pathSeparator}patched.so');
    await source.writeAsBytes([0x50]);
    await patched.writeAsBytes([0x51]);
    await so.writeAsBytes([0x7f, 0x45, 0x4c, 0x46]);
    SharedPreferences.setMockInitialValues({
      ApkWorkspaceBindingService.workDirKey: directory.path,
    });

    await ApkWorkspaceBindingService.runInScope('conv-a', () async {
      await ApkWorkspaceBindingService.recordPatchArtifact(
        source: source.path,
        output: patched.path,
        operation: 'patch_apk_dex_methods',
      );
      await ApkWorkspaceBindingService.stagePendingChange({
        'locator': 'Lx/Vip;->level()I',
        'operation': 'force_return_constant',
      });
      await ApkWorkspaceBindingService.recordFileArtifact(
        path: so.path,
        source: patched.path,
        operation: 'so_build',
        metadata: const {'sourceEntry': 'lib/arm64-v8a/libapp.so'},
      );
      await ApkWorkspaceBindingService.recordToolCheckpoint(
        tool: 'dex_search',
        arguments: const {'action': 'auto', 'methodName': 'level'},
        result: '{"ok":true,"qualifiedId":"Lx/Vip;->level()I","returned":1}',
      );

      final state = await ApkWorkspaceBindingService.taskResumeState();
      expect(state['activeApk'], patched.path);
      final pending =
          (state['activeArtifact'] as Map)['pendingChanges'] as List;
      expect(pending, hasLength(2));
      expect(
        pending.whereType<Map>().any(
          (item) => item['locator'] == 'Lx/Vip;->level()I',
        ),
        isTrue,
      );
      expect((state['latestSoArtifact'] as Map)['path'], so.path);
      expect(state['recentToolCheckpoints'], hasLength(1));
      expect(state['hasResumableState'], isTrue);
    });

    await ApkWorkspaceBindingService.runInScope('conv-b', () async {
      final state = await ApkWorkspaceBindingService.taskResumeState();
      expect(state['activeApk'], isNull);
      expect(state['latestSoArtifact'], isNull);
      expect(state['recentToolCheckpoints'], isEmpty);
      expect(state['hasResumableState'], isFalse);
    });
  });

  test('patch artifacts discard the replaced managed intermediate', () async {
    final directory = await Directory.systemTemp.createTemp('kelivo_patch_');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}${Platform.pathSeparator}source.apk');
    final outputDir = Directory(
      '${directory.path}${Platform.pathSeparator}kelivo_output',
    );
    await outputDir.create();
    final first = File('${outputDir.path}${Platform.pathSeparator}first.apk');
    final latest = File('${outputDir.path}${Platform.pathSeparator}latest.apk');
    await source.writeAsBytes([0x50]);
    await first.writeAsBytes([0x50]);
    await latest.writeAsBytes([0x50]);
    SharedPreferences.setMockInitialValues({
      ApkWorkspaceBindingService.workDirKey: directory.path,
    });

    await ApkWorkspaceBindingService.recordPatchArtifact(
      source: source.path,
      output: first.path,
      operation: 'patch_apk_dex_methods',
    );
    final deleted = await ApkWorkspaceBindingService.recordPatchArtifact(
      source: first.path,
      output: latest.path,
      operation: 'patch_apk_manifest',
    );

    expect(deleted, [first.path]);
    expect(await source.exists(), isTrue);
    expect(await first.exists(), isFalse);
    expect(await latest.exists(), isTrue);
    expect(await ApkWorkspaceBindingService.activeApkPath(), latest.path);
    expect(await ApkWorkspaceBindingService.readBuilds(), hasLength(1));
  });

  test(
    'signature dependency follows the chain and missing files are marked',
    () async {
      final directory = await Directory.systemTemp.createTemp('kelivo_chain_');
      addTearDown(() => directory.delete(recursive: true));
      final source = File(
        '${directory.path}${Platform.pathSeparator}source.apk',
      );
      final outputDir = Directory(
        '${directory.path}${Platform.pathSeparator}kelivo_output',
      );
      await outputDir.create();
      final prepared = File(
        '${outputDir.path}${Platform.pathSeparator}prepared.apk',
      );
      final patched = File(
        '${outputDir.path}${Platform.pathSeparator}patched.apk',
      );
      await source.writeAsBytes([0x50]);
      await prepared.writeAsBytes([0x50]);
      await patched.writeAsBytes([0x50]);
      SharedPreferences.setMockInitialValues({
        ApkWorkspaceBindingService.workDirKey: directory.path,
      });

      await ApkWorkspaceBindingService.recordPatchArtifact(
        source: source.path,
        output: prepared.path,
        operation: 'signature_compatibility_normal',
      );
      await ApkWorkspaceBindingService.recordPatchArtifact(
        source: prepared.path,
        output: patched.path,
        operation: 'so_patch_into_apk',
      );

      var builds = await ApkWorkspaceBindingService.readBuilds();
      expect(builds.single['signatureCompatibility'], 'normal');
      expect(builds.single['modificationInputReady'], isTrue);
      expect(builds.single['eligibleAsNextInput'], isTrue);

      await patched.delete();
      builds = await ApkWorkspaceBindingService.readBuilds();
      expect(builds.single['exists'], isFalse);
      expect(builds.single['state'], 'missing');
      expect(builds.single['eligibleAsNextInput'], isFalse);
    },
  );

  test(
    'current report can be cleared when the work directory changes',
    () async {
      SharedPreferences.setMockInitialValues({});
      await ApkWorkspaceService.saveReport({'fileName': 'old.apk'});

      await ApkWorkspaceService.clearReport();

      expect(await ApkWorkspaceService.readReport(), isNull);
    },
  );

  test(
    'workspace APK discovery is shared by the Agent and workbench',
    () async {
      final directory = await Directory.systemTemp.createTemp('kelivo_apk_');
      addTearDown(() => directory.delete(recursive: true));
      await File(
        '${directory.path}${Platform.pathSeparator}sample.apk',
      ).writeAsBytes([0x50, 0x4b]);
      SharedPreferences.setMockInitialValues({
        ApkWorkspaceBindingService.workDirKey: directory.path,
      });

      final apks = await ApkWorkspaceBindingService.listApks();

      expect(apks.single['name'], 'sample.apk');
    },
  );

  group('一级自动清理（改完即清中间包，免确认）', () {
    test('签名落地后删除全部生成型中间包，保留原包/成品/分析目录', () async {
      final directory = await Directory.systemTemp.createTemp(
        'kelivo_auto_clean_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final sep = Platform.pathSeparator;
      String pathOf(String name) => '${directory.path}$sep$name';
      final original = File(pathOf('原始.apk'));
      final intermediate = File(pathOf('app_dexpatch.apk'));
      final structural = File(pathOf('app_structural.apk'));
      final oldSigned = File(pathOf('app_1_signed.apk'));
      final signed = File(pathOf('最终_signed.apk'));
      final analysisDir = Directory(pathOf('分析目录'));
      final note = File(pathOf('说明.md'));
      for (final file in [original, intermediate, structural, oldSigned, signed]) {
        await file.writeAsBytes([0x50, 0x4b, 0x03, 0x04]);
      }
      await analysisDir.create();
      await note.writeAsString('保留');

      SharedPreferences.setMockInitialValues({
        ApkWorkspaceBindingService.workDirKey: directory.path,
      });
      // 登记链：rootSource=原包，上一版本签名产物就是本次的“中间包”
      await ApkWorkspaceBindingService.cleanupIntermediateArtifacts(
        outputPath: signed.path,
      );

      expect(await intermediate.exists(), isFalse);
      expect(await structural.exists(), isFalse);
      expect(await oldSigned.exists(), isFalse,
          reason: '旧版成品是本轮的中间包，应清理');
      expect(await original.exists(), isTrue, reason: '原包必须保留');
      expect(await signed.exists(), isTrue, reason: '当前成品必须保留');
      expect(await analysisDir.exists(), isTrue, reason: '分析目录保留等确认后清理');
      expect(await note.exists(), isTrue, reason: '非生成文件不动');
    });

    test('命名判定只认生成后缀，普通 apk 不动', () {
      expect(
        ApkWorkspaceBindingService.isGeneratedArtifactName('app_dexpatch.apk'),
        isTrue,
      );
      expect(
        ApkWorkspaceBindingService.isGeneratedArtifactName('万能乐器_signed.apk'),
        isTrue,
      );
      expect(
        ApkWorkspaceBindingService.isGeneratedArtifactName('原始.apk'),
        isFalse,
      );
      expect(
        ApkWorkspaceBindingService.isGeneratedArtifactName('会员修改.apk'),
        isFalse,
      );
    });
  });
}
