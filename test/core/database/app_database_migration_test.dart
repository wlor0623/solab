import 'dart:io';

import 'package:drift/native.dart';
import 'package:solab/core/database/app_database.dart';
import 'package:solab/core/database/chat_database_repository.dart';
import 'package:solab/core/database/database_installation_gate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'generated_schema/schema_v3.dart' show DatabaseAtV3;

void main() {
  test(
    'installation gate creates and validates only the current schema',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'kelivo_current_schema_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      await DatabaseInstallationGate.ensureReady(appDataDirectory: directory);

      final file = File(p.join(directory.path, AppDatabase.databaseFileName));
      final installed = ChatDatabaseRepository.inspectInstalledDatabase(file);
      expect(installed.schemaVersion, AppDatabase.currentSchemaVersion);
      expect(installed.databaseId, isNotEmpty);
    },
  );

  test(
    'installation gate rejects every unpublished SQLite schema without mutation',
    () async {
      // schema 1-8 已发布（旧版本打开时由 drift onUpgrade 迁移）；
      // 9+ 未发布，必须拒绝且不改动。
      for (final schemaVersion in <int>[9, 10, 11, 42]) {
        final directory = await Directory.systemTemp.createTemp(
          'kelivo_reject_schema_${schemaVersion}_',
        );
        addTearDown(() async {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        });
        final file = File(p.join(directory.path, AppDatabase.databaseFileName));
        final database = sqlite.sqlite3.open(file.path);
        database.execute('CREATE TABLE intermediate_only (value TEXT);');
        database.userVersion = schemaVersion;
        database.close();

        await expectLater(
          DatabaseInstallationGate.ensureReady(appDataDirectory: directory),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'database_schema_too_new',
            ),
          ),
        );

        final after = sqlite.sqlite3.open(
          file.path,
          mode: sqlite.OpenMode.readOnly,
        );
        try {
          expect(after.userVersion, schemaVersion);
          expect(
            after.select(
              "SELECT name FROM sqlite_master WHERE type='table' AND name=?;",
              ['intermediate_only'],
            ),
            hasLength(1),
          );
        } finally {
          after.close();
        }
      }
    },
  );

  test(
    'installed schema 1 is rejected when a business table is missing',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'kelivo_missing_business_table_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final file = File(p.join(directory.path, AppDatabase.databaseFileName));
      final database = AppDatabase.open(file: file);
      await database.customSelect('SELECT 1;').getSingle();
      await database.close();

      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP TABLE preference_rows;');
      raw.close();

      expect(
        () => ChatDatabaseRepository.inspectInstalledDatabase(file),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'required_tables',
          ),
        ),
      );
    },
  );

  test(
    'legacy schema 3 database passes pre-migration validation and upgrades',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'kelivo_schema3_upgrade_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final file = File(p.join(directory.path, AppDatabase.databaseFileName));

      // 用 v3 快照建 schema 3 库（prompt 表带 FK；打开即自动建表+索引，
      // 快照类 schemaVersion=3 自动写入 userVersion）。
      final legacy = DatabaseAtV3(NativeDatabase(file));
      await legacy.customSelect('SELECT 1;').getSingle();
      await legacy.close();
      final raw = sqlite.sqlite3.open(file.path);
      raw.userVersion = 3;
      raw.close();

      // 迁移前的只读校验必须放行旧库（schema 3 prompt 表带 FK，
      // 期望按版本分支，不得 foreign_key_schema）。
      await ChatDatabaseRepository.migrateInstalledDatabase(file);
      final inspected = ChatDatabaseRepository.inspectInstalledDatabase(file);
      expect(inspected.schemaVersion, 3);

      // 打开触发 drift onUpgrade 3→5。
      final app = AppDatabase.open(file: file);
      await app.customSelect('SELECT 1;').getSingle();
      await app.close();

      final after = sqlite.sqlite3.open(
        file.path,
        mode: sqlite.OpenMode.readOnly,
      );
      try {
        expect(after.userVersion, AppDatabase.currentSchemaVersion);
        // prompt 表已重建为无 FK；memory CHECK 已扩为 6 值。
        final promptFk = after.select(
          'SELECT * FROM pragma_foreign_key_list(\'message_prompt_rows\');',
        );
        expect(promptFk, isEmpty);
        final memorySql = after.select(
          "SELECT sql FROM sqlite_master WHERE type='table' "
          "AND name='memory_entry_rows';",
        );
        expect(
          memorySql.single.values.single.toString(),
          contains("'apk_patch'"),
        );
        // memory_entry_rows 的三个索引必须全部重建（迁移前校验 index_schema）。
        final indexes = after
            .select(
              "SELECT name FROM sqlite_master WHERE type='index' "
              "AND tbl_name='memory_entry_rows';",
            )
            .map((row) => row.values.single.toString())
            .toSet();
        expect(
          indexes,
          containsAll({
            'idx_memory_entries_visible',
            'idx_memory_entries_recent',
            'idx_memory_entries_dedupe',
          }),
        );
      } finally {
        after.close();
      }
    },
  );

  test(
    'schema 5 database missing memory indexes is repaired by schema 6',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'kelivo_schema5_repair_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final file = File(p.join(directory.path, AppDatabase.databaseFileName));

      // 先完整迁移到当前 schema，再删掉两个索引并把 userVersion 降回 5，
      // 模拟早期 schema-5 迁移留下的"部分迁移卡死"状态。
      final initial = AppDatabase.open(file: file);
      await initial.customSelect('SELECT 1;').getSingle();
      await initial.close();
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP INDEX idx_memory_entries_visible;');
      raw.execute('DROP INDEX idx_memory_entries_recent;');
      raw.userVersion = 5;
      raw.close();

      // 重新打开：from<6 幂等补索引（IF NOT EXISTS），userVersion 回到当前。
      final app = AppDatabase.open(file: file);
      await app.customSelect('SELECT 1;').getSingle();
      await app.close();

      final after = sqlite.sqlite3.open(
        file.path,
        mode: sqlite.OpenMode.readOnly,
      );
      try {
        expect(after.userVersion, AppDatabase.currentSchemaVersion);
        final indexes = after
            .select(
              "SELECT name FROM sqlite_master WHERE type='index' "
              "AND tbl_name='memory_entry_rows';",
            )
            .map((row) => row.values.single.toString())
            .toSet();
        expect(
          indexes,
          containsAll({
            'idx_memory_entries_visible',
            'idx_memory_entries_recent',
            'idx_memory_entries_dedupe',
          }),
        );
      } finally {
        after.close();
      }
    },
  );
}
