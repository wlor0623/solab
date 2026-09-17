import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/message_part.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/logging/context_logger.dart';
import '../../../core/services/search/search_tool_service.dart';
import '../../../core/utils/multimodal_input_utils.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../../utils/assistant_regex.dart';
import '../../../core/models/assistant_regex.dart';
import '../../solab_apk/services/apk_agent_policy.dart';
import '../controllers/stream_controller.dart' as stream_ctrl;
import '../controllers/generation_controller.dart';
import 'ask_user_interaction_service.dart';
import 'message_builder_service.dart';
import 'tool_approval_service.dart';
import 'tool_handler_service.dart';
import 'tool_router.dart';

/// Callback types for UI updates from MessageGenerationService
typedef OnMessagesChanged = void Function();
typedef OnConversationLoadingChanged =
    void Function(String conversationId, bool loading);
typedef OnScrollToBottom = void Function();
typedef OnShowError = void Function(String message);
typedef OnShowWarning = void Function(String message);
typedef OnHapticFeedback = void Function();

const String conversationIdHeaderName = 'X-Conversation-Id';
const String _conversationIdHeaderNameLower = 'x-conversation-id';

Map<String, String>? buildConversationRequestHeaders({
  required String conversationId,
  Map<String, String>? customHeaders,
}) {
  final headers = <String, String>{
    if (customHeaders != null)
      for (final entry in customHeaders.entries)
        if (entry.key.toLowerCase() != _conversationIdHeaderNameLower)
          entry.key: entry.value,
  };
  final normalizedConversationId = conversationId.trim();
  if (normalizedConversationId.isNotEmpty) {
    headers[conversationIdHeaderName] = normalizedConversationId;
  }
  return headers.isEmpty ? null : headers;
}

/// Result of preparing a message generation
class PreparedGeneration {
  final List<Map<String, dynamic>> apiMessages;
  final List<Map<String, dynamic>> toolDefs;
  final ToolCallHandler? onToolCall;
  final bool hasBuiltInSearch;
  final List<String> lastUserImagePaths;

  /// 动态工具扩容（流程图①）：每个 follow-up 轮次前重算工具声明。
  /// 见 [ToolExpansion] / Router 的 Tier 规则。
  final List<Map<String, dynamic>>? Function()? toolsOf;

  PreparedGeneration({
    required this.apiMessages,
    required this.toolDefs,
    this.onToolCall,
    required this.hasBuiltInSearch,
    required this.lastUserImagePaths,
    this.toolsOf,
  });
}

/// Service for handling message generation orchestration.
///
/// This service coordinates:
/// - Message creation (user + assistant placeholder)
/// - API message preparation with all injections
/// - Stream execution and management
/// - Reasoning state initialization
///
/// UI updates are communicated through callbacks to maintain separation.
class MessageGenerationService {
  MessageGenerationService({
    required this.chatService,
    required this.messageBuilderService,
    required this.generationController,
    required this.streamController,
    required this.contextProvider,
  });

  final ChatService chatService;
  final MessageBuilderService messageBuilderService;
  final GenerationController generationController;
  final stream_ctrl.StreamController streamController;
  final BuildContext contextProvider;

