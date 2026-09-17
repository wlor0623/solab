import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../database/business_preferences.dart';
import '../models/world_book.dart';
import '../services/world_book_store.dart';

class WorldBookProvider with ChangeNotifier {
  WorldBookProvider({required this.preferences})
    : _store = WorldBookStore(preferences);

  /// SoLab APK 知识书种子预置的版本 key（<1 时执行一次，执行后置为 1）。
  /// 与其它两个 provider 使用同一前缀、不同后缀，避免先初始化的
  /// provider 把共用版本 key 置 1 后导致其余种子永不写入。
  static const String _apkModSeedVersionKey =
      'apk_mod_knowledge_seed_version_world_book';
  static const String _apkModAssistantId = 'builtin-apk-mod';
  static const String _apkModBookId = 'apk_mod_knowledge_book';
  static const Map<String, String> _apkModSeedV22ContentHashes =
      <String, String>{
        'apk_mod_entry_confirmation_discipline':
            '3f01b72df67bb3ac9eb7e9baca1f005c721da2349833785e6d2f10f4e23b145d',
        'apk_mod_entry_no_budget':
            '041273a909252fdc2e9f0a99fd403a8e19e7608104012f7d9242982a4448daab',
        'apk_mod_entry_multi_signal':
            '5ad7315f9066be68859d8836355ef9c5b5454cd68c08a32a7759cd870cfa82a6',
        'apk_mod_entry_relentless_goal':
            '42835534f868a8765b1929b4034aa29d7762148aaf3e60b22b2177046c657d6a',
        'apk_mod_entry_detection_evasion':
            'e75c96612934c0d477ad651a632e66d27a1b5afd2b2ae9edfb6d5a9393ed5aa3',
      };

  final BusinessPreferences preferences;
  final WorldBookStore _store;
  List<WorldBook> _books = const <WorldBook>[];
  bool _initialized = false;
  Future<void>? _initializationFuture;
  Map<String, List<String>> _activeIdsByAssistant =
      const <String, List<String>>{};
  Map<String, bool> _collapsedBooks = const <String, bool>{};

  List<WorldBook> get books => List<WorldBook>.unmodifiable(_books);

  WorldBook? getById(String id) {
    try {
      return _books.firstWhere((e) => e.id == id);
    } catch (_) {
      return null;
    }
  }

  List<String> activeBookIdsFor(String? assistantId) {
    final key = WorldBookStore.assistantKey(assistantId);
    if (_activeIdsByAssistant.containsKey(key)) {
      return List<String>.unmodifiable(_activeIdsByAssistant[key]!);
    }
    final fallback =
        _activeIdsByAssistant[WorldBookStore.assistantKey(null)] ??
        const <String>[];
    return List<String>.unmodifiable(fallback);
  }

  bool isBookActive(String id, {String? assistantId}) =>
      activeBookIdsFor(assistantId).contains(id);

  bool isBookCollapsed(String id) => _collapsedBooks[id] ?? false;

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
      _books = await _store.getAll();
      _activeIdsByAssistant = await _store.getActiveIdsByAssistant();
      final collapsed = await _store.getCollapsedBooksMap();
      final knownIds = _books.map((e) => e.id).toSet();
      final cleanedCollapsed = <String, bool>{
        for (final entry in collapsed.entries)
          if (knownIds.contains(entry.key)) entry.key: entry.value,
      };
      _collapsedBooks = cleanedCollapsed;

