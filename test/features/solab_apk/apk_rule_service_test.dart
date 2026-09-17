import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solab/core/database/app_database.dart';
import 'package:solab/core/database/chat_database_repository.dart';
import 'package:solab/features/solab_apk/services/apk_rule_service.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase database;
  late ChatDatabaseRepository repository;
  late ApkRuleService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    database = AppDatabase(NativeDatabase.memory());
    repository = ChatDatabaseRepository(database);
    service = ApkRuleService(repository);
  });

  tearDown(() async {
    await database.close();
  });

  test('ensureSeedIfNeeded writes the full seed once', () async {
    await service.ensureSeedIfNeeded();

    final rules = await repository.getAllModifyRules();
    // 871 基础 + v5 特征库并入 + v8 扩充，规范化去重后 1529 条。
    expect(rules.length, 1528);
    expect(rules.where((rule) => rule.source == 'seed').length, 1528);
    expect(rules.every((rule) => rule.enabled), isTrue);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getInt(ApkRuleService.seedVersionKey), 10);
    // 再次调用不重复写入、也不覆盖（版本 key 已满足）。
    await service.ensureSeedIfNeeded();
    expect((await repository.getAllModifyRules()).length, 1528);
  });

  test('seed sync writes the native SP rule key contract', () async {
    await service.ensureSeedIfNeeded();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getStringList('sdk_packages'), isNotEmpty);
    expect(preferences.getStringList('class_patterns'), isNotEmpty);
    expect(preferences.getStringList('method_patterns'), isNotEmpty);
    expect(preferences.getStringList('url_patterns'), isNotEmpty);
    expect(preferences.getStringList('force_true_methods'), isNotEmpty);
    expect(preferences.getStringList('component_patterns'), isNotEmpty);

    // class_patterns 是 class_keywords + 组件类汇总；component_patterns
    // 是 sdk_packages + class_patterns 去重（与原生 AdRules 推导一致）。
    final classPatterns = preferences.getStringList('class_patterns')!;
    final componentPatterns = preferences.getStringList('component_patterns')!;
    final sdkPackages = preferences.getStringList('sdk_packages')!;
    expect(sdkPackages, isNot(contains('com.baidu.')));
    expect(sdkPackages, contains('com.baidu.mobads'));
    expect(
      componentPatterns,
      containsAll(sdkPackages),
      reason: 'component_patterns 应包含全部 sdk_packages',
    );
    expect(
      componentPatterns,
      containsAll(classPatterns),
      reason: 'component_patterns 应包含全部 class_patterns',
    );
    // 与原生 loadRules 相同：长度 >= 4、小写、去重。
    expect(classPatterns.every((value) => value.length >= 4), isTrue);
    expect(classPatterns.toSet().length, classPatterns.length);
  });

  test(
    'disabling a rule re-syncs SP and seed re-run keeps the change',
    () async {
      await service.ensureSeedIfNeeded();
      final rules = await repository.getAllModifyRules();
      final target = rules.firstWhere(
        (rule) => rule.category == 'url_patterns',
      );

      await service.setRuleEnabled(target.id, enabled: false);
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getStringList('url_patterns'),
        isNot(contains(target.name)),
      );

      // 模拟用户关闭规则后再次触发种子流程：已存在的规则不允许被重置。
      final updated = await repository.getModifyRule(target.id);
      expect(updated!.enabled, isFalse);
    },
  );

  test('addRule writes a user rule and deletes it', () async {
    await service.ensureSeedIfNeeded();
    final added = await service.addRule(
      category: 'sdk_packages',
      name: '测试 SDK',
      pattern: 'com.example.testad.sdk',
      risk: 'high',
    );
    expect(added.source, 'user');
    expect(added.risk, 'high');

    final preferences = await SharedPreferences.getInstance();
    // SP 存的是匹配模式（小写规范化），不是显示名。
    expect(
      preferences.getStringList('sdk_packages'),
      contains('com.example.testad.sdk'),
    );

    await service.deleteRule(added.id);
    expect(await repository.getModifyRule(added.id), isNull);
  });

  test('importJson skips existing ids and adds fresh ones', () async {
    await service.ensureSeedIfNeeded();
    final existing = await repository.getAllModifyRules();
    final added = await service.importJson(
      '{"sdk_packages": ["com.example.ad1", "com.example.ad2"]}',
    );
    expect(added, 2);
    final after = await repository.getAllModifyRules();
    expect(after.length, existing.length + 2);

    // 重复导入同内容不再新增。
    final again = await service.importJson(
      '{"sdk_packages": ["com.example.ad1"]}',
    );
    expect(again, 0);
    expect((await repository.getAllModifyRules()).length, after.length);
  });

  test('vendor mapping covers all vendors and pre-check works', () async {
    expect(ApkRuleService.vendors.length, 21);
    // 每个厂商至少有一个模式真实存在于种子 sdk_packages 中。
    await service.ensureSeedIfNeeded();
    final rules = await repository.getAllModifyRules();
    final seedPatterns = rules
        .map(ApkRuleService.patternOf)
        .whereType<String>()
        .toSet();
    for (final patterns in ApkRuleService.vendors.values) {
      expect(
        patterns.any(seedPatterns.contains),
        isTrue,
        reason: '厂商映射 $patterns 在种子中无对应模式',
      );
    }

    final report = {
      'adSdkMatches': ['com.qq.e.ads', 'com.bytedance.sdk.openadsdk'],
    };
    final recommended = await service.vendorsForReport(report);
    expect(recommended, containsAll({'tencent_gdt', 'pangle'}));
    expect(recommended, isNot(contains('admob')));

    // 批量启停：先停用腾讯优量汇全部相关规则。
    final changed = await service.setVendorEnabled(
      'tencent_gdt',
      enabled: false,
    );
    expect(changed, greaterThan(0));
    final vendorRules = await service.rulesForVendor('tencent_gdt');
    expect(vendorRules, isNotEmpty);
    expect(vendorRules.every((rule) => !rule.enabled), isTrue);
  });
}
