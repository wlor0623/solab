import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/utils/token_estimator.dart';
import '../../../core/services/local_tools/local_tool_names.dart';
import '../../../core/services/local_tools/local_tool_registry.dart';
import '../../solab_apk/analyzer/analyzer_tools.dart';
import '../../solab_apk/services/apk_agent_policy.dart';
import 'tool_handler_service.dart' show ToolLoadPolicy;

/// route_task 返回的轨道（决定 Tier2 追加哪组工具）。
enum ToolTrack { flutterVip, dexNative, soAnalysis, fileOps }

/// 工具按需路由层（独立 Tool Manager，⑨⑩）。
///
/// 职责：把工具按任务分段挂载，避免无关对话携带 APK 工具——
/// 1. 闲聊/Tool-Free：`none` → 0 个工具
/// 2. 域名划分（②）：每个工具归属一个域（core/device/workspace/analysis/patch/file）
/// 3. 域内按意图 Top-K（③）：无工作区时按用户消息关键词选一组轻量工具
/// 4. Schema 懒加载（④）：非关键工具只给名字+一句话描述，不随请求携带完整 parameters
///
/// 路由本身是纯规则（零额外 LLM 调用，⑥），保证 Router 不烧 token。
class ToolRouter {
  const ToolRouter._();

  // ---- 域名划分（②） ----

  /// 非 APK 请求的基础工具。
  ///
  /// 必须含任务分流，避免普通任务只拿到“提问/分页”两个工具后无法进入
  /// 对应能力域；纯闲聊仍由 [ToolLoadPolicy.none] 保持零工具。
  static const Set<String> coreNames = <String>{
    LocalToolNames.routeTask,
    LocalToolNames.askUser,
    LocalToolNames.agentRuntimeGuide,
    LocalToolNames.apkToolMap,
    LocalToolNames.apkListWorkspace,
    LocalToolNames.apkProjectInfo,
    LocalToolNames.apkListBuilds,
    LocalToolNames.memoryRead,
    LocalToolNames.memoryUpdate,
    LocalToolNames.memorySearchProfile,
    LocalToolNames.getToolResult,
  };

  static const Set<String> _memoryNames = <String>{
    LocalToolNames.memoryRead,
    LocalToolNames.memoryUpdate,
    LocalToolNames.memorySearchProfile,
    LocalToolNames.memoryEdit,
    LocalToolNames.memoryDelete,
    LocalToolNames.updateUserProfile,
    LocalToolNames.chatSearch,
  };

  static const Set<String> _memoryKeywords = <String>{
    '记住',
    '记忆',
    '偏好',
    '档案',
    '历史对话',
    '之前说过',
    'memory',
    'remember',
    'preference',
    'profile',
    'history',
  };

  /// 设备域（与 APK 无关的设备工具）。
  static const Set<String> deviceNames = <String>{
    LocalToolNames.timeInfo,
    LocalToolNames.clipboard,
    LocalToolNames.textToSpeech,
    LocalToolNames.screenTime,
    LocalToolNames.calendarQuery,
    LocalToolNames.calendarCreate,
  };

  static const Set<String> _deviceKeywords = <String>{
    '时间',
    '日历',
    '提醒',
    '安排',
    '屏幕',
    '使用时长',
    '剪贴',
    '复制',
    '粘贴',
    '朗读',
    '语音',
    '念',
    '计算',
    '算一下',
    'time',
    'calendar',
    'clipboard',
    'screen',
    'tts',
    'speak',
    'calculate',
  };

  /// 工作区域（APK 工作区/项目/报告相关，轻量级——不含重型分析）。
  static const Set<String> workspaceNames = <String>{
    LocalToolNames.apkReport,
    LocalToolNames.apkRules,
    LocalToolNames.apkAnalyzeWorkspace,
    LocalToolNames.apkArchive,
    LocalToolNames.apkExportReport,
    LocalToolNames.apkPatchMemory,
    LocalToolNames.apkNoteRead,
  };

  static const Set<String> _workspaceKeywords = <String>{
    'apk',
    '安装包',
    '包',
    '工作区',
    '规则',
    '报告',
    '分析',
    '查看',
    '笔记',
    '项目',
    '产物',
    'workspace',
    'report',
    'rule',
    'note',
  };

