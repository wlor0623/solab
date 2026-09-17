import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'dart:io';

import '../../../features/home/services/local_tools_service.dart';
import '../../../features/solab_apk/analyzer/analyzer_tools.dart';
import '../../../features/solab_apk/services/apk_agent_policy.dart';
import '../../models/assistant.dart';
import '../../providers/agent_skill_provider.dart';
import '../../providers/instruction_injection_provider.dart';
import '../../providers/world_book_provider.dart';
import '../../services/chat/chat_service.dart';
import '../../services/local_tools/local_tool_names.dart';
import '../../services/local_tools/local_tool_registry.dart';
import '../../services/local_tools/tool_call_loop_guard.dart';
import '../../services/memory/memory_repository.dart';

/// 把本机作为 MCP Server 对外暴露，局域网内的 AI 客户端
/// （Claude Code / Cursor / Cherry Studio 等）可直接连接调用内置 SoLab 工具。
///
/// 支持两种标准传输：
/// 1. Streamable HTTP（MCP 2025-03-26 / 2025-06-18）：
///    POST /mcp（JSON 或 SSE 响应）+ Mcp-Session-Id 会话头。
/// 2. HTTP+SSE（MCP 2024-11-05）：GET /sse 建立长连接，
///    服务器下发 endpoint 事件，客户端 POST /messages?sessionId=...，
///    响应通过 SSE 流异步推回。
///
/// 鉴权可选：token 为空则不鉴权（默认，局域网直连）；
/// 配置 token 后需 `Authorization: Bearer <token>` 或 `?token=`。
/// 工具：复用 LocalToolsService 的 schema 与执行链路，单一来源不漂移。
class McpHttpServer extends ChangeNotifier {
  McpHttpServer._();

  static final McpHttpServer instance = McpHttpServer._();

  static const int maxRequestBytes = 8 * 1024 * 1024; // 8MB

  /// MCP 面单条结果上限。此前钉在 maxVisibleToolResultChars(16000)——
  /// 真机实测 so_analyze 参数目录 16.6KB 被截断，且 MCP 面没有
  /// get_tool_result 续读工具，尾部永久不可达。MCP 消费方多为程序型
  /// Agent，与 App 内 LLM 的 16KB 内联预算诉求不同：提到 512KB（与
  /// ToolHandlerService 结果存储上限一致），超过才走预览截断硬边界。
  static const int maxResultChars = 512 * 1024;
  static const int defaultPort = 8800;
  static const Duration sseHeartbeat = Duration(seconds: 25);
  static const String taskStatusTool = 'mcp_task_status';
  static const Duration taskRetention = Duration(minutes: 30);

  static const Set<String> supportedProtocolVersions = <String>{
    '2024-11-05',
    '2025-03-26',
    '2025-06-18',
  };

  HttpServer? _server;
  String _token = '';
  int _port = defaultPort;
  DateTime _startedAt = DateTime.now();
  List<String> _lanIps = const <String>[];
  final Map<String, _SseSession> _sseSessions = <String, _SseSession>{};
  final Map<String, _McpToolTask> _toolTasks = <String, _McpToolTask>{};
  final Random _random = Random.secure();
  Future<String>? _serverVersion;

  /// 出站网络心跳：部分厂商 ROM（vivo 等）在应用切后台后会用 uid=0 代答
  /// 入站 socket 但不向应用投递数据。周期性出站 TCP 流量可维持应用在
  /// 系统网络管理侧的活跃标记，降低入站连接被冻结的概率。
  Timer? _netHeartbeatTimer;
  String? _netHeartbeatGateway;

  Future<void> _writeToolGate = Future<void>.value();
  final List<Future<void>> _readToolGates = List<Future<void>>.filled(
    2,
    Future<void>.value(),
  );
  int _nextReadGate = 0;
  String? _blockedWriteToolName;
  DateTime? _blockedWriteSince;
  final List<String?> _blockedReadToolNames = List<String?>.filled(2, null);
  final List<DateTime?> _blockedReadSince = List<DateTime?>.filled(2, null);

  /// 超时熔断的自动恢复冷却：挂死超此时长后放弃等待僵尸 Future，重置
  /// 执行通道放行新调用。原实现隔离无期限，一次 native 挂死 = 整个 MCP
  /// 模式永久不可用，只能重启。
  static const Duration _laneRecoveryCooldown = Duration(minutes: 2);

  final ToolCallLoopGuard _toolCallLoopGuard = ToolCallLoopGuard();

  static const Duration _defaultToolTimeout = Duration(seconds: 45);
  static const Duration _fileToolTimeout = Duration(seconds: 15);
  static const Duration _heavyToolTimeout = Duration(minutes: 5);
  static const Duration _adaptiveInlineWindow = Duration(milliseconds: 300);
  static const Set<String> _adaptiveToolIds = <String>{
    LocalToolNames.apkPatchDex,
    LocalToolNames.apkSignatureBypass,
    LocalToolNames.apkPatchManifest,
    LocalToolNames.jadxDecompile,
    LocalToolNames.apkSign,
    LocalToolNames.apkRebuild,
    LocalToolNames.dexSearch,
    LocalToolNames.stringScan,
    LocalToolNames.dexXref,
    LocalToolNames.classOutline,
    LocalToolNames.smaliRead,
    LocalToolNames.soAnalyze,
    LocalToolNames.soPatchIntoApk,
  };

  /// 当前 Assistant 提供者（工具执行需要；由 app 层在启动时注入）。
  Assistant? Function()? _assistantGetter;

  /// 聊天服务提供者：项目记录类工具需要数据库仓库。
  ChatService? Function()? _chatServiceGetter;

  /// 记忆仓库提供者：patch 记忆 / 笔记类工具需要。
  MemoryRepository? Function()? _memoryRepositoryGetter;

  /// 世界书提供者：get_apk_knowledge / 运行时指南需要。
  WorldBookProvider? Function()? _worldBookGetter;

  /// 用户 Skill 提供者：get_installed_skills / 运行时指南需要。
  AgentSkillProvider? Function()? _agentSkillGetter;

  /// 指令注入提供者：运行时指南需要。
  InstructionInjectionProvider? Function()? _instructionInjectionGetter;

  Future<bool> Function()? _keepAliveEnsurer;

  /// 对外暴露的全部工具：本地工具全量，剔除 UI 依赖的
  /// ask_user_input_v0（弹窗）与 text_to_speech（TTS 回调）——MCP 场景无 UI。
  /// MCP initialize 标准指令：注入外部 agent 系统提示，教它入口链路与
  /// 分层判定（尤其 Blutter：外部 agent 不懂何时该走 Dart 层）。
  /// 使用英文短文本：避免外部网页端/客户端对 UTF-8 中文错误解码显示乱码。
  static const String _mcpInstructions =
      '''
Local APK analysis/modification toolchain (runs on this Android device).
Rules:
0. Reply to the user in Chinese; fill tool arguments by schema field names.
${ApkAgentPolicy.sharedDecisionPolicy}
1. Write contracts remain strict: only listed tools are callable; warning/no-change previews are not applied. For an authorized exact change use dryRun=true plus applyAfterPreview=true once. A successful write changes the artifact, so continue with nextInputPath and discard previews for the old APK. Source APK is read-only.
2. Read error.code before recovery. Change the evidence dimension after a miss or timeout; do not retry identical arguments. For queued work poll mcp_task_status; do not repeat the original call.
3. Run apk_rebuild only for decoded resource/Manifest/smali-directory edits, never for a direct DEX patch output.
4. tools/list schemas are compacted. Call get_solab_tool_map only when a required parameter/action is missing; do not guess names.''';

  static String get mcpInstructions => _mcpInstructions;

