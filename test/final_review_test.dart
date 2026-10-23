import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fixma_pixma/controller.dart';
import 'package:fixma_pixma/core/capture_inspector.dart';
import 'package:fixma_pixma/core/canon_maintenance.dart';
import 'package:fixma_pixma/core/discovery.dart';
import 'package:fixma_pixma/core/ipp_message.dart';
import 'package:fixma_pixma/core/network_status.dart';
import 'package:fixma_pixma/core/print_queue.dart';
import 'package:fixma_pixma/core/report_comparison.dart';
import 'package:fixma_pixma/core/report.dart';

import 'canon_maintenance_test.dart' show MaintenancePrinter;
import 'ink_reset_workflow_test.dart' show RefillPrinter;
import 'queue_test.dart' show FakePrinterQueue;
import 'release_reliability_test.dart' show FailingClosePeer;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late CareController c;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('fixma-pixma-review-');
    c = CareController(directory: temp);
  });
  tearDown(() {
    if (!c.disposed) c.dispose();
    temp.deleteSync(recursive: true);
  });

  test('redaction preserves JSON field names and primitive types', () {
    final encoded = redactedDiagnosticText(
      {
        'detail': 'true 1000 detail',
        'enabled': true,
        'count': 1000,
        'nested': [
          {'detail': 'TRUE'},
        ],
      },
      identifiers: ['true', '1000', 'detail'],
    );
    final value = jsonDecode(encoded) as Map;
    expect(value['detail'], '[private] [private] [private]');
    expect(value['enabled'], true);
    expect(value['count'], 1000);
    expect(value['nested'][0]['detail'], '[private]');
  });

  test('quoted paths, forward paths, network paths and email redact without corrupting JSON', () {
    final encoded = redactedDiagnosticText({
      'quoted': 'Failed at C:\\Users\\O\'Connor\\"quoted"\\file.json',
      'forward': 'Failed at D:/Private Folder/report.json',
      'unc': r'Failed at \\private-server\private-share\file.json',
      'unix': 'Failed at /home/private-owner/file',
      'uri': 'http://private-user:private-password@[2001:db8::1]/private-path',
      'email': 'private-owner@example.invalid',
    });
    expect(jsonDecode(encoded), isA<Map>());
    for (final secret in [
      'Connor',
      'Private Folder',
      'private-server',
      'private-share',
      'private-owner',
      'private-password',
      '2001:db8::1',
      'private-path',
    ]) {
      expect(encoded, isNot(contains(secret)), reason: secret);
    }
  });

  test(
    'summary redacts identities and document metadata from earlier operations',
    () {
      c.history = [
        {
          'kind': 'queue status',
          'status': 'Stopped',
          'printer': {'serial': 'OLD-PRIVATE-SERIAL'},
          'jobs': [
            {'title': 'Private document', 'owner': 'Private owner'},
          ],
          'network': {
            'model': 'Canon TESTMODEL',
            'name': 'Earlier printer',
            'attributes': {
              'printer-serial-number': ['OLD-NETWORK-SERIAL'],
            },
          },
        },
      ];
      c.lastError = 'OLD-PRIVATE-SERIAL OLD-NETWORK-SERIAL Private document Private owner Earlier printer';
      final encoded = c.diagnosticSummary();
      expect(jsonDecode(encoded)['currentErrors']['operation'], isNotEmpty);
      for (final secret in [
        'OLD-PRIVATE-SERIAL',
        'OLD-NETWORK-SERIAL',
        'Private document',
        'Private owner',
        'Earlier printer',
      ]) {
        expect(encoded, isNot(contains(secret)), reason: secret);
      }
    },
  );

  List<int> dnsARecords(int count) => [
    0,
    0,
    128,
    0,
    0,
    0,
    count >> 8,
    count & 255,
    0,
    0,
    0,
    0,
    for (var i = 0; i < count; i++) ...[
      0,
      0,
      1,
      0,
      1,
      0,
      0,
      0,
      1,
      0,
      4,
      192,
      0,
      2,
      1,
    ],
  ];
  test('discovery caps total records and ignores further packets', () {
    final window = DiscoveryWindow();
    for (var i = 0; i < 10; i++) {
      window.add(dnsARecords(512), '192.0.2.1');
    }
    expect(window.full, true);
    expect(window.records.length, DiscoveryWindow.maxRecords);
    expect(window.packets, 4);
  });
  test('malformed packets still consume the discovery packet budget', () {
    final window = DiscoveryWindow();
    for (var i = 0; i < DiscoveryWindow.maxPackets; i++) {
      expect(() => window.add([], '192.0.2.1'), throwsFormatException);
    }
    expect(window.full, true);
    window.add(dnsARecords(1), '192.0.2.1');
    expect(window.records, isEmpty);
  });
  test(
    'overlong expanded DNS names and invalid record boundaries are rejected',
    () {
      final name = List.filled(4, 'a' * 63).join('.');
      expect(() => DiscoveryCodec.question(name, 12), throwsFormatException);
      final longReply = [
        0,
        0,
        128,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        for (var i = 0; i < 4; i++) ...[63, ...List.filled(63, 97)],
        0,
        0,
        1,
        0,
        1,
      ];
      expect(
        () => DiscoveryCodec.decode(longReply, '192.0.2.1'),
        throwsFormatException,
      );
      final invalidPtr = [
        0,
        0,
        128,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        12,
        0,
        1,
        0,
        0,
        0,
        1,
        0,
        1,
        192,
        12,
      ];
      expect(
        () => DiscoveryCodec.decode(invalidPtr, '192.0.2.1'),
        throwsFormatException,
      );
    },
  );
  test('invalid discovery ports never become connection targets', () {
    expect(
      DiscoveryCodec.targets([
        const DnsRecord('Printer._ipp._tcp.local', 33, {
          'port': 0,
          'host': 'printer.local',
        }, '192.0.2.1'),
      ]),
      isEmpty,
    );
  });
  test('malformed IPP booleans cannot report acceptance of jobs', () {
    final attr = IppMessage.attribute(0x22, 'printer-is-accepting-jobs', true);
    attr[attr.length - 1] = 2;
    expect(
      () => IppMessage.decode([2, 0, 0, 0, 0, 0, 0, 1, 4, ...attr, 3]),
      throwsFormatException,
    );
  });
  test('nested report imports have a depth and total report limit', () {
    final report = ServiceReport.parse(
      File('assets/sample-report.txt').readAsStringSync(),
      sample: true,
    ).toJson();
    Map<String, dynamic> nested = report;
    for (var i = 0; i < 20; i++) {
      nested = {'report': nested};
    }
    expect(() => importReports(jsonEncode(nested)), throwsFormatException);
    expect(
      () => importReports(
        jsonEncode(List.filled(101, {...report, 'report': report})),
      ),
      throwsFormatException,
    );
  });
  test('loaded history stays within an aggregate memory budget', () {
    final folder = Directory('${temp.path}/history')..createSync();
    final entry = {
      'started': '2026-10-23T10:00:00',
      'kind': 'test',
      'status': 'Completed',
      'padding': 'x' * (12 * 1024 * 1024),
    };
    for (var i = 1; i <= 3; i++) {
      File('${folder.path}/$i.json').writeAsStringSync(jsonEncode(entry));
    }
    c.refreshHistory();
    expect(c.history.length, 2);
  });
  test(
    'disposal handles a helper cleanup failure without an unhandled future',
    () async {
      c.activePeer = FailingClosePeer();
      c.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(c.disposed, true);
    },
  );
  test('future-dated queue confirmation cannot cancel a job after a clock rollback', () async {
    final target = PrinterTarget.parse('192.0.2.1'),
        backend = FakePrinterQueue(PrinterTarget.parse('192.0.2.1'));
    c.dispose();
    c = CareController(directory: temp, printerQueues: backend)
      ..selectedPrinter = target;
    final snapshot = QueueSnapshot(
      sourceKey: target.key,
      label: 'Test',
      identity: 'uuid-test',
      jobs: backend.jobs,
      cancelSupported: true,
      readAt: DateTime.now().add(const Duration(days: 1)),
    );
    c.printerJobs = snapshot;
    await c.cancelJobs(snapshot, snapshot.jobs, confirmed: true);
    expect(backend.canceled, isEmpty);
    expect(c.lastError, contains('out of date'));
  });
  test(
    'future-dated ink confirmation cannot dispatch a refill reset',
    () async {
      final target = PrinterTarget.parse('192.0.2.1'),
          printer = RefillPrinter(temp);
      c.dispose();
      c = CareController(directory: temp, inkFactory: (_) async => printer)
        ..selectedPrinter = target;
      final check = InkResetCheck(
        target,
        await printer.identity(),
        await printer.read(),
        checkedAt: DateTime.now().add(const Duration(days: 1)),
      );
      await c.resetInkCounts(check, {'BK'}, filledToUpperLine: true);
      expect(printer.sent, isEmpty);
      expect(c.lastError, contains('fresh ink check'));
    },
  );
  test(
    'future-dated Canon controls cannot dispatch maintenance or setting writes',
    () async {
      final target = PrinterTarget.parse('192.0.2.1'),
          printer = MaintenancePrinter(temp);
      c.dispose();
      c = CareController(
        directory: temp,
        maintenanceFactory: (_) async => printer,
      )..selectedPrinter = target;
      c.canonControls = CanonControlCheck(
        target,
        await printer.identity(),
        await printer.capabilities(),
        await printer.settings(),
        checkedAt: DateTime.now().add(const Duration(days: 1)),
      );
      await c.runCanonTask(CanonTask.cleaning, prepared: true);
      await c.saveCanonSetting('quiet', 'ON');
      expect(printer.commands, 0);
      expect(printer.settingWrites, 0);
    },
  );
}
