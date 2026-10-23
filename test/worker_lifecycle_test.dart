import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fixma_pixma/core/connection.dart';

class TestProcess implements Process {
  final input = StreamController<List<int>>();
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final exited = Completer<int>();
  bool killed = false;
  @override
  late final IOSink stdin = IOSink(input.sink);
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  Future<int> get exitCode => exited.future;
  @override
  int get pid => 1;
  TestProcess() {
    input.stream.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) {
        if (killed) return;
        output.add(utf8.encode('{"ok":true,"value":true}\n'));
        if (line.contains('"close"')) kill();
      },
      onDone: kill,
    );
  }
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (killed) return false;
    killed = true;
    output.close();
    errors.close();
    exited.complete(0);
    return true;
  }
}

void main() {
  test('non-UTF8 helper diagnostics do not crash a waiting request', () async {
    final process = TestProcess(), records = <Map<String, dynamic>>[];
    final peer = WorkerPeer.fromProcess(process, records.add);
    process.errors.add([255, 254, 10]);
    expect(await peer.call('init'), true);
    await Future<void>.delayed(Duration.zero);
    expect(records.any((v) => v.containsKey('workerError')), true);
    await peer.close();
  });
  test('journal failure in asynchronous stderr terminates the helper without escaping', () async {
    final process = TestProcess();
    final peer = WorkerPeer.fromProcess(
      process,
      (_) => throw const FileSystemException('Disk full'),
    );
    process.errors.add(utf8.encode('Helper failed'));
    await process.exitCode;
    expect(process.killed, true);
    await peer.close();
  });
  test(
    'closing a helper with an already-closed input is safe and idempotent',
    () async {
      final process = TestProcess();
      final closed = WorkerPeer.fromProcess(process, (_) {});
      await process.stdin.close();
      await closed.close();
      await closed.close();
      expect(process.killed, true);
    },
  );
  test('oversized stdout is rejected and the helper is terminated', () async {
    final process = TestProcess();
    final peer = WorkerPeer.fromProcess(process, (_) {});
    final call = peer.call('init');
    process.output.add(List.filled(4 * 1024 * 1024 + 1, 65));
    await expectLater(
      call,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('too large'),
        ),
      ),
    );
    expect(process.killed, true);
    await peer.close();
  });
}
