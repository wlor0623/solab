import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/models/agent_skill.dart';
import '../../../core/providers/agent_skill_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../../theme/app_font_weights.dart';
import '../../solab_apk/services/solab_apk_skills.dart';

class SkillPage extends StatefulWidget {
  const SkillPage({super.key});

  @override
  State<SkillPage> createState() => _SkillPageState();
}

class _SkillPageState extends State<SkillPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AgentSkillProvider>().initialize();
    });
  }

  Future<void> _edit({AgentSkill? skill}) async {
    final result = await showModalBottomSheet<AgentSkill>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SkillEditSheet(skill: skill),
    );
    if (result != null && mounted) {
      await context.read<AgentSkillProvider>().save(result);
    }
  }

  Future<void> _showBuiltinSkill(String id) async {
    final payload = jsonDecode(SolabApkSkills.read(id)) as Map<String, dynamic>;
    final steps =
        (payload['workflow'] ?? payload['steps']) as List? ?? const [];
    final guardrails = payload['guardrails'] as List? ?? const [];
    final applicability = payload['applicability']?.toString().trim();
    final requiredSections = payload['requiredReportSections'] as List?;
    final output = payload['output'] as List?;
    final activation = payload['activation'] is Map
        ? Map<String, dynamic>.from(payload['activation'] as Map)
        : null;
    final remaining = Map<String, dynamic>.from(payload)
      ..remove('id')
      ..remove('name')
      ..remove('activation')
      ..remove('applicability')
      ..remove('workflow')
      ..remove('steps')
      ..remove('guardrails')
      ..remove('requiredReportSections')
      ..remove('output');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .72,
            child: ListView(
              children: [
                Text(
                  (payload['name'] ?? id).toString(),
                  style: TextStyle(fontWeight: AppFontWeights.semibold),
                ),
                if (activation != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        Lucide.CheckCircle,
                        size: 17,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 7),
                      const Expanded(child: Text('已接入任务路由，匹配任务时自动生效')),
                    ],
                  ),
                  if ((activation['trigger'] ?? '').toString().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text('触发范围: ${activation['trigger']}'),
                  ],
                  if (activation['rules'] is List &&
                      (activation['rules'] as List).isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text('自动生效规则'),
                    const SizedBox(height: 6),
                    for (final rule in activation['rules'] as List)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 7),
                        child: Text('• $rule'),
                      ),
                  ],
                ],
                const SizedBox(height: 14),
                if (applicability != null && applicability.isNotEmpty) ...[
                  const Text('适用范围'),
                  const SizedBox(height: 6),
                  Text(applicability),
                  const SizedBox(height: 14),
                ],
                if (requiredSections != null &&
                    requiredSections.isNotEmpty) ...[
                  const Text('需要读取的报告'),
                  const SizedBox(height: 6),
                  Text(requiredSections.join('、')),
                  const SizedBox(height: 14),
                ],
                for (var i = 0; i < steps.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: Text('${i + 1}. ${steps[i]}'),
                  ),
                if (guardrails.isNotEmpty) ...[
                  const Divider(height: 28),
                  const Text('边界'),
                  const SizedBox(height: 8),
                  for (final item in guardrails)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 9),
                      child: Text('• $item'),
                    ),
                ],
                if (output != null && output.isNotEmpty) ...[
                  const Divider(height: 28),
                  const Text('输出应包含'),
                  const SizedBox(height: 8),
                  Text(output.join('、')),
                ],
                if (remaining.isNotEmpty) ...[
                  const Divider(height: 28),
                  const Text('补充知识'),
                  const SizedBox(height: 8),
                  SelectableText(
                    const JsonEncoder.withIndent('  ').convert(remaining),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  AgentSkill? _decodePackage(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final data = decoded['data'];
      if (decoded['type'] != 'solab-skill' &&
          decoded['type'] != 'kelivo-skill') {
        return null;
      }
      if (data is! Map) return null;
      return AgentSkill.fromJson(data.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  String _package(AgentSkill skill) => jsonEncode({
    'type': 'solab-skill',
    'formatVersion': 1,
    'data': skill.toJson(),
  });

  Future<void> _install(AgentSkill skill) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('安装 Skill'),
        content: Text(
          '${skill.name}\n版本: ${skill.version}\n\nSkill 只提供工作说明，不会获得额外工具权限或跳过确认。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('安装'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    final provider = context.read<AgentSkillProvider>();
    final id = skill.id.trim().isEmpty ? const Uuid().v4() : skill.id;
    await provider.save(skill.copyWith(id: id));
  }

  Future<void> _importFile() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    String? raw;
    if (file.bytes != null) {
      raw = utf8.decode(file.bytes!, allowMalformed: true);
    }
    if ((raw == null || raw.trim().isEmpty) && file.path != null) {
      raw = await File(file.path!).readAsString();
    }
    final skill = raw == null ? null : _decodePackage(raw);
    if (skill == null) {
      _toast('不是有效的 SoLab Skill 包');
      return;
    }
    await _install(skill);
  }

  Future<void> _installUrl() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从链接安装'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/skill.json',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('下载'),
          ),
        ],
      ),
    );
    final uri = Uri.tryParse(url ?? '');
    if (uri == null || uri.scheme != 'https') {
      if (url != null) _toast('只允许 HTTPS Skill 包链接');
      return;
    }
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _toast('下载失败: HTTP ${response.statusCode}');
        return;
      }
      final skill = _decodePackage(response.body);
      if (skill == null) {
        _toast('链接内容不是有效的 SoLab Skill 包');
        return;
      }
      await _install(skill.copyWith(sourceUrl: uri.toString()));
    } catch (_) {
      _toast('下载失败，请检查链接和网络');
    }
  }

  Future<void> _export(AgentSkill skill) async {
    final fileName = '${skill.name.trim().isEmpty ? 'skill' : skill.name}.json';
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出 Skill',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['json'],
      bytes: Uint8List.fromList(utf8.encode(_package(skill))),
    );
    if (path != null) _toast('已导出');
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<AgentSkillProvider>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('技能'),
        actions: [
          IconButton(
            icon: const Icon(Lucide.Download),
            tooltip: '从链接安装',
            onPressed: _installUrl,
          ),
          IconButton(
            icon: const Icon(Lucide.Import),
            tooltip: '从文件安装',
            onPressed: _importFile,
          ),
          IconButton(
            icon: const Icon(Lucide.Plus),
            tooltip: '新建 Skill',
            onPressed: () => _edit(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '内置技能由任务路由自动启用，已安装 Skill 按主题匹配后自动注入。Skill 不能新增工具权限，也不能绕过预览或确认。',
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: .65),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '内置任务技能 · ${SolabApkSkills.skillNames.length}',
            style: TextStyle(fontWeight: AppFontWeights.semibold),
          ),
          const SizedBox(height: 8),
          SettingsSectionCard(
            children: [
              for (var i = 0; i < SolabApkSkills.skillNames.length; i++) ...[
                SettingsActionRow(
                  icon: Lucide.NotebookTabs,
                  label: (jsonDecode(
                    SolabApkSkills.read(SolabApkSkills.skillNames[i]),
                  ) as Map)['name'].toString(),
                  detailText:
                      '自动生效 · ${SolabApkSkills.activationHints[SolabApkSkills.skillNames[i]]}',
                  onTap: () => _showBuiltinSkill(SolabApkSkills.skillNames[i]),
                ),
                if (i != SolabApkSkills.skillNames.length - 1)
                  settingsSectionDivider(context),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '已安装 Skill',
            style: TextStyle(fontWeight: AppFontWeights.semibold),
          ),
          const SizedBox(height: 8),
          if (provider.skills.isEmpty)
            SettingsSectionCard(
              children: [
                SettingsActionRow(
                  icon: Lucide.NotebookTabs,
                  label: '还没有安装 Skill',
                  detailText: '可从本地文件、HTTPS 链接安装，或新建一个。',
                  enabled: false,
                ),
              ],
            ),
          if (provider.skills.isNotEmpty)
            SettingsSectionCard(
              children: [
                for (var i = 0; i < provider.skills.length; i++) ...[
                  Builder(
                    builder: (context) {
                      final skill = provider.skills[i];
                      return SettingsActionRow(
                        icon: Lucide.NotebookTabs,
                        label: skill.name.isEmpty ? '未命名 Skill' : skill.name,
                        detailText:
                            '${skill.version}${skill.topics.isEmpty ? '' : ' · ${skill.topics.join('、')}'}',
                        enabled: skill.enabled,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch.adaptive(
                              value: skill.enabled,
                              onChanged: (enabled) => provider.save(
                                skill.copyWith(enabled: enabled),
                              ),
                            ),
                            PopupMenuButton<String>(
                              onSelected: (value) async {
                                if (value == 'edit') await _edit(skill: skill);
                                if (value == 'export') await _export(skill);
                                if (value == 'delete') {
                                  await provider.delete(skill.id);
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: 'edit', child: Text('编辑')),
                                PopupMenuItem(
                                  value: 'export',
                                  child: Text('导出'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('删除'),
                                ),
                              ],
                            ),
                          ],
                        ),
                        onTap: () => _edit(skill: skill),
                      );
                    },
                  ),
                  if (i != provider.skills.length - 1)
                    settingsSectionDivider(context),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _SkillEditSheet extends StatefulWidget {
  const _SkillEditSheet({this.skill});
  final AgentSkill? skill;

  @override
  State<_SkillEditSheet> createState() => _SkillEditSheetState();
}

class _SkillEditSheetState extends State<_SkillEditSheet> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _version;
  late final TextEditingController _author;
  late final TextEditingController _topicInput;
  late final TextEditingController _content;
  late bool _enabled;
  late List<String> _topics;

  @override
  void initState() {
    super.initState();
    final skill = widget.skill;
    _name = TextEditingController(text: skill?.name ?? '');
    _description = TextEditingController(text: skill?.description ?? '');
    _version = TextEditingController(text: skill?.version ?? '1.0.0');
    _author = TextEditingController(text: skill?.author ?? '');
    _topicInput = TextEditingController();
    _content = TextEditingController(text: skill?.content ?? '');
    _enabled = skill?.enabled ?? true;
    _topics = List<String>.from(skill?.topics ?? const <String>[]);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _version.dispose();
    _author.dispose();
    _topicInput.dispose();
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.skill == null ? '新建 Skill' : '编辑 Skill',
              style: TextStyle(fontWeight: AppFontWeights.semibold),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  TextField(
                    controller: _name,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: '名称'),
                  ),
                  TextField(
                    controller: _description,
                    decoration: const InputDecoration(labelText: '说明'),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _version,
                          decoration: const InputDecoration(labelText: '版本'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _author,
                          decoration: const InputDecoration(labelText: '作者'),
                        ),
                      ),
                    ],
                  ),
                  SwitchListTile(
                    value: _enabled,
                    onChanged: (value) => setState(() => _enabled = value),
                    title: const Text('启用'),
                  ),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final topic in _topics)
                        InputChip(
                          label: Text(topic),
                          onDeleted: () =>
                              setState(() => _topics.remove(topic)),
                        ),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _topicInput,
                          decoration: const InputDecoration(labelText: '适用主题'),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Lucide.Plus),
                        onPressed: () {
                          final value = _topicInput.text.trim();
                          if (value.isEmpty || _topics.contains(value)) return;
                          setState(() {
                            _topics.add(value);
                            _topicInput.clear();
                          });
                        },
                      ),
                    ],
                  ),
                  TextField(
                    controller: _content,
                    onChanged: (_) => setState(() {}),
                    minLines: 8,
                    maxLines: 14,
                    decoration: const InputDecoration(labelText: '工作说明'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed:
                  _name.text.trim().isEmpty || _content.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(context).pop(
                      AgentSkill(
                        id: widget.skill?.id ?? const Uuid().v4(),
                        name: _name.text.trim(),
                        description: _description.text.trim(),
                        version: _version.text.trim(),
                        author: _author.text.trim(),
                        sourceUrl: widget.skill?.sourceUrl ?? '',
                        enabled: _enabled,
                        topics: _topics,
                        content: _content.text.trim(),
                      ),
                    ),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
}
