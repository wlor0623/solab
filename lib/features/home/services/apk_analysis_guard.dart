import 'dart:convert';

import '../../../core/services/local_tools/local_tool_names.dart';
import '../../solab_apk/analyzer/analyzer_tools.dart';
import '../../solab_apk/services/apk_agent_policy.dart';

enum ApkAnalysisPhase { startup, locate, verify, patch }

class ApkAnalysisGuardDecision {
  const ApkAnalysisGuardDecision._(
    this.allowed,
    this.message, {
    this.canRequestBudget = false,
  });

  const ApkAnalysisGuardDecision.allow() : this._(true, '');

  const ApkAnalysisGuardDecision.block(
    String message, {
    bool canRequestBudget = false,
  }) : this._(false, message, canRequestBudget: canRequestBudget);

  final bool allowed;
  final String message;
  final bool canRequestBudget;
}

/// 单轮 APK 分析的止损状态机。它只统计本地 APK 工具，不干预普通对话或外部 MCP。
class ApkAnalysisGuard {
  // 大结果会在工具层截断成预览后才交给模型；守卫仍读取完整 JSON 提取状态，
  // 但预算必须按模型实际可见的上限估算，不能把本地索引全文算进去。
  static const _maxDeliveredToolTokens = 4000;
  static const _phaseTokenCaps = <ApkAnalysisPhase, int>{
    ApkAnalysisPhase.startup: 8000,
    ApkAnalysisPhase.locate: 15000,
    ApkAnalysisPhase.verify: 25000,
    ApkAnalysisPhase.patch: 12000,
  };
  static const _verifyCallCap = 12;
  static const _tokenCap = ApkAgentPolicy.maxEvidenceTokens;
  static const _knowledgeTools = <String>{
    LocalToolNames.apkKnowledge,
    LocalToolNames.installedSkills,
    LocalToolNames.apkSkill,
    LocalToolNames.apkToolMap,
    LocalToolNames.apkRules,
    LocalToolNames.agentRuntimeGuide,
  };
  static const _blockedStatuses = <String>{
    'ambiguous',
    'clues_only',
    'not_found',
  };

  final Map<ApkAnalysisPhase, int> _sharedCalls = {};
  final Map<String, Map<ApkAnalysisPhase, int>> _trackCalls = {};
  final Map<ApkAnalysisPhase, int> _sharedTokens = {};
  final Map<String, Map<ApkAnalysisPhase, int>> _trackTokens = {};
  final Map<String, String> _reportStatus = {};
  final Map<String, String> _lastLocator = {};
  final Map<String, String> _selectedSystem = {};
  final Map<String, Set<String>> _evidence = {};
  final Set<String> _adSdkIdentified = {};
  final Set<String> _tracks = {};

  String? _goal;
  String? _lastTrack;
  ApkAnalysisPhase? _lastPhase;
  DateTime? _startedAt;
  int _tokenEstimate = 0;
  int _blutterAnalyzeCalls = 0;
  int _longResultReadCount = 0;
  int _budgetRecoveryCalls = 0;
  int _verifyCallExtension = 0;
  int _tokenExtension = 0;
  bool _workspaceAnalyzed = false;
  bool _shellBlocked = false;
  bool _signatureRisk = false;
  bool? _flutterDetected;
  String _apkFingerprint = '';
  String _reportFreshness = 'missing';

  void begin(String goal) {
    final normalized = goal.trim().toLowerCase();
    if (_startedAt != null && normalized == _goal) return;
    _goal = normalized;
    _startedAt = DateTime.now();
    _sharedCalls.clear();
    _trackCalls.clear();
    _sharedTokens.clear();
    _trackTokens.clear();
    _reportStatus.clear();
    _lastLocator.clear();
    _selectedSystem.clear();
    _evidence.clear();
    _adSdkIdentified.clear();
    _tracks
      ..clear()
      ..addAll(_tracksFor(normalized));
    for (final track in _tracks) {
      _reportStatus[track] = 'not_started';
    }
    _lastTrack = _tracks.length == 1 ? _tracks.first : null;
    _lastPhase = null;
    _tokenEstimate = 0;
    _blutterAnalyzeCalls = 0;
    _longResultReadCount = 0;
    _budgetRecoveryCalls = 0;
    _verifyCallExtension = 0;
    _tokenExtension = 0;
    _workspaceAnalyzed = false;
    _shellBlocked = false;
    _signatureRisk = false;
    _flutterDetected = null;
    _apkFingerprint = '';
    _reportFreshness = 'missing';
  }

