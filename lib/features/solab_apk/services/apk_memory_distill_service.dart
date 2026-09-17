import 'dart:convert';

import '../../../core/models/memory_entry.dart';
import '../../../core/services/memory/memory_repository.dart';
import 'apk_patch_memory_service.dart';

/// APK 经验蒸馏：把同一指纹下的多条零散经验合并为一条精简条目。
///
/// 复用记忆模型（设置→记忆的模型选择）；LLM 不可用时降级为确定性合并
///（保留最新 verified 条目 + 其余归档）。结果由调用方预览确认后写回。
class ApkMemoryDistillService {
  const ApkMemoryDistillService._();

  /// 一个待蒸馏分组：同类的多条经验。
  ///
  /// 分组标准与 [ApkPatchMemoryService.match] 一致：matchScore >=
  /// [threshold] 即同类（连通分量聚类），而非指纹 key 精确相等——
  /// 同类型 APK 版本迭代后厂商列表微变（指纹 key 不同但相似度高），
  /// 此前永远聚不到一组，是"蒸馏判断同样两份不到位"的根因。
  /// 退化指纹不参与（无同类判定信号）。
  static Future<List<List<MemoryEntry>>> groupsForDistill(
    MemoryRepository repo, {
    double threshold = 0.6,
  }) async {
    final all = await repo.readAll();
    final patch = all.where((e) => e.type == MemoryType.apkPatch).toList();
    final candidates = <MemoryEntry>[];
    final fingerprints = <Map<String, dynamic>>[];
    for (final e in patch) {
      final fp = ApkPatchMemoryService.entryFingerprint(e);
      if (ApkPatchMemoryService.fingerprintKey(fp).isEmpty) continue;
      if (ApkPatchMemoryService.appKey(fp).isEmpty &&
          ApkPatchMemoryService.isDegenerateFingerprint(fp)) {
        continue;
      }
      candidates.add(e);
      fingerprints.add(fp);
    }
    // 并查集聚类：两两相似度 >= 阈值即同组
    final parent = List<int>.generate(candidates.length, (i) => i);
    int find(int x) => parent[x] == x ? x : (parent[x] = find(parent[x]));
    void union(int a, int b) {
      final ra = find(a);
      final rb = find(b);
      if (ra != rb) parent[ra] = rb;
    }

    for (var i = 0; i < candidates.length; i++) {
      for (var j = i + 1; j < candidates.length; j++) {
        // appId 硬边界（用户要求）：一个软件一条经验，跨 APP 永不合并。
        // 旧逻辑 matchScore>=阈值 即 union——所有 Flutter arm64 包因
        // flutterProfile 维度互相过 0.6，全部被并成一坨。
        final sameApp =
            ApkPatchMemoryService.appKey(fingerprints[i]).isNotEmpty &&
            ApkPatchMemoryService.appKey(fingerprints[i]) ==
                ApkPatchMemoryService.appKey(fingerprints[j]);
        if (sameApp) {
          union(i, j);
        }
      }
    }
    final byRoot = <int, List<MemoryEntry>>{};
    for (var i = 0; i < candidates.length; i++) {
      byRoot.putIfAbsent(find(i), () => <MemoryEntry>[]).add(candidates[i]);
    }
    // 组内按时间升序（oldest first），蒸馏 prompt 的"第一条"最稳定
    final groups = <List<MemoryEntry>>[
      for (final g in byRoot.values)
        if (g.length > 1)
          g..sort(
            (a, b) => ((a.extraJson ?? const {})['timestamp'] as num? ?? 0)
                .compareTo((b.extraJson ?? const {})['timestamp'] as num? ?? 0),
          ),
    ];
    return groups;
  }

