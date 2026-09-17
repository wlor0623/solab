import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/database/app_database.dart';
import 'package:solab/core/database/chat_database_repository.dart';
import 'package:solab/features/solab_apk/services/apk_project_service.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase database;
  late ChatDatabaseRepository repository;
  late ApkProjectService service;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    repository = ChatDatabaseRepository(database);
    service = ApkProjectService(repository);
  });

  tearDown(() async {
    await database.close();
  });

  Map<String, dynamic> report({
    String? sha256,
    String packageName = 'com.example.app',
    String versionName = '1.2.3',
    int versionCode = 123,
    int analysisVersion = 4,
  }) => {
    'sha256': sha256 ?? 'a' * 64,
    'fileName': 'app-$versionName.apk',
    'packageName': packageName,
    'versionName': versionName,
    'versionCode': versionCode,
    'certificateSha256': 'b' * 64,
    'analysisVersion': analysisVersion,
  };

  test('saves a project and reuses it by SHA-256', () async {
    final first = await service.saveProjectFromReport(
      report(),
      sourcePath: '/tmp/app.apk',
    );
    final second = await service.saveProjectFromReport(
      report(),
      sourcePath: '/tmp/other/path.apk',
    );

    expect(first.id, second.id, reason: '同一 SHA-256 应复用项目');
    expect(await service.findBySha256('a' * 64), isNotNull);
    expect((await service.findBySha256('a' * 64))!.id, first.id);
    expect(first.packageName, 'com.example.app');
    expect(first.apkSha256, 'a' * 64);
    expect(first.sourcePath, '/tmp/app.apk', reason: '首次路径保留');
  });

  test('different SHA-256 creates separate projects', () async {
    final first = await service.saveProjectFromReport(
      report(sha256: 'a' * 64),
      sourcePath: '/tmp/a.apk',
    );
    final second = await service.saveProjectFromReport(
      report(sha256: 'c' * 64),
      sourcePath: '/tmp/b.apk',
    );

    expect(first.id, isNot(second.id));
    expect(await service.listProjects(), hasLength(2));
  });

  test('reanalysis of a replaced file keeps the project ID', () async {
    final first = await service.saveProjectFromReport(
      report(sha256: 'a' * 64),
      sourcePath: '/tmp/app.apk',
    );
    final refreshed = await service.saveProjectFromReport(
      report(sha256: 'c' * 64, versionName: '2.0.0'),
      sourcePath: '/tmp/app.apk',
    );

    expect(refreshed.id, first.id);
    expect(refreshed.apkSha256, 'c' * 64);
    expect(await service.listProjects(), hasLength(1));
  });

  test('links a conversation and finds project by conversation', () async {
    final project = await service.saveProjectFromReport(
      report(),
      sourcePath: '/tmp/app.apk',
      conversationId: 'conv-1',
    );
    await service.linkConversation(project.id, 'conv-2');

    final updated = await service.getProject(project.id);
    expect(updated!.conversationId, 'conv-2');
    expect((await service.findByConversation('conv-2'))!.id, project.id);
    expect(await service.findByConversation('missing'), isNull);
  });

  test('project info for AI is compact and stable', () async {
    final project = await service.saveProjectFromReport(
      report(),
      sourcePath: '/tmp/app.apk',
    );
    final info = service.projectInfoForAi(project);

    expect(info['projectId'], project.id);
    expect(info['packageName'], 'com.example.app');
    expect(info['apkSha256'], 'a' * 64);
    expect(info.containsKey('sourcePath'), isFalse);
    expect(info['analysisVersion'], 4);
    expect(info['ruleSetVersion'], 1);
  });

  test('empty report fields degrade gracefully', () async {
    final project = await service.saveProjectFromReport({
      'sha256': 'd' * 64,
    }, sourcePath: '/tmp/unknown.apk');
    expect(project.packageName, isNull);
    expect(project.versionCode, isNull);
    expect(project.fileName, isEmpty);
  });
}
