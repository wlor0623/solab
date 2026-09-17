import '../../../core/services/local_tools/local_tool_names.dart';
import '../../solab_apk/services/apk_task_router.dart';

/// 为 Agent 返回当前可用工具、知识和 Skill 的最小任务计划。
class TaskRouter {
  const TaskRouter._();

  static const _apkKeywords = <String>[
    'apk',
    '安装包',
    '去广告',
    '广告',
    '会员',
    'vip',
    '解锁',
    '精简',
    '签名',
    'dex',
    'smali',
    '反编译',
    'manifest',
    '权限',
    '闪退',
    '崩溃',
    '加密',
    '解密',
    'vpn',
    '模拟器',
    '虚拟机',
    '截屏',
    '录屏',
    '公告',
    '弹窗',
    '更新',
    '登录',
    '脱壳',
    '加固',
  ];
  static const _flutterKeywords = <String>[
    'flutter',
    'dart',
    'libapp',
    'libflutter',
    'blutter',
  ];
  static const _soKeywords = <String>[
    '.so',
    'so文件',
    'so库',
    'native',
    'elf',
    '动态库',
    '交叉引用',
    'xref',
  ];
  static const _fileKeywords = <String>[
    '文件操作',
    '工作目录',
    '压缩',
    '解压',
    'zip',
    '导出',
  ];
  static Map<String, dynamic> route(String goal) {
    final query = goal.trim().toLowerCase();
    if (query.isEmpty) return _chatRoute('请说明要处理的目标。');
    if (_containsAny(query, _apkKeywords)) return _apkRoute(goal, query);
    if (_containsAny(query, _flutterKeywords)) return _flutterRoute(query);
    if (_containsAny(query, _soKeywords)) return _soRoute();
    if (_containsAny(query, _fileKeywords)) return _fileRoute();
    return _chatRoute('纯问答不加载工具；用户给出 APK、SO 或工作目录目标后再路由。');
  }

