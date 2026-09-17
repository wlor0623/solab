import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/assistant_provider.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../core/providers/mcp_provider.dart';
import '../../../core/providers/world_book_provider.dart';
import '../../../core/providers/agent_skill_provider.dart';
import '../../../core/providers/instruction_injection_provider.dart';
import '../widgets/mcp_server_edit_sheet.dart';
import '../widgets/mcp_json_edit_sheet.dart';
import '../widgets/mcp_timeout_sheet.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../core/services/haptics.dart';
import '../../../theme/app_font_weights.dart';
import 'package:solab/theme/app_semantic_colors.dart';
import '../../../core/services/mcp_server/mcp_http_server.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/services/android_background.dart';
import '../../home/controllers/chat_actions.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/settings_section.dart';

class McpPage extends StatelessWidget {
  const McpPage({super.key});

  Color _statusColor(BuildContext context, McpStatus s) {
    final cs = Theme.of(context).colorScheme;
    switch (s) {
      case McpStatus.connected:
        return context.appColors.success;
      case McpStatus.connecting:
      case McpStatus.authorizing:
        return cs.primary;
      case McpStatus.needsAuthorization:
        return context.appColors.warning;
      case McpStatus.error:
      case McpStatus.idle:
        return Theme.of(context).colorScheme.error;
    }
  }