  ApkAnalysisGuardDecision before(String name, Map<String, dynamic> args) {
    if (_startedAt == null) begin(jsonEncode(args));
    final action = args['action']?.toString();
    final blutterAction = args['blutterAction']?.toString();
    if (name == LocalToolNames.soAnalyze &&
        action == 'blutter' &&
        blutterAction == 'analyze') {
      _blutterAnalyzeCalls++;
      return const ApkAnalysisGuardDecision.allow();
    }

    final phase = _phaseFor(name, args);
    if (phase == null) return const ApkAnalysisGuardDecision.allow();
    final track = _trackFor(args, phase);
    if (_shellBlocked && phase != ApkAnalysisPhase.startup) {
      return const ApkAnalysisGuardDecision.block(
        '当前报告命中加固壳，会员/广告定位和补丁已暂停。先处理脱壳或确认壳状态。',
      );
    }
    final status = track == null ? null : _reportStatus[track];
    // ambiguous 只禁止直接写入。验证正是把候选收敛为可写证据的步骤，
    // 连验证一起拦会形成“状态不清晰 → 无法验证 → 永远不清晰”的死锁。
    if (phase == ApkAnalysisPhase.patch &&
        status != null &&
        _blockedStatuses.contains(status) &&
        !_hasVerifiedTarget(track!)) {
      return ApkAnalysisGuardDecision.block(_statusRecovery(status));
    }
    final calls = track == null
        ? _sharedCalls
        : _trackCalls.putIfAbsent(track, () => <ApkAnalysisPhase, int>{});
    if (phase == ApkAnalysisPhase.patch) {
      calls[phase] = (calls[phase] ?? 0) + 1;
      _lastPhase = phase;
      if (track != null) _lastTrack = track;
      return const ApkAnalysisGuardDecision.allow();
    }
    if (_tokenEstimate >= _effectiveTokenCap) {
      if (_budgetRecoveryCalls < 3 && _isNarrowBudgetRecovery(name, args)) {
        _budgetRecoveryCalls++;
      } else {
        return const ApkAnalysisGuardDecision.block(
          'APK 分析文本预算已用完。需要继续时先让用户明确授权追加一部分预算；未授权不得继续调用。',
          canRequestBudget: true,
        );
      }
    }
    if (phase == ApkAnalysisPhase.verify &&
        (calls[phase] ?? 0) >= _effectiveVerifyCallCap) {
      if (_budgetRecoveryCalls < 3 && _isNarrowBudgetRecovery(name, args)) {
        _budgetRecoveryCalls++;
      } else {
        return const ApkAnalysisGuardDecision.block(
          '同一目标的验证预算已用完。需要继续时先让用户明确授权追加一部分预算；未授权不得继续调用。',
          canRequestBudget: true,
        );
      }
    }
    calls[phase] = (calls[phase] ?? 0) + 1;
    _lastPhase = phase;
    if (track != null) _lastTrack = track;
    return const ApkAnalysisGuardDecision.allow();
  }