  /// Agent 唯一可见的工具白名单（收敛到 21 个高价值意图工具）。
  /// 其余原子操作降级为内部执行器，避免 Agent 在过多工具里迷路、
  /// 重复探索、无头苍蝇乱转。
  /// get_solab_tool_map 额外暴露：tools/list 的 schema 做了压缩，
  /// 完整参数/action 列表按需从这个文档工具读取（schema 懒加载）。
  static final List<String> exposedToolIds = List<String>.unmodifiable(<String>[
    ...LocalToolRegistry.mcpExposedToolIds(),
    AnalyzerToolNames.open,
    AnalyzerToolNames.globalSearch,
    AnalyzerToolNames.fieldUsage,
    AnalyzerToolNames.businessState,
  ]);

  static const Map<String, String> _publishedToolAliases = <String, String>{
    AnalyzerToolNames.open: 'analyzer_open',
    AnalyzerToolNames.globalSearch: 'analyzer_global_search',
    AnalyzerToolNames.fieldUsage: 'analyzer_find_field_usage',
    AnalyzerToolNames.businessState: 'analyzer_analyze_business_state',
  };

  static final Map<String, String> _internalToolAliases = <String, String>{
    for (final entry in _publishedToolAliases.entries) entry.value: entry.key,
  };

  static final Set<String> _readOnlyToolIds = Set<String>.unmodifiable(<String>{
    ...LocalToolRegistry.readOnlyToolIds(),
    AnalyzerToolNames.open,
    AnalyzerToolNames.globalSearch,
    AnalyzerToolNames.fieldUsage,
    AnalyzerToolNames.businessState,
    taskStatusTool,
  });

  bool _isReadOnlyCall(String name, Map<String, dynamic> args) {
    if (_readOnlyToolIds.contains(name)) return true;
    if (name == LocalToolNames.file) {
      return const <String>{
        'inventory',
        'read',
        'list',
        'info',
        'grep',
        'strings',
      }.contains(args['action']?.toString());
    }
    if (name == LocalToolNames.soAnalyze) {
      final action = args['action']?.toString();
      final blutterAction = args['blutterAction']?.toString();
      return action == 'status' ||
          (action == 'blutter' && blutterAction == 'status');
    }
    return false;
  }

  bool get isRunning => _server != null;
  int get port => _port;
  bool get authRequired => _token.isNotEmpty;
  int get sseSessionCount => _sseSessions.length;

  /// 连接地址（启动时缓存；为空表示当前无网络）。
  /// 服务绑定 0.0.0.0，本地回环始终可用（adb reverse / 本机客户端），
  /// 因此固定首个返回 127.0.0.1，其后为局域网地址。
  List<String> get lanUrls => <String>[
    'http://127.0.0.1:$_port/mcp',
    ..._lanIps.map((ip) => 'http://$ip:$_port/mcp'),
  ];

  void configure({
    Assistant? Function()? assistantGetter,
    ChatService? Function()? chatServiceGetter,
    MemoryRepository? Function()? memoryRepositoryGetter,
    WorldBookProvider? Function()? worldBookGetter,
    AgentSkillProvider? Function()? agentSkillGetter,
    InstructionInjectionProvider? Function()? instructionInjectionGetter,
    Future<bool> Function()? keepAliveEnsurer,
    int? port,
    String? token,
  }) {
    if (assistantGetter != null) _assistantGetter = assistantGetter;
    if (chatServiceGetter != null) _chatServiceGetter = chatServiceGetter;
    if (memoryRepositoryGetter != null) {
      _memoryRepositoryGetter = memoryRepositoryGetter;
    }
    if (worldBookGetter != null) _worldBookGetter = worldBookGetter;
    if (agentSkillGetter != null) _agentSkillGetter = agentSkillGetter;
    if (instructionInjectionGetter != null) {
      _instructionInjectionGetter = instructionInjectionGetter;
    }
    if (keepAliveEnsurer != null) _keepAliveEnsurer = keepAliveEnsurer;
    if (port != null && port > 0 && port < 65536) _port = port;
    _token = token ?? _token;
  }

  /// 构造"全量工具" Assistant 视图：以当前助手为底，localToolIds 放开为 exposedToolIds。
  /// getter 未注入/未就绪（如设置页开关路径先于 main 启动）时合成最小 Assistant，
  /// 保证 tools/list 永远返回完整目录而不是空列表。
  Assistant _fullToolAssistant() {
    final base = _assistantGetter?.call();
    if (base != null) {
      return base.copyWith(localToolIds: exposedToolIds);
    }
    return const Assistant(
      id: '__mcp_server__',
      name: 'MCP Server',
      localToolIds: <String>[],
    ).copyWith(localToolIds: exposedToolIds);
  }

  Future<bool> start() async {
    if (_server != null) return true;
    debugPrintSafely(
      '[McpHttpServer] start() called: port=$_port chatGetter=${_chatServiceGetter != null}\n'
      '${StackTrace.current}',
    );
    try {
      if (Platform.isAndroid && await _keepAliveEnsurer?.call() != true) {
        debugPrintSafely(
          '[McpHttpServer] start blocked: keep-alive is not ready',
        );
        return false;
      }
      final server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      server.listen(
        (req) => _handleRequest(req),
        onError: (Object error) {
          debugPrintSafely('[McpHttpServer] listen error: $error');
        },
        cancelOnError: false,
      );
      _server = server;
      _startedAt = DateTime.now();
      _lanIps = await _resolveLanIps();
      _startNetHeartbeat();
      debugPrintSafely(
        '[McpHttpServer] listening on 0.0.0.0:$_port/mcp (lan: ${_lanIps.join(", ")})',
      );
      notifyListeners();
      return true;
    } catch (error) {
      debugPrintSafely('[McpHttpServer] start failed: $error');
      notifyListeners();
      return false;
    }
  }

  Future<void> stop() async {
    debugPrintSafely('[McpHttpServer] stop() called');
    _netHeartbeatTimer?.cancel();
    _netHeartbeatTimer = null;
    final server = _server;
    _server = null;
    for (final id in _sseSessions.keys.toList(growable: false)) {
      _removeSseSession(id);
    }
    await server?.close(force: true);
    notifyListeners();
    debugPrintSafely('[McpHttpServer] stopped');
  }

