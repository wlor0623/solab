import 'package:flutter/foundation.dart';

import '../database/business_preferences.dart';
import '../models/instruction_injection.dart';
import '../services/instruction_injection_store.dart';

class InstructionInjectionProvider with ChangeNotifier {
  InstructionInjectionProvider({required this.preferences})
    : _store = InstructionInjectionStore(preferences);

  /// SoLab APK 指令注入种子预置的版本 key（<1 时执行一次，执行后置为 1）。
  /// 与其它两个 provider 使用同一前缀、不同后缀，避免先初始化的
  /// provider 把共用版本 key 置 1 后导致其余种子永不写入。
  static const String _apkModSeedVersionKey =
      'apk_mod_knowledge_seed_version_instruction_injection';
  static const String _apkModAssistantId = 'builtin-apk-mod';
  static const String _apkModGroup = 'SoLab 修改纪律';
  static const Map<String, String> _apkModSeedV5Prompts = <String, String>{
    'apk_mod_injection_modification_discipline':
        '修改操作铁律：只在证据充分后写入。用户已明确要求修改当前 APK，即视为执行授权；工具支持时一次调用 dryRun=true+applyAfterPreview=true，先预览且无 warning 才自动写入。纯 dryRun 必须原样调用返回的 applyArguments，禁止重复预览。写入失败保留 token 直接重试，成功后切换到 nextInputPath。目标不明、方案有实质分歧或预览明显不符时才用 ask_user_input_v0 一次问全。',
    'apk_mod_injection_reference_analysis':
        '引用分析纪律：.proto/.pb/.bin/SO/权限/ABI 等文件的去留必须经过引用分析（DEX 引用、loadLibrary 调用、manifest 声明）后才能决定；禁止仅凭扩展名盲删；分析结果不确定的一律进入待确认清单，等待用户决策。',
    'apk_mod_injection_ask_first':
        '执行纪律：工作目录里的原项目是只读备份，所有修改都落在副本/中间包上。调用工具前先精读用户原话，禁止无方向全量扫描。用户明确提出精确修改目标后，写工具使用 dryRun=true+applyAfterPreview=true 一次完成；需要人工判断的纯预览则原样执行返回的 applyArguments，不得忘记写入或重复 dryRun。提问只留目标不明确、方案实质分歧、预览明显不符或线索不足四种场景，并一次问全。',
  };
  static const Map<String, String> _apkModSeedV6Prompts = <String, String>{
    'apk_mod_injection_modification_discipline':
        '修改操作铁律：先用当前报告和最窄定位工具闭合证据，再执行唯一必要改点。用户已明确要求修改当前 APK 即视为授权；支持时一次调用 dryRun=true+applyAfterPreview=true，warning、无变更或目标不符会自动阻断。纯 dryRun 只允许一次，随后原样调用 applyArguments；写入失败沿用原 token，写入成功立即切换 nextInputPath。直接 DEX/SO 写回后签名，只有解码目录、资源或 Manifest 改动才重建。',
  };
  static const Map<String, String> _apkModSeedV7Prompts = <String, String>{
    'apk_mod_injection_modification_discipline':
        '修改操作铁律：先用当前报告和最窄定位工具闭合证据，再执行唯一必要改点。除非用户要求跳过去签或 APK 工作台设为不开启，首次业务写入前必须用独立的 signature_bypass 工具对未改原包单独执行；用户指定模式时严格使用，未指定时跟随 APK 工作台设置。dpatch 和 original_apk 都必须使用返回的 outputPath 作为后续唯一输入，禁止直接修改原包或在已修改包上重复注入。用户已明确要求修改当前 APK 即视为授权；支持时一次调用 dryRun=true+applyAfterPreview=true，warning、无变更或目标不符会自动阻断。纯 dryRun 只允许一次，随后原样调用 applyArguments；写入失败沿用原 token，写入成功立即切换 nextInputPath。直接 DEX/SO 写回后签名，只有解码目录、资源或 Manifest 改动才重建。',
  };

  final BusinessPreferences preferences;
  final InstructionInjectionStore _store;
  List<InstructionInjection> _items = const <InstructionInjection>[];
  bool _initialized = false;
  Future<void>? _initializationFuture;
  Map<String, List<String>> _activeIdsByAssistant =
      const <String, List<String>>{};

  String _normGroup(String g) => g.trim();

  List<InstructionInjection> get items =>
      List<InstructionInjection>.unmodifiable(_items);
  List<String> get activeIds => activeIdsFor(null);

