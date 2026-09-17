import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/models/memory_entry.dart';
import '../../../core/services/memory/memory_repository.dart';

/// 修改笔记：记录每个 APK 改过的方法/条目，跨会话避免重复改或漏改。
///
/// 存储已并入记忆系统 V1（MemoryType.apkNote）：content 存摘要，
/// 结构化字段（apkId/locator/status/timestamp/details）存 extraJson。
class ApkPatchNoteService {
  ApkPatchNoteService._();

  static const _assistantId = 'builtin-apk-mod';
  static const _legacyKey = 'apk_mod_patch_notes_v1';

  static Map<String, dynamic> _fromEntry(MemoryEntry e) {
    final extra = e.extraJson ?? const <String, dynamic>{};
    return {
      'locator': (extra['locator'] ?? '').toString(),
      'apkId': (extra['apkId'] ?? '').toString(),
      'status': (extra['status'] ?? 'patched').toString(),
      'summary': e.content,
      if (extra['details'] is Map)
        'details': Map<String, dynamic>.from(extra['details'] as Map),
      'timestamp':
          (extra['timestamp'] as num?)?.toInt() ??
          e.createdAt.millisecondsSinceEpoch,
    };
  }

  static List<Map<String, dynamic>> _notesFromEntry(MemoryEntry e) {
    final extra = e.extraJson ?? const <String, dynamic>{};
    final apkId = (extra['apkId'] ?? '').toString();
    final packed = extra['notes'];
    if (packed is! List) return [_fromEntry(e)];
    return [
      for (final raw in packed)
        if (raw is Map)
          {
            'locator': (raw['locator'] ?? '').toString(),
            'apkId': apkId,
            'status': (raw['status'] ?? 'patched').toString(),
            'summary': (raw['summary'] ?? '').toString(),
            if (raw['details'] is Map)
              'details': Map<String, dynamic>.from(raw['details'] as Map),
            'timestamp': (raw['timestamp'] as num?)?.toInt() ?? 0,
          },
    ];
  }

  static MemoryEntry _packedEntry(
    String apkId,
    List<Map<String, dynamic>> notes, {
    String? id,
    DateTime? createdAt,
  }) {
    notes.sort(
      (a, b) => ((b['timestamp'] as num?)?.toInt() ?? 0).compareTo(
        (a['timestamp'] as num?)?.toInt() ?? 0,
      ),
    );
    final now = DateTime.now().toUtc();
    return MemoryEntry(
      id: id ?? MemoryEntry.newId(),
      scope: MemoryScope.assistant,
      assistantId: _assistantId,
      type: MemoryType.apkNote,
      content: notes.length == 1
          ? (notes.first['summary'] ?? '').toString()
          : '${notes.length} 个修改点: ${(notes.first['summary'] ?? '').toString()}',
      source: MemorySource.tool,
      extraJson: {
        'apkId': apkId,
        'notes': [
          for (final note in notes)
            {
              'locator': note['locator'],
              'status': note['status'],
              'summary': note['summary'],
              if (note['details'] is Map) 'details': note['details'],
              'timestamp': note['timestamp'],
            },
        ],
        'timestamp': notes.isEmpty
            ? now.millisecondsSinceEpoch
            : notes.first['timestamp'],
      },
      createdAt: createdAt ?? now,
      updatedAt: now,
    );
  }

  /// 读取指定 APK 的笔记（时间倒序）。
  static Future<List<Map<String, dynamic>>> read(
    MemoryRepository repo,
    String apkId,
  ) async {
    final all = await repo.readAll();
    final notes = <Map<String, dynamic>>[
      for (final e in all)
        if (e.type == MemoryType.apkNote &&
            ((e.extraJson ?? const <String, dynamic>{})['apkId'] ?? '')
                    .toString() ==
                apkId)
          ..._notesFromEntry(e),
    ];
    notes.sort(
      (a, b) => ((b['timestamp'] as num?)?.toInt() ?? 0).compareTo(
        (a['timestamp'] as num?)?.toInt() ?? 0,
      ),
    );
    return notes;
  }

