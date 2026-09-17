import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

import 'package:solab/theme/app_semantic_colors.dart';
import 'package:solab/theme/app_font_weights.dart';

import '../../../shared/widgets/ios_tactile.dart';

/// 本项目、实际组件与历史参考材料的许可证及来源声明。
/// 未声明许可证的材料只展示来源，不视为已获再分发授权。
/// 点击卡片展开完整声明与协议全文，再点收起。
class OpenSourceLicensesPage extends StatefulWidget {
  const OpenSourceLicensesPage({super.key});

  @override
  State<OpenSourceLicensesPage> createState() => _OpenSourceLicensesPageState();
}

class _LicenseLink {
  const _LicenseLink(this.label, this.url);
  final String label;
  final String url;
}

class _LicenseEntry {
  const _LicenseEntry({
    required this.title,
    required this.badge,
    required this.summary,
    this.body,
    this.links = const [],
    this.asset,
    this.assetLabel,
  });

  final String title;
  final String badge;
  final String summary;
  final String? body;
  final List<_LicenseLink> links;
  final String? asset;
  final String? assetLabel;
}

const _projectEntries = <_LicenseEntry>[
  _LicenseEntry(
    title: 'SoLab',
    badge: 'AGPL-3.0',
    summary: '本项目 · 酷安 Chooseu / MT 永闲居士',
    body:
        'SoLab 由酷安 Chooseu（MT 论坛：永闲居士）开发，基于 Kelivo 继续演进。'
        '项目代码按 GNU Affero General Public License v3.0 发布。'
        '完整协议正文位于源码根目录 LICENSE。\n\n'
        '第三方组件继续适用各自许可证；仅作历史或工程参考、且未声明许可证的材料会单独标注，'
        '不因 SoLab 使用 AGPL-3.0 而自动获得再分发许可。',
  ),
  _LicenseEntry(
    title: 'Kelivo',
    badge: 'AGPL-3.0',
    summary: 'AI 对话框架上游 · Chevey339',
    body:
        'SoLab 的 AI 对话、多模型接入、助手与消息等基础框架源自 Kelivo。'
        'Kelivo 当前仓库的 LICENSE 为 AGPL-3.0。',
    links: [
      _LicenseLink('官方网站', 'https://kelivo.psycheas.top/'),
      _LicenseLink('GitHub 源码', 'https://github.com/Chevey339/kelivo'),
      _LicenseLink(
        'AGPL-3.0 许可证',
        'https://github.com/Chevey339/kelivo/blob/master/LICENSE',
      ),
    ],
  ),
];

const _componentEntries = <_LicenseEntry>[
  _LicenseEntry(
    title: 'SOMCP',
    badge: 'AGPL-3.0',
    summary: 'MCP 网关与逆向引擎聚合参考 · sjlz',
    body:
        'SoLab 参考了 SOMCP 的 MCP 网关和逆向引擎聚合方式。SOMCP 当前公开仓库的 '
        'LICENSE 为 AGPL-3.0；旧说明中标注 GPL-3.0 的内容已更正。',
    links: [
      _LicenseLink(
        'GitHub 源码',
        'https://github.com/bilieebiliee1-design/SOMCP',
      ),
      _LicenseLink(
        'AGPL-3.0 许可证',
        'https://github.com/bilieebiliee1-design/SOMCP/blob/main/LICENSE',
      ),
    ],
  ),
  _LicenseEntry(
    title: 'Blutter（B(l)utter）',
    badge: 'MIT',
    summary: 'Flutter AOT 逆向分析引擎 · worawit',
    body:
        'Blutter 由 Worawit Wangwarunyoo（@worawit）开发，用于解析 Flutter '
        'Dart AOT 产物并生成对象池、汇编和交叉引用等信息。SoLab 的 Flutter AOT '
        '分析能力使用了该项目的技术与组件。',
    links: [
      _LicenseLink('GitHub 源码', 'https://github.com/worawit/blutter'),
      _LicenseLink(
        'MIT 许可证',
        'https://github.com/worawit/blutter/blob/main/LICENSE',
      ),
    ],
    asset: 'assets/licenses/blutter_mit.txt',
    assetLabel: 'MIT 许可证（Blutter）',
  ),
  _LicenseEntry(
    title: 'PPTool-2.0',
    badge: 'Apache-2.0',
    summary: 'Dart 对象池引用定位 · Kirlif',
    body:
        'PPTool 用于根据对象池偏移定位 libapp.so 中 Dart 对象的加载地址。'
        'SoLab 将其作为对象池引用定位方案的工程参考。',
    links: [_LicenseLink('GitHub 源码', 'https://github.com/Kirlif/PPTool')],
    asset: 'assets/licenses/pptool_apache2.txt',
    assetLabel: 'Apache-2.0 许可证（PPTool）',
  ),
  _LicenseEntry(
    title: 'ApkDataMultiplexing',
    badge: '使用组件 · 未声明许可证',
    summary: 'APK 数据复用与 V2/V3 签名 · L-JINBIN',
    body:
        'SoLab 使用 ApkDataMultiplexing 组件处理原包数据复用与 V2/V3 签名。'
        '上游仓库当前没有 LICENSE 文件，因此这里提供来源并明确标注，不将其误写为开源许可证。',
    links: [
      _LicenseLink(
        'GitHub 源码',
        'https://github.com/L-JINBIN/ApkDataMultiplexing',
      ),
    ],
  ),
];