  String record(String name, Map<String, dynamic> args, String result) {
    final estimate = _knowledgeTools.contains(name)
        ? 0
        : ((result.length / 4).ceil())
              .clamp(0, _maxDeliveredToolTokens)
              .toInt();
    _tokenEstimate += estimate;
    final phase = _phaseFor(name, args);
    final track = phase == null
        ? _trackFromPayload(args)
        : _trackFor(args, phase);
    if (phase != null) {
      final tokens = track == null
          ? _sharedTokens
          : _trackTokens.putIfAbsent(track, () => <ApkAnalysisPhase, int>{});
      tokens[phase] = (tokens[phase] ?? 0) + estimate;
    }
    try {
      final decoded = jsonDecode(result);
      if (decoded is Map) {
        final payload = decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
        _updateState(name, args, payload, track);
        if (_isSuccessfulStateChange(name, args, payload)) {
          _restoreVerificationWindow(track);
        }
        final recovery = _recoveryFor(name, args, payload, track);
        // —— 结果噪音压实（Agent 反馈清单 A 类，2026-08-28）——
        // 1) analysisGuard 统计尾巴只在真正需要时附加（预算拦截/恢复、
        //    blocked 轨道、或结果文本命中 blocked/exceeded/violation）；
        //    正常成功结果不带，返回体积可砍 40-60%。
        // 2) 纯样板字段删除：空 nextActions、mcpFallback、memoryState。
        // 3) workspaceSync 仅在 apkCount 变化时保留（每次原样重复=纯噪音）。
        // 4) 同一 question id 只保留首次出现（patch/sign/save 各自回带同一
        //    安装确认问题，照单执行会让用户被重复询问）。
        final compacted = _compactPayload(payload);
        // 尾巴只在"真正拦截/越限"时附加；ambiguous 等状态恢复提示只保留
        // recovery 字段本身，不再携带整段统计（Agent：仅 blocked/exceeded/
        // violation 字样时保留统计）。
        final needsGuard =
            _firstBlockedTrack() != null || _blockedWords.hasMatch(result);
        return jsonEncode(<String, dynamic>{
          ...compacted,
          if (recovery != null) 'recovery': recovery,
          if (needsGuard)
            'analysisGuard': _guardSnapshot(includeElapsed: false),
        });
      }
    } catch (_) {}
    return result;
  }

  void noteLongResultRead() {
    _longResultReadCount++;
  }

  /// 每条新用户消息只恢复少量精确验证机会，保留既有报告、候选和修改状态。
  /// 大范围追加仍必须由用户通过预算授权问题明确确认。
  void beginUserTurn() {
    if (_startedAt == null) return;
    _budgetRecoveryCalls = 0;
    _restoreVerificationWindow(null);
  }

  void _restoreVerificationWindow(String? track) {
    final floor = (_effectiveVerifyCallCap - 4).clamp(0, 1 << 30).toInt();
    if (track != null) {
      final calls = _trackCalls[track];
      final used = calls?[ApkAnalysisPhase.verify] ?? 0;
      if (calls != null && used > floor) {
        calls[ApkAnalysisPhase.verify] = floor;
      }
      return;
    }
    for (final calls in _trackCalls.values) {
      final used = calls[ApkAnalysisPhase.verify] ?? 0;
      if (used > floor) calls[ApkAnalysisPhase.verify] = floor;
    }
    final sharedUsed = _sharedCalls[ApkAnalysisPhase.verify] ?? 0;
    if (sharedUsed > floor) {
      _sharedCalls[ApkAnalysisPhase.verify] = floor;
    }
  }

  static bool _isSuccessfulStateChange(
    String name,
    Map<String, dynamic> args,
    Map<String, dynamic> payload,
  ) {
    if (payload['ok'] == false || payload['error'] != null) return false;
    if (const {
      LocalToolNames.apkAnalyzeWorkspace,
      LocalToolNames.apkPatchDex,
      LocalToolNames.apkPatchManifest,
      LocalToolNames.soPatchIntoApk,
      LocalToolNames.apkSign,
    }.contains(name)) {
      return true;
    }
    if (name != LocalToolNames.soAnalyze) return false;
    return const {
      'edit_asm',
      'edit_hex',
      'edit_undo',
      'edit_redo',
      'edit_reset',
      'edit_rollback',
      'build',
      'build_many',
    }.contains(args['action']?.toString());
  }

  void grantBudget(int additionalCalls) {
    final granted = additionalCalls.clamp(1, 20);
    _verifyCallExtension += granted;
    _tokenExtension += granted * 2000;
    _budgetRecoveryCalls = 0;
  }

  int get _effectiveVerifyCallCap => _verifyCallCap + _verifyCallExtension;
  int get _effectiveTokenCap => _tokenCap + _tokenExtension;

