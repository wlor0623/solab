class AgentSkill {
  const AgentSkill({
    required this.id,
    this.name = '',
    this.description = '',
    this.version = '1.0.0',
    this.author = '',
    this.sourceUrl = '',
    this.enabled = true,
    this.topics = const <String>[],
    this.content = '',
  });

  final String id;
  final String name;
  final String description;
  final String version;
  final String author;
  final String sourceUrl;
  final bool enabled;
  final List<String> topics;
  final String content;

  AgentSkill copyWith({
    String? id,
    String? name,
    String? description,
    String? version,
    String? author,
    String? sourceUrl,
    bool? enabled,
    List<String>? topics,
    String? content,
  }) => AgentSkill(
    id: id ?? this.id,
    name: name ?? this.name,
    description: description ?? this.description,
    version: version ?? this.version,
    author: author ?? this.author,
    sourceUrl: sourceUrl ?? this.sourceUrl,
    enabled: enabled ?? this.enabled,
    topics: topics ?? this.topics,
    content: content ?? this.content,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'version': version,
    'author': author,
    'sourceUrl': sourceUrl,
    'enabled': enabled,
    'topics': topics,
    'content': content,
  };

  static AgentSkill fromJson(Map<String, dynamic> json) => AgentSkill(
    id: (json['id'] ?? '').toString(),
    name: (json['name'] ?? '').toString(),
    description: (json['description'] ?? '').toString(),
    version: (json['version'] ?? '1.0.0').toString(),
    author: (json['author'] ?? '').toString(),
    sourceUrl: (json['sourceUrl'] ?? '').toString(),
    enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
    topics: json['topics'] is List
        ? (json['topics'] as List)
              .map((item) => item.toString().trim())
              .where((item) => item.isNotEmpty)
              .toSet()
              .toList(growable: false)
        : const <String>[],
    content: (json['content'] ?? '').toString(),
  );
}
