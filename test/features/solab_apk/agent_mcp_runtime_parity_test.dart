import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/providers/assistant_provider.dart';
import 'package:solab/core/services/local_tools/local_tool_names.dart';
import 'package:solab/core/services/mcp_server/mcp_http_server.dart';
import 'package:solab/features/solab_apk/services/apk_agent_policy.dart';

void main() {
  test('Agent 与 MCP 原样复用同一判断和结果预算契约', () {
    expect(
      AssistantProvider.apkModSystemPrompt,
      contains(ApkAgentPolicy.sharedDecisionPolicy),
    );
    expect(
      McpHttpServer.mcpInstructions,
      contains(ApkAgentPolicy.sharedDecisionPolicy),
    );
    // 预算契约 2026-08-28 拆分：App 内 LLM 面保持 16KB 内联 + 续读（省
    // token）；MCP 面消费方多为程序型 Agent 且无续读工具，提到 512KB
    // （= ToolHandlerService 结果存储上限）保证尾部可达，超限才截断。
    expect(McpHttpServer.maxResultChars, 512 * 1024);
    expect(
      ApkAgentPolicy.maxVisibleToolResultChars,
      16000,
      reason: 'App 内联阈值独立演进；若调整需同步核对 get_tool_result 续读体验',
    );
  });

  test('MCP 核心工具是 Agent 子集,上下文与技能能力只在 Agent 增量提供', () {
    final agentTools = AssistantProvider.apkModToolIds.toSet();
    final mcpTools = McpHttpServer.exposedToolIds.toSet();

    expect(agentTools, containsAll(mcpTools));
    expect(
      agentTools,
      containsAll(<String>{
        LocalToolNames.agentRuntimeGuide,
        LocalToolNames.apkKnowledge,
        LocalToolNames.installedSkills,
        LocalToolNames.apkSkill,
        LocalToolNames.apkPatchMemory,
        LocalToolNames.apkNoteRead,
      }),
    );
    expect(mcpTools, isNot(contains(LocalToolNames.installedSkills)));
    expect(mcpTools, isNot(contains(LocalToolNames.agentRuntimeGuide)));
    // 真机实测缺陷回归锁：外部 Agent 必须能按文件指纹识别「已验证成品
    // 基线」，否则会从原始包重做（2026-08-28 万能乐器模拟器会话）。
    expect(
      mcpTools,
      contains(LocalToolNames.apkPatchMemory),
      reason: 'get_apk_patch_memory(lookupArtifactPath) 是 MCP 面唯一的成品指纹反查入口',
    );
  });
}
