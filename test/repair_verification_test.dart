import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:printer_care/controller.dart';
import 'package:printer_care/core/ink_counter.dart';
import 'package:printer_care/core/network_status.dart';
import 'package:printer_care/core/printer_network.dart';
import 'package:printer_care/core/repair_record.dart';
import 'package:printer_care/core/print_queue.dart';

class VerificationNetwork implements PrinterNetwork {
  bool busy = false, fail = false;
  @override
  Future<List<PrinterTarget>> discover() async => [];
  @override
  Future<NetworkStatus> read(PrinterTarget target) async {
    if (fail) throw const SocketException('offline');
    final attrs =
        (jsonDecode(
          File('test/fixtures/g7000-ipp.json').readAsStringSync(),
        ) as Map).map(
          (k, v) => MapEntry(k as String, List<Object?>.from(v as List)),
        );
    attrs['printer-state'] = [busy ? 4 : 3];
    attrs['printer-is-accepting-jobs'] = [!busy];
    attrs['printer-state-reasons'] = [busy ? 'spool-area-full-report' : 'none'];
    return NetworkStatus(
      target: target,
      attributes: attrs,
      canon: const CanonWebStatus(),
    );
  }
}

class VerificationInk implements InkCounterPeer {
  String serial = 'TEST12345', support = '', state = 'idle';
  int writes = 0, reads = 0;
  @override
  Future<InkIdentity> identity() async =>
      InkIdentity('G7000 series', '1.050', serial, {});
  @override
  Future<InkCounters> read() async {
    reads++;
    return InkCounters(state, support, {});
  }

  @override
  Future<void> resetColor(String color) async {
    writes++;
    throw StateError('No writes allowed in verification');
  }

  @override
  Future<void> close() async {}
}

class ReadOnlyQueue implements PrinterQueueService {
  @override
  Future<QueueSnapshot> read(PrinterTarget target) async => QueueSnapshot(
    sourceKey: target.key,
    label: 'Printer',
    identity: 'test',
    jobs: [],
    cancelSupported: true,
  );
  @override
  Future<void> cancel(
    PrinterTarget target,
    QueueSnapshot snapshot,
    QueueJob job,
  ) async => throw StateError('No cancellation permitted');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late CareController c;
  late VerificationNetwork network;
  late VerificationInk ink;
  late RepairRecord record;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('care-verification-');
    network = VerificationNetwork();
    ink = VerificationInk();
    c = CareController(
      directory: dir,
      network: network,
      inkFactory: (_) async => ink,
      printerQueues: ReadOnlyQueue(),
    );
    await c.initialize(scan: false);
    c.selectedPrinter = PrinterTarget.parse('192.168.1.50');
    record = RepairRecord(
      id: 'repair-123',
      serial: 'TEST12345',
      model: 'G7000 series',
      firmware: '1.050',
      createdAt: DateTime.now(),
    )..acknowledged = true;
    c.repairs = [record];
    c.repairStore.write(record);
  });
  tearDown(() {
    c.dispose();
    dir.deleteSync(recursive: true);
  });
  test(
    'selecting another printer clears previous identity and usage checks',
    () async {
      await c.checkConnections();
      expect(c.diagnosticIdentity, isNotNull);
      expect(c.connectionChecks, isNotEmpty);
      await c.selectPrinter(PrinterTarget.parse('192.168.1.51'));
      expect(c.diagnosticIdentity, null);
      expect(c.canonUsage, null);
      expect(c.connectionChecks, isEmpty);
    },
  );
  test(
    'no status check before declared restart and no writes during verification',
    () async {
      await c.checkRepair(record);
      expect(ink.reads, 0);
      expect(record.verified, false);
      c.confirmRepairRestart(record);
      await c.checkRepair(record);
      expect(ink.reads, 1);
      expect(ink.writes, 0);
      expect(record.stage, 'Display check pending');
      final current = c.repairs.single;
      c.confirmRepairDisplay(current, true);
      expect(current.verified, true);
      final restored = CareController(directory: dir);
      await restored.initialize(scan: false);
      expect(restored.repairs.single.verified, true);
      expect(restored.priorAttempt, false);
      restored.dispose();
    },
  );
  test('same-model different serial cannot verify or read counters', () async {
    c.confirmRepairRestart(record);
    ink.serial = 'DIFFERENT';
    await c.checkRepair(record);
    expect(c.lastError, contains('different printer'));
    expect(ink.reads, 0);
    expect(c.repairs.single.verified, false);
  });
  test('5B00 and Busy override prior display confirmation', () async {
    c.confirmRepairRestart(record);
    c.confirmRepairDisplay(record, true);
    ink.support = '5B00';
    ink.state = 'notready';
    network.busy = true;
    await c.checkRepair(record);
    expect(c.repairs.single.stage, 'Needs attention');
    expect(c.repairs.single.faultAbsent, false);
  });
  test(
    'lost connection invalidates previous successful verification',
    () async {
      c.confirmRepairRestart(record);
      c.confirmRepairDisplay(record, true);
      await c.checkRepair(record);
      final current = c.repairs.single;
      expect(current.verified, true);
      network.fail = true;
      await c.checkRepair(current);
      expect(c.repairs.single.verified, false);
      expect(c.repairs.single.observation, contains('offline'));
    },
  );
  test('connection checks explain an empty queue and printer Busy without mutations', () async {
    network.busy = true;
    ink.state = 'notready';
    await c.checkConnections();
    expect(
      c.connectionChecks.any(
        (r) => r.area == 'Local network' && r.status == 'Busy',
      ),
      true,
    );
    expect(
      c.connectionChecks.firstWhere((r) => r.area == 'Printer queue').detail,
      contains('empty queue'),
    );
    expect(ink.writes, 0);
    expect(c.history.first['writeCommandsSent'], 0);
    c.trackDeviceIssue();
    expect(
      c.repairs.length,
      1,
      reason: 'Existing unfinished repair is retained',
    );
  });
}
