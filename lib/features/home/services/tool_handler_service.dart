import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../../core/models/assistant.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/agent_skill_provider.dart';
import '../../../core/providers/instruction_injection_provider.dart';
import '../../../core/providers/mcp_provider.dart';
import '../../../core/providers/memory_provider.dart';
import '../../../core/providers/memory_provider_v2.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/tts_provider.dart';
import '../../../core/providers/world_book_provider.dart';
import '../../../core/services/local_tools/local_tool_names.dart';
import '../../../core/services/local_tools/tool_call_loop_guard.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/api/json_schema_utils.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/mcp/mcp_tool_service.dart';
import '../../../core/services/memory/memory_pipeline.dart';
import '../../../core/services/memory/memory_prompts.dart';
import '../../../core/services/memory/memory_tools.dart';
import '../../../core/services/search/search_tool_service.dart';
import '../../solab_apk/services/apk_agent_policy.dart';
import 'ask_user_interaction_service.dart';
import 'apk_analysis_guard.dart';
import 'built_in_tool_names.dart';
import 'local_tools_service.dart';
import 'tool_approval_service.dart';
import 'tool_router.dart';

/// 工具按需加载策略：决定每次请求在 `tools` 里声明多少工具。
///
/// OpenAI 函数调用要求可调用工具全量声明并按请求计费（含系统提示与
/// Schema 的静态开销）。分层是把「58 个工具全量挂载」从每次请求里拆掉：
/// - [none]：不声明任何工具。纯闲聊/打招呼场景，模型不需要任何工具。
/// - [light]：只下发基础/路由/知识工具（get_apk_*/route_task/ask_user/
///   记忆等），无 APK 工作区时使用——重型分析/改写链按需再加载。
/// - [full]：全量工具（含 jadx/baksmali/so/patch/dex/file 等重型链）。
enum ToolLoadPolicy { none, light, full }

/// 工具调用处理服务
///
/// 处理各类工具调用：
/// - MCP 工具
/// - Memory 工具 (§10)
/// - Search 工具
class ToolHandlerService {
  ToolHandlerService({required this.contextProvider});

  static const int _maxToolResultChars =
      ApkAgentPolicy.maxVisibleToolResultChars;
  static const int _toolResultPreviewChars = 4000;
  static const int _toolResultContinuationChars = 4000;
  static const int _maxToolDescriptionChars = 220;
  static const String _toolResultReadTool = 'get_tool_result';
  static const String externalMcpCatalogTool = 'list_available_mcp_tools';

  static const int _maxStoredToolResultsPerConversation = 24;

  /// get_tool_result 分页准入（纯函数，单测直接覆盖）：
  /// - end <= offset（越界/空窗口）→ 拒绝；
  /// - 顺序推进：offset 不超过上次读取边界 prevBound → 放行（含回到起点）；
  /// - prevBound == 0（未读过）→ 任何 offset 放行（首跳到尾部合法）；
  /// - 否则仅允许「尾部直达例外」：offset 落在结尾附近窗口内 → 放行，
  ///   跳过中段的代价由响应里的 contextBefore 缓冲击中兜底。
  ///   说明文本一直承诺「可直接跳到结尾附近的最后一段」，原实现把该路径
  ///   拦死了（契约不一致）——2026-08-28 修正。
  static bool allowPagingTo({
    required int offset,
    required int limit,
    required int storedLen,
    required int prevBound,
  }) {
    final end = (offset + limit).clamp(offset, storedLen).toInt();
    if (end <= offset) return false;
    if (offset <= prevBound || prevBound == 0) return true;
    final tailWindowStart = (storedLen - _toolResultPreviewChars).clamp(0, storedLen);
    return offset >= tailWindowStart;
  }

  /// 单条工具结果的最大存储字符数。旧值 8000 会把大结果（如全量 xref 分页）
  /// 的尾部永久截掉——模型想看后面也读不到。512KB 内几乎容纳所有本地工具
  /// 结果，超过时 storageTruncated 如实标记。
  static const int _maxStoredToolResultChars = 512 * 1024;
  static const int _maxStoredToolResultCharsPerConversation = 2 * 1024 * 1024;
  static const int _maxToolResultConversations = 3;
  static final LinkedHashMap<String, _ToolResultStore>
  _toolResultStoresByConversation = LinkedHashMap<String, _ToolResultStore>();
  static final LinkedHashMap<String, ApkAnalysisGuard>
  _apkAnalysisGuardsByConversation = LinkedHashMap<String, ApkAnalysisGuard>();
  static int _toolResultSerial = 0;

  /// Build context (used for accessing providers)
  final BuildContext contextProvider;

  // ============================================================================
  // Tool Schema Sanitization
  // ============================================================================

  /// Sanitize/translate JSON Schema to each provider's accepted subset.
  ///
  /// Different providers (Google, OpenAI, Claude) have different requirements
  /// for tool parameter schemas. This method normalizes schemas to work across
  /// all providers.
  static Map<String, dynamic> sanitizeToolParametersForProvider(
    Map<String, dynamic> schema,
    ProviderKind kind,
  ) {
    Map<String, dynamic> clone = _deepCloneMap(schema);
    // Inline local $ref targets first: the allow-list below drops $ref/$defs,
    // so an unresolved reference would reach the model as an empty schema and
    // the whole nested object would silently vanish from the tool call.
    clone = resolveJsonSchemaRefs(
      clone,
      expandAdditionalProperties: kind != ProviderKind.google,
    );
    clone = _sanitizeNode(clone, kind) as Map<String, dynamic>;
    return clone;
  }

