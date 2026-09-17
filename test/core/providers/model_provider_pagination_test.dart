import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:solab/core/providers/model_provider.dart';
import 'package:solab/core/providers/settings_provider.dart';

void main() {
  test('Claude 模型列表读取全部分页和能力元数据', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      final after = request.uri.queryParameters['after_id'];
      request.response.write(
        jsonEncode(
          after == null
              ? <String, dynamic>{
                  'data': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'id': 'claude-page-1',
                      'display_name': 'Claude Page 1',
                    },
                  ],
                  'has_more': true,
                  'last_id': 'claude-page-1',
                }
              : <String, dynamic>{
                  'data': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'id': 'vendor-future-model',
                      'display_name': 'Vendor Future Model',
                      'capabilities': <String, dynamic>{
                        'tool_use': <String, dynamic>{'supported': true},
                        'adaptive_thinking': <String, dynamic>{
                          'supported': true,
                        },
                        'vision': <String, dynamic>{'supported': true},
                      },
                    },
                  ],
                  'has_more': false,
                },
        ),
      );
      await request.response.close();
    });

    final models = await ClaudeProvider().listModels(
      ProviderConfig(
        id: 'Claude',
        enabled: true,
        name: 'Claude',
        apiKey: 'test',
        baseUrl: 'http://${server.address.address}:${server.port}',
        providerType: ProviderKind.claude,
      ),
    );

    expect(models.map((model) => model.id), <String>[
      'claude-page-1',
      'vendor-future-model',
    ]);
    final future = models.last;
    expect(future.input, contains(Modality.image));
    expect(future.abilities, containsAll(ModelAbility.values));
  });

  test('Gemini 模型列表读取 nextPageToken 全部分页', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      final token = request.uri.queryParameters['pageToken'];
      request.response.write(
        jsonEncode(
          token == null
              ? <String, dynamic>{
                  'models': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'name': 'models/gemini-page-1',
                      'supportedGenerationMethods': <String>['generateContent'],
                    },
                  ],
                  'nextPageToken': 'next',
                }
              : <String, dynamic>{
                  'models': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'name': 'models/gemini-page-2',
                      'supportedGenerationMethods': <String>['generateContent'],
                    },
                  ],
                },
        ),
      );
      await request.response.close();
    });

    final models = await GoogleProvider().listModels(
      ProviderConfig(
        id: 'Google',
        enabled: true,
        name: 'Google',
        apiKey: 'test',
        baseUrl: 'http://${server.address.address}:${server.port}',
        providerType: ProviderKind.google,
      ),
    );

    expect(models.map((model) => model.id), <String>[
      'gemini-page-1',
      'gemini-page-2',
    ]);
  });
}