  /// 写入/覆盖指定 APK + locator 的笔记。
  static Future<void> write(
    MemoryRepository repo,
    String apkId,
    String locator, {
    String status = 'patched',
    String summary = '',
    Map<String, dynamic>? details,
  }) {
    return repo.runExclusive(() async {
      final all = await repo.readAll();
      final noteEntries = all
          .where((e) => e.type == MemoryType.apkNote)
          .toList();
      final nonNote = all.where((e) => e.type != MemoryType.apkNote).toList();

      final sameAppEntries = noteEntries.where((e) {
        final extra = e.extraJson ?? const <String, dynamic>{};
        return (extra['apkId'] ?? '').toString() == apkId;
      }).toList();
      noteEntries.removeWhere((e) => sameAppEntries.contains(e));
      final notes = <Map<String, dynamic>>[
        for (final entry in sameAppEntries) ..._notesFromEntry(entry),
      ]..removeWhere((note) => note['locator'] == locator);

      final now = DateTime.now();
      notes.add({
        'apkId': apkId,
        'locator': locator,
        'status': status,
        'summary': summary,
        'timestamp': now.millisecondsSinceEpoch,
        if (details != null) 'details': Map<String, dynamic>.from(details),
      });
      final entry = _packedEntry(
        apkId,
        notes,
        id: sameAppEntries.isEmpty ? null : sameAppEntries.first.id,
        createdAt: sameAppEntries.isEmpty
            ? null
            : sameAppEntries.first.createdAt,
      );
      await repo.writeAll([...nonNote, entry, ...noteEntries]);
    });
  }

  static Future<String> readForAi(MemoryRepository repo, String apkId) async {
    final notes = await read(repo, apkId);
    final hasOperationOnly = notes.any(
      (note) => (note['locator'] ?? '').toString().startsWith('auto:'),
    );
    return jsonEncode({
      'apkId': apkId,
      'modified': notes,
      if (hasOperationOnly) 'needsRelocation': true,
      'hint': notes.isEmpty
          ? '暂无已修改标记。修改成功后可用 apk_note_write 记录，跨会话避免重复改。'
          : hasOperationOnly
          ? '含 auto: 操作级旧笔记：它没有真实方法定位符，不能直接复用或验证。先重新定位并用工具结果补齐真实 locator；其余带 details 的笔记可用于恢复输入、产物、结果和下一步。'
          : '以下定位已改过。先核对 details 中的输入、产物和结果，再避免重复修改或漏改。',
    });
  }

  /// 读取全部 APK 的笔记（apkId → 笔记列表，时间倒序），供管理页展示。
  static Future<Map<String, List<Map<String, dynamic>>>> readAll(
    MemoryRepository repo,
  ) async {
    final all = await repo.readAll();
    final result = <String, List<Map<String, dynamic>>>{};
    for (final e in all) {
      if (e.type != MemoryType.apkNote) continue;
      for (final note in _notesFromEntry(e)) {
        final apkId = (note['apkId'] ?? '').toString();
        result.putIfAbsent(apkId, () => <Map<String, dynamic>>[]).add(note);
      }
    }
    for (final list in result.values) {
      list.sort(
        (a, b) => ((b['timestamp'] as num?)?.toInt() ?? 0).compareTo(
          (a['timestamp'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    return result;
  }

  /// 删除指定 APK 的某条笔记（管理页用）。
  static Future<void> remove(
    MemoryRepository repo,
    String apkId,
    String locator,
  ) {
    return repo.runExclusive(() async {
      final all = await repo.readAll();
      final kept = <MemoryEntry>[];
      for (final e in all) {
        if (e.type != MemoryType.apkNote ||
            (e.extraJson?['apkId'] ?? '').toString() != apkId) {
          kept.add(e);
          continue;
        }
        final notes = _notesFromEntry(e)
          ..removeWhere((note) => note['locator'] == locator);
        if (notes.isNotEmpty) {
          kept.add(
            _packedEntry(apkId, notes, id: e.id, createdAt: e.createdAt),
          );
        }
      }
      await repo.writeAll(kept);
    });
  }

  /// 旧版 SharedPreferences 迁移草案（migrationId 幂等防重复）。
  static List<MemoryCreateDraft> draftsFromLegacyJson(String raw) {
    try {
      final all = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final drafts = <MemoryCreateDraft>[];
      for (final entry in all.entries) {
        final apkId = entry.key.toString();
        if (entry.value is! List) continue;
        for (final n in entry.value as List) {
          if (n is! Map) continue;
          drafts.add(
            MemoryCreateDraft(
              scope: MemoryScope.assistant,
              assistantId: _assistantId,
              type: MemoryType.apkNote,
              content: (n['summary'] ?? '').toString(),
              source: MemorySource.tool,
              migrationId: 'apk_note_${apkId}_${n['locator']}',
              extraJson: {
                'apkId': apkId,
                'locator': (n['locator'] ?? '').toString(),
                'status': (n['status'] ?? 'patched').toString(),
                'timestamp': (n['timestamp'] as num?)?.toInt() ?? 0,
              },
            ),
          );
        }
      }
      return drafts;
    } catch (_) {
      return const <MemoryCreateDraft>[];
    }
  }

  static const String legacyKey = _legacyKey;

  static Future<void> removeLegacyKey() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_legacyKey)) {
      await prefs.remove(_legacyKey);
    }
  }
}
