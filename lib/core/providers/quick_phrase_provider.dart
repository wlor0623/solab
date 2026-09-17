import 'package:flutter/foundation.dart';
import '../database/business_preferences.dart';
import '../models/quick_phrase.dart';
import '../services/quick_phrase_store.dart';

class QuickPhraseProvider with ChangeNotifier {
  QuickPhraseProvider({required this.preferences})
    : _store = QuickPhraseStore(preferences);

  /// SoLab APK 快捷短语种子预置的版本 key（<1 时执行一次，执行后置为 1）。
  /// 与其它两个 provider 使用同一前缀、不同后缀，避免先初始化的
  /// provider 把共用版本 key 置 1 后导致其余种子永不写入。
  static const String _apkModSeedVersionKey =
      'apk_mod_knowledge_seed_version_quick_phrase';
  static const String _apkModAssistantId = 'builtin-apk-mod';

  final BusinessPreferences preferences;
  final QuickPhraseStore _store;
  List<QuickPhrase> _phrases = [];
  bool _initialized = false;
  Future<void>? _initializationFuture;

  List<QuickPhrase> get phrases => List.unmodifiable(_phrases);

  List<QuickPhrase> get globalPhrases =>
      _phrases.where((p) => p.isGlobal).toList();

  List<QuickPhrase> getForAssistant(String assistantId) => _phrases
      .where((p) => !p.isGlobal && p.assistantId == assistantId)
      .toList();

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
      _phrases = await _store.getAll();
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load quick phrases: $e');
      _phrases = [];
      notifyListeners();
    }
  }

  Future<void> add(QuickPhrase phrase) async {
    await _store.add(phrase);
    await loadAll();
  }

  Future<void> update(QuickPhrase phrase) async {
    await _store.update(phrase);
    await loadAll();
  }

  Future<void> delete(String id) async {
    await _store.delete(id);
    await loadAll();
  }

  Future<void> clear() async {
    await _store.clear();
    _phrases = [];
    notifyListeners();
  }

  void _reorderInMemory({
    required int oldIndex,
    required int newIndex,
    String? assistantId,
  }) {
    final bool isGlobal = assistantId == null;

    // Determine indices in the subset (global or specific assistant)
    final List<int> subsetIndices = [];
    for (int i = 0; i < _phrases.length; i++) {
      final p = _phrases[i];
      final matches = isGlobal
          ? p.isGlobal
          : (!p.isGlobal && p.assistantId == assistantId);
      if (matches) subsetIndices.add(i);
    }

    if (subsetIndices.isEmpty) return;
    if (oldIndex < 0 || oldIndex >= subsetIndices.length) return;
    if (newIndex < 0 || newIndex >= subsetIndices.length) return;

    // Extract the subset in current order
    final List<QuickPhrase> subset = subsetIndices
        .map((i) => _phrases[i])
        .toList(growable: true);

    final item = subset.removeAt(oldIndex);
    subset.insert(newIndex, item);

    // Merge reordered subset back into original list
    final List<QuickPhrase> merged = [];
    int take = 0;
    for (int i = 0; i < _phrases.length; i++) {
      final p = _phrases[i];
      final matches = isGlobal
          ? p.isGlobal
          : (!p.isGlobal && p.assistantId == assistantId);
      if (matches) {
        merged.add(subset[take++]);
      } else {
        merged.add(p);
      }
    }
    _phrases = merged;
  }

  Future<void> reorder({
    required int oldIndex,
    required int newIndex,
    String? assistantId,
  }) async {
    _reorderInMemory(
      oldIndex: oldIndex,
      newIndex: newIndex,
      assistantId: assistantId,
    );
    notifyListeners();
    await _store.save(_phrases);
  }

  // Backward/alternate API name for clarity
  Future<void> reorderPhrases({
    required int oldIndex,
    required int newIndex,
    String? assistantId,
  }) async {
    // Immediate UI update, then persist
    _reorderInMemory(
      oldIndex: oldIndex,
      newIndex: newIndex,
      assistantId: assistantId,
    );
    notifyListeners();
    await _store.save(_phrases);
  }

  /// 预置 SoLab APK 助手的 6 条种子快捷短语（助手级，绑定 builtin-apk-mod）。
  ///
  /// 模式参考 [AssistantProvider.ensureDefaults]：仅在版本 key < 1 时执行
  /// 一次；用户已有同名标题则跳过创建，绝不覆盖用户已有数据。
  Future<void> ensureApkModSeed() async {
    try {
      if ((preferences.getInt(_apkModSeedVersionKey) ?? 0) >= 1) return;
      final seeds = _apkModSeedPhrases();
      final existingTitles = _phrases.map((p) => p.title.trim()).toSet();
      final toAdd = seeds
          .where((s) => !existingTitles.contains(s.title.trim()))
          .toList(growable: false);
      for (final phrase in toAdd) {
        await _store.add(phrase);
      }
      await preferences.setInt(_apkModSeedVersionKey, 1);
      await loadAll();
    } catch (e) {
      debugPrint('Failed to seed SoLab APK quick phrases: $e');
    }
  }

  List<QuickPhrase> _apkModSeedPhrases() {
    return const <QuickPhrase>[
      QuickPhrase(
        id: 'apk_mod_phrase_analyze_current_apk',
        title: '分析当前 APK',
        content: '请分析当前选中的 APK：输出包名、版本、签名、权限、组件、广告 SDK 与加固情况。',
        isGlobal: false,
        assistantId: _apkModAssistantId,
      ),
      QuickPhrase(
        id: 'apk_mod_phrase_generate_mod_plan',
        title: '生成修改计划',
        content: '基于当前报告生成修改计划：列出目标、命中依据、变更项、风险与验证方法，等待我确认。',
        isGlobal: false,
        assistantId: _apkModAssistantId,
      ),
      QuickPhrase(
        id: 'apk_mod_phrase_list_slim_candidates',
        title: '列出精简候选',
        content: '基于引用分析列出可精简的候选文件，标注命中依据，不确定的标为待确认。',
        isGlobal: false,
        assistantId: _apkModAssistantId,
      ),
      QuickPhrase(
        id: 'apk_mod_phrase_verify_output_apk',
        title: '验证输出 APK',
        content: '对输出 APK 执行验证：签名、重打包完整性、关键组件与功能检查，并报告验证结果。',
        isGlobal: false,
        assistantId: _apkModAssistantId,
      ),
      QuickPhrase(
        id: 'apk_mod_phrase_list_hit_rules',
        title: '列出命中规则',
        content: '列出当前 APK 命中的所有规则及对应证据（DEX、权限、组件、广告 SDK）。',
        isGlobal: false,
        assistantId: _apkModAssistantId,
      ),
      QuickPhrase(
        id: 'apk_mod_phrase_keep_arm64',
        title: '只保留 arm64-v8a',
        content: '过滤原生库只保留 arm64-v8a ABI，删除其余 ABI 目录，并说明对设备兼容范围的影响。',
        isGlobal: false,
        assistantId: _apkModAssistantId,
      ),
    ];
  }
}
