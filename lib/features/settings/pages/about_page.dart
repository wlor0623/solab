import 'dart:io';

import 'package:solab/theme/app_font_weights.dart';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../icons/lucide_adapter.dart';

import 'package:provider/provider.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../core/services/haptics.dart';
import 'debug_page.dart';
import 'log_viewer_page.dart';
import 'open_source_licenses_page.dart';

import 'package:solab/theme/app_semantic_colors.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String _version = '';
  String _buildNumber = '';
  int _versionTapCount = 0;
  DateTime? _lastVersionTap;
  int _appNameTapCount = 0;
  DateTime? _lastAppNameTap;

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  Future<void> _loadInfo() async {
    final pkg = await PackageInfo.fromPlatform();
    setState(() {
      _version = pkg.version;
      _buildNumber = pkg.buildNumber;
    });
  }

  Future<void> _onAppNameTap() async {
    final now = DateTime.now();
    if (_lastAppNameTap == null ||
        now.difference(_lastAppNameTap!) > const Duration(seconds: 2)) {
      _appNameTapCount = 0;
    }
    _lastAppNameTap = now;
    _appNameTapCount++;
    if (_appNameTapCount < 7) return;

    _appNameTapCount = 0;
    Haptics.medium();
    final added = await context.read<SettingsProvider>().unlockKelivoSearch();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showAppSnackBar(
      context,
      message: added
          ? l10n.aboutPageKelivoSearchUnlocked
          : l10n.aboutPageKelivoSearchAlreadyUnlocked,
      type: NotificationType.success,
    );
  }

  void _onVersionTap() {
    final now = DateTime.now();
    // Reset the counter if taps are spaced too far apart
    if (_lastVersionTap == null ||
        now.difference(_lastVersionTap!) > const Duration(seconds: 2)) {
      _versionTapCount = 0;
    }
    _lastVersionTap = now;
    _versionTapCount++;

    const threshold = 7;
    if (_versionTapCount < threshold) return;

    _versionTapCount = 0; // reset after unlock
    _showEasterEgg();
  }

  void _showEasterEgg() {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(
        minWidth: MediaQuery.of(context).size.width,
        maxWidth: MediaQuery.of(context).size.width,
      ),
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogContext, dialogSetState) {
            return SafeArea(
              child: FractionallySizedBox(
                heightFactor: 0.7,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(Lucide.Sparkles, size: 28, color: cs.primary),
                      const SizedBox(height: 16),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              if (Platform.isAndroid || Platform.isIOS) ...[
                                const SizedBox(height: 24),
                                const Divider(),
                                const SizedBox(height: 16),
                                Material(
                                  color: Colors.transparent,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 6,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            l10n.contextLogSettingTitle,
                                            style: TextStyle(
                                              color: cs.onSurface.withValues(
                                                alpha: 0.9,
                                              ),
                                            ),
                                          ),
                                        ),
                                        InkWell(
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          onTap: () {
                                            Navigator.of(context).push(
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    const LogViewerPage(
                                                      initialTab: LogViewerPage
                                                          .contextTab,
                                                    ),
                                              ),
                                            );
                                          },
                                          child: Padding(
                                            padding: const EdgeInsets.all(6),
                                            child: Icon(
                                              Lucide.FolderOpen,
                                              size: 20,
                                              color: cs.primary,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        IosSwitch(
                                          value: dialogContext
                                              .watch<SettingsProvider>()
                                              .contextLogEnabled,
                                          onChanged: (v) => dialogContext
                                              .read<SettingsProvider>()
                                              .setContextLogEnabled(v),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    l10n.contextLogSettingSubtitle,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurface.withValues(
                                        alpha: 0.65,
                                      ),
                                      height: 1.25,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Material(
                                  color: Colors.transparent,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 6,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            l10n.requestLogSettingTitle,
                                            style: TextStyle(
                                              color: cs.onSurface.withValues(
                                                alpha: 0.9,
                                              ),
                                            ),
                                          ),
                                        ),
                                        InkWell(
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          onTap: () {
                                            Navigator.of(context).push(
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    const LogViewerPage(
                                                      initialTab: LogViewerPage
                                                          .requestTab,
                                                    ),
                                              ),
                                            );
                                          },
                                          child: Padding(
                                            padding: const EdgeInsets.all(6),
                                            child: Icon(
                                              Lucide.FolderOpen,
                                              size: 20,
                                              color: cs.primary,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        IosSwitch(
                                          value: dialogContext
                                              .watch<SettingsProvider>()
                                              .requestLogEnabled,
                                          onChanged: (v) => dialogContext
                                              .read<SettingsProvider>()
                                              .setRequestLogEnabled(v),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    l10n.requestLogSettingSubtitle,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurface.withValues(
                                        alpha: 0.65,
                                      ),
                                      height: 1.25,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Material(
                                  color: Colors.transparent,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 6,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            l10n.flutterLogSettingTitle,
                                            style: TextStyle(
                                              color: cs.onSurface.withValues(
                                                alpha: 0.9,
                                              ),
                                            ),
                                          ),
                                        ),
                                        InkWell(
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          onTap: () {
                                            Navigator.of(context).push(
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    const LogViewerPage(
                                                      initialTab:
                                                          LogViewerPage.appTab,
                                                    ),
                                              ),
                                            );
                                          },
                                          child: Padding(
                                            padding: const EdgeInsets.all(6),
                                            child: Icon(
                                              Lucide.FolderOpen,
                                              size: 20,
                                              color: cs.primary,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        IosSwitch(
                                          value: dialogContext
                                              .watch<SettingsProvider>()
                                              .flutterLogEnabled,
                                          onChanged: (v) => dialogContext
                                              .read<SettingsProvider>()
                                              .setFlutterLogEnabled(v),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    l10n.flutterLogSettingSubtitle,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurface.withValues(
                                        alpha: 0.65,
                                      ),
                                      height: 1.25,
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 24),
                              const Divider(),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => Navigator.of(ctx).maybePop(),
                        child: Text(l10n.aboutPageEasterEggButton),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _openDebugPage() {
    Haptics.medium();
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const DebugPage()));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: _TactileIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.settingsPageAbout),
        actions: const [SizedBox(width: 12)],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
        children: [
          // Header card: left icon + right title/description
          _iosSectionCard(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onLongPress: _openDebugPage,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 54,
                          height: 54,
                          child: Image.asset(
                            'assets/app_icon.png',
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _onAppNameTap,
                            child: Text(
                              l10n.aboutPageAppName,
                              key: const ValueKey('about-page-app-name'),
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: AppFontWeights.semibold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l10n.aboutPageAppDescription,
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurface.withValues(alpha: 0.65),
                              height: 1.2,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // SoLab 本项目与当前能力
          _iosSectionCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Row(
                  children: [
                    Icon(Lucide.BadgeInfo, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '关于 SoLab',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: AppFontWeights.semibold,
                          color: cs.onSurface.withValues(alpha: 0.9),
                        ),
                      ),
                    ),
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
                        'AGPL-3.0',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.primary,
                          fontWeight: AppFontWeights.semibold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                child: Text(
                  '基于 Kelivo 继续演进，项目代码按 AGPL-3.0 发布。',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
              ..._solabFeatureRows(context),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 14),
                child: Text(
                  '仅处理你拥有或已获明确授权的 APK。许可证、实际组件与历史来源已在下方分组列明。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: cs.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // iOS-style list card
          _iosSectionCard(
            children: [
              // Version (tap 7x to unlock easter egg) — logic unchanged
              _iosNavRow(
                context,
                icon: Lucide.Code,
                label: l10n.aboutPageVersion,
                detailBuilder: (_) => Text(
                  _version.isEmpty ? '...' : '$_version / $_buildNumber',
                ),
                onTap: _onVersionTap,
              ),
              _iosDivider(context),
              _iosNavRow(
                context,
                icon: Lucide.User,
                label: '软件作者',
                detailBuilder: (_) => const Text('酷安 Chooseu · MT 永闲居士'),
                onTap: null,
              ),
              _iosDivider(context),
              _iosNavRow(
                context,
                icon: Lucide.BookOpenText,
                label: l10n.aboutPageOpenSourceLicenses,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const OpenSourceLicensesPage(),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// SoLab 当前能力清单（纯展示行，不可点击）。
  static const List<({String icon, String title, String desc})>
  _solabFeatures = [
    (
      icon: 'toolbox',
      title: 'APK 工作台',
      desc: '授权 APK 的解包 / 分析 / 修改 / 重签名，产物在工作目录单独生成',
    ),
    (
      icon: 'server',
      title: '进程内 MCP 服务器',
      desc: '可选局域网 HTTP MCP 服务；开启时本地 Agent 工具暂停',
    ),
    (
      icon: 'search',
      title: 'DEX 分析与修补引擎',
      desc: 'methods/fields 定位、smali 读写、交叉引用、混淆类反查',
    ),
    (icon: 'cpu', title: 'SO 分析引擎', desc: 'ELF 解析、函数/控制流/加密识别、反汇编、模拟执行'),
    (
      icon: 'flame',
      title: 'Flutter AOT 解析工具',
      desc: '内置隔离 runner 并自动匹配版本；建立对象池、字符串和函数索引，缺失函数体时回退原生反汇编，验证后可写回 libapp.so',
    ),
    (icon: 'shield', title: '特征规则库', desc: '广告 SDK 特征、厂商快速开关与可选订阅同步'),
    (
      icon: 'report',
      title: '分析报告体系',
      desc: 'reportSourceApk / boundApk 一致性与 reportFreshness 新鲜度校验',
    ),
    (icon: 'brain', title: 'AI 基础设施', desc: '世界书、助手记忆、指令注入、内置 SoLab 助手'),
    (icon: 'chat', title: 'AI 对话与多模型接入', desc: '基于开源框架 Kelivo 二次开发'),
  ];

  List<Widget> _solabFeatureRows(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const icons = {
      'toolbox': Lucide.Wrench,
      'server': Lucide.HardDrive,
      'search': Lucide.Search,
      'cpu': Lucide.Cpu,
      'flame': Lucide.Zap,
      'shield': Lucide.ShieldCheck,
      'report': Lucide.FileSearch,
      'brain': Lucide.Brain,
      'chat': Lucide.MessageSquare,
    };
    return [
      for (final f in _solabFeatures)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  icons[f.icon],
                  size: 16,
                  color: cs.primary.withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      f.title,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: AppFontWeights.medium,
                        color: cs.onSurface.withValues(alpha: 0.85),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      f.desc,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: cs.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
    ];
  }
}

// --- iOS-style helpers (mirroring Settings/Display pages) ---

Widget _iosSectionCard({required List<Widget> children}) {
  return Builder(
    builder: (context) {
      final theme = Theme.of(context);
      final cs = theme.colorScheme;
      final isDark = theme.brightness == Brightness.dark;
      final Color bg = context.appColors.surfaceCard;
      return Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: isDark ? 0.08 : 0.06),
            width: 0.6,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: children),
        ),
      );
    },
  );
}

Widget _iosDivider(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Divider(
    height: 6,
    thickness: 0.6,
    indent: 54,
    endIndent: 12,
    color: cs.outlineVariant.withValues(alpha: 0.18),
  );
}

class _AnimatedPressColor extends StatelessWidget {
  const _AnimatedPressColor({
    required this.pressed,
    required this.base,
    required this.builder,
  });
  final bool pressed;
  final Color base;
  final Widget Function(Color color) builder;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final target = pressed
        ? (Color.lerp(base, cs.surface, 0.55) ?? base)
        : base;
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: target),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, color, _) => builder(color ?? base),
    );
  }
}

class _TactileRow extends StatefulWidget {
  const _TactileRow({
    required this.builder,
    this.onTap,
    this.pressedScale = 1.00,
    this.haptics = false,
  });
  final Widget Function(bool pressed) builder;
  final VoidCallback? onTap;
  final double pressedScale;
  final bool haptics;
  @override
  State<_TactileRow> createState() => _TactileRowState();
}

class _TactileRowState extends State<_TactileRow> {
  bool _pressed = false;
  void _setPressed(bool v) {
    if (_pressed != v) {
      setState(() => _pressed = v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.builder(_pressed);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => _setPressed(true),
      onTapUp: widget.onTap == null ? null : (_) => _setPressed(false),
      onTapCancel: widget.onTap == null ? null : () => _setPressed(false),
      onTap: widget.onTap == null
          ? null
          : () {
              if (widget.haptics &&
                  context.read<SettingsProvider>().hapticsOnListItemTap) {
                Haptics.soft();
              }
              widget.onTap!.call();
            },
      child: widget.pressedScale == 1.0
          ? child
          : AnimatedScale(
              scale: _pressed ? widget.pressedScale : 1.0,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOutCubic,
              child: child,
            ),
    );
  }
}

Widget _iosNavRow(
  BuildContext context, {
  required IconData icon,
  required String label,
  VoidCallback? onTap,
  String? detailText,
  Widget Function(BuildContext ctx)? detailBuilder,
}) {
  final cs = Theme.of(context).colorScheme;
  final interactive = onTap != null;
  return _TactileRow(
    onTap: onTap,
    pressedScale: 1.00, // list rows: color shift only, no scale
    haptics: false,
    builder: (pressed) {
      final baseColor = cs.onSurface.withValues(alpha: 0.9);
      return _AnimatedPressColor(
        pressed: pressed,
        base: baseColor,
        builder: (c) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                SizedBox(width: 36, child: Icon(icon, size: 20, color: c)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 15, color: c),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (detailBuilder != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: DefaultTextStyle(
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                      child: detailBuilder(context),
                    ),
                  )
                else if (detailText != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      detailText,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                if (interactive) Icon(Lucide.ChevronRight, size: 16, color: c),
              ],
            ),
          );
        },
      );
    },
  );
}

// AppBar tactile icon button copied from provider detail page (with slight press scale)
class _TactileIconButton extends StatefulWidget {
  const _TactileIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.size = 22,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;

  @override
  State<_TactileIconButton> createState() => _TactileIconButtonState();
}

class _TactileIconButtonState extends State<_TactileIconButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final base = widget.color;
    final pressColor = base.withValues(alpha: 0.7);
    final icon = Icon(
      widget.icon,
      size: widget.size,
      color: _pressed ? pressColor : base,
    );

    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () {
          // Follow provider detail: no haptics on tap
          widget.onTap();
        },
        child: AnimatedScale(
          scale: _pressed ? 0.95 : 1.0,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: icon,
          ),
        ),
      ),
    );
  }
}
