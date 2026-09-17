import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/services/api/providers/openai/chat_completions_api.dart';
import 'package:solab/core/services/api/providers/openai/responses_api.dart';

// agnes 等严格 OpenAI 兼容网关把 tools[i].function.parameters 判为必填，
// 缺字段直接 HTTP 400（missing field `parameters`）。两个转换函数都必须
// 在工具缺 parameters 时补最小合法 JSON Schema。
void main() {
  test('cleanToolsForCompatibility injects minimal parameters when missing',
      () {
    final out = cleanToolsForCompatibility(const [
      {
        'type': 'function',
        'function': {'name': 'no_params_tool', 'description': 'd'},
      },
      {
        'type': 'function',
        'function': {
          'name': 'with_params_tool',
          'parameters': {
            'type': 'object',
            'properties': {
              'a': {'type': 'string'},
            },
          },
        },
      },
    ]);
    expect(out[0]['function']['parameters'], <String, dynamic>{'type': 'object'});
    expect(
      (out[1]['function']['parameters'] as Map)['properties'],
      isNotNull,
    );
  });

  test('toResponsesToolsFormat always emits parameters', () {
    final out = toResponsesToolsFormat(const [
      {
        'type': 'function',
        'function': {'name': 'flat_missing'},
      },
    ]);
    expect(out.single['parameters'], <String, dynamic>{'type': 'object'});
  });
}
