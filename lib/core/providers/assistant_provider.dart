import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../utils/sandbox_path_resolver.dart';
import '../database/business_preferences.dart';
import '../models/assistant.dart';
import '../models/assistant_regex.dart';
import '../models/preset_message.dart';
import '../services/chat/chat_service.dart';
import '../services/local_tools/local_tool_names.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/avatar_cache.dart';
import '../../utils/app_directories.dart';
import '../../features/solab_apk/services/apk_agent_policy.dart';

class AssistantProvider extends ChangeNotifier {
  static const String _assistantsKey = 'assistants_v1';
  static const String _currentAssistantKey = 'current_assistant_id_v1';
  static const String apkModAssistantId = 'builtin-apk-mod';
  static const String _apkModAssistantVersionKey =
      'builtin_apk_mod_assistant_version';
  static const int _apkModAssistantVersion = 89;

  static const _apkModSystemPrompt =
      '''You are SoLab, an Android APK reverse-engineering and modification agent. Only assist with packages the user is authorized to analyze, modify, and distribute.

## Core Principles

${ApkAgentPolicy.sharedDecisionPolicy}

1. **Resume first.** The injected `apk_resume_state` is the durable state of this conversation. After interruption, continue from its active artifact, pending changes, latest SO, and tool checkpoints. A fresh report whose active artifact is a verified descendant (`resumableLineage=true`) remains the baseline; do not analyze again. Analyze only when this conversation has no usable report or it is truly stale. Every tool is independently callable — call exactly what the user's request needs; never run a fixed full pipeline (analyze → …) as a habit.

2. **Route by intent.** Load only relevant tools:
   - Dart logic (VIP/subscription/player) → Blutter / libapp.so
   - Ad logic → classify SDK init / display trigger / remote config / UI container, then route the verified target to Dart, DEX, or SO
   - SO analysis → Rizin/LIEF/Unidbg
   - Structural ops → file/ABI/ZIP tools
Cross-layer tasks are handled layer by layer.

   Do not assume a target is in Dart merely because the APK uses Flutter, or in SO merely because DEX searches miss it.

## Layer Rules

Agent mode按任务加载本地工具；已连接的外部 MCP 工具以 `mcp__<server>__<tool>` 出现，并保留其参数定义。普通聊天不加载执行工具。只调用本轮实际出现的工具。

Use the smallest connected workflow: fresh report → locate → verify → write → sign. Write-operation contracts, arguments, and preview behavior are defined by each tool schema; pass returned paths, locators, tokens, and task IDs verbatim. Never invent an identifier or call an unavailable tool.

Instruction injections are already applied. `route_task.activeBuiltInSkills` and `activeInstalledSkills` are active instructions for the current task; follow their rules directly and do not reread them. Read a full Skill, runtime guide, memory, world book, or rule only when it can change the next action. On a resumed task, current-conversation checkpoints win: do not read patch memory or notes just because generation was interrupted. At a genuinely new task, only read verified memory for the exact current app when it is useful. Never import pending artifact notes from another conversation.

For rule-sensitive work, read matching APK rules after the report. Record the installed outcome only after user verification; unverified findings remain in the current conversation checkpoint and never enter long-term memory.

Locators use the canonical forms: `dex_class:...`, `dex_method:...`, `dex_field:...`, `string:"..."`, `so:...`, `native:...@VA`, `zip_entry:...`. Every high-level API returns the unified format: `summary / score / confidence / evidenceLevel(L0-L4) / sufficiency / stop_reason / primary_candidates / next_best_actions`.

**DEX:** Give all available class, method, field, string, number, and opcode evidence to `dex_search(auto)`; it may change search paths internally. Follow its verification targets with `smali_read` and `dex_xref`. Consider all dex files before making global absence claims. String candidates in reports are clues, not patch targets.

**SO:** Confirm backend → structure → functions → xrefs → crypto. Segment large SOs. Prefer real symbols; use tool-returned names/VAs when stripped. Empty xref sites need caller/data-flow verification. Emulation only after static location.

**Flutter/Blutter:** Read the saved focused report first. Only run `locate` when REPORT_NOT_READY, and only run async analysis when no succeeded job exists. Membership and ads share one analysis index but use separate locate/verify tracks. When `rawDecisionFlow` joins labels, comparison values, calls, and a return ladder, use its first high-confidence function and perform at most one exact native disasm; do not resume keyword searches or browse Blutter folders. Always use `verificationVa`, not the start of an incomplete Blutter function. If version unsupported, switch paths immediately. Verify file consistency before patching.

**Ads:** Classify SDK initialization, display triggers, remote configuration, and UI containers separately. A local bool gate such as shouldShowAd/canShowAd or a verified void show/play trigger is the preferred target. SDK initialization, remote config, or UI container hits alone are clues, not proof that disabling them removes display safely.

## Modification Rules

- Prefer one verified local decision/display gate over batch patches; match the patch to function shape and preserve calling conventions.
- Escalate method → field → upstream init → cross-layer block; no in-place retries.
- Ask only for an unclear target, a material trade-off, or a mismatched preview. Guard limits are supplied in tool results.

## Status Discipline

Report exactly what is done:
- Analyzed
- Located
- dryRun'd
- Modified
- Signed
- Verified

Never label plans, dryRuns, candidates, or unverified results as completed or verified.

## Memory

Save only stable facts (identity, workflow, preferences, stable environment). Read via dedicated tools; never guess from indexes. APK changes stay in the current conversation checkpoint until the user verifies the installed artifact; only then merge them into the exact app's single patch memory.

## Language

Reply to the user in Simplified Chinese.
Tool calls, code, paths, tool names, and raw errors remain in English.
Use tool and API terminology exactly as defined by the available tools and skills. Do not invent translated tool names or parameters.

## Final Check

Before each substantive action, identify the claim, current evidence, and smallest direct verification.

Keep responses concise and proactively continue the task.''';