  static Map<String, dynamic> _apkRoute(String goal, String query) {
    final routed = ApkTaskRouter.route(goal);
    final tracks = (routed['tracks'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .toList(growable: false);
    final topics = <String>{'APK', '工作流', '规则'};
    final builtInSkills = <String>{};
    final trackTools = <String>{};
    for (final track in tracks) {
      final values = track['knowledgeTopics'];
      if (values is List) {
        topics.addAll(values.map((value) => value.toString()));
      }
      final skill = track['skill']?.toString();
      if (skill != null && skill.isNotEmpty) builtInSkills.add(skill);
      final tools = track['preferredTools'];
      if (tools is List) {
        trackTools.addAll(tools.map((value) => value.toString()));
      }
    }
    final needsFeatureReview = _containsAny(query, const <String>[
      '广告',
      '检测',
      '权限',
      '组件',
      '精简',
      'root',
      'vpn',
      '模拟器',
      '加密',
      '解密',
      '虚拟机',
      '截屏',
      '录屏',
      '公告',
      '弹窗',
      '更新',
      '登录',
      '脱壳',
      '加固',
    ]);
    final featureAudits = _featureAudits(query);
    // Flutter 意图与通用 APK 词（会员/广告/去广告…）同时命中时，
    // 目标走 _apkRoute 而非 _flutterRoute；此处补齐 _flutterRoute 的专属
    // 推荐，避免 flutter+会员任务拿不到 flutter_vip_unlock skill。
    final flutterIntent = _containsAny(query, _flutterKeywords);
    if (flutterIntent) {
      topics.addAll(const <String>['Flutter', 'Blutter']);
      final vipIntent = _containsAny(query, const <String>[
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
      ]);
      if (vipIntent) builtInSkills.add('flutter_vip_unlock');
    }
    if (routed['executionMode'] == 'modify') {
      builtInSkills.add('apk_apply_patch');
    }
    return {
      'intent': 'solab_apk',
      'track': tracks.map((track) => track['name']).join('、'),
      'knowledgeTopics': topics.toList(growable: false),
      'requiredSkills': builtInSkills.toList(growable: false),
      'recommendedTools': <String>{
        LocalToolNames.apkReport,
        ...trackTools,
      }.toList(growable: false),
      'decisionPolicy': routed['decisionPolicy'],
      'executionMode': routed['executionMode'],
      'allowedBoundary': routed['allowedBoundary'],
      'evidenceRoutes': routed['evidenceRoutes'],
      'antiObfuscationPolicy': routed['antiObfuscationPolicy'],
      'conflictPolicy': routed['conflictPolicy'],
      if (featureAudits.isNotEmpty) 'featureAudits': featureAudits,
      'resourcePlan': {
        'worldBooks': '仅在知识书会改变下一步时读取相关条目。',
        'installedSkills': '仅在启用的用户 Skill 与当前任务相关时读取。',
        'builtInSkills': builtInSkills.isEmpty
            ? '本任务没有额外内置 Skill。'
            : '仅在需要额外操作步骤时读取 requiredSkills。',
        'customFeatures': needsFeatureReview
            ? '报告出现规则命中时才读取 list_apk_rules。'
            : '规则引擎自动参与分析；无命中不读取规则页。',
      },
      'memoryToCheck': const <String>[LocalToolNames.apkNoteRead],
      'workflow': const <String>[
        'recommendedTools 是可独立组合的候选探针，不是执行顺序。已有精确 locator 时直接验证。',
        '报告缺失且确实需要全局上下文时才 analyze_apk_workspace；局部证据足以区分假设时不补跑。',
        '每次只选择能改变候选排序或补丁手法的一项观察；直接行为证据可收口，弱线索才需要独立交叉。',
        '用户已授权精确修改时，支持的写工具用 dryRun=true+applyAfterPreview=true 一次完成。',
      ],
      'guardrails': const <String>[
        '世界书、Skill 与自定义特征提供检查项，不替代当前 APK 的工具证据。',
        '任何写入都只能在工作目录产物上进行。',
      ],
    };
  }

  static Map<String, dynamic> _flutterRoute(String query) => {
    'intent': 'flutter_analysis',
    'track': 'Flutter AOT 分析',
    'knowledgeTopics': const <String>['Flutter', 'Blutter', 'SO'],
    'recommendedTools': const <String>[
      LocalToolNames.apkKnowledge,
      LocalToolNames.installedSkills,
      LocalToolNames.soAnalyze,
    ],
    'requiredSkills': _containsAny(query, const <String>['会员', 'vip', '广告'])
        ? const <String>['flutter_vip_unlock']
        : const <String>[],
    'workflow': const <String>[
      '知识、Skill、Blutter 子动作和现有产物都可独立起步；只读取会改变判断的内容。',
      '已有 functionVa、池偏移或数值时直接调用对应动作，不补跑固定链。',
    ],
    'decisionMode': 'evidence_driven_composition',
  };

  static Map<String, dynamic> _soRoute() => {
    'intent': 'so_analysis',
    'track': 'SO 分析',
    'knowledgeTopics': const <String>['SO', '定位'],
    'recommendedTools': const <String>[
      LocalToolNames.apkKnowledge,
      LocalToolNames.installedSkills,
      LocalToolNames.soAnalyze,
    ],
    'requiredSkills': const <String>[],
    'workflow': const <String>[
      '已有文件、VA、符号或引用时从对应 so_analyze 动作直接开始。',
      '符号缺失时改用常量、字符串、函数边界和调用位置，不按名称穷举。',
    ],
    'decisionMode': 'evidence_driven_composition',
  };

  static Map<String, dynamic> _fileRoute() => {
    'intent': 'file_ops',
    'track': '工作目录文件操作',
    'knowledgeTopics': const <String>['文件', '工作目录'],
    'recommendedTools': const <String>[LocalToolNames.file],
    'requiredSkills': const <String>[],
    'workflow': const <String>['先用 file 确认路径和操作，再按工具要求预览与确认。'],
  };

  static List<Map<String, dynamic>> _featureAudits(String query) {
    final audits = <Map<String, dynamic>>[];
    if (_containsAny(query, const <String>[
      '加密',
      '解密',
      'crypto',
      'cipher',
      'aes',
      'rsa',
      '签名校验',
    ])) {
      audits.add(const <String, dynamic>{
        'name': '加解密实现审查',
        'dexTerms': ['cipher', 'encrypt', 'decrypt', 'aes', 'rsa', 'key', 'iv'],
        'soActions': ['crypto_scan', 'jni_bridge'],
        'evidence': '算法常量、导入符号与调用点至少两类证据相互印证。',
      });
    }
    if (_containsAny(query, const <String>[
      'vpn',
      '代理',
      '模拟器',
      '虚拟机',
      '设备检测',
      '截屏',
      '录屏',
      'screen capture',
      'media projection',
    ])) {
      audits.add(const <String, dynamic>{
        'name': '环境与屏幕策略审查',
        'dexTerms': [
          'vpn',
          'proxy',
          'emulator',
          'virtual',
          'flag_secure',
          'media_projection',
        ],
        'soActions': ['strings', 'search'],
        'evidence': '确认检测结果实际支配的分支和调用方,名称或字符串命中只算线索。',
      });
    }
    if (_containsAny(query, const <String>[
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
      audits.add(const <String, dynamic>{
        'name': '界面与登录流程审查',
        'dexTerms': [
          'announcement',
          'notice',
          'dialog',
          'update',
          'version',
          'login',
          'token',
        ],
        'soActions': <String>[],
        'evidence': '定位真实展示或跳转入口,并区分本地 UI、远程配置和服务端状态。',
      });
    }
    if (_containsAny(query, const <String>[
      '脱壳',
      '加固',
      '壳',
      'packer',
      'packed',
      'unpack',
      'shell',
    ])) {
      audits.add(const <String, dynamic>{
        'name': '加固与运行时载荷审查',
        'dexTerms': [
          'dexclassloader',
          'pathclassloader',
          'loadlibrary',
          'asset',
        ],
        'soActions': ['overview', 'read_elf', 'strings', 'jni_bridge'],
        'evidence': '先确认壳、动态加载和真实代码载荷位置,再决定后续分析方式。',
      });
    }
    return audits;
  }

  static Map<String, dynamic> _chatRoute(String hint) => {
    'intent': 'chat',
    'track': '通用问答',
    'knowledgeTopics': const <String>[],
    'recommendedTools': const <String>[],
    'requiredSkills': const <String>[],
    'workflow': const <String>[],
    'hint': hint,
  };

  static bool _containsAny(String query, List<String> keywords) =>
      keywords.any((keyword) => query.contains(keyword));
}
