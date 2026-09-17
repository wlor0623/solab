import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform, kIsWeb;
import 'dart:async';
import 'l10n/app_localizations.dart';
import 'features/home/pages/home_page.dart';
import 'features/mcp/pages/mcp_host_mode_page.dart';
import 'features/migration/hive_to_sqlite_migration_page.dart';
import 'features/migration/hive_to_sqlite_migration_service.dart';
import 'package:flutter/services.dart';
// import 'package:logging/logging.dart' as logging;
// Theme is now managed in SettingsProvider
import 'theme/theme_factory.dart';
import 'theme/palettes.dart';
import 'theme/custom_theme.dart';
import 'package:provider/provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'core/providers/user_provider.dart';
import 'core/providers/settings_provider.dart';
import 'core/providers/mcp_provider.dart';
import 'core/providers/tts_provider.dart';
import 'core/providers/asr_provider.dart';
import 'core/providers/assistant_provider.dart';
import 'core/providers/tag_provider.dart';
import 'core/providers/quick_phrase_provider.dart';
import 'core/providers/instruction_injection_provider.dart';
import 'core/providers/instruction_injection_group_provider.dart';
import 'core/providers/world_book_provider.dart';
import 'core/providers/agent_skill_provider.dart';
import 'core/providers/memory_provider.dart';
import 'core/providers/memory_provider_v2.dart';
import 'core/providers/backup_provider.dart';
import 'core/services/memory/memory_pipeline.dart';
import 'core/services/memory/memory_repository.dart';
import 'core/providers/s3_backup_provider.dart';
import 'core/providers/backup_reminder_provider.dart';
import 'core/database/database_installation_gate.dart';
import 'core/database/app_database.dart';
import 'core/database/business_migration_engine.dart';
import 'core/database/business_preferences.dart';
import 'core/database/business_repository.dart';
import 'core/database/business_startup_gate.dart';
import 'core/database/chat_database_gateway.dart';
import 'core/services/chat/chat_service.dart';
import 'core/services/backup/restore_archive_pruner.dart';
import 'core/services/backup/restore_business_lease.dart';
import 'core/services/backup/restore_startup_gate.dart';
import 'core/services/backup/restore_receipt.dart';
import 'core/services/mcp/mcp_tool_service.dart';
import 'core/services/mcp_server/mcp_http_server.dart';
import 'core/services/logging/flutter_logger.dart';
import 'features/home/services/ask_user_interaction_service.dart';
import 'features/home/services/tool_approval_service.dart';
import 'utils/app_directories.dart';
import 'utils/platform_utils.dart';
import 'utils/sandbox_path_resolver.dart';
import 'shared/widgets/app_overlays.dart';
import 'shared/widgets/snackbar.dart';
import 'shared/widgets/restore_failure_screen.dart';
import 'shared/widgets/restore_outcome_notice.dart';
import 'package:system_fonts/system_fonts.dart';
import 'dart:io'
    show
        Directory,
        File,
        Platform,
        stderr; // kept for global override usage inside provider
import 'core/services/android_background.dart';
import 'core/services/notification_service.dart';
import 'features/solab_apk/services/apk_memory_migration_service.dart';
import 'features/solab_apk/services/apk_progress_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

final RouteObserver<ModalRoute<dynamic>> routeObserver =
    RouteObserver<ModalRoute<dynamic>>();
// 更新检查已停用（SoLab APK 不依赖上游更新源），相关字段/Provider 一并移除。
bool _didEnsureAssistants = false; // ensure defaults after l10n ready
bool _didEnsureKeepAlive = false; // FGS/MCP server 启动只做一次（build 会重复注册回调）

