import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/database/app_database.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('current schema version is 8 (rule subscription tables added)', () {
    expect(AppDatabase.currentSchemaVersion, 8);
  });

  test(
    'current schema creates every business and asset persistence table',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      try {
        final rows = await database
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'table';",
            )
            .get();
        final tables = rows.map((row) => row.read<String>('name')).toSet();

        expect(
          tables,
          containsAll(const {
            'assistant_rows',
            'provider_rows',
            'provider_group_rows',
            'mcp_server_rows',
            'world_book_rows',
            'assistant_memory_rows',
            'quick_phrase_rows',
            'search_service_rows',
            'tts_service_rows',
            'instruction_injection_rows',
            'assistant_tag_rows',
            'preference_rows',
            'memory_entry_rows',
            'user_profile_field_rows',
            'message_prompt_rows',
            'apk_project_rows',
            'modify_rule_rows',
            'asset_rows',
            'message_asset_rows',
            'asset_gc_rows',
            'gc_audit_rows',
            'asset_reference_dirty_rows',
          }),
        );
      } finally {
        await database.close();
      }
    },
  );

  test('current schema memory type CHECK accepts apk_patch/apk_note', () async {
    final database = AppDatabase(NativeDatabase.memory());
    try {
      final rows = await database
          .customSelect(
            "SELECT sql FROM sqlite_master WHERE type = 'table' "
            "AND name = 'memory_entry_rows';",
          )
          .get();
      final sql = rows.single.read<String>('sql');
      expect(sql, contains("'apk_patch'"));
      expect(sql, contains("'apk_note'"));
    } finally {
      await database.close();
    }
  });

  test('unpublished schema is rejected instead of migrated', () async {
    final database = AppDatabase(
      NativeDatabase.memory(
        setup: (rawDatabase) {
          rawDatabase.userVersion = 99;
        },
      ),
    );
    try {
      await expectLater(
        database.customSelect('SELECT 1;').getSingle(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'database_schema_version',
          ),
        ),
      );
    } finally {
      await database.close();
    }
  });
}
