import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solab/core/database/app_database.dart';
import 'package:solab/core/database/business_preferences.dart';
import 'package:solab/core/database/business_repository.dart';
import 'package:solab/core/providers/settings_provider.dart';
import 'package:solab/core/services/memory/memory_prompts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('v4 compaction preserves a user-edited v3 prompt', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final preferences = BusinessPreferences(BusinessRepository(database));
    await preferences.setInt('memory_prompt_contract_version_v1', 3);
    await preferences.setString('memory_rules_prompt_zh_v1', '用户自定义记忆规则');

    final settings = SettingsProvider(preferences);
    await settings.loaded;

    expect(settings.memoryRulesPromptZh, '用户自定义记忆规则');
    expect(settings.memoryRulesPromptEn, MemoryPrompts.rulesEn);
  });
}
