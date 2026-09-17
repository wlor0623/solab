import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solab/features/solab_apk/services/apk_mutation_preview_service.dart';

void main() {
  test('preview token only accepts the matching mutation once', () async {
    SharedPreferences.setMockInitialValues({});
    const args = <String, dynamic>{
      'dryRun': true,
      'classMethods': ['Lcom/example/App;->init()V'],
    };
    final token = await ApkMutationPreviewService.issue(
      operation: 'patch_apk_dex_methods',
      path: '/tmp/source.apk',
      args: args,
    );

    expect(
      await ApkMutationPreviewService.consume(
        token: token,
        operation: 'patch_apk_dex_methods',
        path: '/tmp/source.apk',
        args: const {
          'confirm': true,
          'classMethods': ['Lcom/example/App;->init()V'],
        },
      ),
      isTrue,
    );
    expect(
      await ApkMutationPreviewService.consume(
        token: token,
        operation: 'patch_apk_dex_methods',
        path: '/tmp/source.apk',
        args: const {
          'confirm': true,
          'classMethods': ['Lcom/example/App;->init()V'],
        },
      ),
      isFalse,
    );
  });

  test('preview token rejects a changed mutation', () async {
    SharedPreferences.setMockInitialValues({});
    final token = await ApkMutationPreviewService.issue(
      operation: 'patch_apk_manifest',
      path: '/tmp/source.apk',
      args: const {
        'dryRun': true,
        'removePermissions': ['android.permission.INTERNET'],
      },
    );

    expect(
      await ApkMutationPreviewService.consume(
        token: token,
        operation: 'patch_apk_manifest',
        path: '/tmp/source.apk',
        args: const {
          'confirm': true,
          'removePermissions': ['android.permission.ACCESS_WIFI_STATE'],
        },
      ),
      isFalse,
    );
    expect(
      await ApkMutationPreviewService.consume(
        token: token,
        operation: 'patch_apk_manifest',
        path: '/tmp/source.apk',
        args: const {
          'confirm': true,
          'removePermissions': ['android.permission.INTERNET'],
        },
      ),
      isTrue,
    );
  });

  test(
    'execution-only signing flag does not invalidate mutation preview',
    () async {
      SharedPreferences.setMockInitialValues({});
      final token = await ApkMutationPreviewService.issue(
        operation: 'so_patch_into_apk',
        path: '/tmp/source.apk',
        args: const {'dryRun': true, 'entryName': 'lib/arm64-v8a/libapp.so'},
      );

      expect(
        await ApkMutationPreviewService.consume(
          token: token,
          operation: 'so_patch_into_apk',
          path: '/tmp/source.apk',
          args: const {
            'confirm': true,
            'sign': true,
            'entryName': 'lib/arm64-v8a/libapp.so',
          },
        ),
        isTrue,
      );
    },
  );

  test('validation does not consume token before a successful write', () async {
    SharedPreferences.setMockInitialValues({});
    final token = await ApkMutationPreviewService.issue(
      operation: 'patch_apk_dex_methods',
      path: '/tmp/source.apk',
      args: const {
        'dryRun': true,
        'applyAfterPreview': true,
        'apkPath': '/tmp/source.apk',
        'trueMethods': ['isVip'],
      },
    );

    final first = await ApkMutationPreviewService.validateResult(
      token: token,
      operation: 'patch_apk_dex_methods',
      path: '/tmp/source.apk',
      args: const {
        'confirm': true,
        'trueMethods': ['isVip'],
      },
    );
    final second = await ApkMutationPreviewService.validateResult(
      token: token,
      operation: 'patch_apk_dex_methods',
      path: '/tmp/source.apk',
      args: const {
        'confirm': true,
        'trueMethods': ['isVip'],
      },
    );

    expect(first['ok'], isTrue);
    expect(first['consumed'], isFalse);
    expect(second['ok'], isTrue);
  });

  test(
    'mismatch returns the exact preview arguments without consuming',
    () async {
      SharedPreferences.setMockInitialValues({});
      final token = await ApkMutationPreviewService.issue(
        operation: 'patch_apk_manifest',
        path: '/tmp/source.apk',
        args: const {
          'dryRun': true,
          'removePermissions': ['android.permission.INTERNET'],
        },
      );

      final mismatch = await ApkMutationPreviewService.validateResult(
        token: token,
        operation: 'patch_apk_manifest',
        path: '/tmp/source.apk',
        args: const {
          'confirm': true,
          'removePermissions': ['android.permission.CAMERA'],
        },
      );

      expect(mismatch['reason'], 'mismatch');
      expect((mismatch['expectedArguments'] as Map)['removePermissions'], [
        'android.permission.INTERNET',
      ]);
      expect(
        await ApkMutationPreviewService.consume(
          token: token,
          operation: 'patch_apk_manifest',
          path: '/tmp/source.apk',
          args: const {
            'confirm': true,
            'removePermissions': ['android.permission.INTERNET'],
          },
        ),
        isTrue,
      );
    },
  );

  test(
    'successful mutation invalidates every preview based on old APK',
    () async {
      SharedPreferences.setMockInitialValues({});
      final dexToken = await ApkMutationPreviewService.issue(
        operation: 'patch_apk_dex_methods',
        path: '/tmp/source.apk',
        args: const {
          'trueMethods': ['isVip'],
        },
      );
      final manifestToken = await ApkMutationPreviewService.issue(
        operation: 'patch_apk_manifest',
        path: '/tmp/source.apk',
        args: const {
          'removePermissions': ['android.permission.INTERNET'],
        },
      );

      final removed = await ApkMutationPreviewService.invalidateArtifact(
        '/tmp/source.apk',
      );

      expect(removed, containsAll([dexToken, manifestToken]));
      expect(
        await ApkMutationPreviewService.validateResult(
          token: manifestToken,
          operation: 'patch_apk_manifest',
          path: '/tmp/source.apk',
          args: const {
            'removePermissions': ['android.permission.INTERNET'],
          },
        ).then((result) => result['ok']),
        isFalse,
      );
    },
  );
}
