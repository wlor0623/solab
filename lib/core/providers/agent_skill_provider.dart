import 'package:flutter/foundation.dart';

import '../database/business_preferences.dart';
import '../models/agent_skill.dart';
import '../services/agent_skill_store.dart';

class AgentSkillProvider with ChangeNotifier {
  AgentSkillProvider({required BusinessPreferences preferences})
    : _store = AgentSkillStore(preferences);

  final AgentSkillStore _store;
  List<AgentSkill> _skills = const <AgentSkill>[];
  bool _initialized = false;
  Future<void>? _initializing;

  List<AgentSkill> get skills => List<AgentSkill>.unmodifiable(_skills);

  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    return _initializing ??= _load();
  }

  Future<void> _load() async {
    try {
      _skills = await _store.getAll();
    } finally {
      _initialized = true;
      _initializing = null;
      notifyListeners();
    }
  }

  Future<void> save(AgentSkill skill) async {
    await initialize();
    final next = List<AgentSkill>.from(_skills);
    final index = next.indexWhere((item) => item.id == skill.id);
    if (index == -1) {
      next.add(skill);
    } else {
      next[index] = skill;
    }
    _skills = next;
    notifyListeners();
    await _store.save(next);
  }

  Future<void> delete(String id) async {
    await initialize();
    final next = _skills.where((skill) => skill.id != id).toList();
    _skills = next;
    notifyListeners();
    await _store.save(next);
  }

  List<AgentSkill> retrieve({required List<String> topics, int limit = 3}) {
    const genericTopics = <String>{'apk', '工作流', 'workflow', '规则', 'rules'};
    final query = topics
        .map((topic) => topic.trim().toLowerCase())
        .where((topic) => topic.isNotEmpty && !genericTopics.contains(topic))
        .toSet();
    if (query.isEmpty || limit <= 0) return const <AgentSkill>[];
    final ranked = <({AgentSkill skill, int score})>[];
    for (final skill in _skills.where((skill) => skill.enabled)) {
      final name = skill.name.toLowerCase();
      final description = skill.description.toLowerCase();
      final content = skill.content.toLowerCase();
      var score = 0;
      for (final topic in query) {
        if (name.contains(topic) || description.contains(topic)) score += 6;
        if (content.contains(topic)) score += 2;
        final queryConcepts = _topicConcepts(topic);
        for (final tag in skill.topics) {
          final normalized = tag.toLowerCase();
          if (normalized.contains(topic) || topic.contains(normalized)) {
            score += 8;
          } else if (_topicConcepts(normalized)
              .intersection(queryConcepts)
              .isNotEmpty) {
            score += 8;
          }
        }
      }
      if (score > 0) ranked.add((skill: skill, score: score));
    }
    ranked.sort((a, b) => b.score.compareTo(a.score));
    return ranked
        .take(limit.clamp(1, 5).toInt())
        .map((item) => item.skill)
        .toList(growable: false);
  }

  static Set<String> _topicConcepts(String value) {
    final text = value.trim().toLowerCase();
    final concepts = <String>{text};
    void add(String concept, RegExp pattern) {
      if (pattern.hasMatch(text)) concepts.add(concept);
    }

    add('ads', RegExp(r'广告|开屏|激励|banner|reward|interstitial|\bads?\b'));
    add(
      'membership',
      RegExp(r'会员|权益|订阅|到期|vip|svip|premium|\bpro\b|member|subscription'),
    );
    add('flutter', RegExp(r'flutter|dart|blutter|libapp'));
    add('dex', RegExp(r'dex|smali|字节码|方法|字段|类名'));
    add('native', RegExp(r'native|\.so|elf|rizin|原生'));
    add('signing', RegExp(r'签名|安装|启动|闪退|sign'));
    add('permission', RegExp(r'权限|组件|manifest|permission'));
    add('files', RegExp(r'文件|资源|精简|压缩|解压|zip'));
    return concepts;
  }
}
