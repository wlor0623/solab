import 'dart:convert';

import 'analyzer_api.dart';

// ============================================================================
// Analyzer Index — Phase 0 渐进式索引状态机 + Class/Method/Field/String 索引
//
// 原则：
// - 非阻塞：open 后后台渐进建索引，Agent 用 analysis.status() 查进度。
// - 复用现有执行器：类/方法/字段/字符串明细来自 ApkAnalysisService 的
//   analyzeModule(methods/fields) 与 dex 模块（带 LRU 文件缓存），
//   本层负责把它们聚合、归一化、持久化到内存索引。
// - Field XREF 独立就绪（field_xref=READY 即可做 VIP 定位，不必等全量）。
// ============================================================================

/// 索引里的一个条目（class/method/field/string 的归一化描述）。
class IndexEntry {
  const IndexEntry({
    required this.canonicalLocator,
    required this.name,
    required this.owner,
    required this.dexId,
    this.kind,
    this.extra = const <String, dynamic>{},
  });

  final String canonicalLocator;
  final String name;
  final String owner;
  final int dexId;
  final String? kind;
  final Map<String, dynamic> extra;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'canonical_locator': canonicalLocator,
    'name': name,
    'owner': owner,
    'dex_id': dexId,
    'kind': kind,
    'extra': extra,
  };
}

/// Field READ/WRITE 引用（find_field_usage 的索引查询结果）。
class FieldRef {
  const FieldRef({
    required this.fieldLocator,
    required this.methodLocator,
    required this.relation,
    required this.accessKind,
    required this.opcode,
    required this.instructionIndex,
    required this.dexId,
  });

  final String fieldLocator;
  final String methodLocator;

  /// READ_FIELD / WRITE_FIELD
  final String relation;

  /// READ_INSTANCE / WRITE_INSTANCE / READ_STATIC / WRITE_STATIC / ...
  final String accessKind;
  final String opcode;
  final int instructionIndex;
  final int dexId;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'field': fieldLocator,
    'method': methodLocator,
    'relation': relation,
    'accessKind': accessKind,
    'opcode': opcode,
    'instructionIndex': instructionIndex,
    'dexId': dexId,
  };
}

/// 引用边（Call Graph / 字段流 / 字符串引用的统一表示）。
class RefEdge {
  const RefEdge({
    required this.from,
    required this.to,
    required this.edgeType,
    this.dexId,
    this.instructionIndex,
  });

  final String from;
  final String to;

  /// CALLS / READS_FIELD / WRITES_FIELD / REFERENCES_STRING / OVERRIDES
  final String edgeType;
  final int? dexId;
  final int? instructionIndex;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'from': from,
    'to': to,
    'edge_type': edgeType,
    'dex_id': dexId,
    'instruction_index': instructionIndex,
  };
}

/// 方法体内的指令级引用（Method Body Index，Phase 1）。
///
/// Agent 问「这个 READ_FIELD 在方法里的哪一段」时，返回 instructionIndex
/// 附近 ±N 条指令，而不是整个方法体。
class MethodBody {
  const MethodBody({
    required this.methodLocator,
    this.invokeRefs = const <MethodBodyRef>[],
    this.fieldRefs = const <MethodBodyRef>[],
    this.stringRefs = const <MethodBodyRef>[],
    this.newInstanceRefs = const <MethodBodyRef>[],
    this.branchTargets = const <MethodBodyRef>[],
  });

  final String methodLocator;
  final List<MethodBodyRef> invokeRefs;
  final List<MethodBodyRef> fieldRefs;
  final List<MethodBodyRef> stringRefs;
  final List<MethodBodyRef> newInstanceRefs;
  final List<MethodBodyRef> branchTargets;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'method': methodLocator,
    'invoke_refs': [for (final r in invokeRefs) r.toJson()],
    'field_refs': [for (final r in fieldRefs) r.toJson()],
    'string_refs': [for (final r in stringRefs) r.toJson()],
    'new_instance_refs': [for (final r in newInstanceRefs) r.toJson()],
    'branch_targets': [for (final r in branchTargets) r.toJson()],
  };
}

/// 方法体内一条指令级引用。
class MethodBodyRef {
  const MethodBodyRef({
    required this.target,
    required this.instructionIndex,
    this.opcode,
  });

  /// 引用目标（方法/字段/字符串/类/分支偏移）。
  final String target;
  final int instructionIndex;
  final String? opcode;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'target': target,
    'instructionIndex': instructionIndex,
    'opcode': opcode,
  };
}

/// 内存索引（单 APK 一份，绑定 apkId）。
class AnalyzerIndex {
  AnalyzerIndex({required this.apkId});

  final String apkId;

