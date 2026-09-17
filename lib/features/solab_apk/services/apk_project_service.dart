import 'package:solab/core/database/app_database.dart';
import 'package:solab/core/database/chat_database_repository.dart';
import 'package:uuid/uuid.dart';

/// SoLab APK 项目服务：把一次分析结果落为可复用的项目记录。
///
/// 项目以 APK SHA-256 为去重依据：同一安装包再次分析时复用已有记录
/// （关联会话、最近打开时间），而不是重复插入。
class ApkProjectService {
  const ApkProjectService(this._repository);

  final ChatDatabaseRepository _repository;

  /// 保存（或复用）一次分析产生的项目记录，返回最终的项目行。
  Future<ApkProjectRow> saveProjectFromReport(
    Map<String, dynamic> report, {
    required String sourcePath,
    String? conversationId,
  }) async {
    final sha256 = (report['sha256'] ?? '').toString();
    final existing = sha256.isEmpty
        ? null
        : await _repository.findApkProjectBySha256(sha256);
    if (existing != null) {
      await _repository.touchApkProject(
        existing.id,
        conversationId: conversationId ?? existing.conversationId,
      );
      return (await _repository.getApkProject(existing.id)) ?? existing;
    }

    final now = DateTime.now();
    final previous = await _repository.findLatestApkProjectBySourcePath(
      sourcePath,
    );
    final project = ApkProjectRow(
      id: previous?.id ?? const Uuid().v4(),
      sourcePath: sourcePath,
      fileName: (report['fileName'] ?? '').toString(),
      packageName: _stringOrNull(report['packageName']),
      versionName: _stringOrNull(report['versionName']),
      versionCode: report['versionCode'] is num
          ? (report['versionCode'] as num).toInt()
          : null,
      apkSha256: sha256,
      certificateSha256: _stringOrNull(report['certificateSha256']),
      analysisVersion: report['analysisVersion'] is num
          ? (report['analysisVersion'] as num).toInt()
          : 0,
      ruleSetVersion: 1,
      conversationId: conversationId,
      createdAt: previous?.createdAt ?? now,
      lastOpenedAt: now,
    );
    await _repository.putApkProject(project);
    return project;
  }

  Future<ApkProjectRow?> getProject(String id) => _repository.getApkProject(id);

  Future<ApkProjectRow?> findBySha256(String sha256) =>
      _repository.findApkProjectBySha256(sha256);

  Future<ApkProjectRow?> findByConversation(String conversationId) =>
      _repository.findApkProjectByConversation(conversationId);

  Future<List<ApkProjectRow>> listProjects({int limit = 50}) =>
      _repository.getAllApkProjects(limit: limit);

  /// 给项目关联一个助手会话（工作台 → 助手跳转后回填）。
  Future<void> linkConversation(String projectId, String conversationId) =>
      _repository.touchApkProject(projectId, conversationId: conversationId);

  /// 供助手工具读取的紧凑项目摘要（不包含整份报告）。
  Map<String, dynamic> projectInfoForAi(ApkProjectRow project) {
    return {
      'projectId': project.id,
      'fileName': project.fileName,
      'packageName': project.packageName ?? '',
      'versionName': project.versionName ?? '',
      'versionCode': project.versionCode,
      'apkSha256': project.apkSha256,
      'certificateSha256': project.certificateSha256 ?? '',
      'analysisVersion': project.analysisVersion,
      'ruleSetVersion': project.ruleSetVersion,
      'conversationId': project.conversationId,
      'lastOpenedAt': project.lastOpenedAt.toIso8601String(),
    };
  }

  static String? _stringOrNull(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }
}