  Widget _tag(BuildContext context, String text, {Color? color}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: (color ?? cs.primary).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: (color ?? cs.primary).withValues(alpha: 0.35),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: color ?? cs.primary,
          fontWeight: AppFontWeights.emphasis,
        ),
      ),
    );
  }

  /// 本机 MCP 服务器卡片（app 作为 Server 暴露内置工具给局域网 AI 客户端）。
  Widget _hostServerCard(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sp = context.watch<SettingsProvider>();
    final running = sp.mcpServerEnabled;
    return _TactileRow(
      pressedScale: 1.00,
      haptics: false,
      onTap: () => showMcpHostServerSheet(context),
      builder: (pressed) {
        final base = cs.onSurface.withValues(alpha: 0.9);
        return _AnimatedPressColor(
          pressed: pressed,
          base: base,
          builder: (c) {
            final overlay = pressed
                ? cs.surface.withValues(alpha: isDark ? 0.06 : 0.05)
                : Colors.transparent;
            return Container(
              decoration: BoxDecoration(
                color: context.appColors.surfaceCard,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: cs.outlineVariant.withValues(
                    alpha: isDark ? 0.1 : 0.08,
                  ),
                  width: 0.6,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: context.appColors.surfaceFill,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            Lucide.Network,
                            size: 20,
                            color: cs.primary,
                          ),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: running
                                  ? context.appColors.success
                                  : cs.outline,
                              shape: BoxShape.circle,
                              border: Border.all(color: cs.surface, width: 1.5),
                            ),
                          ),
                        ),
                        if (overlay != Colors.transparent)
                          Positioned.fill(
                            child: Container(
                              decoration: BoxDecoration(
                                color: overlay,
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.mcpServerTitle,
                            style: TextStyle(
                              fontWeight: AppFontWeights.emphasis,
                              color: c,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _tag(
                                context,
                                running
                                    ? l10n.mcpServerStatusRunning
                                    : l10n.mcpServerStatusOff,
                                color: running
                                    ? context.appColors.success
                                    : null,
                              ),
                              const SizedBox.shrink(),
                              _tag(context, 'Streamable HTTP'),
                              _tag(context, 'SSE'),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Lucide.ChevronRight, size: 16, color: c),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final mcp = context.watch<McpProvider>();
    final servers = mcp.servers.toList();

    Future<void> showErrorDetails(
      String serverId,
      String? message,
      String name,
    ) async {
      final cs = Theme.of(context).colorScheme;
      final l10n = AppLocalizations.of(context)!;
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: cs.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.mcpPageErrorDialogTitle,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: AppFontWeights.emphasis,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    name,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: context.appColors.surfaceFill,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: cs.outlineVariant.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Text(
                      message?.isNotEmpty == true
                          ? message!
                          : l10n.mcpPageErrorNoDetails,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.of(ctx).maybePop(),
                          icon: Icon(Lucide.X, size: 16, color: cs.primary),
                          label: Text(
                            l10n.mcpPageClose,
                            style: TextStyle(color: cs.primary),
                          ),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(44),
                            backgroundColor: context.appColors.surfaceFill,
                            side: BorderSide(
                              color: cs.outlineVariant.withValues(alpha: 0.35),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            final mcpProvider = ctx.read<McpProvider>();
                            await mcpProvider.reconnect(serverId);
                            if (mcpProvider.isConnected(serverId) &&
                                ctx.mounted) {
                              Navigator.of(ctx).pop();
                            }
                          },
                          icon: const Icon(Lucide.RefreshCw, size: 18),
                          label: Text(l10n.mcpPageReconnect),
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size.fromHeight(44),
                            backgroundColor: cs.primary,
                            foregroundColor: cs.onPrimary,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.mcpPageBackTooltip,
          child: _TactileIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.mcpAssistantSheetTitle),
        actions: [
          Tooltip(
            message: l10n.mcpTimeoutSettingsTooltip,
            child: _TactileIconButton(
              icon: Lucide.Timer,
              color: cs.onSurface,
              size: 22,
              onTap: () async {
                await showMcpTimeoutSheet(context);
              },
            ),
          ),
          const SizedBox(width: 12),
          Tooltip(
            message: AppLocalizations.of(context)!.mcpJsonEditButtonTooltip,
            child: _TactileIconButton(
              icon: Lucide.Edit,
              color: cs.onSurface,
              size: 22,
              onTap: () async {
                await showMcpJsonEditSheet(context);
              },
            ),
          ),
          const SizedBox(width: 12),
          Tooltip(
            message: l10n.mcpPageAddMcpTooltip,
            child: _TactileIconButton(
              icon: Lucide.Plus,
              color: cs.onSurface,
              size: 22,
              onTap: () async {
                await showMcpServerEditSheet(context);
              },
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          _hostServerCard(context),
          if (servers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 56),
              child: Center(
                child: Text(
                  l10n.mcpPageNoServers,
                  style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
                ),
              ),
            )
          else
            ...servers.map((s) {
              final st = mcp.statusFor(s.id);
              final err = mcp.errorFor(s.id);
              final statusText = switch (st) {
                McpStatus.connected => l10n.mcpPageStatusConnected,
                McpStatus.connecting => l10n.mcpPageStatusConnecting,
                McpStatus.needsAuthorization =>
                  l10n.mcpPageStatusAuthorizationRequired,
                McpStatus.authorizing => l10n.mcpPageStatusAuthorizing,
                McpStatus.idle ||
                McpStatus.error => l10n.mcpPageStatusDisconnected,
              };

              final isDark = Theme.of(context).brightness == Brightness.dark;
              final row = _TactileRow(
                pressedScale: 1.00,
                haptics: false,
                onTap: () async {
                  await showMcpServerEditSheet(context, serverId: s.id);
                },
                builder: (pressed) {
                  final base = cs.onSurface.withValues(alpha: 0.9);
                  return _AnimatedPressColor(
                    pressed: pressed,
                    base: base,
                    builder: (c) {
                      final overlay = pressed
                          ? cs.surface.withValues(alpha: isDark ? 0.06 : 0.05)
                          : Colors.transparent;
                      return Container(
                        decoration: BoxDecoration(
                          color: context.appColors.surfaceCard,
                          // Soften the list card corners a bit
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: cs.outlineVariant.withValues(
                              alpha: isDark ? 0.1 : 0.08,
                            ),
                            width: 0.6,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 11,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Container(
                                    width: 42,
                                    height: 42,
                                    decoration: BoxDecoration(
                                      color: context.appColors.surfaceFill,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    alignment: Alignment.center,
                                    child: Icon(
                                      Lucide.Terminal,
                                      size: 20,
                                      color: cs.primary,
                                    ),
                                  ),
                                  Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child:
                                        st == McpStatus.connecting ||
                                            st == McpStatus.authorizing
                                        ? SizedBox(
                                            width: 12,
                                            height: 12,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                    cs.primary,
                                                  ),
                                            ),
                                          )
                                        : Container(
                                            width: 12,
                                            height: 12,
                                            decoration: BoxDecoration(
                                              color: s.enabled
                                                  ? _statusColor(context, st)
                                                  : cs.outline,
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: cs.surface,
                                                width: 1.5,
                                              ),
                                            ),
                                          ),
                                  ),
                                  if (overlay != Colors.transparent)
                                    Positioned.fill(
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: overlay,
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      s.name,
                                      style: TextStyle(
                                        fontWeight: AppFontWeights.emphasis,
                                        color: c,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 6,
                                      children: [
                                        _tag(
                                          context,
                                          statusText,
                                          color: _statusColor(context, st),
                                        ),
                                        _tag(
                                          context,
                                          s.transport ==
                                                  McpTransportType.inmemory
                                              ? l10n.mcpTransportTagInmemory
                                              : (s.transport ==
                                                        McpTransportType.sse
                                                    ? l10n.mcpTransportTagSse
                                                    : l10n.mcpTransportTagHttp),
                                        ),
                                        _tag(
                                          context,
                                          l10n.mcpPageToolsCount(
                                            s.tools
                                                .where((t) => t.enabled)
                                                .length,
                                            s.tools.length,
                                          ),
                                        ),
                                        if (!s.enabled)
                                          _tag(
                                            context,
                                            l10n.mcpPageStatusDisabled,
                                            color: cs.onSurface.withValues(
                                              alpha: 0.7,
                                            ),
                                          ),
                                      ],
                                    ),
                                    if ((st == McpStatus.error ||
                                            st ==
                                                McpStatus.needsAuthorization) &&
                                        (err?.isNotEmpty ?? false)) ...[
                                      const SizedBox(height: 8),
                                      Row(
                                        children: [
                                          Icon(
                                            Lucide.MessageCircleWarning,
                                            size: 14,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.error,
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              l10n.mcpPageConnectionFailed,
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.error,
                                              ),
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () => showErrorDetails(
                                              s.id,
                                              err,
                                              s.name,
                                            ),
                                            child: Text(l10n.mcpPageDetails),
                                          ),
                                        ],
                                      ),
                                    ],
                                    if (st == McpStatus.needsAuthorization) ...[
                                      const SizedBox(height: 8),
                                      Row(
                                        children: [
                                          Icon(
                                            Lucide.KeyRound,
                                            size: 14,
                                            color: context.appColors.warning,
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              l10n.mcpPageOAuthRequired,
                                              style: TextStyle(
                                                fontSize: 12,
                                                color:
                                                    context.appColors.warning,
                                              ),
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () => context
                                                .read<McpProvider>()
                                                .authorize(s.id),
                                            child: Text(
                                              l10n.mcpPageOAuthSignIn,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(Lucide.ChevronRight, size: 16, color: c),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              );

              return Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Slidable(
                  key: ValueKey('mcp-${s.id}'),
                  endActionPane: ActionPane(
                    motion: const StretchMotion(),
                    extentRatio: 0.42,
                    children: [
                      CustomSlidableAction(
                        autoClose: true,
                        backgroundColor: Colors.transparent,
                        child: Container(
                          width: double.infinity,
                          height: double.infinity,
                          decoration: BoxDecoration(
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? cs.error.withValues(alpha: 0.22)
                                : cs.error.withValues(alpha: 0.14),
                            // Match list card radius for consistency
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: cs.error.withValues(alpha: 0.35),
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          alignment: Alignment.center,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Lucide.Trash2, color: cs.error, size: 18),
                                const SizedBox(width: 6),
                                Text(
                                  l10n.mcpPageDelete,
                                  style: TextStyle(
                                    color: cs.error,
                                    fontWeight: AppFontWeights.emphasis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        onPressed: (_) async {
                          final prov = context.read<McpProvider>();
                          final prev = prov.getById(s.id);
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (dctx) => AlertDialog(
                              backgroundColor: cs.surface,
                              title: Text(l10n.mcpPageConfirmDeleteTitle),
                              content: Text(l10n.mcpPageConfirmDeleteContent),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(dctx).pop(false),
                                  child: Text(l10n.mcpPageCancel),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.of(dctx).pop(true),
                                  child: Text(l10n.mcpPageDelete),
                                ),
                              ],
                            ),
                          );
                          if (ok != true) return;
                          await prov.removeServer(s.id);
                          if (!context.mounted) return;
                          showAppSnackBar(
                            context,
                            message: l10n.mcpPageServerDeleted,
                            type: NotificationType.info,
                            actionLabel: l10n.mcpPageUndo,
                            onAction: () {
                              if (prev == null) return;
                              Future(() async {
                                final newId = await prov.addServer(
                                  enabled: prev.enabled,
                                  name: prev.name,
                                  transport: prev.transport,
                                  url: prev.url,
                                  headers: prev.headers,
                                  oauth: prev.oauth,
                                  oauthClient: prev.oauthClient,
                                );
                                // Try to refresh tools when back online
                                try {
                                  await prov.refreshTools(newId);
                                } catch (_) {}
                              });
                            },
                          );
                        },
                      ),
                    ],
                  ),
                  child: row,
                ),
              );
            }),
        ],
      ),
    );
  }
}

/// 本机 MCP 服务器设置弹窗：开关 / 端口 / 访问保护（可选 token）/ 连接地址。
Future<void> showMcpHostServerSheet(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final sp = context.read<SettingsProvider>();
  final portCtrl = TextEditingController(text: sp.mcpServerPort.toString());
  var overlayEnabled = Platform.isAndroid
      ? await AndroidBackgroundManager.isKeepAliveOverlayEnabled()
      : false;
  if (!context.mounted) {
    portCtrl.dispose();
    return;
  }

  Future<void> applyEnabled(BuildContext sheetContext, bool v) async {
    if (v) {
      if (Platform.isAndroid) {
        await AndroidBackgroundManager.ensureInitialized(
          notificationTitle: l10n.androidBackgroundNotificationTitle,
          notificationText: l10n.androidBackgroundNotificationText,
        );
        final keepAliveReady = await AndroidBackgroundManager.setEnabled(
          true,
          networkRequired: true,
        );
        if (!keepAliveReady) {
          if (sheetContext.mounted) {
            ScaffoldMessenger.of(sheetContext).showSnackBar(
              SnackBar(
                content: Text(
                  AndroidBackgroundManager.lastEnableError ??
                      '后台保活启动失败，未切换到 MCP 模式',
                ),
              ),
            );
          }
          return;
        }
      }
      await sp.setMcpServerEnabled(true);
      try {
        await ChatActions.cancelAllActiveGenerations();
      } catch (error) {
        await sp.setMcpServerEnabled(false);
        if (sheetContext.mounted) {
          ScaffoldMessenger.of(
            sheetContext,
          ).showSnackBar(SnackBar(content: Text('Agent 任务停止失败: $error')));
        }
        return;
      }
      McpHttpServer.instance.configure(
        port: sp.mcpServerPort,
        token: sp.mcpServerToken,
        // 与 main.dart 启动路径保持一致：工具执行依赖的 getter 全量注入。
        // 必须用常活的 rootNavigatorKey.currentContext，不能用本弹窗的
        // sheetContext——弹窗关闭后 context 卸载，getter 再被调用时
        // Provider.read 内部空断言，MCP 请求会全部 500（曾致 list tools failed）。
        assistantGetter: () => rootNavigatorKey.currentContext
            ?.read<AssistantProvider>()
            .currentAssistant,
        // chatService/memoryRepository 已在 main() 进程级注册
        // （后台 context 失效时仍可用），此处不再覆盖。
        worldBookGetter: () =>
            rootNavigatorKey.currentContext?.read<WorldBookProvider>(),
        agentSkillGetter: () =>
            rootNavigatorKey.currentContext?.read<AgentSkillProvider>(),
        instructionInjectionGetter: () => rootNavigatorKey.currentContext
            ?.read<InstructionInjectionProvider>(),
      );
      final ok = await McpHttpServer.instance.start();
      if (!ok) {
        await sp.setMcpServerEnabled(false);
        if (Platform.isAndroid &&
            sp.androidBackgroundChatMode == AndroidBackgroundChatMode.off &&
            !AndroidBackgroundManager.hasActiveGenerationHold) {
          await AndroidBackgroundManager.setEnabled(false);
        } else if (Platform.isAndroid) {
          await AndroidBackgroundManager.setEnabled(
            true,
            networkRequired: AndroidBackgroundManager.hasActiveGenerationHold,
          );
        }
        if (sheetContext.mounted) {
          ScaffoldMessenger.of(sheetContext).showSnackBar(
            SnackBar(
              content: Text(
                'MCP server start failed (port ${sp.mcpServerPort} in use?)',
              ),
            ),
          );
        }
        return;
      }
      // Android：MCP 常驻需要 FGS 保活——FGS 先启动（防冻结是目的），
      // 通知权限异步补发（权限弹窗无人响应时 await 会挂死，不能挡 FGS）。
      if (Platform.isAndroid) {
        try {
          await AndroidBackgroundManager.ensureInitialized(
            notificationTitle: l10n.androidBackgroundNotificationTitle,
            notificationText: l10n.androidBackgroundNotificationText,
          );
          await AndroidBackgroundManager.setEnabled(
            true,
            networkRequired: true,
          );
        } catch (_) {}
        NotificationService.ensureInitialized();
        final notificationsGranted =
            await NotificationService.ensureAndroidNotificationsPermission();
        if (notificationsGranted) {
          // 授予后重发前台通知：本页拉起的 FGS 通知首启即可见，无需杀后台重开。
          await AndroidBackgroundManager.refreshNotification();
        }
        // 电池优化未豁免时厂商 ROM（小米/华为等）后台仍会冻结进程——工具全失效。
        // 服务启动成功后引导一次豁免，拒绝不打扰。
        try {
          final ignored =
              await AndroidBackgroundManager.isIgnoringBatteryOptimizations();
          if (!ignored) {
            final granted =
                await AndroidBackgroundManager.requestIgnoreBatteryOptimizations();
            if (!granted && sheetContext.mounted) {
              ScaffoldMessenger.of(sheetContext).showSnackBar(
                const SnackBar(
                  content: Text('未豁免电池优化：部分系统后台可能冻结应用，导致 MCP 工具失效'),
                  duration: Duration(seconds: 4),
                ),
              );
            }
          } else if (await AndroidBackgroundManager.isKeepAliveOverlayEnabled() &&
              !await AndroidBackgroundManager.isOverlayPermissionGranted()) {
            await AndroidBackgroundManager.requestOverlayPermission();
          }
        } catch (_) {}
      }
    } else {
      await McpHttpServer.instance.stop();
      await sp.setMcpServerEnabled(false);
      // 后台聊天也关着、且无生成中的 agent 任务时才撤 FGS（防互杀）
      if (Platform.isAndroid &&
          sp.androidBackgroundChatMode == AndroidBackgroundChatMode.off &&
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
  }

  Future<void> savePort() async {
    final p = int.tryParse(portCtrl.text.trim());
    if (p == null || p < 1024 || p > 65535) return;
    final wasRunning = McpHttpServer.instance.isRunning;
    if (wasRunning) await McpHttpServer.instance.stop();
    await sp.setMcpServerPort(p);
    McpHttpServer.instance.configure(port: p);
    if (sp.mcpServerEnabled && wasRunning) {
      await McpHttpServer.instance.start();
    }
  }

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setSheetState) {
            final running = McpHttpServer.instance.isRunning;
            final authOn = sp.mcpServerAuthEnabled;
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                2,
                16,
                16 + MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Lucide.Network,
                          size: 18,
                          color: cs.primary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          l10n.mcpServerTitle,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: AppFontWeights.semibold,
                            color: cs.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '开启后进入 MCP 全屏页，外部 AI 可调用全部工具。',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: cs.onSurface.withValues(alpha: 0.62),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 服务器状态 + 端口
                  SettingsSectionCard(
                    children: [
                      _SheetRow(
                        icon: Lucide.Network,
                        label: running ? 'MCP 工具端已开启' : '启用 MCP 工具端',
                        detail: running
                            ? '服务正在运行，App 内 Agent 工具已暂停'
                            : '本机 Agent 正常可用',
                        iconColor: running ? context.appColors.success : null,
                        trailing: IosSwitch(
                          value: running,
                          onChanged: (v) async {
                            await applyEnabled(ctx, v);
                            if (v && ctx.mounted) {
                              Navigator.of(ctx).pop();
                              return;
                            }
                            setSheetState(() {});
                          },
                        ),
                      ),
                      settingsSectionDivider(ctx),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 36,
                              child: Icon(
                                Lucide.HardDrive,
                                size: 20,
                                color: cs.onSurface.withValues(alpha: 0.9),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                l10n.mcpServerPortLabel,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: AppFontWeights.medium,
                                  color: cs.onSurface.withValues(alpha: 0.9),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 76,
                              child: TextField(
                                controller: portCtrl,
                                keyboardType: TextInputType.number,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 14),
                                decoration: InputDecoration(
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 8,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                onSubmitted: (_) => savePort(),
                              ),
                            ),
                            TextButton(
                              onPressed: savePort,
                              child: Text(l10n.mcpServerSave),
                            ),
                          ],
                        ),
                      ),
                      settingsSectionDivider(ctx),
                      if (Platform.isAndroid) ...[
                        _SheetRow(
                          icon: Lucide.Layers,
                          label: '悬浮窗保活',
                          detail: overlayEnabled ? '退到后台时显示小标记' : '仅使用前台服务保活',
                          iconColor: overlayEnabled
                              ? context.appColors.success
                              : null,
                          trailing: IosSwitch(
                            value: overlayEnabled,
                            onChanged: (v) async {
                              await AndroidBackgroundManager.setKeepAliveOverlayEnabled(
                                v,
                              );
                              overlayEnabled = v;
                              if (v &&
                                  !await AndroidBackgroundManager.isOverlayPermissionGranted()) {
                                await AndroidBackgroundManager.requestOverlayPermission();
                              }
                              setSheetState(() {});
                            },
                          ),
                        ),
                        settingsSectionDivider(ctx),
                      ],
                      _SheetRow(
                        icon: Lucide.ShieldCheck,
                        label: l10n.mcpServerAuthTitle,
                        detail: authOn ? '连接时需要访问令牌' : '局域网内可直接连接',
                        iconColor: authOn ? context.appColors.success : null,
                        trailing: IosSwitch(
                          value: authOn,
                          onChanged: (v) async {
                            await sp.setMcpServerAuthEnabled(v);
                            McpHttpServer.instance.configure(
                              token: sp.mcpServerToken,
                            );
                            setSheetState(() {});
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      );
    },
  );
  portCtrl.dispose();
}

/// 弹窗内统一行样式：图标 + 标题/副标题 + 尾部控件（视觉对齐 SettingsActionRow）。
class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.icon,
    required this.label,
    this.detail,
    this.trailing,
    this.iconColor,
  });

  final IconData icon;
  final String label;
  final String? detail;
  final Widget? trailing;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = cs.onSurface.withValues(alpha: 0.9);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Icon(icon, size: 20, color: iconColor ?? color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.medium,
                    color: color,
                  ),
                ),
                if (detail != null && detail!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.35,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

// --- iOS-style tactile helpers ---

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
          Haptics.light();
          widget.onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: icon,
        ),
      ),
    );
  }
}

class _TactileRow extends StatefulWidget {
  const _TactileRow({
    required this.builder,
    this.onTap,
    this.pressedScale = 1.00,
    this.haptics = true,
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
  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => _set(true),
      onTapUp: widget.onTap == null ? null : (_) => _set(false),
      onTapCancel: widget.onTap == null ? null : () => _set(false),
      onTap: widget.onTap == null
          ? null
          : () {
              if (widget.haptics &&
                  context.read<SettingsProvider>().hapticsOnListItemTap) {
                Haptics.soft();
              }
              widget.onTap!.call();
            },
      child: widget.builder(_pressed),
    );
  }
}

class _AnimatedPressColor extends StatelessWidget {
  const _AnimatedPressColor({
    required this.pressed,
    required this.base,
    required this.builder,
  });
  final bool pressed;
  final Color base;
  final Widget Function(Color c) builder;
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
