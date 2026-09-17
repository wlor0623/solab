import 'dart:convert';

import '../database/business_preferences.dart';
import '../models/agent_skill.dart';

class AgentSkillStore {
  AgentSkillStore(this._preferences);

  static const itemsKey = 'agent_skills_v1';
  final BusinessPreferences _preferences;

  Future<List<AgentSkill>> getAll() async {
    await _preferences.load();
    final raw = _preferences.getString(itemsKey);
    if (raw == null || raw.isEmpty) return const <AgentSkill>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <AgentSkill>[];
      return decoded
          .whereType<Map>()
          .map((item) => AgentSkill.fromJson(item.cast<String, dynamic>()))
          .where((skill) => skill.id.trim().isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const <AgentSkill>[];
    }
  }

  Future<void> save(List<AgentSkill> skills) => _preferences.setString(
    itemsKey,
    jsonEncode(skills.map((skill) => skill.toJson()).toList(growable: false)),
  );
}