Future<void> main() async {
  await runZoned(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      // Register notification tap handling for every Android launch. This is
      // independent of the current background-chat mode: an older completion
      // notification can still launch the app after the mode has changed.
      // Initialization does not request notification permission.
      if (Platform.isAndroid) {
        try {
          await NotificationService.ensureInitialized();
        } catch (_) {}
      }
      FlutterLogger.installGlobalHandlers();
      if (Platform.isAndroid) {
        // SoLab APK 原生分析进度监听（EventChannel 'solab/progress' 的消费方，
        // 此前进度事件发出后无任何监听方）。
        ApkProgressService.instance.ensureListening();
      }
      // 立即上首帧：后续初始化链（业务租约/恢复门/数据库准入）含重 IO，
      // 可能耗时数秒；先渲染零依赖启动页接管画面，避免引擎就绪后黑屏等待。
      runApp(const _StartupSplashApp());
      final appDataDirectory = await AppDirectories.getAppDataDirectory();
      final RestoreReceipt? restoreOutcome;
      try {
        // The lease remains process-owned through its internal registry until
        // process exit, preventing another instance from racing business I/O.
        //
        // 重试窗口：Android 前台服务保活下旧引擎/isolate 的销毁是异步的，
        // 退出后立即重开可能撞上尚未释放的 flock/探针。短暂重试（约 3 秒）
        // 覆盖该窗口，避免用户看到「已在运行」失败屏后被迫手动重启。
        final businessLease = await _acquireBusinessLeaseWithRetry(
          appDataDirectory,
        );
        restoreOutcome =
            await RestoreStartupGate.recoverAndRequireBusinessReady(
              appDataDirectory: appDataDirectory,
              businessLease: businessLease,
            );
      } catch (error, stackTrace) {
        stderr.writeln('[RestoreStartupGate] $error\n$stackTrace');
        runApp(
          _RestoreFailureApp(
            diagnosticCode: restoreFailureDiagnosticCode(error),
            appDataDirectory: appDataDirectory,
          ),
        );
        return;
      }
      try {
        final prefs = await SharedPreferences.getInstance();
        final enabled = prefs.getBool('flutter_log_enabled_v1') ?? false;
        await FlutterLogger.setEnabled(enabled);
      } catch (_) {}
      // Trim Flutter global image cache to reduce memory pressure from large images
      try {
        PaintingBinding.instance.imageCache.maximumSize = 200;
        PaintingBinding.instance.imageCache.maximumSizeBytes =
            48 << 20; // ~48MB
      } catch (_) {}
      // Avoid preloading all system fonts at launch (huge memory on desktop)
      // Debug logging and global error handlers were enabled previously for diagnosis.
      // They are commented out now per request to reduce log noise.
      // FlutterError.onError = (FlutterErrorDetails details) { ... };
      // WidgetsBinding.instance.platformDispatcher.onError = (Object error, StackTrace stack) { ... };
      // logging.Logger.root.level = logging.Level.ALL;
      // logging.Logger.root.onRecord.listen((rec) { ... });
      // Cache current Documents directory to fix sandboxed absolute paths on iOS
      await SandboxPathResolver.init();
      ChatDatabaseLease? processDatabaseLease;
      BusinessPreferences? businessPreferences;
      var recoveryAttempted = false;
      while (true) {
        try {
          final migrationDecision = await HiveToSqliteMigrationService.check();
          if (migrationDecision.needsMigration) {
            runApp(
              MigrationApp(
                service: HiveToSqliteMigrationService(migrationDecision),
                restoreOutcome: restoreOutcome?.state,
              ),
            );
            return;
          }
          await DatabaseInstallationGate.ensureReady(
            appDataDirectory: appDataDirectory,
            allowDatabaseIdentityChange:
                restoreOutcome?.selectedComponents.contains(
                  RestoreComponent.database,
                ) ??
                false,
          );
          final databaseFile = File(
            '${appDataDirectory.path}/${AppDatabase.databaseFileName}',
          );
          final databaseLease = await ChatDatabaseGateway.instance.acquire(
            databaseFile,
          );
          try {
            final legacyPreferences =
                await SharedPreferencesLegacyBusinessPreferences.open();
            final loadedBusinessPreferences =
                await BusinessStartupGate.migrateAndLoad(
                  repository: databaseLease.businessRepository,
                  legacyPreferences: legacyPreferences,
                );
            processDatabaseLease = databaseLease;
            businessPreferences = loadedBusinessPreferences;
          } catch (_) {
            await databaseLease.release();
            rethrow;
          }
          break;
        } catch (error, stackTrace) {
          stderr.writeln('[DatabaseAdmission] $error\n$stackTrace');
          if (!recoveryAttempted) {
            recoveryAttempted = true;
            final recovery = await _recoverFailedAdmission(
              appDataDirectory,
              error,
            );
            if (recovery == _AdmissionRecovery.remigrate) {
              runApp(
                MigrationApp(
                  service: HiveToSqliteMigrationService(
                    _legacyMigrationDecision(appDataDirectory),
                  ),
                  restoreOutcome: restoreOutcome?.state,
                ),
              );
              return;
            }
            if (recovery == _AdmissionRecovery.rebuilt) {
              continue;
            }
          }
          runApp(
            _RestoreFailureApp(
              diagnosticCode: restoreFailureDiagnosticCode(error),
              appDataDirectory: appDataDirectory,
            ),
          );
          return;
        }
      }
      // Best-effort trim of archived restore runs after a few cold starts.
      unawaited(_pruneRestoreArchive(appDataDirectory));
      // 一次性迁移：旧版 APK 经验/笔记（SharedPreferences blob）并入记忆系统 V1。
      // businessPreferences 在此处必非空（while 循环已赋值后才 break）。
      try {
        await ApkMemoryMigrationService.migrateIfNeeded(
          MemoryRepository(businessPreferences),
        );
      } catch (_) {
        // 迁移失败不阻塞启动；下次冷启动重试（migrationId 幂等）。
      }
      // Enable edge-to-edge to allow content under system bars (Android)
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      // MCP 服务依赖进程级注册：不经过 rootNavigatorKey.currentContext
      // （后台/Activity 被回收时 context 为 null，曾致 apk_note_write 等
      // 记忆类工具报 chat_service_unavailable）。
      final chatService = ChatService(
        existingRepository: processDatabaseLease.chatRepository,
      );
      final memoryRepository = MemoryRepository(businessPreferences);
      McpHttpServer.instance.configure(
        chatServiceGetter: () => chatService,
        memoryRepositoryGetter: () => memoryRepository,
        keepAliveEnsurer: () =>
            AndroidBackgroundManager.setEnabled(true, networkRequired: true),
      );
      // Start app (Flutter log capture is toggleable and off by default)
      runApp(
        MyApp(
          databaseLease: processDatabaseLease,
          businessPreferences: businessPreferences,
          chatService: chatService,
          memoryRepository: memoryRepository,
          restoreOutcome: restoreOutcome?.state,
        ),
      );
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        FlutterLogger.logPrint(line);
        parent.print(zone, line);
      },
      handleUncaughtError: (self, parent, zone, error, stackTrace) {
        // 兜底：未捕获异步异常只记录不静默，配合 PlatformDispatcher.onError
        // 返回 true 保证进程不因漏网异常直接闪退（stderr 在 logcat 可见）。
        try {
          stderr.writeln('[UncaughtZone] $error\n$stackTrace');
        } catch (_) {}
      },
    ),
  );
}

