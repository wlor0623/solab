import 'package:solab/utils/solab_file_uri.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SolabFileUri encode/decode roundtrip', () {
    test('handles spaces, #, %, and Unicode filenames', () {
      const cases = <String>[
        'hello world.png',
        'hash#tag.png',
        'percent%20done.png',
        '写真_😀.png',
        'nested/dir/file name (1).png',
      ];

      for (final name in cases) {
        final abs = '/data/app/upload/$name';
        final uri = SolabFileUri.encodeFromAbsolute(abs, root: '/data/app');
        expect(uri, isNotNull, reason: name);
        expect(SolabFileUri.isSolabFileUri(uri!), isTrue);

        final segments = SolabFileUri.decodeToSegments(uri);
        expect(segments, isNotNull, reason: name);
        expect(segments!.first, 'upload');
        expect(segments.skip(1).join('/'), name);

        final again = SolabFileUri.encodeFromAbsolute(
          SolabFileUri.resolveToAbsolute(uri, root: '/data/app')!,
          root: '/data/app',
        );
        expect(again, uri);
      }
    });
  });

  group('SolabFileUri.decodeToSegments rejects invalid URIs', () {
    test(
      'rejects path traversal, unknown managed root, host, query/fragment',
      () {
        const invalid = <String>[
          'solab-file:///../secret',
          'solab-file:///unknown/a.png',
          'solab-file://host/upload/a.png',
          'solab-file:///upload/a.png?x=1',
          'solab-file:///upload/a.png#frag',
          'solab-file:///upload//a.png',
          'solab-file:///upload/',
          'solab-file:///upload',
          'solab-file:///',
          'solab-file:',
          'file:///upload/a.png',
        ];

        for (final uri in invalid) {
          expect(SolabFileUri.decodeToSegments(uri), isNull, reason: uri);
        }
      },
    );

    test('rejects empty path segments and dot segments', () {
      expect(
        SolabFileUri.decodeToSegments('solab-file:///images/a//b.png'),
        isNull,
      );
      expect(
        SolabFileUri.decodeToSegments('solab-file:///images/./a.png'),
        isNull,
      );
      expect(
        SolabFileUri.decodeToSegments('solab-file:///images/foo/../a.png'),
        isNull,
      );
    });

    test('returns null for malformed percent encoding', () {
      for (final uri in const [
        'solab-file:///upload/%ZZ.pdf',
        'solab-file:///upload/%.pdf',
        'solab-file:///upload/%FF.pdf',
      ]) {
        expect(SolabFileUri.decodeToSegments(uri), isNull, reason: uri);
      }
    });
  });

  group('SolabFileUri.resolveToAbsolute', () {
    test('joins under POSIX root without existence checks', () {
      final abs = SolabFileUri.resolveToAbsolute(
        'solab-file:///upload/nested/a.png',
        root: '/var/mobile/Documents',
      );
      expect(abs, '/var/mobile/Documents/upload/nested/a.png');
    });

    test('joins under Windows-style root', () {
      final abs = SolabFileUri.resolveToAbsolute(
        'solab-file:///images/photo.png',
        root: r'C:\Users\me\AppData\Local\Kelivo',
      );
      expect(abs, r'C:\Users\me\AppData\Local\Kelivo\images\photo.png');
    });

    test('returns null for invalid URI', () {
      expect(
        SolabFileUri.resolveToAbsolute(
          'solab-file:///unknown/a.png',
          root: '/tmp/root',
        ),
        isNull,
      );
    });
  });

  group('SolabFileUri.tryEncodeLegacyAbsolutePath', () {
    test('encodes iOS Documents style paths even when file is missing', () {
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          '/var/mobile/Containers/Data/Application/A1B2C3D4-E5F6-7890-ABCD-EF1234567890/Documents/upload/x.png',
        ),
        'solab-file:///upload/x.png',
      );
    });

    test('encodes Windows AppData kelivo style paths case-insensitively', () {
      for (final folder in ['kelivo', 'Kelivo', 'KELIVO']) {
        expect(
          SolabFileUri.tryEncodeLegacyAbsolutePath(
            'C:/Users/me/AppData/Local/$folder/images/Pic.PNG',
            allowGenericFallback: false,
          ),
          'solab-file:///images/Pic.PNG',
          reason: folder,
        );
      }
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          'C:/Users/me/AppData/Roaming/kelivo/avatars/a.png',
          allowGenericFallback: false,
        ),
        'solab-file:///avatars/a.png',
      );
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          r'C:\Users\old-user\AppData\Roaming\com.psyche\kelivo\upload\legacy.pdf',
          allowGenericFallback: false,
        ),
        'solab-file:///upload/legacy.pdf',
      );
      // Bare .../Kelivo/images without AppData must not match.
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          'C:/Users/me/Projects/Kelivo/images/x.png',
          allowGenericFallback: false,
        ),
        isNull,
      );
      // Suffix / prefix folder names must not match.
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          'C:/Users/me/AppData/Local/KelivoNotes/images/x.png',
          allowGenericFallback: false,
        ),
        isNull,
      );
    });

    test(
      'encodes Android package-private app_flutter and files style paths',
      () {
        expect(
          SolabFileUri.tryEncodeLegacyAbsolutePath(
            '/data/user/0/com.psyche.kelivo/app_flutter/fonts/a.ttf',
            allowGenericFallback: false,
          ),
          'solab-file:///fonts/a.ttf',
        );
        expect(
          SolabFileUri.tryEncodeLegacyAbsolutePath(
            '/data/user/0/com.psyche.kelivo/files/upload/doc.pdf',
            allowGenericFallback: false,
          ),
          'solab-file:///upload/doc.pdf',
        );
        // Non-kelivo package must not be claimed without generic fallback.
        expect(
          SolabFileUri.tryEncodeLegacyAbsolutePath(
            '/data/user/0/com.example/app_flutter/fonts/a.ttf',
            allowGenericFallback: false,
          ),
          isNull,
        );
      },
    );

    test('rejects lookalike bundles, fake UUIDs, and nested archives', () {
      // Ordinary paths / substring Kelivo.
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          '/Users/alice/Documents/images/report.png',
          allowGenericFallback: false,
        ),
        isNull,
      );
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          '/Users/alice/Projects/Kelivo/images/x.png',
          allowGenericFallback: false,
        ),
        isNull,
      );
      // Similar-but-not-whitelist bundles/packages.
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          '/Users/alice/Library/Containers/com.other.kelivo.notes/Data/Documents/images/x.png',
          allowGenericFallback: false,
        ),
        isNull,
      );
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          '/Users/alice/Library/Application Support/com.other.kelivo.notes/images/x.png',
          allowGenericFallback: false,
        ),
        isNull,
      );
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          '/data/user/0/com.other.kelivo.notes/app_flutter/images/x.png',
          allowGenericFallback: false,
        ),
        isNull,
      );
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          'C:/Users/me/AppData/Local/KelivoNotes/images/x.png',
          allowGenericFallback: false,
        ),
        isNull,
      );
      // Fake / short UUID under real iOS root.
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          '/var/mobile/Containers/Data/Application/ABC/Documents/upload/x.png',
          allowGenericFallback: false,
        ),
        isNull,
      );
      // Nested archives: prefixing a valid sandbox path must not claim it.
      for (final nested in const [
        '/tmp/archive/var/mobile/Containers/Data/Application/A1B2C3D4-E5F6-7890-ABCD-EF1234567890/Documents/images/x.png',
        '/tmp/archive/Users/alice/Library/Developer/CoreSimulator/Devices/A1B2C3D4-E5F6-7890-ABCD-EF1234567890/data/Containers/Data/Application/A1B2C3D4-E5F6-7890-ABCD-EF1234567890/Documents/images/sim.png',
        '/tmp/archive/Users/alice/Library/Application Support/com.psyche.kelivo/images/a.png',
        '/tmp/archive/Users/alice/Library/Containers/com.psyche.kelivo/Data/Documents/upload/x.png',
        '/tmp/archive/C:/Users/me/AppData/Local/Kelivo/images/Pic.PNG',
        '/tmp/archive/data/user/0/com.psyche.kelivo/app_flutter/fonts/a.ttf',
      ]) {
        expect(
          SolabFileUri.tryEncodeLegacyAbsolutePath(
            nested,
            allowGenericFallback: false,
          ),
          isNull,
          reason: nested,
        );
      }
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          '/tmp/playground/app_flutter/images/x.png',
          allowGenericFallback: false,
        ),
        isNull,
      );
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          '//server/share/images/a.png',
          allowGenericFallback: false,
        ),
        isNull,
      );
    });

    test('encodes iOS Simulator CoreSimulator UUID Documents paths', () {
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          '/Users/alice/Library/Developer/CoreSimulator/Devices/A1B2C3D4-E5F6-7890-ABCD-EF1234567890/data/Containers/Data/Application/A1B2C3D4-E5F6-7890-ABCD-EF1234567890/Documents/images/sim.png',
          allowGenericFallback: false,
        ),
        'solab-file:///images/sim.png',
      );
    });

    test('encodes iOS file: URI via portable slash path', () {
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          'file:///var/mobile/Containers/Data/Application/A1B2C3D4-E5F6-7890-ABCD-EF1234567890/Documents/images/pic.png',
          allowGenericFallback: false,
        ),
        'solab-file:///images/pic.png',
      );
    });

    test('normalizes Windows managed root Images casing under AppData', () {
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          r'C:\Users\me\AppData\Local\Kelivo\Images\x.png',
          allowGenericFallback: false,
        ),
        'solab-file:///images/x.png',
      );
    });

    test('encodes macOS Application Support kelivo bundle paths', () {
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          '/Users/alice/Library/Application Support/com.psyche.kelivo/images/a.png',
          allowGenericFallback: false,
        ),
        'solab-file:///images/a.png',
      );
    });

    test('uses generic managed-subdir fallback', () {
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          '/some/random/place/images/nested/file.png',
        ),
        'solab-file:///images/nested/file.png',
      );
    });

    test('rejects POSIX backslash filenames instead of splitting path', () {
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          r'/var/mobile/Containers/Data/Application/A1B2C3D4-E5F6-7890-ABCD-EF1234567890/Documents/images/a\b.png',
        ),
        isNull,
      );
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          r'/some/random/place/images/a\b.png',
        ),
        isNull,
      );
    });

    test('returns null when managed root/filename requirements fail', () {
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          '/var/mobile/Documents/cache/x.png',
        ),
        isNull,
      );
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          '/var/mobile/Documents/upload',
        ),
        isNull,
      );
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath(
          '/var/mobile/Documents/upload/',
        ),
        isNull,
      );
      expect(
        SolabFileUri.tryEncodeLegacyAbsolutePath('/tmp/only-file.png'),
        isNull,
      );
    });
  });

  group('SolabFileUri.isSolabFileUri', () {
    test('is a cheap prefix check', () {
      expect(SolabFileUri.isSolabFileUri('solab-file:///upload/a.png'), isTrue);
      expect(SolabFileUri.isSolabFileUri('solab-file:anything'), isTrue);
      expect(SolabFileUri.isSolabFileUri('file:///upload/a.png'), isFalse);
      expect(
        SolabFileUri.isSolabFileUri('Kelivo-file:///upload/a.png'),
        isFalse,
      );
      expect(SolabFileUri.isSolabFileUri(''), isFalse);
    });
  });

  group('SolabFileUri.encodeFromAbsolute', () {
    test('encodes only paths under root/<managed>/', () {
      expect(
        SolabFileUri.encodeFromAbsolute(
          '/data/app/upload/a.png',
          root: '/data/app',
        ),
        'solab-file:///upload/a.png',
      );
      expect(
        SolabFileUri.encodeFromAbsolute(
          '/data/app/images/nested/b.png',
          root: '/data/app',
        ),
        'solab-file:///images/nested/b.png',
      );
    });

    test('returns null for external or unmanaged paths', () {
      expect(
        SolabFileUri.encodeFromAbsolute(
          '/other/place/upload/a.png',
          root: '/data/app',
        ),
        isNull,
      );
      expect(
        SolabFileUri.encodeFromAbsolute(
          '/data/app/cache/a.png',
          root: '/data/app',
        ),
        isNull,
      );
      expect(
        SolabFileUri.encodeFromAbsolute('/data/app/upload', root: '/data/app'),
        isNull,
      );
    });

    test('encodes Windows-style absolute paths under root', () {
      expect(
        SolabFileUri.encodeFromAbsolute(
          r'C:\Users\me\AppData\Local\Kelivo\upload\a.png',
          root: r'C:\Users\me\AppData\Local\Kelivo',
        ),
        'solab-file:///upload/a.png',
      );
    });

    test('rejects backslash in filename segments', () {
      expect(
        SolabFileUri.encodeFromAbsolute(
          r'/data/app/upload/a\b.png',
          root: '/data/app',
        ),
        isNull,
      );
      expect(
        SolabFileUri.decodeToSegments('solab-file:///upload/a%5Cb.png'),
        isNull,
      );
    });
    test('percent-encodes special characters in filenames', () {
      expect(
        SolabFileUri.encodeFromAbsolute(
          '/data/app/upload/report final.pdf',
          root: '/data/app',
        ),
        'solab-file:///upload/report%20final.pdf',
      );
      expect(
        SolabFileUri.encodeFromAbsolute(
          '/data/app/upload/a#b.png',
          root: '/data/app',
        ),
        'solab-file:///upload/a%23b.png',
      );
    });
  });
}
