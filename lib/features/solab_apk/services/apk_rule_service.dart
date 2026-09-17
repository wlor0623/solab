import 'dart:convert';
import 'dart:io';

import 'package:solab/core/database/app_database.dart';
import 'package:solab/core/database/chat_database_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/ad_rules_default_data.dart';
import 'apk_structural_service.dart';

/// SoLab APK 规则库服务。
///
/// 数据流：
/// - 种子数据（ad_rules_default.json，12 类 716 条）在首次打开规则库时写入
///   drift 表 `modify_rule_rows`（只补缺失 id，不覆盖用户已改过的规则），
///   并同步写 SharedPreferences 规则 key；
/// - SharedPreferences key 契约与原生 SolabChannel.loadRules() 的 AdRules
///   语义一致（下划线风格）：`sdk_packages` / `class_patterns` /
///   `method_patterns` / `url_patterns` / `force_true_methods` /
///   `component_patterns`，其中 `class_patterns` 由 class_keywords +
///   ad_view_names + ad_activities + ad_services + ad_receivers 汇总，
///   `component_patterns` 由 sdk_packages + class_patterns 去重汇总；
/// - UI 任何修改（启停 / 新增 / 导入）后调用 [syncRulesToPreferences]
///   把启用中的规则写回 SP，原生侧无需改动；
/// - hitCount / successCount / failureCount 为暂存统计，供后续分析回写。
class ApkRuleService {
  ApkRuleService(this._repository);

  final ChatDatabaseRepository _repository;

  /// 种子写入版本 key：SP 中该值 < [seedVersion] 才会重新写入种子。
  static const seedVersionKey = 'apk_mod_rules_seed_version';
  static const seedVersion = 10;

  /// 与原生 SolabChannel 约定的 SP 规则 key（下划线风格）。
  static const preferenceRuleKeys = <String>[
    'sdk_packages',
    'class_patterns',
    'method_patterns',
    'url_patterns',
    'force_true_methods',
    'component_patterns',
  ];

  /// 12 类规则 key（与 ad_rules_default.json / 原生 loadRules 读取顺序一致）。
  static const categoryKeys = adRulesDefaultCategories;

  static const categoryLabels = <String, String>{
    'sdk_packages': 'SDK 包',
    'class_keywords': '类关键词',
    'method_patterns': '方法模式',
    'url_patterns': 'URL 模式',
    'ad_view_names': '广告视图名',
    'ad_activities': '广告 Activity',
    'ad_services': '广告 Service',
    'ad_receivers': '广告 Receiver',
    'force_true_methods': '会员方法（force true）',
    'ad_key_strings': '广告关键字符串',
    'ad_asset_files': '广告资源文件',
    'ad_permissions': '广告权限',
    'detection_vpn': 'VPN 检测关键词',
    'detection_emulator': '模拟器检测关键词',
    'detection_root': 'Root 检测关键词',
    'detection_debug': '反调试关键词',
    'time_methods': '时间劫持方法',
    'shell_signatures': '壳特征（libxxx.so=壳名）',
    'ad_asset_paths': '资产路径（ad_asset_paths）',
    'lib_file_keywords': '广告 SO 库名',
    'asset_keywords': '资产文件名关键词',
    'method_neutralize_keywords': '方法中性化词',
    'root_file_keywords': '根目录文件关键词',
    'res_layout_keywords': '布局文件名关键词',
    'force_false_methods': '广告方法（force false）',
    'flutter_string_patterns': 'Flutter AOT 广告字符串',
  };

  /// 种子规则默认风险：参与改包的匹配模式标为 medium，纯识别标为 low。
  static const _categoryRisk = <String, String>{
    'method_patterns': 'medium',
    'force_true_methods': 'medium',
    'ad_key_strings': 'medium',
    'ad_asset_files': 'medium',
    'ad_permissions': 'medium',
    'detection_vpn': 'medium',
    'detection_emulator': 'medium',
    'detection_root': 'medium',
    'detection_debug': 'medium',
    'time_methods': 'medium',
    'lib_file_keywords': 'medium',
    'asset_keywords': 'medium',
    'method_neutralize_keywords': 'low',
    'res_layout_keywords': 'low',
    'force_false_methods': 'medium',
    'flutter_string_patterns': 'low',
  };

