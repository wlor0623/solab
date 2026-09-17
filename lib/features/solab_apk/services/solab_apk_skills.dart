import 'dart:convert';

class SolabApkSkills {
  const SolabApkSkills._();

  static const activationHints = <String, String>{
    'apk_base_analysis': '未细分目标的 APK 分析',
    'apk_reverse_playbook': '逆向、反编译、混淆与代码定位',
    'apk_ad_review': '广告识别、定位与审查',
    'apk_cleanup_review': '安装包精简、体积与资源审查',
    'apk_permission_review': '权限、组件与 Manifest 审查',
    'apk_change_plan': '会员、抓包或其他修改方案设计',
    'apk_apply_patch': '用户明确要求修改、修复或构建',
    'apk_verify_patch': '签名、安装、启动与效果验证',
    'apk_flutter_locate': 'Flutter、Blutter 与 libapp 定位',
    'flutter_vip_unlock': '已确认 Flutter 的会员、订阅或广告任务',
    'apk_crypto_locate': '定位签名、校验、加密或解密实现',
    'apk_patch_migrate': 'App 更新后把旧补丁迁移到新版本',
  };

  static const activationRules = <String, List<String>>{
    'apk_base_analysis': ['先复用当前会话的有效报告，只补缺失分区。', '把报告事实、规则推断和待验证项分开输出。'],
    'apk_reverse_playbook': [
      '先判断目标所在层，再从最有区分力的证据起步，不执行固定流水线。',
      '混淆名称只作线索，以代码、数据流、调用处、常量和真实字节为准。',
    ],
    'apk_ad_review': [
      '把 SDK 初始化、展示触发、远程配置和容器 UI 分开判断。',
      '候选必须收敛到真实代码与调用关系后才可作为修改点。',
    ],
    'apk_cleanup_review': [
      '按安全、待确认和高风险分类，未知二进制与 SO 不自动删除。',
      '精简结论必须说明引用依据和预计收益。',
    ],
    'apk_permission_review': [
      '只按当前报告判断静态风险，未发现调用不等于可以删除。',
      '权限与对应组件、代码引用一起核对。',
    ],
    'apk_change_plan': ['围绕用户目标列出证据、最小变更、风险和验证方式。', '目标明确时不重复提问；分析任务不越权进入写入。'],
    'apk_apply_patch': [
      '从当前会话续接快照继续，已有定位符就直接验证，不重跑全量分析。',
      '除非用户要求跳过或工作台设为不开启，首次业务写入前先对原包单独处理；后续沿去签产物链继续。',
      '只写入已验证的最小目标；生成签名成品后等待用户安装验证。',
    ],
    'apk_verify_patch': [
      '验证安装、启动和目标行为，工具成功不等于用户效果已验证。',
      '用户确认后才合并当前 APP 的唯一记忆；成功时再清理中间产物。',
    ],
    'apk_flutter_locate': [
      '优先复用已有 Blutter 索引和专项报告，禁止重复分析同一 APK。',
      '先识别真实业务体系，再用字符串、数值、字段数据流和调用处定位。',
    ],
    'flutter_vip_unlock': [
      '先判定 Dart、DEX、SO 或资源层，任何证据路线都可独立起步和组合。',
      '等级值由当前 APP 的数值与数据流证明，禁止照搬其他 APP 的映射。',
      '补丁后在当前交付文件验证真实字节，不使用 Blutter 缓存验收。',
    ],

    'apk_crypto_locate': [
      '先 so_analyze(action=crypto_scan) 拿加密常量与导入符号画像，再决定 DEX/SO 哪层承载算法。',
      'so_analyze(action=jni_bridge) 的 classes 与 DEX native 声明求交集，桥接点优先于盲目搜索。',
      '命中 AES/TEA 常量后用 trace 收口 Key/IV 数据流；无明文证据不改字节。',
      'pointycastle、Conscrypt 等通用库命中只作背景，consumerExclude 可过滤 trace 噪声。',
    ],
    'apk_patch_migrate': [
      '新旧包都完成 analyze 后调用 blutterAction=diff，compareToJobId=新包 jobId。',
      'similarity=1 直接替换旧 locator 的 va 复用补丁参数；0.45~0.8 必须重新 disasm 验证分支。',
      '迁移完成后按既有契约走 dryRun 预览与 applyAfterPreview 执行，旧对话不读取长期记忆替代现场报告。',
    ],
  };

