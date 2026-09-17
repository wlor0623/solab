import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/database/app_database.dart';
import 'package:solab/core/database/business_preferences.dart';
import 'package:solab/core/database/business_repository.dart';
import 'package:solab/core/models/agent_skill.dart';
import 'package:solab/core/models/assistant.dart';
import 'package:solab/core/providers/agent_skill_provider.dart';
import 'package:solab/core/services/local_tools/local_tool_names.dart';
import 'package:solab/features/home/services/local_tools_service.dart';

void main() {
  late AppDatabase database;
  late AgentSkillProvider provider;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    provider = AgentSkillProvider(
      preferences: BusinessPreferences(BusinessRepository(database)),
    );
  });

  tearDown(() => database.close());

  test(
    'installed skills tool returns enabled matching package content',
    () async {
      await provider.initialize();
      await provider.save(
        const AgentSkill(
          id: 'ads',
          name: '广告 Skill',
          topics: ['广告'],
          content: '先检查初始化入口。',
        ),
      );
      const assistant = Assistant(
        id: 'builtin-apk-mod',
        name: 'APK Mod',
        localToolIds: [LocalToolNames.installedSkills],
      );

      final raw = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.installedSkills,
        const {
          'topics': ['广告'],
        },
        assistant,
        agentSkillProvider: provider,
      );

      final payload = jsonDecode(raw!) as Map<String, dynamic>;
      expect(payload['returned'], 1);
      expect((payload['skills'] as List).single['content'], '先检查初始化入口。');
    },
  );

  test(
    'route task automatically activates a relevant installed Skill',
    () async {
      await provider.save(
        const AgentSkill(
          id: 'vip-route',
          name: 'VIP 定位 Skill',
          topics: ['VIP'],
          content: '先检查会员等级字段的真实读取处。',
        ),
      );
      const assistant = Assistant(
        id: 'builtin-apk-mod',
        name: 'APK Mod',
        localToolIds: [
          LocalToolNames.routeTask,
          LocalToolNames.installedSkills,
        ],
      );

      final raw = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.routeTask,
        const {'goal': '分析会员等级逻辑'},
        assistant,
        agentSkillProvider: provider,
      );
      final payload = jsonDecode(raw!) as Map<String, dynamic>;
      final active = payload['activeInstalledSkills'] as List;

      expect(active, hasLength(1));
      expect((active.single as Map)['id'], 'vip-route');
      expect(payload['installedSkillInstruction'], contains('已在本轮生效'));
    },
  );
}
