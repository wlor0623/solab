import 'package:solab/core/database/app_database.dart';
import 'package:solab/icons/lucide_adapter.dart';
import 'package:solab/theme/app_font_weights.dart';
import 'package:solab/theme/app_semantic_colors.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/services/chat/chat_service.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../services/apk_rule_service.dart';

/// SoLab APK 规则库工作台二级页（Tab 版）。
///
/// 结构：概览（统计 + 订阅 + 厂商开关）+ 每类规则一个滑动 Tab。
/// 规则列表默认收起——只有切到对应分类 Tab 才展示该类规则；
/// 整行可点切换启用（触感 + 按压反馈），长按删除。
class ApkRulePage extends StatefulWidget {
  const ApkRulePage({super.key});

  @override
  State<ApkRulePage> createState() => _ApkRulePageState();
}

class _ApkRulePageState extends State<ApkRulePage> {
  ApkRuleService? _service;
  bool _seeding = true;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final repository = context.read<ChatService>().chatRepositoryOrNull;
    if (repository == null) {
      _seeding = false;
      return;
    }
    final service = ApkRuleService(repository);
    _service = service;
    service.removeLegacyDefaultSubscription();
    service.ensureSeedIfNeeded().whenComplete(() {
      if (mounted) setState(() => _seeding = false);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _addRule() async {
    final service = _service;
    if (service == null) return;
    final form = await showModalBottomSheet<_RuleFormResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AddRuleSheet(),
    );
    if (form == null || !mounted) return;
    try {
      await service.addRule(
        category: form.category,
        name: form.name,
        pattern: form.pattern,
        risk: form.risk,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('规则已新增并同步到规则库')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('新增失败：$error')));
    }
  }