  static const skillNames = <String>[
    'apk_base_analysis',
    'apk_reverse_playbook',
    'apk_ad_review',
    'apk_cleanup_review',
    'apk_permission_review',
    'apk_change_plan',
    'apk_apply_patch',
    'apk_verify_patch',
    'apk_flutter_locate',
    'flutter_vip_unlock',
    'apk_crypto_locate',
    'apk_patch_migrate',
  ];

  static Map<String, dynamic>? activation(String skill) {
    if (!skillNames.contains(skill)) return null;
    final payload = jsonDecode(read(skill)) as Map<String, dynamic>;
    return <String, dynamic>{
      'id': skill,
      'name': payload['name'],
      'trigger': activationHints[skill],
      'rules': activationRules[skill] ?? const <String>[],
      'fullSkillTool': 'get_solab_skill(skill=$skill)',
    };
  }

  static String read(String skill) {
    final payload = switch (skill) {
      'apk_base_analysis' => {
        'name': 'APK 基础分析',
        'requiredReportSections': ['summary', 'components', 'permissions'],
        'steps': [
          '读取当前 APK 报告的摘要、组件和权限。',
          '区分报告事实、规则推断和待验证项。',
          '列出包信息、签名、导出组件、高风险权限、DEX、资源、SO、ABI。',
        ],
        'output': ['结论', '关键证据', '风险', '下一步'],
      },
      'apk_reverse_playbook' => {
        'name': '逆向工程核心思路与规则集',
        'source': '逆向工程核心思路与正则规则集.md',
        'workflow': [
          'APK 是 ZIP 容器。先看 Manifest、lib、assets、DEX、resources.arsc，再决定修改方式。',
          '分析、签名兼容、最小修改、签名和安装验证都可单独执行；除非用户要求跳过或工作台设为不开启，首次业务修改前在原包上单独生成去签产物，后续修改只使用该产物。只有编辑过解码目录、资源或 Manifest 时才重打包，直接 DEX 补丁无需重打包。源 APK 不覆盖。',
          '有壳先停止结构修改并要求脱壳后的 APK；脱壳不等于反编译。',
          '静态修改前，优先用界面文字、资源 ID、布局、抓包字段、日志和交叉引用定位证据。',
        ],
        'terms': {
          'manifest': '组件、权限、入口和导出状态；删除组件前必须确认代码不再引用。',
          'dex_smali': '只改报告命中的最小方法集；void 置空、布尔值置真/假、long 时间值受当前原生补丁能力约束。',
          'assets_res': 'assets 可检查配置和 H5 资源；未知 proto/pb/bin 与 SO 只标记复核。',
          'native_lib':
              'lib/*.so 用于壳和引擎识别；SO 指令修改必须先由 so_analyze 闭合函数、调用链和栈平衡证据，再通过 so_patch_into_apk 写回。',
          'signing': '改包后必须重新签名；安装或启动失败先检查签名、壳和组件引用。',
        },
        'engineSignals': {
          'Flutter': ['assets/flutter_assets/', 'libflutter.so', 'libapp.so'],
          'React Native': ['assets/index.android.bundle'],
          'H5': ['assets/www/', 'html/js/css'],
          'Unity IL2CPP': ['libil2cpp.so', 'global-metadata.dat'],
          'Unity Mono': ['assets/bin/Data/Managed/', '.dll'],
          'Cocos': ['assets/src/', '.jsc', 'libcocos2djs.so'],
          'Xamarin': ['libmonodroid.so', '.dll'],
        },
        'ruleMapping': {
          '广告': [
            'sdk_packages',
            'method_patterns',
            'ad_key_strings',
            'ad_asset_files',
          ],
          '会员': ['force_true_methods'],
          '时间': ['time_methods'],
          '设备检测': [
            'detection_vpn',
            'detection_emulator',
            'detection_root',
            'detection_debug',
          ],
          '加固壳': ['shell_signatures'],
        },
        'guardrails': [
          '规则命中只是候选，不等于可直接修改；必须先 dryRun 预览，用户已明确目标时直接执行。',
          '笔记中的 Smali 正则已按语义归入规则库；当前自动补丁不执行原始正则文本。',
          '网络协议、支付、签名算法、Native 指令和服务端状态没有本地证据时只给定位线索，不编造结论。',
        ],
      },
      'apk_ad_review' => {
        'name': '广告规则审查',
        'requiredReportSections': ['summary', 'ads', 'components'],
        'steps': [
          '读取广告规则命中和相关组件；Flutter 先 report(ads)，没有专项报告才 locate(goal=定位广告展示开关)。',
          '把广告线索分成 SDK 初始化、展示触发、远程配置和容器 UI 四组，按 SDK、类、URL 和中英文关键词分别说明依据。',
          '展示触发候选必须同时满足体系 clear、返回类型 bool/void、调用链确属业务展示；初始化、远程配置和容器 UI 单独命中只算线索。',
          '没有命中时明确“未命中规则，不等于没有广告”。',
          '只生成候选修改，不执行。',
        ],
        'output': ['命中', '可信度', '候选变更', '验证方式'],
      },
      'apk_cleanup_review' => {
        'name': '安装包精简审查',
        'requiredReportSections': ['summary', 'files'],
        'steps': [
          '读取最大文件、SO、候选文件和文件类型统计。',
          '空文件可标记安全；proto、pb、bin 仅标记复核；SO 一律高风险。',
          '按安全、待确认和高风险三组输出。',
        ],
        'output': ['预计收益', '安全候选', '待确认项', '禁止自动删除项'],
      },
      'apk_permission_review' => {
        'name': '权限审查',
        'requiredReportSections': ['summary', 'permissions', 'components'],
        'steps': [
          '读取权限、高风险权限和导出组件。',
          '只基于报告判断静态风险，不把未发现调用等同于可删除。',
          '将权限分为保留、待确认和可随已移除组件清理。',
        ],
        'output': ['权限清单', '风险来源', '待确认项', '修改前提'],
      },
      'apk_change_plan' => {
        'name': 'APK 修改计划',
        'requiredReportSections': ['summary', 'ads', 'files', 'permissions'],
        'steps': [
          '读取用户已给出的目标；只有目标不明确或方案存在实质取舍时才提问。',
          '读取与目标有关的报告分区和规则命中。',
          '除非用户要求跳过或工作台设为不开启，首次业务写入前先对未改原 APK 单独执行去签：用户指定模式时严格使用，未指定时跟随 APK 工作台设置。后续补丁只接该步骤返回的产物。',
          '逐项列出修改目标、依据、影响、回滚点和验证方式。',
          '用户已明确要求修改当前 APK 时直接进入支持预览的执行工具，不重复索要确认。',
        ],
        'output': ['目标', '变更集', '风险', '确认项', '验证'],
      },
      'apk_apply_patch' => {
        'name': 'APK 修改执行',
        'requiredReportSections': ['summary', 'ads'],
        'steps': [
          '先 get_current_apk_report 读 decision，确认目标范围与脱壳状态（有壳先确认脱壳）。',
          'route_task 返回的是候选证据路线，不是固定调用链。已有 qualifiedId、VA、字段 locator、字符串引用或对照产物时可从任意对应工具直接开始；只有新信息会改变判断时才读取世界书、用户 Skill 或运行时指南。',
          '调用前以当前 tools/list 和工具 schema 为准；工具不存在时查可用工具入口或改走当前已声明工具，禁止使用历史工具名、猜参数或猜路径。',
          '同一源 APK 只使用一个以 App 名称命名的工作区；所有 outputPath、nextInputPath、qualifiedId、VA 和 previewToken 原样传到下一步。',
          '除非用户要求跳过或工作台设为不开启，首次业务写入前先用独立的 signature_bypass 工具对未改原 APK 单独执行：用户指定 mode 时严格使用，未指定时跟随 APK 工作台设置。dpatch 和 original_apk 都必须拿返回的 outputPath 继续，禁止直接修改原包；后续步骤显式保持 signatureBypass=false。禁止在已修改 APK 上补做或重复去签。安装闪退时保留原包，从原包换另一模式重新生成产物后再测。',
          '单点修复优先：分清入口（adEntryMethodMatches，init*/register*/manager*）与调用点（adMethodMatches）。'
              '每类功能只改最上游的一个入口，禁止一次性提交几十个方法。',
          '打击优先级（按目标类型选已验证单点，禁止散弹逐点打）：'
              '广告→先区分 SDK 初始化、展示触发、远程配置和容器 UI；默认选择 shouldShowAd/canShowAd 等本地 bool 闸门或 show/play 等 void 展示触发。'
              'initSdk/initAd 只有在调用链证明它是唯一上游入口且跳过后不会留下占位或崩溃时才修改，不能把“初始化停止”直接等同于“广告展示关闭”；'
              '会员→最内层纯 bool/int 判定函数优先（force true），外层 getter 链不动；'
              '到期/限免→时间计算或次数计数源头（拉远期/置大值）；'
              '校验/签名/完整性→除非用户要求跳过或工作台设为不开启，首次业务写入前先用独立 signature_bypass 工具对未改原包执行：用户指定模式优先，未指定时跟随 APK 工作台设置；后续补丁不再混入签名注入；'
              'dpatch 和 original_apk 都会生成独立产物，后续只使用该 outputPath；'
              '反调试/反篡改→检测函数返回值翻转或入口置空。',
          '修改路径是可组合选项而非固定升级链：方法返回、字段读写、上游入口、调用处分支、Dart 判定和原生加载均可独立验证。按当前证据选择改动最小且副作用可解释的一项；同一参数失败后换观察维度，不原地重试。',
          '用户已授权精确修改时，支持的工具用 dryRun=true+applyAfterPreview=true 一次完成预览与写入；纯 dryRun 必须原样执行返回的 applyArguments，禁止忘记写入或重复预览。warning、无变更和目标不符会阻断自动执行。',
          'Agent 模式的所有提问必须调用 ask_user_input_v0，禁止用普通文字代替；MCP 调用方未提供提问工具时可用文字确认。',
          '每完成一个阶段汇报结果并继续下一步，不逐步等待指示。',
          '调用次数不设硬上限；阶段 token 额度只作软提示，约80K可见证据文本是防失控硬上限。每次调用必须能改变候选排序、证据等级或补丁手法；否则按已有证据收口。只有 hasMore/nextOffset 且下一页会改变判断时才翻页。',
          '修改过程不写长期记忆。apk_sign 生成成品后先用 save_apk_patch_memory 预存待验证草案（不入长期记忆），交付成品后 Agent 立即调用 ask_user_input_v0 询问安装是否有效；MCP 无提问工具时用文字询问。验证通过就停，不继续加改。',
          '报告未命中但用户指认功能时：引导提供定位线索（界面文字/抓包字段/日志 TAG），'
              '再用字符串、字段读写、调用链和反汇编证据交叉确认修改位置（先验证后修改）。',
          '直接 DEX 补丁完成后，用 apk_sign 工具内置签名（v1/v2/v3）后再安装；只有解码目录、资源或 Manifest 已编辑时才 apk_rebuild。',
        ],
        'output': ['选中的工具', '预览命中', '确认记录', '产物路径', '下一步'],
      },
      'apk_verify_patch' => {
        'name': 'APK 修改验证',
        'requiredReportSections': ['summary'],
        'steps': [
          '让用户先安装签名包（内置 apk_sign 签名后）并启动，观察是否正常进入首页。',
          '按修改目标逐项验证：广告入口、会员状态、VPN/模拟器行为、组件跳转。',
          '出现闪退时核对签名状态（v1/v2）、壳状态、被删组件是否仍被引用。',
          '结论区分已生效、未生效（可能服务端校验）、回归风险三档。',
          '用户反馈已签名安装包有效或无效时，立即调用 record_apk_patch_verification 记录 outcome 和最小验证结果；未安装、dryRun 和工具成功返回都不能记录为已验证。',
          '用户确认安装有效后，record_apk_patch_verification 会在保存长期记忆后自动清理工作目录，仅保留原包和最终签名成品；用户反馈无效时保留现场继续修复。',
        ],
        'output': ['验证项', '结果', '回归风险', '下一步'],
      },
      'apk_flutter_locate' => {
        'name': 'Flutter 目标体系定位',
        'applicability':
            '报告确认 flutterApp.detected=true，且需要定位会员、订阅、广告、抓包或其他 Dart 业务状态。',
        'steps': [
          '先读取当前工作区已有的 Blutter 专项 report；只有 REPORT_NOT_READY 才 locate，没有可复用的 succeeded job 才 analyze。禁止重复分析同一 APK。',
          '先对 pp.txt 做一次中英文词族普查并统计命中，不从一个词直接定案。会员至少区分 bool 状态、等级、Pro/买断、订阅、到期永久和 UI/支付文案；广告区分 SDK 初始化、展示触发、远程配置和容器 UI。',
          '根据命中组合确定当前 App 的真实体系，再只对该体系的字符串或对象池偏移做 xref/callers；UI 与支付文案只作线索。',
          '用户给出 5/55 等数值时用 values/汇编立即数查询，同时匹配十进制、十六进制和对象池 int。不得把 ldr/str 字段偏移或 List<T>(N) 长度当等级。',
          '优先定位真实状态读写或判定函数。函数体或字段数据流直接表达目标行为时可单点定案；否则从词族、引用链、函数形态、返回语义、常量或用户给出的产物中选择两个独立来源交叉确认。',
          '只读取摘要、目标函数和一次必要分页；禁止把 pp.txt、asm 或 500 条结果从头到尾喂给模型。',
        ],
        'output': ['体系分类', '命中统计', '目标函数与 VA', '数值证据', '下一步工具'],
        'guardrails': [
          '字符串搜索不到数字常量是搜索维度限制，不代表数值不存在',
          '单个 getter、展示类或支付文案命中不能直接作为补丁目标',
          '每个 App 的等级值不同，禁止沿用其他 App 的 5、10、55 等映射',
        ],
      },
      // Flutter 会员解锁/去广告通用方法论：只固化思维顺序，不固化任何具体
      // 地址/等级值/关键词命中——每个 App 的等级体系、混淆方式、SDK 接入
      // 都不同，参数一律由现场证据决定（先定位后修改，禁止猜测）。
      'flutter_vip_unlock' => {
        'name': 'Flutter 会员解锁 / 去广告',
        'applicability':
            '报告 flutterApp.detected=true 且目标属于「会员权益/等级/订阅/广告」类。'
            '非 Flutter 包走 apk_apply_patch；Flutter 包但目标在原生层（广告 SDK/下载/权限）也走 dex 工具链。',
        'steps': [
          '0 自由编排：以下分层、Dart、DEX、数值、调用链和对照产物都是可独立使用的证据探针，不是必须按编号执行的流水线。已有精确定位符就直接验证；一条直接行为证据足够时停止，只有间接线索时才组合第二条独立路线。',
          // 第一步永远判定目标属层，位置不固定
          '1 分层判定（每个 App 都不同，先定位）：读报告 flutterApp.dualTrackRouting。'
              '会员/VIP/等级/订阅/播放器行为等业务判定 → Dart 业务层（libapp.so，走 Blutter）；'
              '广告 SDK 初始化/加载、下载、权限、系统调用 → 原生层（dex+assets+Manifest，走 methods/fields/dex_search）。'
              '同一任务可能同时跨两层（解锁会员走 Dart 层 + 去广告走原生层），分别定位。',
          // 轨道 A：Dart 层——关键词是词族不是固定清单，命中不了要换词
          '2a Dart 层定位（Blutter）：先 blutterAction=report(report=membership/capture/ads) 复用上次 locate 保存的专项报告；'
              '只有 REPORT_NOT_READY 或 RESULT_NOT_FOUND 才 blutterAction=analyze（path 传 APK 或含 '
              'libapp.so+libflutter.so 的目录，禁止传裸 .so）异步返回 jobId，'
              '用 status+wait=true 等到 succeeded（超时按 hint 续等，不手动高频轮询）；'
              '已有 succeeded 的 jobId 直接 locate，不重复 analyze；locate 默认返回紧凑证据并保存专项报告，禁止读取长结果分页；'
              '产物由工具按需消费：result 摘要读 result.json，result(kind) 分页读 libraries/classes/functions/objects 索引，search 读 pp.txt/asm，xref/locate/values/trace 自动使用语义、对象池、字段访问与 ARM64 函数索引，disasm/callers 读 asm；禁止把整份文件喂给模型。'
              '搜索同类词时用 | 合并为一次 search（例如 isVip|isMember|vipLevel）；ASM 默认走语义索引，只有索引未命中且确需非语义原始行时才 fullScan=true。全扫默认跳过常见第三方包，并用 includePath/excludePath 收窄到目标类或模块；只有目标明确位于依赖库时才 includeThirdParty=true。禁止逐词重复扫整个 ASM 目录。'
              'FLUTTER_VERSION_NOT_SUPPORTED 或分析失败时，立即用 blutterAction=raw_strings(path, goal) '
              '直接扫描 libapp.so 原始中英文字符串保留证据；只有目标本来就在原生层时才转 dex。'
              'blutter locate 先对 pp.txt 做一次中英文特征普查，不拿单个词直接定案。会员域同时统计：'
              '布尔状态（isVip/isMember/是否会员）、等级类型（vipType/memberLevel/至尊/钻石）、'
              'Pro/付费解锁（isPro/fullVersion/专业版/完整版）、订阅购买（subscription/productId/订阅/续费）、'
              '到期永久（expiresAt/lifetime/到期/永久）以及 UI 展示词。抓包域同时统计代理/VPN、TLS Pinning、'
              '证书信任链和网络栈中英文词；广告域把 SDK 初始化、展示触发、远程配置和容器 UI 分开统计。'
              '先读 intentProfile 的命中数、样本与 classificationStatus，明确该 App 实际采用的体系；'
              '体系有歧义就交叉比较前两类，UI/支付文案单独命中不得作为修改点。体系确定后，'
              '只对该体系命中的池偏移做 xref；字段键只出现在解析器、真实判断函数已混淆或分离时，立即用 trace 从键引用追到字段写入和读取。优先验证 sliceConfidence=high 且 decisionEvidence 进入比较/条件分支的候选；low 只证明偏移相同，不能作为结论。',
          // 等级语义必须由证据反推，禁止假设；直接证据可单点定案，
          // 间接线索才需要两个来源交叉。
          '2b 数值与字段语义确认（多信号交叉）：locate 读取 observedValues/valueEvidence；用户给出任意已知业务值时，'
              '立即调用 blutterAction=values(query=用户给出的值, goal=当前目标, va=候选VA)，统一匹配原始整数、Dart Smi、对象池整数和 mov/cmp '
              '立即数与对象池整数。ldr/ldur/str/stur 方括号内的 #0x37 是字段或栈偏移，不是等级 55；'
              'List<T>(N) 的 N 只是元素数量，也不是最高等级。每个 App 的等级体系不同，禁止假设「某值=最高等级」。沿调用链追到最内层解码器/判定函数，'
              '若值搜索与名称搜索无法相接，用 blutterAction=trace(poolOffset=字段键偏移, goal=当前目标) 自动建立解析写入→字段偏移→读取→寄存器消费链，再确认比较值、分支方向和返回语义。'
              '若 locate 返回 rawDecisionFlow 高置信候选，说明工具已用当前 libapp 原始字节把展示文案→比较值→调用链→等级返回函数接通；只对第一候选 functionVa 做一次原生 disasm，禁止重新搜词、翻 asm/classes/functions 目录或从不完整函数头开始扫。'
              '候选采用按证据强度判断：函数体或字段数据流直接表达目标行为时可直接定案；否则从 PP 词族、对象池/调用链、数值、函数形态与返回语义中取两个相互独立的来源。规则命中、UI 文案和同名函数仍只算线索。',
          // 补丁规范：先 disasm 读函数体判形态，再选手法
          '2c 补丁（强制规范）：blutterAction=locate 一次拿全后直接 so_analyze(action=edit_open)→so_analyze(action=edit_asm) dryRun，'
              '按函数形态选手法：'
              '纯 bool/int 判定函数→ force_return_constant 无栈桩'
              '（int→mov w0,#N;ret，bool→0/1，对象→返回 null；值>0xFFFF 自动 movz+movk）；'
              '写状态/void 函数（如 _recompute 类，恒返常量会破坏写入逻辑）→ '
              'tbnz/tbz/b.cond 条件分支用 mode=nop_out nop 化，或 mode=replace_instructions '
              'writeAsm="b <目标VA>" 无条件跳转（保留函数其余逻辑）。'
              '只改最内层判定，外层 getter 不动，最小改动面。'
              '禁止手写 prologue/epilogue 改写——引擎以 STACK_IMBALANCE 自动拦截栈破坏，'
              'dryRun 只验证将要写入的字节；执行后必须对当前输出 SO 或签名 APK 中的真实条目做一次 hexdump/原生 disasm 验收。Blutter disasm 是历史分析产物，只能定位，绝不能证明补丁已写入。',
          // 轨道 B：原生层
          '2d 原生层定位：读报告 adSdkMatches/vendorSignals 确认主导厂商；'
              '展示触发函数优先于 SDK 初始化和容器类。把已有的类名、字段名、方法名、字符串、数值或指令序列交给 dex_search(auto)，由工具自行取交集、拆分换路和排序。不要向用户暴露定位路线，也不要把候选当结果；自动执行 nextActions 核验真实代码、调用处与重写实现，直到得到可修改且可回读的结论。dex_xref(includeGraph=true) 返回可画流程图的 nodes/edges。'
              'patch_apk_dex_methods 做最小方法修改，patch_apk_manifest 只按证据清权限或组件。字符串命中'
              '只是线索，必须先收敛成 qualifiedId 才可 patch。',
          // 打包验证沉淀
          '3 打包交付：so_analyze(action=build) 写出已修改 SO → so_patch_into_apk 写回当前 APK（沿用原压缩方式并校验条目）→ '
              'apk_sign 签名（apksigner 内置校验，成功即生效，无需重验）→ 用户装机验证 → '
              'record_apk_patch_verification 记录结果；save_apk_patch_memory 沉淀时 pitfall 填易错点'
              '（如本次的等级语义确认依据、踩过的坑，以及改了会崩/触发检测/功能异常的负例点，'
              '负例下次自动避开或降权）。'
              '信任边界：edit_asm/so_patch_into_apk/apk_sign 返回 ok 只证明该工具步骤成功；最终补丁点需在当前交付文件上验一次真实字节，禁止用 Blutter 缓存验收，也禁止对同一结果反复复验。'
              '增量改动只重跑受影响的单一工具（改了 so 就 so_patch_into_apk+sign，不重跑 dex/分析链），'
              '唯一人工验证点是装机。',
          // 目标降级链：VIP 搞不定时的本地等效路径，不轻易说做不到
          '4 本地等效路径（按证据选择，可单独或组合）：VIP 判定可能被服务端校验时，评估下列本地目标：'
              'a) 激励视频奖励直接发放（定位奖励回调，跳过播视频直接回调成功）；'
              'b) 试用/限免次数计数器置大或清零重置（fields 找次数字段及其消费点）；'
              'c) 时间劫持拉长有效期（timeMethods 返回远期）；'
              'd) 掐断初始化/连接处（init/register 入口置空整类禁用，load/show 逐点拆）。'
              '只验证与当前产物有证据关联的路径；没有本地消费点时如实汇报服务端限制，不为凑流程穷举。',
        ],
        'guardrails': [
          '修改位置因厂商/SDK 版本/混淆而异，不固定：先定位后修改，位置由证据决定，禁止猜测或沿用其他 App 的地址/方法名',
          'DEX 搜不到只是否定当前搜索维度，不是否定目标。根据 APK 结构自由切换 Blutter、字段数据流、资源引用或原生 SO；若用户产物已给出另一层定位符，直接验证该定位符',
          '恒返回常量必须走 force_return_constant，禁止裸 hex 改栈帧（STACK_IMBALANCE 会拦截）',
          '只改最内层，外层 getter 不动；有正常版对照包先做哈希+字节 diff 快速定位差异',
          '会员权益可能是服务端下发：本地补丁后仍不生效时如实告知「可能存在服务端校验」，不编造成功',
          '正面打不穿就换侧面：试完奖励直发/试用次数/时间劫持/掐断初始化等本地等效路径之前，不下「做不到」结论',
        ],
        'output': [
          '分层判定结论',
          '定位证据（工具返回的函数/VA/qualifiedId）',
          '补丁与验证结果',
          '易错点沉淀',
        ],
      },
      'apk_crypto_locate' => {
        'name': '加密与签名定位',
        'steps': [
          '先用 so_analyze(action=crypto_scan) 获取加密常量、导入符号和可信命中。',
          '用 so_analyze(action=jni_bridge) 与 DEX native 声明交叉定位 JNI 桥接点。',
          '对候选只追踪当前 APK 的 Key、IV、算法选择和调用方；通用库命中不作为修改结论。',
        ],
        'output': ['算法证据', 'JNI/DEX 位置', '调用关系', '下一步'],
      },
      'apk_patch_migrate' => {
        'name': '补丁迁移',
        'steps': [
          '分别确认新旧 APK 的文件身份与已完成的 Blutter 任务。',
          '调用 blutterAction=diff 映射旧定位符到新版本 VA。',
          '只复用 similarity=1 的映射；其余候选重新读取当前函数体后再预览。',
        ],
        'output': ['版本映射', '可复用定位符', '需复核项', '迁移结果'],
      },
      _ => {'error': 'unknown_skill', 'availableSkills': skillNames},
    };
    if (payload['error'] == null) {
      payload['id'] = skill;
      payload['activation'] = {
        'mode': 'task_router',
        'status': 'active',
        'trigger': activationHints[skill],
        'rules': activationRules[skill] ?? const <String>[],
      };
    }
    return jsonEncode(payload);
  }
}
