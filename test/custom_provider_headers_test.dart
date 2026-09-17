import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/providers/settings_provider.dart';
import 'package:solab/core/services/api/chat_api_service.dart';

/// 自定义供应商 Headers 端到端：customHeaders 行配置必须真实出现在请求头。
void main() {
  test('custom provider headers are merged into the request', () async {
    final requestBodyCompleter = Completer<Map<String, dynamic>>();
    final headerCompleter = Completer<Map<String, List<String>>>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });

    server.listen((request) async {
      if (!headerCompleter.isCompleted) {
        final collected = <String, List<String>>{};
        request.headers.forEach((name, values) {
          collected[name] = values;
        });
        headerCompleter.complete(collected);
      }
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      if (!requestBodyCompleter.isCompleted) {
        requestBodyCompleter.complete(body);
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      final chunk = jsonEncode({
        'id': 'cmpl-hdr',
        'object': 'chat.completion.chunk',
        'created': 0,
        'model': 'agnes-2.5-flash',
        'choices': [
          {
            'index': 0,
            'delta': {'role': 'assistant', 'content': 'ok'},
            'finish_reason': 'stop',
          },
        ],
      });
      request.response.write('data: $chunk\n\n');
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });

    final baseUrl = 'http://${server.address.address}:${server.port}/v1';
    final config = ProviderConfig(
      id: 'AgnesCustom',
      enabled: true,
      name: 'AgnesCustom',
      apiKey: 'test-key',
      baseUrl: baseUrl,
      providerType: ProviderKind.openai,
      customHeaders: const [
        {'name': 'X-Custom-Trace', 'value': 'so-lab-trace'},
        {'name': 'X-Org-Id', 'value': 'org-42'},
      ],
    );

    await ChatApiService.sendMessageStream(
      config: config,
      modelId: 'agnes-2.5-flash',
      messages: const [
        {'role': 'user', 'content': 'hello'},
      ],
      thinkingBudget: 0,
    ).toList();

    final headers = await headerCompleter.future;
    expect(headers['x-custom-trace']?.first, 'so-lab-trace');
    expect(headers['x-org-id']?.first, 'org-42');
    // Agnes 400 回归锁：每个 function 必须带 parameters（缺字段被严格网关 400）
    final body = await requestBodyCompleter.future;
    final tools = body['tools'] as List? ?? const [];
    for (final tool in tools) {
      final function = tool['function'] as Map?;
      if (function == null) continue;
      expect(
        function['parameters'],
        isA<Map>(),
        reason: 'tools[${function['name']}] 缺 parameters 会被 Agnes 网关 400',
      );
    }
  });
}