  // ---- ④ Schema 懒加载 ----

  /// 必须保留完整 parameters 的工具（参数契约严格、模型不能瞎猜）。
  static const Set<String> schemaCriticalNames = <String>{
    LocalToolNames.askUser,
    LocalToolNames.routeTask,
    LocalToolNames.apkPatchDex,
    LocalToolNames.apkSignatureBypass,
    LocalToolNames.apkPatchManifest,
    LocalToolNames.soPatchIntoApk,
    LocalToolNames.apkRebuild,
    LocalToolNames.memoryRead,
    LocalToolNames.memoryUpdate,
    LocalToolNames.memorySearchProfile,
    LocalToolNames.memoryEdit,
    LocalToolNames.memoryDelete,
    LocalToolNames.updateUserProfile,
    LocalToolNames.chatSearch,
    LocalToolNames.searchWeb,
    LocalToolNames.getToolResult,
    LocalToolNames.smaliRead,
    LocalToolNames.dexXref,
    LocalToolNames.classOutline,
    LocalToolNames.dexSearch,
    LocalToolNames.apkToolMap,
    LocalToolNames.soAnalyze,
    LocalToolNames.apkSkill,
    LocalToolNames.apkKnowledge,
    LocalToolNames.installedSkills,
    LocalToolNames.apkSign,
    LocalToolNames.file,
    LocalToolNames.apkArchive,
    LocalToolNames.apkExportReport,
    LocalToolNames.apkRecordPatchVerification,
    LocalToolNames.apkSavePatchMemory,
  };

  /// 工具是否需要携带完整 parameters（否则懒加载：只给名字+一句话）。
  static bool isSchemaCritical(String name) =>
      schemaCriticalNames.contains(name);

  // ---- ① 闲聊判定 ----

  /// 判断本条消息是否「纯闲聊」（打招呼/道谢/回应）。
  ///
  /// 保守规则：消息很短、整体匹配闲聊短语、且不含任何任务/工具信号词。
  static bool isCasualText(String text) {
    final t = text.trim();
    if (t.isEmpty || t.length > 24) return false;
    if (!RegExp(
      r'^(你好|您好|哈喽|嗨|hi|hello|hey|在吗|在不在|'
      r'谢谢|感谢|多谢|好的|收到|明白|没问题|ok|嗯|好呀|哈哈|呵呵|'
      r'再见|拜拜|早上好|中午好|晚上好|晚安|辛苦了)[!！。．~～?？，,、]?$',
      caseSensitive: false,
    ).hasMatch(t)) {
      return false;
    }
    return !RegExp(
      r'apk|文件|分析|修改|查看|搜索|查一|查下|工具|代码|安装|问题|'
      r'帮我|麻烦|请问|下载|去广告|解锁|精简|签名|工作|这个|那个',
      caseSensitive: false,
    ).hasMatch(t);
  }

  // ---- ③ 域内 Top-K 选择 ----

  /// 无 APK 工作区时的轻量工具选择：core 恒有 + 按用户消息关键词打进
  /// device/workspace 域，非核心工具最多 [maxExtras] 个（防止全量）。
  static Set<String> resolveLightSelection(
    String userText, {
    int maxExtras = 12,
  }) {
    final selected = <String>{...coreNames};
    final lower = userText.toLowerCase();
    selected.addAll(resolveMemorySelection(userText));
    final extras = <String>[
      if (_anyHit(_deviceKeywords, lower)) ...deviceNames,
      if (_anyHit(_workspaceKeywords, lower)) ...workspaceNames,
    ];
    var n = 0;
    for (final name in extras) {
      if (n >= maxExtras) break;
      selected.add(name);
      n++;
    }
    return selected;
  }

  /// 记忆工具只在用户明确提及记忆、偏好或历史时加入本轮声明。
  static Set<String> resolveMemorySelection(String userText) {
    return _anyHit(_memoryKeywords, userText.toLowerCase())
        ? _memoryNames
        : const <String>{};
  }