  /// 系统提示「静态核心」段：纯闲聊/Tool-Free（ToolLoadPolicy.none）时使用。
  ///
  /// 刻意精炼：只含身份、回答规范与诚实原则，不含 APK 工作流/重型工具纪律
  /// （那一整段只在本轮真正挂载工具时注入，避免「你好」也背上 5k 提示文字）。
  static const String apkModSystemPromptCore =
      '''你是 SoLab 助手，只协助用户处理其有权分析、修改和分发的 Android 安装包。

当前对话为纯聊天/打招呼场景，本轮不使用任何工具。请自然、简洁地用简体中文
回应用户；代码、命令、路径、工具名与接口报错原文可保留英文。
仅基于已知信息回答：不确定的明确说明，不编造事实。''';

  static const _apkModToolIds = <String>[
    // 与 MCP 完全一致的执行工具。
    LocalToolNames.routeTask,
    LocalToolNames.apkReport,
    LocalToolNames.apkAnalyzeWorkspace,
    LocalToolNames.apkArchive,
    LocalToolNames.apkExportReport,
    LocalToolNames.dexSearch,
    LocalToolNames.dexXref,
    LocalToolNames.classOutline,
    LocalToolNames.smaliRead,
    LocalToolNames.jadxDecompile,
    LocalToolNames.stringScan,
    LocalToolNames.file,
    LocalToolNames.apkPatchDex,
    LocalToolNames.apkSignatureBypass,
    LocalToolNames.apkPatchManifest,
    LocalToolNames.apkRebuild,
    LocalToolNames.apkSign,
    LocalToolNames.soAnalyze,
    LocalToolNames.soPatchIntoApk,
    'analyzer.open',
    'analyzer.global_search',
    'analyzer.find_field_usage',
    'analyzer.analyze_business_state',
    // Agent 专用交互与上下文资源。
    LocalToolNames.askUser,
    LocalToolNames.agentRuntimeGuide,
    LocalToolNames.apkToolMap,
    LocalToolNames.apkListWorkspace,
    LocalToolNames.apkProjectInfo,
    LocalToolNames.apkListBuilds,
    LocalToolNames.apkCleanupBuilds,
    LocalToolNames.apkSkill,
    LocalToolNames.apkKnowledge,
    LocalToolNames.installedSkills,
    // 自定义特征规则与跨会话经验/笔记。
    LocalToolNames.apkRules,
    LocalToolNames.apkPatchMemory,
    LocalToolNames.apkSavePatchMemory,
    LocalToolNames.apkRecordPatchVerification,
    LocalToolNames.apkNoteRead,
    LocalToolNames.apkNoteWrite,
  ];

