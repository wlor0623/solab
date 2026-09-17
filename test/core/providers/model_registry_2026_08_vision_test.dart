import 'package:solab/core/providers/model_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ModelRegistry 2026-08 vision matrix', () {
    test('GLM-5.3-Flash (released 2026-08-26) is multimodal', () {
      for (final id in const [
        'glm-5.3-flash',
        'zhipu/glm-5.3-flash',
        'glm-5.3-flash-260826',
      ]) {
        final model = ModelRegistry.infer(ModelInfo(id: id, displayName: id));
        expect(model.input, contains(Modality.image), reason: id);
        expect(model.abilities, contains(ModelAbility.tool), reason: id);
        expect(model.abilities, contains(ModelAbility.reasoning), reason: id);
      }
    });

    test('GLM-5 text-only flagships stay text-only', () {
      for (final id in const [
        'glm-5',
        'glm-5.2',
        'glm-5.3',
        'glm-5.3-flashx',
      ]) {
        final model = ModelRegistry.infer(ModelInfo(id: id, displayName: id));
        expect(model.input, isNot(contains(Modality.image)), reason: id);
      }
    });

    test('MiniMax M3 point releases keep vision; M2 line stays text-only', () {
      for (final id in const ['minimax-m3.5', 'minimax-m3-pro']) {
        final model = ModelRegistry.infer(ModelInfo(id: id, displayName: id));
        expect(model.input, contains(Modality.image), reason: id);
      }
      final m2 = ModelRegistry.infer(
        ModelInfo(id: 'minimax-m2.5', displayName: 'minimax-m2.5'),
      );
      expect(m2.input, isNot(contains(Modality.image)));
    });

    test('Models shipped Jun-Aug 2026 keep vision inference', () {
      for (final id in const [
        'gpt-5.6-sol',
        'gpt-5.6-terra',
        'gemini-3.6-flash',
        'gemini-3.5-flash',
        'grok-4.6',
        'kimi-k3',
        'kimi-k3-thinking',
        'qwen3.8-flash',
        'qwen3.8-flash-next',
        'qwen3.8-max',
        'deepseek-v4-flash-vision-exp',
        'claude-fable-5',
      ]) {
        final model = ModelRegistry.infer(ModelInfo(id: id, displayName: id));
        expect(model.input, contains(Modality.image), reason: id);
      }
    });
  });
}
