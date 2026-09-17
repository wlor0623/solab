import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solab/core/services/mcp_server/mcp_http_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('MCP compact schemas match the approved snapshot', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final server = McpHttpServer.instance;
    server.configure(port: port, token: '');
    expect(await server.start(), isTrue);
    try {
      final response = await _call(port, 'tools/list');
      final actual = sha256
          .convert(utf8.encode(jsonEncode(_canonical(response))))
          .toString();
      final expected = File(
        'test/core/services/mcp_server/__goldens/mcp_tool_schemas.sha256',
      ).readAsStringSync().trim();
      expect(actual, expected, reason: 'MCP 压缩 schema 变更必须显式更新黄金快照');
    } finally {
      await server.stop();
    }
  });
}

Future<Map<String, dynamic>> _call(int port, String method) async {
  final body = jsonEncode(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': 1,
    'method': method,
    'params': const <String, dynamic>{},
  });
  final socket = await Socket.connect('127.0.0.1', port);
  try {
    socket.write(
      'POST /mcp HTTP/1.0\r\n'
      'Host: 127.0.0.1:$port\r\n'
      'Content-Type: application/json\r\n'
      'Content-Length: ${utf8.encode(body).length}\r\n'
      '\r\n'
      '$body',
    );
    final raw = await utf8.decoder.bind(socket).join();
    final separator = raw.indexOf('\r\n\r\n');
    return jsonDecode(raw.substring(separator + 4)) as Map<String, dynamic>;
  } finally {
    socket.destroy();
  }
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