  // ---------------------------------------------------------------------------
  // HTTP routing
  // ---------------------------------------------------------------------------

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      _addCorsHeaders(req);
      final path = req.uri.path;
      final method = req.method;
      switch (path) {
        case '/':
        case '/.well-known/mcp':
          if (method == 'GET') return await _respondJson(req, _discovery());
          break;
        case '/health':
          if (method == 'GET') {
            return await _respondJson(req, <String, dynamic>{
              'ok': true,
              'server': 'kelivo',
              'endpoint': '/mcp',
              'sseEndpoint': '/sse',
              'sseSessionCount': _sseSessions.length,
              'uptimeMillis': DateTime.now()
                  .difference(_startedAt)
                  .inMilliseconds,
            });
          }
          break;
        // Streamable HTTP 端点
        case '/mcp':
          if (method == 'OPTIONS') return _respondNoContent(req);
          if (method == 'POST') return await _handleStreamablePost(req);
          if (method == 'DELETE') {
            // 客户端终止会话：SSE 会话按头清理；Streamable 本地无状态，直接确认。
            final sid = req.headers.value('mcp-session-id');
            if (sid != null && sid.isNotEmpty) _removeSseSession(sid);
            return await _respondJson(req, <String, dynamic>{'ok': true});
          }
          if (method == 'GET') {
            if (!_authorized(req)) {
              return await _respondJson(
                req,
                _authError(),
                status: HttpStatus.unauthorized,
              );
            }
            final accept = req.headers.value(HttpHeaders.acceptHeader) ?? '';
            if (accept.contains('text/event-stream')) {
              // 服务器不提供 GET 推送流；按规范返回 405，客户端回退到 POST 模式。
              return await _respondJson(req, <String, dynamic>{
                'ok': false,
                'error': 'method_not_allowed',
              }, status: HttpStatus.methodNotAllowed);
            }
            return await _respondJson(req, _discovery());
          }
          break;
        // 旧版 HTTP+SSE 传输端点
        case '/sse':
          if (method == 'OPTIONS') return _respondNoContent(req);
          if (method == 'GET') return await _handleSseConnect(req);
          break;
        case '/messages':
          if (method == 'OPTIONS') return _respondNoContent(req);
          if (method == 'POST') return await _handleLegacyMessagesPost(req);
          break;
        // 便捷 JSON-RPC 端点（与 /mcp POST 等价，供脚本快速调用）
        case '/rpc':
          if (method == 'OPTIONS') return _respondNoContent(req);
          if (method == 'POST') return await _handleStreamablePost(req);
          break;
        default:
          break;
      }
      await _respondJson(req, <String, dynamic>{
        'ok': false,
        'error': 'not_found',
        'path': path,
      }, status: HttpStatus.notFound);
    } catch (error) {
      debugPrintSafely('[McpHttpServer] request error: $error');
      try {
        await _respondJson(req, <String, dynamic>{
          'ok': false,
          'error': 'internal_error',
          'detail': error.toString(),
        }, status: HttpStatus.internalServerError);
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // Streamable HTTP（POST /mcp）
  // ---------------------------------------------------------------------------

  Future<void> _handleStreamablePost(HttpRequest req) async {
    if (!_authorized(req)) {
      return _respondJson(req, _authError(), status: HttpStatus.unauthorized);
    }
    final contentLength = req.contentLength;
    if (contentLength > maxRequestBytes) {
      return _respondJson(
        req,
        _rpcError(null, -32002, 'Request body too large (max 8MB)'),
        status: HttpStatus.requestEntityTooLarge,
      );
    }
    final body = await utf8.decoder.bind(req).join();
    if (utf8.encode(body).length > maxRequestBytes) {
      return _respondJson(
        req,
        _rpcError(null, -32002, 'Request body too large (max 8MB)'),
        status: HttpStatus.requestEntityTooLarge,
      );
    }

    // initialize 请求：按 Streamable HTTP 规范在响应头下发会话 ID。
    final clientSession = req.headers.value('mcp-session-id') ?? '';
    if (clientSession.isEmpty && _isInitializeBody(body)) {
      req.response.headers.add('mcp-session-id', _newSessionId());
      // 提示客户端服务器不提供 GET 事件流（405），避免其长时间挂等。
      req.response.headers.add('mcp-protocol-hint', 'no-server-push');
    }

    final response = await _dispatchBody(
      body,
      analyzerContextKey: clientSession.isEmpty
          ? 'mcp-anonymous'
          : 'mcp:$clientSession',
    );
    if (response == null) {
      // 全 notification：按规范回 202 Accepted 空体
      req.response.statusCode = HttpStatus.accepted;
      req.response.close();
      return;
    }
    final accept = req.headers.value(HttpHeaders.acceptHeader) ?? '';
    if (accept.contains('text/event-stream')) {
      // charset 必须 utf-8：dart:io 对无 charset 的 text/* 用 Latin-1 编码，
      // 含中文的工具描述会抛 "Contains invalid characters"（曾致 MCP 客户端连接失败）。
      return _respondText(
        req,
        'event: message\ndata: ${await _encodeJsonBody(response)}\n\n',
        ContentType('text', 'event-stream', charset: 'utf-8'),
      );
    }
    return _respondJson(req, response);
  }

  bool _isInitializeBody(String body) {
    final trimmed = body.trimLeft();
    if (trimmed.isEmpty || trimmed.startsWith('[')) return false;
    try {
      final decoded = jsonDecode(trimmed);
      return decoded is Map<String, dynamic> &&
          decoded['method'] == 'initialize';
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // 旧版 HTTP+SSE 传输（GET /sse + POST /messages）
  // ---------------------------------------------------------------------------

  Future<void> _handleSseConnect(HttpRequest req) async {
    if (!_authorized(req)) {
      return _respondJson(req, _authError(), status: HttpStatus.unauthorized);
    }
    final res = req.response;
    final sessionId = _newSessionId();
    res.statusCode = HttpStatus.ok;
    res.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    res.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    res.persistentConnection = true;

    final session = _SseSession(sessionId, res);
    _sseSessions[sessionId] = session;
    debugPrintSafely(
      '[McpHttpServer] SSE session open: $sessionId (${_sseSessions.length} total)',
    );
    session.heartbeat = Timer.periodic(sseHeartbeat, (_) {
      if (session.closed) {
        _removeSseSession(sessionId);
        return;
      }
      session.push(': ping\n\n');
    });

    // 规范要求：第一个事件为 endpoint，data 为消息回传 URI（字符串）。
    await session.push(
      'event: endpoint\ndata: /messages?sessionId=$sessionId\n\n',
    );

    try {
      await res.done;
    } catch (_) {}
    _removeSseSession(sessionId);
  }

  Future<void> _handleLegacyMessagesPost(HttpRequest req) async {
    if (!_authorized(req)) {
      return _respondJson(req, _authError(), status: HttpStatus.unauthorized);
    }
    final sessionId = req.uri.queryParameters['sessionId'] ?? '';
    final session = _sseSessions[sessionId];
    if (session == null || session.closed) {
      return _respondJson(req, <String, dynamic>{
        'ok': false,
        'error': 'unknown_session',
      }, status: HttpStatus.badRequest);
    }
    if (req.contentLength > maxRequestBytes) {
      return _respondJson(
        req,
        _rpcError(null, -32002, 'Request body too large (max 8MB)'),
        status: HttpStatus.requestEntityTooLarge,
      );
    }
    final body = await utf8.decoder.bind(req).join();
    final response = await _dispatchBody(
      body,
      analyzerContextKey: 'mcp:$sessionId',
    );
    if (response != null) {
      if (response is List) {
        for (final item in response) {
          await session.push(
            'event: message\ndata: ${await _encodeJsonBody(item)}\n\n',
          );
        }
      } else {
        await session.push(
          'event: message\ndata: ${await _encodeJsonBody(response)}\n\n',
        );
      }
    }
    // 按规范回 202 Accepted，真正响应走 SSE 流。
    req.response.statusCode = HttpStatus.accepted;
    req.response.headers.contentLength = 0;
    await req.response.close();
  }

  void _removeSseSession(String id) {
    final session = _sseSessions.remove(id);
    if (session == null) return;
    session.heartbeat?.cancel();
    session.closed = true;
    try {
      session.response.close();
    } catch (_) {}
    debugPrintSafely(
      '[McpHttpServer] SSE session closed: $id (${_sseSessions.length} remaining)',
    );
  }

  String _newSessionId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // ---------------------------------------------------------------------------
  // JSON-RPC dispatch
  // ---------------------------------------------------------------------------

  Future<dynamic> _dispatchBody(
    String body, {
    String analyzerContextKey = 'mcp-anonymous',
  }) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return _rpcError(null, -32700, 'Parse error');
    if (trimmed.startsWith('[')) {
      dynamic arr;
      try {
        arr = jsonDecode(trimmed);
      } catch (_) {
        return _rpcError(null, -32700, 'Parse error');
      }
      if (arr is! List || arr.isEmpty) {
        return _rpcError(null, -32600, 'Invalid Request');
      }
      final out = <dynamic>[];
      var allNotifications = true;
      for (final item in arr) {
        if (item is! Map<String, dynamic>) {
          out.add(_rpcError(null, -32600, 'Invalid Request'));
          allNotifications = false;
          continue;
        }
        final res = await _dispatch(
          item,
          analyzerContextKey: analyzerContextKey,
        );
        out.add(res);
        if (res != null) allNotifications = false;
      }
      // 全是 notification（无 id）→ 202 空体
      return allNotifications ? null : out;
    }
    dynamic req;
    try {
      req = jsonDecode(trimmed);
    } catch (_) {
      return _rpcError(null, -32700, 'Parse error');
    }
    if (req is! Map<String, dynamic>) {
      return _rpcError(null, -32600, 'Invalid Request');
    }
    return _dispatch(req, analyzerContextKey: analyzerContextKey);
  }

  Future<Map<String, dynamic>?> _dispatch(
    Map<String, dynamic> req, {
    required String analyzerContextKey,
  }) async {
    final id = req['id'];
    final method = (req['method'] ?? '').toString();
    if (req['jsonrpc'] != '2.0' || method.isEmpty) {
      return _rpcError(id, -32600, 'Invalid Request');
    }
    // JSON-RPC notification（无 id）→ 返回 null，HTTP 层回 202 空体
    if (id == null) return null;
    final params = (req['params'] is Map<String, dynamic>)
        ? req['params'] as Map<String, dynamic>
        : <String, dynamic>{};
    dynamic result;
    switch (method) {
      case 'initialize':
        // 协议版本协商：客户端请求的版本受支持则回显，否则回落最新版。
        // 新连接建立时重置共享循环检测基线：避免上一个客户端的最后一次
        // 调用指纹 strike 到新客户端的第一条相同调用（跨客户端误判）。
        _toolCallLoopGuard.reset();
        final requested = (params['protocolVersion'] ?? '').toString();
        final negotiated = supportedProtocolVersions.contains(requested)
            ? requested
            : '2025-06-18';
        final serverVersion = await _readServerVersion();
        result = <String, dynamic>{
          'protocolVersion': negotiated,
          'capabilities': <String, dynamic>{
            'tools': <String, dynamic>{'listChanged': false},
          },
          'serverInfo': <String, dynamic>{
            'name': 'SoLab',
            'version': serverVersion,
          },
          'instructions': _mcpInstructions,
          '_meta': <String, dynamic>{
            'fullToolCount': exposedToolIds.length,
            'decisionPolicyVersion': ApkAgentPolicy.version,
            'hint':
                'tools/list advertises the complete built-in SoLab catalog '
                '(SO/Dex/APK/file). SO tasks: so_analyze(action=open) first, keep workspaceId.',
          },
        };
        break;
      case 'notifications/initialized':
        // Notification: no response envelope needed, but returning an empty
        // result keeps strict JSON-RPC clients happy.
        result = <String, dynamic>{};
        break;
      case 'ping':
        result = <String, dynamic>{'ok': true};
        break;
      case 'resources/list':
        result = <String, dynamic>{'resources': <dynamic>[]};
        break;
      case 'prompts/list':
        result = <String, dynamic>{'prompts': <dynamic>[]};
        break;
      case 'tools/list':
        result = _toolsList();
        break;
      case 'tools/call':
        result = await _callTool(
          params,
          analyzerContextKey: analyzerContextKey,
        );
        break;
      default:
        return _rpcError(id, -32601, 'Method not found');
    }
    return <String, dynamic>{'jsonrpc': '2.0', 'id': id, 'result': result};
  }

  Future<String> _readServerVersion() {
    return _serverVersion ??= _loadServerVersion();
  }

  Future<String> _loadServerVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final version = packageInfo.version.trim();
      final buildNumber = packageInfo.buildNumber.trim();
      if (version.isEmpty) return buildNumber.isEmpty ? '0.0.0' : buildNumber;
      if (buildNumber.isEmpty || version.endsWith('+$buildNumber')) {
        return version;
      }
      return '$version+$buildNumber';
    } catch (_) {
      return '0.0.0';
    }
  }

  /// schema 保持全量的工具：写操作三件套（dryRun/confirm 契约本身在
  /// schema 里）与流程入口。其余工具描述截断，全量按需从
  /// get_solab_tool_map 读取（与 App 内 Schema 懒加载同思路）。
  static const Set<String> _schemaKeepFullIds = <String>{
    LocalToolNames.routeTask,
    LocalToolNames.apkPatchDex,
    LocalToolNames.apkSignatureBypass,
    LocalToolNames.apkPatchManifest,
    LocalToolNames.soPatchIntoApk,
    LocalToolNames.file,
    LocalToolNames.apkRebuild,
    LocalToolNames.apkToolMap,
  };

  /// tools/list 描述压缩上限（工具级 / 属性级）。
  static const int _maxToolDescriptionChars = 480;
  static const int _maxPropertyDescriptionChars = 240;

  static String _truncateSchemaText(String text, int max) {
    if (text.length <= max) return text;
    var cut = text.substring(0, max);
    final boundary = cut.lastIndexOf(RegExp(r'[\n。.!?;；]'));
    if (boundary > max ~/ 2) {
      cut = cut.substring(0, boundary + 1);
    }
    return '$cut…';
  }

  /// 压缩单个工具的 MCP schema：描述截断 + 属性描述截断。
  /// 参数名/类型/enum 值一律保留（调用合法性所需），只减描述文本。
  static Map<String, dynamic> _compactMcpToolSchema(
    String internalName,
    Map<String, dynamic> function,
  ) {
    if (_schemaKeepFullIds.contains(internalName) ||
        internalName == taskStatusTool) {
      return function;
    }
    final next = Map<String, dynamic>.from(function);
    final description = function['description']?.toString() ?? '';
    next['description'] =
        '${_truncateSchemaText(description, _maxToolDescriptionChars)}\n'
        '[Full parameters: call get_solab_tool_map once.]';
    final parameters = function['parameters'];
    if (parameters is Map) {
      final params = Map<String, dynamic>.from(parameters);
      final properties = params['properties'];
      if (properties is Map) {
        final compactedProps = <String, dynamic>{};
        properties.forEach((key, value) {
          if (value is Map && value['description'] != null) {
            final prop = Map<String, dynamic>.from(value);
            prop['description'] = _truncateSchemaText(
              value['description'].toString(),
              _maxPropertyDescriptionChars,
            );
            compactedProps[key] = prop;
          } else {
            compactedProps[key] = value;
          }
        });
        params['properties'] = compactedProps;
      }
      next['parameters'] = params;
    }
    return next;
  }

  Map<String, dynamic> _toolsList() {
    final assistant = _fullToolAssistant();
    // T9 后 buildToolDefinitions 返回不可变列表：先复制为可变再并入
    // analyzer 高阶 API，否则对定长 list 调 addAll 抛
    // "Cannot add to a fixed-length list"（tools/list 整体 internal_error）。
    final definitions = <Map<String, dynamic>>[
      ...LocalToolsService.buildToolDefinitions(
        assistant: assistant,
        supportsTools: true,
      ),
    ];
    // 只并入白名单里的 analyzer 高阶 API（open/global_search/
    // find_field_usage/analyze_business_state），其余 18 个桩不暴露。
    final analyzerWhitelisted = AnalyzerToolNames.all
        .where(exposedToolIds.contains)
        .toSet();
    definitions.addAll(
      AnalyzerGatewayTools.buildDefinitions(analyzerWhitelisted),
    );
    final tools = <dynamic>[];
    for (final def in definitions) {
      final rawFunction = (def['function'] as Map?)?.cast<String, dynamic>();
      if (rawFunction == null) continue;
      final internalName = rawFunction['name'].toString();
      final function = _compactMcpToolSchema(internalName, rawFunction);
      final inputSchema = Map<String, dynamic>.from(
        (function['parameters'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{
              'type': 'object',
              'properties': <String, dynamic>{},
            },
      );
      if (function['name'] == LocalToolNames.apkRebuild) {
        inputSchema['properties'] = <String, dynamic>{
          ...((inputSchema['properties'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{}),
          'async': <String, dynamic>{
            'type': 'boolean',
            'description':
                'MCP only: queue the task and return taskId immediately; poll mcp_task_status for its result.',
          },
        };
      }
      inputSchema.putIfAbsent('additionalProperties', () => false);
      final publishedName = _publishedToolAliases[internalName] ?? internalName;
      final entry = <String, dynamic>{
        'name': publishedName,
        'description': function['description'].toString().replaceAll(
          'analyzer.',
          'analyzer_',
        ),
        'inputSchema': inputSchema,
        'outputSchema': _toolOutputSchema,
        'annotations': <String, dynamic>{
          'readOnlyHint': _readOnlyToolIds.contains(internalName),
        },
      };
      tools.add(entry);
    }
    tools.add(<String, dynamic>{
      'name': taskStatusTool,
      'description':
          'Poll a SoLab asynchronous MCP task. apk_rebuild with dex=false is queued automatically; pass async=true to queue another long local tool call.',
      'inputSchema': <String, dynamic>{
        'type': 'object',
        'additionalProperties': false,
        'properties': <String, dynamic>{
          'taskId': <String, dynamic>{
            'type': 'string',
            'description': 'The taskId returned by the queued tool call.',
          },
        },
        'required': <String>['taskId'],
      },
      'outputSchema': _toolOutputSchema,
      'annotations': const <String, dynamic>{'readOnlyHint': true},
    });
    return <String, dynamic>{
      'tools': tools,
      '_meta': <String, dynamic>{
        'returnedCount': tools.length,
        'fullToolCount': exposedToolIds.length + 1,
        'hint':
            'All tools are local on this device. Use mcp_task_status to poll an async APK rebuild task.',
      },
    };
  }

  Future<Map<String, dynamic>> _callTool(
    Map<String, dynamic> params, {
    required String analyzerContextKey,
  }) async {
    final requestedName = (params['name'] ?? '').toString();
    final name = _internalToolAliases[requestedName] ?? requestedName;
    final args = _toolArguments(params['arguments']);
    if (name == LocalToolNames.apkToolMap) {
      final requestedTool = args['tool']?.toString();
      final internalTool = _internalToolAliases[requestedTool];
      if (internalTool != null) args['tool'] = internalTool;
    }
    try {
      // FGS/WakeLock 在 server.start() 前已确认。这里不能再把每个工具调用
      // 同步绑到 Activity 的 MethodChannel：任务界面被移除后原生服务仍在，
      // 但该通道可能不再回包，曾导致 HTTP 与 tools/list 正常、所有工具永久挂起。
      if (name == taskStatusTool) return _taskStatus(args);
      if (!exposedToolIds.contains(name)) {
        return _toolTextResult(
          _toolErrorOutput(
            'tool_not_found',
            'TOOL_NOT_FOUND: $requestedName. Call tools/list for the catalog.',
          ),
          isError: true,
        );
      }
      final isReadOnly = _isReadOnlyCall(name, args);
      final readGateIndex = isReadOnly
          ? _nextReadGate++ % _readToolGates.length
          : null;
      final blockedTool = isReadOnly
          ? _blockedReadToolNames[readGateIndex!]
          : _blockedWriteToolName;
      if (blockedTool != null) {
        final blockedFor = DateTime.now().difference(
          (isReadOnly
                  ? _blockedReadSince[readGateIndex!]
                  : _blockedWriteSince) ??
              DateTime.now(),
        );
        if (blockedFor >= _laneRecoveryCooldown) {
          // 冷却期满自动解封：放弃等待僵尸 Future，重置执行通道。
          if (isReadOnly) {
            _blockedReadToolNames[readGateIndex!] = null;
            _blockedReadSince[readGateIndex] = null;
            _readToolGates[readGateIndex] = Future<void>.value();
          } else {
            _blockedWriteToolName = null;
            _blockedWriteSince = null;
            _writeToolGate = Future<void>.value();
          }
        } else {
          final waitSeconds = (_laneRecoveryCooldown - blockedFor).inSeconds;
          return _toolTextResult(
            _toolErrorOutput(
              'tool_lane_blocked',
              'MCP_TOOL_LANE_BLOCKED: $blockedTool is still running after its '
                  'timeout. The lane auto-recovers in ~$waitSeconds s; wait, '
                  'poll mcp_task_status, or restart MCP mode to recover now. '
                  'Do not repeat the same call after recovery — narrow it first.',
            ),
            isError: true,
          );
        }
      }
      final loopDecision = _toolCallLoopGuard.check(
        name,
        args,
        polling: _isPollingCall(name, args),
      );
      if (!loopDecision.allowed) {
        return _toolTextResult(
          _toolErrorOutput('loop_detected', loopDecision.message),
          isError: true,
        );
      }
      final assistant = _fullToolAssistant();
      debugPrintSafely(
        '[McpHttpServer] call $name: chatGetter=${_chatServiceGetter != null} '
        'repoGetter=${_memoryRepositoryGetter != null}',
      );
      if (_shouldRunAsync(name, args)) {
        return _startAsyncToolCall(
          name,
          args,
          assistant,
          analyzerContextKey: analyzerContextKey,
          readGateIndex: readGateIndex,
          isReadOnly: isReadOnly,
        );
      }
      if (_shouldRunAdaptive(name, args)) {
        return await _startAdaptiveToolCall(
          name,
          args,
          assistant,
          analyzerContextKey: analyzerContextKey,
          readGateIndex: readGateIndex,
          isReadOnly: isReadOnly,
        );
      }
      // 打开工作区只读取已缓存报告并更新内存状态，不依赖底层分析引擎。
      // 让它绕过长构建任务的队列，保证连接和工作区复用即时可用。
      final output = name == AnalyzerToolNames.open
          ? await _runTool(
              name,
              args,
              assistant,
              analyzerContextKey: analyzerContextKey,
            )
          : await _enqueueToolCall(
              name,
              args,
              () => _runTool(
                name,
                args,
                assistant,
                analyzerContextKey: analyzerContextKey,
              ),
              readGateIndex: readGateIndex,
              isReadOnly: isReadOnly,
            );
      return _completedToolResult(name, output);
    } catch (error, stack) {
      // 失败重连（网络原因等）：超时/异常的调用没有可信结果，移除其
      // 指纹，客户端网络恢复后可用相同参数重试而不被 LOOP_DETECTED 拦。
      _toolCallLoopGuard.forget(name, args);
      final message = error is TimeoutException
          ? 'TOOL_TIMEOUT: $name exceeded ${error.duration?.inSeconds ?? 0}s. '
                'The lane auto-recovers after its cooldown; the same call may '
                'be retried once the lane is free.'
          : 'TOOL_EXCEPTION: $name :: ${error.toString()} :: $stack';
      return _toolTextResult(
        _toolErrorOutput(
          error is TimeoutException ? 'tool_timeout' : 'tool_exception',
          message,
        ),
        isError: true,
      );
    }
  }

  Map<String, dynamic> _toolArguments(Object? raw) {
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return decoded.map((key, value) => MapEntry(key.toString(), value));
        }
      } catch (_) {}
    }
    return <String, dynamic>{};
  }

  bool _shouldRunAsync(String name, Map<String, dynamic> args) =>
      name == LocalToolNames.apkAnalyzeWorkspace ||
      args['async'] == true ||
      (name == LocalToolNames.apkRebuild && args['dex'] == false);

  bool _shouldRunAdaptive(String name, Map<String, dynamic> args) {
    if (name == LocalToolNames.soAnalyze &&
        args['action'] == 'blutter' &&
        const {'analyze', 'status', 'cancel'}.contains(args['blutterAction'])) {
      // Blutter 自己已经是 job 模型。analyze 只需完成检查并返回 jobId；
      // status(wait=true) 最多等一个心跳。再包一层 MCP task 会吞掉真实阶段。
      return false;
    }
    if (_adaptiveToolIds.contains(name) ||
        AnalyzerToolNames.all.contains(name)) {
      return true;
    }
    if (name != LocalToolNames.file) return false;
    return !const {'list', 'info'}.contains(args['action']);
  }

  /// 轮询类调用：参数相同但结果随时间变化（异步任务状态查询），豁免循环检测。
  bool _isPollingCall(String name, Map<String, dynamic> args) {
    if (name == taskStatusTool) return true;
    // analyzer.open 幂等（重复调用复用，结果稳定），豁免循环检测。
    if (name == AnalyzerToolNames.open) {
      return true;
    }
    if (name == LocalToolNames.soAnalyze) {
      final action = args['action']?.toString();
      final blutterAction = args['blutterAction']?.toString();
      if (action == 'status' || blutterAction == 'status') return true;
    }
    return false;
  }

  Future<String?> _runTool(
    String name,
    Map<String, dynamic> args,
    Assistant assistant, {
    required String analyzerContextKey,
  }) async {
    final detachBlutterWait =
        name == LocalToolNames.soAnalyze &&
        args['action'] == 'blutter' &&
        args['blutterAction'] == 'analyze' &&
        args['wait'] == true;
    final executionArgs = detachBlutterWait
        ? <String, dynamic>{...args, 'wait': false}
        : args;
    final output = await LocalToolsService.tryHandleToolCall(
      name,
      executionArgs,
      assistant,
      chatService: _chatServiceGetter?.call(),
      memoryRepository: _memoryRepositoryGetter?.call(),
      worldBookProvider: _worldBookGetter?.call(),
      agentSkillProvider: _agentSkillGetter?.call(),
      instructionInjectionProvider: _instructionInjectionGetter?.call(),
      analyzerContextKey: analyzerContextKey,
    );
    if (output == null) return null;
    final normalizedOutput = name == LocalToolNames.apkToolMap
        ? _publishToolMapAliases(output)
        : output;
    if (ToolCallLoopGuard.changesState(name, executionArgs) &&
        ToolCallLoopGuard.succeeded(normalizedOutput)) {
      _toolCallLoopGuard.advanceState(name, executionArgs);
    }
    if (!detachBlutterWait) return normalizedOutput;
    return _annotateDetachedBlutterWait(normalizedOutput);
  }

  String _publishToolMapAliases(String output) {
    try {
      final decoded = jsonDecode(output);
      if (decoded is! Map) return output;
      final root = Map<String, dynamic>.from(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
      final rawData = root['data'];
      final data = rawData is Map
          ? Map<String, dynamic>.from(
              rawData.map((key, value) => MapEntry(key.toString(), value)),
            )
          : root;
      final tools = data['tools'];
      if (tools is List) {
        data['tools'] = <dynamic>[
          for (final tool in tools)
            if (tool is Map)
              <String, dynamic>{
                ...tool.map((key, value) => MapEntry(key.toString(), value)),
                if (tool['name'] case final String internalName)
                  'name': _publishedToolAliases[internalName] ?? internalName,
              }
            else
              tool,
        ];
      }
      final callableNames = data['callableToolNames'];
      if (callableNames is List) {
        data['callableToolNames'] = <dynamic>[
          for (final value in callableNames)
            if (value is String)
              _publishedToolAliases[value] ?? value
            else
              value,
        ];
      }
      if (rawData is Map) root['data'] = data;
      return jsonEncode(root);
    } catch (_) {
      return output;
    }
  }

  String _annotateDetachedBlutterWait(String output) {
    try {
      final decoded = jsonDecode(output);
      if (decoded is! Map) return output;
      final raw = Map<String, dynamic>.from(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
      final note = <String, dynamic>{
        'waitDetached': true,
        'message':
            'MCP 已将长 Blutter 分析转为后台任务。使用返回的 jobId 调 blutterAction=status 查询真实阶段。',
      };
      final data = raw['data'];
      if (data is Map) {
        raw['data'] = <String, dynamic>{
          ...data.map((key, value) => MapEntry(key.toString(), value)),
          'mcpExecution': note,
        };
      } else {
        raw['mcpExecution'] = note;
      }
      return jsonEncode(raw);
    } catch (_) {
      return output;
    }
  }

  Map<String, dynamic> _startAsyncToolCall(
    String name,
    Map<String, dynamic> args,
    Assistant assistant, {
    required String analyzerContextKey,
    required int? readGateIndex,
    required bool isReadOnly,
  }) {
    _pruneFinishedTasks();
    final task = _McpToolTask(_newSessionId(), name, args);
    _toolTasks[task.id] = task;
    unawaited(() async {
      try {
        await _enqueueToolCall(
          name,
          args,
          () async {
            task.start();
            try {
              final output = await _runTool(
                name,
                args,
                assistant,
                analyzerContextKey: analyzerContextKey,
              );
              task.complete(output ?? 'TOOL_NOT_HANDLED: $name');
            } catch (error) {
              task.fail(error.toString());
            }
          },
          readGateIndex: readGateIndex,
          isReadOnly: isReadOnly,
        );
      } catch (error) {
        task.fail(error.toString());
      }
    }());
    return _queuedTaskResult(task);
  }

  Future<Map<String, dynamic>> _startAdaptiveToolCall(
    String name,
    Map<String, dynamic> args,
    Assistant assistant, {
    required String analyzerContextKey,
    required int? readGateIndex,
    required bool isReadOnly,
  }) async {
    _pruneFinishedTasks();
    final task = _McpToolTask(_newSessionId(), name, args);
    _toolTasks[task.id] = task;
    final inline = Completer<_McpAdaptiveResult>();
    unawaited(() async {
      try {
        final output = await _enqueueToolCall(
          name,
          args,
          () async {
            task.start();
            return _runTool(
              name,
              args,
              assistant,
              analyzerContextKey: analyzerContextKey,
            );
          },
          readGateIndex: readGateIndex,
          isReadOnly: isReadOnly,
        );
        task.complete(output ?? 'TOOL_NOT_HANDLED: $name');
        if (!inline.isCompleted) {
          inline.complete(_McpAdaptiveResult(output: output));
        }
      } catch (error) {
        task.fail(error.toString());
        if (!inline.isCompleted) {
          inline.complete(_McpAdaptiveResult(error: error));
        }
      }
    }());
    final raced = await Future.any<Object?>(<Future<Object?>>[
      inline.future,
      Future<Object?>.delayed(_adaptiveInlineWindow),
    ]);
    if (raced is _McpAdaptiveResult) {
      _toolTasks.remove(task.id);
      if (raced.error != null) throw raced.error!;
      return _completedToolResult(name, raced.output);
    }
    return _queuedTaskResult(task);
  }

  Map<String, dynamic> _completedToolResult(String name, String? output) {
    if (output == null) {
      return _toolTextResult('TOOL_NOT_HANDLED: $name', isError: true);
    }
    final limit = _isPromptLikeTool(name) ? 4000 : maxResultChars;
    final normalized = _normalizeToolOutput(output);
    final normalizedPayload = jsonDecode(normalized);
    final isError =
        normalizedPayload is Map && normalizedPayload['ok'] == false;
    return _toolTextResult(
      _truncate(normalized, limitOverride: limit),
      isError: isError,
    );
  }

  Map<String, dynamic> _queuedTaskResult(_McpToolTask task) {
    return _toolTextResult(
      _normalizeToolOutput(
        jsonEncode(<String, dynamic>{
          ...task.toJson(),
          'pollTool': taskStatusTool,
          'message': '任务已排队。请用 mcp_task_status 轮询 taskId，完成后读取 result。',
        }),
      ),
      isError: false,
    );
  }

  Map<String, dynamic> _taskStatus(Map<String, dynamic> args) {
    _pruneFinishedTasks();
    final taskId = (args['taskId'] ?? '').toString().trim();
    final task = _toolTasks[taskId];
    if (task == null) {
      return _toolTextResult(
        _toolErrorOutput('task_not_found', 'TASK_NOT_FOUND: $taskId'),
        isError: true,
      );
    }
    return _toolTextResult(
      _normalizeToolOutput(jsonEncode(task.toJson())),
      isError: task.status == _McpTaskStatus.failed,
    );
  }

  void _pruneFinishedTasks() {
    final now = DateTime.now();
    _toolTasks.removeWhere((_, task) {
      final finishedAt = task.finishedAt;
      return finishedAt != null && now.difference(finishedAt) > taskRetention;
    });
  }

  Duration _toolTimeoutFor(String name, Map<String, dynamic> args) {
    if (name == LocalToolNames.file &&
        const {
          'read',
          'list',
          'info',
          'copy',
          'rename',
        }.contains(args['action'])) {
      return _fileToolTimeout;
    }
    if (name == LocalToolNames.soAnalyze ||
        name == LocalToolNames.apkAnalyzeWorkspace ||
        name == LocalToolNames.apkPatchDex ||
        name == LocalToolNames.apkSignatureBypass ||
        name == LocalToolNames.apkRebuild ||
        args['async'] == true) {
      return _heavyToolTimeout;
    }
    return _defaultToolTimeout;
  }

  /// 排队执行：任一工具超时后隔离整个执行通道，避免挂起 Future 永久堵住
  /// 后续请求；隔离期间拒绝新任务，不冒险并发写入原生工具链。
  Future<T> _enqueueToolCall<T>(
    String name,
    Map<String, dynamic> args,
    Future<T> Function() task, {
    required int? readGateIndex,
    required bool isReadOnly,
  }) {
    final gateIndex = isReadOnly ? readGateIndex! : -1;
    final gate = isReadOnly ? _readToolGates[gateIndex] : _writeToolGate;
    final timeout = _toolTimeoutFor(name, args);
    final guarded = gate.then((_) {
      final running = task();
      return running.timeout(
        timeout,
        onTimeout: () {
          if (isReadOnly) {
            _blockedReadToolNames[gateIndex] = name;
            _blockedReadSince[gateIndex] = DateTime.now();
          } else {
            _blockedWriteToolName = name;
            _blockedWriteSince = DateTime.now();
          }
          running.then(
            (_) {
              if (isReadOnly) {
                _blockedReadToolNames[gateIndex] = null;
                _blockedReadSince[gateIndex] = null;
              } else {
                _blockedWriteToolName = null;
                _blockedWriteSince = null;
              }
            },
            onError: (_) {
              if (isReadOnly) {
                _blockedReadToolNames[gateIndex] = null;
                _blockedReadSince[gateIndex] = null;
              } else {
                _blockedWriteToolName = null;
                _blockedWriteSince = null;
              }
            },
          );
          throw TimeoutException('$name timed out', timeout);
        },
      );
    });
    final nextGate = guarded.then((_) {}, onError: (_) {});
    if (isReadOnly) {
      _readToolGates[gateIndex] = nextGate;
    } else {
      _writeToolGate = nextGate;
    }
    return guarded;
  }

  Map<String, dynamic> _toolTextResult(String text, {required bool isError}) {
    return <String, dynamic>{
      'isError': isError,
      'content': <dynamic>[
        <String, dynamic>{'type': 'text', 'text': text},
      ],
    };
  }

  static const Map<String, dynamic> _toolOutputSchema = <String, dynamic>{
    'type': 'object',
    'additionalProperties': false,
    'properties': <String, dynamic>{
      'ok': <String, dynamic>{'type': 'boolean'},
      'data': <String, dynamic>{},
      'error': <String, dynamic>{
        'type': <String>['object', 'null'],
        'properties': <String, dynamic>{
          'code': <String, dynamic>{'type': 'string'},
          'message': <String, dynamic>{'type': 'string'},
          'recoverable': <String, dynamic>{'type': 'boolean'},
          'retrySameArguments': <String, dynamic>{'type': 'boolean'},
        },
        'required': <String>[
          'code',
          'message',
          'recoverable',
          'retrySameArguments',
        ],
      },
      'nextActions': <String, dynamic>{'type': 'array'},
    },
    'required': <String>['ok', 'data', 'error', 'nextActions'],
  };

  String _normalizeToolOutput(String output) {
    try {
      final decoded = jsonDecode(output);
      if (decoded is Map) {
        final raw = Map<String, dynamic>.from(
          decoded.map((key, value) => MapEntry(key.toString(), value)),
        );
        if (raw.containsKey('data') &&
            raw.containsKey('error') &&
            raw.containsKey('nextActions') &&
            raw['ok'] is bool) {
          return jsonEncode(raw);
        }
        final rawError = raw['error'];
        final failed = raw['ok'] == false || rawError != null;
        final data = Map<String, dynamic>.from(raw)
          ..remove('ok')
          ..remove('error')
          ..remove('nextActions');
        return jsonEncode(<String, dynamic>{
          'ok': !failed,
          'data': data,
          'error': failed
              ? <String, dynamic>{
                  'code': rawError is Map
                      ? (rawError['code'] ?? 'tool_failed').toString()
                      : rawError is String && rawError.isNotEmpty
                      ? rawError
                      : 'tool_failed',
                  'message': rawError is Map
                      ? (rawError['message'] ?? rawError).toString()
                      : (raw['message'] ?? rawError ?? '工具执行失败').toString(),
                  'recoverable': true,
                  'retrySameArguments': false,
                }
              : null,
          'nextActions': raw['nextActions'] is List
              ? raw['nextActions']
              : const <dynamic>[],
        });
      }
      return jsonEncode(<String, dynamic>{
        'ok': true,
        'data': decoded,
        'error': null,
        'nextActions': const <dynamic>[],
      });
    } catch (_) {
      return jsonEncode(<String, dynamic>{
        'ok': true,
        'data': output,
        'error': null,
        'nextActions': const <dynamic>[],
      });
    }
  }

  String _toolErrorOutput(String code, String message) =>
      jsonEncode(<String, dynamic>{
        'ok': false,
        'data': null,
        'error': <String, dynamic>{
          'code': code,
          'message': message,
          'recoverable': true,
          'retrySameArguments': false,
        },
        'nextActions': const <dynamic>[],
      });

  /// 分级截断：长提示词/长结果按工具类别用不同上限，防止撑爆远端 AI 上下文。
  /// [limitOverride] 为指定工具的更低上限（如内部技能/知识提示词）。
  String _truncate(String text, {int? limitOverride}) {
    final limit = limitOverride ?? maxResultChars;
    if (text.length <= limit) return text;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        final envelope = <String, dynamic>{
          'ok': decoded['ok'] is bool ? decoded['ok'] : true,
          'data': <String, dynamic>{
            'truncated': true,
            'originalLength': text.length,
            'preview': '',
          },
          'error': decoded['error'],
          'nextActions': decoded['nextActions'] is List
              ? decoded['nextActions']
              : const <dynamic>[],
        };
        var previewLength = limit ~/ 2;
        while (previewLength > 0) {
          (envelope['data'] as Map<String, dynamic>)['preview'] = text
              .substring(0, previewLength);
          final encoded = jsonEncode(envelope);
          if (encoded.length <= limit) return encoded;
          previewLength ~/= 2;
        }
        (envelope['data'] as Map<String, dynamic>)['preview'] = '';
        return jsonEncode(envelope);
      }
    } catch (_) {}
    return jsonEncode(<String, dynamic>{
      'ok': true,
      'data': <String, dynamic>{
        'truncated': true,
        'originalLength': text.length,
        'preview': text.substring(0, limit ~/ 2),
      },
      'error': null,
      'nextActions': const <dynamic>[],
    });
  }

  /// 内部提示词类工具（技能正文/知识条目）：仅给远端 AI 摘要，不吐全文。
  static bool _isPromptLikeTool(String name) =>
      name == LocalToolNames.apkSkill ||
      name == LocalToolNames.apkKnowledge ||
      name == LocalToolNames.installedSkills;

  // ---------------------------------------------------------------------------
  // Discovery / auth / responses
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _discovery() {
    return <String, dynamic>{
      'ok': true,
      'name': 'SoLab',
      'protocol': 'MCP JSON-RPC 2.0',
      'transports': <dynamic>['streamable-http', 'http+sse'],
      'streamableHttpEndpoint': '/mcp',
      'sseEndpoint': '/sse',
      'messagesEndpoint': '/messages',
      'methods': <dynamic>[
        'initialize',
        'notifications/initialized',
        'ping',
        'tools/list',
        'tools/call',
        'resources/list',
        'prompts/list',
      ],
      'lanUrls': _lanIps.map((ip) => 'http://$ip:$_port/mcp').toList(),
      'authRequired': authRequired,
      'hint':
          'Streamable HTTP: POST JSON-RPC to /mcp. '
          'Legacy SSE: GET /sse then POST /messages?sessionId=... (responses via SSE).',
    };
  }

  Future<List<String>> _resolveLanIps() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      return interfaces
          .expand((i) => i.addresses)
          .map((a) => a.address)
          .where((a) => !a.startsWith('127.'))
          .toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  /// 心跳周期 20s：低于 vivo 等厂商约 30s 的后台网络代答阈值。
  void _startNetHeartbeat() {
    _netHeartbeatTimer?.cancel();
    _netHeartbeatTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _runNetHeartbeat();
    });
  }

  /// 向网关发起短连接：无论成功/被拒/超时，出站 SYN 已产生，
  /// 足以维持系统侧的网络活跃标记。连通过的网关会被缓存。
  Future<void> _runNetHeartbeat() async {
    if (_lanIps.isEmpty) return;
    final parts = _lanIps.first.split('.');
    if (parts.length != 4) return;
    final gateway =
        _netHeartbeatGateway ?? '${parts[0]}.${parts[1]}.${parts[2]}.1';
    try {
      final socket = await Socket.connect(
        gateway,
        80,
        timeout: const Duration(seconds: 4),
      );
      socket.destroy();
      _netHeartbeatGateway ??= gateway;
    } catch (_) {
      // 出站流量已产生，心跳目的达成
    }
  }

  bool _authorized(HttpRequest req) {
    if (!authRequired) return true;
    final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final bearer = auth.startsWith('Bearer ') ? auth.substring(7).trim() : '';
    final queryToken = req.uri.queryParameters['token'] ?? '';
    return bearer == _token || queryToken == _token;
  }

  Map<String, dynamic> _authError() =>
      _rpcError(null, -32001, 'Unauthorized: missing or invalid token');

  Map<String, dynamic> _rpcError(dynamic id, int code, String message) {
    return <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, dynamic>{'code': code, 'message': message},
    };
  }

  void _addCorsHeaders(HttpRequest req) {
    final headers = req.response.headers;
    headers.set('Access-Control-Allow-Origin', '*');
    headers.set('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
    headers.set(
      'Access-Control-Allow-Headers',
      'Content-Type, Authorization, Mcp-Session-Id, Last-Event-ID',
    );
  }

  void _respondNoContent(HttpRequest req) {
    req.response.statusCode = HttpStatus.noContent;
    req.response.close();
  }

  /// 大 payload（工具结果可达数 MB）的 jsonEncode 移到后台 isolate，
  /// 避免主 isolate 同步编码造成 UI 卡顿；小对象保持同步编码零开销。
  static const int _isolateEncodeThresholdChars = 256 * 1024;

  static int _estimateJsonSize(Object? value, [int depth = 0]) {
    if (value is String) return value.length + 2;
    if (value is num || value is bool) return 8;
    if (value == null) return 4;
    if (depth > 6) return 64;
    if (value is Map) {
      var total = 0;
      value.forEach((k, v) {
        total += k.toString().length + 4 + _estimateJsonSize(v, depth + 1);
      });
      return total;
    }
    if (value is List) {
      var total = 0;
      for (final item in value) {
        total += 2 + _estimateJsonSize(item, depth + 1);
      }
      return total;
    }
    return 32;
  }

  Future<String> _encodeJsonBody(Object? body) async {
    if (_estimateJsonSize(body) <= _isolateEncodeThresholdChars) {
      return jsonEncode(body);
    }
    try {
      return await Isolate.run(() => jsonEncode(body));
    } catch (_) {
      // isolate 编码失败（不可发送对象等）退回同步编码，保证功能不受影响
      return jsonEncode(body);
    }
  }

  Future<void> _respondJson(
    HttpRequest req,
    dynamic body, {
    int status = HttpStatus.ok,
  }) async {
    _respondText(
      req,
      await _encodeJsonBody(body),
      ContentType.json,
      status: status,
    );
  }

  void _respondText(
    HttpRequest req,
    String text,
    ContentType type, {
    int status = HttpStatus.ok,
  }) {
    req.response.statusCode = status;
    req.response.headers.contentType = type;
    req.response.write(text);
    req.response.close();
  }
}

