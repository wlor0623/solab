import 'dart:async';
import 'dart:collection';

import '../services/apk_analysis_service.dart';
import '../services/apk_structural_service.dart';
import '../services/apk_toolchain_service.dart';
import '../services/apk_workspace_binding_service.dart';
import '../services/apk_workspace_service.dart';
import 'analyzer_api.dart';
import 'analyzer_index.dart';

// ============================================================================
// AnalyzerGateway 实现（Phase 0）
//
// Agent 通过 4 个高阶 API 访问分析引擎；底层工具对内执行。
// ============================================================================

class AnalyzerGatewayRegistry {
  AnalyzerGatewayRegistry._();

  static const _maxContexts = 8;
  static final LinkedHashMap<String, DefaultAnalyzerGateway> _byContext =
      LinkedHashMap<String, DefaultAnalyzerGateway>();

  static AnalyzerGateway forKey(String contextKey) {
    final key = contextKey.trim().isEmpty ? 'app' : contextKey.trim();
    final existing = _byContext.remove(key);
    if (existing != null) {
      _byContext[key] = existing;
      return existing;
    }
    final created = DefaultAnalyzerGateway();
    _byContext[key] = created;
    while (_byContext.length > _maxContexts) {
      _byContext.remove(_byContext.keys.first);
    }
    return created;
  }

  static void resetForTest() => _byContext.clear();
}

class DefaultAnalyzerGateway implements AnalyzerGateway {
  DefaultAnalyzerGateway({AnalyzerIndex? index})
    : index = index ?? AnalyzerIndex(apkId: 'unbound');

  AnalyzerIndex index;

  /// 最近 open 的 APK 路径（按需分析时用作兜底路径）。
  String _lastOpenedApkPath = '';

  /// 字段级 LRU 缓存：fieldLocator → 扫描结果。访问什么缓存什么，
  /// 不预建全量索引。命中直接返回，避免重复扫 dex。
  final Map<String, List<FieldRef>> _fieldRefCache = <String, List<FieldRef>>{};
  static const int _fieldRefCacheMax = 512;
  final Map<String, AnalyzerResult> _businessStateCache =
      <String, AnalyzerResult>{};
  static const int _businessStateCacheMax = 128;

  void _cacheFieldRefs(String cacheKey, List<FieldRef> refs) {
    if (refs.isEmpty) return;
    _fieldRefCache[cacheKey] = refs;
    // 简单 LRU 淘汰：超出上限删最旧（LinkedHashMap 按插入序）。
    while (_fieldRefCache.length > _fieldRefCacheMax) {
      _fieldRefCache.remove(_fieldRefCache.keys.first);
    }
  }

  void _cacheBusinessState(String key, AnalyzerResult result) {
    _businessStateCache[key] = result;
    while (_businessStateCache.length > _businessStateCacheMax) {
      _businessStateCache.remove(_businessStateCache.keys.first);
    }
  }

  static DefaultAnalyzerGateway get instance =>
      AnalyzerGatewayRegistry.forKey('app') as DefaultAnalyzerGateway;

  AnalyzerResult? _contextMismatch(String query, String? requestedApkId) {
    final requested = requestedApkId?.trim();
    if (requested == null || requested.isEmpty || index.apkId == 'unbound') {
      return null;
    }
    if (requested == index.apkId) return null;
    return AnalyzerResult(
      query: query,
      summary:
          'APK_CONTEXT_MISMATCH: 当前入口打开的是 ${index.apkId}，请求绑定 $requested。请重新 open，或不传 apkId 使用当前目标。',
      score: 0,
      confidence: ConfidenceLevel.high,
      evidenceLevel: EvidenceLevel.l0,
      sufficiency: Sufficiency.insufficient,
      stopReason: 'apk_context_mismatch',
      recommendedAction: 'OPEN_WORKSPACE',
      detail: <String, dynamic>{
        'code': 'APK_CONTEXT_MISMATCH',
        'currentApkId': index.apkId,
        'requestedApkId': requested,
      },
    );
  }

