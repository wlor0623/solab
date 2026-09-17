import 'dart:convert';

import 'analyzer_api.dart';
import 'analyzer_gateway_impl.dart';

// ============================================================================
// Analyzer Tools — 4 个高价值语义入口（按需分析模式）
//
// Agent 面对的是「意图」而非「工具」：
//   analyzer.open               打开 APK（按需模式，秒回就绪）
//   analyzer.global_search      跨 dex 聚合搜索（内部 dex_search）
//   analyzer.find_field_usage   字段 READ/WRITE 消费点（内部 field_xref + LRU）
//   analyzer.analyze_business_state 业务语义定位（内部编排 search→outline→xref）
//
// 底层 58 个原子工具作为内部执行器，不再暴露给 Agent。
// ============================================================================

class AnalyzerToolNames {
  AnalyzerToolNames._();

  static const String open = 'analyzer.open';
  static const String globalSearch = 'analyzer.global_search';
  static const String fieldUsage = 'analyzer.find_field_usage';
  static const String businessState = 'analyzer.analyze_business_state';

  static const List<String> all = <String>[
    open,
    globalSearch,
    fieldUsage,
    businessState,
  ];
}

/// 工具 schema 构建 + 分派。
class AnalyzerGatewayTools {
  AnalyzerGatewayTools({AnalyzerGateway? gateway, String contextKey = 'app'})
    : gateway = gateway ?? AnalyzerGatewayRegistry.forKey(contextKey);

  final AnalyzerGateway gateway;

  static const Map<String, String> _descriptions = <String, String>{
    AnalyzerToolNames.open:
        '打开 APK 的按需分析上下文。仅在 Analyzer 尚未绑定当前 APK 时需要；已有 apkId 或其他工具的精确 locator 时不构成固定流程起点。',
    AnalyzerToolNames.globalSearch:
        '跨全部 DEX 搜索结构候选。混淆时 query 可用字符串、字段语义或已知片段；结果按 locator 保持身份,可任选类结构、字段使用、XREF 或 smali 验证,不规定后续顺序。',
    AnalyzerToolNames.fieldUsage:
        '查询字段 READ/WRITE 消费点,是可独立收口的数据流证据。fieldLocator 可来自任意可信产物；返回的方法 locator 可直接读 smali。字段读写已明确表达目标行为时无需补跑名称搜索。',
    AnalyzerToolNames.businessState:
        '业务状态候选聚合器,用于 VIP、登录、广告等。它给出一组假设和 locator,不是唯一入口；fieldName 仅在有证据时填写。若其他产物已给出精确方法或字段,可跳过本工具直接验证。',
  };

  static const Map<String, Map<String, dynamic>> _paramSchemas =
      <String, Map<String, dynamic>>{
        AnalyzerToolNames.open: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'apkPath': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['apkPath'],
        },
        AnalyzerToolNames.globalSearch: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'query': <String, dynamic>{'type': 'string'},
            'topK': <String, dynamic>{'type': 'integer'},
            'apkId': <String, dynamic>{
              'type': 'string',
              'description': '可选。使用 analyzer.open 返回的 apkId 绑定当前目标。',
            },
          },
          'required': <String>['query'],
        },
        AnalyzerToolNames.fieldUsage: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'fieldLocator': <String, dynamic>{'type': 'string'},
            'apkId': <String, dynamic>{
              'type': 'string',
              'description': '可选。使用 analyzer.open 返回的 apkId 绑定当前目标。',
            },
          },
          'required': <String>['fieldLocator'],
        },
        AnalyzerToolNames.businessState: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'targetKeyword': <String, dynamic>{'type': 'string'},
            'domain': <String, dynamic>{'type': 'string'},
            'fieldName': <String, dynamic>{'type': 'string'},
            'apkId': <String, dynamic>{
              'type': 'string',
              'description': '可选。使用 analyzer.open 返回的 apkId 绑定当前目标。',
            },
          },
          'required': <String>['targetKeyword'],
        },
      };

  /// 构建 tools 声明。
  static List<Map<String, dynamic>> buildDefinitions(Set<String> enabledNames) {
    final defs = <Map<String, dynamic>>[];
    for (final name in AnalyzerToolNames.all) {
      if (!enabledNames.contains(name)) continue;
      defs.add(<String, dynamic>{
        'type': 'function',
        'function': <String, dynamic>{
          'name': name,
          'description': _descriptions[name] ?? '',
          'parameters': _paramSchemas[name] ?? const <String, dynamic>{},
        },
      });
    }
    return defs;
  }

  /// 分派：name → 网关调用 → AnalyzerResult.encode()。
  Future<String> handle(String name, Map<String, dynamic> args) async {
    AnalyzerResult r;
    switch (name) {
      case AnalyzerToolNames.open:
        r = await gateway.openWorkspace(
          apkPath: (args['apkPath'] ?? '').toString(),
        );
      case AnalyzerToolNames.globalSearch:
        r = await gateway.globalSearch(
          query: (args['query'] ?? '').toString(),
          topK: (args['topK'] as num?)?.toInt() ?? 20,
          apkId: args['apkId']?.toString(),
        );
      case AnalyzerToolNames.fieldUsage:
        r = await gateway.findFieldUsage(
          fieldLocator: (args['fieldLocator'] ?? '').toString(),
          apkId: args['apkId']?.toString(),
        );
      case AnalyzerToolNames.businessState:
        r = await gateway.analyzeBusinessState(
          targetKeyword: (args['targetKeyword'] ?? '').toString(),
          domain: (args['domain'] ?? 'vip').toString(),
          fieldName: (args['fieldName'] ?? '').toString(),
          apkId: args['apkId']?.toString(),
        );
      default:
        return jsonEncode(<String, dynamic>{
          'type': 'tool_error',
          'error': 'unknown_analyzer_tool',
          'message': '未知的 analyzer 工具: $name',
        });
    }
    return r.encode();
  }
}