  /// 各索引就绪状态（状态机）。
  final Map<IndexKind, IndexState> states = <IndexKind, IndexState>{
    IndexKind.clazz: IndexState.pending,
    IndexKind.method: IndexState.pending,
    IndexKind.field: IndexState.pending,
    IndexKind.fieldXref: IndexState.pending,
    IndexKind.string: IndexState.pending,
    IndexKind.callGraph: IndexState.pending,
  };

  // ---- 索引主体 ----
  final Map<String, IndexEntry> classByName = <String, IndexEntry>{};
  final Map<String, IndexEntry> methodBySignature = <String, IndexEntry>{};
  final Map<String, IndexEntry> fieldBySignature = <String, IndexEntry>{};
  final Map<String, List<String>> methodsByString = <String, List<String>>{};
  final Map<String, IndexEntry> entryByLocator = <String, IndexEntry>{};

  // ---- Field XREF ----
  final Map<String, List<FieldRef>> fieldRefsByField =
      <String, List<FieldRef>>{};

  // ---- 引用图（Call/Field/String） ----
  final Map<String, List<RefEdge>> edgesByFrom = <String, List<RefEdge>>{};
  final Map<String, List<RefEdge>> edgesByTo = <String, List<RefEdge>>{};

  // ---- Method Body Index（Phase 1：指令级引用） ----
  final Map<String, MethodBody> methodBodies = <String, MethodBody>{};

  // ---- 覆盖率 ----
  int dexParsed = 0;
  int dexTotal = 0;
  int classCount = 0;
  int methodCount = 0;
  int fieldCount = 0;

  int get classTotal => classByName.length;
  int get methodTotal => methodBySignature.length;
  int get fieldTotal => fieldBySignature.length;

  void markReady(IndexKind kind) => states[kind] = IndexState.ready;
  void markBuilding(IndexKind kind) => states[kind] = IndexState.building;
  void markFailed(IndexKind kind) => states[kind] = IndexState.failed;

  AnalysisStatus status() => AnalysisStatus(indexes: Map.of(states));

  Coverage coverage() => Coverage(
    dex: (dexParsed, dexTotal),
    classes: (classCount, classTotal),
    methods: (methodCount, methodTotal),
    fieldXref: (fieldCount, fieldTotal),
  );

  HealthLevel health() =>
      coverage().isComplete ? HealthLevel.healthy : HealthLevel.degraded;

  void addEntry(IndexEntry e) {
    entryByLocator[e.canonicalLocator] = e;
    switch (e.kind) {
      case 'class':
        classByName[e.name] = e;
      case 'method':
        methodBySignature[e.name] = e;
      case 'field':
        fieldBySignature[e.name] = e;
    }
  }

  void addStringRef(String value, String methodLocator) {
    (methodsByString[value] ??= <String>[]).add(methodLocator);
  }

  void addFieldRef(FieldRef ref) {
    (fieldRefsByField[ref.fieldLocator] ??= <FieldRef>[]).add(ref);
  }

  void addEdge(RefEdge e) {
    (edgesByFrom[e.from] ??= <RefEdge>[]).add(e);
    (edgesByTo[e.to] ??= <RefEdge>[]).add(e);
  }

  List<FieldRef> fieldRefs(String fieldLocator) =>
      fieldRefsByField[fieldLocator] ?? const <FieldRef>[];

  /// 方法体引用（Phase 1）；缺失时返回空。
  MethodBody? methodBody(String methodLocator) => methodBodies[methodLocator];

  /// 取方法体内 instructionIndex 附近 ±[window] 条指令的窗口。
  Map<String, dynamic> instructionWindow(
    String methodLocator,
    int instructionIndex, {
    int window = 10,
  }) {
    final body = methodBodies[methodLocator];
    if (body == null) return <String, dynamic>{'found': false};
    final refs = <MethodBodyRef>[
      ...body.invokeRefs,
      ...body.fieldRefs,
      ...body.stringRefs,
      ...body.newInstanceRefs,
      ...body.branchTargets,
    ]..sort((a, b) => a.instructionIndex.compareTo(b.instructionIndex));
    final inWindow = refs
        .where((r) => (r.instructionIndex - instructionIndex).abs() <= window)
        .toList();
    return <String, dynamic>{
      'method': methodLocator,
      'center': instructionIndex,
      'window': window,
      'refs': [for (final r in inWindow) r.toJson()],
    };
  }

  List<RefEdge> outgoing(String from) => edgesByFrom[from] ?? const <RefEdge>[];
  List<RefEdge> incoming(String to) => edgesByTo[to] ?? const <RefEdge>[];

