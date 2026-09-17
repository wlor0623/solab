import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solab/features/solab_apk/services/apk_structural_service.dart';

/// 通道封装测试：mock MethodChannel('solab/workspace') 验证
/// B5/B6/B7/B8 新封装的参数透传与返回归一化。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('solab/workspace');

  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'patchDexMethods':
              return <String, Object?>{
                'ok': true,
                'dryRun': false,
                'changed': true,
                'outputPath': '/tmp/app_dexpatch.apk',
                'voidMethods': 2,
                'trueMethods': 1,
                'falseMethods': 1,
                'nopLoadLibrary': 3,
                'vpnDetection': 1,
                'emulatorDetection': 2,
                'rootDetection': 1,
                'debugDetection': 1,
                'timeMethods': 2,
              };
            case 'patchManifest':
              return <String, Object?>{
                'ok': true,
                'dryRun': true,
                'matchedComponents': [
                  {'tag': 'activity', 'name': 'com.ad.sdk.AdActivity'},
                ],
                'matchedPermissions': ['android.permission.READ_PHONE_STATE'],
              };
            case 'cleanAdAssets':
              return <String, Object?>{
                'ok': true,
                'dryRun': true,
                'candidates': [
                  {'path': 'gdt_plugin/config.json', 'referenced': false},
                  {'path': 'pangle/data.dat', 'referenced': true},
                ],
                'deletableCount': 1,
                'referencedCount': 1,
                'savedBytes': 4096,
              };
            case 'buildApk':
            case 'deleteZipEntries':
            case 'writeZipEntry':
              return <String, Object?>{
                'ok': true,
                'dryRun': (call.arguments as Map)['dryRun'] == true,
              };
            default:
              return <String, Object?>{'ok': false, 'error': 'not_implemented'};
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('patchDexMethods 透传 sdkPackages（B5）', () async {
    final result = await ApkStructuralService.patchDexMethods(
      path: '/tmp/app.apk',
      voidMethods: const ['loadAd'],
      sdkPackages: const ['com.bytedance.sdk.openadsdk'],
    );

    expect(result.ok, isTrue);
    expect(result.data?['nopLoadLibrary'], 3);
    final call = calls.single;
    expect(call.method, 'patchDexMethods');
    expect((call.arguments as Map)['sdkPackages'], isA<List<dynamic>>());
    expect(
      (call.arguments as Map)['sdkPackages'],
      contains('com.bytedance.sdk.openadsdk'),
    );
    // 未传 sdkPackages 时不应带该 key
    calls.clear();
    await ApkStructuralService.patchDexMethods(
      path: '/tmp/app.apk',
      voidMethods: const ['loadAd'],
    );
    expect((calls.single.arguments as Map).containsKey('sdkPackages'), isFalse);
  });

  test('patchDexMethods 透传 trueMethods（B3）', () async {
    final result = await ApkStructuralService.patchDexMethods(
      path: '/tmp/app.apk',
      trueMethods: const ['isVip', 'isMember'],
      dryRun: true,
    );

    expect(result.ok, isTrue);
    final call = calls.single;
    expect(call.method, 'patchDexMethods');
    final args = call.arguments as Map;
    expect(args['trueMethods'], isA<List<dynamic>>());
    expect(args['trueMethods'], containsAll(<String>['isVip', 'isMember']));
    // 未传 trueMethods 时不应带该 key
    calls.clear();
    await ApkStructuralService.patchDexMethods(
      path: '/tmp/app.apk',
      voidMethods: const ['loadAd'],
    );
    expect((calls.single.arguments as Map).containsKey('trueMethods'), isFalse);
  });

  test('patchDexMethods 默认普通签名兼容并支持原包升级参数', () async {
    await ApkStructuralService.patchDexMethods(path: '/tmp/app.apk');
    final normalArgs = calls.single.arguments as Map;
    expect(normalArgs['signatureBypass'], isTrue);
    expect(normalArgs['signatureBypassMode'], 'normal');
    expect(normalArgs.containsKey('originalApkPath'), isFalse);

    calls.clear();
    await ApkStructuralService.patchDexMethods(
      path: '/tmp/app_normal.apk',
      signatureBypass: true,
      signatureBypassMode: 'original_apk',
      originalApkPath: '/tmp/app.apk',
    );
    final fallbackArgs = calls.single.arguments as Map;
    expect(fallbackArgs['signatureBypassMode'], 'original_apk');
    expect(fallbackArgs['originalApkPath'], '/tmp/app.apk');

    calls.clear();
    await ApkStructuralService.patchDexMethods(
      path: '/tmp/app.apk',
      signatureBypass: true,
      signatureBypassMode: 'dpatch',
      originalApkPath: '/tmp/app.apk',
    );
    final dpatchArgs = calls.single.arguments as Map;
    expect(dpatchArgs['signatureBypass'], isTrue);
    expect(dpatchArgs['signatureBypassMode'], 'dpatch');
    expect(dpatchArgs['originalApkPath'], '/tmp/app.apk');
  });

  test('patchDexMethods 透传检测规避开关（VPN/模拟器）', () async {
    final result = await ApkStructuralService.patchDexMethods(
      path: '/tmp/app.apk',
      removeVpnDetection: true,
      removeEmulatorDetection: true,
      dryRun: true,
    );

    expect(result.ok, isTrue);
    final call = calls.single;
    expect(call.method, 'patchDexMethods');
    final args = call.arguments as Map;
    expect(args['removeVpnDetection'], isTrue);
    expect(args['removeEmulatorDetection'], isTrue);
    // 未开启时不应带开关 key
    calls.clear();
    await ApkStructuralService.patchDexMethods(
      path: '/tmp/app.apk',
      voidMethods: const ['loadAd'],
    );
    expect(
      (calls.single.arguments as Map).containsKey('removeVpnDetection'),
      isFalse,
    );
    expect(
      (calls.single.arguments as Map).containsKey('removeEmulatorDetection'),
      isFalse,
    );
  });

  test('patchDexMethods 透传 Root/反调试开关与时间方法（时间劫持）', () async {
    final result = await ApkStructuralService.patchDexMethods(
      path: '/tmp/app.apk',
      removeRootDetection: true,
      removeDebugDetection: true,
      timeMethods: const ['getExpireTime', 'getRemainingTime'],
      dryRun: true,
    );

    expect(result.ok, isTrue);
    final call = calls.single;
    expect(call.method, 'patchDexMethods');
    final args = call.arguments as Map;
    expect(args['removeRootDetection'], isTrue);
    expect(args['removeDebugDetection'], isTrue);
    expect(args['timeMethods'], isA<List<dynamic>>());
    expect(args['timeMethods'], contains('getExpireTime'));
    expect(result.data?['timeMethods'], 2);
    // 未传时不应带 key
    calls.clear();
    await ApkStructuralService.patchDexMethods(
      path: '/tmp/app.apk',
      voidMethods: const ['loadAd'],
    );
    final args2 = calls.single.arguments as Map;
    expect(args2.containsKey('removeRootDetection'), isFalse);
    expect(args2.containsKey('removeDebugDetection'), isFalse);
    expect(args2.containsKey('timeMethods'), isFalse);
  });

  test('patchManifest 支持 auto 与 dryRun（B6/B7）', () async {
    final result = await ApkStructuralService.patchManifest(
      path: '/tmp/app.apk',
      auto: true,
      dryRun: true,
    );

    expect(result.ok, isTrue);
    final call = calls.single;
    expect(call.method, 'patchManifest');
    final args = call.arguments as Map;
    expect(args['auto'], isTrue);
    expect(args['dryRun'], isTrue);
    expect(args.containsKey('removeComponents'), isFalse);
    expect(result.data?['matchedComponents'], isA<List<dynamic>>());
  });

  test('cleanAdAssets 参数与引用标记透传（B8）', () async {
    final result = await ApkStructuralService.cleanAdAssets(
      path: '/tmp/app.apk',
      dryRun: true,
    );

    expect(result.ok, isTrue);
    final call = calls.single;
    expect(call.method, 'cleanAdAssets');
    expect((call.arguments as Map)['dryRun'], isTrue);
    final candidates = result.data?['candidates'] as List;
    expect(candidates, hasLength(2));
    final referenced = (candidates[1] as Map)['referenced'];
    expect(referenced, isTrue);
  });

  test('结构操作透传 dryRun，预览不会执行写入', () async {
    await ApkStructuralService.buildApk(
      path: '/tmp/app.apk',
      keepAbis: const ['arm64-v8a'],
      dryRun: true,
    );
    await ApkStructuralService.deleteZipEntries(
      path: '/tmp/app.apk',
      entries: const ['assets/ad.json'],
      dryRun: true,
    );
    await ApkStructuralService.writeZipEntry(
      path: '/tmp/app.apk',
      entries: const [
        {'locator': 'zip_entry:assets/ad.json', 'action': 'delete'},
      ],
      dryRun: true,
    );

    expect(calls, hasLength(3));
    expect(
      calls.map((call) => (call.arguments as Map)['dryRun']),
      everyElement(isTrue),
    );
  });

  test('PlatformException 归一化为失败结果', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'protected_entry', message: '受保护条目');
        });

    final result = await ApkStructuralService.cleanAdAssets(
      path: '/tmp/app.apk',
    );
    expect(result.ok, isFalse);
    expect(result.error, 'protected_entry');
  });
}
