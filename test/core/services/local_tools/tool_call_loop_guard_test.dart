import 'package:flutter_test/flutter_test.dart';
import 'package:solab/core/services/local_tools/tool_call_loop_guard.dart';

void main() {
  test('blocks a repeated call inside a short cycle', () {
    final guard = ToolCallLoopGuard();

    expect(guard.check('xref', {'offset': 1}).allowed, isTrue);
    expect(guard.check('blutter', {'va': '0xe0f34c'}).allowed, isTrue);
    expect(guard.check('disasm', {'va': '0xe0f34c'}).allowed, isTrue);
    expect(guard.check('xref', {'offset': 1}).allowed, isFalse);
  });

  test('canonicalizes nested map key order', () {
    final guard = ToolCallLoopGuard();

    expect(
      guard.check('search', {
        'filters': {'kind': 'string', 'limit': 10},
      }).allowed,
      isTrue,
    );
    expect(
      guard.check('search', {
        'filters': {'limit': 10, 'kind': 'string'},
      }).allowed,
      isFalse,
    );
  });

  test('does not track polling calls', () {
    final guard = ToolCallLoopGuard();

    expect(guard.check('status', const {}, polling: true).allowed, isTrue);
    expect(guard.check('status', const {}, polling: true).allowed, isTrue);
  });

  test('forgets fingerprints outside the window', () {
    final guard = ToolCallLoopGuard(windowSize: 2);

    expect(guard.check('a', const {}).allowed, isTrue);
    expect(guard.check('b', const {}).allowed, isTrue);
    expect(guard.check('c', const {}).allowed, isTrue);
    expect(guard.check('a', const {}).allowed, isTrue);
  });

  test('forget allows retrying a failed (timeout/network) call', () {
    final guard = ToolCallLoopGuard();

    expect(guard.check('file', {'action': 'read', 'path': 'a.txt'}).allowed, isTrue);
    guard.forget('file', {'action': 'read', 'path': 'a.txt'});
    expect(guard.check('file', {'action': 'read', 'path': 'a.txt'}).allowed, isTrue);
  });

  test('state change invalidates stale reads but keeps duplicate write blocked', () {
    final guard = ToolCallLoopGuard();

    expect(guard.check('get_current_apk_report', const {}).allowed, isTrue);
    expect(guard.check('analyze_apk_workspace', const {}).allowed, isTrue);
    guard.advanceState('analyze_apk_workspace', const {});

    expect(guard.check('get_current_apk_report', const {}).allowed, isTrue);
    expect(guard.check('analyze_apk_workspace', const {}).allowed, isFalse);
  });

  test('classifies Blutter reads and writes separately', () {
    expect(
      ToolCallLoopGuard.changesState('so_analyze', const {
        'action': 'disasm',
      }),
      isFalse,
    );
    expect(
      ToolCallLoopGuard.changesState('so_analyze', const {
        'action': 'blutter',
        'blutterAction': 'locate',
      }),
      isTrue,
    );
  });

  test('does not advance state after failed tool output', () {
    expect(ToolCallLoopGuard.succeeded('{"ok":false}'), isFalse);
    expect(ToolCallLoopGuard.succeeded('{"success":false}'), isFalse);
    expect(ToolCallLoopGuard.succeeded('{"status":"failed"}'), isFalse);
    expect(ToolCallLoopGuard.succeeded('{"ok":true}'), isTrue);
  });
}