  /// 用 LLM 把一组经验合并为一条 [ApkPatchMemory]（未写回）。
  /// [llmCall] 失败抛错，由调用方降级。
  static Future<ApkPatchMemory> distillGroupWithLlm({
    required List<MemoryEntry> group,
    required Future<String> Function(String prompt) llmCall,
  }) async {
    final prompt = _buildPrompt(group);
    final raw = await llmCall(prompt);
    final parsed = _parseLlmResult(raw);
    final fallback = distillGroupDeterministic(group);
    final parsedSolution = (parsed['solution'] ?? '').toString().trim();
    final parsedPitfall = (parsed['pitfall'] ?? '').toString().trim();
    final parsedTargets = parsed['targets'] is List
        ? (parsed['targets'] as List)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList()
        : const <String>[];
    final parsedFingerprint = parsed['fingerprint'] is Map
        ? Map<String, dynamic>.from(parsed['fingerprint'] as Map)
        : const <String, dynamic>{};
    final keepParsedFingerprint =
        ApkPatchMemoryService.appKey(fallback.fingerprint).isEmpty ||
        ApkPatchMemoryService.appKey(parsedFingerprint) ==
            ApkPatchMemoryService.appKey(fallback.fingerprint);
    return fallback.copyWith(
      fingerprint: keepParsedFingerprint && parsedFingerprint.isNotEmpty
          ? parsedFingerprint
          : fallback.fingerprint,
      title: (parsed['title'] ?? fallback.title).toString(),
      solution: parsedSolution.isEmpty ? fallback.solution : parsedSolution,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      operation: (parsed['operation'] ?? fallback.operation).toString(),
      pitfall: ApkPatchMemoryService.mergePitfall(
        fallback.pitfall,
        parsedPitfall,
      ),
      targets: {...fallback.targets, ...parsedTargets}.toList(),
    );
  }

  /// 确定性降级合并：所有方案、易错点和定位符都并入同一条。
  static ApkPatchMemory distillGroupDeterministic(List<MemoryEntry> group) {
    final memories = group.map(ApkPatchMemoryService.entryToMemory).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final base = memories.last;
    final verifiedSuccess =
        group
            .map(ApkPatchMemoryService.entryToMemory)
            .where((m) => m.outcome == 'verified_success')
            .toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final seed = verifiedSuccess.isNotEmpty ? verifiedSuccess.first : base;
    var solution = '';
    var pitfall = '';
    final targets = <String>{};
    for (final memory in memories) {
      solution = solution.isEmpty
          ? memory.solution
          : ApkPatchMemoryService.mergeSolution(solution, memory.solution);
      pitfall = ApkPatchMemoryService.mergePitfall(pitfall, memory.pitfall);
      targets.addAll(memory.targets);
    }
    return seed.copyWith(
      id: memories.first.id,
      fingerprint: base.fingerprint,
      solution: solution,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      outcome: _bestOutcome(group),
      pitfall: pitfall,
      targets: targets.toList(),
    );
  }

  /// 写回：保留一个稳定 id，删除已完整合并的重复条目。
  static Future<void> applyDistill({
    required MemoryRepository repo,
    required List<MemoryEntry> group,
    required ApkPatchMemory merged,
  }) {
    return repo.runExclusive(() async {
      final all = await repo.readAll();
      final mergedIds = group.map((e) => e.id).toSet();
      final entry = ApkPatchMemoryService.memoryToEntry(merged);
      final kept = <MemoryEntry>[];
      for (final e in all) {
        if (mergedIds.contains(e.id)) continue;
        kept.add(e);
      }
      kept.add(entry);
      await repo.writeAll(kept);
    });
  }

  static String _bestOutcome(List<MemoryEntry> group) {
    final outcomes = group
        .map((e) => ((e.extraJson ?? const {})['outcome'] ?? '').toString())
        .toSet();
    if (outcomes.contains('verified_success')) return 'verified_success';
    if (outcomes.contains('verified_failure')) return 'verified_failure';
    return 'unverified';
  }

  static String _buildPrompt(List<MemoryEntry> group) {
    final lines = <String>[];
    for (final e in group) {
      final extra = e.extraJson ?? const <String, dynamic>{};
      lines.add(
        '- [${(extra['outcome'] ?? 'unverified')}] '
        '${(extra['title'] ?? '')}: ${e.content}',
      );
    }
    return '''
你是 APK 修改经验整理助手。下面是同一个 APP 或同类 APK 的多条修改经验。必须合并为一条完整、精简、可继续更新的长期记忆。

要求：
1. 只输出 JSON（不要任何解释或 Markdown 代码块）。
2. JSON 字段：title、solution、operation、fingerprint、pitfall、targets。fingerprint 必须原样保留；targets 是去重后的字符串数组。
3. 不得丢失任何已验证改点、真实字节依据、易错点和定位符。相同内容去重；verified_success 作为结论，verified_failure 只并入 pitfall。
4. solution 可以分行，但每一行必须是可执行结论，不写排查流水。

指纹参考（原样保留）：${jsonEncode(ApkPatchMemoryService.entryFingerprint(group.first))}

经验列表：
${lines.join('\n')}
''';
  }

  static Map<String, dynamic> _parseLlmResult(String raw) {
    try {
      final cleaned = raw
          .trim()
          .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
          .replaceFirst(RegExp(r'\s*```$'), '');
      final decoded = jsonDecode(cleaned);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }
}
