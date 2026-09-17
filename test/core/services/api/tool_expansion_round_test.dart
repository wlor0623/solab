import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/providers/settings_provider.dart';
import 'package:solab/core/services/api/chat_api_service.dart';
import 'package:solab/core/services/api/stream/stream_chunk.dart';
import 'package:solab/features/home/services/tool_router.dart';

import '../../../support/collect_generation.dart';

ProviderConfig _openCodeConfig(
  String baseUrl, {
  Map<String, dynamic> modelOverrides = const <String, dynamic>{},
}) {
  return ProviderConfig(
    id: 'ExpandTest',
    enabled: true,
    name: 'ExpandTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.openai,
    useResponseApi: false,
    modelOverrides: modelOverrides,
  );
}

String _sseChunk(Map<String, dynamic> payload) =>
    'data: ${jsonEncode(payload)}\n\n';

List<Map<String, dynamic>> _defsFor(Set<String> names) => [
  for (final name in names)
    <String, dynamic>{
      'type': 'function',
      'function': <String, dynamic>{
        'name': name,
        'description': 'description of $name',
        if (ToolRouter.isSchemaCritical(name))
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{},
          },
      },
    },
];

void main() {
  group('动态工具扩容（流程图① 轮间追加 Tier2）', () {
    test('route_task 返回轨道后，follow-up 请求体带上 Tier2 工具', () async {
      final expansion = ToolExpansion(apkTask: true);
      List<Map<String, dynamic>>? firstTools;
      List<Map<String, dynamic>>? secondTools;

      var round = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        round++;
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        if (round == 1) {
          firstTools = (body['tools'] as List? ?? const [])
              .cast<Map<String, dynamic>>();
          // 第 1 轮：模型调用 route_task（OpenAI 流式格式）。
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            _sseChunk({
              'id': 'g-1',
              'object': 'chat.completion.chunk',
              'choices': [
                {
                  'index': 0,
                  'delta': {
                    'role': 'assistant',
                    'tool_calls': [
                      {
                        'index': 0,
                        'id': 'call_route',
                        'type': 'function',
                        'function': {
                          'name': 'route_task',
                          'arguments': '{"task":"analyze"}',
                        },
                      },
                    ],
                  },
                  'finish_reason': 'tool_calls',
                },
              ],
            }),
          );
          request.response.write('data: [DONE]\n\n');
          await request.response.close();
        } else {
          secondTools = (body['tools'] as List? ?? const [])
              .cast<Map<String, dynamic>>();
          // 关键断言信息：第 2 轮必须带上 Tier2（flutter 轨道）与工具结果。
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          // 回复带 tool role 结果的对话 → 最终文本。
          request.response.write(
            _sseChunk({
              'id': 'g-2',
              'object': 'chat.completion.chunk',
              'choices': [
                {
                  'index': 0,
                  'delta': {'role': 'assistant', 'content': 'done'},
                  'finish_reason': 'stop',
                },
              ],
            }),
          );
          request.response.write('data: [DONE]\n\n');
          await request.response.close();
        }
      });

      // onToolCall：执行 route_task 后按其返回文本更新扩容状态（Tier2）。
      Future<String> onToolCall(
        String name,
        Map<String, dynamic> args, {
        String? toolCallId,
      }) async {
        if (name == 'route_task') {
          expansion.applyTrackText(
            '{"track":"flutter_vip","target":"vip check"}',
          );
          return '{"track":"flutter_vip"}';
        }
        return 'ok';
      }

      final chunks = <StreamChunk>[];
      await for (final chunk in ChatApiService.sendMessageStream(
        config: _openCodeConfig(
          'http://${server.address.address}:${server.port}/v1',
        ),
        modelId: 'muse-spark-1.2',
        messages: const [
          {'role': 'user', 'content': '分析这个 app 的会员'},
        ],
        tools: _defsFor(expansion.names()),
        onToolCall: onToolCall,
        toolsOf: () => _defsFor(expansion.names()),
      )) {
        chunks.add(chunk);
      }

      // 第 1 轮：只有 Tier0+Tier1，不含重型工具。
      final firstNames = {
        for (final t in firstTools!) (t['function'] as Map)['name'] as String,
      };
      expect(firstNames.contains('route_task'), isTrue);
      expect(firstNames.contains('so_analyze'), isFalse);
      expect(firstNames.contains('patch_apk_dex_methods'), isFalse);

      // 第 2 轮：route_task 定轨 flutter_vip 后，toolsOf 重算出 Tier2。
      final secondNames = {
        for (final t in secondTools!) (t['function'] as Map)['name'] as String,
      };
      expect(secondNames.contains('so_analyze'), isTrue);
      expect(secondNames.contains('so_patch_into_apk'), isTrue);

      // 完整对话应最终完成，且含最终文本。
      expect(chunks.isGenerationDone, isTrue);
      expect(chunks.joinedContent, contains('done'));
    });
  });
}
