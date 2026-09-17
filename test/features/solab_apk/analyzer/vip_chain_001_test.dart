import 'package:flutter_test/flutter_test.dart';

import 'package:solab/features/solab_apk/analyzer/analyzer_api.dart';
import 'package:solab/features/solab_apk/analyzer/analyzer_gateway_impl.dart';
import 'package:solab/features/solab_apk/analyzer/analyzer_index.dart';

/// VIP_CHAIN_001：600 万 token 事故基准回归。
///
/// 场景：UserInfoBean.isVip 被谁写、被谁读，共同上游为 NetApi 回调。
/// Phase 0 验收标准：健康索引下，Analyzer 直接给出正确 Field XREF 与
/// authoritative writer，而不是「索引建好了」。
void main() {
  group('VIP_CHAIN_001（Phase 0 验收）', () {
    test('定位 isVip 字段 → Field XREF → 权威写入方（L3 证据闭环）', () async {
      // 构造健康索引（完整覆盖率）。
      final index = AnalyzerIndex(apkId: 'sha256:vipchain001');
      final builder = AnalyzerIndexBuilder(index: index);

      // 字段索引：isVip 出现在 UserInfoBean。
      builder.ingestModule('fields', <String, dynamic>{
        'dexId': 0,
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'Lcom/lindu/app/UserInfoBean;->isVip:Z',
            'owner': 'Lcom/lindu/app/UserInfoBean;',
            'signature': 'Lcom/lindu/app/UserInfoBean;->isVip:Z',
          },
        ],
      });
      // 方法索引：isVip 相关读写方。
      builder.ingestModule('methods', <String, dynamic>{
        'dexId': 0,
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'Lcom/lindu/app/NetApi;->onSuccess()V',
            'owner': 'Lcom/lindu/app/NetApi;',
            'signature': 'Lcom/lindu/app/NetApi;->onSuccess()V',
            'strings': <String>['vipExpire'],
          },
          <String, dynamic>{
            'name': 'Lcom/lindu/app/MineFragment;->updateUserInfo()V',
            'owner': 'Lcom/lindu/app/MineFragment;',
            'signature': 'Lcom/lindu/app/MineFragment;->updateUserInfo()V',
          },
        ],
      });
      // Field XREF：写入方=NetApi（authoritative），读取方=MineFragment。
      builder.ingestXref(<String, dynamic>{
        'dexId': 0,
        'calls': <Map<String, dynamic>>[
          <String, dynamic>{
            'caller': 'Lcom/lindu/app/NetApi;->onSuccess()V',
            'callee': 'Lcom/lindu/app/UserInfoBean;->setVip(Z)V',
          },
        ],
        'fieldRefs': <Map<String, dynamic>>[
          <String, dynamic>{
            'field': 'Lcom/lindu/app/UserInfoBean;->isVip:Z',
            'method': 'Lcom/lindu/app/NetApi;->onSuccess()V',
            'relation': 'WRITE_FIELD',
            'accessKind': 'WRITE_INSTANCE',
            'opcode': 'iput-boolean',
            'instructionIndex': 42,
          },
          <String, dynamic>{
            'field': 'Lcom/lindu/app/UserInfoBean;->isVip:Z',
            'method': 'Lcom/lindu/app/MineFragment;->updateUserInfo()V',
            'relation': 'READ_FIELD',
            'accessKind': 'READ_INSTANCE',
            'opcode': 'iget-boolean',
            'instructionIndex': 7,
          },
        ],
      });
      builder.setDexTotals(1, 1);
      // 类索引补全（覆盖率要求每类 >0 且 == 总数）。
      builder.ingestClasses(<String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{'name': 'Lcom/lindu/app/UserInfoBean;'},
        ],
      });
      // 覆盖率补满：classes/methods/fields 计数与索引总数一致（健康）。
      index
        ..classCount = index.classTotal
        ..methodCount = index.methodTotal
        ..fieldCount = index.fieldTotal;

      final gateway = DefaultAnalyzerGateway(index: index);

      // 1) 全局搜索 isVip → 命中字段。
      final search = await gateway.globalSearch(query: 'isVip');
      expect(search.primaryCandidates, isNotEmpty);

      // 2) find_field_usage：1 读 1 写，写入方确认 → L3。
      final usage = await gateway.findFieldUsage(
        fieldLocator: 'dex_field:Lcom/lindu/app/UserInfoBean;->isVip:Z',
      );
      expect(usage.summary, contains('1 读'));
      expect(usage.summary, contains('1 写'));
      expect(usage.evidenceLevel, EvidenceLevel.l3);

      // 3) analyze_business_state：权威写入方 = NetApi.onSuccess（读写闭环 → L4）。
      final biz = await gateway.analyzeBusinessState(targetKeyword: 'isVip');
      expect(biz.stopReason, 'authoritative_writer_confirmed');
      expect(biz.evidenceLevel, EvidenceLevel.l4);
      expect(
        biz.primaryCandidates.first.locator,
        contains('NetApi;->onSuccess'),
      );
      expect(biz.summary, contains('UserInfoBean;->isVip'));
      expect(biz.nextBestActions, isNotEmpty);
    });
  });
}