/// 一条旧版 HTTP+SSE 传输的客户端长连接。
class _SseSession {
  _SseSession(this.id, this.response);

  final String id;
  final HttpResponse response;
  Timer? heartbeat;
  bool closed = false;

  Future<void> push(String chunk) async {
    if (closed) return;
    try {
      response.write(chunk);
      await response.flush();
    } catch (_) {
      closed = true;
    }
  }
}

enum _McpTaskStatus { queued, running, completed, failed }

class _McpToolTask {
  _McpToolTask(this.id, this.tool, Map<String, dynamic> arguments)
    : action = arguments['action']?.toString(),
      subAction = arguments['blutterAction']?.toString(),
      createdAt = DateTime.now();

  final String id;
  final String tool;
  final String? action;
  final String? subAction;
  final DateTime createdAt;
  _McpTaskStatus status = _McpTaskStatus.queued;
  DateTime? startedAt;
  DateTime? finishedAt;
  String? result;
  String? error;

  void start() {
    status = _McpTaskStatus.running;
    startedAt = DateTime.now();
  }

  void complete(String value) {
    result = value;
    status = _McpTaskStatus.completed;
    finishedAt = DateTime.now();
  }

  void fail(String value) {
    error = value;
    status = _McpTaskStatus.failed;
    finishedAt = DateTime.now();
  }

