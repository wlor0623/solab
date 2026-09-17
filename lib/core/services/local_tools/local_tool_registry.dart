import 'local_tool_names.dart';

enum LocalToolTier { tier0, tier1, tier2, tier3 }

class LocalToolSpec {
  const LocalToolSpec({
    required this.name,
    required this.title,
    required this.subtitle,
    this.tiers = const <LocalToolTier>{},
    this.tracks = const <String>{},
    this.mcpExposed = false,
    this.mcpOrder,
    this.readOnly = false,
    this.marksCompletion = false,
    this.deviceGated = false,
  });

  final String name;
  final String title;
  final String subtitle;
  final Set<LocalToolTier> tiers;
  final Set<String> tracks;
  final bool mcpExposed;
  final int? mcpOrder;
  final bool readOnly;
  final bool marksCompletion;
  final bool deviceGated;
}

abstract final class LocalToolRegistry {
  static const flutterVip = 'flutterVip';
  static const dexNative = 'dexNative';
  static const soAnalysis = 'soAnalysis';
  static const fileOps = 'fileOps';

  static const List<LocalToolSpec> specs = <LocalToolSpec>[
    LocalToolSpec(
      name: LocalToolNames.timeInfo,
      title: '时间信息',
      subtitle: '获取当前时间',
    ),
    LocalToolSpec(
      name: LocalToolNames.clipboard,
      title: '剪贴板',
      subtitle: '读取/写入剪贴板',
    ),
    LocalToolSpec(
      name: LocalToolNames.textToSpeech,
      title: '朗读',
      subtitle: '用 TTS 朗读文本',
    ),
    LocalToolSpec(
      name: LocalToolNames.askUser,
      title: '询问用户',
      subtitle: '向用户提问以澄清需求',
      tiers: {LocalToolTier.tier0},
    ),
    LocalToolSpec(
      name: LocalToolNames.calculate,
      title: '计算器',
      subtitle: '表达式求值',
    ),
    LocalToolSpec(
      name: LocalToolNames.screenTime,
      title: '屏幕使用时长',
      subtitle: '按时间范围查询 App 使用统计',
      deviceGated: true,
    ),
    LocalToolSpec(
      name: LocalToolNames.calendarQuery,
      title: '日历查询',
      subtitle: '查询设备日历事件',
      deviceGated: true,
    ),
    LocalToolSpec(
      name: LocalToolNames.calendarCreate,
      title: '日历创建',
      subtitle: '创建日历事件（需确认）',
      deviceGated: true,
    ),
    LocalToolSpec(
      name: LocalToolNames.apkReport,
      title: '读取当前 APK 报告',
      subtitle: '按需读取工作台保存的本地分析结果',
      tiers: {LocalToolTier.tier1},
      mcpExposed: true,
      mcpOrder: 1,
      readOnly: true,
    ),
    LocalToolSpec(
      name: LocalToolNames.apkSkill,
      title: 'SoLab Skill',
      subtitle: '读取内置分析、规则审查和修改计划流程',
      tiers: {LocalToolTier.tier1},
    ),
    LocalToolSpec(
      name: LocalToolNames.apkKnowledge,
      title: 'APK 知识',
      subtitle: '按路由主题读取已启用的知识条目',
      tiers: {LocalToolTier.tier1},
    ),
    LocalToolSpec(
      name: LocalToolNames.installedSkills,
      title: '已安装技能',
      subtitle: '读取用户安装的补充说明技能',
      tiers: {LocalToolTier.tier1},
    ),
    LocalToolSpec(
      name: LocalToolNames.agentRuntimeGuide,
      title: '运行时能力清单',
      subtitle: '确认本次启用的注入、记忆、世界书与工具',
      tiers: {LocalToolTier.tier0},
    ),
    LocalToolSpec(
      name: LocalToolNames.apkProjectInfo,
      title: 'APK 项目信息',
      subtitle: '报告源 APK 与工作区绑定 APK 的一致性核对',
      tiers: {LocalToolTier.tier0},
    ),
    LocalToolSpec(
      name: LocalToolNames.apkRules,
      title: '规则库',
      subtitle: '列出 APK 特征规则',
      tiers: {LocalToolTier.tier1},
    ),
    LocalToolSpec(
      name: LocalToolNames.apkPatchDex,
      title: 'DEX 修改',
      subtitle: '方法置空/翻转/时间戳等（需预览+确认）',
      tiers: {LocalToolTier.tier2},
      tracks: {flutterVip, dexNative},
      mcpExposed: true,
      mcpOrder: 11,
      marksCompletion: true,
    ),
    LocalToolSpec(
      name: LocalToolNames.apkSignatureBypass,
      title: '去签名校验',
      subtitle: '独立签名兼容注入（普通/原包模式）',
      tiers: {LocalToolTier.tier2},
      tracks: {flutterVip, dexNative},
      mcpExposed: true,
      mcpOrder: 10,
      marksCompletion: false,
    ),
    LocalToolSpec(
      name: LocalToolNames.apkPatchManifest,
      title: 'Manifest 修改',
      subtitle: '权限清理与组件调整（需预览+确认）',
      tiers: {LocalToolTier.tier2},
      tracks: {flutterVip, dexNative},
      mcpExposed: true,
      mcpOrder: 12,
      marksCompletion: true,
    ),
    LocalToolSpec(
      name: LocalToolNames.apkToolMap,
      title: '工具总表',
      subtitle: '全部本地 APK 工具的能力与触发信号',
      tiers: {LocalToolTier.tier0},
      mcpExposed: true,
      mcpOrder: 3,
      readOnly: true,
    ),
    LocalToolSpec(
      name: LocalToolNames.apkPatchMemory,
      title: '补丁经验检索',
      subtitle: '按厂商+壳+引擎指纹匹配历史经验',
      tiers: {LocalToolTier.tier1},
      // MCP 面也暴露（只读）：真机实测发现外部 Agent 无法按文件指纹
      // 识别「已是验证成品的基线包」，导致从原始包重做。lookupArtifactPath
      // 反查走内容 sha256，MCP 调用方同样需要这个入口。
      mcpExposed: true,
      mcpOrder: 21,
      readOnly: true,
    ),
    LocalToolSpec(
      name: LocalToolNames.apkSavePatchMemory,
      title: '补丁经验保存',
      subtitle: '成功后沉淀一句话最小改动',
      tiers: {LocalToolTier.tier3},
    ),
    LocalToolSpec(
      name: LocalToolNames.apkRecordPatchVerification,
      title: '验证结果登记',
      subtitle: '记录安装验证有效/无效',
      tiers: {LocalToolTier.tier3},
    ),
    LocalToolSpec(
      name: LocalToolNames.apkListBuilds,
      title: '产物列表',
      subtitle: '列出已生成中间包',
      tiers: {LocalToolTier.tier0},
    ),
    LocalToolSpec(
      name: LocalToolNames.apkCleanupBuilds,
      title: '产物清理',
      subtitle: '清缓存与无主中间产物（需预览+确认）',
      mcpExposed: true,
      mcpOrder: 18,
      readOnly: false,
    ),
    LocalToolSpec(
      name: LocalToolNames.apkNoteRead,
      title: '补丁笔记读取',
      subtitle: '读取当前会话待验证修改',
      tiers: {LocalToolTier.tier1},
    ),
    LocalToolSpec(
      name: LocalToolNames.apkNoteWrite,
      title: '补丁笔记写入',
      subtitle: '记录修改位置结论',
      tiers: {LocalToolTier.tier3},
    ),
    LocalToolSpec(
      name: LocalToolNames.apkListWorkspace,
      title: '工作区 APK 列表',
      subtitle: '列出工作目录中的 APK',
      tiers: {LocalToolTier.tier0},
    ),
    LocalToolSpec(
      name: LocalToolNames.apkAnalyzeWorkspace,
      title: '工作区 APK 分析',
      subtitle: '自动分析并保存当前报告',
      tiers: {LocalToolTier.tier1},
      mcpExposed: true,
      mcpOrder: 2,
    ),
    LocalToolSpec(
      name: LocalToolNames.apkArchive,
      title: 'APK 文件浏览',
      subtitle: '分页浏览、预览条目和读取签名证书',
      tiers: {LocalToolTier.tier1},
      mcpExposed: true,
      mcpOrder: 19,
      readOnly: true,
    ),
    LocalToolSpec(
      name: LocalToolNames.apkExportReport,
      title: '导出 APK 报告',
      subtitle: '将当前分析报告保存到工作目录',
      tiers: {LocalToolTier.tier1},
      mcpExposed: true,
      mcpOrder: 20,
    ),
    LocalToolSpec(
      name: LocalToolNames.jadxDecompile,
      title: 'Jadx 反编译',
      subtitle: 'DEX→Java 源码',
      tiers: {LocalToolTier.tier2},
      tracks: {flutterVip, dexNative, soAnalysis},
      mcpExposed: true,
      mcpOrder: 8,
      readOnly: true,
    ),
    LocalToolSpec(
      name: LocalToolNames.apkSign,
      title: 'APK 签名',
      subtitle: '内置密钥 v1/v2/v3',
      tiers: {LocalToolTier.tier2, LocalToolTier.tier3},
      tracks: {flutterVip, dexNative, soAnalysis, fileOps},
      mcpExposed: true,
      mcpOrder: 14,
      marksCompletion: true,
    ),
    LocalToolSpec(
      name: LocalToolNames.apkRebuild,
      title: 'APK 回编',
      subtitle: 'APKEditor 完整回编',
      tiers: {LocalToolTier.tier2},
      tracks: {dexNative, soAnalysis, fileOps},
      mcpExposed: true,
      mcpOrder: 13,
      marksCompletion: true,
    ),
    LocalToolSpec(
      name: LocalToolNames.dexSearch,
      title: 'Dex 反查',
      subtitle: 'DexKit 反混淆查找',
      tiers: {LocalToolTier.tier2},
      tracks: {flutterVip, dexNative, soAnalysis},
      mcpExposed: true,
      mcpOrder: 4,
      readOnly: true,
    ),
    LocalToolSpec(
      name: LocalToolNames.stringScan,
      title: '字符串扫描',
      subtitle: '敏感信息',
      tiers: {LocalToolTier.tier2},
      tracks: {flutterVip, dexNative, soAnalysis},
      mcpExposed: true,
      mcpOrder: 9,
      readOnly: true,
    ),
    LocalToolSpec(
      name: LocalToolNames.dexXref,
      title: 'DEX 调用图',
      subtitle: '谁调我/我调谁',
      tiers: {LocalToolTier.tier2},
      tracks: {flutterVip, dexNative, soAnalysis},
      mcpExposed: true,
      mcpOrder: 5,
      readOnly: true,
    ),
    LocalToolSpec(
      name: LocalToolNames.classOutline,
      title: '类大纲',
      subtitle: '混淆类浏览',
      tiers: {LocalToolTier.tier2},
      tracks: {flutterVip, dexNative, soAnalysis},
      mcpExposed: true,
      mcpOrder: 6,
      readOnly: true,
    ),
    LocalToolSpec(
      name: LocalToolNames.smaliRead,
      title: 'Smali 读取',
      subtitle: '按方法读取 smali',
      tiers: {LocalToolTier.tier2},
      tracks: {flutterVip, dexNative, soAnalysis},
      mcpExposed: true,
      mcpOrder: 7,
      readOnly: true,
    ),
    LocalToolSpec(
      name: LocalToolNames.soAnalyze,
      title: 'SO 分析',
      subtitle: 'Rizin/LIEF/Unidbg 引擎',
      tiers: {LocalToolTier.tier2},
      tracks: {flutterVip, soAnalysis},
      mcpExposed: true,
      mcpOrder: 15,
    ),
    LocalToolSpec(
      name: LocalToolNames.soPatchIntoApk,
      title: 'SO 回填',
      subtitle: '补丁产物一键写回 APK',
      tiers: {LocalToolTier.tier2},
      tracks: {flutterVip, soAnalysis},
      mcpExposed: true,
      mcpOrder: 16,
      marksCompletion: true,
    ),
    LocalToolSpec(
      name: LocalToolNames.file,
      title: '文件',
      subtitle: '工作目录文件操作',
      tiers: {LocalToolTier.tier2},
      tracks: {flutterVip, dexNative, soAnalysis, fileOps},
      mcpExposed: true,
      mcpOrder: 17,
    ),
    LocalToolSpec(
      name: LocalToolNames.routeTask,
      title: '任务路由',
      subtitle: '工具/技能/记忆决策',
      tiers: {LocalToolTier.tier0},
      mcpExposed: true,
      mcpOrder: 0,
      readOnly: true,
    ),
  ];

  static final Map<String, ({String title, String subtitle})> uiMetadata =
      Map<String, ({String title, String subtitle})>.unmodifiable({
        for (final spec in specs)
          spec.name: (title: spec.title, subtitle: spec.subtitle),
      });

  static List<String> mcpExposedToolIds() => List<String>.unmodifiable(
    (specs.where((spec) => spec.mcpExposed).toList()
          ..sort((a, b) => a.mcpOrder!.compareTo(b.mcpOrder!)))
        .map((spec) => spec.name),
  );

  static Set<String> readOnlyToolIds() => Set<String>.unmodifiable(
    specs.where((spec) => spec.readOnly).map((spec) => spec.name),
  );

  static Set<String> namesAtTier(LocalToolTier tier, {String? track}) =>
      Set<String>.unmodifiable(
        specs
            .where((spec) => spec.tiers.contains(tier))
            .where((spec) => track == null || spec.tracks.contains(track))
            .map((spec) => spec.name),
      );

  static Set<String> completionToolNames() => Set<String>.unmodifiable(
    specs.where((spec) => spec.marksCompletion).map((spec) => spec.name),
  );
}