  Map<String, dynamic> toJson() => <String, dynamic>{
    'apk_id': apkId,
    'status': status().toJson(),
    'coverage': coverage().toJson(),
    'health': health().label,
    'classes': classCount,
    'methods': methodCount,
    'fields': fieldCount,
  };
}

/// 索引加载/调度：把现有执行器的输出聚合进 [AnalyzerIndex]。
///
/// 这是 Phase 0 的适配层：未来可直接替换为原生持久化索引（SQLite/DuckDB），
/// 本类只负责「执行器输出 → 归一化索引条目」的映射与状态推进。
class AnalyzerIndexBuilder {
  AnalyzerIndexBuilder({required this.index});

  final AnalyzerIndex index;

  /// 从 analyzeModule(methods/fields) 的输出喂入索引。
  /// [moduleJson] 为 native `analyzeModule` 返回的 JSON（或缓存读取）。
  void ingestModule(String module, Map<String, dynamic> moduleJson) {
    final dexId = (moduleJson['dexId'] as num?)?.toInt() ?? 0;
    final items = moduleJson['items'];
    if (items is! List) return;
    switch (module) {
      case 'methods':
        index.markBuilding(IndexKind.method);
        for (final raw in items) {
          if (raw is! Map) continue;
          final name = raw['name']?.toString() ?? '';
          final owner = raw['owner']?.toString() ?? '';
          final sig = raw['signature']?.toString() ?? name;
          if (name.isEmpty) continue;
          final locator = 'dex_method:$sig';
          index.addEntry(
            IndexEntry(
              canonicalLocator: locator,
              name: sig,
              owner: owner,
              dexId: dexId,
              kind: 'method',
            ),
          );
          index.methodCount++;
          // 方法内字符串引用
          final strings = raw['strings'];
          if (strings is List) {
            for (final s in strings) {
              final v = s?.toString();
              if (v != null && v.isNotEmpty) index.addStringRef(v, locator);
            }
          }
        }
        index.markReady(IndexKind.method);
      case 'fields':
        index.markBuilding(IndexKind.field);
        for (final raw in items) {
          if (raw is! Map) continue;
          final name = raw['name']?.toString() ?? '';
          final owner = raw['owner']?.toString() ?? '';
          final sig = raw['signature']?.toString() ?? name;
          if (name.isEmpty) continue;
          final locator = 'dex_field:$sig';
          index.addEntry(
            IndexEntry(
              canonicalLocator: locator,
              name: sig,
              owner: owner,
              dexId: dexId,
              kind: 'field',
            ),
          );
          index.fieldCount++;
        }
        index.markReady(IndexKind.field);
    }
  }

  /// 从 analyzeModule(classPrefix/offset) 的输出喂入类索引。
  void ingestClasses(Map<String, dynamic> moduleJson, {int dexId = 0}) {
    final items = moduleJson['items'];
    if (items is! List) return;
    index.markBuilding(IndexKind.clazz);
    for (final raw in items) {
      if (raw is! Map) continue;
      final name = raw['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      index.addEntry(
        IndexEntry(
          canonicalLocator: 'dex_class:$name',
          name: name,
          owner: name,
          dexId: dexId,
          kind: 'class',
        ),
      );
      index.classCount++;
    }
    index.markReady(IndexKind.clazz);
  }

  /// 从 analyzeModule(strings) 输出喂入字符串索引。
  void ingestStrings(Map<String, dynamic> moduleJson) {
    final items = moduleJson['items'];
    if (items is! List) return;
    index.markBuilding(IndexKind.string);
    for (final raw in items) {
      if (raw is! Map) continue;
      final value = raw['value']?.toString() ?? '';
      final methods = raw['methods'];
      if (value.isEmpty) continue;
      if (methods is List) {
        for (final m in methods) {
          final ml = m?.toString();
          if (ml != null && ml.isNotEmpty) {
            index.addStringRef(value, ml);
          }
        }
      }
    }
    index.markReady(IndexKind.string);
  }

