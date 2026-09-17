import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/database/app_database.dart';
import 'package:solab/core/database/business_preferences.dart';
import 'package:solab/core/database/business_repository.dart';
import 'package:solab/core/models/agent_skill.dart';
import 'package:solab/core/models/assistant.dart';
import 'package:solab/core/models/world_book.dart';
import 'package:solab/core/providers/agent_skill_provider.dart';
import 'package:solab/core/providers/instruction_injection_provider.dart';
import 'package:solab/core/providers/world_book_provider.dart';
import 'package:solab/core/services/local_tools/local_tool_names.dart';
import 'package:solab/core/services/memory/memory_repository.dart';
import 'package:solab/features/home/services/local_tools_service.dart';

void main() {
  test(
    'runtime guide exposes active agent capabilities without prompt text',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final preferences = BusinessPreferences(BusinessRepository(database));
      final worldBooks = WorldBookProvider(preferences: preferences);
      final skills = AgentSkillProvider(preferences: preferences);
      final injections = InstructionInjectionProvider(preferences: preferences);
      final memory = MemoryRepository(preferences);

      await worldBooks.addBook(
        const WorldBook(id: 'guide-book', name: 'APK 说明书'),
      );
      await worldBooks.setActiveBookIds(const [
        'guide-book',
      ], assistantId: 'builtin-apk-mod');
      await skills.initialize();
      await skills.save(
        const AgentSkill(id: 'guide-skill', name: '流程 Skill', enabled: true),
      );
      const assistant = Assistant(
        id: 'builtin-apk-mod',
        name: 'APK Mod',
        enableMemory: true,
        autoOrganizeMemory: true,
        localToolIds: [LocalToolNames.agentRuntimeGuide],
      );

      final raw = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.agentRuntimeGuide,
        const <String, dynamic>{},
        assistant,
        worldBookProvider: worldBooks,
        agentSkillProvider: skills,
        instructionInjectionProvider: injections,
        memoryRepository: memory,
      );

      final payload = jsonDecode(raw!) as Map<String, dynamic>;
      expect(payload['automatic']['memory']['enabled'], isTrue);
      expect(payload['onDemand']['worldBooks']['active'], contains('APK 说明书'));
      expect(payload['onDemand']['installedSkills']['enabledCount'], 1);
      expect(
        payload['automatic']['instructionInjections']['active'],
        isNotEmpty,
      );
      expect(payload['availableLocalToolCount'], greaterThanOrEqualTo(1));
      expect(
        payload['availableLocalTools'],
        contains(LocalToolNames.agentRuntimeGuide),
      );
      expect(jsonEncode(payload), isNot(contains('APK Mod 修改纪律：')));
      expect(payload['contextReadiness']['worldBooks']['loaded'], isTrue);
      expect(
        payload['contextReadiness']['instructionInjections']['promptChars'],
        greaterThan(0),
      );
      expect(
        payload['contextReadiness']['memory']['repositoryAvailable'],
        isTrue,
      );
      expect(
        payload['automatic']['memory']['memoryContentAutoInjected'],
        isFalse,
      );
    },
  );

  test('MCP 路由只推荐当前可调用工具并在首次调用前加载知识书', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final preferences = BusinessPreferences(BusinessRepository(database));
    final worldBooks = WorldBookProvider(preferences: preferences);
    await worldBooks.addBook(
      const WorldBook(
        id: 'mcp-route-book',
        name: 'MCP 路由知识',
        entries: <WorldBookEntry>[
          WorldBookEntry(
            id: 'flutter-route',
            name: 'Flutter 精确提示',
            priority: 100,
            keywords: <String>['Flutter', 'Blutter'],
            content: '只读取能改变 Flutter 定位判断的证据。',
          ),
        ],
      ),
    );
    await worldBooks.setActiveBookIds(const <String>[
      'mcp-route-book',
    ], assistantId: 'builtin-apk-mod');
    const mcpAssistant = Assistant(
      id: 'builtin-apk-mod',
      name: 'MCP',
      localToolIds: <String>[
        LocalToolNames.routeTask,
        LocalToolNames.soAnalyze,
      ],
    );

    final raw = await LocalToolsService.tryHandleToolCall(
      LocalToolNames.routeTask,
      const <String, dynamic>{'goal': '分析 Flutter libapp'},
      mcpAssistant,
      worldBookProvider: worldBooks,
    );
    final payload = jsonDecode(raw!) as Map<String, dynamic>;
    final tools = (payload['recommendedTools'] as List).cast<String>();

    expect(payload['modeCapabilities']['mode'], 'mcp');
    expect(tools, <String>[LocalToolNames.soAnalyze]);
    expect(tools, isNot(contains(LocalToolNames.apkKnowledge)));
    expect(tools, isNot(contains(LocalToolNames.installedSkills)));
    expect(payload['prefetchedKnowledge']['top']['entryName'], 'Flutter 精确提示');
  });

  test(
    'Agent route activates built-in task skills without a second read',
    () async {
      const assistant = Assistant(
        id: 'builtin-apk-mod',
        name: 'Agent',
        localToolIds: <String>[
          LocalToolNames.routeTask,
          LocalToolNames.apkSkill,
        ],
      );

      final raw = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.routeTask,
        const <String, dynamic>{'goal': '修改 Flutter 会员等级逻辑'},
        assistant,
      );
      final payload = jsonDecode(raw!) as Map<String, dynamic>;
      final active = (payload['activeBuiltInSkills'] as List)
          .whereType<Map>()
          .map((skill) => skill['id'])
          .toSet();

      expect(
        active,
        containsAll(<String>{
          'apk_change_plan',
          'apk_apply_patch',
          'apk_flutter_locate',
          'flutter_vip_unlock',
        }),
      );
      expect(payload['skillInstruction'], contains('已在本轮生效'));
      expect(raw.length, lessThan(16000));
    },
  );
}
