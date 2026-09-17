import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/providers/assistant_provider.dart';

import '../../support/business_preferences_test_harness.dart';

/// 内置 APK Mod 助手升级覆盖策略：
/// 用户编辑过（apk_mod_assistant_user_edited_v1=true）→ 升级不覆盖；
/// 未编辑 → 版本 key 低于当前时覆盖为最新模板。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BusinessPreferencesTestHarness harness;
  late BusinessPreferencesTestSession session;

  setUp(() async {
    harness = await BusinessPreferencesTestHarness.create();
    session = await harness.open();
  });

  tearDown(() => harness.dispose());

  Future<AssistantProvider> loadedProvider(
    List<Map<String, Object?>> assistants,
  ) async {
    await session.preferences.setString(
      'assistants_v1',
      jsonEncode(assistants),
    );
    final provider = AssistantProvider(preferences: session.preferences);
    for (
      var i = 0;
      i < 25 && provider.assistants.length != assistants.length;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return provider;
  }

  test('用户编辑过内置助手时：系统提示词升级为模板（v70 强制同步），其余配置保留', () async {
    const customPrompt = '用户自定义提示词，v69 及以前不被覆盖';
    final provider = await loadedProvider([
      {
        'id': AssistantProvider.apkModAssistantId,
        'name': 'APK Mod',
        'systemPrompt': customPrompt,
        'localToolIds': <String>['get_time_info'],
        'mcpServerIds': <String>['external-mt'],
      },
    ]);
    await session.preferences.setBool(
      'builtin_apk_mod_assistant_user_edited_v1',
      true,
    );
    await session.preferences.setInt('builtin_apk_mod_assistant_version', 30);

    await provider.ensureDefaults(null);

    final apkMod = provider.assistants.firstWhere(
      (a) => a.id == AssistantProvider.apkModAssistantId,
    );
    // v70 起：系统提示词被强制替换为最新模板（用户明确指定）。
    expect(apkMod.systemPrompt, isNot(customPrompt));
    expect(
      apkMod.systemPrompt,
      contains('You are SoLab, an Android APK reverse'),
    );
    // 内置助手只保留当前模板工具，避免旧入口继续残留。
    expect(
      apkMod.localToolIds,
      containsAll(const [
        'route_task',
        'get_current_apk_report',
        'analyze_apk_workspace',
        'so_patch_into_apk',
        'analyzer.global_search',
        'analyzer.find_field_usage',
        'analyzer.analyze_business_state',
        'ask_user_input_v0',
        'get_agent_runtime_guide',
        'get_solab_tool_map',
        'list_workspace_apks',
        'get_apk_project_info',
        'list_apk_builds',
      ]),
    );
    expect(apkMod.localToolIds, isNot(contains('get_time_info')));
    expect(apkMod.mcpServerIds, containsAll(['external-mt', 'solab_fetch']));
    expect(apkMod.thinkingBudget, -1);
  });

  test('用户未编辑过内置助手时，升级覆盖为最新模板', () async {
    final provider = await loadedProvider([
      {
        'id': AssistantProvider.apkModAssistantId,
        'name': 'APK Mod',
        'systemPrompt': '旧提示词',
        'localToolIds': <String>['get_time_info'],
      },
    ]);
    await session.preferences.setInt('builtin_apk_mod_assistant_version', 30);

    await provider.ensureDefaults(null);

    final apkMod = provider.assistants.firstWhere(
      (a) => a.id == AssistantProvider.apkModAssistantId,
    );
    expect(apkMod.systemPrompt, isNot('旧提示词'));
    expect(apkMod.limitContextMessages, isTrue);
    expect(apkMod.generateConversationSummary, isTrue);
    expect(apkMod.thinkingBudget, -1);
    // Phase 0：内置助手收敛为 analyzer.* 高阶 API（58 工具不再直接挂载）。
    expect(
      apkMod.localToolIds,
      containsAll(const [
        'analyzer.global_search',
        'analyzer.find_field_usage',
        'analyzer.analyze_business_state',
      ]),
    );
  });

  test('用户明确关闭思考时升级不覆盖', () async {
    final provider = await loadedProvider([
      {
        'id': AssistantProvider.apkModAssistantId,
        'name': 'APK Mod',
        'thinkingBudget': 0,
      },
    ]);
    await session.preferences.setInt('builtin_apk_mod_assistant_version', 88);

    await provider.ensureDefaults(null);

    final apkMod = provider.assistants.firstWhere(
      (a) => a.id == AssistantProvider.apkModAssistantId,
    );
    expect(apkMod.thinkingBudget, 0);
  });
}