  /// 14 家厂商 → sdk_packages 子集（按种子数据中实际存在的模式整理）。
  static const vendors = <String, List<String>>{
    'tencent_gdt': [
      'com.qq.e.ads',
      'com.qq.e.comm',
      'com.qq.e.union',
      'com.tencent.qqads',
      'com.gdt.ad',
    ],
    'pangle': [
      'com.bytedance.sdk.openadsdk',
      'com.bytedance.pangle',
      'com.pangle.ads',
      'com.bytedance.applog',
      'com.volcengine.onekit',
      'com.bykv.vk',
      'com.byted',
    ],
    'kuaishou': ['com.kuaishou.ad', 'com.kuaishou.sdk.ad', 'com.kwad.sdk'],
    'baidu': ['com.baidu.mobads', 'com.baidu.mobad', 'com.baidu.mobstat'],
    'sigmob': ['com.sigmob.sdk', 'com.sigmob.ads'],
    'miui': ['com.miui.zeus.mimo', 'com.xiaomi.ad'],
    'mintegral': [
      'com.mintegral.msdk',
      'com.mintegral.msdk.out',
      'com.mobvista.msdk',
      'com.mobvista.ads',
    ],
    'admob': [
      'com.google.android.gms.ads',
      'com.google.android.gms.ad',
      'com.google.ads',
      'com.google.android.ads',
      'com.admob.android.ads',
      'com.google.firebase.firebase_ads',
      'com.google.android.ump',
      'com.google.android.gms.measurement',
      'com.google.gms',
    ],
    'cas': ['com.cleversolutions.ads'],
    'taptap': ['com.taptap.ad', 'com.tdc.ads', 'com.oneway.ads'],
    'topon': [
      'com.topon.sdk',
      'com.topon.ads',
      'com.anythink.sdk',
      'com.anythink.core',
    ],
    'beizi': ['com.beizi.ad'],
    'jd_ad': ['com.jd.ad.sdk', 'com.jd.ad'],
    'moqi': ['com.moqi.sdk'],
    // B3：补充特征库存在但映射表缺失的厂商——否则这些厂商的 DEX/Manifest
    // 命中永远进不了 vendorSignals，报告与规则库口径脱节
    'yandex': ['com.yandex.mobile.ads'],
    'ironsource': ['com.ironsource.mediationsdk', 'com.ironsource.sdk'],
    'applovin': ['com.applovin.sdk', 'com.applovin.adview'],
    'unityads': ['com.unity3d.ads', 'com.unity3d.services.ads'],
    'vungle': ['com.vungle.ads', 'com.vungle.warren'],
    'mopub': ['mopub.com'],
    'chartboost': ['com.chartboost.sdk'],
  };

  static const vendorLabels = <String, String>{
    'tencent_gdt': '腾讯优量汇',
    'pangle': '穿山甲',
    'kuaishou': '快手',
    'baidu': '百度联盟',
    'sigmob': 'Sigmob',
    'miui': '小米',
    'mintegral': 'Mintegral',
    'admob': 'Google AdMob',
    'cas': 'CAS',
    'taptap': 'TapTap',
    'topon': 'TopOn',
    'beizi': '贝兹',
    'jd_ad': '京东广告',
    'moqi': '魔奇',
    'yandex': 'Yandex Ads',
    'ironsource': 'ironSource',
    'applovin': 'AppLovin',
    'unityads': 'Unity Ads',
    'vungle': 'Vungle',
    'mopub': 'MoPub',
    'chartboost': 'Chartboost',
  };

  /// 稳定规则 ID：种子/导入为 `"<category>:<pattern>"`，用户新增同规则复用
  /// 同一 ID（内容相同的导入自动跳过）。
  static String ruleIdFor(String category, String pattern) =>
      '$category:${pattern.trim().toLowerCase()}';

  /// 从 matcherJson 取回单条模式文本；非单模式条目返回 null。
  static String? patternOf(ModifyRuleRow rule) {
    try {
      final decoded = jsonDecode(rule.matcherJson);
      if (decoded is Map && decoded['pattern'] is String) {
        return decoded['pattern'] as String;
      }
    } catch (_) {}
    return null;
  }

