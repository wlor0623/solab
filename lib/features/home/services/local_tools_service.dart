import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:math_expressions/math_expressions.dart';
import 'package:path/path.dart' as p;
import '../../solab_apk/analyzer/analyzer_tools.dart';
import '../../../core/models/assistant.dart';
import '../../../core/providers/agent_skill_provider.dart';
import '../../../core/providers/instruction_injection_provider.dart';
import '../../../core/providers/world_book_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/local_tools/local_tool_names.dart';
import '../../../core/services/local_tools/local_tool_registry.dart';
import '../../../core/services/memory/memory_quality.dart';
import '../../../core/services/memory/memory_repository.dart';
import '../../solab_apk/services/apk_analysis_service.dart';
import '../../solab_apk/services/apk_mutation_preview_service.dart';
import '../../solab_apk/services/solab_apk_skills.dart';
import '../../solab_apk/services/apk_patch_memory_service.dart';
import '../../solab_apk/services/apk_workspace_binding_service.dart';
import '../../solab_apk/services/apk_project_service.dart';
import '../../solab_apk/services/apk_rule_service.dart';
import '../../solab_apk/services/apk_structural_service.dart';
import '../../solab_apk/services/apk_toolchain_service.dart';
import 'task_router.dart';
import 'tool_session_state.dart';
import '../../solab_apk/services/apk_workspace_service.dart';
part 'local_tool_schemas.dart';
part 'local_tool_handlers.dart';

typedef TextToSpeechStarter = Future<void> Function(String text);

typedef ToolHandler =
    Future<String?> Function(Map<String, dynamic> args, ToolContext context);

class ToolContext {
  const ToolContext({
    required this.assistant,
    this.chatService,
    this.memoryRepository,
    this.worldBookProvider,
    this.agentSkillProvider,
    this.instructionInjectionProvider,
    this.conversationId,
    this.onSpeakText,
    required this.analyzerContextKey,
  });

  final Assistant assistant;
  final ChatService? chatService;
  final MemoryRepository? memoryRepository;
  final WorldBookProvider? worldBookProvider;
  final AgentSkillProvider? agentSkillProvider;
  final InstructionInjectionProvider? instructionInjectionProvider;
  final String? conversationId;
  final TextToSpeechStarter? onSpeakText;
  final String analyzerContextKey;
}

/// 本地工具开关页 UI 元数据（工具 ID → 标题/简述）。
///
/// 与 [LocalToolsService.buildToolDefinitions] 的工具集合保持一致——
/// 新增工具时需同步登记，避免助手设置页缺失开关。
final Map<String, ({String title, String subtitle})> kLocalToolUiMetadata =
    LocalToolRegistry.uiMetadata;

class LocalToolsService {
  const LocalToolsService._();

  static String? _lastSyncedSoWorkDir;
  static const _apkCheckpointTools = <String>{
    LocalToolNames.routeTask,
    LocalToolNames.apkAnalyzeWorkspace,
    LocalToolNames.apkArchive,
    LocalToolNames.apkExportReport,
    LocalToolNames.dexSearch,
    LocalToolNames.stringScan,
    LocalToolNames.dexXref,
    LocalToolNames.classOutline,
    LocalToolNames.smaliRead,
    LocalToolNames.soAnalyze,
    LocalToolNames.jadxDecompile,
    LocalToolNames.apkPatchDex,
    LocalToolNames.apkSignatureBypass,
    LocalToolNames.apkPatchManifest,
    LocalToolNames.soPatchIntoApk,
    LocalToolNames.apkRebuild,
    LocalToolNames.apkSign,
  };

  static const _apkPathParameter = <String, Object>{
    'apkPath': {
      'type': 'string',
      'description':
          'Local APK path. Accepts either (1) an absolute path INSIDE the unified work directory (outside paths are rejected with PATH_OUTSIDE_WORKSPACE), or (2) a relative path / file name resolved against the work directory. If omitted, the latest patch output or analyzed source APK is used. Use file(action=list) to discover file names. If no work directory is set, stop and ask the user to set it in APK 工作台.',
    },
  };

