import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/providers/settings_provider.dart';
import 'package:solab/core/services/api/chat_api_service.dart';
import 'support/collect_generation.dart';

ProviderConfig _openCodeConfig(
  String baseUrl, {
  Map<String, dynamic> modelOverrides = const <String, dynamic>{},
}) {
  return ProviderConfig(
    id: 'OpenCodeTest',
    enabled: true,
    name: 'OpenCodeTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.openai,
    useResponseApi: false,
    modelOverrides: modelOverrides,
  );
}

String _sseChunk(Map<String, dynamic> payload) =>
    'data: ${jsonEncode(payload)}\n\n';

void main() {
  group('OpenCode muse-spark tool loop', () {
    test(
      'tool_calls round 1 (finish_reason=tool_calls) -> auto follow-up -> final text',
      () async {
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
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          if (round == 1) {
            // Round 1: reasoning + tool call, standard OpenAI stream format.
            request.response.write(
              _sseChunk({
                'id': 'gen-1',
                'object': 'chat.completion.chunk',
                'choices': [
                  {
                    'index': 0,
                    'delta': {
                      'role': 'assistant',
                      'reasoning_content': 'I need to search.',
                    },
                    'finish_reason': null,
                  },
                ],
              }),
            );
            request.response.write(
              _sseChunk({
                'id': 'gen-1',
                'object': 'chat.completion.chunk',
                'choices': [
                  {
                    'index': 0,
                    'delta': {
                      'role': 'assistant',
                      'tool_calls': [
                        {
                          'index': 0,
                          'id': 'call_1',
                          'type': 'function',
                          'function': {
                            'name': 'search_web',
                            'arguments': '{"query":"test"}',
                          },
                        },
                      ],
                    },
                    'finish_reason': null,
                  },
                ],
              }),
            );
            request.response.write(
              _sseChunk({
                'id': 'gen-1',
                'object': 'chat.completion.chunk',
                'choices': [
                  {
                    'index': 0,
                    'delta': {'role': 'assistant'},
                    'finish_reason': 'tool_calls',
                  },
                ],
                'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
              }),
            );
            request.response.write('data: [DONE]\n\n');
          } else {
            // Round 2: final text answer.
            expect(
              body['messages'].any(
                (m) =>
                    m is Map &&
                    m['role'] == 'tool' &&
                    (m['tool_call_id']?.toString() ?? '') == 'call_1',
              ),
              isTrue,
              reason: 'follow-up must carry tool result for call_1',
            );
            // rikkahub-aligned: no redundant tool_choice, and the assistant
            // tool-call message carries an empty content string.
            expect(
              body.containsKey('tool_choice'),
              isFalse,
              reason: 'must not send redundant tool_choice',
            );
            final assistantCalls = (body['messages'] as List)
                .whereType<Map<String, dynamic>>()
                .where(
                  (m) =>
                      m['role'] == 'assistant' &&
                      m['tool_calls'] is List &&
                      (m['tool_calls'] as List).isNotEmpty,
                )
                .toList();
            expect(
              assistantCalls,
              hasLength(1),
              reason: 'exactly one assistant tool-call message',
            );
            expect(
              assistantCalls.first['content'],
              '',
              reason: 'assistant tool-call message content must be empty',
            );
            request.response.write(
              _sseChunk({
                'id': 'gen-2',
                'object': 'chat.completion.chunk',
                'choices': [
                  {
                    'index': 0,
                    'delta': {'role': 'assistant', 'content': 'Search done. '},
                    'finish_reason': null,
                  },
                ],
              }),
            );
            request.response.write(
              _sseChunk({
                'id': 'gen-2',
                'object': 'chat.completion.chunk',
                'choices': [
                  {
                    'index': 0,
                    'delta': {'role': 'assistant', 'content': 'Answer here.'},
                    'finish_reason': 'stop',
                  },
                ],
                'usage': {'prompt_tokens': 50, 'completion_tokens': 20},
              }),
            );
            request.response.write('data: [DONE]\n\n');
          }
          await request.response.close();
        });

        final chunks = await ChatApiService.sendMessageStream(
          config: _openCodeConfig(
            'http://${server.address.address}:${server.port}/v1',
          ),
          modelId: 'muse-spark-1.2-contributor',
          messages: const [
            {'role': 'user', 'content': 'search something'},
          ],
          onToolCall: (name, args, {toolCallId}) async {
            expect(name, 'search_web');
            return 'mock search result';
          },
        ).toList();

        expect(round, 2, reason: 'exactly one follow-up round expected');
        expect(
          chunks.isGenerationDone,
          isTrue,
          reason: 'generation must finish',
        );
        final text = chunks.joinedContent;
        expect(text, contains('Answer here'), reason: 'final text must arrive');
      },
    );

    test(
      'message-form tool_calls with finish_reason=stop still continue',
      () async {
        // Some relays (incl. LiteLLM/OpenCode gateways) may emit the full
        // `message.tool_calls` (non-delta) together with finish_reason=stop.
        var round = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close(force: true);
        });

        server.listen((request) async {
          round++;
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          if (round == 1) {
            request.response.write(
              _sseChunk({
                'id': 'gen-1',
                'object': 'chat.completion.chunk',
                'choices': [
                  {
                    'index': 0,
                    'message': {
                      'role': 'assistant',
                      'tool_calls': [
                        {
                          'index': 0,
                          'id': 'call_x',
                          'type': 'function',
                          'function': {
                            'name': 'search_web',
                            'arguments': '{"query":"q"}',
                          },
                        },
                      ],
                    },
                    'finish_reason': 'stop',
                  },
                ],
              }),
            );
            request.response.write('data: [DONE]\n\n');
          } else {
            final body =
                jsonDecode(await utf8.decoder.bind(request).join())
                    as Map<String, dynamic>;
            expect(
              body.containsKey('tool_choice'),
              isFalse,
              reason: 'must not send redundant tool_choice',
            );
            final assistantCalls = (body['messages'] as List)
                .whereType<Map<String, dynamic>>()
                .where(
                  (m) =>
                      m['role'] == 'assistant' &&
                      m['tool_calls'] is List &&
                      (m['tool_calls'] as List).isNotEmpty,
                )
                .toList();
            expect(
              assistantCalls,
              hasLength(1),
              reason: 'exactly one assistant tool-call message',
            );
            expect(
              assistantCalls.first['content'],
              '',
              reason: 'assistant tool-call message content must be empty',
            );
            request.response.write(
              _sseChunk({
                'id': 'gen-2',
                'object': 'chat.completion.chunk',
                'choices': [
                  {
                    'index': 0,
                    'delta': {'role': 'assistant', 'content': 'Final.'},
                    'finish_reason': 'stop',
                  },
                ],
              }),
            );
            request.response.write('data: [DONE]\n\n');
          }
          await request.response.close();
        });

        final chunks = await ChatApiService.sendMessageStream(
          config: _openCodeConfig(
            'http://${server.address.address}:${server.port}/v1',
          ),
          modelId: 'muse-spark-1.2-contributor',
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
          onToolCall: (name, args, {toolCallId}) async => 'mock result',
        ).toList();

        expect(
          round,
          2,
          reason: 'message-form tool_calls must trigger follow-up',
        );
        expect(chunks.isGenerationDone, isTrue);
        expect(chunks.joinedContent, contains('Final.'));
      },
    );
  });
}
