import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../core/services/android_background.dart';
import '../../../core/services/mcp_server/mcp_http_server.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/app_font_weights.dart';
import 'package:solab/theme/app_semantic_colors.dart';

class McpHostModeGate extends StatelessWidget {
  const McpHostModeGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!context.watch<SettingsProvider>().mcpServerEnabled) return child;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      ),
      child: const McpHostModePage(),
    );
  }
}

class McpHostModePage extends StatelessWidget {
  const McpHostModePage({super.key});

  Future<void> _exit(BuildContext context) async {
    final settings = context.read<SettingsProvider>();
    await McpHttpServer.instance.stop();
    await settings.setMcpServerEnabled(false);
    if (Platform.isAndroid &&
        settings.androidBackgroundChatMode == AndroidBackgroundChatMode.off &&
        !AndroidBackgroundManager.hasActiveGenerationHold) {
      try {
        await AndroidBackgroundManager.setEnabled(false);
      } catch (_) {}
    } else if (Platform.isAndroid) {
      await AndroidBackgroundManager.setEnabled(
        true,
        networkRequired: AndroidBackgroundManager.hasActiveGenerationHold,
      );
    }
  }

  void _copy(BuildContext context, String value, String message) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 1200),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();
    final server = McpHttpServer.instance;
    return ListenableBuilder(
      listenable: server,
      builder: (context, _) {
        final running = server.isRunning;
        final urls = server.lanUrls;
        final authOn = server.authRequired;
        final statusColor = running ? context.appColors.success : cs.error;
        return Scaffold(
          backgroundColor: cs.surface,
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          running ? Lucide.Network : Lucide.TriangleAlert,
                          size: 25,
                          color: statusColor,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        l10n.mcpServerTitle,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: AppFontWeights.emphasis,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: statusColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              running ? '工具端运行中' : '服务已停止',
                              style: TextStyle(
                                fontSize: 12,
                                color: statusColor,
                                fontWeight: AppFontWeights.semibold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 9),
                      Text(
                        running
                            ? '外部 AI 可连接，App 内 Agent 工具已暂停'
                            : '请退出后检查端口并重新开启',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _SectionLabel(label: '连接信息', value: '端口 ${server.port}'),
                const SizedBox(height: 8),
                _HostInfoCard(
                  icon: Lucide.Link2,
                  title: running ? '${urls.length} 个可用地址' : '连接地址',
                  child: !running
                      ? const _HostEmptyState(text: '服务未运行，暂无可用地址')
                      : Column(
                          children: [
                            for (var i = 0; i < urls.length; i++) ...[
                              if (i > 0) const Divider(height: 1, indent: 16),
                              _HostValueRow(
                                label: i == 0 ? '本机' : '局域网',
                                value: urls[i],
                                onCopy: () =>
                                    _copy(context, urls[i], '已复制连接地址'),
                              ),
                            ],
                          ],
                        ),
                ),
                const SizedBox(height: 18),
                const _SectionLabel(label: '安全'),
                const SizedBox(height: 8),
                _HostInfoCard(
                  icon: authOn ? Lucide.ShieldCheck : Lucide.Shield,
                  title: authOn ? '访问保护已开启' : '访问保护未开启',
                  child: authOn
                      ? _HostValueRow(
                          label: '令牌',
                          value: settings.mcpServerToken,
                          onCopy: () => _copy(
                            context,
                            settings.mcpServerToken,
                            '已复制访问令牌',
                          ),
                        )
                      : const _HostEmptyState(text: '局域网内客户端可直接连接'),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  icon: const Icon(Lucide.CircleStop, size: 18),
                  label: const Text('退出 MCP 模式'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    textStyle: TextStyle(
                      fontSize: 15,
                      fontWeight: AppFontWeights.semibold,
                    ),
                  ),
                  onPressed: () => _exit(context),
                ),
                const SizedBox(height: 8),
                Text(
                  '退出后恢复 App 使用，外部 AI 将断开连接',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              color: cs.onSurfaceVariant,
              fontWeight: AppFontWeights.semibold,
            ),
          ),
        ),
        if (value != null)
          Text(
            value!,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
      ],
    );
  }
}

class _HostInfoCard extends StatelessWidget {
  const _HostInfoCard({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Row(
              children: [
                Icon(icon, size: 16, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _HostEmptyState extends StatelessWidget {
  const _HostEmptyState({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}

class _HostValueRow extends StatelessWidget {
  const _HostValueRow({
    required this.label,
    required this.value,
    required this.onCopy,
  });

  final String label;
  final String value;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: cs.primary,
                fontWeight: AppFontWeights.semibold,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontFamily: 'monospace',
                color: cs.onSurface.withValues(alpha: 0.85),
              ),
            ),
          ),
          IconButton(
            icon: Icon(Lucide.Copy, size: 17, color: cs.onSurfaceVariant),
            onPressed: onCopy,
          ),
        ],
      ),
    );
  }
}