  static bool _anyHit(Set<String> keywords, String lowerText) {
    for (final k in keywords) {
      if (lowerText.contains(k)) return true;
    }
    return false;
  }

  /// 由粗粒度策略 + 用户消息得到本次请求要声明的工具集。
  ///
  /// 返回空集表示不声明任何工具（聊天）；返回集合表示本轮按需选中的工具。
  static Set<String>? resolve({
    required ToolLoadPolicy policy,
    required String userText,
  }) {
    switch (policy) {
      case ToolLoadPolicy.none:
        return const <String>{};
      case ToolLoadPolicy.light:
        return resolveLightSelection(userText);
      case ToolLoadPolicy.full:
        return ToolExpansion(
          apkTask: true,
        ).names().union(resolveMemorySelection(userText));
    }
  }

  static Set<String> resolveForExpansion({
    required ToolLoadPolicy initialPolicy,
    required ToolExpansion expansion,
    required String userText,
  }) {
    if (initialPolicy == ToolLoadPolicy.none) return const <String>{};
    if (!expansion.isApkTask) return resolveLightSelection(userText);
    return <String>{...expansion.names(), ...resolveMemorySelection(userText)};
  }

  // ---- ⑦ 系统提示分段（静态核心 + 动态领域） ----

  /// 本次策略下应激活的系统提示段（对应
  /// assistant_provider 里 _apkModSystemPrompt 拆出的段）。
  static List<String> activePromptSections(ToolLoadPolicy policy) {
    switch (policy) {
      case ToolLoadPolicy.none:
        return const <String>['core'];
      case ToolLoadPolicy.light:
        return const <String>['core', 'device', 'workspace'];
      case ToolLoadPolicy.full:
        return const <String>[
          'core',
          'device',
          'workspace',
          'analysis',
          'patch',
          'file',
        ];
    }
  }

  // ====================================================================
  // 动态分层工具（流程图①）：Tier0 常驻 / Tier1 apk 基础 /
  // Tier2 按 route_task 轨道 / Tier3 完成期
  // ====================================================================

  /// Tier0：chat 与 apk 请求都常驻的基础工具（3 个路由 + 记忆/结果分页基础设施）。
  static final Set<String> tier0Names = Set<String>.unmodifiable(<String>{
    ...LocalToolRegistry.namesAtTier(LocalToolTier.tier0),
    LocalToolNames.memoryRead,
    LocalToolNames.memoryUpdate,
    LocalToolNames.memorySearchProfile,
    LocalToolNames.getToolResult,
  });

  /// Tier1：识别为 apk_task 后追加的 APK 基础/知识/工作区工具。
  static final Set<String> tier1Names = LocalToolRegistry.namesAtTier(
    LocalToolTier.tier1,
  );

  /// 轨道 → Tier2 工具（route_task 返回 track 后动态追加）。
  static final Map<ToolTrack, Set<String>> tier2ByTrack =
      <ToolTrack, Set<String>>{
        ToolTrack.flutterVip: _tier2For(LocalToolRegistry.flutterVip),
        ToolTrack.dexNative: _tier2For(LocalToolRegistry.dexNative),
        ToolTrack.soAnalysis: _tier2For(LocalToolRegistry.soAnalysis),
        ToolTrack.fileOps: _tier2For(LocalToolRegistry.fileOps),
      };

  /// Tier3：完成期（修改已发生）追加：签名/验证/记忆。
  static final Set<String> tier3Names = LocalToolRegistry.namesAtTier(
    LocalToolTier.tier3,
  );

  /// 命中即视为"已进入修改"的工具（触发 Tier3 追加）。
  static final Set<String> modifyToolNames =
      LocalToolRegistry.completionToolNames();

  static Set<String> _tier2For(String track) => Set<String>.unmodifiable({
    ...LocalToolRegistry.namesAtTier(LocalToolTier.tier2, track: track),
    AnalyzerToolNames.open,
    AnalyzerToolNames.globalSearch,
    AnalyzerToolNames.fieldUsage,
    AnalyzerToolNames.businessState,
  });