  /// 首次打开规则库时调用：种子版本 < [seedVersion] 才写入种子并同步 SP。
  /// 只补缺失的规则 id，已存在的行（含用户改过的）原样保留。
  Future<void> ensureSeedIfNeeded() async {
    final preferences = await SharedPreferences.getInstance();
    final installedVersion = preferences.getInt(seedVersionKey) ?? 0;
    if (installedVersion >= seedVersion) return;

    if (installedVersion < 10) {
      final retiredId = ruleIdFor('sdk_packages', 'com.baidu.');
      final retired = await _repository.getModifyRule(retiredId);
      if (retired?.source == 'seed') {
        await _repository.deleteModifyRule(retiredId);
      }
    }

    final seed = _parseSeed();
    final now = DateTime.now();
    final rows = <ModifyRuleRow>[];
    for (final category in categoryKeys) {
      final patterns = seed[category] ?? const <dynamic>[];
      final risk = _categoryRisk[category] ?? 'low';
      for (final raw in patterns) {
        final pattern = raw.toString().trim().toLowerCase();
        if (pattern.isEmpty) continue;
        rows.add(
          ModifyRuleRow(
            id: ruleIdFor(category, pattern),
            name: pattern,
            category: category,
            matcherJson: jsonEncode({'type': category, 'pattern': pattern}),
            enabled: true,
            source: 'seed',
            risk: risk,
            hitCount: 0,
            successCount: 0,
            failureCount: 0,
            version: 0,
            updatedAt: now,
          ),
        );
      }
    }
    if (rows.isNotEmpty) {
      await _repository.putModifyRules(rows);
    }
    await syncRulesToPreferences();
    await preferences.setInt(seedVersionKey, seedVersion);
  }

  /// 把启用中的规则按原生契约汇总写入 SP 的 6 个规则 key。
  /// 与原生 loadRules 相同地过滤：trim、lowercase、长度 >= 4、去重。
  Future<void> syncRulesToPreferences() async {
    final rules = await _repository.getAllModifyRules();
    final enabled = rules.where((rule) => rule.enabled).toList();
    final byCategory = <String, List<String>>{};
    for (final rule in enabled) {
      final pattern = patternOf(rule) ?? rule.name;
      byCategory.putIfAbsent(rule.category, () => []).add(pattern);
    }
    List<String> normalized(List<String> patterns) {
      final result = <String>[];
      for (final raw in patterns) {
        final value = raw.trim().toLowerCase();
        if (value.length >= 4 && !result.contains(value)) {
          result.add(value);
        }
      }
      return result;
    }

    List<String> combine(List<List<String>> groups) {
      final merged = <String>[];
      for (final group in groups) {
        for (final value in normalized(group)) {
          if (!merged.contains(value)) merged.add(value);
        }
      }
      return merged;
    }

    final classPatterns = combine([
      byCategory['class_keywords'] ?? const [],
      byCategory['ad_view_names'] ?? const [],
      byCategory['ad_activities'] ?? const [],
      byCategory['ad_services'] ?? const [],
      byCategory['ad_receivers'] ?? const [],
    ]);
    final sdkPackages = normalized(byCategory['sdk_packages'] ?? const []);
    final componentPatterns = combine([sdkPackages, classPatterns]);

    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList('sdk_packages', sdkPackages);
    await preferences.setStringList('class_patterns', classPatterns);
    await preferences.setStringList(
      'method_patterns',
      normalized(byCategory['method_patterns'] ?? const []),
    );
    await preferences.setStringList(
      'url_patterns',
      normalized(byCategory['url_patterns'] ?? const []),
    );
    await preferences.setStringList(
      'force_true_methods',
      normalized(byCategory['force_true_methods'] ?? const []),
    );
    await preferences.setStringList(
      'force_false_methods',
      normalized(byCategory['force_false_methods'] ?? const []),
    );
    await preferences.setStringList('component_patterns', componentPatterns);

    // 自定义特征类别：检测关键词 + 时间方法（与原生 SP 契约同 key）。
    await preferences.setStringList(
      'detection_vpn',
      normalized(byCategory['detection_vpn'] ?? const []),
    );
    await preferences.setStringList(
      'detection_emulator',
      normalized(byCategory['detection_emulator'] ?? const []),
    );
    await preferences.setStringList(
      'detection_root',
      normalized(byCategory['detection_root'] ?? const []),
    );
    await preferences.setStringList(
      'detection_debug',
      normalized(byCategory['detection_debug'] ?? const []),
    );
    await preferences.setStringList(
      'time_methods',
      normalized(byCategory['time_methods'] ?? const []),
    );

    // 推给原生：把启用规则全量同步到原生私有 SP（analyze/patch 合并用），
    // 失败不阻断本地 SP 写入（原生侧有内置规则兜底）。
    try {
      await ApkStructuralService.setUserRules({
        'sdk_packages': sdkPackages,
        'class_patterns': classPatterns,
        'method_patterns': normalized(
          byCategory['method_patterns'] ?? const [],
        ),
        'url_patterns': normalized(byCategory['url_patterns'] ?? const []),
        'force_true_methods': normalized(
          byCategory['force_true_methods'] ?? const [],
        ),
        'force_false_methods': normalized(
          byCategory['force_false_methods'] ?? const [],
        ),
        'flutter_string_patterns': normalized(
          byCategory['flutter_string_patterns'] ?? const [],
        ),
        'time_methods': normalized(byCategory['time_methods'] ?? const []),
        'detection_vpn': normalized(byCategory['detection_vpn'] ?? const []),
        'detection_emulator': normalized(
          byCategory['detection_emulator'] ?? const [],
        ),
        'detection_root': normalized(byCategory['detection_root'] ?? const []),
        'detection_debug': normalized(
          byCategory['detection_debug'] ?? const [],
        ),
        'ad_asset_files': normalized(byCategory['ad_asset_files'] ?? const []),
        'ad_permissions': normalized(byCategory['ad_permissions'] ?? const []),
        'shell_signatures': normalized(
          byCategory['shell_signatures'] ?? const [],
        ),
        'ad_asset_paths': normalized(byCategory['ad_asset_paths'] ?? const []),
        'lib_file_keywords': normalized(
          byCategory['lib_file_keywords'] ?? const [],
        ),
        'asset_keywords': normalized(byCategory['asset_keywords'] ?? const []),
        'method_neutralize_keywords': normalized(
          byCategory['method_neutralize_keywords'] ?? const [],
        ),
        'root_file_keywords': normalized(
          byCategory['root_file_keywords'] ?? const [],
        ),
        'res_layout_keywords': normalized(
          byCategory['res_layout_keywords'] ?? const [],
        ),
      });
    } catch (_) {}
  }

