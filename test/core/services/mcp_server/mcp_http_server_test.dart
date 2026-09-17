import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/services/mcp_server/mcp_http_server.dart';
import 'package:solab/features/solab_apk/services/apk_agent_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final server = McpHttpServer.instance;
  late int port;

  setUpAll(() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = probe.port;
    await probe.close();
    server.configure(port: port, token: '');
    expect(await server.start(), isTrue);
  });

  tearDownAll(server.stop);

  test('lists LAN addresses even when access protection is disabled', () {
    final urls = server.lanUrls;

    expect(urls, contains('http://127.0.0.1:$port/mcp'));
    expect(urls.any((url) => !url.contains('127.0.0.1')), isTrue);
  });

  test('initialize 注入共同判断策略和版本', () async {
    final response = await _call(port, 'initialize', <String, dynamic>{
      'protocolVersion': '2025-06-18',
    });
    final result = response['result'] as Map<String, dynamic>;
    final meta = result['_meta'] as Map<String, dynamic>;

    expect(
      result['instructions'],
      contains(ApkAgentPolicy.sharedDecisionPolicy),
    );
    expect(meta['decisionPolicyVersion'], ApkAgentPolicy.version);
  });

  test(
    'queues MCP tool calls and exposes their result through task status',
    () async {
      final queued = await _call(port, 'tools/call', <String, dynamic>{
        'name': 'route_task',
        'arguments': <String, dynamic>{'goal': '分析 APK', 'async': true},
      });
      final queuedText = _toolText(queued);
      final queuedEnvelope = jsonDecode(queuedText) as Map<String, dynamic>;
      final queuedData = queuedEnvelope['data'] as Map<String, dynamic>;
      expect(queuedEnvelope['ok'], isTrue);
      expect(queuedData['status'], anyOf('queued', 'running'));
      expect(queuedData['phase'], anyOf('queued', 'executing'));
      expect(queuedData['progressPercent'], anyOf(0, isNull));
      expect(queuedData['elapsedMs'], isA<int>());

      Map<String, dynamic>? task;
      for (var i = 0; i < 20; i++) {
        final status = await _call(port, 'tools/call', <String, dynamic>{
          'name': 'mcp_task_status',
          'arguments': <String, dynamic>{'taskId': queuedData['taskId']},
        });
        final statusEnvelope =
            jsonDecode(_toolText(status)) as Map<String, dynamic>;
        task = statusEnvelope['data'] as Map<String, dynamic>;
        if (task['status'] == 'completed') break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(task?['status'], 'completed');
      expect(task?['phase'], 'finished');
      expect(task?['progressPercent'], 100);
      expect(task?['elapsedMs'], isA<int>());
      expect(task?['result'], contains('recommendedTools'));
    },
  );

  test(
    'queues workspace analysis without an explicit async argument',
    () async {
      final queued = await _call(port, 'tools/call', <String, dynamic>{
        'name': 'analyze_apk_workspace',
        'arguments': const <String, dynamic>{},
      });
      final envelope = jsonDecode(_toolText(queued)) as Map<String, dynamic>;
      final data = envelope['data'] as Map<String, dynamic>;

      expect(envelope['ok'], isTrue);
      expect(data['tool'], 'analyze_apk_workspace');
      expect(data['status'], anyOf('queued', 'running'));
    },
  );

  test('returns the standard envelope for unavailable tools', () async {
    final response = await _call(port, 'tools/call', <String, dynamic>{
      'name': 'missing_tool',
      'arguments': const <String, dynamic>{},
    });

    final envelope = jsonDecode(_toolText(response)) as Map<String, dynamic>;
    expect(response['result']?['isError'], isTrue);
    expect(envelope['ok'], isFalse);
    expect(envelope['error']?['code'], 'tool_not_found');
    expect(envelope['nextActions'], isEmpty);
  });

  test('advertises the complete 23-tool catalog with valid schemas', () async {
    final response = await _call(port, 'tools/list', const <String, dynamic>{});
    final result = response['result'] as Map<String, dynamic>;
    final tools = result['tools'] as List<dynamic>;
    final names = tools
        .map((tool) => (tool as Map<String, dynamic>)['name'] as String)
        .toSet();

    final expectedCount = McpHttpServer.exposedToolIds.length + 1;
    expect(tools, hasLength(expectedCount));
    expect(names, hasLength(expectedCount));
    expect(
      names,
      containsAll(
        McpHttpServer.exposedToolIds.map(
          (name) => name.replaceFirst('analyzer.', 'analyzer_'),
        ),
      ),
    );
    expect(names, contains(McpHttpServer.taskStatusTool));
    final soPatch = tools.cast<Map<String, dynamic>>().singleWhere(
      (tool) => tool['name'] == 'so_patch_into_apk',
    );
    final soPatchProperties =
        (soPatch['inputSchema'] as Map<String, dynamic>)['properties'] as Map;
    expect(
      soPatchProperties.keys,
      containsAll(<String>[
        'apkPath',
        'soPath',
        'entryName',
        'dryRun',
        'applyAfterPreview',
        'confirm',
        'previewToken',
      ]),
    );
    final soAnalyze = tools.cast<Map<String, dynamic>>().singleWhere(
      (tool) => tool['name'] == 'so_analyze',
    );
    final soAnalyzeProperties =
        (soAnalyze['inputSchema'] as Map<String, dynamic>)['properties'] as Map;
    expect(
      soAnalyzeProperties.keys,
      containsAll(<String>[
        'edits',
        'mode',
        'value',
        'returnType',
        'valueEncoding',
        'writeAsm',
      ]),
    );
    for (final raw in tools) {
      final tool = raw as Map<String, dynamic>;
      expect(
        tool['name'],
        matches(RegExp(r'^[a-zA-Z0-9_-]+$')),
        reason: tool['name'] as String,
      );
      final schema = tool['inputSchema'] as Map<String, dynamic>;
      expect(schema['type'], 'object', reason: tool['name'] as String);
      expect(schema['additionalProperties'], isFalse);
      expect(tool['description'], isNotEmpty);
    }
    final meta = result['_meta'] as Map<String, dynamic>;
    expect(meta['returnedCount'], expectedCount);
    expect(meta['fullToolCount'], expectedCount);
  });

  test(
    'routes published analyzer aliases to the internal analyzer tools',
    () async {
      final response = await _call(port, 'tools/call', <String, dynamic>{
        'name': 'analyzer_open',
        'arguments': const <String, dynamic>{'apkPath': ''},
      });

      expect(_toolText(response), isNot(contains('TOOL_NOT_FOUND')));
    },
  );

  test('tool map accepts and returns published analyzer aliases', () async {
    final response = await _call(port, 'tools/call', <String, dynamic>{
      'name': 'get_solab_tool_map',
      'arguments': const <String, dynamic>{'tool': 'analyzer_open'},
    });
    final envelope = jsonDecode(_toolText(response)) as Map<String, dynamic>;
    final data = envelope['data'] as Map<String, dynamic>;
    final tools = data['tools'] as List<dynamic>;

    expect((tools.single as Map<String, dynamic>)['name'], 'analyzer_open');
    expect(data['callableToolNames'], <String>['analyzer_open']);
  });

  test(
    'preserves so_patch_into_apk arguments at the confirmation gate',
    () async {
      final response = await _call(port, 'tools/call', <String, dynamic>{
        'name': 'so_patch_into_apk',
        'arguments': jsonEncode(<String, Object?>{
          'apkPath': '/storage/emulated/0/Ai/source.apk',
          'soPath': '/storage/emulated/0/Ai/libapp-patched.so',
          'entryName': 'lib/arm64-v8a/libapp.so',
          'dryRun': false,
          'sign': true,
        }),
      });

      final envelope = jsonDecode(_toolText(response)) as Map<String, dynamic>;
      final data = envelope['data'] as Map<String, dynamic>;

      expect(envelope['ok'], isFalse);
      expect(envelope['error']?['code'], 'confirmation_required');
      expect(data['receivedArgumentCount'], 5);
      expect(
        data['receivedArguments'],
        containsPair('entryName', 'lib/arm64-v8a/libapp.so'),
      );
      expect(data['receivedArguments'], containsPair('dryRun', false));
      expect(data['receivedArguments'], containsPair('sign', true));
    },
  );

  test('blocks a repeated MCP call inside an A-B-C-A cycle', () async {
    await _call(port, 'initialize', <String, dynamic>{
      'protocolVersion': '2025-06-18',
    });

    for (final tool in <String>['route_task', 'file', 'so_analyze']) {
      final response = await _call(port, 'tools/call', <String, dynamic>{
        'name': 'get_solab_tool_map',
        'arguments': <String, dynamic>{'tool': tool},
      });
      expect(response['result']?['isError'], isNot(true));
    }

    final repeated = await _call(port, 'tools/call', <String, dynamic>{
      'name': 'get_solab_tool_map',
      'arguments': const <String, dynamic>{'tool': 'route_task'},
    });
    final envelope = jsonDecode(_toolText(repeated)) as Map<String, dynamic>;

    expect(repeated['result']?['isError'], isTrue);
    expect(envelope['error']?['code'], 'loop_detected');
  });
}

Future<Map<String, dynamic>> _call(
  int port,
  String method,
  Map<String, dynamic> params,
) async {
  final body = jsonEncode(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': 1,
    'method': method,
    'params': params,
  });
  final socket = await Socket.connect('127.0.0.1', port);
  try {
    socket.write(
      'POST /mcp HTTP/1.0\r\n'
      'Host: 127.0.0.1:$port\r\n'
      'Content-Type: application/json\r\n'
      'Content-Length: ${utf8.encode(body).length}\r\n'
      '\r\n'
      '$body',
    );
    final raw = await utf8.decoder.bind(socket).join();
    final separator = raw.indexOf('\r\n\r\n');
    return jsonDecode(raw.substring(separator + 4)) as Map<String, dynamic>;
  } finally {
    socket.destroy();
  }
}

String _toolText(Map<String, dynamic> response) {
  final result = response['result'] as Map<String, dynamic>;
  final content = result['content'] as List<dynamic>;
  return (content.single as Map<String, dynamic>)['text'] as String;
}
