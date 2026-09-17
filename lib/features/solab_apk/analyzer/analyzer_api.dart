import 'dart:convert';

// ============================================================================
// SoLab APK 分析引擎 — 统一对外接口（Phase 0 冻结）
//
// 架构：Agent 只面对 4 个高阶 Analyzer API。
// 底层工具作为 Analyzer Engine 的内部执行器，对 Agent 不可见。
//
// 纪律：
//   1. 不要堆工具数量：58 → 20，而不是 58 → 80。
//   2. 高阶 API 不是工具链包装器：global_search 内部是索引查询，不是 N 次扫描拼接。
//   3. 不要过早做完整数据流分析：SSA/Taint/完整 Interprocedural 先不做。
// ============================================================================

// ----------------------------------------------------------------------------
// 4.1 统一 Locator
// ----------------------------------------------------------------------------

/// 统一 Locator（对外）：描述一个可定位的对象。
///
/// 形式：
///   dex_class:Lcom/lindu/app/UserInfoBean;
///   dex_method:Lcom/lindu/app/UserInfoBean;->isVip()I
///   dex_field:Lcom/lindu/app/UserInfoBean;->isVip:I
///   string:"vipExpire"
///   resource:0x7f010000
///   so:lib/arm64-v8a/libnative.so
///   native:libnative.so@0x123456
///   zip_entry:AndroidManifest.xml
sealed class Locator {
  const Locator(this.raw);

  final String raw;

  static Locator? tryParse(String raw) {
    final s = raw.trim();
    if (s.startsWith('dex_class:')) return DexClassLocator(s.substring(10));
    if (s.startsWith('dex_method:')) return DexMethodLocator(s.substring(11));
    if (s.startsWith('dex_field:')) return DexFieldLocator(s.substring(10));
    if (s.startsWith('string:')) return StringLocator(s.substring(7));
    if (s.startsWith('resource:')) return ResourceLocator(s.substring(9));
    if (s.startsWith('so:')) return SoLocator(s.substring(3));
    if (s.startsWith('native:')) return NativeLocator(s.substring(7));
    if (s.startsWith('zip_entry:')) return ZipEntryLocator(s.substring(10));
    return null;
  }

  @override
  String toString() => raw;
}

class DexClassLocator extends Locator {
  const DexClassLocator(String descriptor)
    : descriptor = descriptor,
      super('dex_class:$descriptor');
  final String descriptor;
}

class DexMethodLocator extends Locator {
  const DexMethodLocator(String signature)
    : signature = signature,
      super('dex_method:$signature');
  final String signature;
}

class DexFieldLocator extends Locator {
  const DexFieldLocator(String signature)
    : signature = signature,
      super('dex_field:$signature');
  final String signature;
}

class StringLocator extends Locator {
  const StringLocator(String value) : value = value, super('string:"$value"');
  final String value;
}

class ResourceLocator extends Locator {
  const ResourceLocator(String idHex) : idHex = idHex, super('resource:$idHex');
  final String idHex;
}

class SoLocator extends Locator {
  const SoLocator(String path) : path = path, super('so:$path');
  final String path;
}

class NativeLocator extends Locator {
  const NativeLocator(String path) : path = path, super('native:$path');
  final String path;
}

class ZipEntryLocator extends Locator {
  const ZipEntryLocator(String path) : path = path, super('zip_entry:$path');
  final String path;
}

// ----------------------------------------------------------------------------
// 4.2 内部 Canonical ID（绑定 APK 身份，防止多版本混淆）
// ----------------------------------------------------------------------------

/// 内部 Canonical ID：数据库/索引里每个对象的唯一身份。
class CanonicalId {
  const CanonicalId({
    required this.apkId,
    required this.objectId,
    required this.canonicalLocator,
    required this.parserVersion,
    required this.schemaVersion,
  });

  /// sha256:xxxx（APK 身份）
  final String apkId;

  /// uuid（对象唯一 id）
  final String objectId;

  /// 规范化 locator
  final String canonicalLocator;