  /// 用户在 ask_user_input_v0 中给出了回答。用户确认属于高位证据：
  /// 若当前分析正因 ambiguous/clues_only/not_found 而被阻断，就把对应轨道
  /// 解除到非阻断状态，放行后续 verify/patch，避免"用户确认了仍在死拦"的自锁。
  void confirmFromUserAnswer() {
    if (_startedAt == null) return;
    final track = _firstBlockedTrack();
    if (track == null) return;
    _reportStatus[track] = 'candidates_need_verification';
    _evidence.putIfAbsent(track, () => <String>{}).add('user_confirmed');
  }

  String? _firstBlockedTrack() {
    final ordered = <String>[if (_lastTrack != null) _lastTrack!, ..._tracks];
    for (final track in ordered) {
      final status = _reportStatus[track];
      if (status != null && _blockedStatuses.contains(status)) {
        return track;
      }
    }
    return null;
  }

  /// 结果里需要暴露守卫信息的关键词（其余统计尾巴一律不附加）。
  static final RegExp _blockedWords = RegExp(
    r'blocked|exceeded|violation',
    caseSensitive: false,
  );

  /// 会话级样板去重状态：question id 首次出现保留，之后重复的删除。
  final Set<String> _seenQuestionIds = <String>{};
  int? _lastWorkspaceApkCount;

  /// 按 Agent 噪音清单压实 payload：只删除明确列出的样板键，其余一律保留
  /// （保守原则：宁可少删不误删，误删=丢失证据）。
  Map<String, dynamic> _compactPayload(Map<String, dynamic> payload) {
    payload.removeWhere((key, value) {
      switch (key) {
        case 'nextActions':
          return value is List && value.isEmpty;
        case 'mcpFallback':
        case 'memoryState':
          return true;
        case 'workspaceSync':
          final count = value is Map ? value['apkCount'] : null;
          if (count is int) {
            if (count == _lastWorkspaceApkCount) return true;
            _lastWorkspaceApkCount = count;
          }
          return false;
        default:
          return false;
      }
    });
    _stripRepeatedQuestion(payload);
    return payload;
  }

