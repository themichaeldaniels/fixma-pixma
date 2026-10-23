import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fixma_pixma/controller.dart';
import 'package:fixma_pixma/core/network_status.dart';
import 'package:fixma_pixma/core/printer_network.dart';

class TestNetwork implements PrinterNetwork {
  int calls = 0;
  bool fail = false, discoveryFail = false;
  List<PrinterTarget> targets = [
    PrinterTarget(
      Uri.parse('ipp://192.168.1.50:631/ipp/print'),
      discoveredName: 'Office printer',
      discoveryId: 'test-printer',
    ),
  ];
  @override
  Future<List<PrinterTarget>> discover() async {
    if (discoveryFail) throw const SocketException('Multicast blocked');
    return targets;
  }

  @override
  Future<NetworkStatus> read(PrinterTarget target) async {
    calls++;
    if (fail) throw const SocketException('Printer offline');
    final attrs =
        (jsonDecode(
          File('test/fixtures/g7000-ipp.json').readAsStringSync(),
        ) as Map).map(
          (k, v) => MapEntry(k as String, List<Object?>.from(v as List)),
        );
    return NetworkStatus(target: target, attributes: attrs);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late TestNetwork network;
  late CareController c;
  setUp(() {
    folder = Directory.systemTemp.createTempSync('printer-network-test-');
    network = TestNetwork();
    c = CareController(directory: folder, network: network);
  });
  tearDown(() {
    c.dispose();
    folder.deleteSync(recursive: true);
  });
  test('fresh discovery reads identity and supplies without enabling service reset', () async {
    await c.initialize(scan: false);
    await c.discover();
    expect(c.networkOnline, true);
    expect(c.networkStatus!.firmware, '1.050');
    expect(c.liveValid, false);
    expect(c.report, null);
    expect(c.resetBlocked, contains('live diagnostic'));
    expect(c.networkStatus!.supplies.map((s) => s.percent), [20, 30, 30, 30]);
  });
  test('failed refresh retains old readings but marks them offline, recovery clears error', () async {
    await c.initialize(scan: false);
    await c.selectPrinter(network.targets.single);
    final previous = c.networkStatus;
    network.fail = true;
    await c.refreshNetwork();
    expect(c.networkOnline, false);
    expect(identical(c.networkStatus, previous), true);
    expect(c.exportText(), contains('Offline - last known reading'));
    network.fail = false;
    await c.refreshNetwork();
    expect(c.networkOnline, true);
    expect(c.networkError, isEmpty);
  });
  test(
    'saved selection works without multicast, snapshots and preferences reload',
    () async {
      await c.initialize(scan: false);
      await c.selectPrinter(network.targets.single);
      await c.saveNetworkSnapshot();
      expect(c.history.single['network']['firmware'], '1.050');
      expect(c.history.single['counterClearAttempted'], false);
      c.dispose();
      c = CareController(directory: folder, network: network);
      network.discoveryFail = true;
      await c.initialize(scan: false);
      await c.discover();
      expect(c.selectedPrinter!.uri.host, '192.168.1.50');
      expect(c.networkOnline, true);
      expect(c.history.single['kind'], 'network snapshot');
    },
  );
  test('stable printer identity follows a discovered address change', () async {
    await c.initialize(scan: false);
    await c.selectPrinter(network.targets.single);
    network.targets = [
      PrinterTarget(
        Uri.parse('ipp://192.168.1.99:631/ipp/print'),
        discoveredName: 'Office printer',
        discoveryId: 'test-printer',
      ),
    ];
    await c.discover();
    expect(c.selectedPrinter!.uri.host, '192.168.1.99');
    expect(c.networkOnline, true);
  });
  testWidgets(
    'automatic refresh runs every 15 seconds and pauses during service work',
    (tester) async {
      await tester.runAsync(() async {
        await c.initialize(scan: false);
        await c.selectPrinter(network.targets.single);
      });
      c.startMonitoring();
      await tester.pump(const Duration(seconds: 15));
      await tester.runAsync(() async {});
      await tester.pump();
      expect(network.calls, 2);
      c.busy = true;
      await tester.pump(const Duration(seconds: 30));
      expect(network.calls, 2);
      c.busy = false;
      c.setAutoRefresh(false);
      await tester.pump(const Duration(seconds: 30));
      expect(network.calls, 2);
    },
  );
}