  final String parserVersion;
  final String schemaVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'apk_id': apkId,
    'object_id': objectId,
    'canonical_locator': canonicalLocator,
    'parser_version': parserVersion,
    'schema_version': schemaVersion,
  };

  static CanonicalId fromJson(Map<String, dynamic> json) => CanonicalId(
    apkId: json['apk_id'] as String,
    objectId: json['object_id'] as String,
    canonicalLocator: json['canonical_locator'] as String,
    parserVersion: json['parser_version'] as String,
    schemaVersion: json['schema_version'] as String,
  );
}

// ----------------------------------------------------------------------------
// 4.3 索引状态机（非阻塞全量）
// ----------------------------------------------------------------------------

enum IndexKind { clazz, method, field, fieldXref, string, callGraph }

enum IndexState { pending, building, ready, failed }

extension IndexStateLabel on IndexState {
  String get label => switch (this) {
    IndexState.pending => 'PENDING',
    IndexState.building => 'BUILDING',
    IndexState.ready => 'READY',
    IndexState.failed => 'FAILED',
  };
}

/// `analysis.status()` 返回的索引状态机快照。
class AnalysisStatus {
  const AnalysisStatus({required this.indexes});

  final Map<IndexKind, IndexState> indexes;

  bool isReady(IndexKind kind) => indexes[kind] == IndexState.ready;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'indexStatus': <String, dynamic>{
      'class': indexes[IndexKind.clazz]?.label ?? 'PENDING',
      'method': indexes[IndexKind.method]?.label ?? 'PENDING',
      'field': indexes[IndexKind.field]?.label ?? 'PENDING',
      'field_xref': indexes[IndexKind.fieldXref]?.label ?? 'PENDING',
      'string': indexes[IndexKind.string]?.label ?? 'PENDING',
      'call_graph': indexes[IndexKind.callGraph]?.label ?? 'PENDING',
    },
  };
}

// ----------------------------------------------------------------------------
// 4.4 健康检查与覆盖率
// ----------------------------------------------------------------------------

enum HealthLevel { healthy, degraded }

extension HealthLabel on HealthLevel {
  String get label => switch (this) {
    HealthLevel.healthy => 'HEALTHY',
    HealthLevel.degraded => 'DEGRADED',
  };
}

/// 覆盖率（实际解析 vs 期望全量）。
class Coverage {
  const Coverage({
    required this.dex,
    required this.classes,
    required this.methods,
    required this.fieldXref,
  });

  final (int, int) dex;
  final (int, int) classes;
  final (int, int) methods;
  final (int, int) fieldXref;

  bool get isComplete =>
      dex.$1 > 0 &&
      dex.$1 == dex.$2 &&
      classes.$1 > 0 &&
      classes.$1 == classes.$2 &&
      methods.$1 > 0 &&
      methods.$1 == methods.$2 &&
      fieldXref.$1 > 0 &&
      fieldXref.$1 == fieldXref.$2;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'dex': '${dex.$1}/${dex.$2}',
    'classes': '${classes.$1}/${classes.$2}',
    'methods': '${methods.$1}/${methods.$2}',
    'field_xref': '${fieldXref.$1}/${fieldXref.$2}',
  };
}

// ----------------------------------------------------------------------------
// 六、统一返回格式
// ----------------------------------------------------------------------------

enum ConfidenceLevel { high, medium, low }

extension ConfidenceLabel on ConfidenceLevel {
  String get label => switch (this) {
    ConfidenceLevel.high => 'HIGH',
    ConfidenceLevel.medium => 'MEDIUM',
    ConfidenceLevel.low => 'LOW',
  };
}

/// 证据等级：L0=搜索命中 / L1=静态引用确认 / L2=调用关系确认 /
/// L3=数据流关系确认 / L4=多证据闭环。
enum EvidenceLevel { l0, l1, l2, l3, l4 }

extension EvidenceLabel on EvidenceLevel {
  String get label => 'L$index';
}

enum Sufficiency { complete, insufficient }

extension SufficiencyLabel on Sufficiency {
  String get label => switch (this) {
    Sufficiency.complete => 'COMPLETE',
    Sufficiency.insufficient => 'INSUFFICIENT',
  };
}

/// 候选（primary_candidates 项）。
class AnalyzerCandidate {
  const AnalyzerCandidate({
    required this.locator,
    required this.score,
    required this.reason,
  });