/// 业务租约重试获取：覆盖 Android 前台服务保活下旧引擎异步销毁的锁残留窗口。
Future<RestoreBusinessLease> _acquireBusinessLeaseWithRetry(
  Directory appDataDirectory, {
  int attempts = 10,
  Duration retryDelay = const Duration(milliseconds: 300),
}) async {
  Object? lastError;
  StackTrace? lastStack;
  for (var attempt = 0; attempt < attempts; attempt++) {
    try {
      return await RestoreBusinessLease.acquire(
        appDataDirectory: appDataDirectory,
      );
    } on RestoreBusinessLeaseUnavailable catch (error, stack) {
      lastError = error;
      lastStack = stack;
      if (attempt + 1 < attempts) {
        await Future<void>.delayed(retryDelay);
      }
    }
  }
  Error.throwWithStackTrace(lastError!, lastStack!);
}

enum _AdmissionRecovery { none, rebuilt, remigrate }

/// Names must mirror HiveToSqliteMigrationService.check().
const _legacyHiveSourceNames = <String>[
  'conversations.hive',
  'messages.hive',
  'tool_events_v1.hive',
];

bool _legacyHiveSourcesExist(Directory appDataDirectory) =>
    _legacyHiveSourceNames.any(
      (name) => File('${appDataDirectory.path}/$name').existsSync(),
    );

