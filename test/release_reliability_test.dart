import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixma_fixa/controller.dart';
import 'package:pixma_fixa/core/connection.dart';
import 'package:pixma_fixa/core/report.dart';
import 'package:pixma_fixa/core/protocol.dart';

import '../bin/ink_probe.dart' as ink_probe;

class FailingClosePeer implements PrinterPeer {
  @override
  Future<dynamic> call(
    String op, [
    Map<String, dynamic> arguments = const {},
  ]) async => null;
  @override
  Future<void> close() async => throw StateError('close failed');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late CareController controller;
  setUp(() {
    directory = Directory.systemTemp.createTempSync(
      'pixma-fixa-reliability-',
    );
    controller = CareController(directory: directory);
  });
  tearDown(() {
    controller.dispose();
    directory.deleteSync(recursive: true);
  });
  test(
    'development refill probe requires an explicit printer address',
    () async {
      await expectLater(ink_probe.main([]), throwsArgumentError);
    },
  );

  test('malformed history never prevents loading a valid record', () async {
    final history = Directory('${directory.path}/history')..createSync();
    final valid = {
      'kind': 'diagnostic',
      'started': '2026-10-23T10:00:00',
      'status': 'Completed',
      'events': [],
    };
    for (final entry in {
      '1': valid,
      '2': {'started': 123},
      '3': {
        'kind': 'diagnostic',
        'started': 'not-a-date',
        'status': 'Completed',
      },
      '4': {...valid, 'events': 'invalid'},
      '5': ['invalid'],
      '7': {...valid, 'report': 'invalid'},
    }.entries) {
      File('${history.path}/${entry.key}.json')
          .writeAsStringSync(jsonEncode(entry.value));
    }
    File('${history.path}/6.json').writeAsStringSync('{broken');
    await controller.initialize(scan: false);
    expect(controller.history, [valid]);
  });

  test('unwritable history prevents work and releases busy state', () async {
    File('${directory.path}/history').writeAsStringSync('not a directory');
    var dispatched = false;
    await controller.run('test', () async {
      dispatched = true;
    });
    expect(dispatched, false);
    expect(controller.busy, false);
    expect(controller.currentLog, null);
    expect(controller.lastError, isNotEmpty);
  });

  test('failed final journal write still releases busy state', () async {
    await controller.run('test', () async {
      final file = controller.currentFile!;
      file.deleteSync();
      Directory(file.path).createSync();
    });
    expect(controller.busy, false);
    expect(controller.currentFile, null);
    expect(controller.lastError, contains('Could not save operation history'));
  });

  test(
    'peer cleanup failure is reported without locking the application',
    () async {
      await controller.run('test', () async {
        controller.activePeer = FailingClosePeer();
      });
      expect(controller.busy, false);
      expect(controller.activePeer, null);
      expect(controller.lastError, contains('cleanup failed'));
      expect(controller.history.single['status'], 'Stopped');
    },
  );

  test(
    'failed preference save preserves previous preferences and does not throw',
    () {
      final settings = File('${directory.path}/settings.json')
        ..writeAsStringSync('{"theme":"system"}');
      Directory('${directory.path}/settings.json.tmp').createSync();
      controller.setTheme(ThemeMode.dark);
      expect(controller.themeMode, ThemeMode.dark);
      expect(settings.readAsStringSync(), '{"theme":"system"}');
      expect(controller.lastError, contains('Could not save preferences'));
    },
  );

  test(
    'upgrade leaves former document caches and reset guards untouched',
    () async {
      final cache = Directory('${directory.path}/scans/old-session')
        ..createSync(recursive: true);
      final image = File('${cache.path}/page-001.jpg')
        ..writeAsBytesSync([1, 2, 3]);
      final guard = File('${directory.path}/reset-TEST.json')
        ..writeAsStringSync('{"serial":"TEST","state":"unknown"}');
      await controller.initialize(scan: false);
      expect(image.readAsBytesSync(), [1, 2, 3]);
      expect(guard.existsSync(), true);
    },
  );

  test('invalid counters and future diagnostic times never enable a reset', () {
    final raw = File('assets/sample-report.txt')
        .readAsStringSync()
        .replaceFirst('D=000.0', 'D=100.0');
    controller.report = ServiceReport.parse(
      raw,
      capturedAt: DateTime.now().add(const Duration(days: 1)),
    );
    controller.liveValid = true;
    controller.serviced = true;
    expect(controller.resetBlocked, contains('fresh diagnostic'));
    for (final counter in [double.nan, double.infinity, -1.0]) {
      expect(
        ResetRules.blocked(
          live: true,
          counter: counter,
          firmware: '1.050',
          priorAttempt: false,
          serviced: true,
          capturedAt: DateTime.now(),
        ),
        contains('invalid counter'),
      );
    }
  });

  test(
    'a second app instance cannot dispatch during an existing transaction',
    () async {
      final second = CareController(directory: directory);
      final started = Completer<void>(), finish = Completer<void>();
      final firstRun = controller.run('first', () async {
        started.complete();
        await finish.future;
      });
      await started.future;
      var dispatched = false;
      await second.run('second', () async {
        dispatched = true;
      });
      expect(dispatched, false);
      expect(second.busy, false);
      expect(second.lastError, contains('Another Pixma Fixa instance'));
      finish.complete();
      await firstRun;
      await second.run('third', () async {
        dispatched = true;
      });
      expect(dispatched, true);
      second.dispose();
    },
    skip: !Platform.isWindows,
  );

  test(
    'truncated USB frames and malformed hex are rejected before decoding',
    () {
      final profile = jsonDecode(
        File('assets/protocol.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(() => hexBytes('abc'), throwsFormatException);
      expect(() => hexBytes('gg'), throwsFormatException);
      expect(
        () =>
            ReplyAssembler(CanonCodec(profile), [1, 2, 3], 21).feed([1, 2, 3]),
        throwsStateError,
      );
    },
  );
}
