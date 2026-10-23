import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fixma_pixma/controller.dart';
import 'package:fixma_pixma/core/connection.dart';
import 'package:fixma_pixma/core/protocol.dart';
import 'package:fixma_pixma/core/report.dart';

class SimulatedPrinter implements PrinterPeer {
  final String text;
  final bool rejectSelector, loseClear;
  final void Function()? beforeClear;
  final sent = <String>[];
  int opcode = 0;
  SimulatedPrinter(
    this.text, {
    this.rejectSelector = false,
    this.loseClear = false,
    this.beforeClear,
  });
  @override
  Future<dynamic> call(
    String op, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (op == 'open') {
      return {
        'model': 'G7000 series',
        'serial': 'DEMO-PRINTER',
        'firmware': '1.050',
      };
    }
    if (op == 'command') {
      final value = arguments['operand'] as String;
      sent.add(value);
      opcode = int.parse(value.substring(0, 2), radix: 16);
      if (value == '0d0000') {
        beforeClear?.call();
        if (loseClear) throw StateError('Simulated interrupted transfer');
      }
    }
    if (op == 'poll') {
      return {
        'continuation': false,
        'reply': {
          'opcode': opcode,
          'accepted': !(rejectSelector && opcode == 0x10),
          'reason': 'Not ready',
          'data': opcode == 0x15 ? hexOf(latin1.encode(text)) : '',
        },
      };
    }
    return {};
  }

  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late String source;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('fixma-pixma-flow-');
    source = File('assets/sample-report.txt').readAsStringSync();
  });
  tearDown(() {
    temp.deleteSync(recursive: true);
  });
  CareController configured({required List<SimulatedPrinter> peers}) {
    var index = 0;
    final c = CareController(
      directory: temp,
      peerFactory: (_, record) async => peers[index++],
    );
    c.report = ServiceReport.parse(source.replaceFirst('D=000.0', 'D=100.0'));
    c.liveValid = true;
    c.serviced = true;
    return c;
  }

  test(
    'reset persists one-shot guard before dispatch and reads counter back',
    () async {
      late CareController c;
      final reset = SimulatedPrinter(
        source,
        beforeClear: () {
          expect(c.guard('DEMO-PRINTER').existsSync(), true);
          expect(
            jsonDecode(c.guard('DEMO-PRINTER').readAsStringSync())['state'],
            contains('unknown'),
          );
        },
      );
      final after = SimulatedPrinter(source);
      c = configured(peers: [reset, after]);
      await c.reset();
      expect(reset.sent, ['10077c', '0d0000']);
      expect(after.sent, ['10077c', '15']);
      expect(c.report!.waste, 0);
      expect(c.priorAttempt, true);
      expect(c.lastError, isEmpty);
      expect(c.history.single['clearAcknowledged'], true);
      c.dispose();
    },
  );
  test('failed selector never creates a marker or sends clear', () async {
    final reset = SimulatedPrinter(source, rejectSelector: true);
    final c = configured(peers: [reset]);
    await c.reset();
    expect(reset.sent, ['10077c']);
    expect(c.guard('DEMO-PRINTER').existsSync(), false);
    expect(c.lastError, isNotEmpty);
    c.dispose();
  });
  test(
    'uncertain clear is recorded and a second click cannot repeat it',
    () async {
      final reset = SimulatedPrinter(source, loseClear: true);
      final c = configured(peers: [reset]);
      await c.reset();
      await c.reset();
      expect(reset.sent.where((v) => v == '0d0000').length, 1);
      expect(c.guard('DEMO-PRINTER').existsSync(), true);
      expect(c.priorAttempt, true);
      expect(c.history.single['counterClearAttempted'], true);
      c.dispose();
    },
  );
  test('preexisting guard prevents even a USB connection', () async {
    final c = configured(peers: []);
    c.guard('DEMO-PRINTER').writeAsStringSync('{}');
    c.priorAttempt = true;
    await c.reset();
    expect(c.lastError, contains('already recorded'));
    c.dispose();
  });
  test('zero counter and sample data cannot reach the worker', () async {
    final c = configured(peers: []);
    c.report = ServiceReport.parse(source);
    await c.reset();
    expect(c.lastError, contains('zero'));
    c.report = ServiceReport.parse(source, sample: true);
    await c.reset();
    expect(c.lastError, contains('live diagnostic'));
    c.dispose();
  });
  test(
    'appearance setting is restored without starting a USB session',
    () async {
      File('${temp.path}/settings.json')
          .writeAsStringSync('{"theme":"dark","ip":"192.168.1.50"}');
      final c = CareController(directory: temp);
      await c.initialize(scan: false);
      expect(c.themeMode.name, 'dark');
      expect(c.ip, '192.168.1.50');
      c.dispose();
    },
  );
}