  /// 取最近一条真实用户消息文本（跳过历史总结/注入行）。
  static String _latestUserText(List<ChatMessage> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role != 'user') continue;
      if (m.id.startsWith('context-summary-')) continue;
      final text = m.content.trim();
      if (text.isEmpty) continue;
      return text;
    }
    return '';
  }

  // Callbacks for UI updates (set by home_page)
  OnMessagesChanged? onMessagesChanged;
  OnConversationLoadingChanged? onConversationLoadingChanged;
  OnScrollToBottom? onScrollToBottom;
  OnShowError? onShowError;
  OnShowWarning? onShowWarning;
  OnHapticFeedback? onHapticFeedback;

  /// Called when file processing starts for the assistant message [messageId].
  void Function(String messageId)? onFileProcessingStarted;

  /// Called when file processing finishes. A null [messageId] clears whichever
  /// message currently owns the indicator (error/cancel cleanup paths).
  void Function(String? messageId)? onFileProcessingFinished;

  /// Check if reasoning is enabled for given budget
  bool isReasoningEnabled(int? budget) {
    if (budget == null) return true;
    if (budget == -1) return true;
    return budget >= 1024;
  }

  /// Prepare API messages with all injections applied.
  Future<PreparedGeneration> prepareApiMessagesWithInjections({
    required List<ChatMessage> messages,
    required Map<String, int> versionSelections,
    required Conversation? currentConversation,
    required SettingsProvider settings,
    required Assistant? assistant,
    required String? assistantId,
    required String providerKey,
    required String modelId,
    ToolApprovalService? approvalService,
    AskUserInteractionService? askUserService,
    String? processingMessageId,
  }) async {
    final cfg = settings.getProviderConfig(providerKey);
    final kind = ProviderConfig.classify(
      providerKey,
      explicitType: cfg.providerType,
    );
    final includeToolMessages = switch (kind) {
      ProviderKind.openai || ProviderKind.claude || ProviderKind.google => true,
    };

    // Build API messages
    final apiMessages = messageBuilderService.buildApiMessages(
      messages: messages,
      versionSelections: versionSelections,
      currentConversation: currentConversation,
      includeToolMessages: includeToolMessages,
    );

    // Apply assistant replace-only regexes at send-time (visual stays unchanged).
    if (assistant != null && assistant.regexRules.isNotEmpty) {
      for (int i = 0; i < apiMessages.length; i++) {
        final role = (apiMessages[i]['role'] ?? '').toString();
        if (role != 'assistant') continue;
        final raw = (apiMessages[i]['content'] ?? '').toString();
        if (raw.isEmpty) continue;
        apiMessages[i]['content'] = applyAssistantRegexes(
          raw,
          assistant: assistant,
          scope: AssistantRegexScope.assistant,
          target: AssistantRegexTransformTarget.send,
        );
      }
    }

    // Inject prompts first so WorldBook can scan the full untrimmed history
    // (same keyword trigger range as before OCR-after-trim). Document/OCR work
    // runs only after the single final context trim below.
    // 先做意图分类（流程图①）：apk_task→Totier0+Tier1（随后 route_task 定
    // 轨道追加 Tier2），chat→ 只挂 Tier0；决定系统提示注入哪一段（⑦）。
    final latestUserText = _latestUserText(messages);
    final isCasual = ToolRouter.isCasualText(latestUserText);
    final restoredRoute = ToolRouter.latestValidRouteResult(apiMessages);
    final apkTask =
        ToolRouter.isApkTaskIntent(latestUserText) ||
        ToolRouter.shouldResumeApkTask(
          hasValidRoute: restoredRoute != null,
          userText: latestUserText,
        );
    final toolExpansion = ToolExpansion(
      apkTask: apkTask,
      executionMode: ApkAgentPolicy.executionModeFor(latestUserText),
    );
    if (restoredRoute != null && apkTask) {
      toolExpansion.applyTrackText(restoredRoute);
    }
    final toolPolicy = apkTask
        ? ToolLoadPolicy.full
        : isCasual
        ? ToolLoadPolicy.none
        : ToolLoadPolicy.light;
    messageBuilderService.injectSystemPrompt(
      apiMessages,
      assistant,
      modelId,
      systemPromptOverride: toolPolicy == ToolLoadPolicy.none
          ? AssistantProvider.apkModSystemPromptCore
          : null,
    );
    await messageBuilderService.injectMemoryAndRecentChats(
      apiMessages,
      assistant,
      settings: settings,
      currentConversationId: currentConversation?.id,
    );

    final hasBuiltInSearch = messageBuilderService.hasBuiltInSearch(
      settings,
      providerKey,
      modelId,
    );
    messageBuilderService.injectSearchPrompt(
      apiMessages,
      settings,
      assistant,
      hasBuiltInSearch,
    );
    final supportsFunctionTools = generationController.isToolModel(
      providerKey,
      modelId,
    );
    if (assistant?.searchEnabled == true &&
        !hasBuiltInSearch &&
        !supportsFunctionTools &&
        requiresOnlineLookup(latestUserText)) {
      final searchResult = await SearchToolService.executeSearch(
        latestUserText,
        settings,
      );
      try {
        final decoded = jsonDecode(searchResult);
        if (decoded is Map && decoded['items'] is List) {
          messageBuilderService.injectSearchFallbackResult(
            apiMessages,
            searchResult,
          );
        }
      } catch (_) {}
    }
    // 闲聊轮（none）：系统提示已换成 140 字符 core，指令注入一并跳过——
    // 「你好」轮不需要背上 862 字符的 APK 修改纪律（与 core 替换同一设计意图）。
    if (toolPolicy != ToolLoadPolicy.none) {
      await messageBuilderService.injectInstructionPrompts(
        apiMessages,
        assistantId,
      );
    }
    await messageBuilderService.injectWorldBookPrompts(
      apiMessages,
      assistantId,
    );

    // Single final trim after WorldBook TOP/BOTTOM/AT_DEPTH injections. OCR and
    // document extraction must run only on this retained set so images that will
    // not be sent are never processed (#769).
    messageBuilderService.applyContextLimit(apiMessages, assistant);

    // Only this step does the actual attachment work (document extraction and
    // OCR), so the indicator must not cover the injection/trim passes above —
    // and it only claims to be parsing files when the retained messages really
    // carry files to parse. A text-only send that is merely slow (frozen prompt
    // reads, memory injection, templating) must never show the bar.
    final indicatorMessageId =
        processingMessageId != null &&
            messageBuilderService.hasPendingAttachmentWork(
              apiMessages,
              settings,
              conversation: currentConversation,
              sourceMessages: messages,
            )
        ? processingMessageId
        : null;
    final List<String> lastUserImagePaths;
    if (indicatorMessageId != null) {
      onFileProcessingStarted?.call(indicatorMessageId);
    }
    try {
      lastUserImagePaths = await messageBuilderService
          .processUserMessagesForApi(
            apiMessages,
            settings,
            assistant,
            conversation: currentConversation,
            sourceMessages: messages,
          );
    } finally {
      if (indicatorMessageId != null) {
        onFileProcessingFinished?.call(indicatorMessageId);
      }
    }

    await messageBuilderService.inlineLocalImages(apiMessages);
    if (ContextLogger.enabled) {
      final providerName = cfg.name.trim();
      ContextLogger.logPrepared(
        apiMessages: apiMessages,
        conversationId: currentConversation?.id ?? '',
        assistantName: assistant?.name ?? '',
        provider: providerName.isNotEmpty ? providerName : providerKey,
        model: modelId,
      );
    }
    messageBuilderService.stripInternalRevisionIds(apiMessages);

    // Prepare tools（流程图① 动态分层：chat→Tier0；apk_task→Tier0+Tier1；
    // route_task 返回轨道后追加 Tier2；发生修改后追加 Tier3）。
    final mcpRouteSnapshot = generationController.captureMcpToolRoutes(
      assistant,
    );
    var externalMcpRequested =
        RegExp(
          r'\b(?:mcp|mt)\b',
          caseSensitive: false,
        ).hasMatch(latestUserText) ||
        latestUserText.contains('外部工具') ||
        latestUserText.contains('外接工具') ||
        latestUserText.contains('外部服务器');
    List<Map<String, dynamic>> buildDefs() {
      // 真实实现「所有工具可单独调用」：用户消息里点名/直接提到的已启用
      // 工具，一律挂载（即使不在当前 tier 路由里）——用户说用什么就调什么，
      // 不靠路由猜。其余仍按 tier 规则。
      final mentioned = _mentionedToolNames(
        latestUserText,
        assistant?.localToolIds.toSet() ?? const <String>{},
      );
      final routed = ToolRouter.resolveForExpansion(
        initialPolicy: toolPolicy,
        expansion: toolExpansion,
        userText: latestUserText,
      );
      return generationController.buildToolDefinitions(
        settings,
        assistant,
        providerKey,
        modelId,
        hasBuiltInSearch,
        mcpRouteSnapshot: mcpRouteSnapshot,
        includeExternalMcpTools: externalMcpRequested,
        includeToolNames: {...routed, ...mentioned},
      );
    }
    final toolDefs = buildDefs();
    Set<String> currentToolNames() => buildDefs()
        .map(
          (definition) =>
              ((definition['function'] as Map?)?['name'] ?? '').toString(),
        )
        .where((name) => name.isNotEmpty)
        .toSet();
    if (ContextLogger.enabled) {
      // ⑧ 请求 Token 预算：分项统计系统/工具/历史/用户/工具结果。
      ToolBudgetReport.report(
        apiMessages: apiMessages,
        tools: toolDefs,
        policy: toolPolicy,
      );
    }
    final baseHandler = toolDefs.isEmpty
        ? null
        : generationController.buildToolCallHandler(
            settings,
            assistant,
            approvalService: approvalService,
            askUserService: askUserService,
            conversationId: currentConversation?.id,
            mcpRouteSnapshot: mcpRouteSnapshot,
            availableToolNames: currentToolNames,
          );
    // 外层包装：每次工具执行后按返回更新扩容状态（route_task→Tier2 轨道；
    // 修改风格工具→Tier3），使下一 follow-up 轮自动带上新工具。
    final onToolCall = baseHandler == null
        ? null
        : (String name, Map<String, dynamic> args, {String? toolCallId}) async {
            final content = await baseHandler(
              name,
              args,
              toolCallId: toolCallId,
            );
            if (name == ToolHandlerService.externalMcpCatalogTool) {
              externalMcpRequested = true;
            }
            _applyToolExpansion(
              toolExpansion,
              name,
              content is String ? content : jsonEncode(content),
            );
            return content;
          };
    // SoLab APK 报告注入放在工具判定之后：provider 支持工具时只注入轻量提示
    //（完整 decision 由 get_current_apk_report 按需读取），避免每条消息重复
    // 注入全量决策上下文；当前会话 ID 用于跨对话感知标注。
    // 闲聊轮整体跳过：toolPolicy=none 时 toolDefs 恒为空，若不跳过会把
    // 「闲聊意图」误判成「provider 不支持工具」而注入全量 decision 报告。
    // 内置 APK 助手只注入轻量续接快照，避免一句补充指令打断后丢失修改状态。
    if (toolPolicy != ToolLoadPolicy.none ||
        assistant?.id == 'builtin-apk-mod') {
      await messageBuilderService.injectApkWorkspacePrompt(
        apiMessages,
        assistant,
        supportsTools: toolDefs.isNotEmpty,
        resumeOnly: toolPolicy == ToolLoadPolicy.none,
        conversationId: currentConversation?.id,
      );
    }

    return PreparedGeneration(
      apiMessages: apiMessages,
      toolDefs: toolDefs,
      onToolCall: onToolCall,
      hasBuiltInSearch: hasBuiltInSearch,
      lastUserImagePaths: lastUserImagePaths,
      toolsOf: toolDefs.isEmpty ? null : buildDefs,
    );
  }

  /// 按工具执行结果更新扩容状态（流程图①）。
  static void _applyToolExpansion(
    ToolExpansion expansion,
    String name,
    String result,
  ) {
    if (name == 'route_task') {
      expansion.applyTrackText(result);
    } else if (name == 'analyze_apk_workspace') {
      expansion.applyWorkspaceAnalysisText(result);
    } else if (ToolRouter.modifyToolNames.contains(name)) {
      expansion.markCompletion();
    }
  }

  /// Create user message from input data.
  Future<ChatMessage> createUserMessage({
    required String conversationId,
    required ChatInputData input,
    required Assistant? assistant,
  }) async {
    final parts = await MessageGenerationService.buildPersistedUserMessageParts(
      input,
      assistant: assistant,
    );
    return chatService.addMessage(
      conversationId: conversationId,
      role: 'user',
      parts: parts,
    );
  }

  Future<
    ({ChatMessage userMessage, ChatMessage assistantMessage, String? runId})
  >
  beginSendGeneration({
    required String conversationId,
    required ChatInputData input,
    required Assistant? assistant,
    required String modelId,
    required String providerKey,
  }) async {
    final userParts = await buildPersistedUserMessageParts(
      input,
      assistant: assistant,
    );
    if (chatService.isTemporaryConversation(conversationId)) {
      final userMessage = await chatService.addMessage(
        conversationId: conversationId,
        role: 'user',
        parts: userParts,
      );
      final assistantMessage = await createAssistantPlaceholder(
        conversationId: conversationId,
        modelId: modelId,
        providerKey: providerKey,
      );
      return (
        userMessage: userMessage,
        assistantMessage: assistantMessage,
        runId: null,
      );
    }
    final result = await chatService.beginSendGeneration(
      conversationId: conversationId,
      userParts: userParts,
      modelId: modelId,
      providerId: providerKey,
    );
    return (
      userMessage: result.userMessage!,
      assistantMessage: result.assistantMessage,
      runId: result.run.id,
    );
  }

  Future<({ChatMessage assistantMessage, String? runId})> beginRegeneration({
    required String conversationId,
    required String modelId,
    required String providerKey,
    required String groupId,
    required int version,
    required bool truncateFuture,
  }) async {
    if (chatService.isTemporaryConversation(conversationId)) {
      final assistantMessage = await createAssistantPlaceholder(
        conversationId: conversationId,
        modelId: modelId,
        providerKey: providerKey,
        groupId: groupId,
        version: version,
      );
      return (assistantMessage: assistantMessage, runId: null);
    }
    final result = await chatService.beginRegeneration(
      conversationId: conversationId,
      modelId: modelId,
      providerId: providerKey,
      groupId: groupId,
      version: version,
      truncateFuture: truncateFuture,
    );
    return (assistantMessage: result.assistantMessage, runId: result.run.id);
  }

  Future<({ChatMessage assistantMessage, String? runId})>
  beginAssistantGeneration({
    required String conversationId,
    required String modelId,
    required String providerKey,
    required String anchorGroupId,
    required bool truncateFuture,
  }) async {
    if (chatService.isTemporaryConversation(conversationId)) {
      final assistantMessage = await createAssistantPlaceholder(
        conversationId: conversationId,
        modelId: modelId,
        providerKey: providerKey,
        temporaryAfterGroupId: anchorGroupId,
      );
      return (assistantMessage: assistantMessage, runId: null);
    }
    final result = await chatService.beginAssistantGeneration(
      conversationId: conversationId,
      modelId: modelId,
      providerId: providerKey,
      anchorGroupId: anchorGroupId,
      truncateFuture: truncateFuture,
    );
    return (assistantMessage: result.assistantMessage, runId: result.run.id);
  }

  /// Build structured parts for a persisted user message.
  ///
  /// Text is always present (possibly empty). Attachments follow in the
  /// user's selection order. No legacy attachment markers are produced.
  static Future<List<MessagePart>> buildPersistedUserMessageParts(
    ChatInputData input, {
    required Assistant? assistant,
  }) async {
    final processedUserText = applyAssistantRegexes(
      input.text.trim(),
      assistant: assistant,
      scope: AssistantRegexScope.user,
      target: AssistantRegexTransformTarget.persist,
    );

    final parts = <MessagePart>[TextPart(processedUserText)];
    for (final path in input.imagePaths) {
      parts.add(
        ImagePart(
          uri: SandboxPathResolver.canonicalize(path),
          mime: await inferAttachmentMime(uri: path),
        ),
      );
    }
    for (final document in input.documents) {
      parts.add(
        FilePart(
          uri: SandboxPathResolver.canonicalize(document.path),
          name: document.fileName,
          mime: await inferAttachmentMime(
            uri: document.path,
            explicitMime: document.mime,
            fileName: document.fileName,
          ),
        ),
      );
    }
    return parts;
  }

  /// Derived text body for callers that still need a plain string.
  static Future<String> buildPersistedUserMessageContent(
    ChatInputData input, {
    required Assistant? assistant,
  }) async {
    final parts = await buildPersistedUserMessageParts(
      input,
      assistant: assistant,
    );
    return parts.whereType<TextPart>().map((part) => part.text).join();
  }

  /// Create assistant message placeholder.
  Future<ChatMessage> createAssistantPlaceholder({
    required String conversationId,
    required String modelId,
    required String providerKey,
    String? groupId,
    int version = 0,
    String? temporaryAfterGroupId,
  }) async {
    return chatService.addMessage(
      conversationId: conversationId,
      role: 'assistant',
      content: '',
      modelId: modelId,
      providerId: providerKey,
      isStreaming: true,
      groupId: groupId,
      version: version,
      selectVersion: groupId != null,
      temporaryAfterGroupId: temporaryAfterGroupId,
    );
  }

  /// Initialize reasoning state for a message if reasoning is enabled.
  Future<void> initializeReasoningState({
    required String messageId,
    required bool enableReasoning,
  }) async {
    if (enableReasoning) {
      final rd = stream_ctrl.ReasoningData();
      streamController.reasoning[messageId] = rd;
      await chatService.updateMessage(
        messageId,
        reasoningStartAt: DateTime.now(),
      );
    }
  }

  /// Build GenerationContext for streaming.
  stream_ctrl.GenerationContext buildGenerationContext({
    required ChatMessage assistantMessage,
    required PreparedGeneration prepared,
    required List<String> userImagePaths,
    required bool allowImagesApiRouting,
    required String providerKey,
    required String modelId,
    required Assistant? assistant,
    required SettingsProvider settings,
    required bool supportsReasoning,
    required bool enableReasoning,
    required bool generateTitleOnFinish,
    String? generationRunId,
  }) {
    final bool ocrActive =
        settings.ocrEnabled &&
        settings.ocrModelProvider != null &&
        settings.ocrModelId != null;

    return stream_ctrl.GenerationContext(
      assistantMessage: assistantMessage,
      apiMessages: prepared.apiMessages,
      userImagePaths: userImagePaths,
      allowImagesApiRouting: allowImagesApiRouting,
      providerKey: providerKey,
      modelId: modelId,
      assistant: assistant,
      settings: settings,
      config: settings.getProviderConfig(providerKey),
      toolDefs: prepared.toolDefs,
      onToolCall: prepared.onToolCall,
      toolsOf: prepared.toolsOf,
      extraHeaders: buildConversationRequestHeaders(
        conversationId: assistantMessage.conversationId,
        customHeaders: generationController.buildCustomHeaders(assistant),
      ),
      extraBody: generationController.buildCustomBody(assistant),
      supportsReasoning: supportsReasoning,
      enableReasoning: enableReasoning,
      streamOutput: assistant?.streamOutput ?? true,
      ocrActive: ocrActive,
      generateTitleOnFinish: generateTitleOnFinish,
      generationRunId: generationRunId,
    );
  }

  /// Get current model and provider from assistant or global settings.
  ({String? providerKey, String? modelId}) getModelConfig(
    SettingsProvider settings,
    Assistant? assistant,
  ) {
    return (
      providerKey:
          assistant?.chatModelProvider ?? settings.currentModelProvider,
      modelId: assistant?.chatModelId ?? settings.currentModelId,
    );
  }

  /// Calculate version info for regeneration.
  ({String? targetGroupId, int nextVersion, int lastKeep})
  calculateRegenerationVersioning({
    required ChatMessage message,
    required List<ChatMessage> messages,
    required bool assistantAsNewReply,
  }) {
    final idx = messages.indexWhere((m) => m.id == message.id);
    if (idx < 0) {
      return (targetGroupId: null, nextVersion: 0, lastKeep: -1);
    }

    String? targetGroupId;
    int nextVersion = 0;
    int lastKeep;

    if (message.role == 'assistant') {
      lastKeep = idx;
      if (assistantAsNewReply) {
        targetGroupId = null;
        nextVersion = 0;
      } else {
        targetGroupId = message.groupId ?? message.id;
        int maxVer = -1;
        for (final m in messages) {
          final gid = (m.groupId ?? m.id);
          if (gid == targetGroupId) {
            if (m.version > maxVer) maxVer = m.version;
          }
        }
        nextVersion = maxVer + 1;
      }
    } else {
      // User message
      final userGroupId = message.groupId ?? message.id;
      int userFirst = -1;
      for (int i = 0; i < messages.length; i++) {
        final gid0 = (messages[i].groupId ?? messages[i].id);
        if (gid0 == userGroupId) {
          userFirst = i;
          break;
        }
      }
      if (userFirst < 0) userFirst = idx;

      int aid = -1;
      for (int i = userFirst + 1; i < messages.length; i++) {
        final candidateGroupId = messages[i].groupId ?? messages[i].id;
        if (candidateGroupId == userGroupId) continue;
        if (messages[i].role == 'assistant') {
          aid = i;
        }
        break;
      }

      if (aid >= 0) {
        lastKeep = aid;
        targetGroupId = messages[aid].groupId ?? messages[aid].id;
        int maxVer = -1;
        for (final m in messages) {
          final gid = (m.groupId ?? m.id);
          if (gid == targetGroupId) {
            if (m.version > maxVer) maxVer = m.version;
          }
        }
        nextVersion = maxVer + 1;
      } else {
        lastKeep = userFirst;
        targetGroupId = null;
        nextVersion = 0;
      }
    }

    return (
      targetGroupId: targetGroupId,
      nextVersion: nextVersion,
      lastKeep: lastKeep,
    );
  }

  /// Remove trailing messages after regeneration cut point.
  @visibleForTesting
  static List<String> collectTrailingMessageIdsForRemoval({
    required List<ChatMessage> messages,
    required int lastKeep,
    required String? targetGroupId,
  }) {
    if (lastKeep >= messages.length - 1) {
      return const [];
    }

    final keepGroups = <String>{};
    for (int i = 0; i <= lastKeep && i < messages.length; i++) {
      keepGroups.add(messages[i].groupId ?? messages[i].id);
    }
    if (targetGroupId != null) keepGroups.add(targetGroupId);

    final removeIds = <String>[];
    for (final message in messages.sublist(lastKeep + 1)) {
      final groupId = message.groupId ?? message.id;
      if (!keepGroups.contains(groupId)) {
        removeIds.add(message.id);
      }
    }
    return removeIds;
  }

  /// Remove trailing messages after regeneration cut point.
  Future<List<String>> removeTrailingMessages({
    required List<ChatMessage> messages,
    required int lastKeep,
    required String? targetGroupId,
  }) async {
    final removeIds = collectTrailingMessageIdsForRemoval(
      messages: messages,
      lastKeep: lastKeep,
      targetGroupId: targetGroupId,
    );

    var deletedIds = removeIds;
    if (removeIds.isNotEmpty && messages.isNotEmpty) {
      final removeIdSet = removeIds.toSet();
      final conversationId = messages.first.conversationId;
      final selectionChanges = <String, int?>{};
      for (final message in messages) {
        if (removeIdSet.contains(message.id)) {
          selectionChanges[message.groupId ?? message.id] = null;
        }
      }
      deletedIds = (await chatService.deleteMessages(
        conversationId: conversationId,
        messageIds: removeIdSet,
        versionSelectionChanges: selectionChanges,
      )).toList(growable: false);
    }
    for (final id in deletedIds) {
      streamController.reasoning.remove(id);
      streamController.toolParts.remove(id);
      streamController.reasoningSegments.remove(id);
    }

    return deletedIds;
  }

  bool _shouldIncludeAudioForProvider(
    SettingsProvider settings, {
    required String providerKey,
    required String modelId,
  }) {
    // Former Omni audio allowlist removed; OpenAI-compatible providers do not
    // receive special audio attachment support via this gate.
    return false;
  }

  bool supportsAudioAttachmentsForProvider(
    SettingsProvider settings, {
    required String providerKey,
    required String modelId,
  }) {
    return _shouldIncludeAudioForProvider(
      settings,
      providerKey: providerKey,
      modelId: modelId,
    );
  }

  String _effectiveAttachmentMime(DocumentAttachment attachment) {
    return resolveDocumentAttachmentMime(attachment);
  }

  bool inputContainsAudioAttachments(ChatInputData input) {
    for (final attachment in input.documents) {
      if (isAudioMime(_effectiveAttachmentMime(attachment))) {
        return true;
      }
    }
    return false;
  }

  bool apiMessagesContainAudioAttachments(List<Map<String, dynamic>> messages) {
    for (final message in messages) {
      for (final ref in parseInternalMediaRefs(
        message[MessageBuilderService.internalMediaPathsKey],
      )) {
        final mime = (ref.mime != null && ref.mime!.trim().isNotEmpty)
            ? ref.mime!.trim()
            : inferMediaMimeFromSource(ref.uri);
        if (isAudioMime(mime)) {
          return true;
        }
      }
    }
    return false;
  }

  List<String> _filterMediaPathsForProvider(
    List<String> paths, {
    required bool includeAudio,
  }) {
    return paths
        .where((path) {
          final mime = inferMediaMimeFromSource(
            path,
            fallbackMime: 'image/png',
          );
          if (isAudioMime(mime)) return includeAudio;
          return isImageMime(mime) || isVideoMime(mime);
        })
        .toList(growable: false);
  }

  /// Build user image paths considering OCR mode.
  List<String> buildUserImagePaths({
    required ChatInputData? input,
    required List<String> lastUserImagePaths,
    required SettingsProvider settings,
    required String providerKey,
    required String modelId,
  }) {
    final bool ocrActive =
        settings.ocrEnabled &&
        settings.ocrModelProvider != null &&
        settings.ocrModelId != null;

    final includeAudio = _shouldIncludeAudioForProvider(
      settings,
      providerKey: providerKey,
      modelId: modelId,
    );

    if (input != null) {
      final currentMediaPaths = <String>[];
      for (final d in input.documents) {
        final effectiveMime = _effectiveAttachmentMime(d);
        if (isVideoMime(effectiveMime) ||
            (includeAudio && isAudioMime(effectiveMime))) {
          currentMediaPaths.add(d.path);
        }
      }
      return _filterMediaPathsForProvider(<String>[
        if (!ocrActive) ...input.imagePaths,
        ...currentMediaPaths,
      ], includeAudio: includeAudio);
    }

    return _filterMediaPathsForProvider(
      lastUserImagePaths
          .where((path) {
            if (!ocrActive) return true;
            return !isImageMime(
              inferMediaMimeFromSource(path, fallbackMime: 'image/png'),
            );
          })
          .toList(growable: false),
      includeAudio: includeAudio,
    );
  }

  static bool requiresOnlineLookup(String text) {
    return RegExp(
      r'联网|上网|网上|网络搜索|搜索网页|查官网|官方资料|最新|当前|今天|实时|新闻|价格|汇率|天气|截至|look up|browse|search (?:the )?web|latest|current|today|real[- ]?time',
      caseSensitive: false,
    ).hasMatch(text);
  }

  /// 用户消息里点名的已启用工具（真实实现「所有工具可单独调用」）：
  /// 工具名（下划线形式，如 dex_search / so_analyze）出现在用户消息中即
  /// 命中，返回该工具名，让 buildDefs 把它挂载进本轮声明。
  static Set<String> _mentionedToolNames(
    String text,
    Set<String> enabledToolIds,
  ) {
    if (text.isEmpty || enabledToolIds.isEmpty) return const <String>{};
    final lower = text.toLowerCase();
    return {
      for (final tool in enabledToolIds)
        if (tool.contains('_') && lower.contains(tool)) tool,
    };
  }
}
