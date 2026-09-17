import 'package:flutter_test/flutter_test.dart';
import 'package:solab/core/services/api/providers/openai/openai_vendor_compat.dart';

void main() {
  test('Agnes uses its documented OpenAI thinking switch', () {
    final body = <String, dynamic>{
      'reasoning_effort': 'high',
      'chat_template_kwargs': <String, dynamic>{'custom': true},
    };
    const info = OpenAIProviderInfo(
      host: 'apihub.agnes-ai.com',
      providerId: 'agnes',
      upstreamModelId: 'agnes-2.5-flash',
    );

    applyVendorReasoningKnobs(
      body,
      info: info,
      isReasoning: true,
      thinkingBudget: -1,
    );

    expect(body.containsKey('reasoning_effort'), isFalse);
    expect(body['chat_template_kwargs'], <String, dynamic>{
      'custom': true,
      'enable_thinking': true,
    });
  });

  test('Hy3 preserves reasoning on tool follow-ups', () {
    const info = OpenAIProviderInfo(
      host: 'tokenhub.tencentmaas.com',
      providerId: 'tencent-tokenhub',
      upstreamModelId: 'hy3',
    );

    expect(info.needsReasoningEcho, isTrue);
    expect(
      info.reasoningContentReplayPolicy,
      ReasoningContentReplayPolicy.toolTurns,
    );

    final body = <String, dynamic>{};
    applyVendorReasoningKnobs(
      body,
      info: info,
      isReasoning: true,
      thinkingBudget: -1,
    );
    expect(body['thinking'], <String, dynamic>{'type': 'enabled'});
    expect(body.containsKey('reasoning_effort'), isFalse);
  });
}
