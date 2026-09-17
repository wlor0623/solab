import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/database/app_database.dart';
import 'package:solab/core/database/business_preferences.dart';
import 'package:solab/core/database/business_repository.dart';
import 'package:solab/core/models/assistant.dart';
import 'package:solab/core/models/world_book.dart';
import 'package:solab/core/providers/world_book_provider.dart';
import 'package:solab/core/services/local_tools/local_tool_names.dart';
import 'package:solab/features/home/services/local_tools_service.dart';
import 'package:solab/features/home/services/tool_session_state.dart';

void main() {
  late AppDatabase database;
  late WorldBookProvider provider;

  setUp(() {
    ToolSessionState.resetForTest();
    database = AppDatabase(NativeDatabase.memory());
    provider = WorldBookProvider(
      preferences: BusinessPreferences(BusinessRepository(database)),
    );
  });

  tearDown(() => database.close());

  test(
    'APK knowledge tool returns only active entries relevant to routed topics',
    () async {
      await provider.addBook(
        const WorldBook(
          id: 'apk-knowledge',
          name: '测试知识',
          entries: [
            WorldBookEntry(
              id: 'ad-entry',
              name: '广告定位',
              keywords: ['广告', '定位'],
              content: '先找广告初始化入口。',
            ),
            WorldBookEntry(
              id: 'disabled-entry',
              name: '不可用条目',
              enabled: false,
              keywords: ['广告'],
              content: '不应返回。',
            ),
            WorldBookEntry(
              id: 'always-entry',
              name: '常驻检查项',
              constantActive: true,
              content: '每次 APK 任务都先核对工作目录。',
            ),
          ],
        ),
      );
      await provider.setActiveBookIds(const [
        'apk-knowledge',
      ], assistantId: 'builtin-apk-mod');

      const assistant = Assistant(
        id: 'builtin-apk-mod',
        name: 'APK Mod',
        localToolIds: [LocalToolNames.apkKnowledge],
      );
      final raw = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.apkKnowledge,
        const {
          'topics': ['广告', '定位'],
          'maxEntries': 3,
        },
        assistant,
        worldBookProvider: provider,
      );

      final payload = jsonDecode(raw!) as Map<String, dynamic>;
      final entries = payload['entries'] as List;
      expect(entries, isNotEmpty);
      expect(entries.map((entry) => entry['entryId']), contains('ad-entry'));
      expect(
        entries.map((entry) => entry['entryId']),
        contains('always-entry'),
      );
      expect(
        entries.map((entry) => entry['entryId']),
        isNot(contains('disabled-entry')),
      );
    },
  );

  test('generic route topics only return always-active entries', () async {
    await provider.addBook(
      const WorldBook(
        id: 'generic-knowledge',
        name: '测试知识',
        entries: [
          WorldBookEntry(
            id: 'ordinary-entry',
            name: 'APK 说明',
            keywords: ['APK'],
            content: '不应因路由通用词自动读取。',
          ),
          WorldBookEntry(
            id: 'always-entry',
            name: '常驻检查项',
            constantActive: true,
            content: '常驻条目可读取。',
          ),
        ],
      ),
    );
    await provider.setActiveBookIds(const [
      'generic-knowledge',
    ], assistantId: 'builtin-apk-mod');

    final entries = provider.retrieveActiveEntries(
      assistantId: 'builtin-apk-mod',
      topics: const ['APK', '工作流', '规则'],
    );

    expect(entries.map((entry) => entry['entryId']), ['always-entry']);
  });

  test(
    'APK knowledge skips the entry already prefetched by route_task',
    () async {
      await provider.addBook(
        const WorldBook(
          id: 'prefetch-knowledge',
          name: '测试知识',
          entries: [
            WorldBookEntry(
              id: 'first-entry',
              name: '首条知识',
              keywords: ['广告'],
              content: '已在路由中附带。',
            ),
            WorldBookEntry(
              id: 'second-entry',
              name: '后续知识',
              keywords: ['广告'],
              content: '应由知识工具返回。',
            ),
          ],
        ),
      );
      await provider.setActiveBookIds(const [
        'prefetch-knowledge',
      ], assistantId: 'builtin-apk-mod');
      const assistant = Assistant(
        id: 'builtin-apk-mod',
        name: 'APK Mod',
        localToolIds: [LocalToolNames.apkKnowledge],
      );
      ToolSessionState.recordPrefetchedKnowledge(
        'conversation:route-1',
        '首条知识',
      );

      final raw = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.apkKnowledge,
        const {
          'topics': ['广告'],
          'maxEntries': 3,
        },
        assistant,
        worldBookProvider: provider,
        conversationId: 'route-1',
      );

      final payload = jsonDecode(raw!) as Map<String, dynamic>;
      final names = (payload['entries'] as List)
          .map((entry) => entry['entryName'])
          .toList();
      expect(names, isNot(contains('首条知识')));
      expect(names, contains('后续知识'));
    },
  );

  test(
    'system knowledge book is not confused with a user book of the same name',
    () async {
      await provider.addBook(
        const WorldBook(id: 'user-book', name: 'SoLab 知识书'),
      );

      await provider.ensureApkModSeed();

      expect(provider.getById('apk_mod_knowledge_book'), isNotNull);
      expect(
        provider.activeBookIdsFor('builtin-apk-mod'),
        contains('apk_mod_knowledge_book'),
      );
      final entries = provider.getById('apk_mod_knowledge_book')!.entries;
      expect(
        entries.map((entry) => entry.id),
        containsAll([
          'apk_mod_entry_workspace_output',
          'apk_mod_entry_flutter_system_identification',
        ]),
      );
      expect(
        entries
            .firstWhere(
              (entry) => entry.id == 'apk_mod_entry_risk_and_signature',
            )
            .content,
        contains('任何业务修改之前'),
      );
      expect(
        entries
            .firstWhere((entry) => entry.id == 'apk_mod_entry_no_budget')
            .content,
        allOf(contains('没有固定调用次数'), contains('软提示')),
      );
      expect(
        entries
            .firstWhere((entry) => entry.id == 'apk_mod_entry_multi_signal')
            .content,
        contains('直接表达目标行为时可单点定案'),
      );
      expect(
        entries
            .firstWhere((entry) => entry.id == 'apk_mod_entry_relentless_goal')
            .content,
        allOf(contains('本地消费点'), contains('禁止为了“顺手清理”扩大改动面')),
      );
      expect(
        entries
            .firstWhere(
              (entry) => entry.id == 'apk_mod_entry_detection_evasion',
            )
            .content,
        contains('当前 patch_apk_dex_methods schema'),
      );
    },
  );
}
