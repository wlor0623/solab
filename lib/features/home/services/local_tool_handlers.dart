part of 'local_tools_service.dart';

/// Platform availability of the device-backed local tools (implemented over
/// a MethodChannel in the Android/iOS host apps).
class DeviceLocalTools {
  const DeviceLocalTools._();

  static const MethodChannel _channel = MethodChannel('app.device_tools');

  static bool get screenTimeSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get calendarSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Whether Android Usage Access (PACKAGE_USAGE_STATS) is granted.
  static Future<bool> hasUsageStatsPermission() async {
    if (!screenTimeSupported) return false;
    try {
      final result = await _channel.invokeMethod<bool>(
        'hasUsageStatsPermission',
      );
      return result == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens the system Usage Access settings page (Android).
  static Future<void> openUsageAccessSettings() async {
    if (!screenTimeSupported) return;
    try {
      await _channel.invokeMethod<void>('openUsageAccessSettings');
    } on MissingPluginException {
      // Unsupported host.
    } on PlatformException {
      // Settings unavailable.
    }
  }

  /// Returns true when calendar full access is already granted.
  /// Uses the native EventKit / Android calendar permission path (not
  /// permission_handler), so it works without iOS PERMISSION_EVENTS macros.
  static Future<bool> hasCalendarPermission() async {
    if (!calendarSupported) return false;
    try {
      final result = await _channel.invokeMethod<bool>('hasCalendarPermission');
      return result == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Requests calendar full access via the native channel.
  /// Returns true only when granted. On iOS, permanently denied / restricted
  /// states open the app Settings page.
  static Future<bool> requestCalendarPermission() async {
    if (!calendarSupported) return false;
    try {
      final result = await _channel.invokeMethod<bool>(
        'requestCalendarPermission',
      );
      return result == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

Future<String> _handleApkProjectInfo(ToolContext context) async {
  final repository = context.chatService?.chatRepositoryOrNull;
  if (repository == null) {
    return jsonEncode({
      'error': 'chat_service_unavailable',
      'message': '聊天服务尚未就绪，请稍后再试。',
    });
  }
  final service = ApkProjectService(repository);
  final report = await _readPatchMemoryReport();
  final activeTarget = await ApkWorkspaceBindingService.activeApkPath();
  final resumeState = await ApkWorkspaceBindingService.taskResumeState();
  if (report == null) {
    if (activeTarget != null && activeTarget.isNotEmpty) {
      return jsonEncode({
        'boundApk': activeTarget,
        'source': 'last_modified',
        'report': null,
        'workflow': _projectWorkflowState(null, resumeState),
        'message':
            '工作台暂无本地分析报告，但存在最近修改的目标（见 boundApk）。可先 analyze_apk_workspace 重建报告，或用 dex_search / dex_xref 获取细节。',
      });
    }
    return jsonEncode({
      'error': 'no_apk_selected',
      'workflow': _projectWorkflowState(null, resumeState),
      'message': '当前没有 APK 项目，请先在 APK 工作台选择 APK 并完成分析。',
    });
  }
  final project = await service.findBySha256(
    (report['sha256'] ?? '').toString(),
  );
  if (project == null) {
    return jsonEncode({
      'error': 'project_not_found',
      'message': '当前报告没有对应的项目记录，请重新在 APK 工作台分析。',
      'sha256': report['sha256'],
    });
  }
  final info = service.projectInfoForAi(project);
  final sourceApk = report['sourceApk'];
  final freshness = await _freshnessWithBoundApk(report, activeTarget);
  return jsonEncode({
    ...info,
    'analysisVersion':
        (report['analysisVersion'] as num?)?.toInt() ?? info['analysisVersion'],
    if (sourceApk is Map) 'reportSourceApk': sourceApk,
    if (activeTarget != null && activeTarget.isNotEmpty)
      'boundApk': activeTarget,
    'reportFreshness': freshness,
    'workflow': _projectWorkflowState(freshness, resumeState),
    ...(await _incrementalBuildContext(activeTarget, sourceApk)),
    'source': 'explicit',
    'consistencyHint':
        '对比 reportSourceApk（报告对应 APK）与 boundApk（当前连续修改目标）：'
        '文件名不一致或报告 sourceApk 缺失时，报告可能对应旧 APK 或当前目标是'
        '另一个 APK，必须先用 analyze_apk_workspace 重新分析当前目标再执行修改。',
  });
}

Map<String, dynamic> _projectWorkflowState(
  Map<String, dynamic>? freshness,
  Map<String, dynamic> resumeState,
) {
  final stale = freshness?['status'] == 'stale';
  final activeArtifact = resumeState['activeArtifact'];
  final waitingVerification =
      activeArtifact is Map &&
      activeArtifact['pendingMemoryStatus'] == 'awaiting_user_verification';
  final stage = freshness == null
      ? 'analysis_required'
      : stale
      ? 'analysis_stale'
      : waitingVerification
      ? 'verification_required'
      : 'analysis_ready';
  return {
    'stage': stage,
    'nextTool': switch (stage) {
      'analysis_required' ||
      'analysis_stale' => LocalToolNames.apkAnalyzeWorkspace,
      'verification_required' => LocalToolNames.askUser,
      _ => LocalToolNames.apkReport,
    },
    'activeApk': resumeState['activeApk'],
    'activeApkExists': resumeState['activeApkExists'] == true,
    'recentCheckpoints': resumeState['recentToolCheckpoints'] ?? const [],
    if (activeArtifact is Map) 'activeArtifact': activeArtifact,
  };
}

Future<String> _handleRouteTask(
  Map<String, dynamic> args,
  ToolContext context,
) async {
  final goal = (args['goal'] ?? '').toString();
  final route = TaskRouter.route(goal);
  final availableTools = context.assistant.localToolIds.toSet();
  final agentContextTools = <String, bool>{
    LocalToolNames.agentRuntimeGuide: availableTools.contains(
      LocalToolNames.agentRuntimeGuide,
    ),
    LocalToolNames.apkKnowledge: availableTools.contains(
      LocalToolNames.apkKnowledge,
    ),
    LocalToolNames.installedSkills: availableTools.contains(
      LocalToolNames.installedSkills,
    ),
    LocalToolNames.apkSkill: availableTools.contains(LocalToolNames.apkSkill),
  };
  final recommended = route['recommendedTools'];
  if (recommended is List) {
    route['recommendedTools'] = recommended
        .map((tool) => tool.toString())
        .where(availableTools.contains)
        .toList(growable: false);
  }
  final requiredSkills = route['requiredSkills'];
  if (requiredSkills is List &&
      agentContextTools[LocalToolNames.apkSkill] != true) {
    route['requiredSkills'] = const <String>[];
  }
  route['modeCapabilities'] = {
    'mode': agentContextTools.values.any((available) => available)
        ? 'agent'
        : 'mcp',
    'agentContextTools': agentContextTools,
    'unavailableAgentExtensions': [
      for (final entry in agentContextTools.entries)
        if (!entry.value) entry.key,
    ],
    'note': '只推荐当前模式真实可调用的工具；MCP 可复用共同分析核心，Agent 额外拥有按需知识、Skill、记忆和交互能力。',
  };
  final membershipTask = RegExp(
    r'会员|权益|vip|svip|premium|member|membership|pro|订阅|subscription|到期|过期|expiry|lifetime',
    caseSensitive: false,
  ).hasMatch(goal);
  if (membershipTask) {
    try {
      final report = await ApkWorkspaceService.readReport();
      final flutter = report?['flutterApp'];
      final detected = flutter is Map ? flutter['detected'] : null;
      if (detected is bool) {
        route['toolTrack'] = detected ? 'flutter_vip' : 'dex_native';
        route['toolTracks'] = detected
            ? ['flutter_vip', 'dex_native']
            : ['dex_native'];
        route['layerHints'] = {
          'primaryLayer': detected ? 'dart' : 'native_dex',
          'availableLayers': detected
              ? ['dart', 'native_dex', 'native_so', 'resources']
              : ['native_dex', 'native_so', 'resources'],
          'evidence': ['report.flutterApp.detected=$detected（当前工作台 APK 实证）'],
          'note': 'primaryLayer 只是优先假设,不排除其他层；可按现有 locator 自由切换或组合。',
        };
        if (detected && agentContextTools[LocalToolNames.apkSkill] == true) {
          final skills = <String>{
            for (final skill
                in (route['requiredSkills'] as List? ?? const <dynamic>[]))
              skill.toString(),
            'apk_flutter_locate',
            'flutter_vip_unlock',
          };
          route['requiredSkills'] = skills.toList(growable: false);
        }
      }
    } catch (_) {}
  }
  if (agentContextTools[LocalToolNames.apkSkill] == true) {
    final activations = <Map<String, dynamic>>[
      for (final skill
          in (route['requiredSkills'] as List? ?? const <dynamic>[]))
        if (SolabApkSkills.activation(skill.toString()) case final activation?)
          activation,
    ];
    if (activations.isNotEmpty) {
      route['activeBuiltInSkills'] = activations;
      route['skillInstruction'] =
          'activeBuiltInSkills 已在本轮生效，直接遵守 rules；只有完整技能正文会改变下一步时才调用 fullSkillTool，禁止重复读取。';
    }
  }
  final topics = (route['knowledgeTopics'] as List? ?? const <dynamic>[])
      .map((topic) => topic.toString())
      .toList(growable: false);
  final installedSkillProvider = context.agentSkillProvider;
  if (installedSkillProvider != null && topics.isNotEmpty) {
    try {
      await installedSkillProvider.initialize();
      final installed = installedSkillProvider.retrieve(
        topics: topics,
        limit: 3,
      );
      if (installed.isNotEmpty) {
        String cap(String text, int max) =>
            text.length <= max ? text : '${text.substring(0, max)}…';
        route['activeInstalledSkills'] = [
          for (final skill in installed)
            {
              'id': skill.id,
              'name': skill.name,
              'topics': skill.topics,
              'content': cap(skill.content, 800),
              'contentTruncated': skill.content.length > 800,
            },
        ];
        route['installedSkillInstruction'] =
            '这些启用且相关的用户 Skill 已在本轮生效；只执行适用部分，事实与权限边界仍以当前工具结果为准。';
      }
    } catch (_) {}
  }
  final worldBookProvider = context.worldBookProvider;
  if (worldBookProvider != null) {
    if (topics.isNotEmpty) {
      try {
        await worldBookProvider.initialize();
        final entries = worldBookProvider.retrieveActiveEntries(
          assistantId: context.assistant.id,
          topics: topics,
          limit: 3,
        );
        if (entries.isNotEmpty) {
          String cap(String text, int max) =>
              text.length <= max ? text : '${text.substring(0, max)}…';
          route['prefetchedKnowledge'] = {
            'top': {
              'entryName': entries.first['entryName'],
              'content': cap(entries.first['content'].toString(), 800),
            },
            'moreEntries': [
              for (final entry in entries.skip(1)) entry['entryName'],
            ],
            'note':
                '最高分条目已直接附上；moreEntries 里的条目按需用 get_apk_knowledge(topics) 读取。',
          };
          ToolSessionState.recordPrefetchedKnowledge(
            _toolSessionKey(context.assistant, context.conversationId),
            entries.first['entryName'].toString(),
          );
        }
      } catch (_) {}
    }
  }
  return jsonEncode(route);
}

Future<String> _handleAgentRuntimeGuide(
  Map<String, dynamic> args,
  Assistant assistant,
  MemoryRepository? memoryRepository,
  WorldBookProvider? worldBookProvider,
  AgentSkillProvider? agentSkillProvider,
  InstructionInjectionProvider? instructionInjectionProvider,
) async {
  final runtimeToolNames = _runtimeToolNames(args, assistant);
  Future<bool> initialize(Future<void> Function()? action) async {
    if (action == null) return false;
    try {
      await action();
      return true;
    } catch (_) {
      return false;
    }
  }

  final readiness = await Future.wait<bool>([
    initialize(worldBookProvider?.initialize),
    initialize(agentSkillProvider?.initialize),
    initialize(instructionInjectionProvider?.initialize),
  ]);
  final activeBookIds =
      worldBookProvider?.activeBookIdsFor(assistant.id).toSet() ??
      const <String>{};
  final activeBooks =
      worldBookProvider?.books
          .where((book) => book.enabled && activeBookIds.contains(book.id))
          .map((book) => book.name)
          .toList(growable: false) ??
      const <String>[];
  final injections =
      instructionInjectionProvider
          ?.activesFor(assistant.id)
          .map(
            (injection) => {
              'title': injection.title,
              if (injection.group.isNotEmpty) 'group': injection.group,
            },
          )
          .toList(growable: false) ??
      const <Map<String, String>>[];
  final installedSkillCount =
      agentSkillProvider?.skills.where((skill) => skill.enabled).length ?? 0;
  final activeBookEntries =
      worldBookProvider?.books
          .where((book) => book.enabled && activeBookIds.contains(book.id))
          .expand((book) => book.entries)
          .where((entry) => entry.enabled && entry.content.trim().isNotEmpty)
          .length ??
      0;
  final injectionPromptChars =
      instructionInjectionProvider
          ?.activesFor(assistant.id)
          .fold<int>(0, (sum, item) => sum + item.prompt.trim().length) ??
      0;

  return jsonEncode(
    {
      'automatic': {
        'instructionInjections': {
          'active': injections,
          'when': '应用在每次请求的 system 提示末尾自动追加；不要再次索取完整文本。',
        },
        'memory': {
          'enabled': assistant.enableMemory,
          'autoOrganize': assistant.autoOrganizeMemory,
          'repositoryAvailable': memoryRepository != null,
          'promptMode': 'system_rules_plus_on_demand_index',
          'memoryContentAutoInjected': false,
          'tools': [
            'memory_read',
            'memory_update',
            'memory_search_profile',
            'memory_edit',
            'memory_delete',
            'update_user_profile',
          ],
          'when': '按任务相关性读取；只保存用户确认的稳定偏好和工作流。',
        },
        'pastConversationRecall': {
          'enabled': assistant.allowPastConversationRecall,
          'tool': 'chat_search',
          'when': '需要历史对话证据时按需检索，不把历史摘要当成当前 APK 事实。',
        },
        'customFeatures': {'when': '规则仅在当前报告出现对应命中、或下一步确实依赖规则时读取；不要为每个任务重复读取。'},
        'patchNotes': {
          'when': '写操作成功后自动记录当前 APK 的修改笔记；任务开始时用 apk_note_read 防止重复修改。',
        },
      },
      'onDemand': {
        'worldBooks': {
          'active': activeBooks,
          'tool': '仅在知识书会改变下一步时，按 route 的 topics 读取少量条目。',
        },
        'installedSkills': {
          'enabledCount': installedSkillCount,
          'tool': '仅在启用的用户 Skill 与当前任务相关时读取。',
        },
        'builtInSkills': {'仅在当前任务需要额外操作步骤时读取指定 Skill。'},
        'patchExperience': {'同类补丁已有验证经验时才读取；安装验证后再记录结果。'},
        'toolSelection': {'tool': '不确定下一步时才重新读取 route_task。'},
      },
      'contextReadiness': {
        'worldBooks': {
          'providerAvailable': worldBookProvider != null,
          'loaded': readiness[0],
          'activeBookCount': activeBooks.length,
          'activeEntryCount': activeBookEntries,
        },
        'installedSkills': {
          'providerAvailable': agentSkillProvider != null,
          'loaded': readiness[1],
          'enabledCount': installedSkillCount,
        },
        'instructionInjections': {
          'providerAvailable': instructionInjectionProvider != null,
          'loaded': readiness[2],
          'activeCount': injections.length,
          'promptChars': injectionPromptChars,
        },
        'memory': {
          'repositoryAvailable': memoryRepository != null,
          'enabled': assistant.enableMemory,
        },
      },
      'requiredOrder': [
        '先读取当前报告；缺失、过期或显式切换 APK 时才分析。',
        '只调用能直接减少当前不确定性的定位工具；相同参数失败后不重试。',
        '优先续接当前会话快照；精确目标已授权时用 dryRun=true+applyAfterPreview=true 一次完成，纯预览则原样调用 applyArguments。',
        '直接 DEX 补丁完成后用 apk_sign；只有已编辑解码目录时用 apk_rebuild。',
      ],
      // 工具清单不在运行时指南里重复罗列：本轮 tools/list 已声明全部
      // 工具，再回传 localToolIds 纯属冗余（此前 31 个 id 白占上下文）。
      'availableLocalToolCount': runtimeToolNames.length,
      'availableLocalTools': runtimeToolNames.toList()..sort(),
      'externalMcpTools': {
        'naming': 'mcp__<server>__<tool>',
        'note': '用户外接的 MCP 工具（如 MT）已按此命名合并进本轮工具列表，每轮动态刷新；直接按名称调用即可，无需询问工具是否存在。',
      },
    },
    toEncodable: (value) =>
        value is Set ? value.toList(growable: false) : value.toString(),
  );
}

Future<String> _handleApkKnowledge(
  Map<String, dynamic> args,
  Assistant assistant,
  WorldBookProvider? worldBookProvider, {
  String? conversationId,
}) async {
  if (worldBookProvider == null) {
    return jsonEncode({
      'error': 'world_book_unavailable',
      'message': '知识书尚未就绪，请稍后重试。',
    });
  }
  final rawTopics = args['topics'];
  if (rawTopics is! List) {
    return jsonEncode({
      'error': 'invalid_topics',
      'message': 'topics 必须是 route_apk_task 返回的 knowledgeTopics 数组。',
    });
  }
  final topics = rawTopics
      .map((topic) => topic.toString().trim())
      .where((topic) => topic.isNotEmpty)
      .toList(growable: false);
  if (topics.isEmpty) {
    return jsonEncode({'error': 'invalid_topics', 'message': 'topics 不能为空。'});
  }
  final rawLimit = args['maxEntries'];
  final parsedLimit = rawLimit is num
      ? rawLimit.toInt()
      : int.tryParse(rawLimit?.toString() ?? '');
  final limit = (parsedLimit ?? 3).clamp(1, 5).toInt();
  await worldBookProvider.initialize();
  final prefetched = ToolSessionState.prefetchedKnowledge(
    _toolSessionKey(assistant, conversationId),
  );
  final entries = worldBookProvider
      .retrieveActiveEntries(
        assistantId: assistant.id,
        topics: topics,
        limit: limit + prefetched.length,
      )
      .where((entry) => !prefetched.contains(entry['entryName']))
      .take(limit)
      .toList(growable: false);
  return jsonEncode({
    'topics': topics,
    'returned': entries.length,
    'entries': entries,
    'instruction': entries.isEmpty
        ? '没有命中的已启用知识条目。基于报告继续，不要猜测或读取整本世界书。'
        : '这些条目是当前任务的说明书。把每条内容转成检查项并在报告或工具结果中验证；不要假定未返回的条目已生效。',
  });
}

String _toolSessionKey(Assistant assistant, String? conversationId) =>
    conversationId == null || conversationId.isEmpty
    ? 'assistant:${assistant.id}'
    : 'conversation:$conversationId';

Future<String> _handleInstalledSkills(
  Map<String, dynamic> args,
  AgentSkillProvider? provider,
) async {
  if (provider == null) {
    return jsonEncode({'error': 'skill_store_unavailable'});
  }
  final rawTopics = args['topics'];
  if (rawTopics is! List) {
    return jsonEncode({'error': 'invalid_topics'});
  }
  final topics = rawTopics
      .map((topic) => topic.toString().trim())
      .where((topic) => topic.isNotEmpty)
      .toList(growable: false);
  final rawLimit = args['maxEntries'];
  final parsedLimit = rawLimit is num
      ? rawLimit.toInt()
      : int.tryParse(rawLimit?.toString() ?? '');
  await provider.initialize();
  final skills = provider.retrieve(
    topics: topics,
    limit: (parsedLimit ?? 3).clamp(1, 5).toInt(),
  );
  return jsonEncode({
    'topics': topics,
    'returned': skills.length,
    'skills': skills
        .map(
          (skill) => {
            'id': skill.id,
            'name': skill.name,
            'description': skill.description,
            'version': skill.version,
            'sourceUrl': skill.sourceUrl,
            'topics': skill.topics,
            'content': skill.content,
          },
        )
        .toList(growable: false),
    'instruction': 'Skill 是当前任务的补充步骤。逐条执行适用部分，并以报告、工具结果、预览和用户确认作为最终边界。',
  });
}

/// F5：签名包续改检测——当前连续修改目标（boundApk=activeApkPath）是签名包
/// （源自报告源 APK 的构建链）时标记 incrementalFromSource。目标缺失时改用
/// build 索引里最新签名包（rootSource 匹配报告源）判定。
Future<Map<String, dynamic>> _incrementalBuildContext(
  String? boundApk,
  Object? sourceApk,
) async {
  final reportFile =
      (sourceApk is Map ? sourceApk['fileName']?.toString() : '') ?? '';
  if (reportFile.isEmpty) return const {};
  final builds = await ApkWorkspaceBindingService.readBuilds();
  final noTarget = boundApk == null || boundApk.isEmpty;
  // 定位当前签名包：优先 boundApk 路径匹配，无目标时取最新签名包（kind=build）
  Map<String, dynamic>? current;
  if (!noTarget) {
    for (final b in builds) {
      if (b['output'] == boundApk) {
        current = b;
        break;
      }
    }
  } else {
    for (final b in builds) {
      if (b['kind'] == 'build' || b['signed'] == true) {
        current = b;
        break; // 索引按时间倒序，第一个签名包即最新
      }
    }
  }
  if (current == null) {
    // 无签名包可核对：无当前目标时一致性无法核对（P3 盲区显式化）
    if (noTarget) {
      return {
        'boundApkUnresolved': true,
        'incrementalHint':
            '当前没有连续修改目标（boundApk 缺失），一致性无法按路径核对：'
            '请用 analyze_apk_workspace 重新分析目标 APK 后再执行修改；'
            'build 索引中也无匹配的签名包记录。',
      };
    }
    return const {};
  }
  final source =
      (current['rootSource'] ?? current['source'] ?? current['input'])
          ?.toString() ??
      '';
  final isIncremental = source.isNotEmpty && source.contains(reportFile);
  if (!isIncremental) return const {};
  final targetOutput = current['output']?.toString() ?? boundApk ?? '';
  return {
    'currentTargetIsBuild': true,
    'incrementalFromSource': true,
    if (noTarget) 'boundApkUnresolved': true,
    'incrementalHint':
        '当前目标（$targetOutput）是签名包产物（源自报告源 APK $reportFile 的构建链），SHA 与报告不同属正常。'
        'DEX/方法/字段定位（dex_search、class_outline、dex_xref）直接基于当前包执行；'
        '报告决策证据（规则命中/组件）仍基于源 APK，修改结果以安装验证为准。',
  };
}

/// F5：freshness 绑定当前目标文件指纹。连续修改目标（boundApk=activeApkPath）
/// 与报告源 APK 文件名不一致（如签名包续改、换包）→ 强制 stale，触发重建
/// 报告流程；无当前目标 → 无法核对，降为 unknown。
Future<Map<String, dynamic>> _freshnessWithBoundApk(
  Map<String, dynamic> report,
  String? boundApk,
) async {
  final base = await ApkWorkspaceService.reportFreshnessOf(report);
  final target = boundApk ?? '';
  final sourceApk = report['sourceApk'];
  final reportFile =
      (sourceApk is Map ? sourceApk['fileName']?.toString() : '') ?? '';
  if (target.isEmpty) {
    return {
      ...base,
      if (base['status'] == 'fresh') 'status': 'unknown',
      'boundApkCheck':
          '当前没有连续修改目标（boundApk 缺失），文件指纹无法核对（P3 盲区）；请用 analyze_apk_workspace 重新分析目标 APK 后重查',
    };
  }
  if (reportFile.isEmpty) return base;
  final boundName = target.split('/').last;
  if (boundName != reportFile) {
    return {
      ...base,
      'status': 'stale',
      'action':
          '当前目标是 $boundName，报告对应 $reportFile（源 APK）——两者不一致：'
          '报告决策证据基于源 APK，当前目标是签名包或其他包，必须先 analyze_apk_workspace '
          '重新分析当前实际目标后再执行任何修改。',
    };
  }
  return base;
}

/// 工具能力总表：列出全部本地 APK 工具的触发信号与流程，供 AI 选工具时查阅。
final Map<String, String> _apkToolMapCache = <String, String>{};

String _handleApkToolMap(Assistant assistant, Map<String, dynamic> args) {
  final requestedTool = args['tool']?.toString().trim();
  // 目录语义 = 能力总表：assistant 启用的全部工具（含 analyzer.*），
  // 不是本轮实际下发的函数子集。此前用 __runtimeToolNames 当目录全集，
  // Tier0 轻量路由下只剩编排/记忆类，Agent 误判「写工具缺失」而中断
  // （实测执行层一切正常，纯粹是目录层与启用集脱节）。
  final enabledToolIds = assistant.localToolIds.toSet();
  final sortedEnabled = enabledToolIds.toList()..sort();
  final runtimeNames = _runtimeToolNames(args, assistant);
  final declaredThisTurn = runtimeNames.intersection(enabledToolIds).toList()
    ..sort();
  final cacheKey =
      '${sortedEnabled.join('\u0001')}\u0000${declaredThisTurn.join('\u0001')}'
      '\u0000${requestedTool ?? ''}';
  final cached = _apkToolMapCache[cacheKey];
  if (cached != null) return cached;
  final definitionsByName = <String, Map>{
    for (final definition in <Map<String, dynamic>>[
      ...LocalToolsService.buildToolDefinitions(
        assistant: assistant,
        supportsTools: true,
      ),
      ...AnalyzerGatewayTools.buildDefinitions(assistant.localToolIds.toSet()),
    ])
      if (definition['function'] case final Map function)
        function['name'].toString(): function,
  };
  final requestedEnabled = requestedTool != null && requestedTool.isNotEmpty;
  if (requestedEnabled && !enabledToolIds.contains(requestedTool)) {
    return jsonEncode({
      'error': 'tool_not_available',
      'message': '工具 $requestedTool 未在当前助手启用（可用名单见 callableToolNames）。',
    });
  }
  final selectedNames = requestedEnabled
      ? <String>[requestedTool]
      : sortedEnabled;
  final tools = <Map<String, dynamic>>[
    for (final name in selectedNames)
      {
        'name': name,
        'declaredNow': declaredThisTurn.contains(name),
        if (definitionsByName[name]?['description'] != null)
          'description': definitionsByName[name]!['description'],
        if (requestedEnabled && definitionsByName[name]?['parameters'] is Map)
          'parameters': name == LocalToolNames.soAnalyze
              ? _fullSoAnalyzeParameters(
                  definitionsByName[name]!['parameters'] as Map,
                )
              : definitionsByName[name]!['parameters'],
      },
  ];
  final result = jsonEncode({
    'tools': tools,
    'callableToolNames': [for (final tool in tools) tool['name']],
    'declaredThisTurn': declaredThisTurn,
    'compact': !requestedEnabled,
    'contract': requestedEnabled
        ? (declaredThisTurn.contains(requestedTool)
              ? '仅可按 parameters 调用该工具。'
              : '该工具已启用但未在本轮函数列表中：立即调用会被 unknown_function 拦截；'
                    '继续正常任务流（route_task 返回轨道/下一轮扩容）后会自动挂载，届时再调用。'
                    '不要因此判定能力缺失。')
        : '这是能力总表（assistant 启用的全部工具），declaredNow=false 的工具本轮未下发、'
              '会在 route_task 返回轨道或下一轮自动挂载。需要参数时调用 '
              'get_solab_tool_map(tool=<name>)，一次读取一个工具。'
              '目录里没有的工具才是真的没启用；不要用本轮 declaredThisTurn 判断能力存缺。',
  });
  if (_apkToolMapCache.length >= 16) {
    _apkToolMapCache.remove(_apkToolMapCache.keys.first);
  }
  _apkToolMapCache[cacheKey] = result;
  return result;
}

Set<String> _runtimeToolNames(Map<String, dynamic> args, Assistant assistant) {
  final runtime = args['__runtimeToolNames'];
  if (runtime is List) {
    return runtime.map((name) => name.toString()).toSet();
  }
  return assistant.localToolIds.toSet();
}

Map<String, dynamic> _fullSoAnalyzeParameters(Map parameters) {
  final properties = Map<String, dynamic>.from(parameters['properties'] as Map);
  final action = Map<String, dynamic>.from(properties['action'] as Map);
  action['description'] = kSoAnalyzeActionCatalog.join(' | ');
  properties['action'] = action;
  return <String, dynamic>{...parameters, 'properties': properties};
}

Future<String> _handleApkRecordPatchVerification(
  Map<String, dynamic> args,
  ChatService? chatService,
  MemoryRepository? memoryRepository,
) async {
  final repository = chatService?.chatRepositoryOrNull;
  if (repository == null || memoryRepository == null) {
    return jsonEncode({
      'error': 'chat_service_unavailable',
      'message': '聊天服务尚未就绪，请稍后再试。',
    });
  }
  final outcome = (args['outcome'] ?? '').toString();
  final summary = (args['summary'] ?? '').toString().trim();
  if ((outcome != 'success' && outcome != 'failure') || summary.isEmpty) {
    return jsonEncode({
      'error': 'invalid_args',
      'message': 'outcome 只能是 success 或 failure，summary 必填。',
    });
  }
  final report = await ApkWorkspaceService.readReport();
  final activePath = await ApkWorkspaceBindingService.activeApkPath();
  if (report == null || activePath == null) {
    return jsonEncode({
      'error': 'patch_artifact_not_found',
      'message': '当前没有可验证的补丁产物，请先完成一次修改。',
    });
  }
  final builds = await ApkWorkspaceBindingService.readBuilds();
  Map<String, dynamic>? artifact;
  for (final build in builds) {
    if (build['output'] == activePath) {
      artifact = build;
      break;
    }
  }
  if (artifact == null ||
      artifact['kind'] != 'build' ||
      artifact['signed'] != true ||
      artifact['pendingMemoryStatus'] != 'awaiting_user_verification') {
    return jsonEncode({
      'error': 'signed_artifact_required',
      'message': '请先生成签名成品并预存待验证记录，再写入安装验证结论。',
    });
  }
  // 成品文件档案：验证通过时把产物的内容指纹（sha256）连同验证结论一起
  // 沉淀到 patch memory——后续会话拿到这个文件时按指纹反查即可识别
  // 「这是已验证的成品/基线」，不必从原始包重做。
  final outputPath = (artifact['output'] ?? '').toString();
  String outputSha256 = '';
  int outputSize = 0;
  if (outputPath.isNotEmpty && File(outputPath).existsSync()) {
    outputSha256 = await _sha256OfFile(outputPath);
    outputSize = File(outputPath).lengthSync();
  }
  final vendors = await ApkRuleService(repository).vendorsForReport(report);
  final fingerprint = ApkPatchMemoryService.fingerprintFromReport(
    report,
    vendors: vendors,
  );
  final operation = (artifact['operation'] ?? '').toString();
  // MT 签名产物没有 operation 字段，用统一标识避免标题空操作。
  final effectiveOperation = operation.isNotEmpty ? operation : 'apk_build';
  final now = DateTime.now().millisecondsSinceEpoch;
  // 改点来自本次 APK 的修改笔记（apk_note_write 沉淀）：验证经验带上
  // 具体 locator（qualifiedId/so 符号/条目路径），复用时按图索骥，
  // 而不是只有一句抽象方案 + 工具名。
  final pendingDraft = artifact['pendingMemoryDraft'] is Map
      ? Map<String, dynamic>.from(artifact['pendingMemoryDraft'] as Map)
      : const <String, dynamic>{};
  final pendingChanges = <Map<String, dynamic>>[
    for (final change in (artifact['pendingChanges'] as List? ?? const []))
      if (change is Map) Map<String, dynamic>.from(change),
  ];
  final targets = {
    for (final target in _stringList(pendingDraft['targets']))
      if (target.toString().trim().isNotEmpty) target.toString().trim(),
    for (final change in pendingChanges) ...{
      if ((change['locator'] ?? '').toString().trim().isNotEmpty)
        (change['locator'] ?? '').toString().trim(),
      for (final locator in _stringList(change['locators']))
        if (locator.toString().trim().isNotEmpty) locator.toString().trim(),
    },
  }.toList();
  // 标题带改点摘要（locator 取短名，最多 3 个）：纯工具名（如
  // patch_apk_dex_methods）零信息量，看不出改了什么。
  String shortLocator(String loc) =>
      loc.length > 40 ? '${loc.substring(0, 40)}…' : loc;
  final draftTitle = (pendingDraft['title'] ?? '').toString().trim();
  final title = draftTitle.isNotEmpty
      ? draftTitle
      : targets.isEmpty
      ? (outcome == 'success'
            ? '已验证有效: $effectiveOperation'
            : '已验证无效: $effectiveOperation')
      : (outcome == 'success'
            ? '已验证有效·${targets.length}处: ${targets.take(3).map(shortLocator).join('; ')}'
            : '已验证无效·${targets.length}处: ${targets.take(3).map(shortLocator).join('; ')}');
  // 收敛写入：同指纹收敛为同一条（方案/易错点/改点合并且保留）。
  // pitfall 可选：本次验证发现/规避的易错点，随经验一起沉淀。
  final draftSolution = (pendingDraft['solution'] ?? '').toString().trim();
  final verifiedSolution = draftSolution.isEmpty
      ? summary
      : '$draftSolution\n安装验证: $summary';
  await ApkPatchMemoryService.upsertVerification(
    repo: memoryRepository,
    fingerprint: fingerprint,
    outcome: 'verified_$outcome',
    title: title,
    solution: verifiedSolution,
    operation: effectiveOperation,
    pitfall: ApkPatchMemoryService.mergePitfall(
      (pendingDraft['pitfall'] ?? '').toString().trim(),
      (args['pitfall'] ?? '').toString().trim(),
    ),
    targets: targets,
    versionName: (report['versionName'] ?? '').toString().trim(),
    artifacts: [
      if (outputSha256.isNotEmpty)
        {
          'sha256': outputSha256,
          'path': outputPath,
          'size': outputSize,
          'fileName': outputPath.split('/').last.split('\\').last,
          'kind': 'patched_output',
          'recordedAt': now,
        },
    ],
  );
  artifact['verification'] = outcome;
  artifact['verificationSummary'] = summary;
  artifact['verifiedAt'] = now;
  if (outputSha256.isNotEmpty) {
    artifact['outputSha256'] = outputSha256;
    artifact['outputSize'] = outputSize;
  }
  artifact['pendingMemoryStatus'] = 'committed_after_user_verification';
  await ApkWorkspaceBindingService.replaceBuilds(builds);
  Map<String, dynamic>? cleanup;
  if (outcome == 'success') {
    cleanup = await ApkWorkspaceBindingService.cleanupAfterVerifiedSuccess();
    ToolSessionState.lastBuiltSoPath = null;
    ToolSessionState.lastBuiltSoApkPath = null;
    ToolSessionState.lastBuiltSoEntry = null;
  }
  return jsonEncode({
    'ok': true,
    'outcome': outcome,
    'operation': effectiveOperation,
    // 消息与 cleanup 结果一致：清理失败就不说“已自动清理”（Agent 曾因
    // 正文与字段矛盾多花一轮手动删除）。
    'message': outcome == 'success'
        ? (cleanup == null || cleanup['ok'] == true
              ? '用户安装验证结论已写入长期记忆；工作目录已自动清理，仅保留原包和最终成品。'
              : '用户安装验证结论已写入长期记忆；工作目录清理未完成（见 cleanup 字段），请检查遗留中间产物。')
        : '用户安装验证结论已写入长期记忆；未清理工作目录，保留现场继续修复。',
    if (cleanup != null) 'cleanup': cleanup,
  });
}

/// Analyzer Gateway：4 个高阶 API 分派。
Future<String> _handleAnalyzerTool(
  String name,
  Map<String, dynamic> args,
  String contextKey,
) async {
  return AnalyzerGatewayTools(contextKey: contextKey).handle(name, args);
}

/// 统一解析本地 APK 绝对路径。
/// 返回 (path, error)：path 非空=成功；error 非空=需报错；两者都空=无路径可用。
/// apkPath/path 契约（两者同语义：补丁类工具 schema 用 apkPath，
/// M1-M6 工具链 schema 用 path）：
///   - 绝对路径（/ 开头或含盘符）→ 原样使用
///   - 未传 → 优先沿用当前连续修改的产物；没有才回退当前项目源包。
///   - 相对路径/文件名 → join(工作目录, 输入)。工作目录是用户在 APK 工作台
///     选定的统一工作目录（APK/SO/文件工具共用）。
///   - 工作目录未设置且给了相对路径 → 明确拒绝（不一致时拒绝执行）。
Future<(String?, String?)> _resolveLocalApkPath(
  Map<String, dynamic> args,
  ChatService? chatService,
) async {
  final explicit = (args['apkPath'] ?? args['path'] ?? '').toString().trim();
  if (explicit.isNotEmpty) {
    final isAbsolute = explicit.startsWith('/') || explicit.contains(':');
    if (isAbsolute) {
      // P0-A 铁律：绝对路径必须位于统一工作目录内，越界直接拒绝。
      final dir = await ApkWorkspaceBindingService.workDir();
      if (dir == null || dir.isEmpty) {
        return (
          null,
          '工作目录未设置：请先在 APK 工作台设置统一工作目录（所有工具读写'
              '限制在工作目录内），或直接传工作目录内路径。',
        );
      }
      final guarded = _guardInsideWorkDir(dir, explicit);
      if (guarded == null) {
        return (
          null,
          '路径越界（$explicit）：所有工具读写必须限制在统一工作目录内'
              '（$dir）。外部 APK 请先用 file(action=copy) 复制进工作目录，'
              '再使用工作目录内路径。',
        );
      }
      if (!await File(guarded).exists()) {
        final regenerated = await _tryRegenerateSignatureArtifact(guarded);
        if (regenerated != null) return (regenerated, null);
        return (null, await _missingLocalApkMessage(guarded));
      }
      if (guarded.toLowerCase().endsWith('.apk') &&
          await File(guarded).exists()) {
        await ApkWorkspaceBindingService.setActiveApkPath(guarded);
      }
      return (guarded, null);
    }
    // 相对路径/文件名 → 用统一工作目录拼接
    final dir = await ApkWorkspaceBindingService.workDir();
    if (dir == null || dir.isEmpty) {
      return (
        null,
        'apkPath 是相对路径/文件名「$explicit」，需要先在 APK 工作台设置「工作目录」'
            '（统一工作目录：APK/SO/文件工具共用），才能解析为绝对路径。请先在工作台选择工作'
            '目录，或直接传绝对路径。',
      );
    }
    final direct = p.join(dir, explicit);
    if (await File(direct).exists()) {
      if (direct.toLowerCase().endsWith('.apk')) {
        await ApkWorkspaceBindingService.setActiveApkPath(direct);
      }
      return (direct, null);
    }
    final matches = await _workspaceApkMatches(explicit);
    if (matches.length == 1) {
      final matched = matches.single['path']?.toString() ?? '';
      if (matched.isNotEmpty) {
        await ApkWorkspaceBindingService.setActiveApkPath(matched);
        return (matched, null);
      }
    }
    final candidates = matches
        .map((entry) => entry['name']?.toString() ?? '')
        .where((name) => name.isNotEmpty)
        .join('、');
    if (candidates.isEmpty) {
      final regenerated = await _tryRegenerateSignatureArtifact(direct);
      if (regenerated != null) return (regenerated, null);
      return (null, await _missingLocalApkMessage(direct));
    }
    return (
      null,
      '「$explicit」匹配多个 APK：$candidates。先调用 list_workspace_apks 后选择准确文件名。',
    );
  }
  final active = await ApkWorkspaceBindingService.activeApkPath();
  if (active != null) {
    if (await File(active).exists()) return (active, null);
    // 链头自愈：active 指向的产物已被清理/删除（自动清中间包、手动删除、
    // 清理工具回收）时，回退到产物索引中仍存在的最新产物并同步修正链头，
    // 防止整条工具链因产物缺失硬中断。
    final builds = await ApkWorkspaceBindingService.readBuilds();
    for (final build in builds) {
      final candidate = build['output']?.toString();
      if (candidate == null || candidate.isEmpty || candidate == active) {
        continue;
      }
      if (build['exists'] == true) {
        await ApkWorkspaceBindingService.setActiveApkPath(candidate);
        return (candidate, null);
      }
    }
    final regenerated = await _tryRegenerateSignatureArtifact(active);
    if (regenerated != null) return (regenerated, null);
    await ApkWorkspaceBindingService.clearActiveApkPath();
    return (null, await _missingLocalApkMessage(active));
  }
  final report = await ApkWorkspaceService.readReport();
  final repository = chatService?.chatRepositoryOrNull;
  if (report != null && repository != null) {
    final project = await ApkProjectService(
      repository,
    ).findBySha256((report['sha256'] ?? '').toString());
    final sourcePath = project?.sourcePath;
    if (sourcePath != null && sourcePath.isNotEmpty) {
      if (await File(sourcePath).exists()) return (sourcePath, null);
      return (null, await _missingLocalApkMessage(sourcePath));
    }
  }
  final workspaceApks = await ApkWorkspaceBindingService.listApks();
  if (workspaceApks.length == 1) {
    final path = workspaceApks.single['path']?.toString() ?? '';
    if (path.isNotEmpty) {
      await ApkWorkspaceBindingService.setActiveApkPath(path);
      return (path, null);
    }
  }
  if (workspaceApks.length > 1) {
    final candidates = workspaceApks
        .map((entry) => entry['name']?.toString() ?? '')
        .where((name) => name.isNotEmpty)
        .join('、');
    return (
      null,
      '当前没有可用 APK 路径。工作目录有多个 APK：$candidates。先调用 list_workspace_apks，再选择 fileName 或 apkPath。',
    );
  }
  return (null, null);
}

Future<List<Map<String, dynamic>>> _workspaceApkMatches(
  String requested,
) async {
  final name = p.basename(requested).toLowerCase();
  final stem = p.basenameWithoutExtension(name);
  return (await ApkWorkspaceBindingService.listApks())
      .where((entry) {
        final candidate = (entry['name'] ?? '').toString().toLowerCase();
        return candidate == name ||
            p.basenameWithoutExtension(candidate) == stem;
      })
      .toList(growable: false);
}

Future<String> _missingLocalApkMessage(String missingPath) async {
  final dir = await ApkWorkspaceBindingService.workDir();
  final apks = await ApkWorkspaceBindingService.listApks();
  final builds = await ApkWorkspaceBindingService.readBuilds();
  Map<String, dynamic>? missingArtifact;
  for (final build in builds) {
    if (build['output'] == missingPath) {
      missingArtifact = build;
      break;
    }
  }
  final available = apks
      .map((entry) => entry['path']?.toString() ?? '')
      .where((path) => path.isNotEmpty)
      .toList(growable: false);
  final signatureChainBroken =
      missingArtifact?['signatureCompatibility'] != null ||
      (missingArtifact?['operation']?.toString() ?? '').startsWith(
        'signature_compatibility_',
      );
  final recovery = signatureChainBroken
      ? '该文件属于签名兼容修改链且已丢失。下一次需要它时会从原始 APK 自动补生，不重做分析报告。'
      : '请从现存 APK 中明确选择 apkPath；若缺失的是签名兼容产物，先调用 analyze_apk_workspace 重新生成。';
  return 'APK 目标不存在: $missingPath。工作目录: ${dir ?? '未设置'}。'
      '现存 APK: ${available.isEmpty ? '无' : available.join('、')}。$recovery';
}

Future<String?> _tryRegenerateSignatureArtifact(String missingPath) async {
  for (final build in await ApkWorkspaceBindingService.readBuilds()) {
    if (build['output'] == missingPath) {
      return _regenerateSignatureArtifact(build, missingPath: missingPath);
    }
  }
  return null;
}

Future<String?> _regenerateSignatureArtifact(
  Map<String, dynamic> artifact, {
  required String missingPath,
}) async {
  final operation = artifact['operation']?.toString() ?? '';
  if (!operation.startsWith('signature_compatibility_')) return null;
  final sourcePath =
      (artifact['rootSource'] ?? artifact['source'] ?? artifact['input'])
          ?.toString() ??
      '';
  if (sourcePath.isEmpty || !await File(sourcePath).exists()) return null;
  final outputDir = await ApkWorkspaceBindingService.managedOutputDir();
  if (outputDir == null || outputDir.isEmpty) return null;
  final mode = operation.substring('signature_compatibility_'.length);
  final result = await ApkStructuralService.patchDexMethods(
    path: sourcePath,
    signatureBypass: true,
    signatureBypassMode: mode,
    originalApkPath: mode == 'original_apk' || mode == 'dpatch'
        ? sourcePath
        : null,
    outputDir: outputDir,
  );
  if (!result.ok) return null;
  final output = result.data?['outputPath']?.toString() ?? '';
  if (output.isEmpty || !await File(output).exists()) return null;
  await ApkWorkspaceBindingService.recordPatchArtifact(
    source: sourcePath,
    output: output,
    operation: operation,
  );
  await ApkWorkspaceService.refreshSourceFingerprint(
    output,
    replacesPath: missingPath,
  );
  return output;
}

Future<String?> _validateMutationPreview(
  Map<String, dynamic> args, {
  required String operation,
  required String path,
}) async {
  final token = (args['previewToken'] ?? '').toString();
  if (token.isEmpty) {
    return '缺少预览凭证。请先用 dryRun=true 预览当前修改，再带 previewToken 执行。';
  }
  final result = await ApkMutationPreviewService.validateResult(
    token: token,
    operation: operation,
    path: path,
    args: args,
  );
  if (result['ok'] == true) return null;
  if (result['reason'] == 'mismatch') {
    return '${result['message']} expectedPath=${result['expectedPath']}; '
        'expectedArguments=${jsonEncode(result['expectedArguments'])}。'
        '使用原 token 和上述参数直接重试，不要重新 dryRun。';
  }
  // P1-4：附过期时间与重取方式，让失败原因可执行
  return '${result['message']}请重新 dryRun=true 预览获取新 previewToken 后执行。';
}

Map<String, dynamic> _previewApplyArguments(
  Map<String, dynamic> args, {
  required String path,
  required String previewToken,
  Map<String, dynamic> resolved = const <String, dynamic>{},
}) => <String, dynamic>{
  ...args,
  ...resolved,
  'apkPath': path,
  'dryRun': false,
  'confirm': true,
  'previewToken': previewToken,
}..remove('applyAfterPreview');

bool _previewCanApply(ApkStructuralResult result) {
  if (!result.ok) return false;
  final data = result.data ?? const <String, Object?>{};
  if (data['changed'] == false) return false;
  final warning = data['warning'];
  if (warning is Map && warning['type'] != null) return false;
  return true;
}

Future<String> _handleApkPatchDex(
  Map<String, dynamic> args,
  ChatService? chatService,
) async {
  final (path, pathError) = await _resolveLocalApkPath(args, chatService);
  if (pathError != null) {
    return jsonEncode({'error': 'invalid_apk_path', 'message': pathError});
  }
  if (path == null || path.isEmpty) {
    return jsonEncode({
      'error': 'project_not_ready',
      'message':
          '需要本地 APK 路径才能修改。请先在工作台选择并分析 APK，'
          '或传入 apkPath 参数指定本地 APK 绝对路径。',
    });
  }
  final dryRun = args['dryRun'] == true;
  if (!dryRun && args['confirm'] != true && args['applyAfterPreview'] != true) {
    return jsonEncode({
      'error': 'confirmation_required',
      ..._gateEcho(args),
      'message':
          '契约：先用 dryRun=true 预览，再以相同参数 + applyAfterPreview=true（或 confirm=true）执行。',
    });
  }
  final outputDir = await ApkWorkspaceBindingService.managedOutputDir();
  if (outputDir == null || outputDir.isEmpty) {
    return jsonEncode({
      'error': 'output_dir_required',
      'message': '请先在 APK 工作台设置「工作目录」（统一工作目录：APK/SO/文件工具共用），产物才能落外部可访问位置。',
    });
  }
  final previewArgs = <String, dynamic>{...args, 'outputDir': outputDir};
  if (!dryRun) {
    final previewError = await _validateMutationPreview(
      previewArgs,
      operation: LocalToolNames.apkPatchDex,
      path: path,
    );
    if (previewError != null) {
      return jsonEncode({'error': 'preview_required', 'message': previewError});
    }
  }
  final signatureBypass = args['signatureBypass'] == true;
  final requestedSignatureMode =
      args['signatureBypassMode']?.toString().trim() ?? '';
  final signatureBypassMode = signatureBypass
      ? (requestedSignatureMode.isEmpty
            ? await ApkWorkspaceBindingService.signatureBypassDefaultMode()
            : requestedSignatureMode)
      : 'normal';
  Future<ApkStructuralResult> runPatch(bool preview) =>
      ApkStructuralService.patchDexMethods(
        path: path,
        voidMethods: _stringList(args['voidMethods']),
        trueMethods: _stringList(args['trueMethods']),
        falseMethods: _stringList(args['falseMethods']),
        classMethods: _stringList(args['classMethods']),
        sdkPackages: _stringList(args['sdkPackages']),
        removeVpnDetection: args['removeVpnDetection'] == true,
        removeEmulatorDetection: args['removeEmulatorDetection'] == true,
        removeRootDetection: args['removeRootDetection'] == true,
        removeDebugDetection: args['removeDebugDetection'] == true,
        timeMethods: _stringList(args['timeMethods']),
        nullMethods: _stringList(args['nullMethods']),
        shortenSplashCountdown: args['shortenSplashCountdown'] == true,
        signatureBypass: signatureBypass,
        signatureBypassMode: signatureBypassMode,
        originalApkPath: args['originalApkPath']?.toString(),
        stripDebugInfo: args['stripDebugInfo'] == true,
        outputDir: outputDir,
        dryRun: preview,
      );

  var result = await runPatch(dryRun);
  var effectiveDryRun = dryRun;
  Map<String, Object?>? previewData;
  String? previewToken = dryRun && result.ok
      ? await ApkMutationPreviewService.issue(
          operation: LocalToolNames.apkPatchDex,
          path: path,
          args: previewArgs,
        )
      : (args['previewToken']?.toString());
  Map<String, dynamic>? applyArguments;
  if (dryRun && previewToken != null) {
    applyArguments = _previewApplyArguments(
      args,
      path: path,
      previewToken: previewToken,
    );
    if (args['applyAfterPreview'] == true && _previewCanApply(result)) {
      previewData = result.data?.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      result = await runPatch(false);
      effectiveDryRun = false;
    }
  }
  var encoded = await _encodeApkMutationResult(
    result,
    sourcePath: path,
    operation: LocalToolNames.apkPatchDex,
    dryRun: effectiveDryRun,
    previewToken: previewToken,
    modifiedLocators: _patchDexLocators(args),
  );
  // 防重复修改闭环：dryRun 预览附带"本次目标与历史修改笔记的重叠"。
  // 此前笔记只写不回读——模型不主动调 apk_note_read 时，同一方法被
  // 重复补丁无任何提示。有意重做（从原包重开链）仍可 confirm，不阻断。
  if (dryRun) {
    try {
      final requested = _patchDexLocators(args).toSet();
      if (requested.isNotEmpty) {
        final active = await ApkWorkspaceBindingService.activeApkPath();
        final builds = await ApkWorkspaceBindingService.readBuilds();
        final patched = <String>{
          for (final build in builds)
            if (build['output'] == active)
              for (final change
                  in (build['pendingChanges'] as List? ?? const []))
                if (change is Map) ...{
                  if ((change['locator'] ?? '').toString().trim().isNotEmpty)
                    (change['locator'] ?? '').toString().trim(),
                  for (final locator in _stringList(change['locators']))
                    if (locator.toString().trim().isNotEmpty)
                      locator.toString().trim(),
                },
        };
        final overlap = requested
            .where(patched.contains)
            .toList(growable: false);
        if (overlap.isNotEmpty) {
          final map = jsonDecode(encoded) as Map<String, dynamic>;
          map['alreadyPatchedOverlap'] = overlap;
          // 基线判定：当前目标与登记链的源头是否同一文件（内容 sha256）。
          // 同包重补 → 提示移除重叠项；换基线重做（用户指示在旧成品上
          // 叠加）→ 提示是预期场景，确认后继续。
          map['alreadyPatchedBaseline'] = await _alreadyPatchedBaselineLabel(
            builds,
            targetPath: path,
          );
          map['alreadyPatchedHint'] = map['alreadyPatchedBaseline'] == 'same'
              ? '以上 locator 已在当前对话的修改链中登记，且本次目标与登记基线是同一文件（同包重补）。'
                    '若是有意重做可继续 confirm；否则移除重叠项，避免对同一方法重复补丁。'
              : '以上 locator 已在历史修改链中登记，但本次目标与登记基线不是同一文件（换基线/在旧成品上叠加重做）。'
                    '属预期场景时确认即可；确认前核对 apkPath 确实是用户指定的目标。';
          encoded = jsonEncode(map);
        }
      }
    } catch (_) {
      // 笔记不可用时预览照常返回。
    }
  }

  return _withPreviewFlow(
    encoded,
    applyArguments: applyArguments,
    previewData: previewData,
    appliedAfterPreview: previewData != null && result.ok,
    autoApplyBlocked:
        dryRun && args['applyAfterPreview'] == true && previewData == null,
  );
}

/// 重叠场景的基线判定：本次目标与登记链源头是否同一文件（内容 sha256）。
/// 返回 same / different / unknown（无登记源或哈希失败）。
Future<String> _alreadyPatchedBaselineLabel(
  List<Map<String, dynamic>> builds, {
  required String targetPath,
}) async {
  String? targetSha;
  try {
    if (File(targetPath).existsSync()) {
      targetSha = await _sha256OfFile(targetPath);
    } else {
      return 'unknown';
    }
  } catch (_) {
    return 'unknown';
  }
  final candidatePaths = <String>{
    for (final build in builds)
      for (final key in const ['rootSource', 'source', 'input'])
        if ((build[key] ?? '').toString().trim().isNotEmpty)
          build[key].toString().trim(),
  };
  for (final candidate in candidatePaths) {
    try {
      if (File(candidate).existsSync() &&
          await _sha256OfFile(candidate) == targetSha) {
        return 'same';
      }
    } catch (_) {
      // 单个候选不可读不影响其余候选。
    }
  }
  return 'different';
}

/// 扫描 APK 的签名校验命中关键词（DPatch 去签的风险判定）。
/// 走 Kotlin channel 的 scanSignatureCheck（AC 自动机全 dex 扫描）。
Future<List<String>> _scanSignatureCheckHits(String path) async {
  try {
    final r = await ApkToolchainService.scanSignatureCheck(path: path);
    if (!r.ok) return const <String>[];
    final hits = r.data?['hits'];
    if (hits is List) {
      return [for (final h in hits) h.toString()];
    }
    return const <String>[];
  } catch (_) {
    return const <String>[];
  }
}

/// 独立去签工具：只做签名兼容注入，不分析、不改业务、不签名。
///
/// 铁律：只作用于「未改原包」。因此 [args] 必须显式传 apkPath（原始 APK），
/// 不沿用「最新 patch 输出」这类隐式回退——否则会把注入打到已修改包上。
Future<String> _handleApkSignatureBypass(
  Map<String, dynamic> args,
  ChatService? chatService,
) async {
  final explicit = (args['apkPath'] ?? '').toString().trim();
  if (explicit.isEmpty) {
    return jsonEncode({
      'error': 'apk_path_required',
      'message':
          '去签必须显式传 apkPath（未改原包）。请先用 list_workspace_apks 或 file(action=list) 确认原包路径，再传 apkPath 调用本工具；不要省略。',
    });
  }
  final (path, pathError) = await _resolveLocalApkPath(args, chatService);
  if (pathError != null) {
    return jsonEncode({'error': 'invalid_apk_path', 'message': pathError});
  }
  if (path == null || path.isEmpty) {
    return jsonEncode({
      'error': 'apk_not_found',
      'message': 'apkPath 无法解析到本地 APK。',
    });
  }
  final requestedMode = args['mode']?.toString().trim() ?? '';
  final mode = requestedMode.isEmpty
      ? await ApkWorkspaceBindingService.signatureBypassDefaultMode()
      : requestedMode;
  if (mode == 'off') {
    return jsonEncode({
      'error': 'signature_bypass_disabled',
      'message': 'APK 工作台当前未开启去签。请在工作台选择普通、原包或 DPatch，或本次调用显式传 mode。',
    });
  }
  if (mode != 'normal' && mode != 'original_apk' && mode != 'dpatch') {
    return jsonEncode({
      'error': 'invalid_mode',
      'message': 'mode 仅支持 normal、original_apk 或 dpatch。',
    });
  }
  final outputDir = await ApkWorkspaceBindingService.managedOutputDir();
  if (outputDir == null || outputDir.isEmpty) {
    return jsonEncode({
      'error': 'output_dir_required',
      'message': '请先在 APK 工作台设置工作目录。',
    });
  }
  final r = await ApkStructuralService.patchDexMethods(
    path: path,
    signatureBypass: true,
    signatureBypassMode: mode,
    originalApkPath: mode == 'original_apk' || mode == 'dpatch'
        ? ((args['originalApkPath']?.toString().trim().isNotEmpty ?? false)
              ? args['originalApkPath'].toString()
              : path)
        : null,
    outputDir: outputDir,
  );
  if (!r.ok) {
    return jsonEncode({
      'error': r.error ?? 'signature_bypass_failed',
      'message': r.displayMessage,
    });
  }
  final output = r.data?['outputPath']?.toString() ?? '';
  if (output.isEmpty ||
      p.normalize(p.absolute(output)) == p.normalize(p.absolute(path))) {
    return jsonEncode({
      'error': 'signature_bypass_output_missing',
      'message': '去签没有生成独立产物，已阻止继续修改原包。请重新执行 signature_bypass。',
    });
  }
  if (output.isNotEmpty) {
    await ApkWorkspaceBindingService.recordPatchArtifact(
      source: path,
      output: output,
      operation: 'signature_compatibility_$mode',
    );
  }
  return jsonEncode({
    'ok': true,
    'mode': mode,
    'outputPath': output,
    if (mode == 'dpatch')
      'signatureCheckHits': await _scanSignatureCheckHits(path),
    if (r.data?['signatureBypass'] != null)
      'signatureBypass': r.data?['signatureBypass'],
    if (r.data?['signatureBypassVerification'] != null)
      'signatureBypassVerification': r.data?['signatureBypassVerification'],
    'next':
        '后续所有修改都传这个 outputPath 作为 apkPath，并显式 signatureBypass=false；最终对输出调用 apk_sign 签名。不要在原包或已修改包上重复去签。',
  });
}

/// B6/B7：Manifest 组件/权限清理（dryRun 预览 → confirm 执行）。
Future<String> _handleApkPatchManifest(
  Map<String, dynamic> args,
  ChatService? chatService,
  MemoryRepository? memoryRepository,
) async {
  final (path, pathError) = await _resolveLocalApkPath(args, chatService);
  if (pathError != null) {
    return jsonEncode({'error': 'invalid_apk_path', 'message': pathError});
  }
  if (path == null || path.isEmpty) {
    return jsonEncode({
      'error': 'project_not_ready',
      'message': '请先在 APK 工作台完成分析，或传入 apkPath 绝对路径。',
    });
  }
  final dryRun = args['dryRun'] == true;
  if (!dryRun && args['confirm'] != true && args['applyAfterPreview'] != true) {
    return jsonEncode({
      'error': 'confirmation_required',
      ..._gateEcho(args),
      'message':
          '契约：先用 dryRun=true 预览命中清单，再以相同参数 + applyAfterPreview=true（或 confirm=true）执行。',
    });
  }
  if (!dryRun) {
    final previewError = await _validateMutationPreview(
      args,
      operation: LocalToolNames.apkPatchManifest,
      path: path,
    );
    if (previewError != null) {
      return jsonEncode({'error': 'preview_required', 'message': previewError});
    }
  }
  final outputDir = await ApkWorkspaceBindingService.managedOutputDir();
  if (outputDir == null || outputDir.isEmpty) {
    return jsonEncode({
      'error': 'output_dir_required',
      'message': '请先在 APK 工作台设置「工作目录」（统一工作目录：APK/SO/文件工具共用）。',
    });
  }
  Future<ApkStructuralResult> runPatch(bool preview) =>
      ApkStructuralService.patchManifest(
        path: path,
        removeComponents: _stringList(args['removeComponents']),
        removePermissions: _stringList(args['removePermissions']),
        removeMetaData: _stringList(args['removeMetaData']),
        auto: args['auto'] == true,
        outputDir: outputDir,
        dryRun: preview,
      );
  var result = await runPatch(dryRun);
  var effectiveDryRun = dryRun;
  Map<String, Object?>? previewData;
  String? previewToken = dryRun && result.ok
      ? await ApkMutationPreviewService.issue(
          operation: LocalToolNames.apkPatchManifest,
          path: path,
          args: args,
        )
      : (args['previewToken']?.toString());
  Map<String, dynamic>? applyArguments;
  if (dryRun && previewToken != null) {
    applyArguments = _previewApplyArguments(
      args,
      path: path,
      previewToken: previewToken,
    );
    if (args['applyAfterPreview'] == true && _previewCanApply(result)) {
      previewData = result.data?.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      result = await runPatch(false);
      effectiveDryRun = false;
    }
  }
  final encoded = await _encodeApkMutationResult(
    result,
    sourcePath: path,
    operation: LocalToolNames.apkPatchManifest,
    dryRun: effectiveDryRun,
    previewToken: previewToken,
  );
  return _withPreviewFlow(
    encoded,
    applyArguments: applyArguments,
    previewData: previewData,
    appliedAfterPreview: previewData != null && result.ok,
    autoApplyBlocked:
        dryRun && args['applyAfterPreview'] == true && previewData == null,
  );
}

/// B8：广告 assets 清理（dryRun 预览 → confirm 执行；被引用不删）。
Future<String> _handleApkPatchMemory(
  Map<String, dynamic> args,
  ChatService? chatService,
  MemoryRepository? memoryRepository,
) async {
  final repository = chatService?.chatRepositoryOrNull;
  if (repository == null || memoryRepository == null) {
    return jsonEncode({
      'error': 'chat_service_unavailable',
      'message': '聊天服务尚未就绪，请稍后再试。',
    });
  }
  // 产物识别模式：给定任意 APK 路径，按内容 sha256 反查——
  // 1) 是否某个已验证补丁记录的成品/基线（跨会话 patch memory 档案）；
  // 2) 是否某个已分析项目的源包（项目注册表）。
  // 修复场景：记忆/笔记里没有基线包记录，Agent 无法识别 _signed.apk
  // 已是改好的成品，从原包重做了一遍。
  final lookupPath = (args['lookupArtifactPath'] ?? '').toString().trim();
  if (lookupPath.isNotEmpty) {
    final f = File(lookupPath);
    if (!f.existsSync()) {
      return jsonEncode({
        'ok': false,
        'error': 'file_not_found',
        'message': '文件不存在: $lookupPath',
      });
    }
    final sha = await _sha256OfFile(lookupPath);
    final matches = await ApkPatchMemoryService.findByArtifactSha256(
      memoryRepository,
      sha,
    );
    final project = await ApkProjectService(repository).findBySha256(sha);
    return jsonEncode({
      'ok': true,
      'lookupArtifactPath': lookupPath,
      'sha256': sha,
      if (project != null)
        'sourceProject': ApkProjectService(
          repository,
        ).projectInfoForAi(project),
      'verifiedArtifacts': [
        for (final m in matches)
          {
            'id': m.id,
            'title': m.title,
            'outcome': m.outcome,
            'operation': m.operation,
            if (m.pitfall.isNotEmpty) 'pitfall': m.pitfall,
            if (m.targets.isNotEmpty) 'targets': m.targets,
            'solution': m.solution,
            'artifacts': m.artifacts,
          },
      ],
      'hint': matches.isNotEmpty
          ? '该文件是已验证补丁记录的产物（成品或基线）：直接在其上继续叠加修改即可，'
                '不要从原始包重做；沿用记录中的方案（solution）与改点（targets）。'
                '路径可能已移动，以指纹为准。'
          : project != null
          ? '该文件是已分析项目的源包，可直接继续分析或修改。'
          : '无任何匹配记录：这是未经本助手处理的包（原始包或外部产物），按新任务流程处理。',
    });
  }
  final report = await _readPatchMemoryReport();
  if (report == null) {
    return jsonEncode({
      'error': 'no_apk_selected',
      'message':
          '当前没有 APK 报告，请先在工作台选择并分析；'
          '识别来历不明的包可用 lookupArtifactPath 按文件指纹反查。',
    });
  }
  final vendors = await ApkRuleService(repository).vendorsForReport(report);
  final fingerprint = ApkPatchMemoryService.fingerprintFromReport(
    report,
    vendors: vendors,
  );
  return ApkPatchMemoryService.readForAi(
    memoryRepository,
    fingerprint,
    listAll: args['listAll'] == true,
  );
}

class _DigestCapture implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// 大文件 sha256：流式分块，不整读进内存（APK 可达数百 MB）。
Future<String> _sha256OfFile(String path) async {
  final sink = _DigestCapture();
  final input = sha256.startChunkedConversion(sink);
  await for (final chunk in File(path).openRead()) {
    input.add(chunk);
  }
  input.close();
  return sink.value!.toString();
}

Future<String> _handleApkSavePatchMemory(
  Map<String, dynamic> args,
  ChatService? chatService,
  MemoryRepository? memoryRepository,
) async {
  final title = (args['title'] ?? '').toString().trim();
  final solution = (args['solution'] ?? '').toString().trim();
  if (title.isEmpty || solution.isEmpty) {
    return jsonEncode({
      'error': 'invalid_args',
      'message': 'title 和 solution 都必填。',
    });
  }
  final titleIssue = MemoryQuality.validate(title);
  final solutionIssue = MemoryQuality.validate(solution);
  if (titleIssue != null || solutionIssue != null) {
    return jsonEncode({
      'error': 'quality_rejected',
      'message': titleIssue ?? solutionIssue,
    });
  }
  final report = await _readPatchMemoryReport();
  final staged = await ApkWorkspaceBindingService.stagePendingMemoryDraft({
    'title': title,
    'solution': solution,
    'pitfall': (args['pitfall'] ?? args['pitfalls'] ?? '').toString().trim(),
    'targets': _stringList(args['targets']),
    if (report?['packageName'] != null) 'packageName': report!['packageName'],
    if (report?['sha256'] != null) 'reportSha256': report!['sha256'],
    'createdAt': DateTime.now().millisecondsSinceEpoch,
  });
  if (!staged) {
    return jsonEncode({
      'error': 'signed_artifact_required',
      'message': '请先生成签名成品，再预存待验证修改记录。',
    });
  }
  return jsonEncode({
    'ok': true,
    'staged': true,
    'persistedToLongTermMemory': false,
    'message': '修改记录已预存，尚未写入长期记忆。',
    'nextRequiredTool': LocalToolNames.askUser,
    'mcpFallback': 'MCP 调用方没有提问工具时，可以用文字询问并等待用户明确回复。',
    'questionArguments': _apkVerificationQuestionArguments,
  });
}

const _apkVerificationQuestionArguments = <String, dynamic>{
  'questions': [
    {
      'id': 'apk_install_result',
      'question': '请安装并运行成品，修改是否有效？',
      'type': 'single',
      'options': ['有效', '无效'],
    },
  ],
};

void _markApkAwaitingVerification(Map<String, dynamic> data) {
  data['memoryState'] = 'staged_until_user_verification';
  data['persistedToLongTermMemory'] = false;
  data['verificationRequired'] = true;
  data['completionBlockedUntilUserAnswer'] = true;
  data['nextRequiredTool'] = LocalToolNames.askUser;
  data['questionArguments'] = _apkVerificationQuestionArguments;
  data['mcpFallback'] = 'MCP 调用方没有提问工具时，用文字询问并等待用户明确回复。';
}

Future<Map<String, dynamic>?> _readPatchMemoryReport() async {
  final current = await ApkWorkspaceService.readReport();
  if (current != null) return current;
  final active = await ApkWorkspaceBindingService.activeApkPath();
  final builds = await ApkWorkspaceBindingService.readBuilds();
  final candidates = <String>{};
  if (active != null && active.isNotEmpty) candidates.add(active);
  for (final build in builds) {
    if (active != null && build['output'] != active) continue;
    for (final key in const ['rootSource', 'source', 'input']) {
      final path = (build[key] ?? '').toString();
      if (path.isNotEmpty) candidates.add(path);
    }
  }
  for (final path in candidates) {
    if (!await File(path).exists()) continue;
    final report = await ApkWorkspaceService.findFreshReportForPath(path);
    if (report != null) return report;
  }
  return null;
}

/// REQ-02：列出 MT build 产物索引。
Future<String> _handleApkListBuilds() async {
  final builds = await ApkWorkspaceBindingService.readBuilds();
  return jsonEncode({'builds': builds, 'count': builds.length});
}

/// 连续修改链的中间包后缀：出现在工作目录根部且不在产物索引里的
/// 即为「无主中间包」（索引 50 条截断 / AI 改名复制的失联产物）。
const _intermediateApkSuffixes = <String>[
  '_dexpatch.apk',
  '_manifest.apk',
  '_structural.apk',
  '_assets.apk',
  '_abi.apk',
  '_rebuilt.apk',
  '_merged.apk',
  '_refactored.apk',
  '_patched.apk',
];

final _intermediateApkVersionPattern = RegExp(r'_v\d+\.apk$', caseSensitive: false);

Future<int> _dirSize(Directory dir) {
  var total = 0;
  return dir
      .list(recursive: true, followLinks: false)
      .handleError((_) {})
      .forEach((entry) {
        if (entry is File) {
          total += entry.lengthSync();
        }
      })
      .then((_) => total);
}

/// P3-1 产物清理（流程图②收尾清理的落地版）：
/// - 默认级：SoLab 缓存目录（dexio/jadx/locator，可再生）+ 过期 so 构建
///   产物（patched*.so / *.patch-report.json，保留最近一次 build 的
///   [ToolSessionState.lastBuiltSoPath]）+ 未索引中间包（见 [_intermediateApkSuffixes]）。
/// - aggressive：额外恢复干净基线（保留签名成品、索引内源 APK、当前
///   连续修改目标，其余全清——Blutter 结果/jadx 导出按需重建）。
/// 统一 dryRun → previewToken → confirm 三件套；源 APK 永不删除。
Future<String> _handleApkCleanupBuilds(Map<String, dynamic> args) async {
  final dryRun = args['dryRun'] == true;
  // confirm 与 applyAfterPreview 等价；文案统一走新契约，不再引用 previewToken。
  final confirm = args['applyAfterPreview'] == true || args['confirm'] == true;
  final aggressive = args['aggressive'] == true;
  if (!dryRun && !confirm) {
    return jsonEncode({
      'error': 'confirmation_required',
      ..._gateEcho(args),
      'message':
          '这是删除操作。契约：先 dryRun=true 预览路径与体积，再以相同参数 + applyAfterPreview=true（或 confirm=true）执行。',
    });
  }
  final workDir = await ApkWorkspaceBindingService.workDir();
  if (workDir == null || workDir.isEmpty) {
    return jsonEncode({
      'error': 'output_dir_required',
      'message': '请先在 APK 工作台设置「工作目录」再清理。',
    });
  }
  final previewArgs = <String, dynamic>{...args, 'apkPath': workDir};
  if (!dryRun) {
    final token = args['previewToken']?.toString() ?? '';
    if (token.isEmpty) {
      return jsonEncode({
        'error': 'preview_token_required',
        'message': '缺少 previewToken：先 dryRun=true 获取预览凭证。',
      });
    }
    final check = await ApkMutationPreviewService.validateResult(
      token: token,
      operation: LocalToolNames.apkCleanupBuilds,
      path: workDir,
      args: previewArgs,
    );
    if (check['ok'] != true) return jsonEncode(check);
  }

  final builds = await ApkWorkspaceBindingService.readBuilds();
  final kept = <String>{};
  final active = await ApkWorkspaceBindingService.activeApkPath();
  if (active != null && active.isNotEmpty) kept.add(active);
  for (final build in builds) {
    final out = (build['output'] ?? '').toString();
    if (out.isNotEmpty && (build['kind'] == 'build' || build['keep'] == true)) {
      kept.add(out);
    }
    for (final key in const ['source', 'rootSource', 'input']) {
      final src = (build[key] ?? '').toString();
      if (src.isNotEmpty && p.isWithin(workDir, src)) kept.add(src);
    }
  }
  var lastBuiltSo = ToolSessionState.lastBuiltSoPath;
  if (lastBuiltSo != null && !await File(lastBuiltSo).exists()) {
    ToolSessionState.lastBuiltSoPath = null;
    ToolSessionState.lastBuiltSoApkPath = null;
    ToolSessionState.lastBuiltSoEntry = null;
    lastBuiltSo = null;
  }

  final candidates = <Map<String, dynamic>>[];
  Future<void> addCandidate(FileSystemEntity entity, String reason) async {
    final path = entity.path;
    if (kept.contains(path)) return;
    if (path == lastBuiltSo) return;
    var size = 0;
    if (entity is File) {
      try {
        size = await entity.length();
      } catch (_) {
        return;
      }
    } else if (entity is Directory) {
      size = await _dirSize(entity);
    }
    candidates.add({
      'path': path,
      'type': entity is Directory ? 'dir' : 'file',
      'size': size,
      'reason': reason,
    });
  }

  // —— 默认级收集 ——
  final soLab = Directory(p.join(workDir, 'SoLab'));
  final root = Directory(workDir);
  // 顶层未索引中间包（索引 50 条截断 / AI 改名复制的失联产物）。
  Future<void> collectIntermediateApks() async {
    final indexed = <String>{
      for (final build in builds) (build['output'] ?? '').toString(),
    };
    if (await root.exists()) {
      await for (final entry in root.list().handleError((_) {})) {
        if (entry is! File) continue;
        final name = entry.path.toLowerCase();
        if (!_intermediateApkSuffixes.any(name.endsWith) &&
            !_intermediateApkVersionPattern.hasMatch(name)) {
          continue;
        }
        if (indexed.contains(entry.path)) continue;
        await addCandidate(entry, '未索引中间包');
      }
    }
  }

  if (aggressive) {
    // aggressive 基线：整个 SoLab/ 目录删除（jadx/apkeditor/blutter 产物
    // 均可再生）。顶层只清已识别的中间包后缀——用户放置的原始 APK 和
    // 其他文件即使不在索引里也不动（索引截断可能丢失源 APK 记录）。
    if (await soLab.exists()) {
      await addCandidate(soLab, 'aggressive: SoLab 全部产物（按需重建）');
    }
    await collectIntermediateApks();
  } else {
    // 1) 可再生缓存目录。
    for (final rel in const ['cache/dexio', 'cache/jadx', 'cache/locator']) {
      final dir = Directory(p.join(soLab.path, rel));
      if (await dir.exists()) await addCandidate(dir, 'SoLab 缓存（可再生）');
    }
    // 2) so 构建产物目录：patched*.so 与补丁报告；当前 build 产物保留。
    final soOut = Directory(p.join(soLab.path, 'output/so'));
    if (await soOut.exists()) {
      await for (final entry in soOut.list().handleError((_) {})) {
        if (entry is! File) continue;
        final name = p.basename(entry.path);
        final isSoBuild =
            (name.endsWith('.so') && name.contains('patched')) ||
            name.endsWith('.patch-report.json');
        if (isSoBuild) await addCandidate(entry, '过期 SO 构建产物');
      }
    }
    await collectIntermediateApks();
  }

  if (dryRun) {
    final staleRecords =
        await ApkWorkspaceBindingService.countMissingArtifacts();
    final totalBytes = candidates.fold<int>(
      0,
      (sum, c) => sum + (c['size'] as int),
    );
    final token = await ApkMutationPreviewService.issue(
      operation: LocalToolNames.apkCleanupBuilds,
      path: workDir,
      args: previewArgs,
    );
    return jsonEncode({
      'ok': true,
      'dryRun': true,
      'aggressive': aggressive,
      'itemCount': candidates.length,
      'totalBytes': totalBytes,
      'candidates': candidates,
      'staleRecords': staleRecords,
      'previewToken': token,
      'keptPaths': kept.toList(growable: false),
      'note': '确认无误后原样传回 previewToken + confirm=true 执行。签名成品、源 APK、当前修改目标不清理。',
    });
  }

  // —— 执行 ——
  final deleted = <String>[];
  final failed = <String>[];
  var freedBytes = 0;
  for (final candidate in candidates) {
    final path = candidate['path'] as String;
    try {
      if (candidate['type'] == 'dir') {
        await Directory(path).delete(recursive: true);
      } else {
        await File(path).delete();
      }
      deleted.add(path);
      freedBytes += candidate['size'] as int;
    } catch (_) {
      failed.add(path);
    }
  }
  if (lastBuiltSo != null && deleted.contains(lastBuiltSo)) {
    ToolSessionState.lastBuiltSoPath = null;
    ToolSessionState.lastBuiltSoApkPath = null;
    ToolSessionState.lastBuiltSoEntry = null;
  }
  final prunedRecords =
      await ApkWorkspaceBindingService.pruneMissingArtifacts();
  final token = args['previewToken']?.toString();
  if (token != null && token.isNotEmpty) {
    await ApkMutationPreviewService.consume(
      token: token,
      operation: LocalToolNames.apkCleanupBuilds,
      path: workDir,
      args: previewArgs,
    );
  }
  return jsonEncode({
    'ok': failed.isEmpty,
    'deletedCount': deleted.length,
    'freedBytes': freedBytes,
    'deleted': deleted,
    'prunedRecords': prunedRecords,
    if (failed.isNotEmpty) 'failed': failed,
  });
}

/// REQ-02：回收 MT build 产物（保留最新 + keep 标记项）。
Future<List<String>> _apkLineageIds() async {
  final ids = <String>{};
  final report = await _readPatchMemoryReport();
  final packageName = report?['packageName']?.toString().trim() ?? '';
  if (packageName.isNotEmpty) ids.add('app:${packageName.toLowerCase()}');
  final sha = report?['sha256']?.toString() ?? '';
  if (sha.isNotEmpty) ids.add(sha);
  final active = await ApkWorkspaceBindingService.activeApkPath();
  if (active != null && active.isNotEmpty) ids.add('apk_$active');
  final builds = await ApkWorkspaceBindingService.readBuilds();
  for (final build in builds) {
    if (active != null && build['output'] != active) continue;
    for (final key in const ['rootSource', 'source', 'input', 'output']) {
      final path = (build[key] ?? '').toString();
      if (path.isNotEmpty) ids.add('apk_$path');
    }
  }
  if (ids.isEmpty) ids.add('unknown');
  return ids.toList(growable: false);
}

Future<String> _handleApkNoteRead() async {
  final apkIds = await _apkLineageIds();
  final merged = <String, Map<String, dynamic>>{};
  final active = await ApkWorkspaceBindingService.activeApkPath();
  for (final build in await ApkWorkspaceBindingService.readBuilds()) {
    if (build['output'] != active) continue;
    for (final change in (build['pendingChanges'] as List? ?? const [])) {
      if (change is! Map) continue;
      final locators = <String>{
        if ((change['locator'] ?? '').toString().isNotEmpty)
          (change['locator'] ?? '').toString(),
        for (final locator in _stringList(change['locators']))
          if (locator.toString().isNotEmpty) locator.toString(),
      };
      if (locators.isEmpty) locators.add('auto:${change['operation']}');
      for (final locator in locators) {
        merged[locator] = {
          'locator': locator,
          'status': 'pending_verification',
          'summary': (change['summary'] ?? change['operation'] ?? '')
              .toString(),
          'timestamp': (change['timestamp'] as num?)?.toInt() ?? 0,
          'persistedToLongTermMemory': false,
        };
      }
    }
  }
  final notes = merged.values.toList()
    ..sort(
      (a, b) => ((b['timestamp'] as num?)?.toInt() ?? 0).compareTo(
        (a['timestamp'] as num?)?.toInt() ?? 0,
      ),
    );
  return jsonEncode({
    'apkId': apkIds.first,
    'lineageIds': apkIds,
    'modified': notes,
    'hint': notes.isEmpty
        ? '当前对话暂无已修改标记。'
        : '只包含当前对话的待验证修改记录；不会读取其他会话产物笔记。安装验证后才合并到当前 APP 的单条长期记忆。',
  });
}

/// REQ-08：写已修改标记。
Future<String> _handleApkNoteWrite(Map<String, dynamic> args) async {
  final locator = (args['locator'] ?? '').toString().trim();
  if (locator.isEmpty) {
    return jsonEncode({'error': 'invalid_args', 'message': 'locator 必填。'});
  }
  final status = (args['status'] ?? 'patched').toString();
  final summary = (args['summary'] ?? '').toString();
  final staged = await ApkWorkspaceBindingService.stagePendingChange({
    'locator': locator,
    'status': status,
    'summary': summary,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
  });
  if (!staged) {
    return jsonEncode({
      'error': 'patch_artifact_not_found',
      'message': '当前没有可暂存修改记录的产物。',
    });
  }
  return jsonEncode({
    'ok': true,
    'locator': locator,
    'status': status,
    'staged': true,
    'persistedToLongTermMemory': false,
  });
}

/// 需求1：列出工作目录里的 APK 文件。
Future<String> _handleApkListWorkspace() async {
  final dir = await ApkWorkspaceBindingService.workDir();
  if (dir == null || dir.isEmpty) {
    return jsonEncode({
      'error': 'work_dir_not_set',
      'message': '请先在 APK 工作台设置「工作目录」（统一工作目录：APK/SO/文件工具共用）。',
    });
  }
  final dirFile = Directory(dir);
  if (!await dirFile.exists()) {
    return jsonEncode({
      'error': 'work_dir_not_found',
      'message': '工作目录不存在: $dir',
    });
  }
  final apks = await ApkWorkspaceBindingService.listApks();
  final activeApk = await ApkWorkspaceBindingService.activeApkPath();
  final builds = await ApkWorkspaceBindingService.readBuilds();
  final missingArtifacts = builds
      .where((build) => build['exists'] == false)
      .toList(growable: false);
  final activeExists =
      activeApk != null &&
      activeApk.isNotEmpty &&
      await File(activeApk).exists();
  if (apks.isEmpty) {
    // 自诊断：区分「目录为空」与「权限被拒」，给可操作的提示。
    final readable = await ApkWorkspaceBindingService.dirReadable(dir);
    if (!readable) {
      // 主动申请：直接在手机上拉起「所有文件访问」授权页。
      var requested = false;
      try {
        requested = await ApkStructuralService.requestStoragePermission();
      } catch (_) {}
      return jsonEncode({
        'workDir': dir,
        'apks': apks,
        'count': 0,
        'permissionRequested': requested,
        'hint': requested
            ? '目录无法读取，已在手机上拉起「所有文件访问」授权页：请用户完成授权后重试本工具。'
            : '目录无法读取（$dir）：请授予「所有文件访问」权限（系统设置 → 应用 → SoLab）。',
      });
    }
    return jsonEncode({
      'workDir': dir,
      'apks': apks,
      'count': apks.length,
      'activeApkPath': activeApk,
      'activeApkExists': activeExists,
      'missingIndexedArtifacts': missingArtifacts,
    });
  }
  return jsonEncode({
    'workDir': dir,
    'apks': apks,
    'count': apks.length,
    'activeApkPath': activeApk,
    'activeApkExists': activeExists,
    'missingIndexedArtifacts': missingArtifacts,
    if (!activeExists && activeApk != null)
      'recovery': await _missingLocalApkMessage(activeApk),
  });
}

/// 需求1：分析工作目录里指定的 APK 并保存为当前报告。
Future<String> _handleApkAnalyzeWorkspace(
  Map<String, dynamic> args,
  ChatService? chatService,
  String? conversationId,
) async {
  var fileName = (args['fileName'] ?? '').toString().trim();
  final dir = await ApkWorkspaceBindingService.workDir();
  if (dir == null || dir.isEmpty) {
    return jsonEncode({
      'error': 'work_dir_not_set',
      'message': '请先在 APK 工作台设置「工作目录」。',
    });
  }
  final apks = await ApkWorkspaceBindingService.listApks();
  if (fileName.isEmpty) {
    if (apks.isEmpty) {
      final readable = await ApkWorkspaceBindingService.dirReadable(dir);
      if (!readable) {
        // 主动申请：直接在手机上拉起「所有文件访问」授权页。
        var requested = false;
        try {
          requested = await ApkStructuralService.requestStoragePermission();
        } catch (_) {}
        return jsonEncode({
          'error': 'apk_not_found',
          'workDir': dir,
          'permissionRequested': requested,
          'message': requested
              ? '工作目录无法读取，已在手机上拉起「所有文件访问」授权页：请用户完成授权后重试。'
              : '工作目录无法读取（$dir）：请授予「所有文件访问」权限。',
        });
      }
      return jsonEncode({
        'error': 'apk_not_found',
        'workDir': dir,
        'message': '工作目录中没有 APK 文件。',
      });
    }
    if (apks.length > 1) {
      final active = await ApkWorkspaceBindingService.activeApkPath();
      final knownPaths = apks.map((apk) => apk['path']?.toString()).toSet();
      String? resumable = active != null && knownPaths.contains(active)
          ? active
          : null;
      if (resumable == null) {
        final builds = await ApkWorkspaceBindingService.readBuilds();
        for (final build in builds) {
          final output = build['output']?.toString() ?? '';
          if (build['signed'] == true && knownPaths.contains(output)) {
            resumable = output;
            break;
          }
        }
      }
      if (resumable == null) {
        return jsonEncode({
          'error': 'apk_selection_required',
          'workDir': dir,
          'apks': apks,
          'message': '目录中有多个 APK，当前对话没有可续接产物，请让用户选择其中一个 fileName。',
        });
      }
      fileName = p.basename(resumable);
    } else {
      fileName = apks.single['name']?.toString() ?? '';
    }
  }
  // 防路径穿越：只取文件名。
  final safeName = fileName.split('/').last.split('\\').last;
  final path = p.join(dir, safeName);
  final file = File(path);
  if (!await file.exists()) {
    return jsonEncode({
      'error': 'apk_not_found',
      'message': '工作目录里没有找到 $safeName，可用 file(action=list) 查看实际文件名。',
    });
  }
  final requestedSignatureMode = args['signatureMode']?.toString().trim() ?? '';
  final signatureMode = requestedSignatureMode.isEmpty
      ? await ApkWorkspaceBindingService.signatureBypassDefaultMode()
      : requestedSignatureMode;
  final effectiveSignatureMode = signatureMode == 'off'
      ? 'skip'
      : signatureMode;
  if (effectiveSignatureMode != 'normal' &&
      effectiveSignatureMode != 'original_apk' &&
      effectiveSignatureMode != 'skip') {
    return jsonEncode({
      'error': 'invalid_signature_mode',
      'message': 'signatureMode 支持 normal、original_apk、skip 或 dpatch。',
    });
  }
  final builds = await ApkWorkspaceBindingService.readBuilds();
  Map<String, dynamic>? selectedArtifact;
  for (final build in builds) {
    if (build['output'] == path) {
      selectedArtifact = build;
      break;
    }
  }
  final reusePreparedArtifact =
      selectedArtifact?['modificationInputReady'] == true ||
      (selectedArtifact?['signatureCompatibility'] ?? '').toString().isNotEmpty;
  var preparedPath = '';
  if (effectiveSignatureMode != 'skip' && !reusePreparedArtifact) {
    final outputDir = await ApkWorkspaceBindingService.managedOutputDir();
    final signaturePrepared = await ApkStructuralService.patchDexMethods(
      path: path,
      signatureBypass: true,
      signatureBypassMode: effectiveSignatureMode,
      originalApkPath:
          effectiveSignatureMode == 'original_apk' ||
              effectiveSignatureMode == 'dpatch'
          ? path
          : null,
      outputDir: outputDir,
    );
    if (!signaturePrepared.ok) {
      return jsonEncode({
        'error': 'signature_prepare_failed',
        'message': signaturePrepared.displayMessage,
        'recovery': '已确认应用无签名校验时，可重试并传 signatureMode=skip。',
      });
    }
    preparedPath = signaturePrepared.data?['outputPath']?.toString() ?? '';
    if (preparedPath.isEmpty ||
        p.normalize(p.absolute(preparedPath)) ==
            p.normalize(p.absolute(path))) {
      return jsonEncode({
        'error': 'signature_prepare_output_missing',
        'message': '去签没有生成独立产物，已停止分析，不能继续直接修改原包。',
      });
    }
  }
  final reportPath = preparedPath.isEmpty ? path : preparedPath;
  if (preparedPath.isNotEmpty) {
    await ApkWorkspaceBindingService.recordPatchArtifact(
      source: path,
      output: preparedPath,
      operation: 'signature_compatibility_$effectiveSignatureMode',
    );
  } else {
    await ApkWorkspaceBindingService.setActiveApkPath(path);
  }
  Map<Object?, Object?>? currentReport;
  final savedReport = await ApkWorkspaceService.readReport();
  if (savedReport != null) {
    final source = savedReport['sourceApk'];
    final sourcePath = source is Map ? source['path']?.toString() : null;
    final freshness = await ApkWorkspaceService.reportFreshnessOf(savedReport);
    if (sourcePath == reportPath && freshness['status'] == 'fresh') {
      currentReport = Map<Object?, Object?>.from(savedReport);
    }
  }
  currentReport ??= await ApkWorkspaceService.findFreshReportForPath(
    reportPath,
  );
  currentReport ??= await ApkAnalysisService.analyzeFull(reportPath);
  if (currentReport == null) {
    return jsonEncode({'error': 'analyze_failed', 'message': '分析失败'});
  }
  if (currentReport.containsKey('error')) {
    return jsonEncode(currentReport);
  }
  await ApkWorkspaceService.saveReport(
    currentReport,
    conversationId: conversationId,
  );
  // 落库为项目记录（按 sha256 去重）。
  String? projectId;
  final repository = chatService?.chatRepositoryOrNull;
  if (repository != null) {
    try {
      final project = await ApkProjectService(repository).saveProjectFromReport(
        currentReport.map((key, value) => MapEntry(key.toString(), value)),
        sourcePath: reportPath,
      );
      projectId = project.id;
    } catch (_) {}
  }
  return jsonEncode({
    'ok': true,
    'analyzed': p.basename(reportPath),
    'packageName': currentReport['packageName'],
    'versionName': currentReport['versionName'],
    'shellDetected':
        currentReport['shellPacking'] is Map &&
        (currentReport['shellPacking'] as Map)['detected'] == true,
    'flutterDetected':
        currentReport['flutterApp'] is Map &&
        (currentReport['flutterApp'] as Map)['detected'] == true,
    // 只回样本+总数（全量在 get_current_apk_report 按需分段读取），
    // 避免 analyze 返回体被几百条 pattern 明细撑爆。
    'adSdkMatchSample': ((currentReport['adSdkMatches'] as List?) ?? const [])
        .take(12)
        .toList(),
    'adSdkMatchTotal':
        ((currentReport['adSdkMatches'] as List?) ?? const []).length,
    if (projectId != null) 'projectId': projectId,
    'signatureCompatibility': effectiveSignatureMode == 'skip'
        ? 'skipped_by_request'
        : reusePreparedArtifact
        ? 'reused_existing'
        : preparedPath.isEmpty
        ? 'already_prepared'
        : '${effectiveSignatureMode}_prepared',
    'signatureDefaultMode': requestedSignatureMode.isEmpty
        ? signatureMode
        : null,
    if (reusePreparedArtifact) 'reusedPreparedArtifact': true,
    'message':
        '分析完成，报告已保存为当前项目，可直接用 get_current_apk_report 读取（命中明细按 section=ads/decision 读取）。',
  });
}

/// 规则库查询：分类统计 + 厂商映射 + 当前报告命中建议。
Future<String> _handleListApkRules(
  Map<String, dynamic> args,
  ChatService? chatService,
) async {
  final repository = chatService?.chatRepositoryOrNull;
  if (repository == null) {
    return jsonEncode({
      'error': 'chat_service_unavailable',
      'message': '聊天服务尚未就绪，请稍后再试。',
    });
  }
  final service = ApkRuleService(repository);
  // 关键：先触发 seed（否则新规则类别 detection_*/time_methods/shell 一直是 0）。
  await service.ensureSeedIfNeeded();
  final vendor = (args['vendor'] ?? '').toString().trim();
  if (vendor.isNotEmpty) {
    final rules = await service.rulesForVendor(vendor);
    // 分页读取：自定义特征可达数千条，默认只给 50 条样本（按需翻页，
    // 不要一次性喂全量），offset/limit 翻页读全量（limit 上限 1000）。
    final offset = (args['offset'] as num?)?.toInt() ?? 0;
    final limit = ((args['limit'] as num?)?.toInt() ?? 50).clamp(1, 1000);
    final window = rules.skip(offset).take(limit).toList();
    final hasMore = offset + window.length < rules.length;
    return jsonEncode({
      'vendor': vendor,
      'label': ApkRuleService.vendorLabels[vendor] ?? vendor,
      'ruleCount': rules.length,
      'offset': offset,
      'limit': limit,
      'hasMore': hasMore,
      if (hasMore) 'nextOffset': offset + window.length,
      'rules': [
        for (final rule in window)
          {
            'name': rule.name,
            'category': rule.category,
            'enabled': rule.enabled,
            'risk': rule.risk,
          },
      ],
      if (hasMore)
        'pagingHint':
            '共 ${rules.length} 条，仅返回 $offset-${offset + window.length}；传 offset=${offset + window.length} 继续读取。',
    });
  }
  final counts = await service.countsByCategory();
  final report = await ApkWorkspaceService.readReport();
  final matchedVendors = report == null
      ? const <String>[]
      : await service.vendorsForReport(report);
  // 多信号厂商聚合：DEX/Manifest/assets 三信号，按信号数排序
  final vendorSignals = report == null
      ? const <Map<String, dynamic>>[]
      : service.vendorSignalsForReport(report);
  return jsonEncode({
    'counts': counts,
    'matchedVendors': [
      for (final id in matchedVendors)
        {'id': id, 'label': ApkRuleService.vendorLabels[id] ?? id},
    ],
    'vendorSignals': vendorSignals,
    'hint':
        "vendorSignals 按证据数降序列出当前 APK 命中的广告商及各自信号（DEX/Manifest/assets），"
        "AI 据此判断主导广告商，优先定位其上游初始化入口。Use vendor=<id> to list a vendor's rules.",
  });
}

/// 结构操作：先 dryRun 预览，再带 previewToken 和 confirm=true 执行。

/// 写操作确认门的标准诊断载荷：让调用方能自证"服务端实际收到了什么"，
/// 而不是对着固定文案盲试参数拼写。
Map<String, dynamic> _gateEcho(Map<String, dynamic> args) {
  return <String, dynamic>{
    'receivedArgumentCount': args.length,
    'receivedArguments': <String, dynamic>{
      for (final k in args.keys) k: args[k],
    },
    'previewIssued': false,
  };
}

Future<String> _handleSoPatchIntoApk(
  Map<String, dynamic> args,
  ChatService? chatService,
  MemoryRepository? memoryRepository,
) async {
  final dryRun = args['dryRun'] == true;
  // confirm 与 applyAfterPreview 等价接受；两步执行仍由 previewToken
  // 绑定预览参数，已获用户授权时可用 applyAfterPreview 单次预览并写入。
  final confirm = args['confirm'] == true || args['applyAfterPreview'] == true;
  if (!dryRun && !confirm) {
    return jsonEncode({
      'error': 'confirmation_required',
      ..._gateEcho(args),
      'message':
          '这是写操作。先用 dryRun=true 预览，再原样发送返回的 applyArguments；用户已授权精确写回时可直接 dryRun=true + applyAfterPreview=true。可传 sign=true 一步出签名包。本响应附 receivedArguments，可用于核对参数是否送达。',
      'nextAction': '若 receivedArguments 为空或不完整，说明调用层丢参，请整段重发工具调用。',
    });
  }

  // SO 补丁产物：显式 soPath > 最近 so_analyze build 产物
  final soPathRaw = (args['soPath'] ?? '').toString().trim();
  String? soPath;
  if (soPathRaw.isNotEmpty) {
    final (resolved, soErr) = await _resolveFileOpsPath(<String, dynamic>{
      'path': soPathRaw,
    });
    if (resolved == null) {
      return jsonEncode(soErr);
    }
    soPath = resolved;
    if (!await File(soPath).exists()) {
      return jsonEncode({
        'error': 'so_path_not_found',
        'message':
            'SO 补丁文件不存在: $soPath。请重新 so_analyze(action=build)，或传入 list_sources/list_builds 返回的现存路径。',
      });
    }
  } else {
    soPath = ToolSessionState.lastBuiltSoPath;
    if (soPath == null || soPath.isEmpty || !await File(soPath).exists()) {
      final artifacts = await ApkWorkspaceBindingService.readFileArtifacts();
      Map<String, dynamic>? recovered;
      for (final artifact in artifacts) {
        if (artifact['operation'] == 'so_build' && artifact['exists'] == true) {
          recovered = artifact;
          break;
        }
      }
      if (recovered != null) {
        soPath = recovered['path']?.toString();
        ToolSessionState.lastBuiltSoPath = soPath;
        ToolSessionState.lastBuiltSoApkPath = recovered['source']?.toString();
        final metadata = recovered['metadata'];
        if (metadata is Map) {
          ToolSessionState.lastBuiltSoEntry = metadata['sourceEntry']
              ?.toString();
        }
      }
    }
    if (soPath == null || soPath.isEmpty) {
      return jsonEncode({
        'error': 'so_path_required',
        'message':
            '缺少 SO 补丁产物：传 soPath，或先 so_analyze(action=build) 构建（成功后自动记忆，之后可缺省）。',
      });
    }
    // 归属校验：记忆产物属于构建时的连续修改目标；切换 APK 后禁止
    // 隐式复用旧产物注入新包（显式传 soPath 表示 Agent 已确认归属）。
    final rememberedApk = ToolSessionState.lastBuiltSoApkPath;
    final activeTarget = await ApkWorkspaceBindingService.activeApkPath();
    if (rememberedApk != null &&
        rememberedApk.isNotEmpty &&
        activeTarget != null &&
        activeTarget != rememberedApk) {
      return jsonEncode({
        'error': 'so_path_mismatch',
        'message':
            '记忆中的 SO 产物属于 $rememberedApk，与当前连续修改目标 $activeTarget 不一致。'
            '切换 APK 后不能缺省复用：请显式传 soPath（确认归属），或对新 APK 重新 so_analyze(action=build)。',
      });
    }
    if (!await File(soPath).exists()) {
      return jsonEncode({
        'error': 'so_path_required',
        'message':
            '上次 so_analyze(build) 的产物已不存在（可能被签名收口自动清理）：请传 soPath，或重新 build。',
      });
    }
  }

  // 目标 APK：显式 apkPath > 当前连续修改目标
  final (path, pathError) = await _resolveLocalApkPath(args, chatService);
  if (pathError != null) {
    return jsonEncode({'error': 'invalid_apk_path', 'message': pathError});
  }
  if (path == null || path.isEmpty) {
    return jsonEncode({
      'error': 'project_not_ready',
      'message': '需要本地 APK 路径。请先分析 APK，或传入 apkPath 指定当前待修改 APK。',
    });
  }
  // 目标条目：entryName 显式 > 按 so 名自动推断。
  // 剥离策略（逐级放宽，命中即停）：
  // 1) 明确的补丁后缀 -patched/-patch[-N]；
  // 2) 任意最后一个 -/_ 短词缀（≤12 位字母数字，如 -patped/-mod/-v2），
  //    覆盖 AI 自起名与项目硬编码后缀（_dexpatch/_manifest 等）。
  final soStems = <String>[];
  var entryName = (args['entryName'] ?? '').toString().trim();
  var autoResolved = false;
  if (entryName.isEmpty) {
    final libResult = await ApkToolchainService.listLibEntries(path: path);
    if (!libResult.ok) {
      return jsonEncode({
        'error': libResult.error ?? 'list_libs_failed',
        'message': libResult.message ?? '读取 APK lib 条目失败',
      });
    }
    final libEntries = (libResult.data?['entries'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final abi = (args['abi'] ?? '').toString().trim().toLowerCase();
    final baseStem = p.basenameWithoutExtension(soPath);
    final knownStems =
        libEntries
            .map(
              (entry) => p.basenameWithoutExtension(
                (entry['soName'] ?? entry['name'] ?? '').toString(),
              ),
            )
            .where(
              (known) =>
                  known.isNotEmpty &&
                  (baseStem == known ||
                      baseStem.startsWith('$known-') ||
                      baseStem.startsWith('${known}_') ||
                      baseStem.endsWith('-$known') ||
                      baseStem.endsWith('_$known')),
            )
            .toSet()
            .toList()
          ..sort((a, b) => b.length.compareTo(a.length));
    soStems.addAll(knownStems);
    var stem = baseStem.replaceAll(
      RegExp(r'[-_](patched|patch)([-_]\d+)?$'),
      '',
    );
    if (stem != baseStem) soStems.add(stem);
    final generic = baseStem.replaceFirst(
      RegExp(r'[-_][A-Za-z0-9]{1,12}$'),
      '',
    );
    if (generic != baseStem && generic.isNotEmpty) soStems.add(generic);
    if (!soStems.contains(baseStem)) soStems.add(baseStem);
    final candidates = <String>[];
    for (final s in soStems) {
      candidates.addAll(
        libEntries
            .where((e) => (e['soName'] ?? '').toString() == '$s.so')
            .map((e) => e['name'].toString()),
      );
      if (candidates.isNotEmpty) break;
    }
    if (candidates.isEmpty) {
      final rememberedEntry = ToolSessionState.lastBuiltSoEntry;
      final rememberedCandidates = rememberedEntry == null
          ? const <String>[]
          : libEntries
                .where((e) => e['name'].toString() == rememberedEntry)
                .map((e) => e['name'].toString())
                .toList();
      final libappCandidates = libEntries
          .where((e) => (e['soName'] ?? '').toString() == 'libapp.so')
          .map((e) => e['name'].toString())
          .where((name) => abi.isEmpty || name.startsWith('lib/$abi/'))
          .toList();
      if (rememberedCandidates.length == 1) {
        candidates.add(rememberedCandidates.single);
      } else if (baseStem.toLowerCase().startsWith('patched') &&
          libappCandidates.length == 1) {
        candidates.add(libappCandidates.single);
      }
    }
    if (candidates.isEmpty) {
      // 近似建议：按最长公共前缀/包含关系挑最接近的 lib 条目，
      // 让 AI 一次看清该传什么 entryName，省一轮试错。
      final soNames = libEntries
          .map((e) => (e['soName'] ?? e['name'] ?? '').toString())
          .where((n) => n.isNotEmpty)
          .toList();
      int lcp(String a, String b) {
        var i = 0;
        while (i < a.length && i < b.length && a[i] == b[i]) {
          i++;
        }
        return i;
      }

      final near = soNames.toList()
        ..sort((x, y) {
          final lx = lcp(baseStem, x);
          final ly = lcp(baseStem, y);
          if (lx != ly) return ly - lx;
          return (x.length - y.length);
        });
      final suggestion = near.take(3).isNotEmpty
          ? '最接近的条目: ${near.take(3).map((n) => n).join(', ')}。'
          : '';
      return jsonEncode({
        'error': 'entry_not_found',
        'message':
            'APK 的 lib/ 下没有 ${soStems.first}.so（已尝试剥离补丁后缀: ${soStems.take(2).join(' → ')}）。$suggestion 全部条目: ${libEntries.map((e) => e['name']).take(20).join(', ')}${libEntries.length > 20 ? ' …' : ''}。目标名不同请传 entryName（如 lib/arm64-v8a/xxx.so）。',
      });
    }
    if (abi.isNotEmpty) {
      final hit = candidates.where((c) => c.startsWith('lib/$abi/')).toList();
      if (hit.isEmpty) {
        return jsonEncode({
          'error': 'abi_not_found',
          'message':
              'APK 无 $abi 的 ${soStems.first}.so。候选: ${candidates.join(', ')}。',
        });
      }
      entryName = hit.first;
    } else if (candidates.length == 1) {
      entryName = candidates.first;
    } else {
      return jsonEncode({
        'error': 'ambiguous_abi',
        'message':
            '${soStems.first}.so 命中多个 ABI: ${candidates.join(', ')}。请传 abi 或 entryName 指定目标。',
      });
    }
    autoResolved = true;
  }

  final resolvedArgs = <String, dynamic>{
    ...args,
    'apkPath': path,
    'soPath': soPath,
    'entryName': entryName,
  };
  if (!dryRun) {
    final previewError = await _validateMutationPreview(
      resolvedArgs,
      operation: LocalToolNames.soPatchIntoApk,
      path: path,
    );
    if (previewError != null) {
      return jsonEncode({'error': 'preview_required', 'message': previewError});
    }
  }

  final outputDir = await ApkWorkspaceBindingService.managedOutputDir();
  if (outputDir == null || outputDir.isEmpty) {
    return jsonEncode({
      'error': 'output_dir_required',
      'message': '请先在 APK 工作台设置「工作目录」（统一工作目录：APK/SO/文件工具共用），产物才能落外部可访问位置。',
    });
  }
  Future<ApkStructuralResult> runPatch(bool preview) =>
      ApkStructuralService.writeZipEntry(
        path: path,
        entries: [
          {
            'locator': 'zip_entry:$entryName',
            'action': 'overwrite',
            'content': {'path': soPath},
          },
        ],
        outputDir: outputDir,
        dryRun: preview,
      );
  var result = await runPatch(dryRun);
  if (!result.ok && dryRun) {
    return jsonEncode({
      'error': result.error ?? 'patch_failed',
      'message': result.message ?? 'SO 回填失败',
    });
  }
  var effectiveDryRun = dryRun;
  Map<String, Object?>? previewData;
  final previewToken = dryRun
      ? await ApkMutationPreviewService.issue(
          operation: LocalToolNames.soPatchIntoApk,
          path: path,
          args: resolvedArgs,
        )
      : args['previewToken']?.toString();
  final applyArguments = previewToken == null
      ? null
      : _previewApplyArguments(
          resolvedArgs,
          path: path,
          previewToken: previewToken,
        );
  if (dryRun && args['applyAfterPreview'] == true && _previewCanApply(result)) {
    previewData = result.data?.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    result = await runPatch(false);
    effectiveDryRun = false;
  }
  var encoded = await _encodeApkMutationResult(
    result,
    sourcePath: path,
    operation: LocalToolNames.soPatchIntoApk,
    dryRun: effectiveDryRun,
    nextStep: effectiveDryRun
        ? '以上为预览。确认后以 confirm=true 执行（可传 sign=true 一步出签名包）。'
        : null,
    previewToken: previewToken,
  );
  encoded = _withPreviewFlow(
    encoded,
    applyArguments: applyArguments,
    previewData: previewData,
    appliedAfterPreview: previewData != null && result.ok,
    autoApplyBlocked:
        dryRun && args['applyAfterPreview'] == true && previewData == null,
  );
  // sign=true 链式签名：中间包签名 → 登记签名成品（自动清理同源中间包）。
  // 输出名去套娃：剥掉累积的 _signed/_structural 等中间尾缀后统一加
  // _signed，最终名稳定为「源名_signed」（覆盖旧成品，不产生
  // _signed_structural_signed 链）。
  if (!effectiveDryRun && args['sign'] == true && result.ok) {
    final output = result.data?['outputPath']?.toString() ?? '';
    if (output.isNotEmpty) {
      final signedDir = File(output).parent.path;
      final stem = _artifactBaseStem(output);
      final signedPath = p.join(
        signedDir,
        '${stem.isEmpty ? 'app' : stem}_成品.apk',
      );
      final signed = await ApkToolchainService.apkSign(
        inputApk: output,
        outputApk: signedPath,
      );
      if (signed.ok) {
        final cleaned = await ApkWorkspaceBindingService.recordSignedBuild(
          source: output,
          output: signedPath,
        );
        final map = jsonDecode(encoded) as Map<String, dynamic>;
        map['signedPath'] = signedPath;
        _markApkAwaitingVerification(map);
        // 目录净化：补丁 so 已写入签名 APK，使命完成即删，
        // 工作目录只留源包与签名成品（patch-report 含 SHA 可追溯）。
        final soFile = File(soPath);
        if (await soFile.exists()) {
          await soFile.delete();
          map['autoCleanedPaths'] = [
            ...((map['autoCleanedPaths'] as List?) ?? const <String>[]),
            soPath,
          ];
        }
        if (cleaned.isNotEmpty) {
          map['autoCleanedPaths'] = [
            ...((map['autoCleanedPaths'] as List?) ?? const <String>[]),
            ...cleaned,
          ];
        }
        encoded = jsonEncode(map);
      } else {
        final map = jsonDecode(encoded) as Map<String, dynamic>;
        map['signError'] = signed.message ?? signed.error ?? 'sign_failed';
        encoded = jsonEncode(map);
      }
    }
  }
  if (autoResolved) {
    final map = jsonDecode(encoded) as Map<String, dynamic>;
    map['autoResolvedEntry'] = entryName;
    encoded = jsonEncode(map);
  }
  return encoded;
}

String _withPreviewFlow(
  String encoded, {
  Map<String, dynamic>? applyArguments,
  Map<String, Object?>? previewData,
  bool appliedAfterPreview = false,
  bool autoApplyBlocked = false,
}) {
  final decoded = jsonDecode(encoded);
  if (decoded is! Map) return encoded;
  final payload = decoded.map((key, value) => MapEntry(key.toString(), value));
  if (applyArguments != null &&
      (!appliedAfterPreview || payload['ok'] != true)) {
    payload['applyArguments'] = applyArguments;
  }
  if (previewData != null) payload['preview'] = previewData;
  if (appliedAfterPreview) payload['appliedAfterPreview'] = true;
  if (autoApplyBlocked) {
    payload['autoApplyBlocked'] = true;
    payload['nextStep'] = '预览包含 warning 或明确无变更，未自动写入。核对预览后修正目标，不要重复相同 dryRun。';
  }
  return jsonEncode(payload);
}

Future<String> _encodeApkMutationResult(
  ApkStructuralResult result, {
  required String sourcePath,
  required String operation,
  required bool dryRun,
  String? nextStep,
  String? previewToken,
  List<String> modifiedLocators = const <String>[],
}) async {
  final data = <String, dynamic>{
    for (final entry in (result.data ?? const <Object?, Object?>{}).entries)
      entry.key.toString(): entry.value,
  };
  final output = data['outputPath']?.toString();
  final autoCleaned =
      !dryRun && result.ok && output != null && output.isNotEmpty
      ? await ApkWorkspaceBindingService.recordPatchArtifact(
          source: sourcePath,
          output: output,
          operation: operation,
          locators: modifiedLocators,
          evidence: _patchNoteEvidence(data),
        )
      : const <String>[];
  // 写操作成功后，基于旧 APK 的全部预览失效，避免不同操作从旧产物分叉。
  final invalidatedTokens = !dryRun && result.ok
      ? await ApkMutationPreviewService.invalidateArtifact(sourcePath)
      : const <String>[];
  return jsonEncode({
    'ok': result.ok,
    'dryRun': dryRun,
    // 目标透明化：明确本次基于哪个 APK 输出，防止连续修改链中
    // 默认目标漂移（如已切到签名包）被误当作「没生效」。
    'basedOnApk': sourcePath,
    if (!result.ok) 'error': result.error,
    'message': result.message,
    'data': data,
    if (output != null && output.isNotEmpty) 'nextInputPath': output,
    if (autoCleaned.isNotEmpty) 'autoCleanedPaths': autoCleaned,
    if (!dryRun && result.ok) 'memoryState': 'staged_until_user_verification',
    if (previewToken != null && (dryRun || !result.ok))
      'previewToken': previewToken,
    if (previewToken != null && !dryRun && !result.ok)
      'previewTokenReusable': true,
    if (invalidatedTokens.isNotEmpty) ...{
      'invalidatedTokens': invalidatedTokens,
      'invalidatedTokenNote':
          '本次写操作已执行，上述未消费的 previewToken 全部失效，'
          '继续修改必须以 nextInputPath 为输入，不得回到旧 APK 或复用旧 token',
    },
    if (nextStep != null) 'nextStep': nextStep,
  });
}

List<String> _patchDexLocators(Map<String, dynamic> args) {
  final locators = <String>{};
  for (final key in [
    'voidMethods',
    'trueMethods',
    'falseMethods',
    'classMethods',
  ]) {
    for (final value in _stringList(args[key])) {
      if (value.startsWith('L') && value.contains('->')) locators.add(value);
    }
  }
  return locators.toList(growable: false);
}

Map<String, dynamic> _patchNoteEvidence(Map<String, dynamic> data) {
  final evidence = <String, dynamic>{};
  void take(String key) {
    final value = data[key];
    if (value is num && value > 0) evidence[key] = value;
    if (value is List && value.isNotEmpty) evidence[key] = value.length;
  }

  for (final key in [
    'voidMethods',
    'trueMethods',
    'falseMethods',
    'nopLoadLibrary',
    'timeMethods',
    'classMethods',
    'modifiedDexFiles',
    'removedPermissions',
    'removedComponents',
    'deletedCount',
    'resSuspectedCount',
  ]) {
    take(key);
  }
  final signatureBypass = data['signatureBypass'];
  if (signatureBypass is Map && signatureBypass.isNotEmpty) {
    evidence['signatureBypass'] = {
      'mode': signatureBypass['mode'],
      'alreadyInjected': signatureBypass['alreadyInjected'],
      'usesEmbeddedOriginalApk': signatureBypass['usesEmbeddedOriginalApk'],
    };
  }
  return evidence;
}

List<String> _stringList(Object? value) => switch (value) {
  final List list => list.map((item) => item.toString()).toList(),
  final String text when text.trim().isNotEmpty => <String>[text.trim()],
  _ => const [],
};

Future<String> _handleClipboardTool(Map<String, dynamic> args) async {
  final action = (args['action'] ?? '').toString();
  switch (action) {
    case 'read':
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return jsonEncode({'text': data?.text ?? ''});
    case 'write':
      final text = args['text']?.toString();
      if (text == null) {
        throw ArgumentError('text is required for clipboard write');
      }
      await Clipboard.setData(ClipboardData(text: text));
      return jsonEncode({'success': true, 'text': text});
    default:
      throw ArgumentError('unknown clipboard action: $action');
  }
}

Future<String> _handleTextToSpeechTool(
  Map<String, dynamic> args,
  TextToSpeechStarter? onSpeakText,
) async {
  final text = args['text']?.toString().trim();
  if (text == null || text.isEmpty) {
    throw ArgumentError('text is required for text_to_speech');
  }
  if (onSpeakText == null) {
    throw StateError('text-to-speech executor is unavailable');
  }
  await onSpeakText(text);
  return jsonEncode({'success': true});
}

Map<String, dynamic> _buildTimeInfoPayload(DateTime now) {
  final offset = now.timeZoneOffset;
  final offsetSign = offset.isNegative ? '-' : '+';
  final offsetAbs = offset.abs();
  final offsetHours = offsetAbs.inHours.toString().padLeft(2, '0');
  final offsetMinutes = (offsetAbs.inMinutes % 60).toString().padLeft(2, '0');

  final year = now.year.toString().padLeft(4, '0');
  final month = now.month.toString().padLeft(2, '0');
  final day = now.day.toString().padLeft(2, '0');
  final hour = now.hour.toString().padLeft(2, '0');
  final minute = now.minute.toString().padLeft(2, '0');
  final second = now.second.toString().padLeft(2, '0');
  final weekdayEn = _englishWeekdayName(now.weekday);

  return <String, dynamic>{
    'year': now.year,
    'month': now.month,
    'day': now.day,
    'weekday': weekdayEn,
    'weekday_en': weekdayEn,
    'weekday_index': now.weekday,
    'date': '$year-$month-$day',
    'time': '$hour:$minute:$second',
    'datetime': now.toIso8601String(),
    'timezone': now.timeZoneName,
    'utc_offset': '$offsetSign$offsetHours:$offsetMinutes',
    'timestamp_ms': now.millisecondsSinceEpoch,
  };
}

String _englishWeekdayName(int weekday) {
  return switch (weekday) {
    DateTime.monday => 'Monday',
    DateTime.tuesday => 'Tuesday',
    DateTime.wednesday => 'Wednesday',
    DateTime.thursday => 'Thursday',
    DateTime.friday => 'Friday',
    DateTime.saturday => 'Saturday',
    DateTime.sunday => 'Sunday',
    _ => 'Unknown',
  };
}

const MethodChannel _deviceToolsChannel = DeviceLocalTools._channel;

String _deviceTimezoneHint() {
  final now = DateTime.now();
  final offset = now.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final abs = offset.abs();
  final hh = abs.inHours.toString().padLeft(2, '0');
  final mm = (abs.inMinutes % 60).toString().padLeft(2, '0');
  return "The device timezone is '${now.timeZoneName}' (UTC offset $sign$hh:$mm); "
      'times without an explicit offset are interpreted in this timezone.';
}

/// Invokes a native device tool over the MethodChannel. The native side
/// returns a JSON string payload (including structured error payloads that
/// the model can act on, e.g. missing permissions).
Future<String> _invokeDeviceTool(
  String method,
  Map<String, dynamic> args,
) async {
  try {
    final result = await _deviceToolsChannel.invokeMethod<String>(
      method,
      jsonEncode(args),
    );
    if (result == null || result.isEmpty) {
      return jsonEncode({
        'error': 'no_result',
        'message': 'The device tool returned no result.',
      });
    }
    return result;
  } on MissingPluginException {
    return jsonEncode({
      'error': 'unsupported_platform',
      'message': 'This tool is not available on the current platform.',
    });
  } on PlatformException catch (e) {
    return jsonEncode({
      'error': e.code,
      'message': e.message ?? 'The device tool failed.',
    });
  }
}

String _handleCalculateTool(Map<String, dynamic> args) {
  final expression = (args['expression'] ?? '').toString().trim();
  if (expression.isEmpty) {
    return jsonEncode({
      'error': 'empty_expression',
      'message':
          'Expression is empty. Please provide a mathematical expression in standard notation, e.g. "(15 + 3) * 2".',
    });
  }

  try {
    final parsed = GrammarParser().parse(expression);
    final result = parsed.evaluate(EvaluationType.REAL, ContextModel());
    if (!result.isFinite) {
      return jsonEncode({
        'error': 'math_error',
        'message':
            'The result is not a finite number. Please check your expression (e.g. division by zero).',
      });
    }
    return jsonEncode({'expression': expression, 'result': result.toString()});
  } catch (e) {
    return jsonEncode({
      'error': 'parse_error',
      'message':
          'Could not parse the expression. Use standard notation, e.g. "(15 + 3) * 2".',
      'detail': e.toString(),
    });
  }
}

// ===== M1: 玄星逆核工具链处理 =====

/// 新工具路径解析：优先显式参数（path/apkPath），绝对路径原样、相对路径
/// join 工作目录；未传回退 activeApkPath（连续修改产物）。
Future<(String?, String?)> _resolveToolchainPath(
  Map<String, dynamic> args,
) async {
  // 统一路径解析：与 _resolveLocalApkPath 同一实现（apkPath/path 参数语义一致）
  return _resolveLocalApkPath(args, null);
}

String _encodeToolResult(ApkStructuralResult r) => jsonEncode(
  r.data ??
      {
        'ok': r.ok,
        if (r.error != null) 'error': r.error,
        'message': r.message ?? (r.ok ? 'ok' : '调用失败'),
      },
);

Future<String> _handleJadxDecompile(Map<String, dynamic> args) async {
  final (path, err) = await _resolveToolchainPath(args);
  if (path == null) {
    return jsonEncode({'ok': false, 'error': 'invalid_args', 'message': err});
  }
  final workDir = await ApkWorkspaceBindingService.workDir();
  if (workDir == null || workDir.trim().isEmpty) {
    return jsonEncode({
      'ok': false,
      'error': 'work_dir_required',
      'message': '请先设置工作目录，反编译产物只会写入工作目录。',
    });
  }
  final r = await ApkToolchainService.jadxDecompile(
    path: path,
    action: (args['action'] ?? 'save').toString(),
    className: (args['className'] ?? '').toString(),
    dexName: (args['dexName'] ?? '').toString(),
    limit: (args['limit'] as num?)?.toInt(),
    offset: (args['offset'] as num?)?.toInt(),
    workDir: workDir,
  );
  return _encodeToolResult(r);
}

String _artifactBaseStem(String path) {
  final source = File(path);
  final stem = p.basenameWithoutExtension(path);
  final match = RegExp(r'^(.*)_v\d+$', caseSensitive: false).firstMatch(stem);
  final previous = match?.group(1) ?? '';
  return previous.isNotEmpty && File(p.join(source.parent.path, '$previous.apk')).existsSync()
      ? previous
      : stem;
}

Future<String> _handleApkSign(Map<String, dynamic> args) async {
  // 防呆（真机实测教训）：无 apkPath 的 apk_sign 会落到「当前活动产物」——
  // 若那已是签名成品（*_成品.apk），探测性调用会重复签名出垃圾产物。
  // 隐式目标且看起来已签名时，要求显式 apkPath 或 confirm=true；
  // 正常链路（patch 产物 _dexpatch.apk 等）不受影响。
  final explicitPath = (args['apkPath'] ?? args['path'] ?? '')
      .toString()
      .trim()
      .isNotEmpty;
  if (!explicitPath && (args['confirm'] != true)) {
    final (probed, _) = await _resolveToolchainPath(const {});
    if (probed != null &&
        (p.basename(probed).endsWith('_成品.apk') ||
            p.basename(probed).toLowerCase().endsWith('_signed.apk'))) {
      return jsonEncode({
        'ok': false,
        'error': 'already_signed_confirm_required',
        'message':
            '未传 apkPath 时解析到的目标已是签名成品：$probed。重复签名只会产生冗余产物。'
            '如确需重签：显式传 apkPath；或对本目标传 confirm=true。',
        'recoverable': true,
        'resolvedTarget': probed,
      });
    }
  }
  final (path, err) = await _resolveToolchainPath(args);
  if (path == null) {
    return jsonEncode({'ok': false, 'error': 'invalid_args', 'message': err});
  }
  final workDir = await ApkWorkspaceBindingService.workDir();
  if (workDir == null || workDir.trim().isEmpty) {
    return jsonEncode({
      'ok': false,
      'error': 'work_dir_required',
      'message': '请先设置工作目录，签名产物只会写入工作目录。',
    });
  }
  final requestedOutput = (args['outputApk'] ?? '').toString().trim();
  final outputApk = requestedOutput.isEmpty
      ? p.join(workDir, '${_artifactBaseStem(path)}_成品.apk')
      : requestedOutput;
  if (requestedOutput.isEmpty) {
    await Directory(p.dirname(outputApk)).create(recursive: true);
  }
  final r = await ApkToolchainService.apkSign(
    inputApk: path,
    outputApk: outputApk,
    minSdk: (args['minSdk'] as num?)?.toInt(),
  );
  if (!r.ok) return _encodeToolResult(r);
  // P1-8 成品即净：登记签名产物并自动清理同源未签名中间包，
  // 使产物列表与验证记录能读取内置签名产物。
  final data = <String, dynamic>{
    for (final entry in (r.data ?? const <Object?, Object?>{}).entries)
      entry.key.toString(): entry.value,
  };
  final output = data['outputApk']?.toString() ?? '';
  if (output.isNotEmpty) {
    final cleaned = await ApkWorkspaceBindingService.recordSignedBuild(
      source: path,
      output: output,
    );
    // 一级自动清理（改完即清，免确认）：成品落地后删除工作区内全部
    // 生成型中间包（_dexpatch/_structural/_manifest/_assets/_abi/_signed
    // 旧成品等），保留原包、当前成品、分析目录。修改无效时上一版成品
    // 即下一轮基底——这里绝不动基底与当前成品。
    final intermediateCleaned =
        await ApkWorkspaceBindingService.cleanupIntermediateArtifacts(
          outputPath: output,
        );
    final allCleaned = {...cleaned, ...intermediateCleaned}.toList();
    if (cleaned.isNotEmpty) {
      data['autoCleanedPaths'] = allCleaned;
      data['autoCleanNote'] = '中间包与同源未签名产物已自动清理（成品即净）';
    }
    _markApkAwaitingVerification(data);
  }
  return jsonEncode(data);
}

Future<String> _handleApkRebuild(Map<String, dynamic> args) async {
  final workDir = await ApkWorkspaceBindingService.workDir();
  if (workDir == null || workDir.trim().isEmpty) {
    return jsonEncode({
      'ok': false,
      'error': 'work_dir_required',
      'message': '请先设置工作目录，重建产物只会写入工作目录。',
    });
  }
  final action = (args['action'] ?? 'decode').toString();
  final (path, err) = action == 'build'
      ? await _resolveDecodedApkDirectory(args, workDir)
      : await _resolveToolchainPath(args);
  if (path == null) {
    return jsonEncode({'ok': false, 'error': 'invalid_args', 'message': err});
  }
  final r = await ApkToolchainService.apkRebuild(
    path: path,
    action: action,
    output: (args['output'] ?? '').toString(),
    type: (args['type'] ?? '').toString(),
    dex: args['dex'] as bool?,
    force: args['force'] as bool?,
    cleanMeta: args['cleanMeta'] as bool?,
    fixTypeNames: args['fixTypeNames'] as bool?,
    workDir: workDir,
  );
  return _encodeToolResult(r);
}

Future<(String?, String?)> _resolveDecodedApkDirectory(
  Map<String, dynamic> args,
  String workDir,
) async {
  final raw = (args['path'] ?? '').toString().trim();
  if (raw.isEmpty) {
    return (null, 'build 的 path 必须是工作目录内的解码目录。');
  }
  final candidate = raw.startsWith('/') || raw.contains(':')
      ? _guardInsideWorkDir(workDir, raw)
      : _guardInsideWorkDir(workDir, p.join(workDir, raw));
  if (candidate == null) {
    return (null, '路径越界：build 的解码目录必须位于工作目录内。');
  }
  if (!await Directory(candidate).exists()) {
    return (null, '解码目录不存在: $candidate。先调用 apk_rebuild(action=decode)。');
  }
  return (candidate, null);
}

Future<String> _handleDexSearch(Map<String, dynamic> args) async {
  final (path, err) = await _resolveToolchainPath(args);
  if (path == null) {
    return jsonEncode({'ok': false, 'error': 'invalid_args', 'message': err});
  }
  List<String>? stringTerms(String key) {
    final value = args[key];
    if (value is! List) return null;
    final terms = value
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    return terms.isEmpty ? null : terms;
  }

  final keyword = (args['keyword'] ?? '').toString().trim();
  final numbers = (args['numbers'] as List?)?.whereType<num>().toList(
    growable: false,
  );
  final className = (args['className'] ?? '').toString().trim();
  final methodName = (args['methodName'] ?? '').toString().trim();
  final fieldNames = stringTerms('fieldNames');
  final invokedMethodNames = stringTerms('invokedMethodNames');
  final opNames = stringTerms('opNames');
  if (keyword.isEmpty &&
      (numbers == null || numbers.isEmpty) &&
      className.isEmpty &&
      methodName.isEmpty &&
      fieldNames == null &&
      invokedMethodNames == null &&
      opNames == null) {
    return jsonEncode({
      'ok': false,
      'error': 'invalid_args',
      'message': '至少提供一种类、方法、字段、字符串、数字或指令线索',
    });
  }
  final r = await ApkToolchainService.dexSearch(
    path: path,
    keyword: keyword,
    numbers: numbers,
    className: className,
    methodName: methodName,
    fieldNames: fieldNames,
    invokedMethodNames: invokedMethodNames,
    opNames: opNames,
    action: (args['action'] ?? 'auto').toString(),
    matchType: (args['matchType'] ?? 'Contains').toString(),
    ignoreCase: args['ignoreCase'] as bool? ?? false,
    packagePrefix: (args['packagePrefix'] ?? '').toString(),
    limit: (args['limit'] as num?)?.toInt(),
  );
  return _encodeToolResult(r);
}

Future<String> _handleStringScan(Map<String, dynamic> args) async {
  final (path, err) = await _resolveToolchainPath(args);
  if (path == null) {
    return jsonEncode({'ok': false, 'error': 'invalid_args', 'message': err});
  }
  final r = await ApkToolchainService.stringScan(
    path: path,
    category: (args['category'] ?? 'all').toString(),
    minLen: (args['minLen'] as num?)?.toInt(),
    limit: (args['limit'] as num?)?.toInt(),
    includePrivate: args['includePrivate'] as bool?,
  );
  return _encodeToolResult(r);
}

Future<String> _handleApkArchive(Map<String, dynamic> args) async {
  final (path, err) = await _resolveToolchainPath(args);
  if (path == null) {
    return jsonEncode({'ok': false, 'error': 'invalid_args', 'message': err});
  }
  final r = await ApkToolchainService.apkArchive(
    path: path,
    action: (args['action'] ?? 'list').toString(),
    query: (args['query'] ?? '').toString(),
    entry: (args['entry'] ?? '').toString(),
    offset: (args['offset'] as num?)?.toInt(),
    limit: (args['limit'] as num?)?.toInt(),
    minLen: (args['minLen'] as num?)?.toInt(),
  );
  return _encodeToolResult(r);
}

Future<String> _handleApkExportReport(
  Map<String, dynamic> args,
  ToolContext context,
) async {
  final report = await ApkWorkspaceService.readReport(
    conversationId: context.conversationId,
  );
  if (report == null) {
    return jsonEncode({
      'ok': false,
      'error': 'report_not_ready',
      'message': '当前没有可导出的 APK 分析报告，请先完成分析。',
    });
  }
  final freshness = await ApkWorkspaceService.reportFreshnessOf(report);
  if (freshness['status'] == 'stale') {
    return jsonEncode({
      'ok': false,
      'error': 'stale_report',
      'message': '当前报告已失效，请重新分析后再导出。',
    });
  }
  final workDir = await ApkWorkspaceBindingService.workDir();
  if (workDir == null || workDir.isEmpty) {
    return jsonEncode({
      'ok': false,
      'error': 'work_dir_required',
      'message': '请先设置工作目录，报告会保存到该目录。',
    });
  }
  final requested = (args['fileName'] ?? '').toString().trim();
  if (requested.isNotEmpty &&
      (p.basename(requested) != requested || !requested.endsWith('.json'))) {
    return jsonEncode({
      'ok': false,
      'error': 'invalid_file_name',
      'message': 'fileName 只能是工作目录中的 .json 文件名。',
    });
  }
  final stem = p.basenameWithoutExtension(
    (report['fileName'] ?? 'apk').toString(),
  );
  final name = requested.isEmpty
      ? '${stem}_analysis_${DateTime.now().millisecondsSinceEpoch}.json'
      : requested;
  final output = File(p.join(workDir, name));
  await output.writeAsString(jsonEncode(report));
  await ApkWorkspaceBindingService.recordFileArtifact(
    path: output.path,
    operation: 'apk_report_export',
    source: (report['sourceApk'] as Map?)?['path']?.toString(),
    metadata: {'analysisVersion': report['analysisVersion']},
  );
  return jsonEncode({
    'ok': true,
    'outputPath': output.path,
    'bytes': await output.length(),
    'message': '当前 APK 分析报告已导出。',
  });
}

Future<String> _handleDexXref(
  Map<String, dynamic> args,
  ChatService? chatService,
) async {
  final (path, pathError) = await _resolveLocalApkPath(args, chatService);
  if (pathError != null) {
    return jsonEncode({
      'ok': false,
      'error': 'invalid_apk_path',
      'message': pathError,
    });
  }
  if (path == null || path.isEmpty) {
    return jsonEncode({
      'ok': false,
      'error': 'invalid_args',
      'message':
          '需要本地 APK 才能查调用图。请先 analyze_apk_workspace 分析目标，或传 path 指定 APK。',
    });
  }
  var target = (args['target'] ?? args['locator'] ?? '').toString().trim();
  // 兼容旧 dex_method: 前缀定位符——引擎直接消费 qualifiedId（R4 同源格式）
  final prefixIdx = target.indexOf('dex_method:');
  if (prefixIdx != -1) {
    target = target.substring(prefixIdx + 'dex_method:'.length).trim();
  }
  if (target.isEmpty) {
    return jsonEncode({
      'ok': false,
      'error': 'invalid_args',
      'message': '缺少 target(qualifiedId)',
    });
  }
  if (target.startsWith('dex_field:')) {
    target = target.substring('dex_field:'.length).trim();
    final fieldResult = await ApkToolchainService.fieldXref(
      path: path,
      fieldTarget: target,
      offset: (args['offset'] as num?)?.toInt(),
      limit: (args['limit'] as num?)?.toInt(),
    );
    if (!fieldResult.ok) {
      return jsonEncode({
        'ok': false,
        'error': fieldResult.error ?? 'field_xref_failed',
        'message': fieldResult.message ?? '字段引用查询失败',
        'recoverable': true,
      });
    }
    final data = <String, dynamic>{
      for (final entry
          in (fieldResult.data ?? const <Object?, Object?>{}).entries)
        entry.key.toString(): entry.value,
      'sourceApk': path,
      'note': '字段引用覆盖 iget/iput/sget/sput；每项 method 可直接传给 smali_read。',
    };
    return jsonEncode(data);
  }
  final classPrefix = (args['classPrefix'] ?? args['callerPrefix'] ?? '')
      .toString()
      .trim();
  final r = await ApkToolchainService.dexXref(
    path: path,
    target: target,
    direction: (args['direction'] ?? 'to').toString(),
    classPrefix: classPrefix,
    offset: (args['offset'] as num?)?.toInt() ?? 0,
    limit: (args['limit'] as num?)?.toInt(),
    callSiteOffset: (args['callSiteOffset'] as num?)?.toInt() ?? 0,
    callSiteLimit: (args['callSiteLimit'] as num?)?.toInt(),
  );
  if (!r.ok) {
    return jsonEncode({
      'ok': false,
      'error': r.error ?? 'xref_failed',
      'message': r.message ?? '调用图查询失败',
      'recoverable': true,
    });
  }
  final data = <String, dynamic>{
    for (final entry in (r.data ?? const <Object?, Object?>{}).entries)
      entry.key.toString(): entry.value,
  };
  data['sourceApk'] = path;
  data['note'] =
      '跨全部 dex 聚合；每项 qualifiedId 可直接传给 smali_read。'
      'directCallers=精确调用点；dispatchCandidates=invoke-virtual 分派候选'
      '（实际执行可能经子类分派，需 class_outline 确认）';
  return jsonEncode(data);
}

Future<String> _handleClassOutline(Map<String, dynamic> args) async {
  final runtime = (args['runtime'] ?? 'dex').toString().toLowerCase();
  final className = (args['className'] ?? '').toString().trim();
  if (className.isEmpty) {
    return jsonEncode({
      'ok': false,
      'error': 'invalid_args',
      'message': '缺少 className',
    });
  }
  if (runtime == 'dart') {
    final jobId = (args['jobId'] ?? '').toString().trim();
    if (jobId.isEmpty) {
      return jsonEncode({
        'ok': false,
        'error': 'blutter_job_required',
        'message': 'Dart 类查询需要当前 APK 的 Blutter jobId。先 analyze，再传其 jobId。',
      });
    }
    final r = await ApkToolchainService.soAnalyze({
      'action': 'blutter',
      'blutterAction': 'search',
      'jobId': jobId,
      'query': className,
      'scope': 'asm',
      'includePath': className,
      'limit': (args['limit'] as num?)?.toInt() ?? 50,
    });
    return _encodeToolResult(r);
  }
  if (runtime != 'dex') {
    return jsonEncode({
      'ok': false,
      'error': 'invalid_runtime',
      'message': 'runtime 只支持 dex 或 dart。',
    });
  }
  if (!className.contains(RegExp(r'[./;$]')) && className.length <= 2) {
    return jsonEncode({
      'ok': false,
      'error': 'ambiguous_short_class',
      'message':
          '两字符短类名无法区分 DEX 混淆类与 Dart 类，拒绝全 DEX 扫描以避免返回系统类噪音。Dart 请传 runtime:"dart" 和当前 Blutter jobId；DEX 请传完整类名。',
    });
  }
  final (path, err) = await _resolveToolchainPath(args);
  if (path == null) {
    return jsonEncode({'ok': false, 'error': 'invalid_args', 'message': err});
  }
  final r = await ApkToolchainService.classOutline(
    path: path,
    className: className,
    offset: (args['offset'] as num?)?.toInt() ?? 0,
    limit: (args['limit'] as num?)?.toInt(),
  );
  return _encodeToolResult(r);
}

// ===== M3/M5: SO 引擎 + root 工具处理 =====

Future<String> _handleSoAnalyze(Map<String, dynamic> args) async {
  final requestedAction = (args['action'] ?? 'open').toString();
  const actionAliases = <String, String>{
    'xrefs': 'rz_xrefs',
    'functions': 'rz_functions',
    'decompile': 'rz_decompile',
  };
  final action = actionAliases[requestedAction] ?? requestedAction;
  if (action != requestedAction) args['action'] = action;
  final detachedBlutterAnalyzeWait =
      action == 'blutter' &&
      args['blutterAction'] == 'analyze' &&
      args['wait'] == true;
  if (detachedBlutterAnalyzeWait) args['wait'] = false;
  // 路径路由修复：open/analyze_apk/blutter 的 path 支持相对路径（相对工作
  // 目录）与文件名（工作区文件），与 APK 工具链的路径语义对齐；
  // P0-A 铁律：绝对路径必须位于统一工作目录内（apk:xxx 内部格式除外）。
  const autoOpenFromPathActions = {
    'read_elf',
    'read_stats',
    'disasm',
    'hexdump',
    'strings',
    'search',
    'list',
    'overview',
    'analysis_report',
    'rz_analyze',
    'rz_functions',
    'rz_xrefs',
    'rz_decompile',
    'rz_crypto',
    'rz_cfg',
    'rz_esil',
    'rz_search_bytes',
    'rz_command',
  };
  final pathRoutedActions = {
    'open',
    'analyze_apk',
    'blutter',
    ...autoOpenFromPathActions,
  };
  if (pathRoutedActions.contains(action) && args['path'] != null) {
    final raw = args['path'].toString().trim();
    if (raw.isNotEmpty && !raw.startsWith('apk:')) {
      final dir = await ApkWorkspaceBindingService.workDir();
      if (dir == null || dir.isEmpty) {
        return jsonEncode(const {
          'ok': false,
          'error': 'workspace_not_set',
          'message': '工作目录未设置：请先在 APK 工作台设置统一工作目录',
        });
      }
      if (raw.startsWith('/') || raw.contains(':')) {
        final guarded = _guardInsideWorkDir(dir, raw);
        if (guarded == null) {
          return jsonEncode(_pathOutsideWorkspace(raw, dir));
        }
        args['path'] = guarded;
      } else {
        args['path'] = p.join(dir, raw);
      }
    }
  }
  // 统一工作路径：每个 action 前把 APK 工作目录同步给 SO 引擎，
  // 保证工作目录内的 .so/.apk 可被 so_analyze 识别（免 SAF，path 模式）。
  // native setWorkDirectoryPath 同路径幂等短路，无额外开销；
  // 不只 open/analyze_apk — list_sources/suggest 等也依赖工作目录。
  {
    final dir = await ApkWorkspaceBindingService.workDir();
    if (dir != null &&
        dir.isNotEmpty &&
        LocalToolsService._lastSyncedSoWorkDir != dir) {
      try {
        final sync = await ApkToolchainService.soAnalyze(<String, Object?>{
          'action': 'set_work_dir',
          'path': dir,
        });
        if (sync.ok) LocalToolsService._lastSyncedSoWorkDir = dir;
      } catch (_) {
        // 同步失败不阻塞主调用（引擎可能未就绪）
      }
    }
  }
  if (autoOpenFromPathActions.contains(action) &&
      (args['workspaceId']?.toString().trim().isEmpty ?? true) &&
      (args['path']?.toString().trim().isNotEmpty ?? false)) {
    final opened = await ApkToolchainService.soAnalyze(<String, Object?>{
      'action': 'open',
      'path': args['path']?.toString(),
      'temporary': true,
    });
    final workspaceId = opened.data?['workspaceId']?.toString() ?? '';
    if (!opened.ok || workspaceId.isEmpty) {
      final data = opened.data ?? <String, Object?>{};
      return jsonEncode({
        ...data,
        'ok': false,
        'error': data['error'] ?? 'workspace_open_failed',
        'message': data['message'] ?? '无法从 path 打开分析工作区',
      });
    }
    args['workspaceId'] = workspaceId;
  }
  const editActions = {'edit_hex', 'edit_asm', 'edit_symbol'};
  final previewRequested = args['dryRun'] == true;
  final applyAfterPreview = args['applyAfterPreview'] == true;
  final aotRawConstantRisk =
      editActions.contains(action) &&
      args['overrideAotObjectSafety'] != true &&
      await _hasUnsafeDartAotRawConstant(args, action);
  if (aotRawConstantRisk && !previewRequested) {
    return jsonEncode({
      'ok': false,
      'error': 'UNSAFE_DART_AOT_RAW_CONSTANT',
      'message':
          '检测到 Flutter/Dart AOT 中手写 MOV 立即数。对象字段不能按普通整数直接写入；请改用 force_return_constant、已证明方向的分支修改，或先补齐真实字段读取与对象编码证据。',
    });
  }
  var r = await ApkToolchainService.soAnalyze(Map<String, Object?>.from(args));
  if (editActions.contains(action) && previewRequested && r.ok) {
    final preview = <String, Object?>{
      for (final entry in (r.data ?? const <String, Object?>{}).entries)
        entry.key.toString(): entry.value,
    };
    final targetVersion = preview['targetVersion']?.toString() ?? '';
    final previewCount = (preview['previewCount'] as num?)?.toInt() ?? 0;
    final applyArgs = <String, Object?>{
      ...Map<String, Object?>.from(args),
      'dryRun': false,
      'targetVersion': targetVersion,
    }..remove('applyAfterPreview');
    if (!aotRawConstantRisk &&
        applyAfterPreview &&
        targetVersion.isNotEmpty &&
        previewCount > 0) {
      final applied = await ApkToolchainService.soAnalyze(applyArgs);
      final appliedData = <String, Object?>{
        for (final entry in (applied.data ?? const <String, Object?>{}).entries)
          entry.key.toString(): entry.value,
        'ok': applied.ok,
        'preview': preview,
        'appliedAfterPreview': applied.ok,
        if (!applied.ok) 'applyArguments': applyArgs,
        if (!applied.ok && applied.error != null) 'error': applied.error,
        if (!applied.ok && applied.message != null) 'message': applied.message,
      };
      return jsonEncode(appliedData);
    }
    if (!aotRawConstantRisk) preview['applyArguments'] = applyArgs;
    if (aotRawConstantRisk) {
      preview['warning'] = {
        'type': 'unsafe_dart_aot_raw_constant',
        'message': '该预览把 Dart AOT 对象字段当原生立即数写入，可能导致登录或对象读取崩溃。',
      };
      preview['autoApplyBlocked'] = true;
      preview['nextStep'] =
          '回到字段读取者或业务条件分支验证。常量返回使用 force_return_constant；对象构造/JSON 解析函数只作字段来源证据，不作补丁目标。';
    } else if (applyAfterPreview) {
      preview['autoApplyBlocked'] = true;
      preview['nextStep'] =
          '预览没有可写入字节或缺少 targetVersion，未执行。修正定位或编辑参数，不要重复同一 dryRun。';
    }
    r = ApkStructuralResult(ok: r.ok, data: preview);
  }
  // Blutter wait=true 在终态、阶段变化或新心跳时立即返回，避免一次工具调用
  // 阻塞 90 秒而用户看不到任何反馈。Agent 可把本次进度告诉用户后继续续等。
  if (action == 'blutter' && args['wait'] == true) {
    r = await _waitBlutterJob(args, r);
  }
  final data = r.data ?? {'ok': r.ok, 'error': r.error, 'message': r.message};
  if (detachedBlutterAnalyzeWait &&
      r.ok &&
      data['status']?.toString() == 'running') {
    data['waitDetached'] = true;
    data['hint'] =
        '分析已在后台运行。立即向用户报告 jobId 和当前阶段,\n'
        '然后用同一 jobId 调用 status(wait=true),不要在单次 analyze 里静默等待。';
  }
  // T1: 记录最近一次 build 成功产物路径，so_patch_into_apk 缺省自动感知。
  if (data['ok'] == true) {
    if (action == 'build') {
      final out = data['outputPath']?.toString() ?? '';
      if (out.isNotEmpty) {
        final activeApk = await ApkWorkspaceBindingService.activeApkPath();
        ToolSessionState.lastBuiltSoPath = out;
        ToolSessionState.lastBuiltSoApkPath = activeApk;
        ToolSessionState.lastBuiltSoEntry = data['sourceEntry']?.toString();
        await ApkWorkspaceBindingService.recordFileArtifact(
          path: out,
          operation: 'so_build',
          source: activeApk,
          metadata: {
            if (data['sourceEntry'] != null) 'sourceEntry': data['sourceEntry'],
          },
        );
      }
    } else if (action == 'build_many') {
      final outputs = data['outputs'];
      if (outputs is List && outputs.isNotEmpty) {
        final last = outputs.last;
        if (last is Map) {
          final out = last['outputPath']?.toString() ?? '';
          if (out.isNotEmpty) {
            final activeApk = await ApkWorkspaceBindingService.activeApkPath();
            ToolSessionState.lastBuiltSoPath = out;
            ToolSessionState.lastBuiltSoApkPath = activeApk;
            ToolSessionState.lastBuiltSoEntry = last['sourceEntry']?.toString();
            await ApkWorkspaceBindingService.recordFileArtifact(
              path: out,
              operation: 'so_build',
              source: activeApk,
              metadata: {
                if (last['sourceEntry'] != null)
                  'sourceEntry': last['sourceEntry'],
              },
            );
          }
        }
      }
    }
  }
  // 成功打开的 SO 工作区无需审批；修改类 action 走 dryRun/confirm 链由提示词约束
  return jsonEncode(data);
}

Future<bool> _hasUnsafeDartAotRawConstant(
  Map<String, dynamic> args,
  String action,
) async {
  if (action != 'edit_hex' && action != 'edit_asm') return false;
  final report = await _readPatchMemoryReport();
  final path = (args['path'] ?? '').toString().replaceAll('\\', '/');
  final isAot =
      (report != null && ApkPatchMemoryService.reportLooksFlutter(report)) ||
      p.basename(path).toLowerCase() == 'libapp.so';
  if (!isAot) return false;

  final edits = <Map<String, dynamic>>[];
  final rawEdits = args['edits'];
  if (rawEdits is List) {
    for (final edit in rawEdits) {
      if (edit is Map) edits.add(Map<String, dynamic>.from(edit));
    }
  }
  if (edits.isEmpty) edits.add(args);
  if (action == 'edit_asm') {
    final rawMov = RegExp(
      r'\bmov[zk]?\s+[wx][0-9]+\s*,\s*#',
      caseSensitive: false,
    );
    return edits.any((edit) {
      final mode = (edit['mode'] ?? '').toString();
      if (const {
        'force_return_constant',
        'return_constant',
        'constant_return',
      }.contains(mode)) {
        return false;
      }
      final asm =
          (edit['writeAsm'] ??
                  edit['newAsm'] ??
                  edit['asm'] ??
                  edit['assembly'] ??
                  '')
              .toString();
      return rawMov.hasMatch(asm);
    });
  }
  return edits.any((edit) {
    final raw =
        (edit['newHex'] ??
                edit['hex'] ??
                edit['bytes'] ??
                edit['data'] ??
                edit['rawHex'] ??
                args['patchHex'] ??
                '')
            .toString();
    final cleaned = raw.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (cleaned.isEmpty || cleaned.length.isOdd) return false;
    final bytes = <int>[
      for (var i = 0; i < cleaned.length; i += 2)
        int.parse(cleaned.substring(i, i + 2), radix: 16),
    ];
    for (var i = 0; i + 3 < bytes.length; i += 4) {
      final word =
          bytes[i] |
          (bytes[i + 1] << 8) |
          (bytes[i + 2] << 16) |
          (bytes[i + 3] << 24);
      if ((word & 0x7f800000) == 0x52800000) return true;
    }
    return false;
  });
}

/// Blutter job 等待。每 2s 轮询；终态、阶段变化或新心跳任一发生就返回，
/// 让调用方能持续展示真实阶段和产物增长，不在单次 MCP 调用里静默等待。
Future<ApkStructuralResult> _waitBlutterJob(
  Map<String, dynamic> args,
  ApkStructuralResult initial,
) async {
  const terminal = {'succeeded', 'failed', 'cancelled', 'interrupted'};
  final timeoutMs = (((args['timeoutMs'] as num?)?.toInt()) ?? 90000).clamp(
    5000,
    90000,
  );
  final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));

  Map<String, Object?> dataOf(ApkStructuralResult r) =>
      r.data?.map((k, v) => MapEntry(k.toString(), v)) ?? const {};

  var data = dataOf(initial);
  var jobId = data['jobId']?.toString() ?? '';
  var current = initial;
  var fingerprint =
      '${data['updatedAt']}|${data['stage']}|${data['outputBytes']}|${data['outputFiles']}';
  while (jobId.isNotEmpty &&
      !terminal.contains(data['status']?.toString() ?? '') &&
      DateTime.now().isBefore(deadline)) {
    await Future.delayed(const Duration(seconds: 2));
    current = await ApkToolchainService.soAnalyze(<String, Object?>{
      'action': 'blutter',
      'blutterAction': 'status',
      'jobId': jobId,
    });
    data = dataOf(current);
    final nextFingerprint =
        '${data['updatedAt']}|${data['stage']}|${data['outputBytes']}|${data['outputFiles']}';
    if (!terminal.contains(data['status']?.toString() ?? '') &&
        nextFingerprint != fingerprint) {
      data['inProgress'] = true;
      data['hint'] =
          'Blutter 正在运行: ${data['stageLabel'] ?? data['stage']}, '
          '已耗时 ${data['elapsedMillis'] ?? 0}ms, '
          '已产生 ${data['outputFiles'] ?? 0} 个文件。可向用户报告后用同一 jobId 续等。';
      return ApkStructuralResult(ok: current.ok, data: data);
    }
    fingerprint = nextFingerprint;
  }
  if (jobId.isNotEmpty &&
      !terminal.contains(data['status']?.toString() ?? '')) {
    final stage = data['stage']?.toString() ?? data['status']?.toString() ?? '';
    data['waitTimeout'] = true;
    data['hint'] =
        'Blutter 仍在运行（stage=$stage），再次调用 so_analyze(action=blutter, '
        'blutterAction=status, jobId=$jobId, wait=true) 续等';
    current = ApkStructuralResult(ok: current.ok, data: data);
  }
  return current;
}

String? _guardInsideWorkDir(String workDir, String path) {
  String norm(String s) =>
      s.startsWith('/sdcard/') ? '/storage/emulated/0/${s.substring(8)}' : s;
  final d = norm(workDir);
  final v = norm(path);
  if (v == d || p.isWithin(d, v)) return v;
  return null;
}

/// 越界/未设置错误信封（file_* 与 apk/so 工具链共用同一套错误码）。
Map<String, dynamic> _pathOutsideWorkspace(String path, String workDir) => {
  'ok': false,
  'error': 'PATH_OUTSIDE_WORKSPACE',
  'message':
      '路径越界（$path）：所有读写必须限制在统一工作目录内（$workDir）。'
      '外部文件请先用 file(action=copy) 复制进工作目录，再使用工作目录内路径。',
};

/// 统一路径：相对路径/文件名 join 工作目录；绝对路径仅允许工作目录内
/// 子路径（P0-A 铁律）。返回 (path, error)，二者互斥。
Future<(String?, Map<String, dynamic>?)> _resolveFileOpsPath(
  Map<String, dynamic> args,
) async {
  final raw = (args['path'] ?? '').toString().trim();
  if (raw.isEmpty) {
    return (
      null,
      const {'ok': false, 'error': 'invalid_path', 'message': 'path 缺失或为空'},
    );
  }
  final dir = await ApkWorkspaceBindingService.workDir();
  if (dir == null || dir.isEmpty) {
    return (
      null,
      const {
        'ok': false,
        'error': 'workspace_not_set',
        'message': '工作目录未设置：请先在 APK 工作台设置统一工作目录',
      },
    );
  }
  if (raw.startsWith('/') || raw.contains(':')) {
    final guarded = _guardInsideWorkDir(dir, raw);
    if (guarded == null) return (null, _pathOutsideWorkspace(raw, dir));
    return (guarded, null);
  }
  if (raw.split('/').contains('..') || raw.split(r'\').contains('..')) {
    return (
      null,
      const {'ok': false, 'error': 'invalid_path', 'message': 'path 含 .. 已拒绝'},
    );
  }
  return (p.join(dir, raw), null);
}

/// 统一文件操作入口：action ∈ {inventory,read,write,list,info,delete,copy,rename,zip,unzip,grep,replace,strings}。
/// 复用既有 9 个原子 handler，Agent 只记一个 file 工具。
Future<String> _handleFileUnified(Map<String, dynamic> args) async {
  final action = (args['action'] ?? '').toString().trim();
  switch (action) {
    case 'inventory':
      return _handleFileInventory();
    case 'read':
      return _handleFileRead(args);
    case 'write':
      return _handleFileWrite(args);
    case 'list':
      return _handleFileList(args);
    case 'info':
      return _handleFileInfo(args);
    case 'delete':
      return _handleFileDelete(args);
    case 'copy':
      return _handleFileCopy(args);
    case 'diff':
      return _handleFileDiff(args);
    case 'mkdir':
      return _handleFileMkdir(args);
    case 'rename':
    case 'move':
      return _handleFileRename(args);
    case 'zip':
    case 'unzip':
      return _handleFileZip(<String, dynamic>{...args, 'action': action});
    case 'grep':
    case 'replace':
      return _handleFileGrep(<String, dynamic>{
        ...args,
        'mode': action == 'replace' ? 'replace' : 'grep',
      });
    case 'strings':
      return _handleFileStrings(args);
    default:
      return jsonEncode(<String, dynamic>{
        'ok': false,
        'error': 'invalid_action',
        'message':
            'file action 非法：$action。支持 inventory/read/write/list/info/delete/copy/diff/mkdir/rename/zip/unzip/grep/replace/strings',
      });
  }
}

Future<Map<String, dynamic>> _workspaceInventory() async {
  final workDir = await ApkWorkspaceBindingService.workDir();
  final active = await ApkWorkspaceBindingService.activeApkPath();
  final report = await ApkWorkspaceService.readReport();
  final source = report?['sourceApk'];
  final reportPath = source is Map ? source['path']?.toString() : null;
  var lastSo = ToolSessionState.lastBuiltSoPath;
  if (lastSo == null || !await File(lastSo).exists()) {
    for (final artifact
        in await ApkWorkspaceBindingService.readFileArtifacts()) {
      if (artifact['operation'] == 'so_build' && artifact['exists'] == true) {
        lastSo = artifact['path']?.toString();
        ToolSessionState.lastBuiltSoPath = lastSo;
        ToolSessionState.lastBuiltSoApkPath = artifact['source']?.toString();
        final metadata = artifact['metadata'];
        if (metadata is Map) {
          ToolSessionState.lastBuiltSoEntry = metadata['sourceEntry']
              ?.toString();
        }
        break;
      }
    }
  }

  /// 工作目录根的真实文件清单：用户手动放进来的 .md/日志等非绑定产物
  /// 也必须可见，否则模型"看不见"目录里的普通文件。
  final workDirRoot = <Map<String, dynamic>>[];
  var workDirRootTruncated = false;
  if (workDir != null && workDir.isNotEmpty) {
    try {
      final entities = await Directory(
        workDir,
      ).list(followLinks: false).toList();
      entities.sort((a, b) {
        final aDir = a is Directory;
        final bDir = b is Directory;
        if (aDir != bDir) return aDir ? -1 : 1;
        final an = p.basename(a.path).toLowerCase();
        final bn = p.basename(b.path).toLowerCase();
        return an.compareTo(bn);
      });
      const cap = 100;
      for (final entity in entities.take(cap)) {
        try {
          final stat = await entity.stat();
          workDirRoot.add(<String, dynamic>{
            'name': p.basename(entity.path),
            'path': entity.path,
            'isDirectory': entity is Directory,
            'size': entity is File ? stat.size : 0,
            'modified': stat.modified.millisecondsSinceEpoch,
          });
        } catch (_) {}
      }
      workDirRootTruncated = entities.length > cap;
    } catch (_) {}
  }
  return <String, dynamic>{
    'ok': true,
    'scope': ApkWorkspaceBindingService.currentScopeId ?? 'global',
    'workDir': workDir,
    'workDirRoot': workDirRoot,
    if (workDirRootTruncated) 'workDirRootTruncated': true,
    'activeApk': active,
    'activeApkExists': active != null && await File(active).exists(),
    'reportSourceApk': reportPath,
    'reportSourceExists': reportPath != null && await File(reportPath).exists(),
    'lastBuiltSo': lastSo,
    'lastBuiltSoExists': lastSo != null && await File(lastSo).exists(),
    'apkFiles': await ApkWorkspaceBindingService.listApks(),
    'buildArtifacts': await ApkWorkspaceBindingService.readBuilds(),
    'fileArtifacts': await ApkWorkspaceBindingService.readFileArtifacts(),
  };
}

Future<String> _handleFileInventory() async =>
    jsonEncode(await _workspaceInventory());

Future<String> _encodeFileMutation(
  ApkStructuralResult result, {
  required bool dryRun,
  required String operation,
  String? path,
  String? source,
  Future<void> Function()? reconcile,
}) async {
  if (result.ok && !dryRun) {
    if (reconcile != null) await reconcile();
    if (path != null && path.isNotEmpty) {
      await ApkWorkspaceBindingService.recordFileArtifact(
        path: path,
        operation: operation,
        source: source,
      );
    }
  }
  final decoded = jsonDecode(_encodeToolResult(result));
  if (decoded is! Map) return _encodeToolResult(result);
  final payload = Map<String, dynamic>.from(decoded);
  if (result.ok && !dryRun) {
    // 变更类工具回带轻量同步摘要；完整清单由 action=inventory 显式获取，
    // 避免连续写操作时重复枚举目录与全量 jsonEncode。
    final inv = await _workspaceInventory();
    payload['workspaceSync'] = <String, dynamic>{
      'scope': inv['scope'],
      'workDir': inv['workDir'],
      'activeApk': inv['activeApk'],
      'rootEntryCount': (inv['workDirRoot'] as List?)?.length ?? 0,
      if (inv['workDirRootTruncated'] == true) 'workDirRootTruncated': true,
      'apkCount': (inv['apkFiles'] as List?)?.length ?? 0,
      'buildCount': (inv['buildArtifacts'] as List?)?.length ?? 0,
      'lastBuiltSo': inv['lastBuiltSo'],
      'hint': '完整清单请调用 action=inventory。',
    };
  }
  return jsonEncode(payload);
}

Future<String> _handleFileRead(Map<String, dynamic> args) async {
  final (path, pathErr) = await _resolveFileOpsPath(args);
  if (path == null) return jsonEncode(pathErr);
  final normalized = path.replaceAll('\\', '/').toLowerCase();
  final isBlutterReference =
      normalized.contains('/blutter/v1/results/') &&
      (normalized.endsWith('/pp.txt') ||
          normalized.endsWith('/objs.txt') ||
          normalized.endsWith('.jsonl') ||
          (normalized.contains('/asm/') && normalized.endsWith('.dart')));
  final requestedOffset = (args['offset'] as num?)?.toInt() ?? 0;
  if (isBlutterReference && requestedOffset > 0) {
    return jsonEncode(<String, dynamic>{
      'ok': false,
      'error': 'reference_paging_blocked',
      'referenceOnly': true,
      'message':
          '这是 Blutter 参考产物，禁止按 offset 连续翻页。请用 grep 精确匹配，或用 so_analyze 的 locate/search/xref/disasm 按证据读取。当前页没有帮助就停止。',
    });
  }
  final req = <String, Object?>{'action': 'read', 'path': path};
  final offset = args['offset'];
  final limit = args['limit'];
  if (offset is num) req['offset'] = offset.toInt();
  if (limit is num) {
    req['limit'] = isBlutterReference
        ? limit.toInt().clamp(1, 80).toInt()
        : limit.toInt();
  } else if (isBlutterReference) {
    req['limit'] = 80;
  }
  final r = await ApkToolchainService.fileOps(req);
  final encoded = _encodeToolResult(r);
  if (!isBlutterReference) return encoded;
  final decoded = jsonDecode(encoded);
  if (decoded is Map<String, dynamic>) {
    decoded['referenceOnly'] = true;
    decoded['pagingBlocked'] = true;
    decoded['nextStep'] =
        '不要继续 read 下一页；改用 grep 或 so_analyze locate/search/xref/disasm。';
    return jsonEncode(decoded);
  }
  return encoded;
}

Future<String> _handleFileWrite(Map<String, dynamic> args) async {
  final (path, pathErr) = await _resolveFileOpsPath(args);
  if (path == null) return jsonEncode(pathErr);
  final content = (args['content'] ?? '').toString();
  final dryRun = (args['dryRun'] as bool?) ?? true;
  final r = await ApkToolchainService.fileOps(<String, Object?>{
    'action': 'write',
    'path': path,
    'content': content,
    'dryRun': dryRun,
  });
  return _encodeFileMutation(r, dryRun: dryRun, operation: 'write', path: path);
}

Future<String> _handleFileList(Map<String, dynamic> args) async {
  // path 缺省 = 列统一工作目录本身（与 build/so 工具链产物落点一致）
  final raw = (args['path'] ?? '').toString().trim();
  final String? path;
  if (raw.isEmpty) {
    final dir = await ApkWorkspaceBindingService.workDir();
    path = (dir == null || dir.isEmpty) ? null : dir;
    if (path == null) {
      return jsonEncode(const {
        'ok': false,
        'error': 'workspace_not_set',
        'message': '工作目录未设置：请先在 APK 工作台设置统一工作目录，或显式传 path',
      });
    }
  } else {
    final (resolved, pathErr) = await _resolveFileOpsPath(args);
    if (resolved == null) return jsonEncode(pathErr);
    path = resolved;
  }
  final r = await ApkToolchainService.fileOps(<String, Object?>{
    'action': 'list',
    'path': path,
    'limit': (args['limit'] as num?)?.toInt() ?? 200,
    // APK/ZIP 条目列表（Kotlin 端识别包文件后走包内清单分支）
    if (args['offset'] is num) 'offset': (args['offset'] as num).toInt(),
    if ((args['entryPrefix'] ?? '').toString().trim().isNotEmpty)
      'entryPrefix': args['entryPrefix'].toString().trim(),
  });
  return _encodeToolResult(r);
}

Future<String> _handleFileInfo(Map<String, dynamic> args) async {
  final (path, pathErr) = await _resolveFileOpsPath(args);
  if (path == null) return jsonEncode(pathErr);
  final r = await ApkToolchainService.fileOps(<String, Object?>{
    'action': 'info',
    'path': path,
  });
  return _encodeToolResult(r);
}

Future<String> _handleFileDelete(Map<String, dynamic> args) async {
  final (path, pathErr) = await _resolveFileOpsPath(args);
  if (path == null) return jsonEncode(pathErr);
  final dryRun = (args['dryRun'] as bool?) ?? true;
  final r = await ApkToolchainService.fileOps(<String, Object?>{
    'action': 'delete',
    'path': path,
    'recursive': args['recursive'] == true,
    'dryRun': dryRun,
  });
  return _encodeFileMutation(
    r,
    dryRun: dryRun,
    operation: 'delete',
    path: path,
  );
}

Future<String> _handleFileZip(Map<String, dynamic> args) async {
  final (path, pathErr) = await _resolveFileOpsPath(args);
  if (path == null) return jsonEncode(pathErr);
  final action = (args['action'] ?? 'zip').toString();
  final output = (args['output'] ?? '').toString().trim();
  final outputDir = (args['outputDir'] ?? '').toString().trim();
  final (resolvedOutput, outputErr) = output.isEmpty
      ? (null, null)
      : await _resolveFileOpsPath(<String, dynamic>{'path': output});
  final (resolvedOutputDir, outputDirErr) = outputDir.isEmpty
      ? (null, null)
      : await _resolveFileOpsPath(<String, dynamic>{'path': outputDir});
  if (outputErr != null) return jsonEncode(outputErr);
  if (outputDirErr != null) return jsonEncode(outputDirErr);
  final dryRun = (args['dryRun'] as bool?) ?? true;
  final r = await ApkToolchainService.fileOps(<String, Object?>{
    'action': action,
    'path': path,
    if (resolvedOutput != null) 'output': resolvedOutput,
    if (resolvedOutputDir != null) 'outputDir': resolvedOutputDir,
    'dryRun': dryRun,
  });
  return _encodeFileMutation(
    r,
    dryRun: dryRun,
    operation: action,
    path:
        (action == 'zip' ? resolvedOutput : resolvedOutputDir) ??
        r.data?['outputPath']?.toString() ??
        r.data?['outputDir']?.toString(),
    source: path,
  );
}

Future<String> _handleFileDiff(Map<String, dynamic> args) async {
  final (source, sourceErr) = await _resolveFileOpsPath(<String, dynamic>{
    'path': args['sourcePath'],
  });
  if (source == null) return jsonEncode(sourceErr);
  final (target, targetErr) = await _resolveFileOpsPath(<String, dynamic>{
    'path': args['targetPath'],
  });
  if (target == null) return jsonEncode(targetErr);
  final r = await ApkToolchainService.fileOps(<String, Object?>{
    'action': 'diff',
    'path': source,
    'target': target,
    if (args['context'] is num) 'context': (args['context'] as num).toInt(),
  });
  return _encodeToolResult(r);
}

Future<String> _handleFileMkdir(Map<String, dynamic> args) async {
  final (path, pathErr) = await _resolveFileOpsPath(args);
  if (path == null) return jsonEncode(pathErr);
  final r = await ApkToolchainService.fileOps(<String, Object?>{
    'action': 'mkdir',
    'path': path,
  });
  return _encodeFileMutation(r, dryRun: false, operation: 'mkdir', path: path);
}

Future<String> _handleFileCopy(Map<String, dynamic> args) async {
  final (source, sourceErr) = await _resolveFileOpsPath(<String, dynamic>{
    'path': args['sourcePath'],
  });
  if (source == null) return jsonEncode(sourceErr);
  final (target, targetErr) = await _resolveFileOpsPath(<String, dynamic>{
    'path': args['targetPath'],
  });
  if (target == null) return jsonEncode(targetErr);
  final dryRun = (args['dryRun'] as bool?) ?? true;
  final r = await ApkToolchainService.fileOps(<String, Object?>{
    'action': 'copy',
    'path': source,
    'target': target,
    'overwrite': args['overwrite'] == true,
    'dryRun': dryRun,
  });
  return _encodeFileMutation(
    r,
    dryRun: dryRun,
    operation: 'copy',
    path: target,
    source: source,
    reconcile: () => ApkWorkspaceBindingService.reconcileMovedPath(
      source,
      target,
      copy: true,
    ),
  );
}

Future<String> _handleFileRename(Map<String, dynamic> args) async {
  final (source, sourceErr) = await _resolveFileOpsPath(<String, dynamic>{
    'path': args['sourcePath'],
  });
  if (source == null) return jsonEncode(sourceErr);
  final (target, targetErr) = await _resolveFileOpsPath(<String, dynamic>{
    'path': args['targetPath'],
  });
  if (target == null) return jsonEncode(targetErr);
  final dryRun = (args['dryRun'] as bool?) ?? true;
  final r = await ApkToolchainService.fileOps(<String, Object?>{
    'action': 'rename',
    'path': source,
    'target': target,
    'overwrite': args['overwrite'] == true,
    'dryRun': dryRun,
  });
  return _encodeFileMutation(
    r,
    dryRun: dryRun,
    operation: 'rename',
    path: target,
    source: source,
    reconcile: () async {
      await ApkWorkspaceBindingService.reconcileMovedPath(source, target);
      await ApkWorkspaceService.refreshSourceFingerprint(
        target,
        replacesPath: source,
      );
    },
  );
}

Future<String> _handleFileGrep(Map<String, dynamic> args) async {
  final (path, pathErr) = await _resolveFileOpsPath(args);
  if (path == null) return jsonEncode(pathErr);
  final mode = (args['mode'] ?? 'grep').toString();
  final dryRun = (args['dryRun'] as bool?) ?? false;
  final req = <String, Object?>{
    'action': mode == 'replace' ? 'replace' : 'grep',
    'path': path,
    if (mode == 'replace') ...{
      'find': (args['find'] ?? '').toString(),
      'replacement': (args['replacement'] ?? '').toString(),
      'dryRun': dryRun,
    } else ...{
      'pattern': (args['pattern'] ?? args['query'] ?? '').toString(),
      if (args['limit'] is num) 'limit': (args['limit'] as num).toInt(),
    },
    if (args['include'] != null) 'include': args['include'].toString(),
  };
  final r = await ApkToolchainService.fileOps(req);
  if (mode != 'replace') return _encodeToolResult(r);
  return _encodeFileMutation(
    r,
    dryRun: dryRun,
    operation: 'replace',
    path: path,
  );
}

Future<String> _handleFileStrings(Map<String, dynamic> args) async {
  final (path, pathErr) = await _resolveFileOpsPath(args);
  if (path == null) return jsonEncode(pathErr);
  final result = await ApkToolchainService.fileOps(<String, Object?>{
    'action': 'strings',
    'path': path,
    'encoding': (args['encoding'] ?? 'auto').toString(),
    'query': (args['query'] ?? '').toString(),
    if (args['limit'] is num) 'limit': (args['limit'] as num).toInt(),
    if (args['minLength'] is num)
      'minLength': (args['minLength'] as num).toInt(),
  });
  return _encodeToolResult(result);
}

Future<String> _handleSmaliRead(Map<String, dynamic> args) async {
  final (path, err) = await _resolveToolchainPath(args);
  if (path == null) {
    return jsonEncode({'ok': false, 'error': 'invalid_args', 'message': err});
  }
  final qid = (args['qualifiedId'] ?? '').toString();
  if (qid.isEmpty) {
    return jsonEncode({
      'ok': false,
      'error': 'invalid_args',
      'message': '缺少 qualifiedId',
    });
  }
  final r = await ApkToolchainService.smaliRead(path: path, qualifiedId: qid);
  return _encodeToolResult(r);
}