  Future<List<ModifyRuleRow>> loadAllRules() => _repository.getAllModifyRules();

  Stream<List<ModifyRuleRow>> watchAllRules() =>
      _repository.watchAllModifyRules();

  Future<void> setRuleEnabled(String id, {required bool enabled}) async {
    final existing = await _repository.getModifyRule(id);
    if (existing == null) return;
    await _repository.putModifyRule(
      existing.copyWith(
        enabled: enabled,
        version: existing.version + 1,
        updatedAt: DateTime.now(),
      ),
    );
    await syncRulesToPreferences();
  }

  /// 批量启用/停用规则（分类一键全选用），只同步一次偏好。
  Future<void> setRulesEnabled(
    List<String> ids, {
    required bool enabled,
  }) async {
    final now = DateTime.now();
    for (final id in ids) {
      final existing = await _repository.getModifyRule(id);
      if (existing == null) continue;
      await _repository.putModifyRule(
        existing.copyWith(
          enabled: enabled,
          version: existing.version + 1,
          updatedAt: now,
        ),
      );
    }
    await syncRulesToPreferences();
  }

  /// 新增一条规则（来源 user）。matcher 为单条模式文本。
  Future<ModifyRuleRow> addRule({
    required String category,
    required String name,
    required String pattern,
    String risk = 'low',
  }) async {
    final normalizedPattern = pattern.trim().toLowerCase();
    if (normalizedPattern.isEmpty) {
      throw ArgumentError.value(pattern, 'pattern', '匹配内容不能为空');
    }
    final now = DateTime.now();
    final rule = ModifyRuleRow(
      id: ruleIdFor(category, normalizedPattern),
      name: name.trim().isEmpty ? normalizedPattern : name.trim(),
      category: category,
      matcherJson: jsonEncode({'type': category, 'pattern': normalizedPattern}),
      enabled: true,
      source: 'user',
      risk: risk,
      hitCount: 0,
      successCount: 0,
      failureCount: 0,
      version: 0,
      updatedAt: now,
    );
    await _repository.putModifyRule(rule);
    await syncRulesToPreferences();
    return rule;
  }

