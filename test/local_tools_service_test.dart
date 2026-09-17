import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solab/core/models/assistant.dart';
import 'package:solab/core/services/local_tools/local_tool_names.dart';
import 'package:solab/features/solab_apk/services/apk_workspace_binding_service.dart';
import 'package:solab/features/home/services/local_tools_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Assistant local tools', () {
    const localToolsAssistant = Assistant(
      id: 'a1',
      name: 'Assistant',
      localToolIds: [
        LocalToolNames.timeInfo,
        LocalToolNames.clipboard,
        LocalToolNames.textToSpeech,
        LocalToolNames.askUser,
      ],
    );

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('solab/workspace'),
            null,
          );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
    });

    test('assistant defaults to no local tools', () {
      const assistant = Assistant(id: 'a1', name: 'Assistant');

      expect(assistant.localToolIds, isEmpty);
    });

    test('APK tool map lists only declared callable tool names', () async {
      const assistant = Assistant(
        id: 'apk-map',
        name: 'APK',
        localToolIds: <String>[
          LocalToolNames.apkToolMap,
          LocalToolNames.file,
          LocalToolNames.soAnalyze,
          'analyzer.global_search',
        ],
      );

      final raw = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.apkToolMap,
        const <String, dynamic>{},
        assistant,
      );
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      final names = (decoded['callableToolNames'] as List<dynamic>).toSet();

      expect(names, assistant.localToolIds.toSet());
      final mappedTools = decoded['tools'] as List<dynamic>;
      expect(mappedTools.length, names.length);
      expect(decoded['compact'], isTrue);
      expect(mappedTools.first['parameters'], isNull);
      expect(decoded['contract'], contains('tool=<name>'));
    });

    test('APK tool map catalog stays complete under tiered runtime subset', () async {
      // 缺陷回归：Tier0 轻量路由下本轮只下发编排/记忆类工具，目录此前
      // 跟着缩水成 12 个，Agent 误判「写工具缺失」而中断。目录必须始终
      // 覆盖全部已启用能力，只用 declaredNow 标注本轮声明状态。
      const assistant = Assistant(
        id: 'apk-map-tier',
        name: 'APK',
        localToolIds: <String>[
          LocalToolNames.apkToolMap,
          LocalToolNames.file,
          LocalToolNames.soAnalyze,
          LocalToolNames.apkPatchDex,
        ],
      );

      final raw = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.apkToolMap,
        <String, dynamic>{
          '__runtimeToolNames': <String>[
            LocalToolNames.apkToolMap,
            'get_tool_result',
          ],
        },
        assistant,
      );
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      final names = (decoded['callableToolNames'] as List<dynamic>).toSet();

      expect(names, assistant.localToolIds.toSet());
      expect(
        (decoded['declaredThisTurn'] as List).toSet(),
        <String>{LocalToolNames.apkToolMap},
      );
      final declaredNow = <String>{
        for (final tool in decoded['tools'] as List<dynamic>)
          if ((tool as Map)['declaredNow'] == true) tool['name'].toString(),
      };
      expect(declaredNow, <String>{LocalToolNames.apkToolMap});
      // 未声明工具仍可在目录中查参数（等挂载后调用），不再被拒
      final requested = jsonDecode(
        (await LocalToolsService.tryHandleToolCall(
          LocalToolNames.apkToolMap,
          <String, dynamic>{
            '__runtimeToolNames': <String>[LocalToolNames.apkToolMap],
            'tool': LocalToolNames.apkPatchDex,
          },
          assistant,
        ))!,
      ) as Map<String, dynamic>;
      expect((requested['tools'] as List).single['declaredNow'], isFalse);
      expect(requested['contract'], contains('unknown_function'));
      // 完全未启用的工具仍然拒绝
      final disabled = jsonDecode(
        (await LocalToolsService.tryHandleToolCall(
          LocalToolNames.apkToolMap,
          <String, dynamic>{'tool': LocalToolNames.dexSearch},
          assistant,
        ))!,
      ) as Map<String, dynamic>;
      expect(disabled['error'], 'tool_not_available');
    });

    test('file schema exposes live workspace inventory', () {
      const assistant = Assistant(
        id: 'files',
        name: 'Files',
        localToolIds: [LocalToolNames.file],
      );

      final definition = LocalToolsService.buildToolDefinitions(
        assistant: assistant,
        supportsTools: true,
      ).single;
      final action =
          ((((definition['function'] as Map)['parameters'] as Map)['properties']
                  as Map)['action']
              as Map);

      expect(action['enum'], contains('inventory'));
    });

    test(
      'APK tool map returns the complete SO action catalog on request',
      () async {
        const assistant = Assistant(
          id: 'so-catalog',
          name: 'SO catalog',
          localToolIds: <String>[
            LocalToolNames.apkToolMap,
            LocalToolNames.soAnalyze,
          ],
        );

        final raw = await LocalToolsService.tryHandleToolCall(
          LocalToolNames.apkToolMap,
          const <String, dynamic>{'tool': LocalToolNames.soAnalyze},
          assistant,
        );
        final decoded = jsonDecode(raw!) as Map<String, dynamic>;
        final tools = decoded['tools'] as List<dynamic>;
        final action =
            (((tools.single as Map)['parameters'] as Map)['properties']
                    as Map)['action']
                as Map;
        final compact =
            LocalToolsService.buildToolDefinitions(
              assistant: assistant,
              supportsTools: true,
            ).singleWhere(
              (definition) =>
                  (definition['function'] as Map)['name'] ==
                  LocalToolNames.soAnalyze,
            );
        final compactAction =
            (((compact['function'] as Map)['parameters'] as Map)['properties']
                    as Map)['action']
                as Map;

        expect(tools.single['name'], LocalToolNames.soAnalyze);
        expect(action['description'], kSoAnalyzeActionCatalog.join(' | '));
        expect(compactAction['description'], isNot(contains('rz_crypto')));
        expect((compactAction['description'] as String).length, lessThan(240));
      },
    );

    test('assistant defaults to web search disabled', () {
      const assistant = Assistant(id: 'a1', name: 'Assistant');

      expect(assistant.searchEnabled, isFalse);
    });

    test('assistant json keeps missing local tools disabled', () {
      final assistant = Assistant.fromJson(const {
        'id': 'a1',
        'name': 'Assistant',
      });

      expect(assistant.localToolIds, isEmpty);
    });

    test('assistant json keeps missing web search disabled', () {
      final assistant = Assistant.fromJson(const {
        'id': 'a1',
        'name': 'Assistant',
      });

      expect(assistant.searchEnabled, isFalse);
    });

    test('assistant json round trips enabled web search', () {
      const assistant = Assistant(
        id: 'a1',
        name: 'Assistant',
        searchEnabled: true,
      );

      final decoded = Assistant.fromJson(assistant.toJson());

      expect(decoded.searchEnabled, isTrue);
    });

    test('assistant json round trips enabled local tools', () {
      const assistant = Assistant(
        id: 'a1',
        name: 'Assistant',
        localToolIds: [LocalToolNames.timeInfo, LocalToolNames.clipboard],
      );

      final decoded = Assistant.fromJson(assistant.toJson());

      expect(decoded.localToolIds, const [
        LocalToolNames.timeInfo,
        LocalToolNames.clipboard,
      ]);
    });

    test(
      'builds enabled local tool definitions only when model supports tools',
      () {
        final disabled = LocalToolsService.buildToolDefinitions(
          assistant: const Assistant(id: 'a2', name: 'Assistant'),
          supportsTools: true,
        );
        final unsupported = LocalToolsService.buildToolDefinitions(
          assistant: localToolsAssistant,
          supportsTools: false,
        );
        final enabled = LocalToolsService.buildToolDefinitions(
          assistant: localToolsAssistant,
          supportsTools: true,
        );

        expect(disabled, isEmpty);
        expect(unsupported, isEmpty);
        expect(enabled.map((tool) => tool['function']['name']), const [
          LocalToolNames.timeInfo,
          LocalToolNames.clipboard,
          LocalToolNames.textToSpeech,
          LocalToolNames.askUser,
        ]);
        expect(enabled.first['function']['parameters']['properties'], isEmpty);
        expect(
          enabled[1]['function']['parameters']['properties']['action']['enum'],
          const ['read', 'write'],
        );
        final ttsParameters = enabled[2]['function']['parameters'];
        expect(ttsParameters['required'], const ['text']);
        expect(ttsParameters['properties']['text']['type'], 'string');
        final askUserParameters = enabled[3]['function']['parameters'];
        expect(askUserParameters['required'], const ['questions']);
        final questionSchema =
            askUserParameters['properties']['questions']['items'];
        expect(questionSchema['required'], const ['id', 'question']);
        expect(questionSchema['properties']['type']['enum'], const [
          'single',
          'multi',
        ]);
        expect(
          questionSchema['properties']['options']['items']['type'],
          'string',
        );
      },
    );

    test('APK write tools expose the same optional local APK path', () {
      const assistant = Assistant(
        id: 'apk',
        name: 'APK Mod',
        localToolIds: [
          LocalToolNames.apkPatchDex,
          LocalToolNames.apkPatchManifest,
          LocalToolNames.soPatchIntoApk,
          LocalToolNames.soAnalyze,
        ],
      );
      final tools = LocalToolsService.buildToolDefinitions(
        assistant: assistant,
        supportsTools: true,
      );

      for (final tool in tools) {
        final properties = tool['function']['parameters']['properties'] as Map;
        if (tool['function']['name'] != LocalToolNames.soAnalyze) {
          expect(properties['apkPath']['type'], 'string');
        }
        expect(properties['applyAfterPreview']['type'], 'boolean');
      }
    });

    test('so_analyze documents numeric boolean return values', () {
      const assistant = Assistant(
        id: 'apk',
        name: 'APK Mod',
        localToolIds: [LocalToolNames.soAnalyze],
      );
      final tool = LocalToolsService.buildToolDefinitions(
        assistant: assistant,
        supportsTools: true,
      ).single;
      final properties = tool['function']['parameters']['properties'] as Map;

      expect(
        properties['edits']['description'],
        contains('returnType=bool requires numeric value 0 or 1'),
      );
      expect(properties['mode']['type'], 'string');
      expect(properties['value']['type'], 'integer');
      expect(properties['returnType']['type'], 'string');
      expect(properties['valueEncoding']['enum'], const [
        'auto',
        'native',
        'dart_aot',
      ]);
    });

    test('DEX search exposes combined anti-obfuscation features', () {
      const assistant = Assistant(
        id: 'apk',
        name: 'APK Mod',
        localToolIds: [LocalToolNames.dexSearch],
      );
      final tool = LocalToolsService.buildToolDefinitions(
        assistant: assistant,
        supportsTools: true,
      ).single;
      final properties = tool['function']['parameters']['properties'] as Map;
      expect(properties['action']['enum'], contains('auto'));
      expect(properties['action']['enum'], contains('method_by_strings'));
      expect(properties['action']['enum'], contains('class_by_strings'));
      expect(properties['action']['enum'], contains('method_by_numbers'));
      expect(properties['action']['enum'], contains('method_by_features'));
      expect(properties['numbers']['type'], 'array');
      expect(properties['className']['type'], 'string');
      expect(properties['methodName']['type'], 'string');
      expect(properties['fieldNames']['type'], 'array');
      expect(properties['opNames']['type'], 'array');
      expect(
        (tool['function']['parameters']['required'] as List),
        isNot(contains('keyword')),
      );
    });

    test('DEX auto search forwards every evidence dimension', () async {
      final workspace = await Directory.systemTemp.createTemp(
        'kelivo_dex_auto_',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final apk = File(p.join(workspace.path, 'target.apk'));
      await apk.writeAsBytes([0x50, 0x4b]);
      SharedPreferences.setMockInitialValues({
        ApkWorkspaceBindingService.workDirKey: workspace.path,
      });
      Map<String, dynamic>? calledArgs;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('solab/workspace'), (
            call,
          ) async {
            calledArgs = Map<String, dynamic>.from(
              (call.arguments as Map).cast<String, dynamic>(),
            );
            return <String, dynamic>{'ok': true, 'results': const []};
          });
      const assistant = Assistant(
        id: 'apk-auto',
        name: 'APK Mod',
        localToolIds: [LocalToolNames.dexSearch],
      );

      final result = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.dexSearch,
        const {
          'path': 'target.apk',
          'className': 'VipState',
          'methodName': 'level',
          'fieldNames': ['memberLevel'],
          'keyword': '至尊',
          'numbers': [5],
          'opNames': ['if-ne'],
          'invokedMethodNames': ['refresh'],
        },
        assistant,
      );

      expect(result, isNotNull);
      expect(calledArgs!['action'], 'auto');
      expect(calledArgs!['className'], 'VipState');
      expect(calledArgs!['methodName'], 'level');
      expect(calledArgs!['fieldNames'], const ['memberLevel']);
      expect(calledArgs!['keyword'], '至尊');
      expect(calledArgs!['numbers'], const [5]);
      expect(calledArgs!['opNames'], const ['if-ne']);
      expect(calledArgs!['invokedMethodNames'], const ['refresh']);
    });

    test('DEX xref exposes call sites graphs and overrides', () {
      const assistant = Assistant(
        id: 'apk',
        name: 'APK Mod',
        localToolIds: [LocalToolNames.dexXref],
      );
      final tool = LocalToolsService.buildToolDefinitions(
        assistant: assistant,
        supportsTools: true,
      ).single;
      final properties = tool['function']['parameters']['properties'] as Map;
      expect(properties['direction']['enum'], contains('overrides'));
      expect(properties['includeGraph']['type'], 'boolean');
    });

    test('text to speech call starts playback and returns success', () async {
      final spokenTexts = <String>[];

      final result = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.textToSpeech,
        const {'text': 'Read this aloud.'},
        localToolsAssistant,
        onSpeakText: (text) async {
          spokenTexts.add(text);
        },
      );

      expect(spokenTexts, const ['Read this aloud.']);
      expect(result, isNotNull);
      expect(jsonDecode(result!) as Map<String, dynamic>, {'success': true});
    });

    test('text to speech requires non-empty text', () async {
      expect(
        () => LocalToolsService.tryHandleToolCall(
          LocalToolNames.textToSpeech,
          const {},
          localToolsAssistant,
          onSpeakText: (_) async {},
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => LocalToolsService.tryHandleToolCall(
          LocalToolNames.textToSpeech,
          const {'text': '   '},
          localToolsAssistant,
          onSpeakText: (_) async {},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'time info call returns local date, weekday, time, timezone fields',
      () async {
        final result = await LocalToolsService.tryHandleToolCall(
          LocalToolNames.timeInfo,
          const {},
          localToolsAssistant,
        );

        expect(result, isNotNull);
        final payload = jsonDecode(result!) as Map<String, dynamic>;
        expect(payload['year'], isA<int>());
        expect(payload['month'], isA<int>());
        expect(payload['day'], isA<int>());
        expect(payload['weekday'], isA<String>());
        expect(payload['weekday_en'], isA<String>());
        expect(payload['weekday_index'], inInclusiveRange(1, 7));
        expect(payload['date'], isA<String>());
        expect(payload['time'], isA<String>());
        expect(payload['datetime'], isA<String>());
        expect(payload['timezone'], isA<String>());
        expect(payload['utc_offset'], isA<String>());
        expect(payload['timestamp_ms'], isA<int>());
      },
    );

    test(
      'so_analyze exposes stable rollback and cross-workspace diff inputs',
      () {
        const assistant = Assistant(
          id: 'apk',
          name: 'APK Mod',
          localToolIds: [LocalToolNames.soAnalyze],
        );
        final tool =
            LocalToolsService.buildToolDefinitions(
                  assistant: assistant,
                  supportsTools: true,
                ).firstWhere(
                  (item) =>
                      item['function']['name'] == LocalToolNames.soAnalyze,
                )['function']
                as Map;
        final properties = tool['parameters']['properties'] as Map;
        expect(properties.containsKey('snapshotId'), isTrue);
        expect(properties.containsKey('compareWorkspaceId'), isTrue);
        expect(properties.containsKey('compareSessionId'), isTrue);
        expect(properties.containsKey('fullInventory'), isTrue);
        expect(properties['blutterAction']['enum'], contains('raw_strings'));
        expect(properties['blutterAction']['enum'], contains('report'));
        expect(properties['blutterAction']['enum'], contains('trace'));
        expect(properties.containsKey('report'), isTrue);
        expect(properties.containsKey('includeEvidence'), isTrue);
        final blutterDescription =
            properties['blutterAction']['description'] as String;
        expect(blutterDescription, contains('result.json'));
        expect(blutterDescription, contains('REPORT_NOT_READY'));
        expect(blutterDescription, contains('disasm、callers'));
      },
    );

    test(
      'SO edit applyAfterPreview reuses targetVersion and applies once',
      () async {
        final workspace = await Directory.systemTemp.createTemp(
          'kelivo_so_preview_',
        );
        addTearDown(() => workspace.delete(recursive: true));
        SharedPreferences.setMockInitialValues({
          ApkWorkspaceBindingService.workDirKey: workspace.path,
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async => workspace.path,
            );
        final editCalls = <Map<String, dynamic>>[];
        const channel = MethodChannel('solab/workspace');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              expect(call.method, 'soAnalyze');
              final callArgs = Map<String, dynamic>.from(call.arguments as Map);
              if (callArgs['action'] == 'set_work_dir') {
                return <String, dynamic>{'ok': true};
              }
              editCalls.add(callArgs);
              if (callArgs['dryRun'] == true) {
                return <String, dynamic>{
                  'ok': true,
                  'dryRun': true,
                  'previewCount': 1,
                  'targetVersion': 'sha-before',
                  'preview': [
                    {'virtualAddress': '0x1234', 'newHex': '20 00 80 52'},
                  ],
                };
              }
              expect(callArgs['targetVersion'], 'sha-before');
              return <String, dynamic>{
                'ok': true,
                'applied': 1,
                'newTargetVersion': 'sha-after',
              };
            });
        const assistant = Assistant(
          id: 'apk',
          name: 'APK Mod',
          localToolIds: [LocalToolNames.soAnalyze],
        );

        final result = await LocalToolsService.tryHandleToolCall(
          LocalToolNames.soAnalyze,
          const {
            'action': 'edit_asm',
            'workspaceId': 'ws-1',
            'editSessionId': 'edit-1',
            'locator': '0x1234',
            'edits': [
              {
                'mode': 'force_return_constant',
                'returnType': 'int',
                'value': 5,
              },
            ],
            'dryRun': true,
            'applyAfterPreview': true,
          },
          assistant,
        );

        final payload = jsonDecode(result!) as Map<String, dynamic>;
        expect(editCalls, hasLength(2));
        expect(editCalls.first['dryRun'], isTrue);
        expect(editCalls.last['dryRun'], isFalse);
        expect(payload['ok'], isTrue);
        expect(payload['appliedAfterPreview'], isTrue);
        expect(payload['newTargetVersion'], 'sha-after');
        expect(payload.containsKey('applyArguments'), isFalse);
      },
    );

    test('Blutter analyze returns its background job immediately', () async {
      final workspace = await Directory.systemTemp.createTemp(
        'kelivo_blutter_progress_',
      );
      addTearDown(() => workspace.delete(recursive: true));
      SharedPreferences.setMockInitialValues({
        ApkWorkspaceBindingService.workDirKey: workspace.path,
      });
      var statusCalls = 0;
      bool? analyzeWait;
      const channel = MethodChannel('solab/workspace');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final callArgs = Map<String, dynamic>.from(call.arguments as Map);
            if (callArgs['action'] == 'set_work_dir') {
              return <String, dynamic>{'ok': true};
            }
            if (callArgs['blutterAction'] == 'status') {
              statusCalls++;
              return <String, dynamic>{
                'ok': true,
                'jobId': 'blutter-progress-test',
                'status': 'running',
                'stage': 'runner_execution',
                'stageLabel': '解析 Dart AOT',
                'progressMessage': 'runner 仍在运行',
                'updatedAt': 2,
                'elapsedMillis': 2100,
                'outputBytes': 0,
                'outputFiles': 0,
              };
            }
            if (callArgs['blutterAction'] == 'analyze') {
              analyzeWait = callArgs['wait'] as bool?;
            }
            return <String, dynamic>{
              'ok': true,
              'jobId': 'blutter-progress-test',
              'status': 'running',
              'stage': 'runner_launch',
            };
          });
      const assistant = Assistant(
        id: 'apk',
        name: 'APK Mod',
        localToolIds: [LocalToolNames.soAnalyze],
      );

      final result =
          await LocalToolsService.tryHandleToolCall(LocalToolNames.soAnalyze, {
            'action': 'blutter',
            'blutterAction': 'analyze',
            'path': p.join(workspace.path, 'fixture.apk'),
            'wait': true,
            'timeoutMs': 5000,
          }, assistant);
      final payload = jsonDecode(result!) as Map<String, dynamic>;

      expect(statusCalls, 0);
      expect(analyzeWait, isFalse);
      expect(payload['status'], 'running');
      expect(payload['waitDetached'], isTrue);
      expect(payload['hint'], contains('同一 jobId'));
    });

    test(
      'file blocks sequential paging of Blutter reference artifacts',
      () async {
        final workspace = await Directory.systemTemp.createTemp(
          'kelivo_blutter_reference_',
        );
        addTearDown(() => workspace.delete(recursive: true));
        SharedPreferences.setMockInitialValues({
          ApkWorkspaceBindingService.workDirKey: workspace.path,
        });
        const assistant = Assistant(
          id: 'apk',
          name: 'APK Mod',
          localToolIds: [LocalToolNames.file],
        );

        final result = await LocalToolsService.tryHandleToolCall(
          LocalToolNames.file,
          const {
            'action': 'read',
            'path': 'SoLab/blutter/v1/results/sample/pp.txt',
            'offset': 80,
            'limit': 500,
          },
          assistant,
        );

        final payload = jsonDecode(result!) as Map<String, dynamic>;
        expect(payload['error'], 'reference_paging_blocked');
        expect(payload['referenceOnly'], isTrue);
      },
    );

    test(
      'clipboard read returns plain text from the device clipboard',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.getData') {
                return const <String, dynamic>{'text': 'clipboard text'};
              }
              fail('Unexpected platform call: ${call.method}');
            });

        final result = await LocalToolsService.tryHandleToolCall(
          LocalToolNames.clipboard,
          const {'action': 'read'},
          localToolsAssistant,
        );

        expect(result, isNotNull);
        expect(jsonDecode(result!) as Map<String, dynamic>, {
          'text': 'clipboard text',
        });
      },
    );

    test('clipboard write updates the device clipboard', () async {
      String? writtenText;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              writtenText =
                  (call.arguments as Map<Object?, Object?>)['text'] as String?;
              return null;
            }
            fail('Unexpected platform call: ${call.method}');
          });

      final result = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.clipboard,
        const {'action': 'write', 'text': 'next clipboard'},
        localToolsAssistant,
      );

      expect(writtenText, 'next clipboard');
      expect(result, isNotNull);
      expect(jsonDecode(result!) as Map<String, dynamic>, {
        'success': true,
        'text': 'next clipboard',
      });
    });

    test('clipboard write requires text', () async {
      expect(
        () => LocalToolsService.tryHandleToolCall(
          LocalToolNames.clipboard,
          const {'action': 'write'},
          localToolsAssistant,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('disabled or unknown local tool calls are not handled', () async {
      expect(
        await LocalToolsService.tryHandleToolCall(
          LocalToolNames.timeInfo,
          const {},
          const Assistant(id: 'a1', name: 'Assistant'),
        ),
        isNull,
      );
      expect(
        await LocalToolsService.tryHandleToolCall(
          'unknown_local_tool',
          const {},
          localToolsAssistant,
        ),
        isNull,
      );
    });

    test(
      'smali_read definition is registered (R4: methods qualifiedId readable as-is)',
      () {
        const assistant = Assistant(
          id: 'apk',
          name: 'APK Mod',
          localToolIds: [
            LocalToolNames.smaliRead,
            LocalToolNames.dexXref,
            LocalToolNames.file,
          ],
        );
        final tools = LocalToolsService.buildToolDefinitions(
          assistant: assistant,
          supportsTools: true,
        );
        final names = tools.map((t) => t['function']['name']).toList();
        expect(names, contains(LocalToolNames.smaliRead));
        final smaliRead =
            tools.firstWhere(
                  (t) => t['function']['name'] == LocalToolNames.smaliRead,
                )['function']
                as Map;
        expect(smaliRead['parameters']['required'], const ['qualifiedId']);

        // dex_xref：path 可选（自动解析当前目标），callerPrefix 为 classPrefix 别名
        final xref =
            tools.firstWhere(
                  (t) => t['function']['name'] == LocalToolNames.dexXref,
                )['function']
                as Map;
        final xrefProps = xref['parameters']['properties'] as Map;
        expect(xref['parameters']['required'], const ['target']);
        expect(xrefProps.containsKey('callerPrefix'), isTrue);
        expect(xrefProps.containsKey('offset'), isTrue);

        final file =
            tools.firstWhere(
                  (t) => t['function']['name'] == LocalToolNames.file,
                )['function']
                as Map;
        final fileActions =
            file['parameters']['properties']['action']['enum'] as List;
        expect(fileActions, containsAll(const ['read', 'delete', 'grep']));
      },
    );

    test(
      'dex_xref strips dex_method prefix, resolves work-dir path and calls the engine',
      () async {
        final appDataDir = await Directory.systemTemp.createTemp(
          'kelivo_xref_',
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async => appDataDir.path,
            );
        final apk = File(p.join(appDataDir.path, 'app.apk'));
        await apk.writeAsBytes([0x50, 0x4b]);
        SharedPreferences.setMockInitialValues({
          'apk_mod_output_dir': appDataDir.path,
        });
        const channel = MethodChannel('solab/workspace');
        String? calledMethod;
        Map<String, dynamic>? calledArgs;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calledMethod = call.method;
              calledArgs = Map<String, dynamic>.from(
                (call.arguments as Map).cast<String, dynamic>(),
              );
              return <String, dynamic>{
                'ok': true,
                'tool': 'dex_xref',
                'target': 'Lcom/x/Y;->m()V',
                'directCallers': [
                  {'qualifiedId': 'Lcom/x/Z;->n()V', 'callSiteCount': 2},
                ],
                'dispatchCandidates': <Map<String, dynamic>>[],
                'callees': <Map<String, dynamic>>[],
              };
            });

        const assistant = Assistant(
          id: 'apk',
          name: 'APK Mod',
          localToolIds: [LocalToolNames.dexXref],
        );
        final result = await LocalToolsService.tryHandleToolCall(
          LocalToolNames.dexXref,
          const {
            'target': 'dex_method:Lcom/x/Y;->m()V',
            'callerPrefix': 'Lcom/x',
            'path': 'app.apk',
          },
          assistant,
        );

        expect(result, isNotNull);
        expect(calledMethod, 'dexXref');
        expect(calledArgs!['target'], 'Lcom/x/Y;->m()V');
        expect(calledArgs!['classPrefix'], 'Lcom/x');
        expect(calledArgs!['path'], apk.path);
        final payload = jsonDecode(result!) as Map<String, dynamic>;
        expect(payload['ok'], isTrue);
        expect(payload['sourceApk'], isNotNull);
        expect(payload['note'], contains('smali_read'));
      },
    );

    test(
      'dex_xref returns structured error when no APK is resolvable',
      () async {
        final appDataDir = await Directory.systemTemp.createTemp(
          'kelivo_xref_',
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async => appDataDir.path,
            );
        SharedPreferences.setMockInitialValues({});
        const assistant = Assistant(
          id: 'apk',
          name: 'APK Mod',
          localToolIds: [LocalToolNames.dexXref],
        );
        final result = await LocalToolsService.tryHandleToolCall(
          LocalToolNames.dexXref,
          const {'target': 'Lcom/x/Y;->m()V'},
          assistant,
        );
        final payload = jsonDecode(result!) as Map<String, dynamic>;
        expect(payload['ok'], isFalse);
        expect(payload['error'], 'invalid_args');
      },
    );

    test(
      'dex_xref resolves an unambiguous workspace APK by file stem',
      () async {
        final appDataDir = await Directory.systemTemp.createTemp(
          'kelivo_xref_',
        );
        final workspace = await Directory.systemTemp.createTemp(
          'kelivo_xref_ws_',
        );
        addTearDown(() async {
          await appDataDir.delete(recursive: true);
          await workspace.delete(recursive: true);
        });
        final apk = File(p.join(workspace.path, 'current_release.apk'));
        await apk.writeAsBytes([0x50, 0x4b]);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async => appDataDir.path,
            );
        SharedPreferences.setMockInitialValues({
          ApkWorkspaceBindingService.workDirKey: workspace.path,
        });
        const channel = MethodChannel('solab/workspace');
        Map<String, dynamic>? calledArgs;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calledArgs = Map<String, dynamic>.from(
                (call.arguments as Map).cast<String, dynamic>(),
              );
              return <String, dynamic>{
                'ok': true,
                'directCallers': <Map<String, dynamic>>[],
                'dispatchCandidates': <Map<String, dynamic>>[],
                'callees': <Map<String, dynamic>>[],
              };
            });
        const assistant = Assistant(
          id: 'apk',
          name: 'APK Mod',
          localToolIds: [LocalToolNames.dexXref],
        );

        final result = await LocalToolsService.tryHandleToolCall(
          LocalToolNames.dexXref,
          const {'target': 'Lcom/x/Y;->m()V', 'path': 'current_release'},
          assistant,
        );

        expect(result, isNotNull);
        expect(calledArgs!['path'], apk.path);
        expect(await ApkWorkspaceBindingService.activeApkPath(), apk.path);
      },
    );

    test(
      'missing signature base is regenerated without rerunning analysis',
      () async {
        final workspace = await Directory.systemTemp.createTemp(
          'kelivo_missing_target_',
        );
        final appData = await Directory.systemTemp.createTemp(
          'kelivo_missing_target_data_',
        );
        addTearDown(() async {
          await workspace.delete(recursive: true);
          await appData.delete(recursive: true);
        });
        final source = File(p.join(workspace.path, 'source.apk'));
        final missing = p.join(workspace.path, 'source_dexpatch.apk');
        await source.writeAsBytes([0x50, 0x4b]);
        SharedPreferences.setMockInitialValues({
          ApkWorkspaceBindingService.workDirKey: workspace.path,
          'apk_mod_active_apk_v1': missing,
          'apk_mod_build_index_v1': jsonEncode([
            {
              'output': missing,
              'source': source.path,
              'operation': 'signature_compatibility_normal',
              'signatureCompatibility': 'normal',
              'modificationInputReady': true,
            },
          ]),
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async => appData.path,
            );
        final calls = <String>[];
        const channel = MethodChannel('solab/workspace');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call.method);
              if (call.method == 'patchDexMethods') {
                final args = Map<String, dynamic>.from(call.arguments as Map);
                expect(args['path'], source.path);
                expect(args['signatureBypassMode'], 'normal');
                await File(missing).writeAsBytes([0x50, 0x4b, 1]);
                return <String, dynamic>{'ok': true, 'outputPath': missing};
              }
              expect(call.method, 'dexXref');
              expect((call.arguments as Map)['path'], missing);
              return <String, dynamic>{
                'ok': true,
                'directCallers': <Object?>[],
              };
            });
        const assistant = Assistant(
          id: 'apk',
          name: 'APK Mod',
          localToolIds: [LocalToolNames.dexXref],
        );

        final result = await LocalToolsService.tryHandleToolCall(
          LocalToolNames.dexXref,
          const {'target': 'Lcom/demo/User;->isVip()Z'},
          assistant,
        );
        final payload = jsonDecode(result!) as Map<String, dynamic>;

        expect(payload['sourceApk'], missing);
        expect(await File(missing).exists(), isTrue);
        expect(calls, ['patchDexMethods', 'dexXref']);
      },
    );

    test(
      'signature bypass keeps normal, original and Dpatch as separate outputs',
      () async {
        final workspace = await Directory.systemTemp.createTemp(
          'kelivo_signature_modes_',
        );
        addTearDown(() => workspace.delete(recursive: true));
        final source = File(p.join(workspace.path, 'source.apk'));
        await source.writeAsBytes([0x50, 0x4b]);
        SharedPreferences.setMockInitialValues({
          ApkWorkspaceBindingService.workDirKey: workspace.path,
        });
        final patchArguments = <Map<String, dynamic>>[];
        const channel = MethodChannel('solab/workspace');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'scanSignatureCheck') {
                expect((call.arguments as Map)['path'], source.path);
                return <String, dynamic>{
                  'ok': true,
                  'hits': ['check'],
                };
              }
              expect(call.method, 'patchDexMethods');
              final args = Map<String, dynamic>.from(call.arguments as Map);
              patchArguments.add(args);
              final mode = args['signatureBypassMode'].toString();
              return <String, dynamic>{
                'ok': true,
                'outputPath': p.join(workspace.path, 'source_$mode.apk'),
                'signatureBypass': {'mode': mode},
                'signatureBypassVerification': {'verified': true},
              };
            });
        const assistant = Assistant(
          id: 'apk',
          name: 'APK Mod',
          localToolIds: [LocalToolNames.apkSignatureBypass],
        );

        for (final mode in ['normal', 'original_apk', 'dpatch']) {
          final raw = await LocalToolsService.tryHandleToolCall(
            LocalToolNames.apkSignatureBypass,
            {'apkPath': source.path, 'mode': mode},
            assistant,
          );
          final result = jsonDecode(raw!) as Map<String, dynamic>;
          expect(result['ok'], isTrue);
          expect(result['mode'], mode);
          expect(result['outputPath'], isNot(source.path));
        }

        await ApkWorkspaceBindingService.setSignatureBypassDefaultMode(
          'dpatch',
        );
        final defaultRaw = await LocalToolsService.tryHandleToolCall(
          LocalToolNames.apkSignatureBypass,
          {'apkPath': source.path},
          assistant,
        );
        final defaultResult = jsonDecode(defaultRaw!) as Map<String, dynamic>;
        expect(defaultResult['mode'], 'dpatch');

        final explicitRaw = await LocalToolsService.tryHandleToolCall(
          LocalToolNames.apkSignatureBypass,
          {'apkPath': source.path, 'mode': 'normal'},
          assistant,
        );
        final explicitResult =
            jsonDecode(explicitRaw!) as Map<String, dynamic>;
        expect(explicitResult['mode'], 'normal');

        await ApkWorkspaceBindingService.setSignatureBypassDefaultMode('off');
        final disabledRaw = await LocalToolsService.tryHandleToolCall(
          LocalToolNames.apkSignatureBypass,
          {'apkPath': source.path},
          assistant,
        );
        final disabledResult =
            jsonDecode(disabledRaw!) as Map<String, dynamic>;
        expect(disabledResult['error'], 'signature_bypass_disabled');

        expect(patchArguments, hasLength(5));
        expect(patchArguments[0]['originalApkPath'], isNull);
        expect(patchArguments[1]['originalApkPath'], source.path);
        expect(patchArguments[2]['originalApkPath'], source.path);
        expect(patchArguments[3]['originalApkPath'], source.path);
        expect(patchArguments[4]['originalApkPath'], isNull);
        expect(
          patchArguments.every((args) => args['signatureBypass'] == true),
          isTrue,
        );
      },
    );

    test(
      'signature bypass refuses an output that overwrites the original',
      () async {
        final workspace = await Directory.systemTemp.createTemp(
          'kelivo_signature_same_output_',
        );
        addTearDown(() => workspace.delete(recursive: true));
        final source = File(p.join(workspace.path, 'source.apk'));
        await source.writeAsBytes([0x50, 0x4b]);
        SharedPreferences.setMockInitialValues({
          ApkWorkspaceBindingService.workDirKey: workspace.path,
        });
        const channel = MethodChannel('solab/workspace');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              expect(call.method, 'patchDexMethods');
              return <String, dynamic>{'ok': true, 'outputPath': source.path};
            });
        const assistant = Assistant(
          id: 'apk',
          name: 'APK Mod',
          localToolIds: [LocalToolNames.apkSignatureBypass],
        );

        final raw = await LocalToolsService.tryHandleToolCall(
          LocalToolNames.apkSignatureBypass,
          {'apkPath': source.path, 'mode': 'dpatch'},
          assistant,
        );
        final result = jsonDecode(raw!) as Map<String, dynamic>;

        expect(result['error'], 'signature_bypass_output_missing');
      },
    );

    test('DEX applyAfterPreview previews and applies in one call', () async {
      final workspace = await Directory.systemTemp.createTemp(
        'kelivo_preview_apply_',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final source = File(p.join(workspace.path, 'app.apk'));
      final output = File(p.join(workspace.path, 'app_dexpatch.apk'));
      await source.writeAsBytes([0x50, 0x4b]);
      SharedPreferences.setMockInitialValues({
        ApkWorkspaceBindingService.workDirKey: workspace.path,
      });
      final dryRuns = <bool>[];
      const channel = MethodChannel('solab/workspace');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'patchDexMethods');
            final callArgs = Map<String, dynamic>.from(call.arguments as Map);
            final dryRun = callArgs['dryRun'] == true;
            dryRuns.add(dryRun);
            if (dryRun) {
              return <String, dynamic>{
                'ok': true,
                'dryRun': true,
                'changed': true,
                'matchedMethods': ['Lcom/demo/User;->isVip()Z'],
              };
            }
            await output.writeAsBytes([0x50, 0x4b, 1]);
            return <String, dynamic>{
              'ok': true,
              'dryRun': false,
              'changed': true,
              'outputPath': output.path,
            };
          });
      const assistant = Assistant(
        id: 'apk',
        name: 'APK Mod',
        localToolIds: [LocalToolNames.apkPatchDex],
      );

      final result = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.apkPatchDex,
        {
          'apkPath': source.path,
          'dryRun': true,
          'applyAfterPreview': true,
          'trueMethods': ['Lcom/demo/User;->isVip()Z'],
        },
        assistant,
      );

      final payload = jsonDecode(result!) as Map<String, dynamic>;
      expect(dryRuns, [true, false]);
      expect(payload['ok'], isTrue);
      expect(payload['dryRun'], isFalse);
      expect(payload['appliedAfterPreview'], isTrue);
      expect(payload['nextInputPath'], output.path);
      expect(payload.containsKey('previewToken'), isFalse);
      expect(payload.containsKey('applyArguments'), isFalse);
    });

    test('failed DEX write keeps preview token reusable', () async {
      final workspace = await Directory.systemTemp.createTemp(
        'kelivo_preview_retry_',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final source = File(p.join(workspace.path, 'app.apk'));
      final output = File(p.join(workspace.path, 'app_dexpatch.apk'));
      await source.writeAsBytes([0x50, 0x4b]);
      SharedPreferences.setMockInitialValues({
        ApkWorkspaceBindingService.workDirKey: workspace.path,
      });
      var writeAttempts = 0;
      final dryRuns = <bool>[];
      const channel = MethodChannel('solab/workspace');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final callArgs = Map<String, dynamic>.from(call.arguments as Map);
            final dryRun = callArgs['dryRun'] == true;
            dryRuns.add(dryRun);
            if (dryRun) {
              return <String, dynamic>{
                'ok': true,
                'changed': true,
                'matchedMethods': ['Lcom/demo/User;->isVip()Z'],
              };
            }
            writeAttempts++;
            if (writeAttempts == 1) {
              return <String, dynamic>{
                'ok': false,
                'error': 'temporary_write_failure',
                'message': 'temporary failure',
              };
            }
            await output.writeAsBytes([0x50, 0x4b, 1]);
            return <String, dynamic>{
              'ok': true,
              'changed': true,
              'outputPath': output.path,
            };
          });
      const assistant = Assistant(
        id: 'apk',
        name: 'APK Mod',
        localToolIds: [LocalToolNames.apkPatchDex],
      );

      final failedRaw = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.apkPatchDex,
        {
          'apkPath': source.path,
          'dryRun': true,
          'applyAfterPreview': true,
          'trueMethods': ['Lcom/demo/User;->isVip()Z'],
        },
        assistant,
      );
      final failed = jsonDecode(failedRaw!) as Map<String, dynamic>;
      expect(failed['ok'], isFalse);
      expect(failed['previewTokenReusable'], isTrue);
      expect(failed['applyArguments'], isA<Map>());

      final retriedRaw = await LocalToolsService.tryHandleToolCall(
        LocalToolNames.apkPatchDex,
        Map<String, dynamic>.from(failed['applyArguments'] as Map),
        assistant,
      );
      final retried = jsonDecode(retriedRaw!) as Map<String, dynamic>;
      expect(dryRuns, [true, false, false]);
      expect(retried['ok'], isTrue);
      expect(retried['nextInputPath'], output.path);
    });

    test(
      'apk_sign keeps intermediates and stages verification before cleanup',
      () async {
        final appDataDir = await Directory.systemTemp.createTemp(
          'kelivo_sign_',
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async => appDataDir.path,
            );
        final now = DateTime.now().millisecondsSinceEpoch;
        final intermediate = '/ws/app_patched.apk';
        SharedPreferences.setMockInitialValues({
          'apk_mod_output_dir': '/ws',
          'apk_mod_build_index_v1': jsonEncode([
            {
              'output': intermediate,
              'kind': 'patch',
              'rootSource': '/ws/app.apk',
              'signed': false,
              'timestamp': now - 1000,
            },
          ]),
        });
        final intermediateFile = File(intermediate);
        await intermediateFile.parent.create(recursive: true);
        await intermediateFile.writeAsBytes([1, 2, 3]);

        const channel = MethodChannel('solab/workspace');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              expect(call.method, 'apkSign');
              return <String, dynamic>{
                'ok': true,
                'tool': 'apk_sign',
                'success': true,
                'outputApk': '/ws/app-signed.apk',
              };
            });

        const assistant = Assistant(
          id: 'apk',
          name: 'APK Mod',
          localToolIds: [LocalToolNames.apkSign],
        );
        final result = await LocalToolsService.tryHandleToolCall(
          LocalToolNames.apkSign,
          const {'path': '/ws/app_patched.apk'},
          assistant,
        );

        final payload = jsonDecode(result!) as Map<String, dynamic>;
        expect(payload['outputApk'], '/ws/app-signed.apk');
        expect(payload['autoCleanedPaths'], isNull);
        expect(payload['memoryState'], 'staged_until_user_verification');
        expect(payload['persistedToLongTermMemory'], isFalse);
        expect(payload['nextRequiredTool'], LocalToolNames.askUser);
        expect(await intermediateFile.exists(), isTrue);

        final prefs = await SharedPreferences.getInstance();
        final builds =
            (jsonDecode(prefs.getString('apk_mod_build_index_v1')!) as List)
                .cast<Map<String, dynamic>>();
        expect(
          builds.any(
            (b) =>
                b['output'] == '/ws/app-signed.apk' &&
                b['signed'] == true &&
                b['kind'] == 'build',
          ),
          isTrue,
        );
        expect(builds.any((b) => b['output'] == intermediate), isTrue);
        final signed = builds.firstWhere(
          (b) => b['output'] == '/ws/app-signed.apk',
        );
        expect(signed['pendingMemoryStatus'], 'awaiting_user_verification');

        await intermediateFile.parent.delete(recursive: true);
      },
    );
  });
}