const _referenceEntries = <_LicenseEntry>[
  _LicenseEntry(
    title: '小奶瓶项目',
    badge: '历史源码 · 未声明许可证',
    summary: 'APK 工具历史项目 · MT 论坛来源',
    body:
        '小奶瓶项目是 SoLab APK 工具能力的历史来源之一。现以 MT 论坛项目帖作为'
        '准确来源，不再链接错误的 GitHub 仓库。',
    links: [
      _LicenseLink('MT 论坛项目帖', 'https://bbs.binmt.cc/thread-171312-1-1.html'),
    ],
  ),
  _LicenseEntry(
    title: 'ApkSignatureKillerEx',
    badge: '工程参考 · 未声明许可证',
    summary: '原包签名校验处理参考 · 作者：L-JINBIN',
    body:
        'SoLab 参考 ApkSignatureKillerEx 对 MT 去除签名校验原理及其对抗方式的演示。'
        '此前记录的仓库地址已经失效，现改为可访问的上游仓库。该仓库当前没有 LICENSE。',
    links: [
      _LicenseLink(
        'GitHub 源码',
        'https://github.com/L-JINBIN/ApkSignatureKillerEx',
      ),
    ],
  ),
  _LicenseEntry(
    title: '玄星逆核（XuanXing NieHe）',
    badge: '参考材料 · 随附 GPL-3.0',
    summary: '逆向工具聚合与 MCP 网关工程参考',
    body:
        'SoLab 参考了本地玄星逆核源码材料中的工具组织和 MCP 网关工程实践。'
        '该材料随附 GPL-3.0 LICENSE，但其说明将 SOMCP 标为 GPL-3.0；SOMCP 当前公开仓库'
        '实际为 AGPL-3.0，因此两者分开列示，不用该 GPL 文本替代 SOMCP 的许可证。',
    asset: 'assets/licenses/xuanxingniehe_gpl3.txt',
    assetLabel: '参考材料随附的 GPL-3.0 文本',
  ),
  _LicenseEntry(
    title: 'Flutter 解析工具（Blutter 封装）',
    badge: '组件来源记录 · MT 论坛',
    summary: '手机端 Blutter 封装 · com.ayue.flutter',
    body:
        'SoLab 在原手机端 Flutter 解析工具基础上，重做了版本匹配、隔离 runner 调度、'
        '结果缓存与对象池/字符串/函数索引；Blutter 无法还原函数体时自动回退原生反汇编，'
        '并把定位、验证和 libapp.so 写回接入统一工作区。Blutter 上游代码为 MIT；'
        '封装 App 和预编译 runner 的来源仍单独记录。',
    links: [
      _LicenseLink('MT 论坛帖子', 'https://bbs.binmt.cc/thread-168571-1-1.html'),
    ],
    asset: 'assets/licenses/blutter_mit.txt',
    assetLabel: 'MIT 许可证（Blutter）',
  ),
];

