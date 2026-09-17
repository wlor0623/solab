import '../../../support/business_test_harness.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:solab/core/models/chat_input_data.dart';
import 'package:solab/core/providers/asr_provider.dart';
import 'package:solab/core/providers/assistant_provider.dart';
import 'package:solab/core/providers/settings_provider.dart';
import 'package:solab/core/services/asr/asr_service_options.dart';
import 'package:solab/core/services/asr/system_asr_service.dart';
import 'package:solab/features/home/widgets/chat_input_bar.dart';
import 'package:solab/l10n/app_localizations.dart';

void main() {
  Widget harness({
    required SettingsProvider settings,
    required AsrProvider asr,
    required TextEditingController controller,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(
          value: AssistantProvider(
            preferences: createBusinessTestPreferences(),
          ),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ChatInputBar(
            controller: controller,
            asrProvider: asr,
            onSend: (_) async => ChatInputSubmissionResult.rejected,
          ),
        ),
      ),
    );
  }

  testWidgets('microphone is hidden until the user adds an ASR service', (
    tester,
  ) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
    final asr = AsrProvider();
    final controller = TextEditingController();
    addTearDown(asr.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      harness(settings: settings, asr: asr, controller: controller),
    );
    await tester.pump();

    expect(find.byTooltip('Voice input'), findsNothing);
  });

  testWidgets('system ASR replaces partials from a stable draft base', (
    tester,
  ) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
    final option = SystemAsrOptions(id: 'system-test');
    await settings.setAsrServices(<AsrServiceOptions>[option]);
    final backend = _FakeSystemBackend();
    final asr = AsrProvider(systemService: SystemAsrService(backend: backend));
    final controller = TextEditingController(text: 'draft');
    addTearDown(asr.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      harness(settings: settings, asr: asr, controller: controller),
    );
    await tester.tap(find.byTooltip('Voice input'));
    await tester.pump();

    backend.emitTranscript('hello', false);
    await tester.pump();
    expect(controller.text, 'draft hello');
    backend.emitTranscript('hello world', false);
    await tester.pump();
    expect(controller.text, 'draft hello world');

    await tester.tap(find.byTooltip('Stop and transcribe to input'));
    await tester.pumpAndSettle();
    expect(controller.text, 'draft hello world');
    expect(find.byTooltip('Voice input'), findsOneWidget);
  });

  testWidgets('cancelling ASR restores the exact original editing value', (
    tester,
  ) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
    final option = SystemAsrOptions(id: 'system-test');
    await settings.setAsrServices(<AsrServiceOptions>[option]);
    final backend = _FakeSystemBackend();
    final asr = AsrProvider(systemService: SystemAsrService(backend: backend));
    final controller = TextEditingController(text: '保留内容')
      ..selection = const TextSelection(baseOffset: 1, extentOffset: 3);
    final original = controller.value;
    addTearDown(asr.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      harness(settings: settings, asr: asr, controller: controller),
    );
    await tester.tap(find.byTooltip('Voice input'));
    await tester.pump();
    backend.emitTranscript('临时识别', false);
    await tester.pump();

    await tester.tap(find.byTooltip('Discard recording'));
    await tester.pumpAndSettle();
    expect(controller.value, original);
  });

  testWidgets('voice waveform advances on a steady 60 ms sampling clock', (
    tester,
  ) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
    final option = SystemAsrOptions(id: 'system-test');
    await settings.setAsrServices(<AsrServiceOptions>[option]);
    final backend = _FakeSystemBackend();
    final asr = AsrProvider(systemService: SystemAsrService(backend: backend));
    final controller = TextEditingController();
    addTearDown(asr.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      harness(settings: settings, asr: asr, controller: controller),
    );
    await tester.tap(find.byTooltip('Voice input'));
    await tester.pump();
    backend.emitSoundLevel(-12);
    await tester.pump();

    dynamic waveform = tester.widget(
      find.byKey(const ValueKey('voice-waveform')),
    );
    expect(waveform.levels, isEmpty);
    await tester.pump(const Duration(milliseconds: 65));
    waveform = tester.widget(find.byKey(const ValueKey('voice-waveform')));
    final firstCount = (waveform.levels as List<double>).length;
    expect(firstCount, greaterThan(0));
    final waveformPaint = find.descendant(
      of: find.byKey(const ValueKey('voice-waveform')),
      matching: find.byType(CustomPaint),
    );
    expect(waveformPaint, findsOneWidget);
    expect(tester.getSize(waveformPaint).width, greaterThan(0));
    expect(tester.getSize(waveformPaint).height, 32);

    await tester.pump(const Duration(milliseconds: 180));
    waveform = tester.widget(find.byKey(const ValueKey('voice-waveform')));
    expect((waveform.levels as List<double>).length, greaterThan(firstCount));

    await tester.tap(find.byTooltip('Discard recording'));
    await tester.pumpAndSettle();
  });
}

final class _FakeSystemBackend implements SystemAsrBackend {
  void Function(String status)? _onStatus;
  SystemAsrTranscriptCallback? _onTranscript;
  SystemAsrSoundLevelCallback? _onSoundLevel;

  void emitTranscript(String text, bool isFinal) {
    _onTranscript?.call(text, isFinal);
  }

  void emitSoundLevel(double level) {
    _onSoundLevel?.call(level);
  }

  @override
  Future<bool> initialize({
    required SystemAsrErrorCallback onError,
    required void Function(String status) onStatus,
  }) async {
    _onStatus = onStatus;
    return true;
  }

  @override
  Future<List<SystemAsrLocale>> locales() async => const <SystemAsrLocale>[];

  @override
  Future<SystemAsrLocale?> systemLocale() async => null;

  @override
  Future<void> listen({
    required String? localeId,
    required Duration listenFor,
    required Duration pauseFor,
    required SystemAsrTranscriptCallback onTranscript,
    required SystemAsrSoundLevelCallback onSoundLevel,
  }) async {
    _onTranscript = onTranscript;
    _onSoundLevel = onSoundLevel;
    _onStatus?.call('listening');
  }

  @override
  Future<void> stop() async {
    _onTranscript?.call('hello world', true);
    _onStatus?.call('done');
  }

  @override
  Future<void> cancel() async {
    _onStatus?.call('done');
  }
}
