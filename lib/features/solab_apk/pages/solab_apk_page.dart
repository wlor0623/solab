import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../../core/models/memory_entry.dart';
import '../../../core/providers/memory_provider_v2.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../../settings/pages/memory_entries_page.dart';
import 'apk_rule_page.dart';
import '../services/apk_memory_distill_service.dart';
import '../services/apk_patch_memory_service.dart';
import '../services/apk_progress_service.dart';
import '../services/apk_workspace_binding_service.dart';
import '../services/apk_workspace_service.dart';

/// APK 工作台：工作目录管理 + 分析进度 + 补丁经验记忆入口。
class SolabApkPage extends StatefulWidget {
  const SolabApkPage({super.key});

  @override
  State<SolabApkPage> createState() => _SolabApkPageState();
}

class _SolabApkPageState extends State<SolabApkPage> {
  String? _workDir;
  bool _workDirReadable = true;
  bool _distilling = false;
  String _signatureBypassDefault = 'normal';

  @override
  void initState() {
    super.initState();
    _loadWorkspace();
  }

  Future<void> _loadWorkspace() async {
    final workDir = await ApkWorkspaceBindingService.workDir();
    final readable =
        workDir == null ||
        await ApkWorkspaceBindingService.dirReadable(workDir);
    final signatureBypassDefault =
        await ApkWorkspaceBindingService.signatureBypassDefaultMode();
    if (!mounted) return;
    setState(() {
      _workDir = workDir;
      _workDirReadable = readable;
      _signatureBypassDefault = signatureBypassDefault;
    });
  }