class _OpenSourceLicensesPageState extends State<OpenSourceLicensesPage> {
  final Map<String, String> _texts = {};
  Future<void>? _loadFuture;
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _loadFuture = _loadAll();
  }

  Future<void> _loadAll() async {
    for (final entry in [
      ..._projectEntries,
      ..._componentEntries,
      ..._referenceEntries,
    ]) {
      final asset = entry.asset;
      if (asset == null || _texts.containsKey(asset)) continue;
      _texts[asset] = await rootBundle.loadString(asset);
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.aboutPageOpenSourceLicenses)),
      body: FutureBuilder<void>(
        future: _loadFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _sectionHeader(context, '本项目与上游'),
              for (int i = 0; i < _projectEntries.length; i++) ...[
                _LicenseCard(
                  entry: _projectEntries[i],
                  text: _texts[_projectEntries[i].asset],
                  expanded: _expanded.contains('p$i'),
                  onToggle: () => setState(() {
                    if (!_expanded.add('p$i')) _expanded.remove('p$i');
                  }),
                  onOpenUrl: _openUrl,
                ),
                if (i != _projectEntries.length - 1) const SizedBox(height: 12),
              ],
              const SizedBox(height: 24),
              _sectionHeader(context, '实际使用的组件'),
              for (int i = 0; i < _componentEntries.length; i++) ...[
                _LicenseCard(
                  entry: _componentEntries[i],
                  text: _texts[_componentEntries[i].asset],
                  expanded: _expanded.contains('c$i'),
                  onToggle: () => setState(() {
                    if (!_expanded.add('c$i')) _expanded.remove('c$i');
                  }),
                  onOpenUrl: _openUrl,
                ),
                if (i != _componentEntries.length - 1)
                  const SizedBox(height: 12),
              ],
              const SizedBox(height: 24),
              _sectionHeader(context, '历史与工程参考'),
              for (int i = 0; i < _referenceEntries.length; i++) ...[
                _LicenseCard(
                  entry: _referenceEntries[i],
                  text: _texts[_referenceEntries[i].asset],
                  expanded: _expanded.contains('r$i'),
                  onToggle: () => setState(() {
                    if (!_expanded.add('r$i')) _expanded.remove('r$i');
                  }),
                  onOpenUrl: _openUrl,
                ),
                if (i != _referenceEntries.length - 1)
                  const SizedBox(height: 12),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: AppFontWeights.semibold,
          color: cs.onSurface.withValues(alpha: 0.6),
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _LicenseCard extends StatelessWidget {
  const _LicenseCard({
    required this.entry,
    required this.text,
    required this.expanded,
    required this.onToggle,
    required this.onOpenUrl,
  });

  final _LicenseEntry entry;
  final String? text;
  final bool expanded;
  final VoidCallback onToggle;
  final Future<void> Function(String url) onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final bg = context.appColors.surfaceCard;
    // IosCardPress 提供整卡按压反馈（变色 + 轻微缩放），修复点击无反馈问题。
    return IosCardPress(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(16),
      baseColor: bg,
      pressedBlendStrength: 0.5,
      border: Border.all(
        color: cs.outlineVariant.withValues(alpha: isDark ? 0.08 : 0.06),
        width: 0.6,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 12, 13),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: AppFontWeights.semibold,
                                color: cs.onSurface.withValues(alpha: 0.9),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: cs.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              entry.badge,
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.primary,
                                fontWeight: AppFontWeights.semibold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        entry.summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Lucide.ChevronDown,
                    size: 18,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (entry.body != null) ...[
                          SelectableText(
                            entry.body!,
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.6,
                              color: cs.onSurface.withValues(alpha: 0.75),
                            ),
                          ),
                        ],
                        if (entry.links.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final link in entry.links)
                                _LinkChip(
                                  label: link.label,
                                  onTap: () => onOpenUrl(link.url),
                                ),
                            ],
                          ),
                        ],
                        if (text != null) ...[
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  entry.assetLabel ?? '',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: AppFontWeights.semibold,
                                    color: cs.onSurface.withValues(alpha: 0.7),
                                  ),
                                ),
                              ),
                              GestureDetector(
                                onTap: () => Clipboard.setData(
                                  ClipboardData(text: text!),
                                ),
                                child: Icon(
                                  Lucide.Copy,
                                  size: 15,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Container(
                            width: double.infinity,
                            constraints: const BoxConstraints(maxHeight: 300),
                            decoration: BoxDecoration(
                              color: cs.onSurface.withValues(
                                alpha: isDark ? 0.06 : 0.035,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(12),
                              child: SelectableText(
                                text!,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  height: 1.5,
                                  color: cs.onSurface.withValues(alpha: 0.65),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity, height: 0),
          ),
        ],
      ),
    );
  }
}

class _LinkChip extends StatelessWidget {
  const _LinkChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IosCardPress(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      baseColor: cs.primary.withValues(alpha: 0.08),
      border: Border.all(color: cs.primary.withValues(alpha: 0.25), width: 0.6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Lucide.ExternalLink, size: 13, color: cs.primary),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: cs.primary,
              fontWeight: AppFontWeights.medium,
            ),
          ),
        ],
      ),
    );
  }
}
