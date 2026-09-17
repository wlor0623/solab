import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/memory/memory_repository.dart';
import 'apk_patch_memory_service.dart';
import 'apk_patch_note_service.dart';

/// 一次性把旧版 APK 经验/笔记（两个 SharedPreferences blob）迁入记忆系统 V1。
///
/// migrationId 幂等：迁移中断后重启会跳过已入库条目；成功后删除旧 key。
/// 迁移只在启动早期调用一次，且 createMany 对空 drafts 无副作用。
class ApkMemoryMigrationService {
  const ApkMemoryMigrationService._();

  static Future<({int migrated, bool cleaned})> migrateIfNeeded(
    MemoryRepository repo,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final memoryRaw = prefs.getString(ApkPatchMemoryService.legacyKey);
    final noteRaw = prefs.getString(ApkPatchNoteService.legacyKey);
    if (memoryRaw == null && noteRaw == null) {
      return (migrated: 0, cleaned: false);
    }

    final drafts = <MemoryCreateDraft>[
      if (memoryRaw != null)
        ...ApkPatchMemoryService.draftsFromLegacyJson(memoryRaw),
      if (noteRaw != null) ...ApkPatchNoteService.draftsFromLegacyJson(noteRaw),
    ];

    var created = 0;
    if (drafts.isNotEmpty) {
      final result = await repo.createMany(drafts);
      created = result.created;
    }

    var cleaned = false;
    if (memoryRaw != null) {
      await ApkPatchMemoryService.removeLegacyKey();
      cleaned = true;
    }
    if (noteRaw != null) {
      await ApkPatchNoteService.removeLegacyKey();
      cleaned = true;
    }
    return (migrated: created, cleaned: cleaned);
  }
}
