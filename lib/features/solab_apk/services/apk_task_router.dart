import '../../../core/services/local_tools/local_tool_names.dart';
import 'apk_agent_policy.dart';

/// 根据用户目标选择最小的 APK 分析分区和工具集合。
class ApkTaskRouter {
  const ApkTaskRouter._();

  static Map<String, dynamic> route(String goal) {
    final query = goal.trim().toLowerCase();
    final executionMode = ApkAgentPolicy.executionModeFor(goal);
    final tracks = <Map<String, dynamic>>[];

    void add({
      required String name,
      String? skill,
      required List<String> sections,
      required List<String> tools,
    }) {
      tracks.add({
        'name': name,
        if (skill != null) 'skill': skill,
        'reportSections': sections,
        'preferredTools': tools,
        'knowledgeTopics': <String>[],
      });
    }

    if (_containsAny(query, [
      '广告',
      'ad',
      'ads',
      'banner',
      '开屏',
      'splash',
      'rewarded',
      'interstitial',
      '信息流',
      '原生广告',
      'advert',
      'native ad',
    ])) {
      add(
        name: '广告处理',
        skill: 'apk_ad_review',
        sections: ['decision', 'ads', 'components'],
        tools: [
          LocalToolNames.dexSearch,
          LocalToolNames.classOutline,
          LocalToolNames.dexXref,
          LocalToolNames.smaliRead,
          LocalToolNames.soAnalyze,
          LocalToolNames.apkPatchDex,
          LocalToolNames.apkPatchManifest,
        ],
      );
      tracks.last['knowledgeTopics'] = ['广告', '定位', '工具'];
    }
    if (_containsAny(query, [
      '会员',
      '权益',
      'vip',
      'svip',
      'premium',
      'member',
      'membership',
      'pro',
      '订阅',
      'subscription',
      '到期',
      '过期',
      'expiry',
      'lifetime',
    ])) {
      add(
        name: '会员与检测',
        skill: 'apk_change_plan',
        sections: ['decision', 'ads'],
        tools: [
          LocalToolNames.apkReport,
          LocalToolNames.apkAnalyzeWorkspace,
          LocalToolNames.soAnalyze,
        ],
      );
      tracks.last['knowledgeTopics'] = ['会员', '检测', '定位'];
    }
    if (_containsAny(query, [
      '抓包',
      '代理',
      '证书',
      '中间人',
      'vpn',
      'proxy',
      'pinning',
      'mitm',
      'ssl',
      'tls',
      'certificate',
    ])) {
      add(
        name: '抓包与网络检测',
        skill: 'apk_change_plan',
        sections: ['decision'],
        tools: [LocalToolNames.apkReport, LocalToolNames.soAnalyze],
      );
      tracks.last['knowledgeTopics'] = ['抓包', '代理', '证书', '定位'];
    }
    if (_containsAny(query, [
      '加密',
      '解密',
      'crypto',
      'cipher',
      'aes',
      'rsa',
      '签名校验',
    ])) {
      add(
        name: '加解密实现审查',
        sections: ['decision'],
        tools: [LocalToolNames.soAnalyze, LocalToolNames.dexSearch, LocalToolNames.classOutline, LocalToolNames.dexXref],
      );
      tracks.last['knowledgeTopics'] = ['加密', '解密', 'JNI', '定位'];
    }
    if (_containsAny(query, [
      'vpn',
      '代理检测',
      '模拟器',
      '虚拟机',
      '设备检测',
      '截屏',
      '录屏',
      'screen capture',
      'media projection',
    ])) {
      add(
        name: '环境与屏幕策略审查',
        sections: ['decision', 'components'],
        tools: [
          LocalToolNames.dexSearch,
          LocalToolNames.classOutline,
          LocalToolNames.dexXref,
          LocalToolNames.smaliRead,
          LocalToolNames.soAnalyze,
        ],
      );
      tracks.last['knowledgeTopics'] = ['设备检测', '屏幕策略', '定位'];
    }
    if (_containsAny(query, [
      '公告',
      '弹窗',
      '更新',
      '登录',
      '登录页',
      '强制更新',
      'dialog',
      'update',
      'login',
    ])) {
      add(
        name: '界面与登录流程审查',
        sections: ['decision', 'components'],
        tools: [LocalToolNames.dexSearch, LocalToolNames.classOutline, LocalToolNames.dexXref, LocalToolNames.smaliRead],
      );
      tracks.last['knowledgeTopics'] = ['公告', '弹窗', '更新', '登录', '定位'];
    }
    if (_containsAny(query, [
      '脱壳',
      '加固',
      '壳',
      'packer',
      'packed',
      'unpack',
      'shell',
    ])) {
      add(
        name: '加固与运行时载荷审查',
        sections: ['summary', 'files'],
        tools: [LocalToolNames.apkAnalyzeWorkspace, LocalToolNames.soAnalyze, LocalToolNames.dexSearch, LocalToolNames.file],
      );
      tracks.last['knowledgeTopics'] = ['加固壳', '动态加载', 'SO', '定位'];
    }
    if (_containsAny(query, ['权限', '组件', 'manifest', '导出'])) {
      add(
        name: '组件与权限',
        skill: 'apk_permission_review',
        sections: ['decision', 'permissions', 'components'],
        tools: [LocalToolNames.apkPatchManifest],
      );
      tracks.last['knowledgeTopics'] = ['权限', '组件', '修改计划'];
    }
    if (_containsAny(query, ['精简', '瘦身', '体积', 'abi', '资源'])) {
      add(
        name: '安装包精简',
        skill: 'apk_cleanup_review',
        sections: ['decision', 'files'],
        tools: [LocalToolNames.file, LocalToolNames.apkRebuild, LocalToolNames.apkSign],
      );
      tracks.last['knowledgeTopics'] = ['精简', '引用分析', 'SO'];
    }
    if (_containsAny(query, ['签名', '安装', '闪退', '崩溃', '启动'])) {
      add(
        name: '签名与验证',
        skill: 'apk_verify_patch',
        sections: ['summary', 'components'],
        tools: [LocalToolNames.apkReport, LocalToolNames.apkSignatureBypass, LocalToolNames.apkSign],
      );
      tracks.last['knowledgeTopics'] = ['签名', '验证', '加固', '去签'];
    }
    if (_containsAny(query, [
      '逆向',
      '反编译',
      '混淆',
      '代码定位',
      '方法定位',
      '字段定位',
      'reverse',
      'decompile',
      'obfuscation',
    ])) {
      add(
        name: '逆向与混淆定位',
        skill: 'apk_reverse_playbook',
        sections: ['decision'],
        tools: [LocalToolNames.dexSearch, LocalToolNames.classOutline, LocalToolNames.smaliRead, LocalToolNames.dexXref],
      );
      tracks.last['knowledgeTopics'] = ['逆向', '混淆', '定位'];
    }
    // —— 非 APK 轨道（兑现 runtime guide 承诺的六类意图路由）——
    // 关键词刻意收窄：'so'/'dart' 等裸短词会误匹配英文子串，一律用带边界
    // 的 token（.so 后缀/中文词），宁可少命中交给基础分析兜底也不误路由。
    if (_containsAny(query, ['.so', 'so文件', 'so库', 'native', 'elf', '动态库'])) {
      add(name: 'SO 分析', sections: <String>[], tools: [LocalToolNames.soAnalyze]);
      tracks.last['knowledgeTopics'] = ['SO', 'Rizin', '定位'];
    }
    if (_containsAny(query, ['flutter', 'libapp', 'blutter'])) {
      add(
        name: 'Flutter 逆向',
        skill: 'apk_flutter_locate',
        sections: <String>[],
        tools: [LocalToolNames.soAnalyze],
      );
      tracks.last['knowledgeTopics'] = ['Flutter', 'Blutter', 'SO'];
    }
    if (_containsAny(query, ['文件管理', '文件操作', '解压', '压缩', 'zip', '工作目录'])) {
      add(name: '文件操作', sections: <String>[], tools: [LocalToolNames.file]);
      tracks.last['knowledgeTopics'] = ['文件', '工作目录'];
    }
    if (tracks.isEmpty) {
      add(
        name: '基础分析',
        skill: 'apk_base_analysis',
        sections: ['decision'],
        tools: [LocalToolNames.apkReport],
      );
      tracks.last['knowledgeTopics'] = ['分析', '定位', '工具'];
    }

    return {
      'goal': goal,
      'executionMode': executionMode.name,
      'allowedBoundary': switch (executionMode) {
        ApkExecutionMode.reportOnly => '只读取现有事实并输出报告, 不启动修改或产物流程。',
        ApkExecutionMode.analyzeOnly => '只分析并输出结论, 不预览或执行任何修改。',
        ApkExecutionMode.modify => '可按证据执行用户明确要求的修改并生成产物。',
      },
      'tracks': tracks,
      'executiveSummary':
          '本次候选方向为 ${tracks.map((track) => track['name']).join('、')}。方向和工具都不是固定顺序，由当前产物中最有区分力的证据决定下一步。',
      'actionPlan': [
        for (final track in tracks)
          {
            'name': track['name'],
            'skill': track['skill'],
            'reportSections': track['reportSections'],
            'preferredTools': track['preferredTools'],
            'knowledgeTopics': track['knowledgeTopics'],
          },
      ],
      'confirmMode': 'batch',
      'decisionPolicy': {
        'version': ApkAgentPolicy.version,
        'mode': 'evidence_driven_composition',
        'rules': [
          '把目标拆成可证伪假设，每次选择最便宜且最能区分假设的工具；preferredTools 只是候选，不是必经链。',
          'DEX、Flutter、Native、资源和现有产物均可独立起步、独立收口，也可任意组合；已有精确 locator 时直接验证，不必补跑前置流程。',
          '一个直接证据可定案：目标函数体或字段数据流明确表达目标行为。没有直接证据时，使用两个来源独立的间接证据交叉确认。',
          '新结果只在能改变结论、候选排序或补丁手法时继续读取；否则停止探索。',
        ],
      },
      'evidenceRoutes': [
        {
          'name': '字符串或资源锚点',
          'canStartAlone': true,
          'tools': [LocalToolNames.dexSearch, LocalToolNames.stringScan, 'so_analyze(search/xref)'],
          'produces': ['字符串使用者', '对象池偏移', '资源到代码引用'],
        },
        {
          'name': '结构与数据流',
          'canStartAlone': true,
          'tools': [
            LocalToolNames.classOutline,
            LocalToolNames.dexXref,
            'analyzer_find_field_usage',
            LocalToolNames.smaliRead,
          ],
          'produces': ['字段读写者', '调用关系', '返回类型与真实分支'],
        },
        {
          'name': 'Flutter 与原生语义',
          'canStartAlone': true,
          'tools': ['so_analyze(locate/trace/values/xref/disasm/callers)'],
          'produces': ['函数 VA', '字段读写链', '常量证据', '对象池引用', '调用方'],
        },
        {
          'name': '产物或对照差异',
          'canStartAlone': true,
          'tools': [LocalToolNames.file, LocalToolNames.apkReport],
          'produces': ['当前产物事实', '版本差异', '已有精确定位符'],
        },
      ],
      'antiObfuscationPolicy': [
        '名称只作弱线索；短类名、匿名闭包和同名函数必须按文件、函数地址、签名、字段形态和调用位置区分。',
        '名称搜索失败时切换到字符串使用、资源 ID、常量、返回类型、字段 READ/WRITE、调用图或对象池引用，不重复改写同一个关键词。',
        '不同工具产物是同一程序的不同投影，不要求文本一致；先映射 APK 条目、DEX qualifiedId、ELF VA、Dart functionVa 的身份，再比较行为。',
      ],
      'conflictPolicy': [
        '当前文件的函数体或字段数据流高于缓存报告和名称规则。',
        '精确 locator 的证据高于包名、SDK 名和关键词命中。',
        '两条强证据冲突时保留两个假设，选择第三种独立观察；不得用多数票或固定偏好强行裁决。',
        '旧产物与当前 APK 冲突时先检查指纹和版本，不把不同构建误判成逻辑矛盾。',
      ],
      'executionOrder': [
        'route_task 只提供候选证据路线，不锁定执行顺序；若用户或现有产物已给出精确 locator，直接从对应验证工具开始。',
        '没有足够上下文时读取最小报告分区；已有局部证据时不要为了形式完整重跑 analyze_apk_workspace。',
        '任一证据路线可单独执行；结果不够区分假设时，再组合另一条独立路线。',
        'Blutter 专项 report 可直接复用；REPORT_NOT_READY 时可 locate，确无成功索引时才 analyze。缓存规则只避免重复计算，不限制证据路线。',
        '写入前只预览选中的工具；用户已授权精确修改时用 dryRun=true+applyAfterPreview=true 一次完成。纯预览则原样调用返回的 applyArguments，禁止重复 dryRun。',
        '交付链路是 一次分析→修改→签名→成品；签名落地后中间包已自动清理。修改无效时直接在上一版成品上叠改（它就是新基底）：不重跑 analyze_apk_workspace、不重做签名兼容、不从原包重开。',
      ],
      'performanceRule':
          '默认只返回结论、定位符、关键证据和下一种可区分假设的动作。工具说明按需读取；长清单只在用户明确要求导出时分页。约${ApkAgentPolicy.maxEvidenceTokens} token结果文本是防失控上限，不是要求用满的步骤预算。',
      'requiredRunStats': ['工具调用数', '结果token估算', '耗时', '最终结论'],
      if (tracks.any((track) => track['name'] == '广告处理') &&
          tracks.any((track) => track['name'] == '会员与检测'))
        'dualTargetPolicy': {
          'shared': [
            LocalToolNames.routeTask,
            LocalToolNames.apkProjectInfo,
            'get_current_apk_report(section=decision)',
            '同一 APK 的一次 Blutter analyze/index',
          ],
          'separate': ['会员 locate/verify', '广告 locate/verify'],
          'merge': '同一 SO/DEX 内的已验证改点合并到一次 build/写回/签名。',
        },
      'resourceFlow': [
        '指令注入由应用自动提供；稳定记忆和历史对话按任务相关性通过运行时工具读取。',
        'APK 世界书与用户安装 Skill 通过 get_apk_knowledge/get_installed_skills 按 knowledgeTopics 主动读取。',
        '世界书保存可复用知识与流程，不复制到其他存储，也不自动全文注入；Skill 只补充说明，不改变工具权限或确认边界。',
        '报告和工具结果是 APK 当前事实；只有缺少证据时才调用单点定位。',
      ],
      'repackPolicy': [
        '所有同类 DEX 修改合并为一次 patch_apk_dex_methods 调用。',
        '文件操作只处理当前工作目录中已确认的目标。',
        'Manifest、DEX 和 SO 操作保留独立预览；执行后不自动串联输出 APK。',
        '会员与广告同时命中同一 SO/DEX 时，共享一次分析并合并已验证改点，避免重复构建和签名。',
      ],
    };
  }

  static bool _containsAny(String text, List<String> values) => values.any((
    value,
  ) {
    final shortAscii =
        value.length <= 3 &&
        value.codeUnits.every(
          (unit) =>
              (unit >= 0x61 && unit <= 0x7a) || (unit >= 0x30 && unit <= 0x39),
        );
    return shortAscii
        ? RegExp(
            '(^|[^a-z0-9])${RegExp.escape(value)}([^a-z0-9]|\$)',
          ).hasMatch(text)
        : text.contains(value);
  });
}
