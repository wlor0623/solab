import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'business SharedPreferences access stays inside the frozen allowlist',
    () async {
      const allowed = <String>{
        'lib/core/database/app_database.dart',
        'lib/core/database/business_migration_engine.dart',
        'lib/core/providers/settings_provider.dart',
        'lib/features/solab_apk/services/apk_analysis_service.dart',
        'lib/features/solab_apk/services/apk_memory_migration_service.dart',
        'lib/features/solab_apk/services/apk_mutation_preview_service.dart',
        'lib/features/solab_apk/services/apk_patch_memory_service.dart',
        'lib/features/solab_apk/services/apk_patch_note_service.dart',
        'lib/features/solab_apk/services/apk_rule_service.dart',
        'lib/features/solab_apk/services/apk_workspace_binding_service.dart',
        'lib/features/solab_apk/services/apk_workspace_service.dart',
        'lib/features/migration/hive_to_sqlite_migration_service.dart',
        'lib/main.dart',
      };
      final references = <String>[];
      await for (final entity in Directory('lib').list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = await entity.readAsString();
        if (!source.contains('package:shared_preferences/') &&
            !RegExp(r'\bSharedPreferences\b').hasMatch(source)) {
          continue;
        }
        references.add(entity.path.replaceAll('\\', '/'));
      }
      references.sort();

      expect(references, orderedEquals(allowed.toList()..sort()));
    },
  );

  test(
    'discarded chat preference keys only exist in the routing filter',
    () async {
      final references = <String>[];
      await for (final entity in Directory('lib').list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = await entity.readAsString();
        if (!source.contains('pinned_chat_ids') &&
            !source.contains('chat_titles_map')) {
          continue;
        }
        references.add(entity.path.replaceAll('\\', '/'));
      }
      references.sort();

      expect(references, <String>[
        'lib/core/database/business_settings_router.dart',
      ]);
    },
  );
}