  Future<String?> _analysisPath() async {
    if (_lastOpenedApkPath.isNotEmpty) return _lastOpenedApkPath;
    try {
      return await ApkWorkspaceBindingService.activeApkPath();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<AnalyzerResult> openWorkspace({
    required String apkPath,
    String? apkIdOverride,
  }) async {
    // 幂等：同一路径已打开过时直接复用，避免每次再读完整报告。
    if (_lastOpenedApkPath == apkPath && index.apkId != 'unbound') {
      return AnalyzerResult(
        query: 'workspace.open($apkPath)',
        summary: '已打开（${index.apkId}），按需分析就绪。',
        score: 1,
        confidence: ConfidenceLevel.high,
        evidenceLevel: EvidenceLevel.l0,
        sufficiency: Sufficiency.complete,
        stopReason: 'workspace_reused',
        detail: <String, dynamic>{
          'apk_id': index.apkId,
          'apkId': index.apkId,
          'apk_path': apkPath,
        },
      );
    }

    // 首次打开时从报告取 APK 身份，后续调用走上面的内存复用路径。
    final report = await ApkWorkspaceService.readReport();
    final normalizedPath = apkPath.replaceAll('\\', '/');
    final fileName = normalizedPath.substring(
      normalizedPath.lastIndexOf('/') + 1,
    );
    final sourceApk = report?['sourceApk'];
    final reportPath = sourceApk is Map
        ? sourceApk['path']?.toString().replaceAll('\\', '/')
        : null;
    final reportFileName = report?['fileName']?.toString();
    final reportMatchesPath =
        reportPath == normalizedPath ||
        (reportPath == null && reportFileName == fileName);
    final sha = reportMatchesPath ? (report?['sha256'])?.toString() : null;
    final apkId =
        apkIdOverride ??
        (sha != null && sha.isNotEmpty ? 'sha256:$sha' : 'apk:$apkPath');
    index = AnalyzerIndex(apkId: apkId);
    _lastOpenedApkPath = apkPath;
    _fieldRefCache.clear();
    _businessStateCache.clear();

    // 按需分析模式：不预建任何索引。dex 总数从报告读（仅用于覆盖率展示）。
    final dexDetails = reportMatchesPath && report != null
        ? report['dexDetails']
        : null;
    if (dexDetails is List) {
      index.dexTotal = dexDetails.length;
      index.dexParsed = dexDetails.length;
    }

    return AnalyzerResult(
      query: 'workspace.open($apkPath)',
      summary: '已打开 APK（$apkId）。按需分析模式：无需预建索引，直接用 locate/trace 定位。',
      score: 1,
      confidence: ConfidenceLevel.high,
      evidenceLevel: EvidenceLevel.l0,
      sufficiency: Sufficiency.complete,
      stopReason: 'workspace_ready',
      detail: <String, dynamic>{
        'apk_id': apkId,
        'apkId': apkId,
        'apk_path': apkPath,
        'mode': 'on_demand',
      },
    );
  }

  @override
  Future<AnalyzerResult> globalSearch({
    required String query,
    int topK = 20,
    String? apkId,
  }) async {
    final mismatch = _contextMismatch('global_search($query)', apkId);
    if (mismatch != null) return mismatch;
    // 按需扫 dex：走底层 dex_search（class_by_string），真实跨 36 dex 搜。
    final viaNative = await _globalSearchNative(query, topK);
    if (viaNative != null) return viaNative;

    // 回退：内存索引（无工作区/通道不可用时）。
    final lower = query.toLowerCase();
    final hits = <IndexEntry>[];
    for (final e in index.classByName.values) {
      if (e.name.toLowerCase().contains(lower)) hits.add(e);
      if (hits.length >= topK) break;
    }
    if (hits.length < topK) {
      for (final e in index.methodBySignature.values) {
        if (e.name.toLowerCase().contains(lower)) {
          hits.add(e);
          if (hits.length >= topK) break;
        }
      }
    }
    if (hits.length < topK) {
      for (final e in index.fieldBySignature.values) {
        if (e.name.toLowerCase().contains(lower)) {
          hits.add(e);
          if (hits.length >= topK) break;
        }
      }
    }
    return IndexQueryResult.fromSearch(
      index: index,
      query: 'global_search($query)',
      hits: hits,
      summary: '内存索引命中 ${hits.length} 项',
    );
  }

  /// 走底层 dex_search（class_by_string）按需扫；通道不可用返回 null。
  Future<AnalyzerResult?> _globalSearchNative(String query, int topK) async {
    final path = await _analysisPath();
    if (path == null || path.isEmpty) return null;
    try {
      ApkStructuralResult? result;
      List<dynamic>? results;
      var action = '';
      for (final candidateAction in const <String>[
        'auto',
        'method_by_name',
        'class_by_name',
        'method_by_string',
        'class_by_string',
      ]) {
        final attempt = await ApkToolchainService.dexSearch(
          path: path,
          keyword: query,
          action: candidateAction,
          matchType: 'Contains',
          ignoreCase: true,
          limit: topK,
        );
        if (!attempt.ok || attempt.data == null) continue;
        final attemptResults = attempt.data!['results'];
        if (attemptResults is List && attemptResults.isNotEmpty) {
          result = attempt;
          results = attemptResults;
          action = candidateAction;
          break;
        }
      }
      if (result == null || results == null) {
        return AnalyzerResult(
          query: 'global_search($query)',
          summary: 'DEX 类名、方法名与字符串均未命中',
          score: 0,
          confidence: ConfidenceLevel.high,
          evidenceLevel: EvidenceLevel.l0,
          sufficiency: Sufficiency.complete,
          stopReason: 'no_hit',
          recommendedAction: 'FIND_CLASS',
        );
      }
      final candidates = <AnalyzerCandidate>[];
      final evidence = <Map<String, dynamic>>[];
      for (final raw in results) {
        if (raw is! Map) continue;
        final cls = raw['class']?.toString() ?? '';
        if (cls.isEmpty) continue;
        final method = raw['method']?.toString() ?? '';
        final locator = action.startsWith('method_') && method.isNotEmpty
            ? 'dex_method:$cls->$method'
            : 'dex_class:$cls';
        candidates.add(
          AnalyzerCandidate(
            locator: locator,
            score: 0.6,
            reason: '$action 命中 "$query"',
          ),
        );
        evidence.add(<String, dynamic>{
          'type': action.startsWith('method_') ? 'method_match' : 'class_match',
          'locator': locator,
          'simple_name': raw['simpleName']?.toString() ?? '',
        });
      }
      final total = result.data!['total'] ?? results.length;
      return AnalyzerResult(
        query: 'global_search($query)',
        summary: 'dex_search($action) 命中 $total 项',
        score: candidates.isEmpty ? 0 : 0.6,
        confidence: ConfidenceLevel.high,
        evidenceLevel: EvidenceLevel.l0,
        sufficiency: Sufficiency.complete,
        stopReason: candidates.isEmpty ? 'no_hit' : 'hits',
        primaryCandidates: candidates.take(topK).toList(),
        evidenceGraph: <String, dynamic>{
          'matches': evidence,
          'source': 'dex_search',
        },
        nextBestActions: <String>[
          for (final c in candidates.take(3)) 'class_outline("${c.locator}")',
        ],
        recommendedAction: candidates.isEmpty ? 'FIND_CLASS' : 'CLASS_OUTLINE',
        detail: <String, dynamic>{'total': total, 'results': results},
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<AnalyzerResult> findFieldUsage({
    required String fieldLocator,
    String? apkId,
  }) async {
    final mismatch = _contextMismatch('find_field_usage($fieldLocator)', apkId);
    if (mismatch != null) return mismatch;
    // 字段 → 读写方法：按需扫（LRU 缓存，二次命中秒回）。
    final refs = await _fieldRefsFor(fieldLocator);
    final reads = refs.where((r) => r.relation == 'READ_FIELD').length;
    final writes = refs.where((r) => r.relation == 'WRITE_FIELD').length;

    // 证据链：每条引用是「可复验证据」——locator + opcode + 指令 index，
    // Agent 可直接使用返回的定位信息复核，不盲信结论。
    final evidence = <Map<String, dynamic>>[
      for (final r in refs)
        <String, dynamic>{
          'type': r.relation == 'WRITE_FIELD' ? 'field_write' : 'field_read',
          'method': r.methodLocator,
          'opcode': r.opcode,
          'instruction_index': r.instructionIndex,
          'access_kind': r.accessKind,
        },
    ];

    // 排序（不造假概率）：写入方优先（权威），其次按指令序。
    final ranked = <Map<String, dynamic>>[
      for (final r in _rankFieldRefs(refs))
        <String, dynamic>{
          'locator': r.methodLocator,
          'rank_reason': _rankReasons(r),
          'is_writer': r.relation == 'WRITE_FIELD',
        },
    ];

    final writerRefs = refs.where((r) => r.relation == 'WRITE_FIELD').toList();
    final writer = writerRefs.isEmpty ? null : writerRefs.first;
    final conclusion = refs.isEmpty
        ? _fieldRefSource == 'native_xref'
              ? '字段 $fieldLocator 的实时扫描未发现读写引用'
              : '字段 $fieldLocator 暂无可验证读写引用（扫描不可用）'
        : writer != null
        ? '$fieldLocator 的权威写入方是 ${writer.methodLocator}'
        : '$fieldLocator 只有读取、无写入方';

    return AnalyzerResult(
      query: 'find_field_usage($fieldLocator)',
      summary: '$conclusion；$reads 读 $writes 写',
      score: refs.isEmpty ? 0 : 0.7,
      confidence: refs.isEmpty ? ConfidenceLevel.medium : ConfidenceLevel.high,
      evidenceLevel: refs.isEmpty
          ? EvidenceLevel.l1
          : (writes > 0 ? EvidenceLevel.l3 : EvidenceLevel.l2),
      sufficiency: refs.isEmpty && _fieldRefSource != 'native_xref'
          ? Sufficiency.insufficient
          : Sufficiency.complete,
      stopReason: refs.isEmpty
          ? 'no_refs'
          : (writes > 0 ? 'writer_confirmed' : 'read_only'),
      primaryCandidates: [
        for (final r in ranked.take(20))
          AnalyzerCandidate(
            locator: r['locator'] as String,
            score: (r['is_writer'] == true) ? 0.95 : 0.5,
            reason: (r['rank_reason'] as List).join(', '),
          ),
      ],
      evidenceGraph: <String, dynamic>{
        'field': fieldLocator,
        'evidence': evidence,
        'ranking': ranked,
        'source': _fieldRefSource,
      },
      uncertainties: writes > 1
          ? <dynamic>[
              <String, dynamic>{
                'reason': '字段有 $writes 个写入方，需 trace_backward 确认权威路径',
                'impact': '写入方候选不止一个',
              },
            ]
          : const <dynamic>[],
      nextBestActions: <String>[
        for (final r in ranked.take(3))
          'smali_read("${(r['locator'] as String).replaceFirst('dex_method:', '')}")',
        if (writer != null)
          'dex_xref("${writer.methodLocator.replaceFirst('dex_method:', '')}")',
      ],
      nextActions: <AnalyzerNextAction>[
        // 精确下一步：读消费点方法体（smali_read 底层，Agent 直接复制）。
        for (final r in ranked.take(3))
          AnalyzerNextAction(
            tool: 'smali_read',
            purpose: 'inspect',
            arguments: <String, dynamic>{
              'qualifiedId': (r['locator'] as String).replaceFirst(
                'dex_method:',
                '',
              ),
            },
            description: '读该消费点的 smali 字节码，确认逻辑后再改',
          ),
        if (writer != null)
          AnalyzerNextAction(
            tool: 'dex_xref',
            purpose: 'trace_callers',
            arguments: <String, dynamic>{
              'target': writer.methodLocator.replaceFirst('dex_method:', ''),
              'direction': 'to',
            },
            description: '按需查看权威写入方的上游调用者，避免修改无关下游判断',
          ),
      ],
      recommendedAction: refs.isEmpty
          ? 'FIND_CLASS'
          : (writer != null ? 'INSPECT_ENTITIES' : 'TRACE_BACKWARD'),
      detail: <String, dynamic>{
        'refs': [for (final r in refs) r.toJson()],
        'reads': reads,
        'writes': writes,
        'source': _fieldRefSource,
      },
    );
  }

  /// 排序：写入方优先，其余按指令序。
  List<FieldRef> _rankFieldRefs(List<FieldRef> refs) {
    final sorted = List<FieldRef>.from(refs);
    sorted.sort((a, b) {
      final aw = a.relation == 'WRITE_FIELD' ? 0 : 1;
      final bw = b.relation == 'WRITE_FIELD' ? 0 : 1;
      if (aw != bw) return aw.compareTo(bw);
      return a.instructionIndex.compareTo(b.instructionIndex);
    });
    return sorted;
  }

  List<String> _rankReasons(FieldRef r) {
    final reasons = <String>[];
    if (r.relation == 'WRITE_FIELD') reasons.add('writer');
    reasons.add(r.relation == 'WRITE_FIELD' ? 'WRITE_FIELD' : 'READ_FIELD');
    reasons.add('opcode=${r.opcode}');
    reasons.add('instruction#${r.instructionIndex}');
    return reasons;
  }

  /// Field XREF 数据源标识（测试/日志断言用）：
  /// sqlite_index=Kotlin Workspace 索引（纯 SELECT）；native_xref=按需扫 dex；memory=内存索引。
  String _fieldRefSource = 'memory';

  /// 公开只读：Field XREF 数据源（测试断言用）。
  String get fieldRefSource => _fieldRefSource;

  /// 按需查字段引用（LRU 缓存 → fieldXref 按需扫 → 内存索引兜底）。
  /// 不预建全量索引：首次扫，扫过即缓存，二次命中秒回。
  Future<List<FieldRef>> _fieldRefsFor(String fieldLocator) async {
    final path = await _analysisPath();
    // 归一化 fieldTarget：dex_field:Lcom/x/A;->f:I → Lcom/x/A;->f:I
    var fieldTarget = fieldLocator;
    if (fieldTarget.startsWith('dex_field:')) {
      fieldTarget = fieldTarget.substring('dex_field:'.length);
    }
    final cacheKey = '${path ?? _lastOpenedApkPath}|$fieldTarget';
    final cached = _fieldRefCache[cacheKey];
    if (cached != null) {
      _fieldRefSource = 'lru_cache';
      return cached;
    }
    if (path != null && path.isNotEmpty) {
      // fieldXref 通道（按需扫 dex）：一次扫出该字段的全部 READ/WRITE。
      try {
        final result = await ApkToolchainService.fieldXref(
          path: path,
          fieldTarget: fieldTarget,
        );
        if (result.ok && result.data != null) {
          final rawRefs = result.data!['fieldRefs'];
          if (rawRefs is List) {
            _fieldRefSource = 'native_xref';
            final refs = rawRefs.isEmpty
                ? const <FieldRef>[]
                : _parseFieldRefs(rawRefs);
            _cacheFieldRefs(cacheKey, refs);
            return refs;
          }
        }
      } catch (_) {
        // 通道失败回退。
      }
    }
    _fieldRefSource = 'memory';
    final memoryRefs = index.fieldRefs(fieldLocator);
    _cacheFieldRefs(cacheKey, memoryRefs);
    return memoryRefs;
  }

  List<FieldRef> _parseFieldRefs(List<dynamic> rawRefs) {
    final out = <FieldRef>[];
    for (final raw in rawRefs) {
      if (raw is! Map) continue;
      final field = raw['field']?.toString() ?? '';
      final method = raw['method']?.toString() ?? '';
      if (field.isEmpty || method.isEmpty) continue;
      out.add(
        FieldRef(
          fieldLocator: 'dex_field:$field',
          methodLocator: 'dex_method:$method',
          relation: raw['relation']?.toString() ?? 'READ_FIELD',
          accessKind: raw['accessKind']?.toString() ?? 'READ_INSTANCE',
          opcode: raw['opcode']?.toString() ?? 'iget',
          instructionIndex: (raw['instructionIndex'] as num?)?.toInt() ?? 0,
          dexId: (raw['dexId'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    return out;
  }

  @override
  Future<AnalyzerResult> analyzeBusinessState({
    required String targetKeyword,
    String domain = 'vip',
    String fieldName = '',
    String? apkId,
  }) async {
    final mismatch = _contextMismatch(
      'analyze_business_state($targetKeyword, $domain)',
      apkId,
    );
    if (mismatch != null) return mismatch;
    final cacheKey = '${index.apkId}|$targetKeyword|$domain|$fieldName';
    final cached = _businessStateCache[cacheKey];
    if (cached != null) return cached;
    final path = await _analysisPath();

    // 主数据源：analyzeModule(fields) 一步返回敏感字段 + 消费点 + patch 目标，
    // 底层内置通用领域词表（isVip/vipExpire/userType 等），跨 dex 聚合，
    // 不硬编码任何 APK 特定类名。
    if (path != null && path.isNotEmpty) {
      final result = await ApkAnalysisService.analyzeModule(
        path: path,
        module: 'fields',
        useCache: true,
      );
      if (result['ok'] == true) {
        final readCandidates = result['fieldReadCandidates'];
        final fieldCandidates = result['fieldCandidates'];
        final filter = (fieldName.isNotEmpty ? fieldName : targetKeyword)
            .toLowerCase();

        // 匹配源：优先 fieldReadCandidates（带消费点），补 fieldCandidates
        // （全字段，含消费点少被截断的字段）。用 field 字段名过滤，不 fallback。
        final allCandidates = <Map<String, dynamic>>[
          if (readCandidates is List)
            for (final r in readCandidates)
              if (r is Map) Map<String, dynamic>.from(r),
          if (fieldCandidates is List)
            for (final r in fieldCandidates)
              if (r is Map) Map<String, dynamic>.from(r),
        ];

        // 过滤：字段名含 filter（field 值形如 Lcom/x/Y;->isVip:I 或 Lcom/x/Y;->isVip）
        final matched = <Map<String, dynamic>>[];
        for (final raw in allCandidates) {
          final field = raw['field']?.toString() ?? '';
          final name =
              raw['name']?.toString() ??
              (field.contains('->') ? field.split('->').last : field);
          if (filter.isNotEmpty &&
              !field.toLowerCase().contains(filter) &&
              !name.toLowerCase().contains(filter)) {
            continue;
          }
          // 去重（fieldReadCandidates + fieldCandidates 可能重复）
          final sig = raw['field']?.toString() ?? raw['name']?.toString() ?? '';
          if (matched.any(
            (m) =>
                (m['field']?.toString() ?? m['name']?.toString() ?? '') == sig,
          )) {
            continue;
          }
          matched.add(raw);
        }

        // 关键修复：matched 为空 = 该关键词真无匹配字段，不 fallback 到全部，
        // 否则会命中无关字段（如 joiningDeadlineMs）。
        if (matched.isNotEmpty) {
          // VIP 状态优先布尔/整数用户字段；同类候选再按消费点数量排序。
          matched.sort(
            (a, b) => _businessFieldScore(
              b,
              domain: domain,
            ).compareTo(_businessFieldScore(a, domain: domain)),
          );

          // 取第一个字段，解析其消费点。
          final top = matched.first;
          final field = top['field']?.toString() ?? '';
          final refs = await _fieldRefsFor('dex_field:$field');
          final writers = refs
              .where((r) => r.relation == 'WRITE_FIELD')
              .toList();
          final readers = refs
              .where((r) => r.relation == 'READ_FIELD')
              .toList();
          final writer = writers.isEmpty ? null : writers.first;

          final evidence = <Map<String, dynamic>>[
            for (final r in refs)
              <String, dynamic>{
                'type': r.relation == 'WRITE_FIELD'
                    ? 'field_write'
                    : 'field_read',
                'method': r.methodLocator,
                'opcode': r.opcode,
              },
          ];

          final patchTargets = refs
              .map((ref) => ref.methodLocator.replaceFirst('dex_method:', ''))
              .toSet()
              .toList();

          final answer = AnalyzerResult(
            query: 'analyze_business_state($targetKeyword, $domain)',
            summary: writer != null
                ? '$domain 状态字段 dex_field:$field：${writers.length} 写 ${readers.length} 读，'
                      '权威写入方 ${writer.methodLocator}'
                : '$domain 状态字段 dex_field:$field：${readers.length} 读 0 写'
                      '（字段由反射/反序列化填充，无 iput 写入点，需逐读取点修改）',
            score: refs.isEmpty ? 0.3 : 0.9,
            confidence: ConfidenceLevel.high,
            evidenceLevel: refs.length >= 2
                ? EvidenceLevel.l4
                : (refs.isNotEmpty ? EvidenceLevel.l3 : EvidenceLevel.l1),
            sufficiency: refs.isEmpty
                ? Sufficiency.insufficient
                : Sufficiency.complete,
            stopReason: refs.isEmpty
                ? 'no_consumers'
                : (writer != null ? 'writer_confirmed' : 'read_only_field'),
            primaryCandidates: [
              if (writer != null)
                AnalyzerCandidate(
                  locator: writer.methodLocator,
                  score: 0.95,
                  reason: 'authoritative writer (WRITE_FIELD)',
                ),
              for (final r in readers.take(5))
                AnalyzerCandidate(
                  locator: r.methodLocator,
                  score: 0.5,
                  reason: 'READ_FIELD @${r.opcode}',
                ),
            ],
            evidenceGraph: <String, dynamic>{
              'field': 'dex_field:$field',
              'evidence': evidence,
              'patch_targets': patchTargets,
              'source': 'analyze_module_fields',
            },
            uncertainties: writers.length > 1
                ? <dynamic>[
                    <String, dynamic>{
                      'reason': '字段有 ${writers.length} 个写入方',
                      'impact': '需 trace_backward 确认权威路径',
                    },
                  ]
                : const <dynamic>[],
            nextBestActions: patchTargets.take(3).toList(),
            nextActions: <AnalyzerNextAction>[
              for (final m in patchTargets.take(5))
                AnalyzerNextAction(
                  tool: 'smali_read',
                  purpose: 'inspect',
                  arguments: <String, dynamic>{'qualifiedId': m},
                  description: '读消费点 smali，确认逻辑后定位 patch 目标',
                ),
            ],
            recommendedAction: 'INSPECT_ENTITIES',
            detail: <String, dynamic>{
              'field': 'dex_field:$field',
              'writers': [for (final w in writers) w.toJson()],
              'readers': readers.length,
              'patch_targets': patchTargets,
              'candidate_count': matched.length,
            },
          );
          _cacheBusinessState(cacheKey, answer);
          return answer;
        }
      }
    }

    // 回退：内存索引（无工作区/单元测试）。
    final hits = <IndexEntry>[];
    for (final e in index.fieldBySignature.values) {
      if (e.name.toLowerCase().contains(
        (fieldName.isNotEmpty ? fieldName : targetKeyword).toLowerCase(),
      )) {
        hits.add(e);
      }
    }
    if (hits.isEmpty) {
      for (final e in index.methodBySignature.values) {
        if (e.name.toLowerCase().contains(
          (fieldName.isNotEmpty ? fieldName : targetKeyword).toLowerCase(),
        )) {
          hits.add(e);
          if (hits.length >= 10) break;
        }
      }
    }
    final field = hits.isEmpty ? null : hits.first;
    final refs = field == null
        ? const <FieldRef>[]
        : await _fieldRefsFor(field.canonicalLocator);
    final writers = refs.where((r) => r.relation == 'WRITE_FIELD').toList();
    final writer = writers.isEmpty ? null : writers.first;
    final readers = refs.where((r) => r.relation == 'READ_FIELD').toList();

    return AnalyzerResult(
      query: 'analyze_business_state($targetKeyword, $domain)',
      summary: writer == null
          ? '未定位 $domain 字段 $targetKeyword'
          : '$domain 状态字段 ${field?.canonicalLocator}：权威写入方 ${writer.methodLocator}',
      score: writer == null ? 0 : 0.9,
      confidence: ConfidenceLevel.high,
      evidenceLevel: writer == null
          ? EvidenceLevel.l1
          : (refs.length >= 2 ? EvidenceLevel.l4 : EvidenceLevel.l3),
      sufficiency: writer == null
          ? Sufficiency.insufficient
          : Sufficiency.complete,
      stopReason: writer == null
          ? 'writer_not_found'
          : 'authoritative_writer_confirmed',
      primaryCandidates: [
        if (writer != null)
          AnalyzerCandidate(
            locator: writer.methodLocator,
            score: 0.95,
            reason: 'authoritative writer (WRITE_FIELD)',
          ),
      ],
      evidenceGraph: <String, dynamic>{
        'field': field?.canonicalLocator,
        'source': 'memory_index',
      },
      nextBestActions: <String>[
        if (writer != null) 'smali_read("${writer.methodLocator}")',
      ],
      nextActions: <AnalyzerNextAction>[
        if (writer != null)
          AnalyzerNextAction(
            tool: 'smali_read',
            purpose: 'inspect',
            arguments: <String, dynamic>{
              'qualifiedId': writer.methodLocator.replaceFirst(
                'dex_method:',
                '',
              ),
            },
            description: '读权威写入方 smali',
          ),
      ],
      recommendedAction: writer == null ? 'LOCATE_SYMBOL' : 'INSPECT_ENTITIES',
      detail: <String, dynamic>{
        'field': field?.canonicalLocator,
        'writers': [for (final w in writers) w.toJson()],
        'readers': readers.length,
        'source': 'memory_index',
      },
    );
  }

  int _businessFieldScore(
    Map<String, dynamic> candidate, {
    required String domain,
  }) {
    final field = candidate['field']?.toString() ?? '';
    final lower = field.toLowerCase();
    var score = (candidate['consumerCount'] as num?)?.toInt() ?? 0;
    if (domain.toLowerCase() != 'vip') return score;
    if (field.endsWith(':Z') || field.endsWith(':I')) score += 1000;
    if (lower.contains('user') ||
        lower.contains('account') ||
        lower.contains('member') ||
        lower.contains('profile') ||
        lower.contains('userinfo')) {
      score += 100;
    }
    return score;
  }
}