  static List<Map<String, dynamic>> buildToolDefinitions({
    required Assistant? assistant,
    required bool supportsTools,
  }) => buildLocalToolSchemas(
    assistant: assistant,
    supportsTools: supportsTools,
    apkPathParameter: _apkPathParameter,
    deviceTimezoneHint: _deviceTimezoneHint,
  );

  static final Map<String, ToolHandler> _toolHandlers =
      Map<String, ToolHandler>.unmodifiable(<String, ToolHandler>{
        for (final name in AnalyzerToolNames.all)
          name: (args, context) =>
              _handleAnalyzerTool(name, args, context.analyzerContextKey),
        LocalToolNames.timeInfo: (args, context) => Future<String?>.value(
          jsonEncode(_buildTimeInfoPayload(DateTime.now())),
        ),
        LocalToolNames.clipboard: (args, context) => _handleClipboardTool(args),
        LocalToolNames.textToSpeech: (args, context) =>
            _handleTextToSpeechTool(args, context.onSpeakText),
        LocalToolNames.askUser: (args, context) => Future<String?>.value(null),
        LocalToolNames.calculate: (args, context) =>
            Future<String?>.value(_handleCalculateTool(args)),
        LocalToolNames.screenTime: (args, context) =>
            DeviceLocalTools.screenTimeSupported
            ? _invokeDeviceTool('getScreenTime', args)
            : Future<String?>.value(null),
        LocalToolNames.calendarQuery: (args, context) =>
            DeviceLocalTools.calendarSupported
            ? _invokeDeviceTool('queryCalendar', args)
            : Future<String?>.value(null),
        LocalToolNames.calendarCreate: (args, context) =>
            DeviceLocalTools.calendarSupported
            ? _invokeDeviceTool('createCalendarEvent', args)
            : Future<String?>.value(null),
        LocalToolNames.agentRuntimeGuide: (args, context) =>
            _handleAgentRuntimeGuide(
              args,
              context.assistant,
              context.memoryRepository,
              context.worldBookProvider,
              context.agentSkillProvider,
              context.instructionInjectionProvider,
            ),
        LocalToolNames.apkReport: (args, context) =>
            ApkWorkspaceService.readForAi(
              (args['section'] ?? 'summary').toString(),
              currentConversationId: context.conversationId,
            ),
        LocalToolNames.apkSkill: (args, context) => Future<String?>.value(
          SolabApkSkills.read((args['skill'] ?? '').toString()),
        ),
        LocalToolNames.apkKnowledge: (args, context) => _handleApkKnowledge(
          args,
          context.assistant,
          context.worldBookProvider,
          conversationId: context.conversationId,
        ),
        LocalToolNames.installedSkills: (args, context) =>
            _handleInstalledSkills(args, context.agentSkillProvider),
        LocalToolNames.apkProjectInfo: (args, context) =>
            _handleApkProjectInfo(context),
        LocalToolNames.apkRules: (args, context) =>
            _handleListApkRules(args, context.chatService),
        LocalToolNames.soPatchIntoApk: (args, context) => _handleSoPatchIntoApk(
          args,
          context.chatService,
          context.memoryRepository,
        ),
        LocalToolNames.apkPatchDex: (args, context) =>
            _handleApkPatchDex(args, context.chatService),
        LocalToolNames.apkSignatureBypass: (args, context) =>
            _handleApkSignatureBypass(args, context.chatService),
        LocalToolNames.apkPatchManifest: (args, context) =>
            _handleApkPatchManifest(
              args,
              context.chatService,
              context.memoryRepository,
            ),
        LocalToolNames.apkToolMap: (args, context) =>
            Future<String?>.value(_handleApkToolMap(context.assistant, args)),
        LocalToolNames.apkPatchMemory: (args, context) => _handleApkPatchMemory(
          args,
          context.chatService,
          context.memoryRepository,
        ),
        LocalToolNames.apkSavePatchMemory: (args, context) =>
            _handleApkSavePatchMemory(
              args,
              context.chatService,
              context.memoryRepository,
            ),
        LocalToolNames.apkRecordPatchVerification: (args, context) =>
            _handleApkRecordPatchVerification(
              args,
              context.chatService,
              context.memoryRepository,
            ),
        LocalToolNames.apkListBuilds: (args, context) => _handleApkListBuilds(),
        LocalToolNames.apkCleanupBuilds: (args, context) =>
            _handleApkCleanupBuilds(args),
        LocalToolNames.apkNoteRead: (args, context) => _handleApkNoteRead(),
        LocalToolNames.apkNoteWrite: (args, context) =>
            _handleApkNoteWrite(args),
        LocalToolNames.apkListWorkspace: (args, context) =>
            _handleApkListWorkspace(),
        LocalToolNames.apkAnalyzeWorkspace: (args, context) =>
            _handleApkAnalyzeWorkspace(
              args,
              context.chatService,
              context.conversationId,
            ),
        LocalToolNames.apkArchive: (args, context) => _handleApkArchive(args),
        LocalToolNames.apkExportReport: (args, context) =>
            _handleApkExportReport(args, context),
        LocalToolNames.jadxDecompile: (args, context) =>
            _handleJadxDecompile(args),
        LocalToolNames.apkSign: (args, context) => _handleApkSign(args),
        LocalToolNames.apkRebuild: (args, context) => _handleApkRebuild(args),
        LocalToolNames.dexSearch: (args, context) => _handleDexSearch(args),
        LocalToolNames.stringScan: (args, context) => _handleStringScan(args),
        LocalToolNames.dexXref: (args, context) =>
            _handleDexXref(args, context.chatService),
        LocalToolNames.classOutline: (args, context) =>
            _handleClassOutline(args),
        LocalToolNames.smaliRead: (args, context) => _handleSmaliRead(args),
        LocalToolNames.soAnalyze: (args, context) => _handleSoAnalyze(args),
        LocalToolNames.file: (args, context) => _handleFileUnified(args),
        LocalToolNames.routeTask: _handleRouteTask,
      });