Future<_AdmissionRecovery> _recoverFailedAdmission(
  Directory appDataDirectory,
  Object error,
) async {
  final action = await DatabaseInstallationGate.recoveryActionFor(
    appDataDirectory: appDataDirectory,
    error: error,
    legacyHiveDataPresent: _legacyHiveSourcesExist(appDataDirectory),
  );
  switch (action) {
    case DatabaseRecoveryAction.rebuildAutomatically:
      try {
        await DatabaseInstallationGate.rebuildFresh(
          appDataDirectory: appDataDirectory,
        );
        return _AdmissionRecovery.rebuilt;
      } catch (rebuildError, rebuildStack) {
        stderr.writeln(
          '[DatabaseAdmission] rebuild failed: $rebuildError\n$rebuildStack',
        );
        return _AdmissionRecovery.none;
      }
    case DatabaseRecoveryAction.promptRemigration:
      return _AdmissionRecovery.remigrate;
    case DatabaseRecoveryAction.promptUpgrade:
    case DatabaseRecoveryAction.none:
      return _AdmissionRecovery.none;
  }
}

HiveToSqliteMigrationDecision _legacyMigrationDecision(
  Directory appDataDirectory,
) {
  return HiveToSqliteMigrationDecision(
    needsMigration: true,
    appDataDir: appDataDirectory,
    sqliteFile: File(
      '${appDataDirectory.path}/${AppDatabase.databaseFileName}',
    ),
    hiveFiles: [
      for (final name in _legacyHiveSourceNames)
        if (File('${appDataDirectory.path}/$name').existsSync())
          File('${appDataDirectory.path}/$name'),
    ],
  );
}

/// 启动占位页：main() 初始化链完成前的第一帧画面（零依赖，深浅色自适应）。
/// 初始化完成后由 MyApp / MigrationApp / _RestoreFailureApp 替换。
class _StartupSplashApp extends StatelessWidget {
  const _StartupSplashApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF2F6FED)),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF2F6FED),
        brightness: Brightness.dark,
      ),
      home: const Scaffold(body: Center(child: CircularProgressIndicator())),
    );
  }
}

class _RestoreFailureApp extends StatelessWidget {
  const _RestoreFailureApp({
    required this.diagnosticCode,
    this.appDataDirectory,
  });

  final String diagnosticCode;
  final Directory? appDataDirectory;

  @override
  Widget build(BuildContext context) {
    final palette = ThemePalettes.defaultPalette;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SoLab',
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: buildLightThemeForScheme(palette.light),
      darkTheme: buildDarkThemeForScheme(palette.dark),
      home: diagnosticCode == 'database_schema_too_new'
          ? _UpdateRequiredScreen(diagnosticCode: diagnosticCode)
          : RestoreFailureScreen(
              diagnosticCode: diagnosticCode,
              restart: PlatformUtils.restartApp,
              appDataDirectory: appDataDirectory,
            ),
    );
  }
}

/// Shown when the installed database was written by a newer app version;
/// restarting cannot help, so the only action is updating SoLab.
class _UpdateRequiredScreen extends StatelessWidget {
  const _UpdateRequiredScreen({required this.diagnosticCode});

  final String diagnosticCode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Material(
                color: colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: colors.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          Icons.system_update_alt_rounded,
                          size: 30,
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        l10n.startupDatabaseUpdateRequiredTitle,
                        style: textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        l10n.startupDatabaseUpdateRequiredContent,
                        style: textTheme.bodyLarge?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: SelectableText(
                          l10n.backupRestoreFailureDiagnostic(diagnosticCode),
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Removed eager system font preloading to reduce memory footprint at launch.

Future<void> _pruneRestoreArchive(Directory appDataDirectory) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    const key = RestoreArchivePruner.coldStartsKey;
    await RestoreArchivePruner(
      appDataDirectory: appDataDirectory,
      readColdStarts: () async => prefs.getInt(key) ?? 0,
      writeColdStarts: (count) => prefs.setInt(key, count),
    ).pruneAfterSuccessfulColdStart();
  } catch (_) {}
}

class MigrationApp extends StatelessWidget {
  const MigrationApp({super.key, required this.service, this.restoreOutcome});

  final HiveToSqliteMigrationService service;
  final RestoreReceiptState? restoreOutcome;

  @override
  Widget build(BuildContext context) {
    final palette = ThemePalettes.defaultPalette;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SoLab',
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: buildLightThemeForScheme(palette.light),
      darkTheme: buildDarkThemeForScheme(palette.dark),
      builder: (context, child) =>
          AppSnackBarOverlay(child: child ?? const SizedBox.shrink()),
      home: RestoreOutcomeNotice(
        outcome: restoreOutcome,
        child: HiveToSqliteMigrationPage(service: service),
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    required this.databaseLease,
    required this.businessPreferences,
    required this.chatService,
    required this.memoryRepository,
    this.restoreOutcome,
  });