  Future<void> _importJson() async {
    final service = _service;
    if (service == null) return;
    final controller = TextEditingController();
    final pasted = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入规则 JSON'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText:
                  '粘贴 ad_patterns_default.json 格式内容\n'
                  '（{"sdk_packages": ["..."], "class_keywords": [...], ...}）',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (pasted == null || pasted.trim().isEmpty || !mounted) return;
    try {
      final added = await service.importJson(pasted);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导入完成：新增 $added 条，已存在的条目自动跳过')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导入失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final service = _service;
    final categories = ApkRuleService.categoryKeys;
    return DefaultTabController(
      length: 1 + categories.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('自定义特征'),
          actions: [
            IconButton(
              icon: const Icon(Lucide.Plus),
              tooltip: '新增规则',
              onPressed: service == null ? null : _addRule,
            ),
            IconButton(
              icon: const Icon(Lucide.Upload),
              tooltip: '导入 JSON',
              onPressed: service == null ? null : _importJson,
            ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            dividerColor: cs.outlineVariant.withValues(alpha: 0.3),
            labelColor: cs.primary,
            unselectedLabelColor: cs.onSurfaceVariant,
            indicatorColor: cs.primary,
            tabs: [
              const Tab(text: '概览'),
              for (final category in categories)
                Tab(text: ApkRuleService.categoryLabels[category] ?? category),
            ],
          ),
        ),
        body: service == null
            ? Center(
                child: Text(
                  '数据库未就绪',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              )
            : _seeding
            ? const Center(child: CircularProgressIndicator())
            : StreamBuilder<List<ModifyRuleRow>>(
                stream: service.watchAllRules(),
                builder: (context, snapshot) {
                  final rules = snapshot.data ?? const <ModifyRuleRow>[];
                  return TabBarView(
                    children: [
                      _OverviewTab(service: service, rules: rules),
                      for (final category in categories)
                        _CategoryTab(
                          service: service,
                          category: category,
                          rules: rules,
                          searchController: _searchController,
                          onConfirmDelete: _confirmDelete,
                        ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  Future<void> _confirmDelete(ModifyRuleRow rule) async {
    final service = _service;
    if (service == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除规则'),
        content: Text('确定删除规则「${rule.name}」吗？删除后同步到原生规则库。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await service.deleteRule(rule.id);
  }
}

// --- 概览 Tab：统计 + 订阅 + 厂商 ---

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.service, required this.rules});

  final ApkRuleService service;
  final List<ModifyRuleRow> rules;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabledCount = rules.where((rule) => rule.enabled).length;
    final usedCategories = rules.map((rule) => rule.category).toSet().length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        // 统计
        SettingsSectionCard(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  _StatBlock(
                    label: '规则总数',
                    value: '${rules.length}',
                    color: cs.primary,
                  ),
                  _StatBlock(
                    label: '已启用',
                    value: '$enabledCount',
                    color: context.appColors.success,
                  ),
                  _StatBlock(
                    label: '覆盖分类',
                    value: '$usedCategories',
                    color: cs.tertiary,
                  ),
                ],
              ),
            ),
            settingsSectionDivider(context),
            SettingsActionRow(
              icon: Lucide.cloudDownload,
              label: '规则订阅管理',
              detailText: '添加 / 同步网络特征库，多订阅源独立管理',
              trailing: const Icon(Lucide.ChevronRight, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ApkRuleSubscriptionPage(service: service),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _VendorSection(service: service, rules: rules),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '规则修改后自动同步到原生规则库；各分类规则请切换上方 Tab 查看',
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
      ],
    );
  }
}

class _StatBlock extends StatelessWidget {
  const _StatBlock({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: AppFontWeights.semibold,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

// --- 订阅管理（独立页面） ---

/// 规则订阅独立页：多订阅源增删改查、手动同步。
class ApkRuleSubscriptionPage extends StatefulWidget {
  const ApkRuleSubscriptionPage({super.key, required this.service});

  final ApkRuleService service;

  @override
  State<ApkRuleSubscriptionPage> createState() =>
      _ApkRuleSubscriptionPageState();
}

class _ApkRuleSubscriptionPageState extends State<ApkRuleSubscriptionPage> {
  String? _syncingId;

  static String _friendlyError(Object error) {
    final text = error.toString();
    if (text.contains('subscription_url_invalid')) {
      return '订阅地址无效（需 http/https 链接）';
    }
    if (text.contains('rules_json_shape')) {
      return '订阅源格式不正确（需 ad_patterns.json 结构）';
    }
    if (text.contains('rules_json_empty')) return '订阅源为空或没有可识别的规则';
    if (text.contains('HttpException')) return '网络请求失败：$text';
    if (text.contains('TimeoutException')) return '请求超时，请稍后重试';
    return text;
  }

  Future<void> _sync(RuleSubscriptionRow row) async {
    setState(() => _syncingId = row.id);
    try {
      final added = await widget.service.refreshSubscription(row.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(added > 0 ? '订阅已同步：新增 $added 条规则' : '订阅已同步：规则库已是最新的'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('同步失败：${_friendlyError(error)}')));
    } finally {
      if (mounted) setState(() => _syncingId = null);
    }
  }

  Future<void> _add() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('添加订阅源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '名称（留空则用地址）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                labelText: '订阅地址（ad_patterns.json 格式）',
                hintText: 'https://example.com/ad_patterns.json',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (urlController.text.trim().isEmpty) return;
              Navigator.of(dialogContext).pop(true);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (ok != true) {
      nameController.dispose();
      urlController.dispose();
      return;
    }
    try {
      final row = await widget.service.addSubscription(
        name: nameController.text,
        url: urlController.text,
      );
      if (mounted) await _sync(row);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('添加失败：${_friendlyError(error)}')));
    } finally {
      nameController.dispose();
      urlController.dispose();
    }
  }

  Future<void> _delete(RuleSubscriptionRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除订阅'),
        content: Text('确定删除订阅「${row.name}」吗？\n已同步入库的规则会保留，不会随之删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.service.deleteSubscription(row.id);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('规则订阅')),
      floatingActionButton: FloatingActionButton(
        onPressed: _add,
        child: const Icon(Lucide.Plus),
      ),
      body: StreamBuilder<List<RuleSubscriptionRow>>(
        stream: widget.service.watchSubscriptions(),
        builder: (context, snapshot) {
          final subs = snapshot.data ?? const <RuleSubscriptionRow>[];
          if (subs.isEmpty) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                SettingsSectionCard(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          Icon(
                            Lucide.cloudDownload,
                            size: 36,
                            color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '暂无订阅源',
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: AppFontWeights.medium,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '从网络订阅广告特征库，同步后自动合并入库\n点击右下角「+」接入网络特征库',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.5,
                              color: cs.onSurface.withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            itemCount: subs.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) => SettingsSectionCard(
              children: [
                _SubscriptionTile(
                  row: subs[index],
                  syncing: _syncingId == subs[index].id,
                  onSync: () => _sync(subs[index]),
                  onToggle: (value) => widget.service.setSubscriptionEnabled(
                    subs[index].id,
                    enabled: value,
                  ),
                  onDelete: () => _delete(subs[index]),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SubscriptionTile extends StatelessWidget {
  const _SubscriptionTile({
    required this.row,
    required this.syncing,
    required this.onSync,
    required this.onToggle,
    required this.onDelete,
  });

  final RuleSubscriptionRow row;
  final bool syncing;
  final VoidCallback onSync;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  static String _fmt(DateTime time) {
    final local = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final syncLabel = row.lastSyncAt == null
        ? '尚未同步'
        : '上次同步 ${_fmt(row.lastSyncAt!)} · 库内 ${row.lastRuleCount} 条';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: AppFontWeights.medium,
                    color: row.enabled ? cs.onSurface : cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  row.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 2),
                Text(
                  syncLabel,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: cs.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
          if (syncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: Icon(Lucide.RefreshCw, size: 18, color: cs.primary),
              tooltip: '同步',
              onPressed: onSync,
            ),
          IconButton(
            icon: Icon(Lucide.Trash, size: 18, color: cs.error),
            tooltip: '删除订阅',
            onPressed: onDelete,
          ),
          IosSwitch(value: row.enabled, onChanged: onToggle),
        ],
      ),
    );
  }
}

// --- 厂商快速开关 ---

class _VendorSection extends StatelessWidget {
  const _VendorSection({required this.service, required this.rules});

  final ApkRuleService service;
  final List<ModifyRuleRow> rules;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SettingsSectionCard(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Row(
            children: [
              Icon(Lucide.Box, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '按厂商快速开关',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.semibold,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            '点选批量启用其 SDK 相关规则，再次点击可整体停用',
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final vendor in ApkRuleService.vendors.keys)
                _VendorChip(
                  label: ApkRuleService.vendorLabels[vendor] ?? vendor,
                  patterns: ApkRuleService.vendors[vendor]!,
                  rules: rules,
                  onTap: () => service.setVendorEnabled(
                    vendor,
                    enabled: !_allEnabled(
                      rules,
                      ApkRuleService.vendors[vendor]!,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  static bool _allEnabled(
    List<ModifyRuleRow> rules,
    List<String> vendorPatterns,
  ) {
    final matching = rules
        .where(
          (rule) => vendorPatterns.contains(ApkRuleService.patternOf(rule)),
        )
        .toList(growable: false);
    return matching.isNotEmpty && matching.every((rule) => rule.enabled);
  }
}

class _VendorChip extends StatelessWidget {
  const _VendorChip({
    required this.label,
    required this.patterns,
    required this.rules,
    required this.onTap,
  });

  final String label;
  final List<String> patterns;
  final List<ModifyRuleRow> rules;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final matching = rules
        .where((rule) => patterns.contains(ApkRuleService.patternOf(rule)))
        .toList(growable: false);
    final enabledCount = matching.where((rule) => rule.enabled).length;
    // 选中态跟「启用状态」走：全启用=选中，部分启用=半选，全停用=未选。
    final allEnabled = matching.isNotEmpty && enabledCount == matching.length;
    final someEnabled = enabledCount > 0 && !allEnabled;
    final color = allEnabled
        ? cs.primary
        : someEnabled
        ? cs.tertiary
        : cs.onSurfaceVariant;
    return IosCardPress(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(
        color: allEnabled || someEnabled ? color : cs.outlineVariant,
        width: allEnabled || someEnabled ? 1.2 : 0.8,
      ),
      baseColor: allEnabled
          ? color.withValues(alpha: 0.18)
          : someEnabled
          ? color.withValues(alpha: 0.14)
          : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            allEnabled ? Lucide.Check : Lucide.circleDot,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 6),
          Text(
            matching.isEmpty
                ? label
                : '$label $enabledCount/${matching.length}',
            style: TextStyle(
              fontSize: 12.5,
              color: color,
              fontWeight: allEnabled ? AppFontWeights.semibold : null,
            ),
          ),
        ],
      ),
    );
  }
}

// --- 分类规则 Tab ---

class _CategoryTab extends StatelessWidget {
  const _CategoryTab({
    required this.service,
    required this.category,
    required this.rules,
    required this.searchController,
    required this.onConfirmDelete,
  });

  final ApkRuleService service;
  final String category;
  final List<ModifyRuleRow> rules;
  final TextEditingController searchController;
  final void Function(ModifyRuleRow rule) onConfirmDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final categoryRules = rules
        .where((rule) => rule.category == category)
        .toList(growable: false);
    final allEnabled =
        categoryRules.isNotEmpty && categoryRules.every((rule) => rule.enabled);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
          child: Row(
            children: [
              Expanded(
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: searchController,
                  builder: (context, value, _) => TextField(
                    controller: searchController,
                    onChanged: (_) {},
                    decoration: InputDecoration(
                      hintText:
                          '搜索${ApkRuleService.categoryLabels[category] ?? category}内的规则',
                      prefixIcon: const Icon(Lucide.Search),
                      suffixIcon: value.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Lucide.CircleX),
                              onPressed: searchController.clear,
                            ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      isDense: true,
                    ),
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: categoryRules.isEmpty
                    ? null
                    : () => service.setRulesEnabled(
                        categoryRules.map((rule) => rule.id).toList(),
                        enabled: !allEnabled,
                      ),
                icon: Icon(
                  allEnabled ? Lucide.CircleX : Lucide.CheckCircle,
                  size: 16,
                  color: categoryRules.isEmpty
                      ? null
                      : (allEnabled ? cs.onSurfaceVariant : cs.primary),
                ),
                label: Text(
                  allEnabled ? '取消全选' : '全选',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: categoryRules.isEmpty ? null : cs.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Builder(
            builder: (context) {
              final query = searchController.text.trim().toLowerCase();
              final filtered = rules
                  .where(
                    (rule) =>
                        rule.category == category &&
                        (query.isEmpty ||
                            rule.name.toLowerCase().contains(query) ||
                            (ApkRuleService.patternOf(rule) ?? '')
                                .toLowerCase()
                                .contains(query)),
                  )
                  .toList(growable: false);
              if (filtered.isEmpty) {
                return Center(
                  child: Text(
                    query.isEmpty ? '该分类暂无规则' : '没有匹配「$query」的规则',
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.5),
                      fontSize: 13,
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                itemCount: filtered.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _RuleTile(
                    rule: filtered[index],
                    onToggle: () => service.setRuleEnabled(
                      filtered[index].id,
                      enabled: !filtered[index].enabled,
                    ),
                    onLongPress: () => onConfirmDelete(filtered[index]),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 规则行：整行可点切换启用（按压反馈 + 触感），长按删除。
/// 启用态：主题色对勾 + 正常文字；停用态：灰圈 + 弱化文字。
class _RuleTile extends StatelessWidget {
  const _RuleTile({
    required this.rule,
    required this.onToggle,
    required this.onLongPress,
  });

  final ModifyRuleRow rule;
  final VoidCallback onToggle;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final risk = rule.risk;
    final riskColor = switch (risk) {
      'high' => cs.error,
      'medium' => context.appColors.warning,
      _ => context.appColors.success,
    };
    return IosCardPress(
      onTap: onToggle,
      onLongPress: onLongPress,
      pressedScale: 0.98,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: rule.enabled
            ? cs.primary.withValues(alpha: 0.55)
            : cs.outlineVariant.withValues(alpha: 0.5),
      ),
      baseColor: rule.enabled
          ? cs.primary.withValues(alpha: 0.10)
          : context.appColors.surfaceCard,
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      child: Row(
        children: [
          Icon(
            rule.enabled ? Lucide.CheckCircle : Lucide.circleDot,
            size: 18,
            color: rule.enabled ? cs.primary : cs.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  rule.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: AppFontWeights.medium,
                    color: rule.enabled
                        ? cs.onSurface
                        : cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Text(
                      switch (rule.source) {
                        'seed' => '内置',
                        'import' => '导入',
                        'subscription' => '订阅',
                        _ => '自建',
                      },
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: riskColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(switch (risk) {
                        'high' => '高风险',
                        'medium' => '中风险',
                        _ => '低风险',
                      }, style: TextStyle(fontSize: 10, color: riskColor)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IosSwitch(value: rule.enabled, onChanged: (_) => onToggle()),
        ],
      ),
    );
  }
}

// --- 新增规则弹窗 ---

class _RuleFormResult {
  const _RuleFormResult({
    required this.category,
    required this.name,
    required this.pattern,
    required this.risk,
  });

  final String category;
  final String name;
  final String pattern;
  final String risk;
}

class _AddRuleSheet extends StatefulWidget {
  const _AddRuleSheet();

  @override
  State<_AddRuleSheet> createState() => _AddRuleSheetState();
}

class _AddRuleSheetState extends State<_AddRuleSheet> {
  final _nameController = TextEditingController();
  final _patternController = TextEditingController();
  String _category = 'sdk_packages';
  String _risk = 'low';

  @override
  void dispose() {
    _nameController.dispose();
    _patternController.dispose();
    super.dispose();
  }

  void _submit() {
    final pattern = _patternController.text.trim();
    if (pattern.isEmpty) return;
    Navigator.of(context).pop(
      _RuleFormResult(
        category: _category,
        name: _nameController.text.trim(),
        pattern: pattern,
        risk: _risk,
      ),
    );
  }

  InputDecoration _field(String label) => InputDecoration(
    labelText: label,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    isDense: true,
  );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 标题区（与其他弹窗统一）
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurface.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '新增规则',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: AppFontWeights.semibold,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '规则入库后自动同步到原生规则库',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 14),
                SettingsSectionCard(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          DropdownButtonFormField<String>(
                            initialValue: _category,
                            decoration: _field('分类'),
                            items: [
                              for (final category
                                  in ApkRuleService.categoryKeys)
                                DropdownMenuItem(
                                  value: category,
                                  child: Text(
                                    ApkRuleService.categoryLabels[category] ??
                                        category,
                                  ),
                                ),
                            ],
                            onChanged: (value) =>
                                setState(() => _category = value ?? _category),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _patternController,
                            decoration: _field('匹配内容（如 com.example.ad.Sdk）'),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _nameController,
                            decoration: _field('名称（留空则用匹配内容）'),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            initialValue: _risk,
                            decoration: _field('风险等级'),
                            items: const [
                              DropdownMenuItem(
                                value: 'low',
                                child: Text('低风险'),
                              ),
                              DropdownMenuItem(
                                value: 'medium',
                                child: Text('中风险'),
                              ),
                              DropdownMenuItem(
                                value: 'high',
                                child: Text('高风险'),
                              ),
                            ],
                            onChanged: (value) =>
                                setState(() => _risk = value ?? _risk),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _submit,
                    child: const Text('保存'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