  /// 意图分类（代码层，零 LLM）：是否 apk_task（而非 chat）。
  static bool isApkTaskIntent(String text) {
    final t = text.toLowerCase();
    return RegExp(
          r'apk|安装包|分析|修改|反向|逆向|反编译|vip|svip|会员|订阅|去广告|'
          r'解锁|精简|签名|脱壳|flutter|sonative|dex|smali|native|权限|启动|'
          r'flag[_\s-]?secure|截屏|录屏',
          caseSensitive: false,
        ).hasMatch(t) ||
        _anyHit(_workspaceKeywords, t);
  }

  static bool shouldResumeApkTask({
    required bool hasValidRoute,
    required String userText,
  }) => hasValidRoute && !isCasualText(userText);

  static bool isApkTaskContinuation(String text) {
    final t = text.trim();
    if (t.isEmpty || t.length > 80 || isCasualText(t)) return false;
    return RegExp(
      r'继续|接着|重试|再试|修复|修改|改好|解决|写回|打包|签名|验证|搜索|'
      r'查找|定位|执行|应用|完成|优化|替换|删除|保留',
      caseSensitive: false,
    ).hasMatch(t);
  }

  static String? latestValidRouteResult(
    List<Map<String, dynamic>> apiMessages,
  ) {
    for (final message in apiMessages.reversed) {
      if (message['role'] != 'tool' ||
          message['name'] != LocalToolNames.routeTask) {
        continue;
      }
      final content = message['content']?.toString() ?? '';
      if (resolveTrackFromText(content) != null) return content;
    }
    return null;
  }

  /// 从 route_task 的返回文本里解析轨道（关键词兜底，支持 JSON track 字段）。
  static ToolTrack? resolveTrackFromText(String result) {
    final text = result.toLowerCase();
    final declaredTrack = RegExp(
      r'''["'](?:toolTrack|track)["']\s*:\s*["']([^"']+)["']''',
    ).firstMatch(text)?.group(1);
    switch (declaredTrack) {
      case 'flutter_vip':
      case 'fluttervip':
        return ToolTrack.flutterVip;
      case 'dex_native':
      case 'dexnative':
        return ToolTrack.dexNative;
      case 'so_analysis':
      case 'soanalysis':
        return ToolTrack.soAnalysis;
      case 'file_ops':
      case 'fileops':
        return ToolTrack.fileOps;
    }
    if (text.contains('flutter') || text.contains('blutter')) {
      return ToolTrack.flutterVip;
    }
    if (text.contains('dex') ||
        text.contains('smali') ||
        text.contains('dex_native') ||
        text.contains('反编译') ||
        text.contains('逆向')) {
      return ToolTrack.dexNative;
    }
    if (text.contains('so_') ||
        text.contains('rz_') ||
        text.contains('lib') ||
        text.contains('native') ||
        text.contains('elf')) {
      return ToolTrack.soAnalysis;
    }
    if (text.contains('file') ||
        text.contains('文件') ||
        text.contains('结构') ||
        text.contains('abi') ||
        text.contains('精简') ||
        text.contains('res') ||
        text.contains('资源')) {
      return ToolTrack.fileOps;
    }
    return null;
  }
}

/// 单个生成会话的工具扩容状态（流程图①）。
///
/// 起始只挂 Tier0（chat）或 Tier0+Tier1（apk_task）；route_task 返回轨道后
/// 动态追加 Tier2；发生修改后追加 Tier3。后续请求轮次通过
/// [names] 读取当前应声明的工具集（由 toolsOf 每轮重算）。
class ToolExpansion {
  ToolExpansion({
    required bool apkTask,
    ApkExecutionMode executionMode = ApkExecutionMode.modify,
  }) : _apkTask = apkTask, // ignore: prefer_initializing_formals
       _executionMode = executionMode; // ignore: prefer_initializing_formals

  bool _apkTask;
  ApkExecutionMode _executionMode;
  ApkExecutionMode get executionMode => _executionMode;
  ToolTrack? _track;
  final Set<ToolTrack> _tracks = <ToolTrack>{};
  bool _completion = false;
  final Set<String> _routeTools = <String>{};