  Future<void> deleteRule(String id) async {
    await _repository.deleteModifyRule(id);
    await syncRulesToPreferences();
  }

  /// 粘贴导入 ad_patterns_default.json 格式（12 类 key → 模式数组）。
  /// 已存在的同 id 条目自动跳过；返回实际新增条数。
  Future<int> importJson(String rawJson) =>
      _importWithSource(rawJson, 'import');

  /// 订阅合并入库：与粘贴导入同格式，source 标记 'subscription'。
  Future<int> _importWithSource(String rawJson, String source) async {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map) {
      throw const FormatException('rules_json_shape');
    }
    final knownCategories = categoryKeys.toSet();
    final now = DateTime.now();
    final rows = <ModifyRuleRow>[];
    for (final entry in decoded.entries) {
      final category = entry.key.toString();
      if (!knownCategories.contains(category)) continue;
      final patterns = entry.value;
      if (patterns is! List) continue;
      for (final raw in patterns) {
        final pattern = raw.toString().trim().toLowerCase();
        if (pattern.isEmpty) continue;
        rows.add(
          ModifyRuleRow(
            id: ruleIdFor(category, pattern),
            name: pattern,
            category: category,
            matcherJson: jsonEncode({'type': category, 'pattern': pattern}),
            enabled: true,
            source: source,
            risk: _categoryRisk[category] ?? 'low',
            hitCount: 0,
            successCount: 0,
            failureCount: 0,
            version: 0,
            updatedAt: now,
          ),
        );
      }
    }
    if (rows.isEmpty) throw const FormatException('rules_json_empty');
    final existing = await _repository.getAllModifyRules();
    final existingIds = existing.map((rule) => rule.id).toSet();
    final fresh = rows.where((rule) => !existingIds.contains(rule.id)).toList();
    if (fresh.isNotEmpty) {
      await _repository.putModifyRules(fresh);
      await syncRulesToPreferences();
    }
    return fresh.length;
  }

  /// 每类规则总数（全部，含未启用）。
  Future<Map<String, int>> countsByCategory() async {
    final rules = await _repository.getAllModifyRules();
    final counts = <String, int>{};
    for (final category in categoryKeys) {
      counts[category] = 0;
    }
    for (final rule in rules) {
      counts[rule.category] = (counts[rule.category] ?? 0) + 1;
    }
    return counts;
  }

  /// 每类命中统计（hitCount / successCount / failureCount 汇总，暂存态）。
  Future<Map<String, ({int hits, int success, int failure})>>
  hitStatsByCategory() async {
    final rules = await _repository.getAllModifyRules();
    final stats = <String, ({int hits, int success, int failure})>{};
    for (final rule in rules) {
      final current = stats[rule.category] ?? (hits: 0, success: 0, failure: 0);
      stats[rule.category] = (
        hits: current.hits + rule.hitCount,
        success: current.success + rule.successCount,
        failure: current.failure + rule.failureCount,
      );
    }
    return stats;
  }

  /// 根据报告 adSdkMatches 返回命中的厂商集合（用于预勾选）。
  Future<Set<String>> vendorsForReport(Map<String, dynamic> report) async {
    final matches =
        (report['adSdkMatches'] as List?)
            ?.map((item) => item.toString().toLowerCase())
            .toSet() ??
        const <String>{};
    return vendors.entries
        .where((entry) => entry.value.any(matches.contains))
        .map((entry) => entry.key)
        .toSet();
  }

  /// 厂商多信号聚合：
  /// 每个厂商按 DEX（sdk 包/类命中）+ Manifest（组件名含包前缀）+ assets（文件含厂商片段）
  /// 规则3：聚合中介平台——命中任一即标记"内嵌多广告源"，防止单厂商归因漏判
  /// （topon↔anythink 同源：anythink 是 topon 的旧名；两者都再聚合穿山甲/百度/快手/优量汇）。
  static const aggregatorVendors = <String>{'topon', 'cas'};

  /// 三信号判定，返回命中厂商及其信号清单，按信号数降序。
  /// AI 据此一眼看出「穿山甲+腾讯双广告商」及各自证据来源。
  List<Map<String, dynamic>> vendorSignalsForReport(
    Map<String, dynamic> report,
  ) {
    final sdkHits =
        (report['adSdkMatches'] as List?)
            ?.map((e) => e.toString().toLowerCase())
            .toSet() ??
        const <String>{};
    final classHits =
        (report['adClassMatches'] as List?)
            ?.map((e) => e.toString().toLowerCase())
            .toSet() ??
        const <String>{};
    // Manifest 组件名（全限定，含包前缀）
    final componentText = <String>[
      ...(report['activities'] as List? ?? const []),
      ...(report['services'] as List? ?? const []),
      ...(report['receivers'] as List? ?? const []),
      ...(report['providers'] as List? ?? const []),
    ].map((e) => e.toString().toLowerCase()).join('\n');
    // assets 候选文件名（candidates 里 assets/ 开头的）
    final assetNames =
        (report['candidates'] as List?)
            ?.map((e) => e is Map ? (e['path']?.toString() ?? '') : '')
            .where((p) => p.toLowerCase().startsWith('assets/'))
            .map((p) => p.split('/').last.toLowerCase())
            .toList() ??
        const <String>[];

    final result = <Map<String, dynamic>>[];
    for (final entry in vendors.entries) {
      final vendorId = entry.key;
      final pkgs = entry.value.map((p) => p.toLowerCase());
      final signals = <String>[];
      // DEX 信号：sdk 包命中（优先）
      for (final pkg in pkgs) {
        if (sdkHits.contains(pkg)) {
          signals.add('DEX: $pkg');
          break;
        }
      }
      // DEX 类信号：类命中含厂商包前缀
      for (final pkg in pkgs) {
        final pkgFragment = pkg.split('.').last.toLowerCase();
        if (pkgFragment.length >= 4 &&
            classHits.any((c) => c.contains(pkgFragment))) {
          signals.add('DEX类: $pkgFragment');
          break;
        }
      }
      // Manifest 信号：组件名含厂商包名任一段（>=4 字符）——点分/斜杠/相对名
      // 都兼容；"com.yandex.mobile.ads" 取 yandex/mobile 段，"ads" 等短段跳过
      for (final pkg in pkgs) {
        final fragments = pkg
            .split('.')
            .where((s) => s.length >= 4)
            .map((s) => s.toLowerCase());
        final hit = fragments.firstWhere(
          (f) => componentText.contains(f),
          orElse: () => '',
        );
        if (hit.isNotEmpty) {
          signals.add('Manifest: $hit');
          break;
        }
      }
      // assets 信号：候选文件名含厂商片段
      for (final pkg in pkgs) {
        final fragment = pkg.split('.').last.toLowerCase();
        if (fragment.length >= 4 &&
            assetNames.any((n) => n.contains(fragment))) {
          signals.add('assets: $fragment');
          break;
        }
      }
      if (signals.isNotEmpty) {
        // 规则3：聚合中介平台标注（topon/cas 等——内嵌多广告源，单厂商归因不完整）
        if (aggregatorVendors.contains(vendorId) && !signals.contains('聚合平台')) {
          signals.add(
            '聚合平台：中介再聚合多广告源（穿山甲/百度/快手/优量汇等），内嵌 SDK 需逐源处理，命中任一即按聚合平台对待',
          );
        }
        result.add({
          'id': vendorId,
          'label': vendorLabels[vendorId] ?? vendorId,
          'signals': signals,
          'score': signals.length,
        });
      }
    }
    result.sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));
    return result;
  }

  /// 某厂商对应的规则行（sdk_packages 子集）。
  Future<List<ModifyRuleRow>> rulesForVendor(String vendorId) async {
    final patterns = vendors[vendorId] ?? const <String>[];
    final rules = await _repository.getAllModifyRules();
    return rules
        .where((rule) => patterns.contains(patternOf(rule)))
        .toList(growable: false);
  }

  /// 批量启用/停用某厂商的全部相关规则。
  Future<int> setVendorEnabled(String vendorId, {required bool enabled}) async {
    final patterns = vendors[vendorId] ?? const <String>[];
    if (patterns.isEmpty) return 0;
    final rules = await _repository.getAllModifyRules();
    var changed = 0;
    final now = DateTime.now();
    for (final rule in rules) {
      final pattern = patternOf(rule);
      if (pattern == null || !patterns.contains(pattern)) continue;
      if (rule.enabled == enabled) continue;
      await _repository.putModifyRule(
        rule.copyWith(
          enabled: enabled,
          version: rule.version + 1,
          updatedAt: now,
        ),
      );
      changed++;
    }
    if (changed > 0) await syncRulesToPreferences();
    return changed;
  }

  /// 解析种子 JSON；解析失败时静默降级为空（不阻断规则库打开）。
  Map<String, List<String>> _parseSeed() {
    try {
      final decoded = jsonDecode(adRulesDefaultJson);
      if (decoded is! Map) return const {};
      final result = <String, List<String>>{};
      for (final entry in decoded.entries) {
        final values = entry.value;
        if (values is! List) continue;
        final seen = <String>{};
        result[entry.key.toString()] = [
          for (final value in values)
            if (seen.add(value.toString().trim().toLowerCase()))
              value.toString(),
        ];
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  // --- 规则订阅（网络订阅源，元信息存库，不落文件） ---

  /// 官方订阅源（APK 去广告编辑器特征库，与种子同格式）。
  /// 仅用于识别历史版本预置的残留订阅；订阅源不再自动预置，由用户自行添加。
  static const defaultSubscriptionUrl =
      'https://apkadremovereditor.pages.dev/ad_patterns.json';

  /// 清理历史版本预置的官方订阅源（未被用户改过地址才删）。
  Future<void> removeLegacyDefaultSubscription() async {
    final existing = await _repository.getRuleSubscription('official');
    if (existing == null || existing.url != defaultSubscriptionUrl) return;
    await _repository.deleteRuleSubscription('official');
  }

  Stream<List<RuleSubscriptionRow>> watchSubscriptions() =>
      _repository.watchAllRuleSubscriptions();

  Future<List<RuleSubscriptionRow>> loadSubscriptions() =>
      _repository.getAllRuleSubscriptions();

  /// 添加订阅源（URL 必须是 http/https 且指向 ad_patterns.json 格式）。
  Future<RuleSubscriptionRow> addSubscription({
    required String name,
    required String url,
  }) async {
    final trimmedUrl = url.trim();
    final uri = Uri.tryParse(trimmedUrl);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('subscription_url_invalid');
    }
    final id = 'sub_${DateTime.now().microsecondsSinceEpoch}';
    final row = RuleSubscriptionRow(
      id: id,
      name: name.trim().isEmpty ? trimmedUrl : name.trim(),
      url: trimmedUrl,
      enabled: true,
      lastSyncAt: null,
      lastRuleCount: 0,
      createdAt: DateTime.now(),
    );
    await _repository.putRuleSubscription(row);
    return row;
  }

  Future<void> deleteSubscription(String id) =>
      _repository.deleteRuleSubscription(id);

  Future<void> setSubscriptionEnabled(
    String id, {
    required bool enabled,
  }) async {
    final row = await _repository.getRuleSubscription(id);
    if (row == null) return;
    await _repository.putRuleSubscription(row.copyWith(enabled: enabled));
  }

  /// 拉取订阅源并合并入库；返回新增条数。失败抛异常（UI 捕获展示）。
  Future<int> refreshSubscription(String id) async {
    final row = await _repository.getRuleSubscription(id);
    if (row == null) throw const FormatException('subscription_not_found');
    final body = await _fetchRemote(row.url);
    final added = await _importWithSource(body, 'subscription');
    final total = (await _repository.getAllModifyRules()).length;
    await _repository.putRuleSubscription(
      row.copyWith(lastSyncAt: Value(DateTime.now()), lastRuleCount: total),
    );
    return added;
  }

  /// HTTP GET 拉取订阅 JSON（超时 15s；仅 2xx 视为成功）。
  Future<String> _fetchRemote(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('Accept', 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('http_${response.statusCode}');
      }
      return await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
    } finally {
      client.close();
    }
  }
}