      if (cleanedCollapsed.length != collapsed.length) {
        await _store.setCollapsedMap(cleanedCollapsed);
      }

      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load world books: $e');
      _books = const <WorldBook>[];
      _activeIdsByAssistant = const <String, List<String>>{};
      _collapsedBooks = const <String, bool>{};
      notifyListeners();
    }
  }

  Future<void> addBook(WorldBook book) async {
    await _store.add(book);
    await loadAll();
  }

  Future<void> updateBook(WorldBook book) async {
    if (!book.enabled) {
      try {
        final map = await _store.getActiveIdsByAssistant();
        final next = <String, List<String>>{};
        bool changed = false;
        for (final entry in map.entries) {
          final filtered = entry.value
              .where((e) => e != book.id)
              .toList(growable: false);
          if (filtered.length != entry.value.length) changed = true;
          next[entry.key] = filtered;
        }
        if (changed) {
          await _store.setActiveIdsMap(next);
        }
      } catch (_) {}
    }
    await _store.update(book);
    await loadAll();
  }

  Future<void> deleteBook(String id) async {
    await _store.delete(id);
    await loadAll();
  }

  Future<void> clear() async {
    await _store.clear();
    _books = const <WorldBook>[];
    _activeIdsByAssistant = const <String, List<String>>{};
    _collapsedBooks = const <String, bool>{};
    notifyListeners();
  }

  Future<void> reorderBooks({
    required int oldIndex,
    required int newIndex,
  }) async {
    if (_books.isEmpty) return;
    if (oldIndex < 0 || oldIndex >= _books.length) return;
    if (newIndex < 0 || newIndex >= _books.length) return;
    final list = List<WorldBook>.from(_books);
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    _books = list;
    notifyListeners();
    await _store.save(_books);
  }

  Future<void> reorderEntries({
    required String bookId,
    required int oldIndex,
    required int newIndex,
  }) async {
    final bookIndex = _books.indexWhere((e) => e.id == bookId);
    if (bookIndex == -1) return;
    final book = _books[bookIndex];
    final entries = List<WorldBookEntry>.from(book.entries);
    if (entries.isEmpty) return;
    if (oldIndex < 0 || oldIndex >= entries.length) return;
    if (newIndex < 0 || newIndex >= entries.length) return;
    final item = entries.removeAt(oldIndex);
    entries.insert(newIndex, item);
    final nextBook = book.copyWith(entries: entries);
    final nextBooks = List<WorldBook>.from(_books);
    nextBooks[bookIndex] = nextBook;
    _books = nextBooks;
    notifyListeners();
    await _store.save(_books);
  }

  Future<void> setBookCollapsed(String id, bool collapsed) async {
    final key = id.trim();
    if (key.isEmpty) return;

    final next = Map<String, bool>.from(_collapsedBooks);
    next[key] = collapsed;
    _collapsedBooks = next;
    notifyListeners();
    await _store.setCollapsed(key, collapsed);
  }

  Future<void> toggleBookCollapsed(String id) async {
    await setBookCollapsed(id, !isBookCollapsed(id));
  }

  Future<void> setActiveBookIds(List<String> ids, {String? assistantId}) async {
    final key = WorldBookStore.assistantKey(assistantId);
    final nextMap = Map<String, List<String>>.from(_activeIdsByAssistant);
    nextMap[key] = ids.toSet().toList(growable: false);
    _activeIdsByAssistant = nextMap;
    notifyListeners();
    await _store.setActiveIds(ids, assistantId: assistantId);
  }

  Future<void> toggleActiveBookId(String id, {String? assistantId}) async {
    final set = activeBookIdsFor(assistantId).toSet();
    if (set.contains(id)) {
      set.remove(id);
    } else {
      final book = getById(id);
      if (book == null) return;
      if (!book.enabled) return;
      set.add(id);
    }
    await setActiveBookIds(
      set.toList(growable: false),
      assistantId: assistantId,
    );
  }

  /// 按 Agent 已激活的知识书和任务主题返回少量相关条目。
  ///
  /// APK Agent 通过工具主动读取，避免把整本世界书塞入每轮提示词。
  List<Map<String, dynamic>> retrieveActiveEntries({
    required String? assistantId,
    required List<String> topics,
    int limit = 3,
  }) {
    // 泛 topic 过滤：路由 knowledgeTopics 里的超泛词（工具/定位/分析/验证/
    // 文件）几乎匹配所有条目（content contains +2），参与打分只会稀释排序。
    const genericTopics = <String>{
      'apk',
      '工作流',
      'workflow',
      '规则',
      'rules',
      '工具',
      '定位',
      '分析',
      '验证',
      '文件',
    };
    final normalizedTopics = topics
        .map((topic) => topic.trim().toLowerCase())
        .where((topic) => topic.isNotEmpty && !genericTopics.contains(topic))
        .toSet();
    if (limit <= 0) {
      return const <Map<String, dynamic>>[];
    }

    final activeIds = activeBookIdsFor(assistantId).toSet();
    final candidates = <Map<String, dynamic>>[];
    for (final book in _books) {
      if (!book.enabled || !activeIds.contains(book.id)) continue;
      for (final entry in book.entries) {
        if (!entry.enabled || entry.content.trim().isEmpty) continue;
        final name = entry.name.toLowerCase();
        final content = entry.content.toLowerCase();
        final keywords = entry.keywords
            .map((keyword) => keyword.trim().toLowerCase())
            .where((keyword) => keyword.isNotEmpty)
            .toList(growable: false);
        var score = 0;
        if (entry.constantActive) score += 1;
        for (final topic in normalizedTopics) {
          if (name.contains(topic)) score += 8;
          if (content.contains(topic)) score += 2;
          for (final keyword in keywords) {
            if (keyword.contains(topic) || topic.contains(keyword)) score += 6;
          }
        }
        if (score == 0) continue;
        candidates.add({
          'bookId': book.id,
          'bookName': book.name,
          'entryId': entry.id,
          'entryName': entry.name,
          'priority': entry.priority,
          'constantActive': entry.constantActive,
          'score': score,
          'content': entry.content,
        });
      }
    }
    candidates.sort((a, b) {
      final alwaysOrder = ((b['constantActive'] as bool) ? 1 : 0).compareTo(
        (a['constantActive'] as bool) ? 1 : 0,
      );
      if (alwaysOrder != 0) return alwaysOrder;
      final builtInOrder = ((a['bookId'] as String) == _apkModBookId ? 1 : 0)
          .compareTo((b['bookId'] as String) == _apkModBookId ? 1 : 0);
      if (builtInOrder != 0) return builtInOrder;
      final scoreOrder = (b['score'] as int).compareTo(a['score'] as int);
      if (scoreOrder != 0) return scoreOrder;
      return (b['priority'] as int).compareTo(a['priority'] as int);
    });
    return candidates.take(limit.clamp(1, 5).toInt()).toList(growable: false);
  }

  /// 预置 SoLab APK 助手的种子世界书「SoLab APK 知识书」。
  ///
  /// 模式参考 [AssistantProvider.ensureDefaults]：仅在版本 key < 1 时执行
  /// 一次；用户已有同名书则跳过创建，激活列表只追加不清空，绝不覆盖
  /// 用户已有数据。
  ///
  /// 版本 key 2：按「条目 id」补齐新增条目（工具能力总表、分步提问纪律、
  /// 检测规避），存量用户不会缺新知识，也不会重复已有条目。
  /// 版本 key 3：对种子条目做内容同步（检测规避扩展、定位法新条目），
  /// 保留用户对 enabled/priority 等的开关设置，仅覆盖内容与关键词。
  /// 版本 key 9：执行纪律改版——工作目录原项目是只读备份，目标明确即
  /// 果断执行（快准狠）；新增「用户提示词优先」条目；全条目关键词扩充。
  /// 版本 key 10：新增「目标达成：不择手段」条目——目标降级链
  /// （VIP → 免广告奖励直发 → 试用次数/时间劫持）与掐断策略
  /// （初始化/连接处/资源清理三路逐一尝试）。
  /// 版本 key 11：新增「无预算纪律」条目——不存在工具调用预算，
  /// 禁止以「预算有限/要收敛/次数用完」为借口减少工作或提前停下。
  /// 版本 key 12：新增「定位纪律：多信号交叉」条目——双信号定案、
  /// 混淆短名语义恢复、失败升级链（改方法→改字段→上游入口→跨层堵死）。
  /// 版本 key 13：品牌更名——种子书「SoLab APK 知识书」改名为
  /// 「SoLab 知识书」，条目与用户开关全部保留。
  /// 版本 key 14：工具总表切换到当前 20 个执行工具；仅更新仍含旧入口的
  /// 内置条目，不覆盖用户已改写的其他知识内容。
  /// 版本 key 15：修正按需资源、工具说明和远期时间值；只更新仍含旧文案的
  /// 内置条目，不覆盖用户改写内容。
  /// 版本 key 16：明确用户已给出修改目标时，dryRun 后直接执行。
  /// 版本 key 17：全轨道止损状态机、广告四体系和双目标共享分析。
  /// 版本 key 18：预览可同次执行，失败保留凭证并返回精确执行参数。
  /// 版本 key 19：新增统一工作区纪律和 Flutter 体系识别知识；只补缺失
  /// 条目，不覆盖用户修改过的现有内容。
  /// 版本 key 20：签名兼容注入固定为原始 APK 的首次写操作，只执行一次。
  /// 版本 key 23：统一直接证据标准，移除失真的固定调用次数和“顺手清理”，
  /// 并把检测能力说明改为以当前 schema/报告为准。
  /// 版本 key 24：定位改为目标驱动；工具自动组合证据、换路和验证候选。
  /// 版本 key 25：打断后按当前会话快照续接,待验证状态不再跨会话读入。
  /// 版本 key 26：新增「补丁编码假设验证」条目（写补丁前验证寄存器分配）。
  Future<void> ensureApkModSeed() async {
    try {
      final book = _apkModKnowledgeBook();
      final version = preferences.getInt(_apkModSeedVersionKey) ?? 0;

      // v13：旧名迁移——书名仍是旧种子名时重命名为新名（用户改过名则
      // 不动，与旧版按名匹配的行为一致）。
      if (version < 13) {
        var renamed = false;
        for (final b in _books) {
          if (b.id == _apkModBookId && b.name.trim() == 'SoLab APK 知识书') {
            await _store.update(b.copyWith(name: book.name));
            renamed = true;
          }
        }
        if (renamed) await loadAll();
      }

      var currentBook = getById(book.id);

      if (currentBook == null) {
        await _store.add(book);
        currentBook = book;
      } else if (version < 12) {
        // v1~v11 → v12：新增「定位纪律：多信号交叉」条目
        // （保留用户开关设置，仅同步种子条目内容）。
        final byId = <String, WorldBookEntry>{
          for (final e in currentBook.entries) e.id: e,
        };
        final merged = <WorldBookEntry>[];
        for (final seedEntry in book.entries) {
          final existing = byId[seedEntry.id];
          if (existing == null) {
            merged.add(seedEntry);
          } else {
            merged.add(
              existing.copyWith(
                name: seedEntry.name,
                content: seedEntry.content,
                keywords: seedEntry.keywords,
                priority: seedEntry.priority,
              ),
            );
          }
        }
        await _store.update(currentBook.copyWith(entries: merged));
        currentBook = await _store.getAll().then(
          (books) => books.firstWhere((b) => b.id == book.id),
        );
      }

      if (version < 14) {
        final seedEntry = book.entries.firstWhere(
          (entry) => entry.id == 'apk_mod_entry_tool_map',
        );
        var changed = false;
        final entries = currentBook.entries
            .map((entry) {
              if (entry.id != seedEntry.id ||
                  !entry.content.contains('get_solab_tool_map')) {
                return entry;
              }
              changed = true;
              return entry.copyWith(
                name: seedEntry.name,
                content: seedEntry.content,
                keywords: seedEntry.keywords,
                priority: seedEntry.priority,
              );
            })
            .toList(growable: false);
        if (changed) {
          await _store.update(currentBook.copyWith(entries: entries));
          currentBook = currentBook.copyWith(entries: entries);
        }
      }

      if (version < 15) {
        final seedEntries = <String, WorldBookEntry>{
          for (final entry in book.entries) entry.id: entry,
        };
        const staleMarkers = <String, String>{
          'apk_mod_entry_tool_map': '当前 Agent 和 MCP 共用 20 个执行工具。',
          'apk_mod_entry_step_questioning': '用户给出新指示时先复述确认再执行。',
          'apk_mod_entry_detection_evasion': '返回 long 的方法强制远期 0xffffff。',
        };
        var changed = false;
        final entries = currentBook.entries
            .map((entry) {
              final marker = staleMarkers[entry.id];
              final seedEntry = seedEntries[entry.id];
              if (marker == null ||
                  seedEntry == null ||
                  !entry.content.contains(marker)) {
                return entry;
              }
              changed = true;
              return entry.copyWith(
                name: seedEntry.name,
                content: seedEntry.content,
                keywords: seedEntry.keywords,
                priority: seedEntry.priority,
              );
            })
            .toList(growable: false);
        if (changed) {
          await _store.update(currentBook.copyWith(entries: entries));
          currentBook = currentBook.copyWith(entries: entries);
        }
      }

      if (version < 16) {
        final seedEntries = <String, WorldBookEntry>{
          for (final entry in book.entries) entry.id: entry,
        };
        const staleMarkers = <String, String>{
          'apk_mod_entry_risk_and_sign': '所有写操作先 dryRun，再确认。',
          'apk_mod_entry_tool_map': '说明命中与风险后一次确认，再原样携带 previewToken 执行。',
        };
        var changed = false;
        final entries = currentBook.entries
            .map((entry) {
              final marker = staleMarkers[entry.id];
              final seedEntry = seedEntries[entry.id];
              if (marker == null ||
                  seedEntry == null ||
                  !entry.content.contains(marker)) {
                return entry;
              }
              changed = true;
              return entry.copyWith(
                name: seedEntry.name,
                content: seedEntry.content,
                keywords: seedEntry.keywords,
                priority: seedEntry.priority,
              );
            })
            .toList(growable: false);
        if (changed) {
          await _store.update(currentBook.copyWith(entries: entries));
          currentBook = currentBook.copyWith(entries: entries);
        }
      }

      if (version < 17) {
        final seedEntries = <String, WorldBookEntry>{
          for (final entry in book.entries) entry.id: entry,
        };
        const synchronizedIds = <String>{
          'apk_mod_entry_no_budget',
          'apk_mod_entry_minimal_patch',
          'apk_mod_entry_ad_types',
        };
        final entries = currentBook.entries
            .map((entry) {
              final seedEntry = seedEntries[entry.id];
              if (!synchronizedIds.contains(entry.id) || seedEntry == null) {
                return entry;
              }
              return entry.copyWith(
                name: seedEntry.name,
                content: seedEntry.content,
                keywords: seedEntry.keywords,
                priority: seedEntry.priority,
              );
            })
            .toList(growable: false);
        await _store.update(currentBook.copyWith(entries: entries));
        currentBook = currentBook.copyWith(entries: entries);
      }

      if (version < 18) {
        final seedEntries = <String, WorldBookEntry>{
          for (final entry in book.entries) entry.id: entry,
        };
        const synchronizedIds = <String>{
          'apk_mod_entry_risk_and_signature',
          'apk_mod_entry_tool_map',
          'apk_mod_entry_preview_and_memory',
        };
        final entries = currentBook.entries
            .map((entry) {
              final seedEntry = seedEntries[entry.id];
              if (!synchronizedIds.contains(entry.id) || seedEntry == null) {
                return entry;
              }
              return entry.copyWith(
                name: seedEntry.name,
                content: seedEntry.content,
                keywords: seedEntry.keywords,
                priority: seedEntry.priority,
              );
            })
            .toList(growable: false);
        await _store.update(currentBook.copyWith(entries: entries));
        currentBook = currentBook.copyWith(entries: entries);
      }

      if (version < 19) {
        final seedEntries = <String, WorldBookEntry>{
          for (final entry in book.entries) entry.id: entry,
        };
        const addedIds = <String>{
          'apk_mod_entry_workspace_output',
          'apk_mod_entry_flutter_system_identification',
        };
        final existingIds = currentBook.entries
            .map((entry) => entry.id)
            .toSet();
        final additions = <WorldBookEntry>[
          for (final id in addedIds)
            if (!existingIds.contains(id) && seedEntries[id] != null)
              seedEntries[id]!,
        ];
        if (additions.isNotEmpty) {
          final entries = <WorldBookEntry>[
            ...currentBook.entries,
            ...additions,
          ];
          await _store.update(currentBook.copyWith(entries: entries));
          currentBook = currentBook.copyWith(entries: entries);
        }
      }

      if (version < 20) {
        final seedEntry = book.entries.firstWhere(
          (entry) => entry.id == 'apk_mod_entry_risk_and_signature',
        );
        const previousContent =
            '修改风险与签名要点：直接删除 .so 原生库会闪退（UnsatisfiedLinkError），优先定位并修改对应的 loadLibrary/System.load 入口；删除 Manifest 组件可能导致 ActivityNotFoundException，优先只清有证据的权限或元数据；DEX 修改跳过 <init>/<clinit>。用户已明确精确修改目标时，支持的工具使用 dryRun=true+applyAfterPreview=true 一次完成预览与写入；预览有 warning 或无变更会自动阻断。纯 dryRun 返回 applyArguments，必须原样执行，禁止重复预览。产物用 apk_sign 签名后安装；改完方法用 smali_read 回读核验。';
        final entries = currentBook.entries
            .map(
              (entry) =>
                  entry.id == seedEntry.id && entry.content == previousContent
                  ? seedEntry
                  : entry,
            )
            .toList(growable: false);
        if (entries != currentBook.entries) {
          await _store.update(currentBook.copyWith(entries: entries));
          currentBook = currentBook.copyWith(entries: entries);
        }
      }

      if (version < 21) {
        final seedEntry = book.entries.firstWhere(
          (entry) => entry.id == 'apk_mod_entry_no_budget',
        );
        const previousContent =
            '分析止损纪律：状态机按单目标限制启动3次、定位3次、核验8次、补丁4次，工具结果约60K token；会员和广告共享启动与一次 Blutter analyze，各自独立计算 locate/verify。达到上限不是偷懒借口：必须输出已有证据、缺失证据和确定恢复动作；ambiguous/clues_only/not_found 只允许一次询问用户已知文案、等级值或广告出现位置，不继续逐词搜索。长结果只读预览和一次追加，同参数第3次、同失败步骤第3次均由工具阻断。';
        final entries = currentBook.entries
            .map(
              (entry) =>
                  entry.id == seedEntry.id && entry.content == previousContent
                  ? seedEntry
                  : entry,
            )
            .toList(growable: false);
        if (entries != currentBook.entries) {
          await _store.update(currentBook.copyWith(entries: entries));
          currentBook = currentBook.copyWith(entries: entries);
        }
      }

      if (version < 22) {
        const previousContents = <String, String>{
          'apk_mod_entry_tool_map':
              '本轮只声明与当前任务相关且已启用的本地工具；外接工具按需加载。先 route_task；复用有效报告。DEX 单线索用 dex_search；类名、字段名、方法名、字符串、数值、指令序列中有多类证据时用 method_by_features 一次取同一方法交集，再走 class_outline → smali_read → dex_xref；字段读写用 dex_xref(target=dex_field:...)。修改只使用当前声明的写工具。用户已授权精确修改时，优先 dryRun=true+applyAfterPreview=true 一次完成；需要判断的纯预览必须原样调用 applyArguments。直接 DEX 补丁后只需 apk_sign；只有编辑过解码目录、资源或 Manifest 时才 apk_rebuild。',
          'apk_mod_entry_preview_and_memory':
              '写操作必须先预览。精确目标已获授权时用 dryRun=true+applyAfterPreview=true，同一次调用先预览再写入；warning 或无变更不会自动执行。纯 dryRun 返回完整 applyArguments，原样调用即可，禁止靠模型重组参数。previewToken 有效期 30 分钟，写入失败仍可用原 token 重试；写入成功后，基于旧 APK 的全部预览自动失效，后续必须使用 nextInputPath。用户反馈安装结果后调用 record_apk_patch_verification。',
        };
        const replacements = <String, String>{
          'apk_mod_entry_tool_map':
              '本轮只声明与当前任务相关且已启用的本地工具；外接工具按需加载。先 route_task，复用有效报告。DEX 单线索用 dex_search；多类证据用 method_by_features 在同一方法取交集，再走 class_outline → smali_read → dex_xref；字段读写用 dex_xref(target=dex_field:...)。工具参数和写操作契约以当前工具 schema 为准。',
          'apk_mod_entry_preview_and_memory':
              '写操作契约、预览参数与确认语义以当前写工具 schema 为准。用户反馈安装结果后调用 record_apk_patch_verification。',
        };
        final entries = currentBook.entries
            .map((entry) {
              final replacement = replacements[entry.id];
              if (replacement == null ||
                  entry.content != previousContents[entry.id]) {
                return entry;
              }
              return entry.copyWith(content: replacement);
            })
            .toList(growable: false);
        if (entries != currentBook.entries) {
          await _store.update(currentBook.copyWith(entries: entries));
          currentBook = currentBook.copyWith(entries: entries);
        }
      }

      if (version < 23) {
        final seedEntries = <String, WorldBookEntry>{
          for (final entry in book.entries) entry.id: entry,
        };
        final entries = currentBook.entries
            .map((entry) {
              final previousHash = _apkModSeedV22ContentHashes[entry.id];
              final replacement = seedEntries[entry.id];
              if (previousHash == null ||
                  replacement == null ||
                  sha256.convert(utf8.encode(entry.content)).toString() !=
                      previousHash) {
                return entry;
              }
              return entry.copyWith(
                name: replacement.name,
                content: replacement.content,
                keywords: replacement.keywords,
                priority: replacement.priority,
              );
            })
            .toList(growable: false);
        await _store.update(currentBook.copyWith(entries: entries));
        currentBook = currentBook.copyWith(entries: entries);
      }

      if (version < 24) {
        const previousContent =
            '本轮只声明与当前任务相关且已启用的本地工具；外接工具按需加载。先 route_task，复用有效报告。DEX 单线索用 dex_search；多类证据用 method_by_features 在同一方法取交集，再走 class_outline → smali_read → dex_xref；字段读写用 dex_xref(target=dex_field:...)。工具参数和写操作契约以当前工具 schema 为准。';
        final replacement = book.entries.firstWhere(
          (entry) => entry.id == 'apk_mod_entry_tool_map',
        );
        final entries = currentBook.entries
            .map(
              (entry) =>
                  entry.id == replacement.id && entry.content == previousContent
                  ? entry.copyWith(content: replacement.content)
                  : entry,
            )
            .toList(growable: false);
        if (entries != currentBook.entries) {
          await _store.update(currentBook.copyWith(entries: entries));
          currentBook = currentBook.copyWith(entries: entries);
        }
      }

      if (version < 25) {
        const previousContents = <String, String>{
          'apk_mod_entry_tool_map':
              '本轮只声明与当前任务相关且已启用的本地工具；外接工具按需加载。先 route_task，复用有效报告。用户只需给目标和已有线索；DEX 默认调用 dex_search(auto)，由工具自由组合类、方法、字段、字符串、数字和指令证据，严格交集失败时自行拆分换路并排序。候选不是结果：继续执行 nextActions 或任选等价工具核验真实代码、调用处和返回语义，直到得到可修改、可回读的结论；不要要求用户选择定位方式。字段读写可直接用 dex_xref(target=dex_field:...)。工具参数和写操作契约以当前 schema 为准。',
          'apk_mod_entry_preview_and_memory':
              '写操作契约、预览参数与确认语义以当前写工具 schema 为准。用户反馈安装结果后调用 record_apk_patch_verification。',
        };
        final seedEntries = <String, WorldBookEntry>{
          for (final entry in book.entries) entry.id: entry,
        };
        final entries = currentBook.entries
            .map((entry) {
              final previous = previousContents[entry.id];
              final replacement = seedEntries[entry.id];
              if (previous == null ||
                  replacement == null ||
                  entry.content != previous) {
                return entry;
              }
              return entry.copyWith(content: replacement.content);
            })
            .toList(growable: false);
        if (entries != currentBook.entries) {
          await _store.update(currentBook.copyWith(entries: entries));
          currentBook = currentBook.copyWith(entries: entries);
        }
      }

      if (version < 26) {
        // v26：新增「补丁编码假设验证」条目——写 SO 补丁前必须在原始
        // 二进制验证寄存器/编码假设（如 NULL_REG 是 x17 还是 x22），
        // 禁止照搬 Blutter 文档默认分配。
        const newEntryId = 'apk_mod_entry_patch_encoding_verification';
        if (!currentBook.entries.any((entry) => entry.id == newEntryId)) {
          final seedEntry = book.entries.firstWhere(
            (entry) => entry.id == newEntryId,
          );
          final merged = <WorldBookEntry>[...currentBook.entries, seedEntry];
          await _store.update(currentBook.copyWith(entries: merged));
          currentBook = currentBook.copyWith(entries: merged);
        }
      }

      // 绑定到 SoLab 助手：在既有激活列表上追加，不清空用户配置。
      final activeMap = await _store.getActiveIdsByAssistant();
      final key = WorldBookStore.assistantKey(_apkModAssistantId);
      final existing = activeMap[key] ?? const <String>[];
      if (!existing.contains(book.id)) {
        await _store.setActiveIds(
          <String>{...existing, book.id}.toList(growable: false),
          assistantId: _apkModAssistantId,
        );
      }
      await preferences.setInt(_apkModSeedVersionKey, 26);
      await loadAll();
    } catch (e) {
      debugPrint('Failed to seed SoLab world book: $e');
    }
  }

  WorldBook _apkModKnowledgeBook() {
    return WorldBook(
      id: _apkModBookId,
      name: 'SoLab 知识书',
      description: 'APK 修改助手的内置知识：内置工具链流程、广告 SDK、修改风险、精简与脱壳判断。',
      enabled: true,
      entries: const <WorldBookEntry>[
        WorldBookEntry(
          id: 'apk_mod_entry_mt_toolchain',
          name: '外部 MT MCP（可选）',
          priority: 20,
          keywords: <String>[
            'MT修改',
            'MT工具',
            'edit_session',
            'locator',
            'mt_apk',
          ],
          content:
              'MT Manager 是可选的外部 MCP：仅当用户自行配置了 MT MCP 服务器并明确要求走 MT 流程时才使用其 mt_* 工具；内置工具链（分析/定位/patch/签名/验签）完全自闭环，一律优先使用内置工具，不依赖也不等待 MT。若确实使用 MT：先 mt_apk_open 打开目标（APK 参数名是 apk 不是 path；会话标识是 sessionId），edit_open 建立编辑会话，read_text 读取 locator 与 targetVersion，edit_text 提交修改（edits[] 每项含 mode/matchText/writeText），edit_check（runBuildChecks=true）构建校验，最后 build（sign=true 签名）。locator 格式为 axml:/、dex_class:/、dex_method:/、zip_entry:/、resource:0x…；valueXml 必须传完整值。业务错误（WORKSPACE_NOT_FOUND/EDIT_SESSION_NOT_FOUND/TARGET_VERSION_MISMATCH）按提示重建会话/刷新版本后重试。MT 产物与内置产物索引互不相通。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_ad_sdk',
          name: '广告 SDK 速查',
          priority: 10,
          keywords: <String>[
            '广告SDK',
            '穿山甲',
            '腾讯广告',
            '快手广告',
            'AdMob',
            '去广告',
            '广告',
            'Pangle',
            'GDT',
            '优量汇',
            'Mintegral',
            'TopOn',
            '信息流',
            '插屏',
            '开屏',
          ],
          content:
              '常见广告 SDK 典型包名速查：腾讯广告 GDT（com.qq.e.*）、穿山甲 Pangle（com.bytedance.sdk.openadsdk.*）、快手（com.kuaishou.ad.*）、百度（com.baidu.mobads.*）、Sigmob（com.sigmob.*）、米萌（com.miui.zeus.*）、Mintegral（com.mbridge.*）、AdMob（com.google.android.gms.ads.*）、CAS（com.cleversolutions.ads.*）、TapTap（com.tapsdk.*）、TopOn（com.anythink.*）、倍孜（com.beizi.*）、京东 JAD（com.jd.ad.*）、Moqi（com.moqi.*）。识别组件特征：广告相关 Activity、loadAd/onAdLoad 回调、Banner/激励视频/插屏，以及 manifest 中声明的广告组件与权限。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_risk_and_signature',
          name: '修改风险与签名',
          priority: 10,
          keywords: <String>[
            '签名',
            '重打包',
            '闪退',
            'UnsatisfiedLinkError',
            '验签',
            '证书',
            '安装失败',
            '崩溃',
            'loadLibrary',
            '死代码',
            '回读',
          ],
          content:
              '修改风险与签名要点：直接删除 .so 原生库会闪退（UnsatisfiedLinkError），优先定位并修改对应的 loadLibrary/System.load 入口；删除 Manifest 组件可能导致 ActivityNotFoundException，优先只清有证据的权限或元数据；DEX 修改跳过 <init>/<clinit>。分析、签名兼容、修改、构建和签名都可独立调用；除非用户要求跳过去签或工作台设为不开启，首次业务写入前用独立的 signature_bypass 工具对未改原 APK 执行：用户指定模式优先，未指定时跟随 APK 工作台设置。把返回的 outputPath 作为后续 DEX、SO、Manifest 和资源修改的唯一输入，后续调用不混入签名注入，禁止修改后补做或重复注入。dpatch 和 original_apk 都不允许直接修改原包。用户已明确精确修改目标时，支持的工具使用 dryRun=true+applyAfterPreview=true 一次完成预览与写入；预览有 warning 或无变更会自动阻断。纯 dryRun 返回 applyArguments，必须原样执行，禁止重复预览。最终产物用 apk_sign 签名后安装；改完方法用 smali_read 回读核验。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_slim_candidates',
          name: '精简候选规则',
          priority: 10,
          keywords: <String>[
            '精简',
            '.proto',
            '未知文件',
            'SO',
            'ABI',
            '删除文件',
            '清理',
            '多余',
            '无用',
            '体积',
            '瘦身',
            'arm64',
            'armeabi',
          ],
          content:
              '精简候选判定规则：.proto/.pb/.bin 等未知格式文件必须先在 DEX 中检索引用（字符串、类名、资源 id），确认无引用后才能列入删除候选，禁止按扩展名盲删；.so 原生库默认保留，除非确认没有 loadLibrary 引用；按 ABI 过滤（如只保留 arm64-v8a）会缩小设备兼容范围，需要向用户说明影响；权限显示“未发现静态调用”只代表静态扫描未命中，仍可能被系统或动态方式使用，应标为待确认。每项候选都须给出命中依据。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_unpacking',
          name: '脱壳判断',
          priority: 10,
          keywords: <String>[
            '脱壳',
            '加固',
            '壳',
            '360加固',
            '乐固',
            '加壳',
            '梆梆',
            '爱加密',
            'libshell',
            'libDexHelper',
            'dex加密',
          ],
          content:
              '动手修改前必须先判断 APK 是否加壳：常见加固有 360 加固、腾讯乐固、梆梆、爱加密等。有壳包的直接修改通常无效——核心 dex 在运行时才解密加载，改了也不生效。正确流程：先确认脱壳状态；已脱壳的包要校验 dex 可正常解析、壳相关 so（如 libshell、libDexHelper）已清理、入口类完整；未脱壳的包应明确告知用户需先脱壳，拒绝直接修改。脱壳相关操作须在用户确认后进行。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_confirmation_discipline',
          name: '修改前执行摘要',
          priority: 10,
          keywords: <String>['修改计划', '变更清单', '风险', '验证', '变更', '执行前', '影响'],
          content:
              '写入前只给必要摘要：目标、精确定位符、决定性证据、改动、风险和验证方法。目标明确且已授权就直接进入工具预览，不重复索要确认；只有目标不明、方案有实质取舍或预览不符时提问。事实、推断和待验证项必须分开，工具未返回的内容不补写。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_tool_map',
          name: '本地修改工具总表',
          priority: 20,
          keywords: <String>[
            '工具',
            'patch_apk',
            '什么时候用',
            '选工具',
            '怎么改',
            '用哪个',
            '修改流程',
            '工具链',
            '怎么去广告',
            '怎么精简',
          ],
          content:
              '本轮只声明与当前任务相关且已启用的本地工具；外接工具按需加载。先读当前对话注入的 apk_resume_state：打断后直接沿 activeArtifact、latestSoArtifact、recentToolCheckpoints 与 pendingChanges 续接；fresh 且 resumableLineage=true 的报告仍是当前修改链基线，禁止重跑全量分析。不得读取其他对话的产物笔记补上下文。用户只需给目标和已有线索；DEX 默认调用 dex_search(auto)，由工具自由组合类、方法、字段、字符串、数字和指令证据，严格交集失败时自行拆分换路并排序。候选不是结果：继续核验真实代码、调用处和返回语义，直到得到可修改、可回读的结论。工具参数和写操作契约以当前 schema 为准。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_workspace_output',
          name: '统一工作区与产物路径',
          priority: 20,
          keywords: <String>[
            '工作目录',
            '工作区',
            '路径',
            '产物',
            '重复分析',
            '缓存',
            '找不到路径',
            'nextInputPath',
            'workspace',
            'output',
          ],
          content:
              '路径纪律：先用当前报告或工作区工具确认 sourceApk、workspaceRoot 和当前输入；同一源 APK 只绑定到一个以现有 App 名称命名的工作区，禁止同时在工作目录根部和 App 子目录重复分析。每个工具返回的 outputPath/nextInputPath 是下一步唯一输入，必须原样传递，不能凭文件名猜路径。可交付 APK、报告、反编译结果和补丁记录都写入该工作区；内部临时目录只允许短期计算并在任务结束清理，不能作为交付地址。路径不存在时先 list_workspace_apks 或 get_apk_project_info 查真实路径，不重新全量分析。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_flutter_system_identification',
          name: 'Flutter AOT 混淆字段定位',
          priority: 20,
          keywords: <String>[
            'pp.txt',
            'Flutter',
            'libapp.so',
            'Blutter',
            '字段混淆',
            '字段偏移',
            '数据流',
            '立即数',
          ],
          content:
              'Flutter AOT 混淆定位不预设业务名、字段名或常量。先从用户目标提取多个语义线索，在 pp.txt 收敛真实字段键；键只出现在解析器时，用 trace 建立键引用→字段写入→同偏移读取→寄存器消费链。decisionEvidence 证明读取值进入比较、条件分支、布尔结果或返回时才提高置信度；只有相同偏移的 low 候选不能修改。用户给出的整数由 values 同时检查原始立即数、Dart Smi 和对象池整数；内存寻址偏移、集合长度不算业务值。最终必须由语义、字段数据流和真实分支/返回三类证据闭合。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_patch_encoding_verification',
          name: '补丁编码假设验证',
          priority: 20,
          keywords: <String>[
            '寄存器',
            '编码',
            'patchHex',
            'edit_hex',
            'writeAsm',
            'NULL_REG',
            'x17',
            'x22',
            '字节',
            '手写补丁',
            '汇编',
            '写补丁',
          ],
          content:
              '写 SO 补丁字节前必须先在原始二进制里验证编码假设，禁止照搬文档或通用模式的默认寄存器分配。每个构建的寄存器分配都可能不同：Blutter 文档默认 NULL_REG=x17，但很多构建实际用 x22（callee-saved，跨函数持有）；x17/IP1 是平台临时寄存器，运行时可能装入垃圾值。验证方法 30 秒完成：用 so_analyze(action=hexdump/search) 统计目标编码全 SO 的真实出现次数——例如 add x1,x17,#0x20 全文件 0 命中而 add x1,x22,#0x20 数百命中，即可排除 x17。最终采用的补丁字节应与编译器原生生成的同语义指令逐字节一致；手写汇编同理，先找同函数或邻近函数里编译器生成的同模式指令作参照。edit_hex 传补丁时优先用 edits[i].va（绝对 VA，与 disasm 返回值直接对齐），不用 byteOffset 相对换算；build 必须显式传 editSessionId，否则会被 EDIT_SESSION_REQUIRED 拦截。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_preview_and_memory',
          name: '预览确认与验证经验',
          priority: 20,
          keywords: <String>[
            'dryRun',
            'previewToken',
            '确认',
            '验证',
            '记忆',
            '预览',
            'preview',
            '凭证',
            '过期',
            '安装包有效',
            '无效',
            '记录验证',
          ],
          content:
              '写操作契约、预览参数与确认语义以当前写工具 schema 为准。待验证修改只保存在当前对话快照,不读取其他会话的产物笔记,也不写长期记忆。用户安装并明确反馈后才调用 record_apk_patch_verification,并合并到当前 APP 的唯一一条记忆。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_step_questioning',
          name: '执行纪律：快准狠',
          priority: 20,
          keywords: <String>[
            '提问',
            '确认',
            '分步',
            '一步一步',
            'ask_user_input_v0',
            '备份',
            '快准狠',
            '评估',
            '犹豫',
            '直接执行',
            '该动手就动手',
            '畏手畏脚',
            '不懂就问',
            '预算',
            '收敛',
          ],
          content:
              '执行纪律（快准狠）：工作目录里的原项目是只读备份，所有修改都发生在副本或中间包上，不碰原件。目标明确就直接执行，风险一句话提示即可；同一信息不反复分析、不逐步追问。提问只留三种场景：1) 目标不明确或有多种实质不同的方案；2) dryRun 命中与用户目标明显不符；3) 线索不足。一次问全，不瞎猜。每完成一个阶段汇报结果并继续下一步，不逐步问“是否继续”。用户的新指示直接作为当前目标执行。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_no_budget',
          name: '分析性能与止损',
          priority: 20,
          keywords: <String>[
            '预算',
            '工具预算',
            '预算有限',
            '收敛',
            '要收敛',
            '次数',
            '限额',
            '上限',
            '省着',
            '节省调用',
            '聚焦',
            '时间不多了',
            '来不及',
            '干不完',
            '做不完',
            '挑重点',
            '先做能做的',
            '放弃',
            '跳过',
          ],
          content:
              '分析性能纪律：没有固定调用次数，阶段额度只是软提示；约 80K 可见证据文本是防失控硬上限，不是必须跑满的流程。每次调用必须能改变候选排序、证据等级或补丁手法，否则停止。会员与广告可共享一次工作区分析和 Blutter 索引，但分别维护定位证据。长结果默认只读紧凑摘要，只有 hasMore/nextOffset 且下一页会改变判断时才翻页；同参数失败后换证据维度。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_user_hint_first',
          name: '用户提示词优先',
          priority: 20,
          keywords: <String>[
            '提示',
            '提示词',
            '用户说',
            '用户提到',
            '指定',
            '按需求',
            '别瞎找',
            '瞎找',
            '定位线索',
            '多思考',
          ],
          content:
              '调用工具前先精读用户原话——用户的话里通常自带定位提示词：文件名、类名/方法名、SDK/厂商名、界面文字、功能描述（如「会员」「开屏」「签到」）。把这些提示直接当第一定位线索：用户点名了文件就先分析那个文件，点名了功能就直接查对应入口，禁止抛开提示词做无方向的全量扫描。同一信号反复未命中说明方向错了——回到用户原话重新读提示，而不是换关键词继续盲扫。线索不够时按最小缺口一次问全（ask_user_input_v0），不瞎猜乱试。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_multi_signal',
          name: '定位纪律：多信号交叉',
          priority: 20,
          keywords: <String>[
            '多信号',
            '交叉验证',
            '置信度',
            'confidence',
            '单信号',
            '混淆',
            '短名',
            '语义恢复',
            '改字段',
            '上游入口',
            '跨层堵死',
            '改不动',
            '无效',
          ],
          content:
              '定位证据标准：当前函数体或字段数据流直接表达目标行为时可单点定案；否则从字符串/资源、常量、调用关系、控制流形态、字段读写和返回值传播中选择两个独立来源。报告候选、UI 文案、包名和同名方法只算线索。混淆短名通过调用方、被调函数、字段 READ/WRITE、签名和地址恢复语义。方法、字段、上游入口、调用处分支和跨层路径都是可独立选择的方案，不是必须顺序执行的升级链；失败后换观察维度。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_relentless_goal',
          name: '本地替代路径',
          priority: 20,
          keywords: <String>[
            '替代路径',
            '本地消费点',
            '搞不定',
            '做不到',
            '达不到',
            '没效果',
            '未生效',
            'VIP',
            '会员',
            '解锁',
            '免广告',
            '奖励',
            '激励视频',
            '试用',
            '次数',
            '限免',
            '保护',
            '校验',
            '初始化',
            '掐断',
            '连接处',
            '清理',
            '降级',
          ],
          content:
              '本地替代路径：原目标存在服务端校验时，只评估与当前 APK 证据相关的本地等效点，例如本地权益消费、奖励回调、试用计数或有效期计算。每条路径都必须先证明存在真实本地消费点，再选择副作用最小的一项；不存在本地消费证据时明确说明边界。初始化、连接点、资源、组件和权限分别判断，禁止为了“顺手清理”扩大改动面。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_detection_evasion',
          name: '检测规避与时间劫持',
          priority: 10,
          keywords: <String>[
            'VPN',
            '模拟器',
            '检测规避',
            'isvpn',
            'isemulator',
            'removeVpnDetection',
            'removeEmulatorDetection',
            'Root',
            '反调试',
            'isrooted',
            'isdebuggable',
            '时间劫持',
            'getExpireTime',
            '会员',
            'VIP',
            'isVip',
            '过期',
            '试用',
            '强制true',
          ],
          content:
              '检测规避与时间修改必须以当前 patch_apk_dex_methods schema 和当前报告候选为准，禁止依赖历史关键词数量。名称命中只生成候选；先核对返回类型、真实方法体、调用方和字段数据流，再提交最小 qualifiedId 集合。构造器、类初始化器和回调不按名称批量改。预览范围过宽或含无关方法时立即阻断并缩小目标；本地修改不能替代服务端校验。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_locating',
          name: '代码定位法与先验证后修改',
          priority: 10,
          keywords: <String>[
            '定位',
            '字符串搜索',
            '抓包',
            'Jadx',
            '验证',
            '找不到方法',
            '找不到',
            '定位不到',
            '界面文字',
            '日志',
            'logcat',
          ],
          content:
              '报告未命中但用户指认某个功能时，不猜测方法名，用定位法收集线索：1) 字符串搜索（成功率最高）——搜索界面看到的文字；2) 抓包字段名——抓包看到 vipLevel/token 等字段名，到反编译结果里搜；3) 日志分析——logcat 搜 TAG 定位类；4) 交叉引用——核对字段读写、方法调用者和返回值。方法论铁律：先验证后修改——用字符串、字段读写、调用链和反汇编结果交叉确认修改位置，确认后再做最小永久修改，避免改错位置白签一轮包。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_minimal_patch',
          name: '单点修复与最小修改',
          priority: 20,
          keywords: <String>[
            '单点修复',
            '入口方法',
            '最小修改',
            'adEntryMethodMatches',
            '别到处改',
            '杜绝',
            'splash',
            '开屏',
            '入口',
            '上游',
            '批量',
            '只改一处',
          ],
          content:
              '单点修复铁律：广告必须先区分 SDK 初始化、展示触发、远程配置和容器 UI。默认优先已验证的本地展示闸门：shouldShowAd/canShowAd 等 bool 返回恒 false，show/play 等 void 展示触发用 nop_out 或已验证分支替换。initSdk/initAd 只在调用链证明它是唯一上游入口且跳过后不会留下占位或崩溃时修改；初始化停止不能直接当成广告展示已关闭。远程配置和容器 UI 单独命中只算线索。每类功能只改三重证据闭合的最小必要集，禁止一次提交几十个候选。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_ad_types',
          name: '八类广告速查',
          priority: 10,
          keywords: <String>[
            '广告类型',
            'splash',
            'banner',
            'feed',
            'interstitial',
            'reward',
            'fullVideo',
            'native',
            'rewardInterstitial',
            '信息流',
            '激励插屏',
            '开屏广告',
            '横幅',
            '激励视频',
            '原生广告',
          ],
          content:
              '主流广告 8 类：1 splash 开屏、2 banner 横幅、3 feed 信息流、4 interstitial 插屏、5 reward 激励视频、6 fullVideo 全屏视频、7 native 原生、8 rewardInterstitial 激励插屏。定位时按实际出现类型查询 showSplashAd/showFeedAd/showInterstitialAd/showRewardedAd/showNativeAd 等展示触发，并用 callers/xref 确认业务调用；SDK 初始化、远程配置和容器 View 不能单独作为展示关闭的证据。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_evidence_ladder',
          name: '逆向定位证据链',
          priority: 20,
          keywords: <String>[
            '界面文字',
            '资源 ID',
            '布局',
            '抓包',
            '日志',
            '交叉引用',
            '调用链',
            '调用方',
            '反查',
          ],
          content:
              '定位按证据强度推进：先取界面文字或资源 ID，再查布局和调用方；网络问题用抓包字段反查代码；运行异常用日志 TAG 收敛类名；最后用交叉引用确认上游入口。每一步都把“线索→真实方法定义→调用方→预览命中”写清，找不到只表示当前证据不足，不能推断功能不存在。',
        ),
        WorldBookEntry(
          id: 'apk_mod_entry_engine_boundaries',
          name: '引擎与规则边界',
          priority: 10,
          keywords: <String>[
            'Flutter',
            'Unity',
            'React Native',
            'Xamarin',
            'Smali 正则',
            'libapp.so',
            'il2cpp',
            '游戏引擎',
            '跨平台',
          ],
          content:
              '先按文件特征识别引擎：Flutter 看 flutter_assets/libapp.so，React Native 看 bundle，Unity 看 il2cpp/metadata，Xamarin 看 DLL。现有自动工具只处理可验证的 DEX、Manifest、ZIP 条目；原始 Smali 正则只作为人工研究线索，不自动执行。需要新增特征时从 APK 工作目录的“特征规则库”界面添加、导入、启停，并通过 dryRun 验证命中范围。',
        ),
      ],
    );
  }
}
