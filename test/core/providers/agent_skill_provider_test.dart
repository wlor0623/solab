import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/database/app_database.dart';
import 'package:solab/core/database/business_preferences.dart';
import 'package:solab/core/database/business_repository.dart';
import 'package:solab/core/models/agent_skill.dart';
import 'package:solab/core/providers/agent_skill_provider.dart';

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

  test('retrieves only enabled skills matching routed topics', () async {
    await provider.initialize();
    await provider.save(
      const AgentSkill(
        id: 'ads',
        name: '广告定位',
        topics: ['广告', '定位'],
        content: '先定位上游入口。',
      ),
    );
    await provider.save(
      const AgentSkill(
        id: 'disabled',
        name: '禁用',
        enabled: false,
        topics: ['广告'],
        content: '不可读取。',
      ),
    );

    expect(provider.retrieve(topics: const ['广告']).map((skill) => skill.id), [
      'ads',
    ]);
  });

  test('does not retrieve skills from generic route topics alone', () async {
    await provider.initialize();
    await provider.save(
      const AgentSkill(
        id: 'generic',
        name: 'APK 通用说明',
        topics: ['APK'],
        content: '不应因路由通用词自动读取。',
      ),
    );

    expect(provider.retrieve(topics: const ['APK', '工作流', '规则']), isEmpty);
  });

  test('matches Chinese routed topics to equivalent Skill tags', () async {
    await provider.save(
      const AgentSkill(
        id: 'vip-skill',
        name: '会员定位',
        topics: ['VIP'],
        content: '读取会员状态。',
      ),
    );

    expect(provider.retrieve(topics: const ['会员']).map((skill) => skill.id), [
      'vip-skill',
    ]);
  });

  test(
    'save before explicit initialize keeps existing stored skills',
    () async {
      await provider.save(
        const AgentSkill(id: 'first', name: '一', content: '一'),
      );
      final secondProvider = AgentSkillProvider(
        preferences: BusinessPreferences(BusinessRepository(database)),
      );

      await secondProvider.save(
        const AgentSkill(id: 'second', name: '二', content: '二'),
      );

      expect(secondProvider.skills.map((skill) => skill.id), [
        'first',
        'second',
      ]);
    },
  );
}
