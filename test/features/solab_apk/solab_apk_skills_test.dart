import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/models/assistant.dart';
import 'package:solab/core/services/local_tools/local_tool_names.dart';
import 'package:solab/features/solab_apk/services/solab_apk_skills.dart';
import 'package:solab/features/home/services/local_tools_service.dart';

void main() {
  test('reverse playbook exposes mapped rules and verification boundaries', () {
    final payload = jsonDecode(
      SolabApkSkills.read('apk_reverse_playbook'),
    ) as Map<String, dynamic>;

    expect(payload['source'], '逆向工程核心思路与正则规则集.md');
    expect(payload['ruleMapping']['会员'], contains('force_true_methods'));
    expect(payload['engineSignals']['Flutter'], isNotEmpty);
    expect(payload['guardrails'], isNotEmpty);
  });

  test(
    'Flutter skill classifies the system before locating numeric values',
    () {
      expect(SolabApkSkills.skillNames, contains('apk_flutter_locate'));

      final payload = jsonDecode(
        SolabApkSkills.read('apk_flutter_locate'),
      ) as Map<String, dynamic>;
      final steps = (payload['steps'] as List).join('\n');

      expect(steps, contains('pp.txt'));
      expect(steps, contains('values/汇编立即数'));
      expect(steps, contains('500 条结果'));
    },
  );

  test('Flutter patch skill writes the rebuilt SO back into the APK', () {
    final payload = jsonDecode(
      SolabApkSkills.read('flutter_vip_unlock'),
    ) as Map<String, dynamic>;
    final steps = (payload['steps'] as List).join('\n');

    expect(steps, contains('so_patch_into_apk'));
    expect(steps, contains('自由编排'));
    expect(steps, contains('一条直接行为证据足够'));
    expect(steps, isNot(contains('必须三类信号同时成立')));
  });

  test('逆向工具说明允许独立起步和自由组合', () {
    const assistant = Assistant(
      id: 'apk-flex',
      name: 'APK Flex',
      localToolIds: <String>[
        LocalToolNames.dexSearch,
        LocalToolNames.classOutline,
        LocalToolNames.smaliRead,
        LocalToolNames.soAnalyze,
        LocalToolNames.routeTask,
      ],
    );
    final descriptions =
        LocalToolsService.buildToolDefinitions(
              assistant: assistant,
              supportsTools: true,
            )
            .map((tool) => (tool['function'] as Map)['description'].toString())
            .join('\n');

    expect(descriptions, contains('可独立'));
    expect(descriptions, contains('不是固定'));
    expect(descriptions, contains('无需补齐固定前置链'));
  });

  test(
    'patch skill keeps signature compatibility opt-in and standalone',
    () {
      final payload = jsonDecode(
        SolabApkSkills.read('apk_apply_patch'),
      ) as Map<String, dynamic>;
      final steps = (payload['steps'] as List).join('\n');

      expect(steps, contains('除非用户要求跳过或工作台设为不开启'));
      expect(steps, contains('未指定时跟随 APK 工作台设置'));
      expect(steps, contains('signatureBypass=false'));
      expect(steps, contains('禁止在已修改 APK 上补做'));
    },
  );

  // 防漂移：get_solab_skill 的 schema enum 直接引用 skillNames 生成，
  // 断言注册表中每个 skill 都可被读取且出现在工具 schema enum 里。
  test('skill schema enum covers every registered skill name', () {
    const assistant = Assistant(
      id: 'apk',
      name: 'APK Mod',
      localToolIds: [LocalToolNames.apkSkill],
    );
    final tool =
        LocalToolsService.buildToolDefinitions(
              assistant: assistant,
              supportsTools: true,
            ).first['function']
            as Map;
    final enumValues =
        tool['parameters']['properties']['skill']['enum'] as List;

    expect(enumValues, SolabApkSkills.skillNames);
    for (final name in SolabApkSkills.skillNames) {
      expect(SolabApkSkills.read(name), isNotEmpty);
    }
  });

  test('every built-in skill exposes an active routed summary', () {
    expect(
      SolabApkSkills.activationHints.keys.toSet(),
      SolabApkSkills.skillNames.toSet(),
    );
    expect(
      SolabApkSkills.activationRules.keys.toSet(),
      SolabApkSkills.skillNames.toSet(),
    );
    for (final name in SolabApkSkills.skillNames) {
      final activation = SolabApkSkills.activation(name)!;
      expect(activation['id'], name);
      expect(activation['trigger'], isNotEmpty);
      expect(activation['rules'], isNotEmpty);
      final full = jsonDecode(SolabApkSkills.read(name)) as Map;
      expect(full['activation']['status'], 'active');
    }
  });
}
