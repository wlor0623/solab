import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/models/assistant.dart';
import 'package:solab/features/home/services/local_tools_service.dart';

void main() {
  test('local tool schemas match the approved snapshot', () {
    final definitions = LocalToolsService.buildToolDefinitions(
      assistant: Assistant(
        id: 'schema-snapshot',
        name: 'Schema snapshot',
        localToolIds: kLocalToolUiMetadata.keys.toList(growable: false),
      ),
      supportsTools: true,
    );
    final actual = sha256
        .convert(utf8.encode(jsonEncode(_canonical(definitions))))
        .toString();
    final expected = File(
      'test/features/home/services/__goldens/tool_schemas.sha256',
    ).readAsStringSync().trim();

    expect(actual, expected, reason: '工具 schema 变更必须显式更新黄金快照');
  });
}

dynamic _canonical(dynamic value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, dynamic>{
      for (final key in keys) key: _canonical(value[key]),
    };
  }
  if (value is Iterable) return value.map(_canonical).toList(growable: false);
  return value;
}