  List<String> activeIdsFor(String? assistantId) {
    final key = InstructionInjectionStore.assistantKey(assistantId);
    if (_activeIdsByAssistant.containsKey(key)) {
      return List<String>.unmodifiable(_activeIdsByAssistant[key]!);
    }
    final fallback =
        _activeIdsByAssistant[InstructionInjectionStore.assistantKey(null)] ??
        const <String>[];
    return List<String>.unmodifiable(fallback);
  }

  bool isActive(String id, {String? assistantId}) =>
      activeIdsFor(assistantId).contains(id);

  List<InstructionInjection> get actives => activesFor(null);

  List<InstructionInjection> activesFor(String? assistantId) {
    final ids = activeIdsFor(assistantId).toSet();
    return _items.where((e) => ids.contains(e.id)).toList(growable: false);
  }

  String? get activeId => activeIdFor(null);
  String? activeIdFor(String? assistantId) {
    final ids = activeIdsFor(assistantId);
    return ids.isEmpty ? null : ids.first;
  }

  InstructionInjection? get active => activeFor(null);
  InstructionInjection? activeFor(String? assistantId) {
    final list = activesFor(assistantId);
    if (list.isEmpty) return null;
    return list.first;
  }

  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    return _initializationFuture ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      await loadAll();
      await ensureApkModSeed();
      _initialized = true;
    } finally {
      _initializationFuture = null;
    }
  }

  Future<void> loadAll() async {
    try {
      _items = await _store.getAll();
      _activeIdsByAssistant = await _store.getActiveIdsByAssistant();
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load instruction injections: $e');
      _items = const <InstructionInjection>[];
      _activeIdsByAssistant = const <String, List<String>>{};
      notifyListeners();
    }
  }

  Future<void> add(InstructionInjection item) async {
    await _store.add(item);
    await loadAll();
  }

  Future<void> addMany(List<InstructionInjection> items) async {
    if (items.isEmpty) return;
    await _store.addMany(items);
    await loadAll();
  }

  Future<void> update(InstructionInjection item) async {
    await _store.update(item);
    await loadAll();
  }

  Future<void> delete(String id) async {
    await _store.delete(id);
    await loadAll();
  }

  Future<void> clear() async {
    await _store.clear();
    _items = const <InstructionInjection>[];
    _activeIdsByAssistant = const <String, List<String>>{};
    notifyListeners();
  }

  Future<void> reorder({required int oldIndex, required int newIndex}) async {
    if (_items.isEmpty) return;
    if (oldIndex < 0 || oldIndex >= _items.length) return;
    if (newIndex < 0 || newIndex >= _items.length) return;
    final list = List<InstructionInjection>.from(_items);
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    _items = list;
    notifyListeners();
    await _store.save(_items);
  }

  Future<void> reorderWithinGroup({
    required String group,
    required int oldIndex,
    required int newIndex,
  }) async {
    if (_items.isEmpty) return;

    final targetGroup = _normGroup(group);
    final indices = <int>[];
    for (int i = 0; i < _items.length; i++) {
      if (_normGroup(_items[i].group) == targetGroup) indices.add(i);
    }
    if (indices.isEmpty) return;
    if (oldIndex < 0 || oldIndex >= indices.length) return;
    if (newIndex < 0 || newIndex > indices.length) return;

    final globalOld = indices[oldIndex];
    final list = List<InstructionInjection>.from(_items);
    final moved = list.removeAt(globalOld);

    // Recompute group indices after removal.
    final after = <int>[];
    for (int i = 0; i < list.length; i++) {
      if (_normGroup(list[i].group) == targetGroup) after.add(i);
    }

    int insertAt;
    if (newIndex >= after.length) {
      insertAt = after.isEmpty ? list.length : after.last + 1;
    } else {
      insertAt = after[newIndex];
    }
    list.insert(insertAt, moved);

    _items = list;
    notifyListeners();
    await _store.save(_items);
  }

  Future<void> setActiveId(String? id, {String? assistantId}) async {
    if (id == null || id.isEmpty) {
      await setActiveIds(const <String>[], assistantId: assistantId);
      return;
    }
    await setActiveIds(<String>[id], assistantId: assistantId);
  }

  Future<void> setActiveIds(List<String> ids, {String? assistantId}) async {
    final key = InstructionInjectionStore.assistantKey(assistantId);
    final nextMap = Map<String, List<String>>.from(_activeIdsByAssistant);
    nextMap[key] = ids.toSet().toList(growable: false);
    _activeIdsByAssistant = nextMap;
    notifyListeners();
    await _store.setActiveIds(ids, assistantId: assistantId);
  }

  Future<void> toggleActiveId(String id, {String? assistantId}) async {
    final set = activeIdsFor(assistantId).toSet();
    if (set.contains(id)) {
      set.remove(id);
    } else {
      set.add(id);
    }
    await setActiveIds(set.toList(growable: false), assistantId: assistantId);
  }

  Future<void> setActive(InstructionInjection? item, {String? assistantId}) =>
      setActiveId(item?.id, assistantId: assistantId);

  /// 预置 SoLab 助手的 3 条种子指令注入。
  ///
  /// 模式参考 [AssistantProvider.ensureDefaults]：仅在版本 key < 1 时执行
  /// 一次；用户已有同名标题则跳过创建；激活列表只追加不清空，绝不覆盖
  /// 用户已有数据。
  ///
  /// 版本 key 2：品牌更名——种子分组「SoLab APK 修改纪律」改为
  /// 「SoLab 修改纪律」，条目与用户开关全部保留。
  /// 版本 key 3：收敛写操作提示词，避免完整变更清单和逐步确认造成重复等待。
  /// 版本 key 4：用户明确修改目标即视为授权，dryRun 后直接执行。
  /// 版本 key 5：支持一次调用完成预览与执行，避免重复 dryRun。
  /// 版本 key 6：补充工具可用性、按需读取、统一路径和依赖/资源引用纪律；
  /// 只同步未被用户修改过的 v5 种子正文。
  /// 版本 key 7：签名兼容注入固定为原始 APK 的首次写操作，只执行一次。
  Future<void> ensureApkModSeed() async {
    try {
      final version = preferences.getInt(_apkModSeedVersionKey) ?? 0;

      if (version < 1) {
        final seeds = _apkModSeedItems();
        final existingTitles = _items.map((e) => e.title.trim()).toSet();
        final toAdd = seeds
            .where((s) => !existingTitles.contains(s.title.trim()))
            .toList(growable: false);
        if (toAdd.isNotEmpty) {
          await _store.addMany(toAdd);
          // 绑定到 SoLab 助手：在既有激活列表上追加，不清空用户配置。
          final createdIds = toAdd.map((e) => e.id).toList(growable: false);
          final activeMap = await _store.getActiveIdsByAssistant();
          final key = InstructionInjectionStore.assistantKey(
            _apkModAssistantId,
          );
          final existing = activeMap[key] ?? const <String>[];
          final merged = <String>{
            ...existing,
            ...createdIds,
          }.toList(growable: false);
          await _store.setActiveIds(merged, assistantId: _apkModAssistantId);
        }
        await preferences.setInt(_apkModSeedVersionKey, 1);
      }

      // v2：旧分组名迁移——组名仍是旧种子名时改为新名（用户改过组名
      // 的条目不动，与旧版按内容匹配的行为一致）。
      if (version < 2) {
        for (final item in _items) {
          if (item.id.startsWith('apk_mod_injection_') &&
              item.group.trim() == 'SoLab APK 修改纪律') {
            await _store.update(item.copyWith(group: _apkModGroup));
          }
        }
        await preferences.setInt(_apkModSeedVersionKey, 2);
        await loadAll();
      }

      if (version < 3) {
        final seeds = {for (final item in _apkModSeedItems()) item.id: item};
        var changed = false;
        for (var index = 0; index < _items.length; index++) {
          final item = _items[index];
          final seed = seeds[item.id];
          final isLegacySeed =
              (item.id == 'apk_mod_injection_modification_discipline' &&
                  item.prompt.startsWith('修改操作铁律：')) ||
              (item.id == 'apk_mod_injection_ask_first' &&
                  item.prompt.startsWith('执行纪律：工作目录里的原项目是只读备份'));
          if (seed == null || !isLegacySeed) {
            continue;
          }
          await _store.update(item.copyWith(prompt: seed.prompt));
          changed = true;
        }
        await preferences.setInt(_apkModSeedVersionKey, 3);
        if (changed) await loadAll();
      }

      if (version < 4) {
        final seeds = {for (final item in _apkModSeedItems()) item.id: item};
        var changed = false;
        for (var index = 0; index < _items.length; index++) {
          final item = _items[index];
          final seed = seeds[item.id];
          final isLegacySeed =
              (item.id == 'apk_mod_injection_modification_discipline' &&
                  item.prompt.startsWith('修改操作铁律：')) ||
              (item.id == 'apk_mod_injection_ask_first' &&
                  item.prompt.startsWith('执行纪律：工作目录里的原项目是只读备份'));
          if (seed == null || !isLegacySeed) {
            continue;
          }
          await _store.update(item.copyWith(prompt: seed.prompt));
          changed = true;
        }
        await preferences.setInt(_apkModSeedVersionKey, 4);
        if (changed) await loadAll();
      }

      if (version < 5) {
        final seeds = {for (final item in _apkModSeedItems()) item.id: item};
        var changed = false;
        for (final item in _items) {
          final seed = seeds[item.id];
          if (seed == null ||
              !const {
                'apk_mod_injection_modification_discipline',
                'apk_mod_injection_ask_first',
              }.contains(item.id)) {
            continue;
          }
          await _store.update(item.copyWith(prompt: seed.prompt));
          changed = true;
        }
        await preferences.setInt(_apkModSeedVersionKey, 5);
        if (changed) await loadAll();
      }

      if (version < 6) {
        final seeds = {for (final item in _apkModSeedItems()) item.id: item};
        var changed = false;
        for (final item in _items) {
          final seed = seeds[item.id];
          final previousPrompt = _apkModSeedV5Prompts[item.id];
          if (seed == null ||
              previousPrompt == null ||
              item.prompt != previousPrompt) {
            continue;
          }
          await _store.update(item.copyWith(prompt: seed.prompt));
          changed = true;
        }
        await preferences.setInt(_apkModSeedVersionKey, 6);
        if (changed) await loadAll();
      }

      if (version < 7) {
        final seeds = {for (final item in _apkModSeedItems()) item.id: item};
        var changed = false;
        for (final item in _items) {
          final seed = seeds[item.id];
          final previousPrompt = _apkModSeedV6Prompts[item.id];
          if (seed == null ||
              previousPrompt == null ||
              item.prompt != previousPrompt) {
            continue;
          }
          await _store.update(item.copyWith(prompt: seed.prompt));
          changed = true;
        }
        await preferences.setInt(_apkModSeedVersionKey, 7);
        if (changed) await loadAll();
      }

      if (version < 8) {
        final seeds = {for (final item in _apkModSeedItems()) item.id: item};
        var changed = false;
        for (final item in _items) {
          final seed = seeds[item.id];
          final previousPrompt = _apkModSeedV7Prompts[item.id];
          if (seed == null ||
              previousPrompt == null ||
              item.prompt != previousPrompt) {
            continue;
          }
          await _store.update(item.copyWith(prompt: seed.prompt));
          changed = true;
        }
        await preferences.setInt(_apkModSeedVersionKey, 8);
        if (changed) await loadAll();
      }
    } catch (e) {
      debugPrint('Failed to seed SoLab instruction injections: $e');
    }
  }

  List<InstructionInjection> _apkModSeedItems() {
    const group = _apkModGroup;
    return const <InstructionInjection>[
      InstructionInjection(
        id: 'apk_mod_injection_modification_discipline',
        title: '修改操作铁律',
        group: group,
        prompt:
            '修改操作铁律：先用当前报告和最窄定位工具闭合证据，再执行唯一必要改点。分析、去签、修改、构建和签名均可单独调用；除非用户要求跳过去签或 APK 工作台设为不开启，首次业务写入前必须用独立 signature_bypass 工具：用户指定 mode 时严格使用，未指定时跟随 APK 工作台设置。dpatch 和 original_apk 返回的 outputPath 是后续唯一输入，禁止直接修改原包；工具参数、预览和确认语义以当前写工具 schema 为准。直接 DEX/SO 写回后签名，只有解码目录、资源或 Manifest 改动才重建。',
      ),
      InstructionInjection(
        id: 'apk_mod_injection_reference_analysis',
        title: '引用分析纪律',
        group: group,
        prompt:
            '引用分析纪律：依赖、代码、assets、.proto/.pb/.bin、SO、权限和 ABI 的去留必须同时检查静态引用、运行时注册/动态路径和构建清单。零字符串命中不等于无引用；DEX 字段访问要查 iget/iput/sget/sput，原生库要查 loadLibrary/DT_NEEDED，资源要查 Manifest、配置和动态拼接。三项都确认无用才删除；不确定项保留并说明缺失证据，禁止按扩展名、文件大小或目录名盲删。',
      ),
      InstructionInjection(
        id: 'apk_mod_injection_ask_first',
        title: '执行纪律',
        group: group,
        prompt:
            '执行纪律：先精读用户原话并 route_task，只加载本轮相关工具、知识和 Skill；长报告只读摘要、目标分区和一次必要分页，禁止把 500 条结果从头读完。调用前核对当前 tools/list 与参数定义；工具没出现就查可用工具列表或改走已声明入口，禁止编造工具名、参数或路径。同一源 APK 只用一个以 App 名称命名的工作区，返回的 outputPath/nextInputPath 原样传递。目标明确直接执行；只在目标不明、方案实质分歧、预览不符或缺少决定性线索时一次问全。',
      ),
    ];
  }
}
