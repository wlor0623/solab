import 'package:flutter_test/flutter_test.dart';

import 'package:solab/features/home/services/tool_handler_service.dart'
    show ToolLoadPolicy;
import 'package:solab/features/home/services/task_router.dart';
import 'package:solab/features/home/services/tool_router.dart';
import 'package:solab/features/solab_apk/services/apk_agent_policy.dart';

void main() {
  group('ToolRouter', () {
    test('APK 路由把自由编排和冲突裁决交给 Agent', () {
      final route = TaskRouter.route('分析 APK 中的混淆会员逻辑');

      expect(route['decisionPolicy']['mode'], 'evidence_driven_composition');
      expect(route['evidenceRoutes'], isNotEmpty);
      expect(route['conflictPolicy'].join('\n'), contains('精确 locator'));
      expect(route['workflow'].join('\n'), contains('候选探针'));
      expect(route['executionMode'], 'analyzeOnly');
    });

    test('报告、分析、修改三种边界互不越权', () {
      final report = ToolExpansion(
        apkTask: true,
        executionMode: ApkExecutionMode.reportOnly,
      )..applyTrackText('track=dex_native');
      expect(report.names(), contains('get_current_apk_report'));
      expect(report.names(), isNot(contains('dex_search')));
      expect(report.names(), isNot(contains('patch_apk_dex_methods')));

      final analyze = ToolExpansion(
        apkTask: true,
        executionMode: ApkExecutionMode.analyzeOnly,
      )..applyTrackText('track=dex_native');
      expect(analyze.names(), contains('dex_search'));
      expect(analyze.names(), isNot(contains('patch_apk_dex_methods')));
      expect(analyze.names(), isNot(contains('apk_sign')));

      final modify = ToolExpansion(
        apkTask: true,
        executionMode: ApkExecutionMode.modify,
      )..applyTrackText('track=dex_native');
      expect(modify.names(), contains('patch_apk_dex_methods'));
    });

    test('纯闲聊 → none（不声明任何工具）', () {
      final names = ToolRouter.resolve(
        policy: ToolLoadPolicy.none,
        userText: '你好',
      );
      expect(names, isNotNull);
      expect(names, isEmpty);
    });

    test('casual 判定：你好/谢谢 是闲聊；带任务词不是', () {
      expect(ToolRouter.isCasualText('你好'), isTrue);
      expect(ToolRouter.isCasualText('谢谢'), isTrue);
      expect(ToolRouter.isCasualText('在吗'), isTrue);
      expect(ToolRouter.isCasualText('好的'), isTrue);
      expect(ToolRouter.isCasualText('帮我分析这个apk'), isFalse);
      expect(ToolRouter.isCasualText('查一下文件'), isFalse);
      expect(ToolRouter.isCasualText('修改目标'), isFalse);
      // 过长消息不算闲聊
      expect(ToolRouter.isCasualText('你好，这是一段明显超过二十四字符限制的聊天消息哦'), isFalse);
    });

    test('full → 分层起始集（不全量声明工具）', () {
      final names = ToolRouter.resolve(
        policy: ToolLoadPolicy.full,
        userText: '分析 apk',
      );
      expect(names, ToolRouter.tier0Names.union(ToolRouter.tier1Names));
    });

    test('light + 消息含 apk → core + workspace 工具', () {
      final names = ToolRouter.resolve(
        policy: ToolLoadPolicy.light,
        userText: '帮我分析这个 apk',
      );
      expect(names, isNotNull);
      expect(names!.isNotEmpty, isTrue);
      // 轻量请求只保留可直接使用的核心入口
      expect(names, contains('ask_user_input_v0'));
      // 工作区工具按关键词命中
      expect(names, contains('analyze_apk_workspace'));
      // 绝不含重型分析/改写工具
      expect(names, isNot(contains('dex_search')));
    });

    test('light + 无关键词 → 保留完整核心入口，extras 受上限约束', () {
      final names = ToolRouter.resolveLightSelection('随便聊聊');
      expect(names, contains('ask_user_input_v0'));
      expect(names, contains('route_task'));
      expect(names, contains('get_agent_runtime_guide'));
      expect(names, contains('get_solab_tool_map'));
      expect(names, contains('list_workspace_apks'));
      expect(names, ToolRouter.coreNames);
      // 无关键词不应误引入设备/工作区工具（可能算入 core 的除外）
      expect(names.contains('clipboard_tool'), isFalse);
    });

    test('记忆工具仅在消息明确需要记忆时按需加入', () {
      expect(
        ToolRouter.resolveMemorySelection('帮我记住这个偏好'),
        contains('memory_update'),
      );
      expect(ToolRouter.resolveMemorySelection('帮我分析这个 apk'), isEmpty);
    });

    test('light + 设备关键词 → 打进 device 域', () {
      final names = ToolRouter.resolveLightSelection('现在几点 / 帮我朗读这段');
      expect(names, isNot(contains('dex_search')));
    });

    test('schema 懒加载：非关键工具不带完整 parameters，关键工具保留', () {
      expect(ToolRouter.isSchemaCritical('ask_user_input_v0'), isTrue);
      expect(ToolRouter.isSchemaCritical('smali_read'), isTrue);
      expect(ToolRouter.isSchemaCritical('get_solab_tool_map'), isTrue);
      expect(ToolRouter.isSchemaCritical('so_patch_into_apk'), isTrue);
      expect(ToolRouter.isSchemaCritical('signature_bypass'), isTrue);
      expect(ToolRouter.isSchemaCritical('apk_rebuild'), isTrue);
      expect(ToolRouter.isSchemaCritical('get_time_info'), isFalse);
    });
  });

  group('ToolExpansion（流程图① 动态分层）', () {
    test('chat：只挂 Tier0', () {
      final e = ToolExpansion(apkTask: false);
      expect(e.names(), ToolRouter.tier0Names);
    });

    test('apk_task：挂 Tier0+Tier1', () {
      final e = ToolExpansion(apkTask: true);
      final names = e.names();
      expect(names, ToolRouter.tier0Names.union(ToolRouter.tier1Names));
      // 未定轨前不含重型链
      expect(
        names.intersection(
          ToolRouter.tier2ByTrack.values.expand((s) => s).toSet(),
        ),
        isEmpty,
      );
    });

    test('route_task 返回 flutter 轨道 → 动态追加 Tier2-Flutter', () {
      final e = ToolExpansion(apkTask: true);
      e.applyTrackText('track=flutter_vip 会员逻辑');
      final names = e.names();
      expect(names, contains('so_analyze'));
      expect(names, contains('so_patch_into_apk'));
      expect(names, contains('patch_apk_dex_methods'));
    });

    test('route_task 返回 dex 轨道 → 动态追加 Tier2-DEX', () {
      final e = ToolExpansion(apkTask: true);
      e.applyTrackText('track=dex_native 反编译 smali');
      expect(e.names(), contains('jadx_decompile'));
      expect(e.names(), contains('patch_apk_dex_methods'));
    });

    test('route_task 的广告工具保留到 Flutter 双轨任务', () {
      final e = ToolExpansion(apkTask: true);
      e.applyTrackText(
        '{"toolTrack":"flutter_vip","recommendedTools":["dex_search","patch_apk_dex_methods","patch_apk_manifest"]}',
      );
      expect(
        e.names(),
        containsAll(<String>[
          'so_analyze',
          'dex_search',
          'patch_apk_dex_methods',
          'patch_apk_manifest',
        ]),
      );
    });

    test('初始非 APK 任务经 route_task 定轨后升级为 APK 工具集', () {
      final e = ToolExpansion(apkTask: false);
      e.applyTrackText('{"track":"dex_native","target":"vip"}');
      expect(e.isApkTask, isTrue);
      expect(e.names(), containsAll(ToolRouter.tier1Names));
      expect(e.names(), contains('patch_apk_dex_methods'));
    });

    test('route_task 的明确轨道优先于结果中的会员等描述词', () {
      expect(
        ToolRouter.resolveTrackFromText(
          '{"track":"dex_native","target":"会员逻辑"}',
        ),
        ToolTrack.dexNative,
      );
    });

    test('会员文字本身不再猜测 Flutter 轨道', () {
      expect(ToolRouter.resolveTrackFromText('会员状态需要先分析'), isNull);
    });

    test('工作区分析结果按 Flutter 实证定轨', () {
      final flutter = ToolExpansion(apkTask: true);
      flutter.applyWorkspaceAnalysisText('{"flutterDetected":true}');
      expect(flutter.track, ToolTrack.flutterVip);
      expect(
        flutter.tracks,
        containsAll(<ToolTrack>[ToolTrack.flutterVip, ToolTrack.dexNative]),
      );
      expect(
        flutter.names(),
        containsAll(<String>['so_analyze', 'dex_search', 'smali_read']),
      );

      final dex = ToolExpansion(apkTask: true);
      dex.applyWorkspaceAnalysisText('{"flutterDetected":false}');
      expect(dex.track, ToolTrack.dexNative);
    });

    test('route_task 可同时启用多条独立工具轨道', () {
      final expansion = ToolExpansion(apkTask: true);
      expansion.applyTrackText(
        '{"toolTrack":"flutter_vip","toolTracks":["flutter_vip","dex_native"]}',
      );

      expect(
        expansion.tracks,
        containsAll(<ToolTrack>[ToolTrack.flutterVip, ToolTrack.dexNative]),
      );
      expect(
        expansion.names(),
        containsAll(<String>['so_analyze', 'dex_xref', 'class_outline']),
      );
    });

    test('so 轨道 → Tier2-SO；修改工具 → 追加 Tier3', () {
      final e = ToolExpansion(apkTask: true);
      e.applyTrackText('so rz_analysis libnative');
      expect(e.names(), contains('so_analyze'));
      // 完成前不追加 Tier3（验证/记忆仅修改后需要）
      expect(e.names(), isNot(contains('record_apk_patch_verification')));
      e.markCompletion();
      expect(e.names(), contains('apk_sign'));
      expect(e.names(), contains('record_apk_patch_verification'));
    });

    test('意图分类：apk_task vs chat', () {
      expect(ToolRouter.isApkTaskIntent('帮我分析这个 apk 去广告'), isTrue);
      expect(ToolRouter.isApkTaskIntent('解锁会员'), isTrue);
      expect(ToolRouter.isApkTaskIntent('查 FLAG_SECURE'), isTrue);
      expect(ToolRouter.isApkTaskIntent('你好'), isFalse);
      expect(ToolRouter.isApkTaskIntent('今天天气怎么样'), isFalse);
    });

    test('有效路由在非闲聊消息中恢复 APK 工具集', () {
      expect(
        ToolRouter.shouldResumeApkTask(
          hasValidRoute: true,
          userText: 'FLAG_SECURE',
        ),
        isTrue,
      );
      expect(
        ToolRouter.shouldResumeApkTask(hasValidRoute: true, userText: '你好'),
        isFalse,
      );
    });

    test('轻量首轮路由成功后,下一轮按扩容状态重建工具表', () {
      final expansion = ToolExpansion(apkTask: false)
        ..applyTrackText('{"track":"dex_native"}');

      final names = ToolRouter.resolveForExpansion(
        initialPolicy: ToolLoadPolicy.light,
        expansion: expansion,
        userText: '查 FLAG_SECURE',
      );

      expect(names, containsAll(<String>['dex_search', 'smali_read']));
    });

    test('恢复的修改路由会恢复写工具', () {
      final expansion = ToolExpansion(
        apkTask: true,
        executionMode: ApkExecutionMode.analyzeOnly,
      )..applyTrackText('{"track":"dex_native","executionMode":"modify"}');

      expect(expansion.executionMode, ApkExecutionMode.modify);
      expect(expansion.names(), contains('patch_apk_dex_methods'));
    });

    test('恢复会话从最后一个有效 route_task 结果续接工具轨道', () {
      final route = ToolRouter.latestValidRouteResult([
        <String, dynamic>{
          'role': 'tool',
          'name': 'route_task',
          'content': '{"track":"flutter_vip"}',
        },
        <String, dynamic>{'role': 'user', 'content': '继续修复写回'},
      ]);

      expect(route, isNotNull);
      expect(ToolRouter.isApkTaskContinuation('继续修复写回'), isTrue);
      expect(ToolRouter.isApkTaskContinuation('今天天气怎么样'), isFalse);
      final expansion = ToolExpansion(apkTask: true)..applyTrackText(route!);
      expect(expansion.names(), contains('so_patch_into_apk'));
    });

    test('恢复会话忽略无有效轨道的旧问答状态', () {
      expect(
        ToolRouter.latestValidRouteResult([
          <String, dynamic>{
            'role': 'tool',
            'name': 'route_task',
            'content': '{"answerMode":"question"}',
          },
        ]),
        isNull,
      );
    });

    test('常用安全与界面目标会路由到专项审查工具', () {
      final route = TaskRouter.route(
        '分析 APK 的加解密、VPN 和虚拟机检测、截屏录屏、公告弹窗更新、登录和脱壳',
      );

      expect(route['intent'], 'solab_apk');
      expect(
        route['recommendedTools'],
        containsAll(<String>[
          'so_analyze',
          'dex_search',
          'class_outline',
          'dex_xref',
          'smali_read',
        ]),
      );
      final audits = route['featureAudits'] as List<dynamic>;
      expect(
        audits.map((item) => item['name']),
        containsAll(<String>[
          '加解密实现审查',
          '环境与屏幕策略审查',
          '界面与登录流程审查',
          '加固与运行时载荷审查',
        ]),
      );
    });
  });
}