  /// questionArguments 的同一 question id 只保留首次出现；重复时连带
  /// 删除 nextRequiredTool（避免链路里每个工具都提示再问一次用户）。
  void _stripRepeatedQuestion(Map<String, dynamic> payload) {
    final qa = payload['questionArguments'];
    final raw = qa is Map ? qa['questions'] : null;
    var questions = const <Object?>[];
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) questions = decoded;
      } catch (_) {}
    } else if (raw is List) {
      questions = raw;
    } else {
      return;
    }
    final ids = <String>[
      for (final q in questions)
        if (q is Map) (q['id'] ?? '').toString().trim(),
    ].where((id) => id.isNotEmpty).toList();
    if (ids.isEmpty) return;
    final anySeen = ids.any(_seenQuestionIds.contains);
    for (final id in ids) {
      if (!_seenQuestionIds.contains(id)) _seenQuestionIds.add(id);
    }
    if (anySeen) {
      payload.remove('questionArguments');
      payload.remove('nextRequiredTool');
    }
  }

  /// 附加给结果的守卫快照（可选剔除 elapsedMs——Agent 要求永远可删）。
  Map<String, dynamic> _guardSnapshot({required bool includeElapsed}) {
    final snapshot = this.snapshot();
    if (!includeElapsed) snapshot.remove('elapsedMs');
    return snapshot;
  }

  Map<String, dynamic> snapshot() => {
    'apkFingerprint': _apkFingerprint,
    'reportFreshness': _reportFreshness,
    'flutterDetected': _flutterDetected,
    'phase': _lastPhase?.name ?? 'startup',
    'membership': _trackSnapshot('membership'),
    'ads': {
      ..._trackSnapshot('ads'),
      'sdkIdentified': _adSdkIdentified.toList(growable: false),
    },
    'budget': {
      'enabled': true,
      'callsUsed': _allCalls,
      'callsCap': {
        'verify': _effectiveVerifyCallCap,
        'narrowRecovery': 3,
        'userGranted': _verifyCallExtension,
      },
      'tokenUsedEst': _tokenEstimate,
      'tokenCap': _effectiveTokenCap,
      'phaseSoftCaps': {
        for (final entry in _phaseTokenCaps.entries)
          entry.key.name: entry.value,
      },
      'sharedCalls': _phaseSnapshot(_sharedCalls),
      'trackCalls': {
        for (final entry in _trackCalls.entries)
          entry.key: _phaseSnapshot(entry.value),
      },
      'sharedTokenEstimate': _phaseSnapshot(_sharedTokens),
      'trackTokenEstimate': {
        for (final entry in _trackTokens.entries)
          entry.key: _phaseSnapshot(entry.value),
      },
    },
    'guard': {
      'longResultReadCount': _longResultReadCount,
      'blutterAnalyzeCalls': _blutterAnalyzeCalls,
      'budgetRecoveryCalls': _budgetRecoveryCalls,
      'workspaceAnalyzed': _workspaceAnalyzed,
      'shellBlocked': _shellBlocked,
      'signatureRisk': _signatureRisk,
    },
    'elapsedMs': _startedAt == null
        ? 0
        : DateTime.now().difference(_startedAt!).inMilliseconds,
  };

  int get _allCalls =>
      _sharedCalls.values.fold<int>(0, (sum, value) => sum + value) +
      _trackCalls.values
          .expand((calls) => calls.values)
          .fold<int>(0, (sum, value) => sum + value) +
      _blutterAnalyzeCalls;

  bool _isNarrowBudgetRecovery(String name, Map<String, dynamic> args) {
    if (name != LocalToolNames.soAnalyze) return false;
    final action = args['action']?.toString();
    final blutterAction = args['blutterAction']?.toString();
    if (action == 'blutter' && blutterAction == 'values') {
      return (args['query']?.toString().trim().isNotEmpty ?? false);
    }
    if (action == 'blutter' && blutterAction == 'disasm') {
      return (args['va']?.toString().trim().isNotEmpty ?? false);
    }
    if (action == 'disasm' || action == 'hexdump') {
      return (args['va']?.toString().trim().isNotEmpty ?? false) ||
          (args['locator']?.toString().trim().isNotEmpty ?? false);
    }
    return false;
  }

  Map<String, dynamic> _trackSnapshot(String track) => {
    'reportStatus': _reportStatus[track] ?? 'not_started',
    'lastLocatorVA': _lastLocator[track],
    'selectedSystem': _selectedSystem[track],
    'evidence': (_evidence[track] ?? const <String>{}).toList(),
    'callCount': _phaseSnapshot(
      _trackCalls[track] ?? const <ApkAnalysisPhase, int>{},
    ),
  };

  void _updateState(
    String name,
    Map<String, dynamic> args,
    Map<String, dynamic> payload,
    String? track,
  ) {
    final facts = _asMap(payload['facts']) ?? payload;
    if (name == LocalToolNames.apkAnalyzeWorkspace &&
        payload['ok'] != false &&
        payload['error'] == null) {
      _workspaceAnalyzed = true;
    }
    final freshness = _asMap(payload['reportFreshness']);
    if (freshness != null) {
      _reportFreshness = freshness['status']?.toString() ?? _reportFreshness;
    } else if (name == LocalToolNames.apkReport && payload['error'] == null) {
      _reportFreshness = 'fresh';
    }
    final fingerprintParts = <String>[
      facts['packageName']?.toString() ?? '',
      facts['versionName']?.toString() ?? '',
      facts['sha256']?.toString() ?? '',
    ].where((value) => value.isNotEmpty).toList(growable: false);
    if (fingerprintParts.isNotEmpty) {
      _apkFingerprint = fingerprintParts.join('+');
    }
    final flutter = _asMap(facts['flutterApp']);
    if (flutter != null && flutter['detected'] is bool) {
      _flutterDetected = flutter['detected'] as bool;
    }
    final shell = _asMap(facts['shellPacking']);
    if (shell?['detected'] == true) _shellBlocked = true;
    final signature = _asMap(facts['signatureCheck']);
    if (signature?['detected'] == true) _signatureRisk = true;

    if (track == null) return;
    _tracks.add(track);
    final classification = payload['classificationStatus']?.toString();
    final reportStatus = payload['reportStatus']?.toString();
    final action = args['blutterAction']?.toString();
    if (reportStatus != null && reportStatus.isNotEmpty) {
      _reportStatus[track] = reportStatus;
    } else if (action == 'report' &&
        payload['status'] is String &&
        payload['reportType'] != null) {
      _reportStatus[track] = payload['status'].toString();
    } else if (classification != null && classification.isNotEmpty) {
      final candidates = _asList(payload['patchCandidates']);
      final windows = _asList(payload['verificationWindows']);
      _reportStatus[track] = switch (classification) {
        'clear' when candidates.isNotEmpty => 'candidates_need_verification',
        'clear' when windows.isNotEmpty => 'references_need_verification',
        'clear' => 'system_identified_no_function',
        _ => classification,
      };
      if (classification == 'clear') {
        _evidence.putIfAbsent(track, () => <String>{}).add('system');
      }
    }

    final profile = _asMap(payload['intentProfile']);
    final system =
        _asMap(profile?['selectedSystem']) ?? _asMap(payload['system']);
    final systemId = system?['id']?.toString();
    if (systemId != null && systemId.isNotEmpty) {
      _selectedSystem[track] = systemId;
    }
    if (track == 'ads' && system != null) {
      for (final keyword in _asList(system['matchedKeywords'])) {
        final value = keyword.toString();
        if (value.isNotEmpty) _adSdkIdentified.add(value);
      }
    }

    final candidates = _asList(payload['patchCandidates']);
    final windows = _asList(payload['verificationWindows']);
    final first = candidates.isNotEmpty
        ? _asMap(candidates.first)
        : (windows.isNotEmpty ? _asMap(windows.first) : null);
    final locator =
        first?['functionVa']?.toString() ??
        first?['verificationVa']?.toString();
    if (locator != null && locator.isNotEmpty) _lastLocator[track] = locator;

    final evidence = _evidence.putIfAbsent(track, () => <String>{});
    if (candidates.any((candidate) {
      final row = _asMap(candidate);
      return _asList(row?['referenceVas']).isNotEmpty ||
          (row?['refCount'] is num && (row?['refCount'] as num) > 0);
    })) {
      evidence.add('reference');
    }
    if (name == LocalToolNames.dexXref || action == 'xref') {
      if (_resultCount(payload) > 0) evidence.add('reference');
    }
    if (name == AnalyzerToolNames.fieldUsage && _resultCount(payload) > 0) {
      evidence
        ..add('data_flow')
        ..add('exact_locator');
    }
    if (name == LocalToolNames.classOutline && _resultCount(payload) > 0) {
      evidence.add('structure');
    }
    if (name == LocalToolNames.smaliRead || action == 'disasm') {
      if (payload['ok'] != false && payload['error'] == null) {
        evidence.add('semantics');
        evidence.add('type');
        if (_hasExactLocator(name, args, payload)) {
          evidence.add('exact_locator');
        }
      }
    }
    if (action == 'values') {
      final valueSearch = _asMap(payload['valueSearch']);
      if (_resultCount(valueSearch ?? const <String, dynamic>{}) > 0) {
        evidence.add('value');
      }
    }
    if (_hasVerifiedTarget(track)) {
      _reportStatus[track] = 'confirmed';
    }
  }

  bool _hasVerifiedTarget(String track) {
    final evidence = _evidence[track] ?? const <String>{};
    if (evidence.containsAll(const {'semantics', 'exact_locator'})) return true;
    if (evidence.containsAll(const {'data_flow', 'exact_locator'})) return true;
    if (evidence.contains('semantics') &&
        evidence.any(
          const {'reference', 'value', 'data_flow', 'user_confirmed'}.contains,
        )) {
      return true;
    }
    return false;
  }

  static bool _hasExactLocator(
    String name,
    Map<String, dynamic> args,
    Map<String, dynamic> payload,
  ) {
    if (name == LocalToolNames.smaliRead) {
      final qualifiedId = args['qualifiedId']?.toString() ?? '';
      return qualifiedId.startsWith('L') && qualifiedId.contains(';->');
    }
    if (name == LocalToolNames.soAnalyze && args['blutterAction'] == 'disasm') {
      final va = (args['va'] ?? args['addr'])?.toString() ?? '';
      return va.isNotEmpty && payload['found'] != false;
    }
    return false;
  }

  Map<String, dynamic>? _recoveryFor(
    String name,
    Map<String, dynamic> args,
    Map<String, dynamic> payload,
    String? track,
  ) {
    final errorValue = payload['error'];
    final error = errorValue is Map
        ? errorValue['code']?.toString()
        : errorValue?.toString();
    final warning = _asMap(payload['warning']);
    final warningType = warning?['type']?.toString();
    final status = track == null ? null : _reportStatus[track];
    if (_shellBlocked) {
      return const {
        'code': 'shell_packing_blocked',
        'nextAction': '先完成壳识别/脱壳，暂停会员和广告定位。',
      };
    }
    if (error == 'REPORT_NOT_READY') {
      return const {
        'code': 'report_not_ready',
        'nextAction': '有 succeeded job 就直接 locate；没有才 analyze(wait=true)。',
      };
    }
    if (error == 'RESULT_NOT_FOUND') {
      return const {
        'code': 'result_not_found',
        'nextAction': 'Blutter 结果不存在，只允许重新 analyze 一次。',
      };
    }
    if (error == 'STACK_IMBALANCE') {
      return const {
        'code': 'stack_imbalance',
        'nextAction': '改用 force_return_constant、nop_out 或已验证的分支替换，不手写栈帧。',
      };
    }
    if (warningType == 'no_method_hits' || error == 'no_method_hits') {
      return const {
        'code': 'no_method_hits',
        'nextAction':
            '停止 patch；用 class_outline 核对真实 qualifiedId，再由 smali_read 验证。',
      };
    }
    if (args['blutterAction'] == 'callers' && _resultCount(payload) == 0) {
      return const {
        'code': 'direct_callers_empty',
        'nextAction': '不能断言无调用方；改用对象池 xref 或字段 dex_xref 反查，不重复 callers。',
      };
    }
    if (status != null && _blockedStatuses.contains(status)) {
      return {'code': status, 'nextAction': _statusRecovery(status)};
    }
    if (_signatureRisk) {
      return const {
        'code': 'signature_check_risk',
        'nextAction':
            '任何业务修改前，先对未改原包调用 signature_bypass(mode=normal) 做一次普通签名兼容注入；普通模式实机失败后才改用 original_apk 模式。',
      };
    }
    return null;
  }

  ApkAnalysisPhase? _phaseFor(String name, Map<String, dynamic> args) {
    if (name == LocalToolNames.routeTask ||
        name == LocalToolNames.apkProjectInfo ||
        (name == LocalToolNames.apkReport && args['section'] == 'decision')) {
      return ApkAnalysisPhase.startup;
    }
    final action = args['action']?.toString();
    final blutter = args['blutterAction']?.toString();
    if ((name == LocalToolNames.soAnalyze &&
            action == 'blutter' &&
            blutter == 'locate') ||
        name == LocalToolNames.dexSearch) {
      return ApkAnalysisPhase.locate;
    }
    if ((name == LocalToolNames.soAnalyze &&
            action == 'blutter' &&
            const {
              'search',
              'raw_strings',
              'values',
              'xref',
              'callers',
              'disasm',
            }.contains(blutter)) ||
        (name == LocalToolNames.soAnalyze &&
            const {'disasm', 'hexdump'}.contains(action)) ||
        const {
          LocalToolNames.dexXref,
          LocalToolNames.classOutline,
          LocalToolNames.smaliRead,
          AnalyzerToolNames.fieldUsage,
          AnalyzerToolNames.businessState,
        }.contains(name)) {
      return ApkAnalysisPhase.verify;
    }
    if (name == LocalToolNames.file &&
        const {'list', 'read', 'grep', 'strings'}.contains(action) &&
        (args['path']
                ?.toString()
                .replaceAll('\\', '/')
                .toLowerCase()
                .contains('/solab/blutter/') ??
            false)) {
      return ApkAnalysisPhase.verify;
    }
    if (const {
          LocalToolNames.apkPatchDex,
          LocalToolNames.apkPatchManifest,
          LocalToolNames.soPatchIntoApk,
          LocalToolNames.apkSign,
        }.contains(name) ||
        (name == LocalToolNames.soAnalyze &&
            const {'edit_asm', 'edit_hex', 'build'}.contains(action))) {
      return ApkAnalysisPhase.patch;
    }
    return null;
  }

  String? _trackFor(Map<String, dynamic> args, ApkAnalysisPhase phase) {
    if (phase == ApkAnalysisPhase.startup) return null;
    final found = _tracksFor(jsonEncode(args));
    _tracks.addAll(found);
    if (found.length == 1) return found.first;
    if (_tracks.length == 1) return _tracks.first;
    return _lastTrack;
  }

  String? _trackFromPayload(Map<String, dynamic> args) {
    final found = _tracksFor(jsonEncode(args));
    if (found.length == 1) return found.first;
    return _lastTrack;
  }

  static Set<String> _tracksFor(String text) {
    final lower = text.toLowerCase();
    final tracks = <String>{};
    if (_containsTerms(lower, const [
      '广告',
      '开屏',
      '插屏',
      '激励',
      '横幅',
      '信息流',
      'advert',
      'banner',
      'splash',
      'rewarded',
      'interstitial',
      'native ad',
      'ad',
      'ads',
    ])) {
      tracks.add('ads');
    }
    if (_containsTerms(lower, const [
      '会员',
      '权益',
      '订阅',
      '到期',
      '永久',
      'vip',
      'premium',
      'member',
      'membership',
      'pro',
      'subscription',
      'lifetime',
      'isvip',
      'hasvip',
      'viptype',
      'viplevel',
      'ismember',
      'ispremium',
      'ispro',
      'expiretime',
    ])) {
      tracks.add('membership');
    }
    return tracks;
  }

  static bool _containsTerms(String text, List<String> terms) => terms.any((
    term,
  ) {
    final shortAscii =
        term.length <= 3 &&
        term.codeUnits.every(
          (unit) =>
              (unit >= 0x61 && unit <= 0x7a) || (unit >= 0x30 && unit <= 0x39),
        );
    return shortAscii
        ? RegExp(
            '(^|[^a-z0-9])${RegExp.escape(term)}([^a-z0-9]|\$)',
          ).hasMatch(text)
        : text.contains(term);
  });

  static String _statusRecovery(String status) => switch (status) {
    'ambiguous' => '体系有歧义。一次展示前两类样本并询问用户已知文案、等级值或广告出现位置，不再自行加调用硬猜。',
    'clues_only' => '当前只有 UI/容器/展示线索。停止同词搜索，一次询问具体页面、时机或原文后再做一次窄 search。',
    'not_found' => '目标词未命中。先查 shellPacking；无壳则一次询问已知函数名、文案或等级值。',
    _ => '使用已有证据收口，缺少的新证据必须来自确定的替代路径。',
  };

  static int _resultCount(Map<String, dynamic> payload) {
    for (final key in const ['count', 'candidateCount', 'matched', 'total']) {
      final value = payload[key];
      if (value is num) return value.toInt();
    }
    for (final key in const [
      'matches',
      'items',
      'callers',
      'references',
      'hits',
    ]) {
      final value = payload[key];
      if (value is List) return value.length;
    }
    for (final value in payload.values) {
      final nested = _asMap(value);
      if (nested != null) {
        final count = _resultCount(nested);
        if (count > 0) return count;
      }
    }
    return 0;
  }

  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is! Map) return null;
    return value.map((key, item) => MapEntry(key.toString(), item));
  }

  static List<dynamic> _asList(Object? value) =>
      value is List ? value : const <dynamic>[];

  static Map<String, int> _phaseSnapshot(Map<ApkAnalysisPhase, int> values) => {
    for (final phase in ApkAnalysisPhase.values) phase.name: values[phase] ?? 0,
  };
}
