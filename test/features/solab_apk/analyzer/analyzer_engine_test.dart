import 'package:flutter_test/flutter_test.dart';

import 'package:solab/features/solab_apk/analyzer/analyzer_api.dart';
import 'package:solab/features/solab_apk/analyzer/analyzer_gateway_impl.dart';
import 'package:solab/features/solab_apk/analyzer/analyzer_index.dart';

void main() {
  group('AnalyzerIndex（Phase 0 索引状态机 + Field XREF）', () {
    test('状态机：pending→building→ready', () {
      final index = AnalyzerIndex(apkId: 'sha256:test');
      expect(index.states[IndexKind.method], IndexState.pending);

      final builder = AnalyzerIndexBuilder(index: index);
      builder.ingestModule('methods', <String, dynamic>{
        'dexId': 0,
        'items': [
          <String, dynamic>{
            'name': 'Lcom/x/UserInfoBean;->isVip()Z',
            'owner': 'Lcom/x/UserInfoBean;',
            'signature': 'Lcom/x/UserInfoBean;->isVip()Z',
            'strings': <String>['vipExpire'],
          },
        ],
      });

      expect(index.states[IndexKind.method], IndexState.ready);
      expect(index.methodTotal, 1);
      expect(index.methodsByString['vipExpire'], isNotEmpty);
    });

    test('ingestXref：Field XREF 独立就绪 + READ/WRITE 计数', () {
      final index = AnalyzerIndex(apkId: 'sha256:test');
      final builder = AnalyzerIndexBuilder(index: index);
      builder.ingestXref(<String, dynamic>{
        'dexId': 1,
        'calls': <Map<String, dynamic>>[
          <String, dynamic>{
            'caller': 'Lcom/x/A;->m()V',
            'callee': 'Lcom/x/B;->n()V',
          },
        ],
        'fieldRefs': <Map<String, dynamic>>[
          <String, dynamic>{
            'field': 'Lcom/x/UserInfoBean;->isVip:Z',
            'method': 'Lcom/x/NetApi;->onSuccess()V',
            'relation': 'WRITE_FIELD',
            'opcode': 'iput',
            'instructionIndex': 42,
          },
          <String, dynamic>{
            'field': 'Lcom/x/UserInfoBean;->isVip:Z',
            'method': 'Lcom/x/MineFragment;->update()V',
            'relation': 'READ_FIELD',
            'opcode': 'iget',
            'instructionIndex': 7,
          },
        ],
      });

      expect(index.states[IndexKind.fieldXref], IndexState.ready);
      final refs = index.fieldRefs('dex_field:Lcom/x/UserInfoBean;->isVip:Z');
      expect(refs.length, 2);
      expect(refs.where((r) => r.relation == 'WRITE_FIELD').length, 1);
      expect(refs.where((r) => r.relation == 'READ_FIELD').length, 1);
      // 调用图边
      expect(index.outgoing('dex_method:Lcom/x/A;->m()V').length, 1);
    });
  });

  group('Locator（统一规范）', () {
    test('解析 8 种 locator', () {
      expect(Locator.tryParse('dex_class:Lcom/x/A;'), isA<DexClassLocator>());
      expect(
        Locator.tryParse('dex_method:Lcom/x/A;->m()V'),
        isA<DexMethodLocator>(),
      );
      expect(
        Locator.tryParse('dex_field:Lcom/x/A;->f:I'),
        isA<DexFieldLocator>(),
      );
      expect(Locator.tryParse('string:"vipExpire"'), isA<StringLocator>());
      expect(Locator.tryParse('resource:0x7f010000'), isA<ResourceLocator>());
      expect(
        Locator.tryParse('so:lib/arm64-v8a/libnative.so'),
        isA<SoLocator>(),
      );
      expect(
        Locator.tryParse('native:libnative.so@0x123456'),
        isA<NativeLocator>(),
      );
      expect(
        Locator.tryParse('zip_entry:AndroidManifest.xml'),
        isA<ZipEntryLocator>(),
      );
      expect(Locator.tryParse('garbage'), isNull);
    });
  });

  group('DefaultAnalyzerGateway（20 API）', () {
    test('apkId 不一致时拒绝查询，避免跨 APK 静默取证', () async {
      final gateway = DefaultAnalyzerGateway(
        index: AnalyzerIndex(apkId: 'sha256:apk-x'),
      );

      final result = await gateway.findFieldUsage(
        fieldLocator: 'dex_field:Lcom/x/UserInfoBean;->isVip:Z',
        apkId: 'sha256:apk-y',
      );

      expect(result.stopReason, 'apk_context_mismatch');
      expect(
        (result.detail as Map<String, dynamic>)['code'],
        'APK_CONTEXT_MISMATCH',
      );
      expect(
        (result.detail as Map<String, dynamic>)['currentApkId'],
        'sha256:apk-x',
      );
    });

    test('Registry 按入口隔离网关实例', () {
      AnalyzerGatewayRegistry.resetForTest();
      final first = AnalyzerGatewayRegistry.forKey('mcp:client-a');
      final same = AnalyzerGatewayRegistry.forKey('mcp:client-a');
      final other = AnalyzerGatewayRegistry.forKey('mcp:client-b');

      expect(identical(first, same), isTrue);
      expect(identical(first, other), isFalse);
      AnalyzerGatewayRegistry.resetForTest();
    });

    test('find_field_usage：返回 READ/WRITE + 证据链', () async {
      final index = AnalyzerIndex(apkId: 'sha256:test');
      AnalyzerIndexBuilder(index: index).ingestXref(<String, dynamic>{
        'dexId': 0,
        'calls': const [],
        'fieldRefs': <Map<String, dynamic>>[
          <String, dynamic>{
            'field': 'Lcom/x/UserInfoBean;->isVip:Z',
            'method': 'Lcom/x/NetApi;->onSuccess()V',
            'relation': 'WRITE_FIELD',
            'opcode': 'iput',
            'instructionIndex': 0,
          },
        ],
      });
      final gateway = DefaultAnalyzerGateway(index: index);

      final r = await gateway.findFieldUsage(
        fieldLocator: 'dex_field:Lcom/x/UserInfoBean;->isVip:Z',
      );

      expect(r.summary, contains('1 写'));
      expect(r.primaryCandidates.length, 1);
      expect(r.evidenceLevel, EvidenceLevel.l3);
      expect(r.sufficiency, Sufficiency.complete);
      final refs = (r.detail as Map<String, dynamic>)['refs'] as List;
      expect(refs.length, 1);
      // 证据链：返回可复验证据（method + opcode + instruction_index）。
      expect(r.evidenceGraph['evidence'], isNotEmpty);
      expect(r.uncertainties, isEmpty);
      expect(r.nextActions.map((action) => action.tool).toSet(), <String>{
        'smali_read',
        'dex_xref',
      });
      expect(
        r.nextBestActions,
        everyElement(isNot(contains('trace_backward'))),
      );
      expect(
        r.nextBestActions,
        everyElement(isNot(contains('inspect_entities'))),
      );
    });

    test('analyze_business_state：命中权威写入方 → L3 + stop_reason', () async {
      final index = AnalyzerIndex(apkId: 'sha256:test');
      final builder = AnalyzerIndexBuilder(index: index);
      builder.ingestModule('fields', <String, dynamic>{
        'dexId': 0,
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'Lcom/x/UserInfoBean;->isVip:Z',
            'owner': 'Lcom/x/UserInfoBean;',
            'signature': 'Lcom/x/UserInfoBean;->isVip:Z',
          },
        ],
      });
      builder.ingestXref(<String, dynamic>{
        'dexId': 0,
        'calls': const [],
        'fieldRefs': <Map<String, dynamic>>[
          <String, dynamic>{
            'field': 'Lcom/x/UserInfoBean;->isVip:Z',
            'method': 'Lcom/x/NetApi;->onSuccess()V',
            'relation': 'WRITE_FIELD',
            'opcode': 'iput',
            'instructionIndex': 0,
          },
        ],
      });
      final gateway = DefaultAnalyzerGateway(index: index);

      final r = await gateway.analyzeBusinessState(targetKeyword: 'isVip');
      expect(r.stopReason, 'authoritative_writer_confirmed');
      expect(r.evidenceLevel, EvidenceLevel.l3);
      expect(r.primaryCandidates.first.locator, contains('NetApi'));
    });
  });

  group('Method Body Index（Phase 1）', () {
    test('ingestMethodBody + instructionWindow 窗口查询', () {
      final index = AnalyzerIndex(apkId: 'sha256:mb');
      final builder = AnalyzerIndexBuilder(index: index);
      builder.ingestMethodBody(
        'Lcom/x/NetApi;->onSuccess()V',
        <String, dynamic>{
          'signature': 'Lcom/x/NetApi;->onSuccess()V',
          'instructions': <Map<String, dynamic>>[
            <String, dynamic>{
              'index': 40,
              'opcode': 'iget-boolean',
              'refs': <Map<String, dynamic>>[
                <String, dynamic>{
                  'target': 'Lcom/x/UserInfoBean;->isVip:Z',
                  'type': 'field',
                },
              ],
            },
            <String, dynamic>{
              'index': 42,
              'opcode': 'iput-boolean',
              'refs': <Map<String, dynamic>>[
                <String, dynamic>{
                  'target': 'Lcom/x/UserInfoBean;->isVip:Z',
                  'type': 'field',
                },
              ],
            },
            <String, dynamic>{
              'index': 50,
              'opcode': 'invoke-virtual',
              'refs': <Map<String, dynamic>>[
                <String, dynamic>{
                  'target': 'Lcom/x/UserInfoBean;->setVip(Z)V',
                  'type': 'invoke',
                },
              ],
            },
          ],
        },
      );

      final body = index.methodBody('dex_method:Lcom/x/NetApi;->onSuccess()V');
      expect(body, isNotNull);
      expect(body!.fieldRefs.length, 2);
      expect(body.invokeRefs.length, 1);

      final window = index.instructionWindow(
        'dex_method:Lcom/x/NetApi;->onSuccess()V',
        42,
        window: 5,
      );
      expect(window['refs'], hasLength(2)); // 40(iget)/42(iput) 在窗口内，50 不在
    });
  });
}
