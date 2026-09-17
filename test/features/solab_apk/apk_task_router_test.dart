import 'package:flutter_test/flutter_test.dart';

import 'package:solab/features/solab_apk/services/apk_task_router.dart';

void main() {
  test('routes ad requests to focused report sections and tools', () {
    final result = ApkTaskRouter.route('去掉开屏广告');
    final tracks = List<Map<String, dynamic>>.from(result['tracks'] as List);

    expect(tracks.single['skill'], 'apk_ad_review');
    expect(tracks.single['reportSections'], containsAll(['decision', 'ads']));
    expect(tracks.single['preferredTools'], contains('patch_apk_dex_methods'));
    expect(tracks.single['preferredTools'], contains('dex_xref'));
    expect(tracks.single['preferredTools'], contains('so_analyze'));
    expect(result['repackPolicy'], isNotEmpty);
    expect(result['confirmMode'], 'batch');
    expect(result['actionPlan'], isNotEmpty);
    expect(result['executiveSummary'], contains('广告处理'));
    expect(result['decisionPolicy']['mode'], 'evidence_driven_composition');
    expect(result['evidenceRoutes'], isNotEmpty);
    expect(result['antiObfuscationPolicy'].join('\n'), contains('函数地址'));
    expect(result['conflictPolicy'].join('\n'), contains('第三种独立观察'));
  });

  test('会员和广告共享分析但分别定位核验', () {
    final result = ApkTaskRouter.route('解锁会员并去掉信息流广告');
    final policy = result['dualTargetPolicy'] as Map<String, dynamic>;

    expect((policy['shared'] as List).join('\n'), contains('Blutter analyze'));
    expect(
      policy['separate'],
      containsAll(['会员 locate/verify', '广告 locate/verify']),
    );
    expect(policy['merge'], contains('同一 SO/DEX'));
    expect(
      result['requiredRunStats'],
      containsAll(['工具调用数', '结果token估算', '耗时', '最终结论']),
    );
  });

  test('routes unknown requests to the minimal base analysis', () {
    final result = ApkTaskRouter.route('帮我看看这个 APK');
    final tracks = List<Map<String, dynamic>>.from(result['tracks'] as List);

    expect(tracks.single['skill'], 'apk_base_analysis');
    expect(tracks.single['reportSections'], ['decision']);
  });

  test('does not advertise unavailable root or unpack tools', () {
    final result = ApkTaskRouter.route('给加固包脱壳');
    final tracks = List<Map<String, dynamic>>.from(result['tracks'] as List);

    expect(tracks.map((track) => track['name']), isNot(contains('root 与脱壳')));
    final tools = tracks.expand((track) => track['preferredTools'] as List);
    expect(tools, isNot(contains('frida_control')));
    expect(tools, isNot(contains('dex_unpack')));
  });

  test('routes English Pro membership without confusing proxy', () {
    final membership = ApkTaskRouter.route('unlock Pro membership');
    final membershipTracks = List<Map<String, dynamic>>.from(
      membership['tracks'] as List,
    );
    expect(membershipTracks.map((track) => track['name']), contains('会员与检测'));
    expect(
      membershipTracks.map((track) => track['name']),
      isNot(contains('抓包与网络检测')),
    );
    expect(membershipTracks.single['preferredTools'], contains('so_analyze'));
    expect(
      membership['executionOrder'].join('\n'),
      contains('REPORT_NOT_READY'),
    );

    final capture = ApkTaskRouter.route('bypass proxy and SSL pinning');
    final captureTracks = List<Map<String, dynamic>>.from(
      capture['tracks'] as List,
    );
    expect(captureTracks.map((track) => track['name']), contains('抓包与网络检测'));
    expect(
      captureTracks.map((track) => track['name']),
      isNot(contains('会员与检测')),
    );
  });

  test('routes Flutter work through the focused locating skill', () {
    final result = ApkTaskRouter.route('分析 Flutter libapp.so 的会员等级');
    final tracks = List<Map<String, dynamic>>.from(result['tracks'] as List);
    final flutterTrack = tracks.firstWhere(
      (track) => track['name'] == 'Flutter 逆向',
    );

    expect(flutterTrack['skill'], 'apk_flutter_locate');
    expect(flutterTrack['preferredTools'], ['so_analyze']);
  });

  test('候选工具不是固定执行顺序，已有 locator 可直接验证', () {
    final result = ApkTaskRouter.route('验证已有的混淆方法 Lx/a;->a()Z');
    final order = (result['executionOrder'] as List).join('\n');
    final rules = (result['decisionPolicy']['rules'] as List).join('\n');

    expect(order, contains('直接从对应验证工具开始'));
    expect(rules, contains('不是必经链'));
    expect(rules, contains('一个直接证据可定案'));
  });
}
