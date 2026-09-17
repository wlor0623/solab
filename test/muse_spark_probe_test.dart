import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/providers/model_provider.dart';

void main() {
  group('muse-spark model capability inference', () {
    for (final modelId in const [
      'muse-spark-1.2',
      'muse-spark-1.2-contributor',
      'meta/muse-spark-1.2',
      'meta/muse-spark-1.2-contributor',
    ]) {
      test('$modelId inferred as reasoning + vision + tool', () {
        final info = ModelRegistry.infer(
          ModelInfo(
            id: modelId,
            displayName: modelId,
            type: ModelType.chat,
            input: const [Modality.text],
            output: const [Modality.text],
            abilities: const [],
          ),
        );
        expect(
          info.abilities.contains(ModelAbility.reasoning),
          isTrue,
          reason: 'model=$modelId abilities=${info.abilities}',
        );
        expect(
          info.abilities.contains(ModelAbility.tool),
          isTrue,
          reason: 'model=$modelId abilities=${info.abilities}',
        );
        expect(
          info.input.contains(Modality.image),
          isTrue,
          reason: 'model=$modelId input=${info.input}',
        );
      });
    }
  });
}