  final String locator;
  final double score;
  final String reason;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'locator': locator,
    'score': score,
    'reason': reason,
  };
}

/// 结构化下一步（MT 风格 nextActions）。
/// 带具体工具名 + 用途 + 可直接复制的参数（locator），Agent 不迷路。
class AnalyzerNextAction {
  const AnalyzerNextAction({
    required this.tool,
    required this.purpose,
    required this.arguments,
    this.description = '',
  });

  final String tool;
  final String purpose;
  final Map<String, dynamic> arguments;
  final String description;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'tool': tool,
    'purpose': purpose,
    'arguments': arguments,
    'description': description,
  };
}

/// 统一返回格式（所有高阶 API 均返回该结构）。
///
/// 关键区分：
/// - [score] = 排序值，不是概率
/// - [confidence] = 置信度描述（HIGH/MEDIUM/LOW）
/// - [evidenceLevel] = L0..L4
/// - [sufficiency] = COMPLETE / INSUFFICIENT
/// - [stopReason] = 为什么现在可以停了
class AnalyzerResult {
  const AnalyzerResult({
    required this.query,
    required this.summary,
    required this.score,
    required this.confidence,
    required this.evidenceLevel,
    required this.sufficiency,
    this.stopReason,
    this.primaryCandidates = const <AnalyzerCandidate>[],
    this.evidenceGraph = const <String, dynamic>{},
    this.uncertainties = const <dynamic>[],
    this.nextBestActions = const <String>[],
    this.nextActions = const <AnalyzerNextAction>[],
    this.recommendedAction,
    this.detail,
  });

  final String query;
  final String summary;
  final double score;
  final ConfidenceLevel confidence;
  final EvidenceLevel evidenceLevel;
  final Sufficiency sufficiency;
  final String? stopReason;
  final List<AnalyzerCandidate> primaryCandidates;
  final Map<String, dynamic> evidenceGraph;
  final List<dynamic> uncertainties;
  final List<String> nextBestActions;

  /// 结构化下一步（MT 风格）：带 tool + purpose + 具体参数（locator），
  /// Agent 直接复制即可，不用猜下一步调什么、传什么参数。
  final List<AnalyzerNextAction> nextActions;
  final String? recommendedAction;

  /// 各 API 的附加结构数据（如 xref 列表、指令窗口等）。
  final dynamic detail;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'query': query,
    'summary': summary,
    'score': score,
    'confidence': confidence.label,
    'evidenceLevel': evidenceLevel.label,
    'sufficiency': sufficiency.label,
    'stop_reason': stopReason,
    'primary_candidates': [for (final c in primaryCandidates) c.toJson()],
    'evidence_graph': evidenceGraph,
    'uncertainties': uncertainties,
    'next_best_actions': nextBestActions,
    'nextActions': [for (final a in nextActions) a.toJson()],
    'recommended_action': recommendedAction,
    'detail': detail,
  };

  String encode() => jsonEncode(toJson());
}

// ----------------------------------------------------------------------------
// 4 个高阶 API
// ----------------------------------------------------------------------------

/// Analyzer Gateway：Agent 唯一可见的查询入口。
///
/// 内部封装 Search Engine / Graph Engine / Domain Analyzer /
/// Evidence Engine / Ranking Engine / Index 与底层 58 个执行器。
abstract class AnalyzerGateway {
  /// workspace.open()：打开 APK 工作区。
  Future<AnalyzerResult> openWorkspace({
    required String apkPath,
    String? apkIdOverride,
  });

  /// global_search()：跨全 dex/全结构聚合搜索，Top 20 候选。
  Future<AnalyzerResult> globalSearch({
    required String query,
    int topK = 20,
    String? apkId,
  });

  /// find_field_usage()：字段 READ/WRITE 消费点（索引查询，非扫描）。
  Future<AnalyzerResult> findFieldUsage({
    required String fieldLocator,
    String? apkId,
  });

  /// analyze_business_state()：业务状态自动分析（VIP/登录/广告等）。
  Future<AnalyzerResult> analyzeBusinessState({
    required String targetKeyword,
    String domain = 'vip',
    String fieldName = '',
    String? apkId,
  });
}