  static dynamic _sanitizeNode(dynamic node, ProviderKind kind) {
    if (node is List) {
      return node.map((e) => _sanitizeNode(e, kind)).toList();
    }
    if (node is! Map) return node;

    final m = Map<String, dynamic>.from(node);
    // Remove $schema as it's not needed for tool definitions
    m.remove(r'$schema');

    // Convert 'const' to 'enum' for compatibility
    if (m.containsKey('const')) {
      final v = m['const'];
      if (v is String || v is num || v is bool) {
        m['enum'] = [v];
        // Keep the declared type in sync so a non-string const is not mistaken
        // for a string enum downstream.
        if (m['type'] == null) {
          if (v is bool) {
            m['type'] = 'boolean';
          } else if (v is int) {
            m['type'] = 'integer';
          } else if (v is num) {
            m['type'] = 'number';
          } else {
            m['type'] = 'string';
          }
        }
      }
      m.remove('const');
    }

    // Flatten anyOf/oneOf/allOf to first variant for simplicity
    for (final key in [
      'anyOf',
      'oneOf',
      'allOf',
      'any_of',
      'one_of',
      'all_of',
    ]) {
      if (m[key] is List && (m[key] as List).isNotEmpty) {
        final first = (m[key] as List).first;
        final flattened = _sanitizeNode(first, kind);
        m.remove(key);
        if (flattened is Map<String, dynamic>) {
          m
            ..remove('type')
            ..remove('properties')
            ..remove('items');
          m.addAll(flattened);
        }
      }
    }

    // Normalize type array to single type
    final t = m['type'];
    if (t is List && t.isNotEmpty) m['type'] = t.first.toString();

    // Normalize items array to single item
    final items = m['items'];
    if (items is List && items.isNotEmpty) m['items'] = items.first;
    if (m['items'] is Map) m['items'] = _sanitizeNode(m['items'], kind);

    // Recursively sanitize properties
    if (m['properties'] is Map) {
      final props = Map<String, dynamic>.from(m['properties']);
      final norm = <String, dynamic>{};
      props.forEach((k, v) {
        norm[k] = _sanitizeNode(v, kind);
      });
      m['properties'] = norm;
    }

    // additionalProperties can itself be a schema.
    if (m['additionalProperties'] is Map) {
      m['additionalProperties'] = _sanitizeNode(
        m['additionalProperties'],
        kind,
      );
    }

    // Keep only allowed keys based on provider
    Set<String> allowed;
    switch (kind) {
      case ProviderKind.google:
        allowed = {
          'type',
          'description',
          'properties',
          'required',
          'items',
          'enum',
        };
        break;
      case ProviderKind.openai:
      case ProviderKind.claude:
        allowed = {
          'type',
          'description',
          'properties',
          'required',
          'items',
          'enum',
          'additionalProperties',
        };
        break;
    }
    m.removeWhere((k, v) => !allowed.contains(k));
    return m;
  }

  static Map<String, dynamic> _deepCloneMap(Map<String, dynamic> input) {
    return <String, dynamic>{
      for (final entry in input.entries) entry.key: _deepCloneValue(entry.value),
    };
  }