  /// route_task 返回后调用：按返回文本设置轨道，追加 Tier2。
  void applyTrackText(String result) {
    final track = ToolRouter.resolveTrackFromText(result);
    if (track != null) {
      _apkTask = true;
      _track = track;
      _tracks.add(track);
    }
    try {
      final value = jsonDecode(result);
      if (value is Map && value['toolTracks'] is List) {
        for (final raw in value['toolTracks'] as List) {
          final parsed = ToolRouter.resolveTrackFromText(
            '{"toolTrack":"${raw.toString()}"}',
          );
          if (parsed != null) _tracks.add(parsed);
        }
      }
      if (value is Map && value['recommendedTools'] is List) {
        _routeTools.addAll(
          (value['recommendedTools'] as List).map((item) => item.toString()),
        );
      }
      if (value is Map &&
          value['executionMode'] == ApkExecutionMode.modify.name &&
          _executionMode == ApkExecutionMode.analyzeOnly) {
        _executionMode = ApkExecutionMode.modify;
      }
    } catch (_) {}
  }

  /// 工作区分析完成后，必须以 APK 的实际 Flutter 识别结果定轨，不能根据会员词猜测。
  void applyWorkspaceAnalysisText(String result) {
    try {
      final value = jsonDecode(result);
      if (value is! Map) return;
      final flutterDetected = value['flutterDetected'];
      if (flutterDetected is bool) {
        _tracks.clear();
        if (flutterDetected) {
          setTrack(ToolTrack.flutterVip);
          _tracks.add(ToolTrack.dexNative);
        } else {
          setTrack(ToolTrack.dexNative);
        }
      }
    } catch (_) {}
  }

  /// 直接指定轨道（供测试）。
  void setTrack(ToolTrack track) {
    _apkTask = true;
    _track = track;
    _tracks.add(track);
  }

  /// 发生修改风格工具后调用：追加 Tier3。
  void markCompletion() {
    if (executionMode == ApkExecutionMode.modify) _completion = true;
  }

  bool get isApkTask => _apkTask;
  ToolTrack? get track => _track;
  Set<ToolTrack> get tracks => Set<ToolTrack>.unmodifiable(_tracks);
  bool get inCompletion => _completion;

  /// 当前应声明的工具名集合。
  Set<String> names() {
    final out = <String>{...ToolRouter.tier0Names};
    if (_apkTask) out.addAll(ToolRouter.tier1Names);
    if (executionMode == ApkExecutionMode.reportOnly) {
      return out.difference(ApkAgentPolicy.mutationToolNames);
    }
    for (final track in _tracks) {
      out.addAll(ToolRouter.tier2ByTrack[track] ?? const <String>{});
    }
    out.addAll(_routeTools);
    if (_completion) out.addAll(ToolRouter.tier3Names);
    if (executionMode != ApkExecutionMode.modify) {
      out.removeAll(ApkAgentPolicy.mutationToolNames);
    }
    return out;
  }
}

/// ⑧ 请求 Token 预算：每次请求分项统计，帮助定位「是谁在烧 token」。
///
/// 仅在 [ContextLogger.enabled] 时输出，正常使用零开销。
class ToolBudgetReport {
  const ToolBudgetReport._();

  static void report({
    required List<Map<String, dynamic>> apiMessages,
    required List<Map<String, dynamic>> tools,
    required ToolLoadPolicy policy,
  }) {
    var systemTokens = 0;
    var historyTokens = 0;
    var toolResultTokens = 0;
    var userTokens = 0;
    for (final m in apiMessages) {
      final role = (m['role'] ?? '').toString();
      final content = (m['content'] ?? '').toString();
      final tokens = estimateTokens(content);
      switch (role) {
        case 'system':
          systemTokens += tokens;
        case 'tool':
          toolResultTokens += tokens;
        case 'user':
          userTokens += tokens;
        default:
          historyTokens += tokens;
      }
    }
    final toolsTokens = estimateTokens(jsonEncode(tools));
    final total =
        systemTokens +
        toolsTokens +
        historyTokens +
        userTokens +
        toolResultTokens;
    debugPrint(
      '[TokenBudget] policy=$policy tools=${tools.length} '
      'system=$systemTokens tools=$toolsTokens history=$historyTokens '
      'user=$userTokens toolResult=$toolResultTokens total=$total',
    );
  }
}