  final ChatDatabaseLease databaseLease;
  final BusinessPreferences businessPreferences;
  final ChatService chatService;
  final MemoryRepository memoryRepository;
  final RestoreReceiptState? restoreOutcome;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<BusinessRepository>.value(
          value: databaseLease.businessRepository,
        ),
        Provider<BusinessPreferences>.value(value: businessPreferences),
        ChangeNotifierProvider(
          create: (_) => UserProvider(preferences: businessPreferences),
        ),
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(businessPreferences),
        ),
        ChangeNotifierProvider<ChatService>.value(value: chatService),
        ChangeNotifierProvider(create: (_) => McpToolService()),
        ChangeNotifierProvider(
          create: (_) => McpProvider(preferences: businessPreferences),
        ),
        ChangeNotifierProvider(create: (_) => ToolApprovalService()),
        ChangeNotifierProvider(create: (_) => AskUserInteractionService()),
        ChangeNotifierProvider(
          create: (ctx) => AssistantProvider(
            preferences: businessPreferences,
            chatService: ctx.read<ChatService>(),
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => TagProvider(preferences: businessPreferences),
        ),
        ChangeNotifierProvider(
          create: (_) => TtsProvider(preferences: businessPreferences),
        ),
        ChangeNotifierProvider(
          create: (ctx) =>
              AsrProvider(settingsProvider: ctx.read<SettingsProvider>()),
        ),
        ChangeNotifierProvider(
          create: (_) => QuickPhraseProvider(preferences: businessPreferences),
        ),
        ChangeNotifierProvider(
          create: (_) =>
              InstructionInjectionProvider(preferences: businessPreferences),
        ),
        ChangeNotifierProvider(
          create: (_) => InstructionInjectionGroupProvider(
            preferences: businessPreferences,
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => WorldBookProvider(preferences: businessPreferences),
        ),
        ChangeNotifierProvider(
          create: (_) => AgentSkillProvider(preferences: businessPreferences),
        ),
        ChangeNotifierProvider(
          create: (_) => MemoryProvider(preferences: businessPreferences),
        ),
        ChangeNotifierProvider(
          create: (_) => MemoryProviderV2(
            repository: memoryRepository,
            chatRepository: databaseLease.chatRepository,
          ),
        ),
        Provider<MemoryPipelineService>(
          create: (ctx) {
            final memoryV2 = ctx.read<MemoryProviderV2>();
            return MemoryPipelineService(
              chatService: ctx.read<ChatService>(),
              repository: memoryV2.repository,
              chatRepository: memoryV2.chatRepository,
              settings: () => ctx.read<SettingsProvider>(),
              assistants: () => ctx.read<AssistantProvider>(),
              memoryV2: () => ctx.read<MemoryProviderV2>(),
            );
          },
        ),
        ChangeNotifierProvider(
          create: (_) =>
              BackupReminderProvider(preferences: businessPreferences),
        ),
        ChangeNotifierProvider(
          create: (ctx) => BackupProvider(
            chatService: ctx.read<ChatService>(),
            businessRepository: databaseLease.businessRepository,
            businessPreferences: businessPreferences,
            initialConfig: ctx.read<SettingsProvider>().webDavConfig,
          ),
        ),
        ChangeNotifierProvider(
          create: (ctx) => S3BackupProvider(
            chatService: ctx.read<ChatService>(),
            businessRepository: databaseLease.businessRepository,
            businessPreferences: businessPreferences,
            initialConfig: ctx.read<SettingsProvider>().s3Config,
          ),
        ),
      ],
      child: Builder(
        builder: (context) {
          final settings = context.watch<SettingsProvider>();
          // Apply global proxy overrides when settings change
          settings.applyGlobalProxyOverridesIfNeeded();
          // Lazily ensure system fonts only if user selected a system family (desktop only)
          // Load ONLY selected families to avoid huge memory from loading all system fonts.
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            try {
              final isDesktop =
                  !kIsWeb &&
                  (defaultTargetPlatform == TargetPlatform.windows ||
                      defaultTargetPlatform == TargetPlatform.macOS ||
                      defaultTargetPlatform == TargetPlatform.linux);
              if (!isDesktop) return;
              // Selected system app/code fonts (not local alias)
              final wantsAppSystem =
                  (settings.appFontFamily?.isNotEmpty == true) &&
                  (settings.appFontLocalAlias == null ||
                      settings.appFontLocalAlias!.isEmpty);
              final wantsCodeSystem =
                  (settings.codeFontFamily?.isNotEmpty == true) &&
                  (settings.codeFontLocalAlias == null ||
                      settings.codeFontLocalAlias!.isEmpty);
              if (wantsAppSystem || wantsCodeSystem) {
                final sf = SystemFonts();
                if (wantsAppSystem) {
                  final fam = settings.appFontFamily!;
                  try {
                    await sf.loadFont(fam);
                  } catch (_) {}
                }
                if (wantsCodeSystem) {
                  final fam = settings.codeFontFamily!;
                  try {
                    if (fam != settings.appFontFamily) await sf.loadFont(fam);
                  } catch (_) {}
                }
              }
            } catch (_) {}
          });
          return DynamicColorBuilder(
            builder: (lightDynamic, darkDynamic) {
              // if (lightDynamic != null) {
              //   debugPrint('[DynamicColor] Light dynamic detected. primary=${lightDynamic.primary.value.toRadixString(16)} surface=${lightDynamic.surface.value.toRadixString(16)}');
              // } else {
              //   debugPrint('[DynamicColor] Light dynamic not available');
              // }
              // if (darkDynamic != null) {
              //   debugPrint('[DynamicColor] Dark dynamic detected. primary=${darkDynamic.primary.value.toRadixString(16)} surface=${darkDynamic.surface.value.toRadixString(16)}');
              // } else {
              //   debugPrint('[DynamicColor] Dark dynamic not available');
              // }
              final isAndroid =
                  Theme.of(context).platform == TargetPlatform.android;
              // Update dynamic color capability for settings UI (avoid notify during build)
              final dynSupported =
                  isAndroid && (lightDynamic != null || darkDynamic != null);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                try {
                  settings.setDynamicColorSupported(dynSupported);
                } catch (_) {}
              });

              // Android-only: ensure background execution matches setting and prepare notifications if needed
              if (!_didEnsureKeepAlive) {
                _didEnsureKeepAlive = true;
                final l10nKeepAlive = AppLocalizations.of(context);
                // 必须等 settings 加载完成：首轮 build 时 mcpServerEnabled 等
                // 异步配置还是默认值，守卫若先烧掉会导致 MCP server / FGS
                // 启动块永远不执行（弹窗路径启动时 getter 未注入）。
                settings.loaded.then((_) {
                  WidgetsBinding.instance.addPostFrameCallback((_) async {
                    try {
                      if (Platform.isAndroid) {
                        final mode = settings.androidBackgroundChatMode;
                        // 后台聊天或 MCP server 常驻都需要 FGS 保活
                        final needKeepAlive =
                            mode != AndroidBackgroundChatMode.off ||
                            settings.mcpServerEnabled;
                        if (needKeepAlive && context.mounted) {
                          // 保活优先：FGS 先启动（进程防冻结是目的，通知权限
                          // 只影响通知可见性）。权限请求异步补发——Android 13+
                          // 权限对话框无人响应时 await 会永久挂起，绝不能挡在
                          // FGS 启动前面（曾因此导致 MCP server 40 秒后被冻结）。
                          try {
                            await AndroidBackgroundManager.ensureInitialized(
                              notificationTitle: l10nKeepAlive
                                  ?.androidBackgroundNotificationTitle,
                              notificationText: l10nKeepAlive
                                  ?.androidBackgroundNotificationText,
                            );
                            await AndroidBackgroundManager.setEnabled(
                              true,
                              networkRequired: settings.mcpServerEnabled,
                            );
                          } catch (_) {}
                          // 通知权限不阻塞：FGS 已在跑，弹窗挂住/被拒都不影响保活。
                          // 授予后必须重发前台通知，否则首启被系统隐藏的
                          // 「软件保护」通知要杀后台重开才出现。
                          NotificationService.ensureInitialized();
                          final notificationsGranted =
                              await NotificationService.ensureAndroidNotificationsPermission();
                          if (notificationsGranted) {
                            await AndroidBackgroundManager.refreshNotification();
                          }
                          await AndroidBackgroundManager.requestKeepAlivePermissions();
                        } else if (context.mounted) {
                          await AndroidBackgroundManager.ensureInitialized();
                          await AndroidBackgroundManager.setEnabled(false);
                        }
                      }
                      // MCP server：先取得 FGS 保活，再绑定局域网端口，避免冷启动
                      // 暴露出会被系统冻结的无保活服务窗口。
                      if (settings.mcpServerEnabled) {
                        McpHttpServer.instance.configure(
                          port: settings.mcpServerPort,
                          token: settings.mcpServerToken,
                          assistantGetter: () => context
                              .read<AssistantProvider>()
                              .currentAssistant,
                          // chatService/memoryRepository 已在 main() 进程级
                          // 注册（后台 context 失效时仍可用），此处不再覆盖。
                          worldBookGetter: () =>
                              context.read<WorldBookProvider>(),
                          agentSkillGetter: () =>
                              context.read<AgentSkillProvider>(),
                          instructionInjectionGetter: () =>
                              context.read<InstructionInjectionProvider>(),
                        );
                        await McpHttpServer.instance.start();
                      }
                    } catch (_) {}
                  });
                });
              }

              final useDyn = isAndroid && settings.useDynamicColor;
              final custom = settings.selectedCustomTheme;
              final palette =
                  settings.themePaletteId == ThemePalettes.customPaletteId &&
                      custom != null
                  ? buildCustomThemePalette(custom)
                  : ThemePalettes.byId(settings.themePaletteId);

              final light = buildLightThemeForScheme(
                palette.light,
                dynamicScheme: useDyn ? lightDynamic : null,
                pureBackground: settings.usePureBackground,
              );
              final dark = buildDarkThemeForScheme(
                palette.dark,
                dynamicScheme: useDyn ? darkDynamic : null,
                pureBackground: settings.usePureBackground,
              );
              // Resolve effective app font family (system/local alias)
              String? effectiveAppFontFamily() {
                final fam = settings.appFontFamily;
                if (fam == null || fam.isEmpty) return null;
                return fam;
              }

              final effectiveAppFont = effectiveAppFontFamily();

              // Apply user-selected app font to theme text styles and app bar
              ThemeData applyAppFont(ThemeData base) {
                if (effectiveAppFont == null || effectiveAppFont.isEmpty) {
                  return base;
                }
                TextStyle? withFamily(TextStyle? s) =>
                    s?.copyWith(fontFamily: effectiveAppFont);
                TextTheme apply(TextTheme t) => t.copyWith(
                  displayLarge: withFamily(t.displayLarge),
                  displayMedium: withFamily(t.displayMedium),
                  displaySmall: withFamily(t.displaySmall),
                  headlineLarge: withFamily(t.headlineLarge),
                  headlineMedium: withFamily(t.headlineMedium),
                  headlineSmall: withFamily(t.headlineSmall),
                  titleLarge: withFamily(t.titleLarge),
                  titleMedium: withFamily(t.titleMedium),
                  titleSmall: withFamily(t.titleSmall),
                  bodyLarge: withFamily(t.bodyLarge),
                  bodyMedium: withFamily(t.bodyMedium),
                  bodySmall: withFamily(t.bodySmall),
                  labelLarge: withFamily(t.labelLarge),
                  labelMedium: withFamily(t.labelMedium),
                  labelSmall: withFamily(t.labelSmall),
                );
                final bar = base.appBarTheme;
                final appBar = bar.copyWith(
                  titleTextStyle: (bar.titleTextStyle ?? const TextStyle())
                      .copyWith(fontFamily: effectiveAppFont),
                  toolbarTextStyle: (bar.toolbarTextStyle ?? const TextStyle())
                      .copyWith(fontFamily: effectiveAppFont),
                );
                // Apply as default family to all text in ThemeData
                return base.copyWith(
                  textTheme: apply(base.textTheme),
                  primaryTextTheme: apply(base.primaryTextTheme),
                  appBarTheme: appBar,
                );
              }

              final themedLight = applyAppFont(light);
              final themedDark = applyAppFont(dark);
              // Log top-level colors likely used by widgets (card/bg/shadow approximations)
              // debugPrint('[Theme/App] Light scaffoldBg=${light.colorScheme.surface.value.toRadixString(16)} card≈${light.colorScheme.surface.value.toRadixString(16)} shadow=${light.colorScheme.shadow.value.toRadixString(16)}');
              // debugPrint('[Theme/App] Dark scaffoldBg=${dark.colorScheme.surface.value.toRadixString(16)} card≈${dark.colorScheme.surface.value.toRadixString(16)} shadow=${dark.colorScheme.shadow.value.toRadixString(16)}');
              return MaterialApp(
                debugShowCheckedModeBanner: false,
                title: 'SoLab',
                navigatorKey: rootNavigatorKey,
                // App UI language; null = follow system (respects iOS per-app language)
                locale: settings.appLocaleForMaterialApp,
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                theme: themedLight,
                darkTheme: themedDark,
                themeMode: settings.themeMode,
                navigatorObservers: <NavigatorObserver>[routeObserver],
                home: RestoreOutcomeNotice(
                  outcome: restoreOutcome,
                  child: _selectHome(),
                ),
                builder: (ctx, child) {
                  final bright = Theme.of(ctx).brightness;
                  final overlay = bright == Brightness.dark
                      ? const SystemUiOverlayStyle(
                          statusBarColor: Colors.transparent,
                          statusBarIconBrightness: Brightness.light,
                          statusBarBrightness: Brightness.dark,
                          systemNavigationBarColor: Colors.transparent,
                          systemNavigationBarIconBrightness: Brightness.light,
                          systemNavigationBarDividerColor: Colors.transparent,
                          systemNavigationBarContrastEnforced: false,
                        )
                      : const SystemUiOverlayStyle(
                          statusBarColor: Colors.transparent,
                          statusBarIconBrightness: Brightness.dark,
                          statusBarBrightness: Brightness.light,
                          systemNavigationBarColor: Colors.transparent,
                          systemNavigationBarIconBrightness: Brightness.dark,
                          systemNavigationBarDividerColor: Colors.transparent,
                          systemNavigationBarContrastEnforced: false,
                        );
                  // Ensure localized defaults (assistants and chat default title) after first frame
                  if (!_didEnsureAssistants) {
                    _didEnsureAssistants = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      try {
                        ctx.read<AssistantProvider>().ensureDefaults(ctx);
                      } catch (_) {}
                      try {
                        ctx.read<ChatService>().setDefaultConversationTitle(
                          AppLocalizations.of(
                            ctx,
                          )!.chatServiceDefaultConversationTitle,
                        );
                      } catch (_) {}
                      try {
                        ctx.read<UserProvider>().setDefaultNameIfUnset(
                          AppLocalizations.of(ctx)!.userProviderDefaultUserName,
                        );
                      } catch (_) {}
                    });
                  }

                  final mq = MediaQuery.of(ctx);
                  final display = View.of(ctx).display;
                  final displaySize = display.size / display.devicePixelRatio;
                  final isFloatingIpad =
                      defaultTargetPlatform == TargetPlatform.iOS &&
                      displaySize.shortestSide >= 600 &&
                      (mq.size.shortestSide < displaySize.shortestSide - 1 ||
                          mq.size.longestSide < displaySize.longestSide - 1);
                  final systemTop = mq.viewPadding.top;
                  final controlsTop = systemTop < 56 ? 56.0 : systemTop;
                  final appWithOverlays = MediaQuery(
                    data: isFloatingIpad
                        ? mq.copyWith(
                            padding: mq.padding.copyWith(top: controlsTop),
                            viewPadding: mq.viewPadding.copyWith(
                              top: controlsTop,
                            ),
                          )
                        : mq,
                    child: AppOverlays(child: child ?? const SizedBox.shrink()),
                  );
                  final gated = McpHostModeGate(child: appWithOverlays);
                  // Enforce app font as a default across the tree for Texts without explicit family
                  return AnnotatedRegion<SystemUiOverlayStyle>(
                    value: overlay,
                    child: effectiveAppFont == null
                        ? gated
                        : DefaultTextStyle.merge(
                            style: TextStyle(fontFamily: effectiveAppFont),
                            child: gated,
                          ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

Widget _selectHome() {
  // 仅保留移动端首页（已裁剪桌面端）
  return const HomePage();
}

// Overrides logic is implemented within SettingsProvider now.
