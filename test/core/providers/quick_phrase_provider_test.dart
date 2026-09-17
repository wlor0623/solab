import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/database/app_database.dart';
import 'package:solab/core/database/business_preferences.dart';
import 'package:solab/core/database/business_repository.dart';
import 'package:solab/core/models/quick_phrase.dart';
import 'package:solab/core/providers/quick_phrase_provider.dart';

void main() {
  late AppDatabase database;
  late QuickPhraseProvider provider;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    final repository = BusinessRepository(database);
    provider = QuickPhraseProvider(
      preferences: BusinessPreferences(repository),
    );
  });

  tearDown(() => database.close());

  test(
    'adds and deletes global and assistant quick phrases independently',
    () async {
      const global = QuickPhrase(
        id: 'global',
        title: '全局',
        content: 'global content',
      );
      const assistant = QuickPhrase(
        id: 'assistant',
        title: '助手',
        content: 'assistant content',
        isGlobal: false,
        assistantId: 'builtin-apk-mod',
      );

      await provider.add(global);
      await provider.add(assistant);

      expect(provider.globalPhrases.map((phrase) => phrase.id), ['global']);
      expect(
        provider.getForAssistant('builtin-apk-mod').map((phrase) => phrase.id),
        ['assistant'],
      );

      await provider.delete(assistant.id);

      expect(provider.globalPhrases.map((phrase) => phrase.id), ['global']);
      expect(provider.getForAssistant('builtin-apk-mod'), isEmpty);
    },
  );
}