  Future<void> _pickWorkDir() async {
    // 先强制申请「所有文件访问」权限：不授权就不让选目录。
    if (!await _requestManageStorage()) return;
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null || path.isEmpty) {
      // 部分ROM的目录选择器会静默失败：不提示的话用户以为按钮坏了。
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未选择目录：请重试，或更换系统文件管理器后重试')),
        );
      }
      return;
    }
    await ApkWorkspaceBindingService.setWorkDir(path);
    await ApkWorkspaceBindingService.clearActiveApkPath();
    await ApkWorkspaceService.clearReport();
    // 选完即验证：目录不可读时当场提示，而不是等 AI 调工具时才暴露。
    final readable = await ApkWorkspaceBindingService.dirReadable(path);
    if (!mounted) return;
    setState(() {
      _workDir = path;
      _workDirReadable = readable;
    });
    if (!readable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('目录已设置，但无法读取：请在系统设置中为 SoLab 授予「所有文件访问」权限'),
        ),
      );
    }
  }

  Future<bool> _requestManageStorage() async {
    // Android 11+：「所有文件访问」特殊权限，request() 会直接拉起
    // 系统的 All files access 开关页；从设置返回后必须重新检查状态，
    // 不能沿用跳转前的结果（否则用户开完权限回来仍被拦）。
    final manage = Permission.manageExternalStorage;
    final current = await manage.status;
    // Android 10 及以下没有「所有文件访问」开关（该权限 API 30 才引入，
    // 恒返回 restricted）：走旧版「存储」运行时权限。
    if (current.isRestricted) {
      final legacy = await Permission.storage.request();
      return legacy.isGranted;
    }
    if (current.isGranted) return true;
    // request() 在部分 ROM（无 All files access 设置页）会抛 PlatformException，
    // 不能让异常静默中断流程——降级到对话框引导。
    await manage.request().onError((_, __) => manage.status);
    if (await manage.isGranted) return true;
    // 拒绝/受限：引导去系统设置手动开启「所有文件访问」。
    if (mounted) {
      final goSettings = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('需要「所有文件访问」权限'),
          content: const Text(
            'APK 分析/修改需要读取工作目录下的安装包。\n\n'
            '请在系统设置中为应用开启「所有文件访问」\n'
            '（通常位于 设置 → 应用 → SoLab → 权限，或 设置 → 隐私 → 特殊权限）。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('去设置'),
            ),
          ],
        ),
      );
      if (goSettings == true) {
        // 再次 request() 直达「所有文件访问」专属开关页；
        // openAppSettings 只到应用详情页，那里没有这个开关。
        await manage.request().onError((_, __) => manage.status);
        if (await manage.isGranted) return true;
        // 兜底：应用详情页路径。
        await openAppSettings();
        // openAppSettings 的 Future 在设置页拉起时就完成，不等用户返回；
        // 必须等应用回到前台后再判定，否则用户开完权限回来仍被拦。
        await _waitForAppReturnFromSettings();
        if (await manage.isGranted) return true;
      }
    }
    return false;
  }

  /// 等待应用从系统设置页回到前台（一次 resume 即完成，带超时兜底）。
  Future<void> _waitForAppReturnFromSettings() {
    final completer = Completer<void>();
    late final _AppResumeObserver observer;
    observer = _AppResumeObserver(() {
      WidgetsBinding.instance.removeObserver(observer);
      if (!completer.isCompleted) completer.complete();
    });
    WidgetsBinding.instance.addObserver(observer);
    return completer.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () {
        WidgetsBinding.instance.removeObserver(observer);
      },
    );
  }

  Future<void> _clearWorkDir() async {
    await ApkWorkspaceBindingService.clearWorkDir();
    await ApkWorkspaceBindingService.clearActiveApkPath();
    await ApkWorkspaceService.clearReport();
    if (mounted) setState(() => _workDir = null);
  }

  Future<void> _pickSignatureBypassDefault() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('默认去签名'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('off'),
            child: const Text('不开启'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('normal'),
            child: const Text('普通去签'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('original_apk'),
            child: const Text('原包去签'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('dpatch'),
            child: const Text('DPatch 去签'),
          ),
        ],
      ),
    );
    if (selected == null) return;
    await ApkWorkspaceBindingService.setSignatureBypassDefaultMode(selected);
    if (mounted) setState(() => _signatureBypassDefault = selected);
  }

  String get _signatureBypassDefaultLabel => switch (_signatureBypassDefault) {
    'normal' => '普通去签',
    'original_apk' => '原包去签',
    'dpatch' => 'DPatch 去签',
    _ => '不开启',
  };

  void _openPage(Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Future<void> _distill() async {
    final memoryProvider = context.read<MemoryProviderV2>();
    final repo = memoryProvider.repository;
    final settings = context.read<SettingsProvider>();
    final groups = await ApkMemoryDistillService.groupsForDistill(repo);
    if (!mounted) return;
    if (groups.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无需整理：当前每个 APP 已只有一条经验。')));
      return;
    }

    // 构造记忆模型回调；模型未配置时降级为确定性合并。
    Future<String> Function(String)? llmCall;
    final provKey = settings.memoryModelProvider;
    final mdlId = settings.memoryModelId;
    if (provKey != null && mdlId != null) {
      final cfg = settings.getProviderConfig(provKey);
      final budget = settings.memoryModelThinkingEnabled
          ? settings.thinkingBudget
          : 0;
      llmCall = (prompt) => ChatApiService.generateText(
        config: cfg,
        modelId: mdlId,
        prompt: prompt,
        thinkingBudget: budget,
      );
    }

    setState(() => _distilling = true);
    // 先算出每组的合并草案（LLM 失败降级确定性合并），再交给用户预览确认。
    final drafts = <({List<MemoryEntry> group, ApkPatchMemory merged})>[];
    for (final group in groups) {
      try {
        final merged = llmCall != null
            ? await ApkMemoryDistillService.distillGroupWithLlm(
                group: group,
                llmCall: llmCall,
              )
            : ApkMemoryDistillService.distillGroupDeterministic(group);
        drafts.add((group: group, merged: merged));
      } catch (_) {
        try {
          drafts.add((
            group: group,
            merged: ApkMemoryDistillService.distillGroupDeterministic(group),
          ));
        } catch (_) {}
      }
    }
    if (!mounted) return;
    setState(() => _distilling = false);
    if (drafts.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('蒸馏失败：没有产出任何合并草案。')));
      return;
    }

    // 预览确认：逐组展示「N 条 → 合并后」，勾选后写回（归档旧条目）。
    final confirmed = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) =>
          _DistillPreviewSheet(drafts: drafts, usedLlm: llmCall != null),
    );
    if (confirmed == null || confirmed.isEmpty) return;

    var distilled = 0;
    for (final i in confirmed) {
      try {
        await ApkMemoryDistillService.applyDistill(
          repo: repo,
          group: drafts[i].group,
          merged: drafts[i].merged,
        );
        distilled++;
      } catch (_) {}
    }
    await memoryProvider.reloadCurrentScope();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已整理 $distilled 个 APP，每个 APP 只保留一条完整经验')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('APK 工作台')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '选择一个目录。分析时只使用其中一个 APK，报告会在更换目录后自动失效。',
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: .65),
            ),
          ),
          const SizedBox(height: 12),
          SettingsSectionCard(
            children: [
              SettingsActionRow(
                icon: Lucide.Folder,
                label: '选择工作目录',
                detailText: _workDir == null
                    ? '尚未选择'
                    : (_workDirReadable
                          ? _workDir!
                          : '$_workDir（无法读取：请授予「所有文件访问」权限）'),
                trailing: _workDir == null
                    ? const Icon(Lucide.ChevronRight, size: 18)
                    : PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'change') _pickWorkDir();
                          if (value == 'clear') _clearWorkDir();
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'change', child: Text('更换目录')),
                          PopupMenuItem(value: 'clear', child: Text('清除目录')),
                        ],
                      ),
                onTap: _pickWorkDir,
              ),
              SettingsActionRow(
                icon: Lucide.Shield,
                label: '默认去签名',
                detailText: _signatureBypassDefaultLabel,
                trailing: const Icon(Lucide.ChevronRight, size: 18),
                onTap: _pickSignatureBypassDefault,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ProgressCard(),
          const SizedBox(height: 12),
          SettingsSectionCard(
            children: [
              SettingsActionRow(
                icon: Lucide.ScanSearch,
                label: '自定义特征',
                detailText: '广告特征规则库：分类浏览 / 订阅同步 / 厂商开关',
                trailing: const Icon(Lucide.ChevronRight, size: 18),
                onTap: () => _openPage(const ApkRulePage()),
              ),
              SettingsActionRow(
                icon: Lucide.Bookmark,
                label: '记忆（经验 / 笔记）',
                detailText: 'APK 经验与修改笔记已并入记忆系统，统一管理',
                trailing: const Icon(Lucide.ChevronRight, size: 18),
                onTap: () => _openPage(const MemoryEntriesPage()),
              ),
              SettingsActionRow(
                icon: Lucide.Sparkles,
                label: '整理蒸馏经验',
                detailText: _distilling ? '正在生成合并草案…' : '同一 APP 的零散经验合并为唯一一条',
                trailing: _distilling
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Lucide.ChevronRight, size: 18),
                onTap: _distilling ? null : _distill,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 蒸馏预览面板：逐组展示「N 条零散经验 → 合并后」，勾选确认后写回。
/// 返回选中的 draft 下标列表；取消返回 null。
class _DistillPreviewSheet extends StatefulWidget {
  const _DistillPreviewSheet({required this.drafts, required this.usedLlm});

  final List<({List<MemoryEntry> group, ApkPatchMemory merged})> drafts;
  final bool usedLlm;

  @override
  State<_DistillPreviewSheet> createState() => _DistillPreviewSheetState();
}

class _DistillPreviewSheetState extends State<_DistillPreviewSheet> {
  late final Set<int> _checked = {
    for (var i = 0; i < widget.drafts.length; i++) i,
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.72,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '蒸馏预览（${widget.drafts.length} 组）',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: AppFontWeights.semibold,
                            color: cs.onSurface,
                          ),
                        ),
                      ),
                      IosIconButton(
                        icon: Lucide.X,
                        color: cs.onSurface,
                        size: 20,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.usedLlm
                        ? '由记忆模型合并；确认后只保留一条完整记忆'
                        : '未配置记忆模型，使用确定性完整合并',
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: .6),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: widget.drafts.length,
                itemBuilder: (ctx, i) {
                  final d = widget.drafts[i];
                  final checked = _checked.contains(i);
                  return CheckboxListTile(
                    value: checked,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: Text(
                      d.merged.title.isEmpty ? '（无标题）' : d.merged.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: AppFontWeights.semibold,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${d.group.length} 条 → ${d.merged.solution}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, height: 1.3),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${d.merged.outcome} · '
                          '${((d.merged.fingerprint['vendors'] as List?) ?? const []).join('+')}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurface.withValues(alpha: .5),
                          ),
                        ),
                      ],
                    ),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _checked.add(i);
                      } else {
                        _checked.remove(i);
                      }
                    }),
                  );
                },
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _checked.isEmpty
                          ? null
                          : () => Navigator.of(context).pop(_checked.toList()),
                      child: Text(
                        '合并 ${_checked.length}/${widget.drafts.length} 组',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 最近一次原生分析进度（EventChannel 'solab/progress'）。
class _ProgressCard extends StatefulWidget {
  @override
  State<_ProgressCard> createState() => _ProgressCardState();
}

class _ProgressCardState extends State<_ProgressCard> {
  @override
  void initState() {
    super.initState();
    ApkProgressService.instance.addListener(_onProgress);
  }

  @override
  void dispose() {
    ApkProgressService.instance.removeListener(_onProgress);
    super.dispose();
  }

  void _onProgress() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final progress = ApkProgressService.instance;
    if (!progress.hasProgress) return const SizedBox.shrink();
    return SettingsSectionCard(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  value: progress.percent / 100,
                  color: cs.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '分析中 ${progress.percent}% · ${progress.stage}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 一次性生命周期观察者：应用回到前台（resume）时回调一次。
class _AppResumeObserver extends WidgetsBindingObserver {
  _AppResumeObserver(this.onResumed);

  final VoidCallback onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResumed();
  }
}
