import '../../solab_apk/services/apk_workspace_binding_service.dart';

class ToolSessionState {
  ToolSessionState._();

  static const _maxKnowledgeSessions = 16;
  static final Map<String, Set<String>> _prefetchedKnowledgeBySession =
      <String, Set<String>>{};
  static final Map<String, String> _lastBuiltSoPathByScope = {};
  static final Map<String, String> _lastBuiltSoApkPathByScope = {};
  static final Map<String, String> _lastBuiltSoEntryByScope = {};

  static String get _scopeKey =>
      ApkWorkspaceBindingService.currentScopeId ?? 'global';

  static String? get lastBuiltSoPath => _lastBuiltSoPathByScope[_scopeKey];
  static set lastBuiltSoPath(String? value) {
    if (value == null || value.isEmpty) {
      _lastBuiltSoPathByScope.remove(_scopeKey);
    } else {
      _lastBuiltSoPathByScope[_scopeKey] = value;
    }
  }

  static String? get lastBuiltSoApkPath =>
      _lastBuiltSoApkPathByScope[_scopeKey];
  static set lastBuiltSoApkPath(String? value) {
    if (value == null || value.isEmpty) {
      _lastBuiltSoApkPathByScope.remove(_scopeKey);
    } else {
      _lastBuiltSoApkPathByScope[_scopeKey] = value;
    }
  }

  static String? get lastBuiltSoEntry => _lastBuiltSoEntryByScope[_scopeKey];
  static set lastBuiltSoEntry(String? value) {
    if (value == null || value.isEmpty) {
      _lastBuiltSoEntryByScope.remove(_scopeKey);
    } else {
      _lastBuiltSoEntryByScope[_scopeKey] = value;
    }
  }

  static void recordPrefetchedKnowledge(String sessionKey, String entryName) {
    if (entryName.isEmpty) return;
    if (!_prefetchedKnowledgeBySession.containsKey(sessionKey) &&
        _prefetchedKnowledgeBySession.length >= _maxKnowledgeSessions) {
      _prefetchedKnowledgeBySession.remove(
        _prefetchedKnowledgeBySession.keys.first,
      );
    }
    _prefetchedKnowledgeBySession
        .putIfAbsent(sessionKey, () => <String>{})
        .add(entryName);
  }

  static Set<String> prefetchedKnowledge(String sessionKey) =>
      Set<String>.unmodifiable(
        _prefetchedKnowledgeBySession[sessionKey] ?? const <String>{},
      );

  static void resetForTest() {
    _prefetchedKnowledgeBySession.clear();
    _lastBuiltSoPathByScope.clear();
    _lastBuiltSoApkPathByScope.clear();
    _lastBuiltSoEntryByScope.clear();
  }
}