  static String get apkModSystemPrompt => _apkModSystemPrompt;
  static List<String> get apkModToolIds =>
      List<String>.unmodifiable(_apkModToolIds);

  final BusinessPreferences preferences;
  final List<Assistant> _assistants = <Assistant>[];
  String? _currentAssistantId;
  final ChatService? chatService;

  List<Assistant> get assistants => List.unmodifiable(_assistants);
  String? get currentAssistantId => _currentAssistantId;
  Assistant? get currentAssistant {
    final idx = _assistants.indexWhere((a) => a.id == _currentAssistantId);
    if (idx != -1) return _assistants[idx];
    if (_assistants.isNotEmpty) return _assistants.first;
    return null;
  }

  bool get currentSearchEnabled => currentAssistant?.searchEnabled ?? false;

  AssistantProvider({required this.preferences, this.chatService}) {
    loaded = _load();
  }

  late final Future<void> loaded;

  Future<void> _load() async {
    if (!preferences.isLoaded) {
      await preferences.load();
    }
    final raw = preferences.getString(_assistantsKey);
    if (raw != null && raw.isNotEmpty) {
      _assistants
        ..clear()
        ..addAll(_decodeAssistants(raw));
      // Fix any sandboxed local paths (avatars/backgrounds) imported from other platforms
      bool changed = false;
      for (int i = 0; i < _assistants.length; i++) {
        final a = _assistants[i];
        String? av = a.avatar;
        String? bg = a.background;
        var itemChanged = false;
        if (av != null &&
            av.isNotEmpty &&
            (av.startsWith('/') || av.contains(':')) &&
            !av.startsWith('http')) {
          final fixed = SandboxPathResolver.fix(av);
          if (fixed != av) {
            av = fixed;
            changed = true;
            itemChanged = true;
          }
        }
        if (bg != null &&
            bg.isNotEmpty &&
            (bg.startsWith('/') || bg.contains(':')) &&
            !bg.startsWith('http')) {
          final fixedBg = SandboxPathResolver.fix(bg);
          if (fixedBg != bg) {
            bg = fixedBg;
            changed = true;
            itemChanged = true;
          }
        }
        if (itemChanged) {
          _assistants[i] = a.copyWith(avatar: av, background: bg);
        }
      }
      if (changed) {
        try {
          await _persist();
        } catch (_) {}
      }
    }
    // Do not create defaults here because localization is not available.
    // Defaults will be ensured later via ensureDefaults(context).
    // Restore current assistant if present
    final savedValue = preferences.get(_currentAssistantKey);
    final savedId = savedValue is String ? savedValue : null;
    if (savedId != null && _assistants.any((a) => a.id == savedId)) {
      _currentAssistantId = savedId;
    } else {
      _currentAssistantId = null;
    }
    notifyListeners();
  }