  /// schema 树为纯 JSON 结构（字面量或 jsonDecode 产物），递归克隆与
  /// jsonEncode/jsonDecode 往返语义等价（含 key 顺序保持），免去每请求 40 个
  /// schema 的双重序列化开销。
  static dynamic _deepCloneValue(dynamic value) {
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries) entry.key: _deepCloneValue(entry.value),
      };
    }
    if (value is List) {
      return <dynamic>[for (final item in value) _deepCloneValue(item)];
    }
    return value;
  }

  static _ToolResultStore _toolResultStoreForConversation(
    String conversationId,
  ) {
    final existing = _toolResultStoresByConversation.remove(conversationId);
    final store = existing ?? _ToolResultStore();
    _toolResultStoresByConversation[conversationId] = store;
    while (_toolResultStoresByConversation.length >
        _maxToolResultConversations) {
      _toolResultStoresByConversation.remove(
        _toolResultStoresByConversation.keys.first,
      );
    }
    return store;
  }

  static ApkAnalysisGuard _apkAnalysisGuardForConversation(
    String conversationId,
  ) {
    final existing = _apkAnalysisGuardsByConversation.remove(conversationId);
    final guard = existing ?? ApkAnalysisGuard();
    _apkAnalysisGuardsByConversation[conversationId] = guard;
    while (_apkAnalysisGuardsByConversation.length >
        _maxToolResultConversations) {
      _apkAnalysisGuardsByConversation.remove(
        _apkAnalysisGuardsByConversation.keys.first,
      );
    }
    return guard;
  }

  static String _toolError({
    required String error,
    required String message,
    required String tool,
    String? instruction,
    Map<String, dynamic>? extra,
  }) {
    return jsonEncode({
      'type': 'tool_error',
      'error': error,
      'message': message,
      'tool': tool,
      if (instruction != null) 'instruction': instruction,
      if (extra != null) ...extra,
    });
  }

  // ============================================================================
  // Tool Definitions Builder
  // ============================================================================

  McpToolRouteSnapshot captureMcpToolRoutes(Assistant? assistant) {
    return contextProvider.read<McpToolService>().captureRoutesForAssistant(
      contextProvider.read<McpProvider>(),
      contextProvider.read<AssistantProvider>(),
      assistantId: assistant?.id,
      reservedNames: BuiltInToolNames.all,
    );
  }

  /// Build tool definitions for API call.
  ///
  /// Returns a list of tool definitions including:
  /// - Search tool (if enabled and model supports tools)
  /// - Memory tools (if assistant has memory / past-recall enabled)
  /// - MCP tools (from selected servers for the assistant)
  /// Whether the chat being generated is a throwaway one.
  ///
  /// Tool definitions are built without a conversation id, so this reads the
  /// active conversation the same way the tool handler does.
  bool _isTemporaryConversation() {
    try {
      final chatService = contextProvider.read<ChatService>();
      return chatService.isTemporaryConversation(
        chatService.currentConversationId,
      );
    } catch (_) {
      return false;
    }
  }

  List<Map<String, dynamic>> buildToolDefinitions(
    SettingsProvider settings,
    Assistant? assistant,
    String providerKey,
    String modelId,
    bool hasBuiltInSearch, {
    required bool Function(String providerKey, String modelId) isToolModel,
    McpToolRouteSnapshot? mcpRouteSnapshot,
    // 工具按需选择（由 ToolRouter 计算）：null=全量；空集=不声明工具；
    // 集合=只声明这些工具。响应式回调选择工具（Domain→Top-K，见
    // ToolRouter.resolveLightSelection / ToolExpansion）。
    Set<String>? includeToolNames,
    bool includeExternalMcpTools = false,
  }) {
    final List<Map<String, dynamic>> toolDefs = <Map<String, dynamic>>[];
    final supportsTools = isToolModel(providerKey, modelId);

    // Search tool (skip when Gemini built-in search is active)
    if (assistant?.searchEnabled == true &&
        !hasBuiltInSearch &&
        supportsTools) {
      toolDefs.add(SearchToolService.getToolDefinition());
    }

    // Memory tools (§10.1)
    if (settings.legacyMemoryMode) {
      if (assistant?.enableMemory == true && supportsTools) {
        toolDefs.addAll(
          _buildLegacyMemoryToolDefinitions(settings.resolvedMemoryPromptLang),
        );
      }
    } else if (supportsTools && assistant != null) {
      toolDefs.addAll(
        MemoryTools.buildDefinitions(
          lang: settings.resolvedMemoryPromptLang,
          writeScope: assistant.memoryWriteScope,
          enableMemory: assistant.enableMemory,
          allowPastConversationRecall: assistant.allowPastConversationRecall,
          allowMemoryWrites: !_isTemporaryConversation(),
        ),
      );
    }

    final localTools = LocalToolsService.buildToolDefinitions(
      assistant: assistant,
      supportsTools: supportsTools,
    );
    toolDefs.addAll(localTools);
    final mcpTools = _buildMcpToolDefinitions(
      settings: settings,
      assistant: assistant,
      providerKey: providerKey,
      supportsTools: supportsTools,
      mcpRouteSnapshot: mcpRouteSnapshot,
    );
    toolDefs.addAll(mcpTools);
    if (supportsTools && mcpTools.isNotEmpty) {
      toolDefs.add(<String, dynamic>{
        'type': 'function',
        'function': <String, dynamic>{
          'name': externalMcpCatalogTool,
          'description':
              '按需列出或调用当前 Agent 已连接的外部 MCP 工具。先空参数获取目录，再传 toolName 和 arguments 调用；无需把全部外部工具常驻提示词。',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'toolName': <String, dynamic>{'type': 'string'},
              'arguments': <String, dynamic>{
                'type': 'object',
                'additionalProperties': true,
              },
            },
          },
        },
      });
    }

    if (supportsTools && toolDefs.isNotEmpty) {
      toolDefs.add(<String, dynamic>{
        'type': 'function',
        'function': <String, dynamic>{
          'name': _toolResultReadTool,
          'description':
              'Read the single bounded continuation of a truncated result. Use offset=4000 once; sequential paging is blocked. If evidence is still missing, rerun the source tool with a narrower query.',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'resultId': <String, dynamic>{'type': 'string'},
              'offset': <String, dynamic>{'type': 'integer'},
              'limit': <String, dynamic>{'type': 'integer'},
            },
            'required': <String>['resultId'],
          },
        },
      });
    }

    final filtered = toolDefs
        .where(
          (def) =>
              includeToolNames == null ||
              includeToolNames.contains(
                (def['function'] as Map?)?['name']?.toString(),
              ) ||
              (def['function'] as Map?)?['name']?.toString() ==
                  externalMcpCatalogTool ||
              (includeExternalMcpTools &&
                  ((def['function'] as Map?)?['name']?.toString() ?? '')
                      .startsWith('mcp__')),
        )
        .toList(growable: false);
    if (filtered.isEmpty) return const <Map<String, dynamic>>[];
    return filtered.map(_compactToolDefinition).toList(growable: false);
  }

  /// 工具定义轻量化（④ Schema 懒加载 + 描述截断）：
  /// - 描述压缩为不超过 [_maxToolDescriptionChars] 的一句话；
  /// - 非关键工具（见 ToolRouter.schemaCriticalNames）不携带完整 parameters，
  ///   只保留名字+一句话，参数在调用时由本地 handler 按名解析。
  static Map<String, dynamic> _compactToolDefinition(
    Map<String, dynamic> definition,
  ) {
    final function = (definition['function'] as Map?)?.cast<String, dynamic>();
    if (function == null) return definition;
    final name = function['name']?.toString() ?? '';
    final description = function['description']?.toString() ?? '';
    final next = <String, dynamic>{
      ...function,
      'description': _shorten(description, _maxToolDescriptionChars),
    };
    if (!ToolRouter.isSchemaCritical(name) && !name.startsWith('mcp__')) {
      // 严格 OpenAI 兼容网关（如 agnes）要求 function.parameters 必填，
      // 不能整字段删除——改为最小占位，保持懒加载语义（不给参数描述）。
      next['parameters'] = <String, dynamic>{'type': 'object'};
    }
    return <String, dynamic>{...definition, 'function': next};
  }

  /// 压缩长描述：取首句/前 220 字符，截断时附「详情见工具映射」。
  static String _shorten(String text, int max) {
    if (text.length <= max) return text;
    var cut = text.substring(0, max);
    // 尽量在换行或句号处断开，避免半句话。
    final boundary = cut.lastIndexOf(RegExp(r'[\n。.!?]'));
    if (boundary > max ~/ 2) {
      cut = cut.substring(0, boundary + 1);
    }
    final end = cut.indexOf('\n');
    return '${end > 0 ? cut.substring(0, end) : cut}'
        '\n[按任务阶段加载所需工具]';
  }

  /// Legacy create/edit/delete_memory tool schemas (pre-v2 memory system).
  ///
  /// Localised by [lang] like [MemoryTools.buildDefinitions], so the schemas
  /// match the language the legacy rules are sent in.
  List<Map<String, dynamic>> _buildLegacyMemoryToolDefinitions(
    MemoryPromptLang lang,
  ) {
    final zh = lang == MemoryPromptLang.zh;
    return [
      {
        'type': 'function',
        'function': {
          'name': 'create_memory',
          'description': zh ? '新增一条记忆记录。' : 'Create a memory record.',
          'parameters': {
            'type': 'object',
            'properties': {
              'content': {
                'type': 'string',
                'description': zh
                    ? '记忆记录的内容。'
                    : 'The content of the memory record.',
              },
            },
            'required': ['content'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'edit_memory',
          'description': zh
              ? '更新一条已有的记忆记录。'
              : 'Update an existing memory record.',
          'parameters': {
            'type': 'object',
            'properties': {
              'id': {
                'type': 'integer',
                'description': zh
                    ? '记忆记录的 id。'
                    : 'The id of the memory record.',
              },
              'content': {
                'type': 'string',
                'description': zh
                    ? '记忆记录的内容。'
                    : 'The content of the memory record.',
              },
            },
            'required': ['id', 'content'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'delete_memory',
          'description': zh ? '删除一条记忆记录。' : 'Delete a memory record.',
          'parameters': {
            'type': 'object',
            'properties': {
              'id': {
                'type': 'integer',
                'description': zh
                    ? '记忆记录的 id。'
                    : 'The id of the memory record.',
              },
            },
            'required': ['id'],
          },
        },
      },
    ];
  }

  /// Build MCP tool definitions from connected servers.
  List<Map<String, dynamic>> _buildMcpToolDefinitions({
    required SettingsProvider settings,
    required Assistant? assistant,
    required String providerKey,
    required bool supportsTools,
    McpToolRouteSnapshot? mcpRouteSnapshot,
  }) {
    if (!supportsTools) return [];

    final mcp = contextProvider.read<McpProvider>();
    final toolSvc = contextProvider.read<McpToolService>();
    final tools = toolSvc.listAvailableToolsForAssistant(
      mcp,
      contextProvider.read<AssistantProvider>(),
      assistant?.id,
      routeSnapshot: mcpRouteSnapshot,
      reservedNames: BuiltInToolNames.all,
    );

    if (tools.isEmpty) return [];

    final providerCfg = settings.getProviderConfig(providerKey);
    final providerKind = ProviderConfig.classify(
      providerCfg.id,
      explicitType: providerCfg.providerType,
    );

    return tools.map((t) {
      Map<String, dynamic> baseSchema;
      if (t.schema != null && t.schema!.isNotEmpty) {
        baseSchema = Map<String, dynamic>.from(t.schema!);
      } else {
        final props = <String, dynamic>{
          for (final p in t.params) p.name: {'type': (p.type ?? 'string')},
        };
        final required = [
          for (final p in t.params.where((e) => e.required)) p.name,
        ];
        baseSchema = {
          'type': 'object',
          'properties': props,
          if (required.isNotEmpty) 'required': required,
        };
      }
      final sanitized = sanitizeToolParametersForProvider(
        baseSchema,
        providerKind,
      );
      return {
        'type': 'function',
        'function': {
          'name': t.name,
          if ((t.description ?? '').isNotEmpty) 'description': t.description,
          'parameters': sanitized,
        },
      };
    }).toList();
  }

  // ============================================================================
  // Tool Call Handler
  // ============================================================================

  /// Build tool call handler function.
  ///
  /// Returns a function that handles tool calls by name and arguments.
  /// Supports:
  /// - Search tool calls
  /// - Memory tool calls (§10)
  /// - MCP tool calls
  ToolCallHandler? buildToolCallHandler(
    SettingsProvider settings,
    Assistant? assistant, {
    ToolApprovalService? approvalService,
    AskUserInteractionService? askUserService,
    String? conversationId,
    McpToolRouteSnapshot? mcpRouteSnapshot,
    Set<String> Function()? availableToolNames,
  }) {
    final mcp = contextProvider.read<McpProvider>();
    final toolSvc = contextProvider.read<McpToolService>();
    // Capture AssistantProvider reference before async gap to avoid
    // use_build_context_synchronously warning
    final assistantProvider = contextProvider.read<AssistantProvider>();
    T? optionalProvider<T>() {
      try {
        return contextProvider.read<T>();
      } on ProviderNotFoundException {
        return null;
      }
    }

    final agentSkillProvider = optionalProvider<AgentSkillProvider>();
    final instructionInjectionProvider =
        optionalProvider<InstructionInjectionProvider>();
    final worldBookProvider = optionalProvider<WorldBookProvider>();
    // APK 记忆已并入 Memory V1 体系；测试等精简 Provider 环境下允许缺省。
    final memoryRepository =
        optionalProvider<MemoryProviderV2>()?.repository;
    final apkAnalysisGuard = conversationId == null
        ? ApkAnalysisGuard()
        : _apkAnalysisGuardForConversation(conversationId);
    apkAnalysisGuard.beginUserTurn();
    final toolCallLoopGuard = ToolCallLoopGuard();
    // APK 工具链按对话保存文本预算和分析状态；调用次数不设上限。
    final toolResultStore = conversationId == null
        ? _ToolResultStore()
        : _toolResultStoreForConversation(conversationId);

    String limitToolResult(String result) {
      if (result.length <= _maxToolResultChars) return result;
      final resultId =
          'tool_result_${DateTime.now().microsecondsSinceEpoch}_${++_toolResultSerial}';
      final stored = toolResultStore.put(
        resultId,
        result,
        _maxStoredToolResultsPerConversation,
        _maxStoredToolResultChars,
        _maxStoredToolResultCharsPerConversation,
      );
      return jsonEncode(<String, dynamic>{
        'ok': true,
        'truncated': true,
        'resultId': resultId,
        'originalChars': result.length,
        'storedChars': stored.content.length,
        'storageTruncated': stored.isTruncated,
        'preview': result.substring(0, _toolResultPreviewChars),
        'nextAction': stored.isTruncated
            ? 'Stored up to $_maxStoredToolResultChars chars (storageTruncated=true). Page with get_tool_result offset=$_toolResultPreviewChars and limit=65536 to reach the end faster; prefer narrowing the source query when possible.'
            : 'Call get_tool_result with offset=$_toolResultPreviewChars and a larger limit (up to 65536) to continue reading; sequential paging is allowed until hasMore=false.',
      });
    }

    final routes =
        mcpRouteSnapshot ??
        toolSvc.captureRoutesForAssistant(
          mcp,
          assistantProvider,
          assistantId: assistant?.id,
          reservedNames: BuiltInToolNames.all,
        );

    String approvalIdFor(String name, String? toolCallId) {
      final trimmed = toolCallId?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
      return '${name}_${DateTime.now().microsecondsSinceEpoch}';
    }

    Future<Object?> approveAndExecuteMcp(
      String name,
      Map<String, dynamic> args, {
      String? toolCallId,
    }) async {
      if (approvalService != null &&
          toolSvc.toolNeedsApprovalForAssistant(
            mcp,
            assistantProvider,
            assistantId: assistant?.id,
            toolName: name,
            routeSnapshot: routes,
            reservedNames: BuiltInToolNames.all,
          )) {
        final result = await approvalService.requestApproval(
          toolCallId: approvalIdFor(name, toolCallId),
          toolName: name,
          arguments: args,
          conversationId: conversationId,
        );
        if (!result.approved) {
          return _toolError(
            error: 'approval_denied',
            message: result.denyReason ?? 'User denied the tool call',
            tool: name,
          );
        }
      }

      return toolSvc.callToolForAssistant(
        mcp,
        assistantProvider,
        assistantId: assistant?.id,
        toolName: name,
        arguments: args,
        routeSnapshot: routes,
        reservedNames: BuiltInToolNames.all,
      );
    }

    return (name, args, {toolCallId}) async {
      final runtimeToolNames = availableToolNames?.call();
      if (runtimeToolNames != null && !runtimeToolNames.contains(name)) {
        // 真实实现「所有工具可单独调用」：已启用的工具即使本轮未下发也放行
        // （用户点名/直接调用即可执行），只有未启用/不存在的工具才拦截。
        // 放行条件与 LocalToolsService 的 localToolIds 过滤保持一致。
        final enabledSet = assistant?.localToolIds.toSet() ?? const <String>{};
        if (!enabledSet.contains(name)) {
          final sortedNames = runtimeToolNames.toList()..sort();
          return _toolError(
            error: 'unknown_function',
            message: '工具 $name 不存在或未启用,本次调用未执行。',
            tool: name,
            instruction:
                '只能调用已启用的工具;可先查 get_solab_tool_map 确认可用名单。',
            extra: <String, dynamic>{'availableToolNames': sortedNames},
          );
        }
        // 已启用 → 放行（schema 与 handler 均存在，可真实执行）
      }
      final loopDecision = toolCallLoopGuard.check(
        name,
        args,
        polling: _isPollingToolCall(name, args),
      );
      if (!loopDecision.allowed) {
        return _toolError(
          error: 'loop_detected',
          message: loopDecision.message,
          tool: name,
          instruction:
              '直接使用上一次结果,或改变参数和分析路径;若目标工具不在 availableToolNames,本次调用不会替换成其他工具执行。route_task 已完成仍缺失时停止重试并报告工具注入异常。',
          extra: runtimeToolNames == null
              ? null
              : <String, dynamic>{
                  'availableToolNames': runtimeToolNames.toList()..sort(),
                },
        );
      }
      if (name == LocalToolNames.routeTask) {
        apkAnalysisGuard.begin((args['goal'] ?? '').toString());
      }
      final budget = apkAnalysisGuard.before(name, args);
      if (!budget.allowed) {
        if (budget.canRequestBudget) {
          return jsonEncode({
            'type': 'tool_error',
            'error': 'apk_analysis_budget_authorization_required',
            'message': budget.message,
            'tool': name,
            'nextRequiredTool': LocalToolNames.askUser,
            'questionArguments': const {
              'questions': [
                {
                  'id': 'apk_budget_extension',
                  'question': '当前 APK 分析预算已用完，是否授权追加一部分预算继续定位？',
                  'type': 'single',
                  'options': ['追加 12 次', '追加 20 次', '停止并汇报'],
                },
              ],
            },
            'mcpFallback': 'MCP 调用方没有提问工具时，用文字取得用户明确授权后再继续。',
          });
        }
        return _toolError(
          error: 'apk_analysis_guard_blocked',
          message: budget.message,
          tool: name,
          instruction: '不要重复调用。根据已有报告、候选和失败状态切换到返回结果中的替代路径；没有新证据时直接报告当前结论。',
        );
      }
      if (name == _toolResultReadTool) {
        final resultId = (args['resultId'] ?? '').toString();
        final result = toolResultStore.take(resultId);
        if (result == null) {
          return _toolError(
            error: 'tool_result_not_found',
            message: 'The resultId is unavailable in this conversation.',
            tool: name,
          );
        }
        // 顺序分页允许多次：只要 offset 单调前进即可继续读取到结尾。
        final storedLen = result.content.length;
        int offset = (args['offset'] as num?)?.toInt() ?? -1;
        if (offset < 0) offset = _toolResultPreviewChars;
        offset = offset.clamp(0, storedLen).toInt();
        if (!result.continuationRead && offset != _toolResultPreviewChars &&
            offset != 0 && offset < storedLen) {
          // 首次续读仍从预览边界开始，防止跳过中段内容造成误判。
          offset = _toolResultPreviewChars;
        }
        final limit = ((args['limit'] as num?)?.toInt() ??
                _toolResultContinuationChars)
            .clamp(1, 65536)
            .toInt();
        final end = (offset + limit).clamp(offset, storedLen).toInt();
        final prevBound = result.maxReadOffset;
        if (!allowPagingTo(
          offset: offset,
          limit: limit,
          storedLen: storedLen,
          prevBound: prevBound,
        )) {
          return _toolError(
            error: 'tool_result_paging_blocked',
            message:
                'offset 必须从上次读取边界($prevBound)开始顺序推进；仅允许跳到结尾附近的最后一段。',
            tool: name,
            instruction:
                '下一次调用 get_tool_result 时传 offset=$prevBound（或直接跳到结尾附近的最后一段）。缺少证据时也应回原工具收窄查询。',
          );
        }
        final hasMore = end < storedLen;
        if (end > result.maxReadOffset) result.maxReadOffset = end;
        result.continuationRead = true;
        apkAnalysisGuard.noteLongResultRead();
        final contextBefore = offset == 0
            ? ''
            : result.content.substring((offset - 80).clamp(0, storedLen), offset);
        return jsonEncode(<String, dynamic>{
          'ok': true,
          'resultId': resultId,
          'offset': offset,
          'end': end,
          'totalChars': storedLen,
          'sourceChars': result.originalChars,
          'storageTruncated': result.isTruncated,
          if (contextBefore.isNotEmpty) ...<String, dynamic>{
            'contextBefore': contextBefore,
            'pageAnchor':
                '[get_tool_result offset=$offset end=$end total=$storedLen]',
          },
          'content': result.content.substring(offset, end),
          'hasMore': hasMore,
          if (hasMore)
            'nextOffset': end,
          if (!hasMore && result.isTruncated)
            'storageNote':
                '存储层按上限截断了原始结果；超出的尾部不在缓存中。需完整内容请回原工具收窄查询。',
        });
      }
      if (name == externalMcpCatalogTool) {
        final tools = toolSvc.listAvailableToolsForAssistant(
          mcp,
          assistantProvider,
          assistant?.id,
          routeSnapshot: routes,
        );
        final requestedTool = (args['toolName'] ?? '').toString().trim();
        if (requestedTool.isNotEmpty) {
          if (!tools.any((tool) => tool.name == requestedTool)) {
            return _toolError(
              error: 'mcp_tool_not_available',
              message: '外部 MCP 工具不存在或当前未启用: $requestedTool',
              tool: name,
              instruction: '先空参数调用本工具获取最新目录，再使用目录中的精确名称。',
            );
          }
          final toolArguments =
              (args['arguments'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{};
          if (approvalService != null &&
              toolSvc.toolNeedsApprovalForAssistant(
                mcp,
                assistantProvider,
                assistantId: assistant?.id,
                toolName: requestedTool,
                routeSnapshot: routes,
              )) {
            final approval = await approvalService.requestApproval(
              toolCallId: (toolCallId?.trim().isNotEmpty == true)
                  ? toolCallId!.trim()
                  : '${requestedTool}_${DateTime.now().microsecondsSinceEpoch}',
              toolName: requestedTool,
              arguments: toolArguments,
              conversationId: conversationId,
            );
            if (!approval.approved) {
              return _toolError(
                error: 'approval_denied',
                message: approval.denyReason ?? 'User denied the tool call',
                tool: requestedTool,
              );
            }
          }
          final result = await toolSvc.callToolTextForAssistant(
            mcp,
            assistantProvider,
            assistantId: assistant?.id,
            toolName: requestedTool,
            arguments: toolArguments,
            routeSnapshot: routes,
          );
          return limitToolResult(result);
        }
        return jsonEncode(<String, dynamic>{
          'ok': true,
          'count': tools.length,
          'tools': <Map<String, dynamic>>[
            for (final tool in tools)
              <String, dynamic>{
                'name': tool.name,
                if ((tool.description ?? '').trim().isNotEmpty)
                  'description': _shorten(
                    tool.description!.trim(),
                    _maxToolDescriptionChars,
                  ),
                if (tool.schema != null && tool.schema!.isNotEmpty)
                  'parameters': tool.schema,
              },
          ],
          'nextAction':
              '可再次调用 list_available_mcp_tools，并传入 toolName 与 arguments；支持动态工具声明的模型下一轮也会自动加载精确工具。',
        });
      }
      // 参数 JSON 解析失败的统一拦截：写操作在零参数下执行会造成
      // 盲 build/decode 或确认死循环，必须在此原路返回并要求重发。
      if (args['__rawArguments'] is String) {
        final rawPreview = (args['__rawArguments'] as String);
        final clipped = rawPreview.length > 300
            ? '${rawPreview.substring(0, 300)}…'
            : rawPreview;
        return jsonEncode(<String, dynamic>{
          'type': 'tool_error',
          'error': 'invalid_tool_arguments',
          'recoverable': true,
          'tool': name,
          'receivedArgumentCount': args.length,
          'message':
              'arguments 不是合法 JSON 对象，本次调用未执行任何操作。原文：$clipped',
          'instruction':
              '重发同一调用：arguments 必须是严格 JSON——双引号键、无尾逗号、无 ``` 围栏。修正后整段重发即可。',
        });
      }

      // 轻量/旧记忆工具不依赖会话服务；完整应用仍会提供它给本地工作台工具。
      final chatServiceForTools = optionalProvider<ChatService>();
      try {
        if (routes.containsExposedName(name)) {
          return await approveAndExecuteMcp(name, args, toolCallId: toolCallId);
        }

        // Search tool
        if (name == SearchToolService.toolName &&
            assistant?.searchEnabled == true) {
          final q = (args['query'] ?? '').toString();
          return limitToolResult(
            await SearchToolService.executeSearch(q, settings),
          );
        }

        // Memory tools
        final memoryResult = await _handleMemoryToolCall(
          name,
          args,
          assistant,
          conversationId: conversationId,
        );
        if (memoryResult != null) {
          return limitToolResult(memoryResult);
        }

        // Creating calendar events modifies user data, so it always requires
        // explicit user approval before the local tool runs.
        if (name == LocalToolNames.calendarCreate &&
            assistant != null &&
            assistant.localToolIds.contains(LocalToolNames.calendarCreate) &&
            approvalService != null) {
          final approval = await approvalService.requestApproval(
            toolCallId: approvalIdFor(name, toolCallId),
            toolName: name,
            arguments: args,
            conversationId: conversationId,
          );
          if (!approval.approved) {
            return _toolError(
              error: 'approval_denied',
              message: approval.denyReason ?? 'User denied the tool call',
              tool: name,
            );
          }
        }

        // Local tools
        final localArgs =
            runtimeToolNames == null ||
                (name != LocalToolNames.apkToolMap &&
                    name != LocalToolNames.agentRuntimeGuide)
            ? args
            : <String, dynamic>{
                ...args,
                '__runtimeToolNames': runtimeToolNames.toList(),
              };
        final localResult = await LocalToolsService.tryHandleToolCall(
          name,
          localArgs,
          assistant,
          onSpeakText: (text) async {
            final tts = contextProvider.read<TtsProvider>();
            if (!tts.isAvailable) {
              throw StateError('Text-to-speech is unavailable.');
            }
            unawaited(
              tts.speak(text).catchError((Object error, StackTrace stack) {
                FlutterError.reportError(
                  FlutterErrorDetails(
                    exception: error,
                    stack: stack,
                    library: 'SoLab local tools',
                    context: ErrorDescription('while playing text-to-speech'),
                  ),
                );
              }),
            );
          },
          chatService: chatServiceForTools,
          worldBookProvider: worldBookProvider,
          agentSkillProvider: agentSkillProvider,
          instructionInjectionProvider: instructionInjectionProvider,
          conversationId: conversationId,
          memoryRepository: memoryRepository,
        );
        if (localResult != null) {
          if (ToolCallLoopGuard.changesState(name, args) &&
              ToolCallLoopGuard.succeeded(localResult)) {
            toolCallLoopGuard.advanceState(name, args);
          }
          return limitToolResult(
            apkAnalysisGuard.record(name, args, localResult),
          );
        }

        if (name == LocalToolNames.askUser &&
            assistant != null &&
            assistant.localToolIds.contains(LocalToolNames.askUser)) {
          if (askUserService == null) {
            return _toolError(
              error: 'ask_user_unavailable',
              message: 'Ask user interaction service is unavailable.',
              tool: name,
            );
          }
          try {
            final result = await askUserService.requestAnswer(
              toolCallId: (toolCallId?.trim().isNotEmpty == true)
                  ? toolCallId!.trim()
                  : '${name}_${DateTime.now().microsecondsSinceEpoch}',
              arguments: args,
              conversationId: conversationId,
            );
            // 用户给出了回答：解除分析守卫对当前轨道 ambiguous 等的阻断，
            // 否则用户确认了体系仍会因 reportStatus=ambiguous 被死拦。
            if (result.error == null && result.answers.isNotEmpty) {
              apkAnalysisGuard.confirmFromUserAnswer();
              final budgetAnswer =
                  result.answers['apk_budget_extension']?.value.toString() ??
                  '';
              final granted = RegExp(
                r'追加\s*(\d+)',
              ).firstMatch(budgetAnswer)?.group(1);
              if (granted != null) {
                apkAnalysisGuard.grantBudget(int.parse(granted));
              }
              toolCallLoopGuard.advanceState(name, args);
            }
            return limitToolResult(result.toJsonString());
          } on AskUserInvalidRequestException catch (e) {
            return _toolError(
              error: 'invalid_ask_user_request',
              message: e.message,
              tool: name,
            );
          }
        }

        return await approveAndExecuteMcp(name, args, toolCallId: toolCallId);
      } catch (e) {
        // Catch unexpected exceptions and return error JSON to LLM
        // This prevents tool failures from terminating the chat flow
        return _toolError(
          error: 'execution_error',
          message: e.toString(),
          tool: name,
          instruction:
              'The tool execution failed unexpectedly. You may try again with different parameters or inform the user about the issue.',
        );
      }
    };
  }

  static bool _isPollingToolCall(String name, Map<String, dynamic> arguments) {
    if (name == 'mcp_task_status' || name == 'open') return true;
    if (name != LocalToolNames.soAnalyze) return false;
    return arguments['action'] == 'status' ||
        arguments['blutterAction'] == 'status';
  }

  /// Handle memory tool calls (§10).
  ///
  /// Returns null if the tool is not a memory tool or the relevant gate is off.
  Future<String?> _handleMemoryToolCall(
    String name,
    Map<String, dynamic> args,
    Assistant? assistant, {
    String? conversationId,
  }) async {
    final settings = contextProvider.read<SettingsProvider>();
    if (settings.legacyMemoryMode) {
      if (MemoryTools.allToolNames.contains(name)) return null;
      return _handleLegacyMemoryToolCall(name, args, assistant);
    }

    if (assistant == null) return null;
    if (!MemoryTools.allToolNames.contains(name)) return null;

    final memoryV2 = contextProvider.read<MemoryProviderV2>();
    ChatService? chatService;
    try {
      chatService = contextProvider.read<ChatService>();
    } catch (_) {
      chatService = null;
    }

    MemoryPipelineService? pipeline;
    try {
      pipeline = contextProvider.read<MemoryPipelineService>();
    } catch (_) {
      pipeline = null;
    }

    Future<String> Function(String prompt)? memoryLlmCall;
    final provKey = settings.memoryModelProvider;
    final mdlId = settings.memoryModelId;
    if (provKey != null && mdlId != null) {
      final cfg = settings.getProviderConfig(provKey);
      final budget = settings.memoryModelThinkingEnabled
          ? (assistant.thinkingBudget ?? settings.thinkingBudget)
          : 0;
      memoryLlmCall = (prompt) => ChatApiService.generateText(
        config: cfg,
        modelId: mdlId,
        prompt: prompt,
        thinkingBudget: budget,
      );
    }

    final temporary =
        chatService?.isTemporaryConversation(conversationId) ?? false;
    return MemoryTools.handle(
      name: name,
      args: args,
      assistant: assistant,
      repository: memoryV2.repository,
      chatRepository: memoryV2.chatRepository,
      chatService: chatService,
      conversationId: conversationId,
      // Reload without changing which assistants the open memory UI is showing.
      onMutated: memoryV2.reloadCurrentScope,
      smartAdd: pipeline?.smartAdd,
      promptLang: settings.resolvedMemoryPromptLang,
      memoryLlmCall: memoryLlmCall,
      smartAddPromptZh: settings.memorySmartAddPromptZh,
      smartAddPromptEn: settings.memorySmartAddPromptEn,
      // Temporary chats are discarded on exit; their tool traces must not linger.
      traceRecorder: temporary ? null : pipeline?.traceRecorder,
      conversationTitle: conversationId == null
          ? null
          : chatService?.getConversation(conversationId)?.title,
    );
  }

  /// Handle legacy create/edit/delete_memory calls via [MemoryProvider].
  ///
  /// Returns null if memory is disabled or [name] is not a legacy memory tool.
  Future<String?> _handleLegacyMemoryToolCall(
    String name,
    Map<String, dynamic> args,
    Assistant? assistant,
  ) async {
    if (assistant?.enableMemory != true) return null;
    if (name != 'create_memory' &&
        name != 'edit_memory' &&
        name != 'delete_memory') {
      return null;
    }

    try {
      final mp = contextProvider.read<MemoryProvider>();

      if (name == 'create_memory') {
        final content = (args['content'] ?? '').toString();
        if (content.isEmpty) {
          return _toolError(
            error: 'invalid_memory_content',
            message: 'Memory content must not be empty.',
            tool: name,
          );
        }
        final m = await mp.add(assistantId: assistant!.id, content: content);
        return m.content;
      } else if (name == 'edit_memory') {
        final id = (args['id'] as num?)?.toInt() ?? -1;
        final content = (args['content'] ?? '').toString();
        if (id <= 0) {
          return _toolError(
            error: 'invalid_memory_id',
            message: 'Memory id must be a positive integer.',
            tool: name,
          );
        }
        if (content.isEmpty) {
          return _toolError(
            error: 'invalid_memory_content',
            message: 'Memory content must not be empty.',
            tool: name,
          );
        }
        final m = await mp.update(id: id, content: content);
        if (m == null) {
          return _toolError(
            error: 'memory_not_found',
            message: 'No memory record was found for id $id.',
            tool: name,
            instruction:
                'Use the available memory records shown in context, or create a new memory instead of editing a missing one.',
          );
        }
        return m.content;
      } else if (name == 'delete_memory') {
        final id = (args['id'] as num?)?.toInt() ?? -1;
        if (id <= 0) {
          return _toolError(
            error: 'invalid_memory_id',
            message: 'Memory id must be a positive integer.',
            tool: name,
          );
        }
        final ok = await mp.delete(id: id);
        if (!ok) {
          return _toolError(
            error: 'memory_not_found',
            message: 'No memory record was found for id $id.',
            tool: name,
            instruction:
                'Use the available memory records shown in context, or skip deleting a missing memory.',
          );
        }
        return 'deleted';
      }
    } catch (e) {
      return _toolError(
        error: 'memory_execution_error',
        message: e.toString(),
        tool: name,
        instruction:
            'The memory tool failed. Retry only after correcting the parameters, or inform the user about the issue.',
      );
    }

    return null;
  }
}

class _ToolResultStore {
  final LinkedHashMap<String, _StoredToolResult> _results =
      LinkedHashMap<String, _StoredToolResult>();
  var _storedChars = 0;

  _StoredToolResult put(
    String resultId,
    String result,
    int maxEntries,
    int maxEntryChars,
    int maxTotalChars,
  ) {
    final content = result.length > maxEntryChars
        ? result.substring(0, maxEntryChars)
        : result;
    final stored = _StoredToolResult(content, result.length);
    final previous = _results.remove(resultId);
    if (previous != null) _storedChars -= previous.content.length;
    _results[resultId] = stored;
    _storedChars += content.length;
    while (_results.length > maxEntries || _storedChars > maxTotalChars) {
      final removed = _results.remove(_results.keys.first);
      if (removed != null) _storedChars -= removed.content.length;
    }
    return stored;
  }

  _StoredToolResult? take(String resultId) {
    final result = _results.remove(resultId);
    if (result != null) _results[resultId] = result;
    return result;
  }
}

class _StoredToolResult {
  _StoredToolResult(this.content, this.originalChars);

  final String content;
  final int originalChars;
  bool continuationRead = false;
  int maxReadOffset = 0;

  bool get isTruncated => content.length < originalChars;
}