  static Set<String> get handledToolNames =>
      Set<String>.unmodifiable(_toolHandlers.keys);

  static Future<String?> tryHandleToolCall(
    String name,
    Map<String, dynamic> args,
    Assistant? assistant, {
    TextToSpeechStarter? onSpeakText,
    ChatService? chatService,
    WorldBookProvider? worldBookProvider,
    AgentSkillProvider? agentSkillProvider,
    InstructionInjectionProvider? instructionInjectionProvider,
    String? conversationId,
    MemoryRepository? memoryRepository,
    String analyzerContextKey = 'app',
  }) async {
    if (assistant == null || !assistant.localToolIds.contains(name)) {
      return null;
    }
    final context = ToolContext(
      assistant: assistant,
      chatService: chatService,
      memoryRepository: memoryRepository,
      worldBookProvider: worldBookProvider,
      agentSkillProvider: agentSkillProvider,
      instructionInjectionProvider: instructionInjectionProvider,
      conversationId: conversationId,
      onSpeakText: onSpeakText,
      analyzerContextKey: analyzerContextKey,
    );
    final handler = _toolHandlers[name];
    if (handler != null) {
      final scopeId = conversationId?.trim().isNotEmpty == true
          ? conversationId
          : (analyzerContextKey == 'app' ? null : analyzerContextKey);
      return ApkWorkspaceBindingService.runInScope(scopeId, () async {
        final output = await handler(args, context);
        if (output != null &&
            assistant.id == 'builtin-apk-mod' &&
            _apkCheckpointTools.contains(name)) {
          try {
            await ApkWorkspaceBindingService.recordToolCheckpoint(
              tool: name,
              arguments: args,
              result: output,
            );
          } catch (_) {
            // 续接快照失败不影响工具本身的结果。
          }
        }
        return output;
      });
    }
    return null;
  }
}