  List<Assistant> _decodeAssistants(String raw) {
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in decoded)
          if (e is Map) Assistant.fromJson(e.cast<String, dynamic>()),
      ];
    } catch (_) {
      return const <Assistant>[];
    }
  }

  Assistant _apkModAssistant() => _apkModAssistantDefinition().copyWith(
    systemPrompt: _apkModSystemPrompt,
    localToolIds: _apkModToolIds,
  );

  Assistant _apkModAssistantDefinition() => const Assistant(
    id: apkModAssistantId,
    name: 'SoLab',
    useAssistantName: true,
    thinkingBudget: -1,
    temperature: 0.2,
    // 历史摘要存在时保留完整上下文直到摘要替换旧消息；摘要缺失或失败时，
    // 最终请求只保留最近 24 条，防止上下文无限增长。
    contextMessageSize: 24,
    limitContextMessages: true,
    // v71：工具默认开启——内置搜索 + 内置 fetch（solab_fetch 内存 MCP）。
    searchEnabled: true,
    mcpServerIds: <String>['solab_fetch'],
    // systemPrompt 唯一事实源是 _apkModSystemPrompt（_apkModAssistant 经
    // copyWith 覆盖注入）；此处不重复内联，避免两份提示词漂移。
    localToolIds: _apkModToolIds,
    enableMemory: true,
    autoOrganizeMemory: true,
    memoryWriteScope: MemoryWriteScope.alwaysAssistant,
    // 会话上下文压缩：开启摘要生成（每 N 条新消息自动总结旧消息），
    // 上下文满时用摘要替换已总结旧消息继续追加（不再硬裁失忆）
    allowPastConversationRecall: true,
    generateConversationSummary: true,
  );

  // Ensure the built-in SoLab APK assistant exists; call this after localization is ready.
  Future<void> ensureDefaults(dynamic context) async {
    await loaded;
    var changed = false;
    if (_assistants.isEmpty) {
      // 仅内置 SoLab APK 助手，不再创建默认/示例助手
      _assistants.add(_apkModAssistant());
      changed = true;
    }
    if (_assistants.every((assistant) => assistant.id != apkModAssistantId)) {
      _assistants.add(_apkModAssistant());
      changed = true;
    }
    final storedVersion = preferences.getInt(_apkModAssistantVersionKey) ?? 0;
    if (_assistants.any((a) => a.id == apkModAssistantId) &&
        storedVersion < _apkModAssistantVersion) {
      final index = _assistants.indexWhere(
        (assistant) => assistant.id == apkModAssistantId,
      );
      final template = _apkModAssistant();
      final existing = _assistants[index];
      _assistants[index] = existing.copyWith(
        systemPrompt: template.systemPrompt,
        contextMessageSize: template.contextMessageSize,
        limitContextMessages: template.limitContextMessages,
        searchEnabled: template.searchEnabled,
        thinkingBudget: existing.thinkingBudget ?? template.thinkingBudget,
        mcpServerIds: <String>{
          ...existing.mcpServerIds,
          ...template.mcpServerIds,
        }.toList(growable: false),
        localToolIds: template.localToolIds,
        enableMemory: template.enableMemory,
        autoOrganizeMemory: template.autoOrganizeMemory,
        memoryOrganizeEveryNTurns: template.memoryOrganizeEveryNTurns,
        memorySmartAddMode: template.memorySmartAddMode,
        memoryWriteScope: template.memoryWriteScope,
        allowPastConversationRecall: template.allowPastConversationRecall,
        generateConversationSummary: template.generateConversationSummary,
        recentChatsSummaryMessageCount: template.recentChatsSummaryMessageCount,
      );
      changed = true;
    }
    if (storedVersion < _apkModAssistantVersion) {
      await preferences.setInt(
        _apkModAssistantVersionKey,
        _apkModAssistantVersion,
      );
    }
    if (changed) await _persist();
    // Set current assistant if not set
    if (_currentAssistantId == null && _assistants.isNotEmpty) {
      _currentAssistantId = _assistants.first.id;
      await preferences.setString(_currentAssistantKey, _currentAssistantId!);
    }
    notifyListeners();
  }

  String _buildCopyName(Assistant source, AppLocalizations? l10n) {
    final suffix = (l10n?.assistantSettingsCopySuffix ?? 'Copy').trim();
    final baseName = source.name.trim().isEmpty
        ? (l10n?.assistantProviderNewAssistantName ?? 'Assistant')
        : source.name.trim();
    final existingNames = _assistants.map((a) => a.name).toSet();

    String candidate = suffix.isEmpty ? baseName : '$baseName $suffix';
    int counter = 2;
    while (existingNames.contains(candidate)) {
      final counterSuffix = suffix.isEmpty ? '$counter' : '$suffix $counter';
      candidate = '$baseName $counterSuffix';
      counter++;
    }
    return candidate;
  }

  Future<String?> _duplicateLocalFile(
    String? rawPath, {
    required bool isAvatar,
    required String newId,
  }) async {
    final raw = (rawPath ?? '').trim();
    if (raw.isEmpty) return rawPath;
    if (raw.startsWith('http') || raw.startsWith('data:')) return rawPath;
    final fixed = SandboxPathResolver.fix(raw);
    final src = File(fixed);
    if (!await src.exists()) return rawPath;

    try {
      final dir = isAvatar
          ? await AppDirectories.getAvatarsDirectory()
          : await AppDirectories.getImagesDirectory();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      String ext = '';
      final dot = fixed.lastIndexOf('.');
      if (dot != -1 && dot < fixed.length - 1) {
        ext = fixed.substring(dot + 1).toLowerCase();
        if (ext.length > 6) ext = 'jpg';
      } else {
        ext = 'jpg';
      }
      final prefix = isAvatar ? 'assistant' : 'background';
      final dest = File(
        '${dir.path}/${prefix}_${newId}_${DateTime.now().millisecondsSinceEpoch}.$ext',
      );
      await src.copy(dest.path);
      return dest.path;
    } catch (_) {
      return rawPath;
    }
  }

  Future<String?> _copyLocalAssetToManagedDirectory(
    String? rawPath, {
    required Future<Directory> Function() directoryAsync,
    required String filenamePrefix,
    required String id,
  }) async {
    final raw = (rawPath ?? '').trim();
    if (raw.isEmpty || raw.startsWith('http') || raw.startsWith('data:')) {
      return rawPath;
    }
    if (!(raw.startsWith('/') || raw.contains(':'))) return rawPath;

    final fixed = SandboxPathResolver.fix(raw);
    final src = File(fixed);
    if (!await src.exists()) return rawPath;

    final managedDir = await directoryAsync();
    final managedRoot = p.normalize(managedDir.absolute.path);
    final sourcePath = p.normalize(src.absolute.path);
    if (p.isWithin(managedRoot, sourcePath)) return fixed;

    if (!await managedDir.exists()) {
      await managedDir.create(recursive: true);
    }

    var ext = p.extension(fixed).toLowerCase();
    if (ext.isEmpty || ext.length > 7) ext = '.jpg';
    final safeId = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final dest = File(
      p.join(
        managedDir.path,
        '${filenamePrefix}_${safeId}_${DateTime.now().millisecondsSinceEpoch}$ext',
      ),
    );
    await src.copy(dest.path);
    return dest.path;
  }

  Future<void> _deleteManagedFileIfOwned(
    String? rawPath, {
    required Future<Directory> Function() directoryAsync,
    required String? replacementPath,
  }) async {
    final raw = (rawPath ?? '').trim();
    if (raw.isEmpty) return;
    try {
      final dir = await directoryAsync();
      final root = p.normalize(dir.absolute.path);
      final targetFile = File(raw);
      final target = p.normalize(targetFile.absolute.path);
      if (!p.isWithin(root, target)) return;
      if (replacementPath != null &&
          p.equals(target, p.normalize(File(replacementPath).absolute.path))) {
        return;
      }
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
    } catch (_) {}
  }

  Future<void> _persist() async {
    await preferences.setString(
      _assistantsKey,
      Assistant.encodeList(_assistants),
    );
  }

  Future<void> setCurrentAssistant(String id) async {
    await loaded;
    if (_currentAssistantId == id) return;
    _currentAssistantId = id;
    notifyListeners();
    await preferences.setString(_currentAssistantKey, id);
  }

  Assistant? getById(String id) {
    final idx = _assistants.indexWhere((a) => a.id == id);
    if (idx == -1) return null;
    return _assistants[idx];
  }

  // Lightweight accessor so callers don't depend on Assistant.presetMessages symbol
  List<Map<String, String>> getPresetMessagesForAssistant(String? assistantId) {
    Assistant? a;
    if (assistantId != null) {
      a = getById(assistantId);
    } else {
      a = currentAssistant;
    }
    if (a == null) return const <Map<String, String>>[];
    return [
      for (final m in a.presetMessages) {'role': m.role, 'content': m.content},
    ];
  }

  Future<String> addAssistant({String? name, dynamic context}) async {
    final a = Assistant(
      id: const Uuid().v4(),
      name:
          (name ??
          (context != null
              ? AppLocalizations.of(context)!.assistantProviderNewAssistantName
              : 'New Assistant')),
      temperature: null,
      topP: null,
      limitContextMessages: false,
    );
    _assistants.add(a);
    await _persist();
    notifyListeners();
    return a.id;
  }

  Future<String?> duplicateAssistant(
    String id, {
    AppLocalizations? l10n,
  }) async {
    final idx = _assistants.indexWhere((a) => a.id == id);
    if (idx == -1) return null;
    final source = _assistants[idx];
    final newId = const Uuid().v4();

    final avatarCopy = await _duplicateLocalFile(
      source.avatar,
      isAvatar: true,
      newId: newId,
    );
    final backgroundCopy = await _duplicateLocalFile(
      source.background,
      isAvatar: false,
      newId: newId,
    );

    final copy = source.copyWith(
      id: newId,
      name: _buildCopyName(source, l10n),
      avatar: avatarCopy,
      background: backgroundCopy,
      mcpServerIds: List<String>.of(source.mcpServerIds),
      localToolIds: List<String>.of(source.localToolIds),
      customHeaders: source.customHeaders
          .map((e) => Map<String, String>.from(e))
          .toList(),
      customBody: source.customBody
          .map((e) => Map<String, String>.from(e))
          .toList(),
      presetMessages: source.presetMessages
          .map((m) => PresetMessage(role: m.role, content: m.content))
          .toList(),
      regexRules: source.regexRules
          .map(
            (r) => AssistantRegex(
              id: const Uuid().v4(),
              name: r.name,
              pattern: r.pattern,
              replacement: r.replacement,
              scopes: List<AssistantRegexScope>.of(r.scopes),
              visualOnly: r.visualOnly,
              replaceOnly: r.replaceOnly,
              enabled: r.enabled,
            ),
          )
          .toList(),
    );

    _assistants.insert(idx + 1, copy);
    await _persist();
    notifyListeners();
    return copy.id;
  }

  Future<void> updateAssistant(Assistant updated) async {
    final idx = _assistants.indexWhere((a) => a.id == updated.id);
    if (idx == -1) return;

    var next = updated;

    try {
      final prev = _assistants[idx];
      final raw = (updated.avatar ?? '').trim();
      final prevRaw = (prev.avatar ?? '').trim();
      final changed = raw != prevRaw;

      if (changed) {
        final avatarPath = await _copyLocalAssetToManagedDirectory(
          raw,
          directoryAsync: AppDirectories.getAvatarsDirectory,
          filenamePrefix: 'assistant',
          id: updated.id,
        );
        if (avatarPath != updated.avatar) {
          await _deleteManagedFileIfOwned(
            prevRaw,
            directoryAsync: AppDirectories.getAvatarsDirectory,
            replacementPath: avatarPath,
          );
          next = updated.copyWith(avatar: avatarPath);
        } else if (raw.isEmpty) {
          await _deleteManagedFileIfOwned(
            prevRaw,
            directoryAsync: AppDirectories.getAvatarsDirectory,
            replacementPath: null,
          );
        }
      }

      // Prefetch URL avatar to allow offline display later
      if (changed && raw.startsWith('http')) {
        try {
          await AvatarCache.getPath(raw);
        } catch (_) {}
      }

      // Handle background persistence similar to avatar, but under images/
      final bgRaw = (updated.background ?? '').trim();
      final prevBgRaw = (prev.background ?? '').trim();
      final bgChanged = bgRaw != prevBgRaw;
      if (bgChanged) {
        final backgroundPath = await _copyLocalAssetToManagedDirectory(
          bgRaw,
          directoryAsync: AppDirectories.getImagesDirectory,
          filenamePrefix: 'background',
          id: updated.id,
        );
        if (backgroundPath != updated.background) {
          await _deleteManagedFileIfOwned(
            prevBgRaw,
            directoryAsync: AppDirectories.getImagesDirectory,
            replacementPath: backgroundPath,
          );
          next = next.copyWith(background: backgroundPath);
        } else if (bgRaw.isEmpty) {
          await _deleteManagedFileIfOwned(
            prevBgRaw,
            directoryAsync: AppDirectories.getImagesDirectory,
            replacementPath: null,
          );
        }
      }
    } catch (_) {
      // On any failure, fall back to the provided value unchanged.
    }

    _assistants[idx] = next;
    await _persist();
    notifyListeners();
  }

  Future<void> setSearchEnabledForCurrentAssistant(bool enabled) async {
    final a = currentAssistant;
    if (a == null || a.searchEnabled == enabled) return;
    await updateAssistant(a.copyWith(searchEnabled: enabled));
  }

  Future<void> reorderAssistantRegex({
    required String assistantId,
    required int oldIndex,
    required int newIndex,
  }) async {
    final idx = _assistants.indexWhere((a) => a.id == assistantId);
    if (idx == -1) return;
    final list = List<AssistantRegex>.of(_assistants[idx].regexRules);
    if (oldIndex < 0 || oldIndex >= list.length) return;
    if (newIndex < 0 || newIndex >= list.length) return;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    _assistants[idx] = _assistants[idx].copyWith(regexRules: list);
    notifyListeners();
    await _persist();
  }

  Future<bool> deleteAssistant(String id) async {
    final idx = _assistants.indexWhere((a) => a.id == id);
    if (idx == -1) return false;
    // Do not allow deleting the last remaining assistant
    if (_assistants.length <= 1) return false;

    await chatService?.deleteConversationsForAssistant(id);

    final removingCurrent = _assistants[idx].id == _currentAssistantId;
    _assistants.removeAt(idx);
    if (removingCurrent) {
      _currentAssistantId = _assistants.isNotEmpty
          ? _assistants.first.id
          : null;
    }
    await _persist();
    if (_currentAssistantId != null) {
      await preferences.setString(_currentAssistantKey, _currentAssistantId!);
    } else {
      await preferences.remove(_currentAssistantKey);
    }
    notifyListeners();
    return true;
  }

  Future<void> reorderAssistants(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    if (oldIndex < 0 || oldIndex >= _assistants.length) return;
    if (newIndex < 0 || newIndex >= _assistants.length) return;

    final assistant = _assistants.removeAt(oldIndex);
    _assistants.insert(newIndex, assistant);

    // Notify listeners immediately for smooth UI update
    notifyListeners();

    // Then persist the changes
    await _persist();
  }

  // Reorder only within a subset (e.g., assistants belonging to a tag group or ungrouped).
  // subsetIds defines the set and order boundary; other assistants remain in place.
  Future<void> reorderAssistantsWithin({
    required List<String> subsetIds,
    required int oldIndex,
    required int newIndex,
  }) async {
    if (oldIndex == newIndex) return;
    if (subsetIds.isEmpty) return;

    // Build subset indices in the master list preserving current order
    final idSet = subsetIds.toSet();
    final subsetIndices = <int>[];
    for (int i = 0; i < _assistants.length; i++) {
      if (idSet.contains(_assistants[i].id)) subsetIndices.add(i);
    }
    if (subsetIndices.isEmpty) return;
    if (oldIndex < 0 || oldIndex >= subsetIndices.length) return;
    if (newIndex < 0 || newIndex >= subsetIndices.length) return;

    // Extract subset in current order
    final subset = subsetIndices
        .map((i) => _assistants[i])
        .toList(growable: true);
    final moved = subset.removeAt(oldIndex);
    subset.insert(newIndex, moved);

    // Merge back into master list
    final merged = <Assistant>[];
    int take = 0;
    for (int i = 0; i < _assistants.length; i++) {
      final a = _assistants[i];
      if (idSet.contains(a.id)) {
        merged.add(subset[take++]);
      } else {
        merged.add(a);
      }
    }
    _assistants
      ..clear()
      ..addAll(merged);

    notifyListeners();
    await _persist();
  }
}