  /// 从 dex_xref 输出喂入引用图（CALLS / READS_FIELD / WRITES_FIELD）。
  /// [xrefJson] 为 native `dexXref` 返回的 JSON。
  void ingestXref(Map<String, dynamic> xrefJson) {
    final dexId = (xrefJson['dexId'] as num?)?.toInt() ?? 0;
    final calls = xrefJson['calls'];
    if (calls is List) {
      for (final raw in calls) {
        if (raw is! Map) continue;
        final from = raw['caller']?.toString() ?? '';
        final to = raw['callee']?.toString() ?? '';
        if (from.isEmpty || to.isEmpty) continue;
        index.addEdge(
          RefEdge(
            from: 'dex_method:$from',
            to: 'dex_method:$to',
            edgeType: 'CALLS',
            dexId: dexId,
          ),
        );
      }
    }
    final refs = xrefJson['fieldRefs'];
    if (refs is List) {
      for (final raw in refs) {
        if (raw is! Map) continue;
        final field = raw['field']?.toString() ?? '';
        final method = raw['method']?.toString() ?? '';
        final relation = raw['relation']?.toString() ?? 'READ_FIELD';
        if (field.isEmpty || method.isEmpty) continue;
        index.addFieldRef(
          FieldRef(
            fieldLocator: 'dex_field:$field',
            methodLocator: 'dex_method:$method',
            relation: relation,
            accessKind: raw['accessKind']?.toString() ?? 'READ_INSTANCE',
            opcode: raw['opcode']?.toString() ?? 'iget',
            instructionIndex: (raw['instructionIndex'] as num?)?.toInt() ?? 0,
            dexId: dexId,
          ),
        );
        index.addEdge(
          RefEdge(
            from: 'dex_method:$method',
            to: 'dex_field:$field',
            edgeType: relation == 'WRITE_FIELD'
                ? 'WRITES_FIELD'
                : 'READS_FIELD',
            dexId: dexId,
            instructionIndex: (raw['instructionIndex'] as num?)?.toInt(),
          ),
        );
      }
    }
    index.markReady(IndexKind.fieldXref);
  }

  /// 设置解析进度（覆盖率分母）。
  void setDexTotals(int parsed, int total) {
    index.dexParsed = parsed;
    index.dexTotal = total;
  }

  /// 喂入方法体指令级引用（Method Body Index）。
  /// [methodJson] 形如 { 'signature': ..., 'instructions': [...] }，
  /// 每条 instruction: { index, opcode, refs: [{target, type}] }。
  void ingestMethodBody(String signature, Map<String, dynamic> methodJson) {
    final locator = 'dex_method:$signature';
    final instructions = methodJson['instructions'];
    if (instructions is! List) return;
    final invokes = <MethodBodyRef>[];
    final fields = <MethodBodyRef>[];
    final strings = <MethodBodyRef>[];
    final news = <MethodBodyRef>[];
    final branches = <MethodBodyRef>[];
    for (final raw in instructions) {
      if (raw is! Map) continue;
      final idx = (raw['index'] as num?)?.toInt() ?? 0;
      final opcode = raw['opcode']?.toString();
      final refs = raw['refs'];
      if (refs is! List) continue;
      for (final r in refs) {
        if (r is! Map) continue;
        final target = r['target']?.toString() ?? '';
        if (target.isEmpty) continue;
        final type = r['type']?.toString() ?? 'invoke';
        final ref = MethodBodyRef(
          target: target,
          instructionIndex: idx,
          opcode: opcode,
        );
        switch (type) {
          case 'field':
            fields.add(ref);
          case 'string':
            strings.add(ref);
          case 'new_instance':
            news.add(ref);
          case 'branch':
            branches.add(ref);
          default:
            invokes.add(ref);
        }
      }
    }
    index.methodBodies[locator] = MethodBody(
      methodLocator: locator,
      invokeRefs: invokes,
      fieldRefs: fields,
      stringRefs: strings,
      newInstanceRefs: news,
      branchTargets: branches,
    );
    index.markReady(IndexKind.method);
  }
}

/// 把索引查询结果包装成统一 [AnalyzerResult]。
class IndexQueryResult {
  static AnalyzerResult fromSearch({
    required AnalyzerIndex index,
    required String query,
    required List<IndexEntry> hits,
    String summary = '',
  }) {
    final isComplete = index.coverage().isComplete;
    return AnalyzerResult(
      query: query,
      summary: summary.isEmpty
          ? '命中 ${hits.length} 项（索引 ${isComplete ? '完整' : '进行中'}）'
          : summary,
      score: hits.isEmpty ? 0 : 0.5,
      confidence: isComplete ? ConfidenceLevel.high : ConfidenceLevel.medium,
      evidenceLevel: EvidenceLevel.l0,
      sufficiency: isComplete ? Sufficiency.complete : Sufficiency.insufficient,
      primaryCandidates: [
        for (final h in hits)
          AnalyzerCandidate(
            locator: h.canonicalLocator,
            score: 0.5,
            reason: '索引命中',
          ),
      ],
      nextBestActions: hits.isEmpty
          ? const <String>['find_class', 'find_method']
          : const <String>[],
      detail: <String, dynamic>{
        'hits': [for (final h in hits) h.toJson()],
      },
    );
  }
}

/// 序列化辅助（供测试/日志）。
String encodeJson(Map<String, dynamic> json) => jsonEncode(json);
