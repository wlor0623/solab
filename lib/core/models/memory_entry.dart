import 'dart:math';

enum MemoryScope { global, assistant }

enum MemoryType { identity, workflow, voice, instruction, apkPatch, apkNote }

enum MemoryStatus { active, archived }

enum MemorySource { manual, tool, extracted, distilled }

class MemoryEntry {
  final String id;
  final MemoryScope scope;
  final String? assistantId;
  final MemoryType type;
  final MemoryStatus status;
  final String content;
  final MemorySource source;
  final List<String> relatedIds;
  final List<String> migrationIds;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 结构化扩展数据（APK 经验指纹 / 笔记 locator 等）。经 toPayload 序列化进
  /// payload JSON，由 drift 镜像表的 payload 列原样承载，无需独立列。
  final Map<String, dynamic>? extraJson;

  const MemoryEntry({
    required this.id,
    required this.scope,
    this.assistantId,
    required this.type,
    this.status = MemoryStatus.active,
    required this.content,
    this.source = MemorySource.manual,
    this.relatedIds = const <String>[],
    this.migrationIds = const <String>[],
    required this.createdAt,
    required this.updatedAt,
    this.extraJson,
  });

  MemoryEntry copyWith({
    String? id,
    MemoryScope? scope,
    String? assistantId,
    MemoryType? type,
    MemoryStatus? status,
    String? content,
    MemorySource? source,
    List<String>? relatedIds,
    List<String>? migrationIds,
    DateTime? createdAt,
    DateTime? updatedAt,
    Map<String, dynamic>? extraJson,
    bool clearExtraJson = false,
    bool clearAssistantId = false,
  }) => MemoryEntry(
    id: id ?? this.id,
    scope: scope ?? this.scope,
    assistantId: clearAssistantId ? null : (assistantId ?? this.assistantId),
    type: type ?? this.type,
    status: status ?? this.status,
    content: content ?? this.content,
    source: source ?? this.source,
    relatedIds: relatedIds ?? this.relatedIds,
    migrationIds: migrationIds ?? this.migrationIds,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    extraJson: clearExtraJson ? null : (extraJson ?? this.extraJson),
  );

  Map<String, dynamic> toPayload() => {
    'id': id,
    'scope': scopeToString(scope),
    'assistantId': assistantId,
    'type': typeToString(type),
    'status': statusToString(status),
    'content': content,
    'source': sourceToString(source),
    'relatedIds': relatedIds,
    if (migrationIds.isNotEmpty) 'migrationIds': migrationIds,
    if (extraJson != null) 'extraJson': extraJson,
    'createdAt': createdAt.microsecondsSinceEpoch,
    'updatedAt': updatedAt.microsecondsSinceEpoch,
  };

  static MemoryEntry fromPayload(Map<String, dynamic> json) {
    final scope = scopeFromString(json['scope'] as String);
    return MemoryEntry(
      id: json['id'] as String,
      scope: scope,
      assistantId: json['assistantId'] as String?,
      type: typeFromString(json['type'] as String),
      status: statusFromString((json['status'] as String?) ?? 'active'),
      content: json['content'] as String,
      source: sourceFromString((json['source'] as String?) ?? 'manual'),
      relatedIds:
          (json['relatedIds'] as List?)?.cast<String>() ?? const <String>[],
      migrationIds:
          (json['migrationIds'] as List?)?.cast<String>() ?? const <String>[],
      createdAt: DateTime.fromMicrosecondsSinceEpoch(
        (json['createdAt'] as num).toInt(),
      ),
      updatedAt: DateTime.fromMicrosecondsSinceEpoch(
        (json['updatedAt'] as num).toInt(),
      ),
      extraJson: json['extraJson'] is Map
          ? Map<String, dynamic>.from(json['extraJson'] as Map)
          : null,
    );
  }

  /// Trim, collapse every whitespace run to a single space, then lowercase.
  static String normalizeContent(String content) {
    return content.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }

  /// Alphabet: `0123456789abcdef` (8 hex chars after `mem_`).
  static String newId([Random? random]) {
    final rng = random ?? Random.secure();
    const alphabet = '0123456789abcdef';
    final buf = StringBuffer('mem_');
    for (var i = 0; i < 8; i++) {
      buf.write(alphabet[rng.nextInt(alphabet.length)]);
    }
    return buf.toString();
  }

  static String scopeToString(MemoryScope scope) {
    switch (scope) {
      case MemoryScope.global:
        return 'global';
      case MemoryScope.assistant:
        return 'assistant';
    }
  }

  static MemoryScope scopeFromString(String value) {
    switch (value) {
      case 'global':
        return MemoryScope.global;
      case 'assistant':
        return MemoryScope.assistant;
      default:
        throw FormatException('Unknown MemoryScope: $value');
    }
  }

  static String typeToString(MemoryType type) {
    switch (type) {
      case MemoryType.identity:
        return 'identity';
      case MemoryType.workflow:
        return 'workflow';
      case MemoryType.voice:
        return 'voice';
      case MemoryType.instruction:
        return 'instruction';
      case MemoryType.apkPatch:
        return 'apk_patch';
      case MemoryType.apkNote:
        return 'apk_note';
    }
  }

  static MemoryType typeFromString(String value) {
    switch (value) {
      case 'identity':
        return MemoryType.identity;
      case 'workflow':
        return MemoryType.workflow;
      case 'voice':
        return MemoryType.voice;
      case 'instruction':
        return MemoryType.instruction;
      case 'apk_patch':
        return MemoryType.apkPatch;
      case 'apk_note':
        return MemoryType.apkNote;
      default:
        throw FormatException('Unknown MemoryType: $value');
    }
  }

  static String statusToString(MemoryStatus status) {
    switch (status) {
      case MemoryStatus.active:
        return 'active';
      case MemoryStatus.archived:
        return 'archived';
    }
  }

  static MemoryStatus statusFromString(String value) {
    switch (value) {
      case 'active':
        return MemoryStatus.active;
      case 'archived':
        return MemoryStatus.archived;
      default:
        throw FormatException('Unknown MemoryStatus: $value');
    }
  }

  static String sourceToString(MemorySource source) {
    switch (source) {
      case MemorySource.manual:
        return 'manual';
      case MemorySource.tool:
        return 'tool';
      case MemorySource.extracted:
        return 'extracted';
      case MemorySource.distilled:
        return 'distilled';
    }
  }

  static MemorySource sourceFromString(String value) {
    switch (value) {
      case 'manual':
        return MemorySource.manual;
      case 'tool':
        return MemorySource.tool;
      case 'extracted':
        return MemorySource.extracted;
      case 'distilled':
        return MemorySource.distilled;
      default:
        throw FormatException('Unknown MemorySource: $value');
    }
  }
}

/// 记忆对指定助手的可见性（global 对所有助手可见；assistant 域仅属主可见）。
/// 复用：memory_tools 与 memory_provider_v2 曾各自实现一份 _isVisible。
extension MemoryVisibility on MemoryEntry {
  bool isVisibleFor(String? assistantId) {
    if (scope == MemoryScope.global) return true;
    return assistantId != null && assistantId == this.assistantId;
  }
}
