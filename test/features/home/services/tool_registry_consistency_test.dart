import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/models/assistant.dart';
import 'package:solab/core/services/local_tools/local_tool_names.dart';
import 'package:solab/core/services/local_tools/local_tool_registry.dart';
import 'package:solab/core/services/mcp_server/mcp_http_server.dart';
import 'package:solab/features/home/services/local_tools_service.dart';
import 'package:solab/features/home/services/tool_router.dart';

/// 注册点防漂移：同一个工具名目前登记在多处（LocalToolNames 常量、
/// schema 定义、UI 元数据表、MCP 白名单、ToolRouter 分层集合）。任何一处
/// 漏登记/改名都会造成「工具可调但 UI 无开关 / MCP 缺席 / 分层挂载失联」。
/// 本测试把所有注册点钉在同一个名单上，新增或改名工具必须五处同步。
void main() {
  // 全量工具名单（与 LocalToolNames 常量一一对应；analyzer.* 不在
  /// LocalToolNames 中，由 AnalyzerToolNames 单独管理）。
  const allLocalToolNames = <String>[
    LocalToolNames.timeInfo,
    LocalToolNames.clipboard,
    LocalToolNames.textToSpeech,
    LocalToolNames.askUser,
    LocalToolNames.calculate,
    LocalToolNames.screenTime,
    LocalToolNames.calendarQuery,
    LocalToolNames.calendarCreate,
    LocalToolNames.apkReport,
    LocalToolNames.apkSkill,
    LocalToolNames.apkKnowledge,
    LocalToolNames.installedSkills,
    LocalToolNames.agentRuntimeGuide,
    LocalToolNames.apkProjectInfo,
    LocalToolNames.apkRules,
    LocalToolNames.apkPatchDex,
    LocalToolNames.apkSignatureBypass,
    LocalToolNames.apkPatchManifest,
    LocalToolNames.apkToolMap,
    LocalToolNames.apkPatchMemory,
    LocalToolNames.apkSavePatchMemory,
    LocalToolNames.apkRecordPatchVerification,
    LocalToolNames.apkListBuilds,
    LocalToolNames.apkCleanupBuilds,
    LocalToolNames.apkNoteRead,
    LocalToolNames.apkNoteWrite,
    LocalToolNames.apkListWorkspace,
    LocalToolNames.apkAnalyzeWorkspace,
    LocalToolNames.apkArchive,
    LocalToolNames.apkExportReport,
    LocalToolNames.jadxDecompile,
    LocalToolNames.apkSign,
    LocalToolNames.apkRebuild,
    LocalToolNames.dexSearch,
    LocalToolNames.stringScan,
    LocalToolNames.dexXref,
    LocalToolNames.classOutline,
    LocalToolNames.smaliRead,
    LocalToolNames.soAnalyze,
    LocalToolNames.soPatchIntoApk,
    LocalToolNames.file,
    LocalToolNames.routeTask,
  ];

  test('all registry points agree on the same tool name set', () {
    final known = allLocalToolNames.toSet();
    expect(known.length, allLocalToolNames.length, reason: '名单自身不得有重复');

    // UI 元数据表：每个已登记工具都有开关条目，且没有失联条目。
    final uiKeys = kLocalToolUiMetadata.keys.toSet();
    expect(
      uiKeys.difference(known),
      isEmpty,
      reason: 'kLocalToolUiMetadata 存在未注册工具',
    );
    expect(
      known.difference(uiKeys),
      isEmpty,
      reason: 'LocalToolNames 有工具缺 UI 元数据',
    );

    // ToolRouter 分层集合：引用的名字必须都在注册表内（改名失联即报）。
    // memory_* / get_tool_result / analyzer.* 属于独立注册表，不计入本名单。
    final tierNames =
        <String>{
              ...ToolRouter.tier0Names,
              ...ToolRouter.tier1Names,
              ...ToolRouter.tier3Names,
              ...ToolRouter.modifyToolNames,
              ...ToolRouter.coreNames,
              ...ToolRouter.deviceNames,
              ...ToolRouter.workspaceNames,
              for (final tierTools in ToolRouter.tier2ByTrack.values)
                ...tierTools,
            }
            .where((name) => !name.startsWith('analyzer.'))
            .where((name) => !name.startsWith('memory_'))
            .where((name) => name != 'get_tool_result')
            .toSet();
    expect(
      tierNames.difference(known),
      isEmpty,
      reason: 'ToolRouter 分层集合引用了未注册的工具名',
    );

    // MCP 白名单：必须都是已注册工具（analyzer.* 由 AnalyzerToolNames 管理）。
    expect(
      McpHttpServer.exposedToolIds
          .where((name) => !name.startsWith('analyzer.'))
          .toSet()
          .difference(known),
      isEmpty,
      reason: 'MCP exposedToolIds 含未注册工具',
    );
  });

  test('buildToolDefinitions emits a schema for every registered tool', () {
    final definitions = LocalToolsService.buildToolDefinitions(
      assistant: Assistant(
        id: 'all-tools',
        name: 'All',
        localToolIds: allLocalToolNames,
      ),
      supportsTools: true,
    );
    final schemaNames = definitions
        .map((def) => (def['function'] as Map)['name'].toString())
        .toSet();
    expect(
      allLocalToolNames.toSet().difference(schemaNames),
      isEmpty,
      reason: '注册的工具缺少 schema 定义',
    );
  });

  test('every registered local tool has a handler-table entry', () {
    final registryNames = LocalToolRegistry.specs
        .map((spec) => spec.name)
        .toSet();
    expect(
      registryNames.difference(LocalToolsService.handledToolNames),
      isEmpty,
      reason: '注册表工具缺少 handler-table 分发',
    );
  });

  test('MCP and device-gated registry metadata is internally complete', () {
    final mcpSpecs = LocalToolRegistry.specs
        .where((spec) => spec.mcpExposed)
        .toList(growable: false);
    expect(mcpSpecs.every((spec) => spec.mcpOrder != null), isTrue);
    expect(
      mcpSpecs.map((spec) => spec.mcpOrder).toSet().length,
      mcpSpecs.length,
    );
    expect(
      LocalToolRegistry.specs
          .where((spec) => spec.deviceGated)
          .map((spec) => spec.name),
      containsAll([
        LocalToolNames.screenTime,
        LocalToolNames.calendarQuery,
        LocalToolNames.calendarCreate,
      ]),
    );
  });
}