  Map<String, dynamic> toJson() {
    final end = finishedAt ?? DateTime.now();
    final phase = switch (status) {
      _McpTaskStatus.queued => 'queued',
      _McpTaskStatus.running => 'executing',
      _McpTaskStatus.completed || _McpTaskStatus.failed => 'finished',
    };
    final progressPercent = switch (status) {
      _McpTaskStatus.queued => 0,
      _McpTaskStatus.running => null,
      _McpTaskStatus.completed || _McpTaskStatus.failed => 100,
    };
    return <String, dynamic>{
      'ok': status != _McpTaskStatus.failed,
      'taskId': id,
      'tool': tool,
      'status': status.name,
      'phase': phase,
      if (progressPercent != null) 'progressPercent': progressPercent,
      if (status == _McpTaskStatus.running) 'progressIndeterminate': true,
      'elapsedMs': end.difference(createdAt).inMilliseconds,
      if (action != null) 'action': action,
      if (subAction != null) 'subAction': subAction,
      'createdAt': createdAt.millisecondsSinceEpoch,
      if (startedAt != null) 'startedAt': startedAt!.millisecondsSinceEpoch,
      if (finishedAt != null) 'finishedAt': finishedAt!.millisecondsSinceEpoch,
      if (result != null) 'result': result,
      if (error != null) 'error': error,
    };
  }
}

class _McpAdaptiveResult {
  const _McpAdaptiveResult({this.output, this.error});

  final String? output;
  final Object? error;
}

void debugPrintSafely(String message) {
  // ignore: avoid_print
  print(message);
}
