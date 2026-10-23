import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixma_fixa/controller.dart';
import 'package:pixma_fixa/core/ink_counter.dart';

import 'network_controller_test.dart' show TestNetwork;

class RefillPrinter implements InkCounterPeer {
  final Directory folder;
  Map<String, int?> levels = {'BK': 20, 'C': 30, 'M': 30, 'Y': 30};
  String serial = 'TEST12345', state = 'idle';
  bool failWrite = false, alterOtherColor = false;
  final sent = <String>[];
  RefillPrinter(this.folder);
  @override
  Future<InkIdentity> identity() async =>
      InkIdentity('G7000 series', '1.050', serial, inkNames.keys.toSet());
  @override
  Future<InkCounters> read() async => InkCounters(state, '', {...levels});
  @override
  Future<void> resetColor(String color) async {
    final guard = jsonDecode(
      File('${folder.path}/ink-refill-$serial.json').readAsStringSync(),
    ) as Map;
    expect(
      guard.containsKey(color),
      true,
      reason: 'Attempt must be flushed before sending',
    );
    sent.add(color);
    if (failWrite) throw const SocketException('Reply was lost');
    levels[color] = 100;
    if (alterOtherColor) levels['Y'] = 100;
  }

  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late RefillPrinter printer;
  late CareController c;
  late TestNetwork network;
  setUp(() async {
    folder = Directory.systemTemp.createTempSync('ink-refill-test-');
    printer = RefillPrinter(folder);
    network = TestNetwork();
    c = CareController(
      directory: folder,
      network: network,
      inkFactory: (_) async => printer,
    );
    await c.initialize(scan: false);
    await c.selectPrinter(network.targets.single);
  });
  tearDown(() {
    c.dispose();
    folder.deleteSync(recursive: true);
  });

  test(
    'selected colors reset once with durable records and real readback',
    () async {
      final check = (await c.prepareInkReset())!;
      await c.resetInkCounts(check, {'C', 'M'}, filledToUpperLine: true);
      expect(printer.sent, ['C', 'M']);
      expect(printer.levels, {'BK': 20, 'C': 100, 'M': 100, 'Y': 30});
      expect(c.history.first['verified'], true);
      expect(c.history.first['counterClearAttempted'], false);
      expect(c.history.first['inkCounterAttempted'], true);
      expect(c.report, null);
      expect(c.liveValid, false);
    },
  );
  test('confirmation and a nonempty valid selection are required', () async {
    final check = (await c.prepareInkReset())!;
    await c.resetInkCounts(check, {'BK'}, filledToUpperLine: false);
    await c.resetInkCounts(check, {}, filledToUpperLine: true);
    await c.resetInkCounts(check, {'all'}, filledToUpperLine: true);
    expect(printer.sent, isEmpty);
    expect(c.history, isEmpty);
  });
  test('lost reply is never retried and survives controller restart', () async {
    printer.failWrite = true;
    final check = (await c.prepareInkReset())!;
    await c.resetInkCounts(check, {'BK', 'C'}, filledToUpperLine: true);
    expect(printer.sent, ['BK']);
    expect(c.history.first['status'], 'Stopped');
    c.dispose();
    c = CareController(
      directory: folder,
      network: network,
      inkFactory: (_) async => printer,
    );
    await c.initialize(scan: false);
    await c.refreshNetwork();
    final again = (await c.prepareInkReset())!;
    await c.resetInkCounts(again, {'BK'}, filledToUpperLine: true);
    expect(printer.sent, ['BK']);
    expect(c.lastError, contains('previous refill reset'));
    expect(printer.levels['C'], 30);
  });
  test(
    'changed identity, busy state and unknown counters block dispatch',
    () async {
      var check = (await c.prepareInkReset())!;
      printer.serial = 'OTHER12345';
      await c.resetInkCounts(check, {'BK'}, filledToUpperLine: true);
      expect(printer.sent, isEmpty);
      expect(c.lastError, contains('identity changed'));
      printer.state = 'processing';
      expect(await c.prepareInkReset(), null);
      printer.state = 'idle';
      printer.levels['BK'] = null;
      check = (await c.prepareInkReset())!;
      await c.resetInkCounts(check, {'BK'}, filledToUpperLine: true);
      expect(printer.sent, isEmpty);
    },
  );
  test('unselected changes stop the batch before another write', () async {
    printer.alterOtherColor = true;
    final check = (await c.prepareInkReset())!;
    await c.resetInkCounts(check, {'BK', 'C'}, filledToUpperLine: true);
    expect(printer.sent, ['BK']);
    expect(c.lastError, contains('unselected'));
    expect(c.history.first['verified'], isNot(true));
  });
  test(
    'already full counts are read without dispatching another reset',
    () async {
      printer.levels['BK'] = 100;
      final check = (await c.prepareInkReset())!;
      await c.resetInkCounts(check, {'BK'}, filledToUpperLine: true);
      expect(printer.sent, isEmpty);
      expect(c.history.first['verified'], true);
    },
  );
}
