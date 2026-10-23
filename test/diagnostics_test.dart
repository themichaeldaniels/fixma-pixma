import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixma_fixa/controller.dart';
import 'package:pixma_fixa/core/model_support.dart';
import 'package:pixma_fixa/core/repair_record.dart';
import 'package:pixma_fixa/core/report.dart';
import 'package:pixma_fixa/core/report_comparison.dart';
import 'package:pixma_fixa/core/capture_inspector.dart';
import 'package:pixma_fixa/core/protocol.dart';
import 'package:pixma_fixa/core/canon_usage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late String raw;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('care-diagnostics-');
    raw = File('assets/sample-report.txt').readAsStringSync();
  });
  tearDown(() => dir.deleteSync(recursive: true));
  RepairRecord record() => RepairRecord(
    id: 'repair-123',
    serial: 'TEST12345',
    model: 'G7000 series',
    firmware: '1.050',
    createdAt: DateTime(2026, 10, 20),
    beforeCounter: 100,
  );

  test(
    'candidate and unknown firmware profiles cannot grant verified features',
    () {
      expect(
        ModelSupport.find('Canon G6000 series')!.matchesFirmware('1.070'),
        false,
      );
      expect(
        ModelSupport.find('Canon G7000 series')!.matchesFirmware('1.051'),
        false,
      );
      expect(
        ModelSupport.find('Canon G7000 series')!.matchesFirmware('1.050'),
        true,
      );
      expect(ModelSupport.find('Canon G7000 series modified'), null);
      expect(ModelSupport.find('unidentified printer'), null);
    },
  );
  test('USB identity change is evidence, never a model verification', () {
    final checks = usbChecks(
      [
        {'path': 'new', 'service': true},
      ],
      {'old'},
      '',
    );
    expect(checks.last.status, '1 added · 1 removed');
    expect(checks[1].detail, contains('verify the model'));
    expect(
      usbChecks(
        [
          {'path': 'a', 'service': true},
          {'path': 'b', 'service': true},
        ],
        null,
        '',
      )[1].attention,
      true,
    );
    expect(usbChecks([], null, 'helper missing').single.status, 'Unavailable');
  });
  test('zero readback and acknowledgment do not prove a repair', () {
    final r = record()
      ..acknowledged = true
      ..afterCounter = 0;
    expect(r.stage, 'Restart pending');
    r.confirmRestart();
    expect(r.stage, 'Status check pending');
    r.checkedAt = DateTime.now();
    r.identityMatched = true;
    r.ready = true;
    r.faultAbsent = true;
    expect(r.stage, 'Display check pending');
    r.displayClear = true;
    expect(r.verified, true);
    r.confirmRestart();
    expect(r.verified, false);
    expect(r.checkedAt, null);
    expect(r.displayClear, false);
  });
  test('uncertain command remains uncertain even with later normal status', () {
    final r = record()
      ..restartConfirmed = true
      ..checkedAt = DateTime.now()
      ..identityMatched = true
      ..ready = true
      ..faultAbsent = true
      ..displayClear = true;
    expect(r.verified, false);
    expect(r.stage, 'Result uncertain');
  });
  test(
    'repair store overwrites atomically and restores evidence across launches',
    () {
      final store = RepairStore(Directory('${dir.path}/repairs'));
      final r = record();
      store.write(r);
      r.acknowledged = true;
      store.write(r);
      expect(store.read().single.acknowledged, true);
      File('${store.directory.path}/repair-999.json')
          .writeAsStringSync('{broken');
      expect(store.read().length, 1);
      final bad = RepairRecord(
        id: '../escape',
        serial: 'TEST',
        model: 'G7000',
        firmware: '1',
        createdAt: DateTime.now(),
      );
      expect(() => store.write(bad), throwsFormatException);
    },
  );
  test(
    'old reset guard migrates once and remains an effective one-shot guard',
    () async {
      final guard = File('${dir.path}/reset-TEST12345.json')
        ..writeAsStringSync(
          jsonEncode({
            'serial': 'TEST12345',
            'time': '2026-10-20T10:00:00',
            'state': 'Clear acknowledged; restart verification pending',
          }),
        );
      final original = guard.readAsStringSync();
      final c = CareController(directory: dir);
      await c.initialize(scan: false);
      expect(c.repairs.single.stage, 'Restart pending');
      c.restoreRepairs();
      expect(c.repairs.length, 1);
      expect(guard.readAsStringSync(), original);
      c.dispose();
    },
  );
  test(
    'comparison requires same identity, data class, and chronological order',
    () {
      final a = ServiceReport.parse(raw, capturedAt: DateTime(2026, 10, 19));
      final b = ServiceReport.parse(
        raw.replaceFirst('D=000.0', 'D=010.0'),
        capturedAt: DateTime(2026, 10, 20),
      );
      expect(ReportComparison(a, b).rows[1].$4, '+10.0 points');
      expect(() => ReportComparison(b, a), throwsFormatException);
      expect(
        () => ReportComparison(
          a,
          ServiceReport.parse(raw.replaceAll('DEMO-PRINTER', 'OTHER-PRINTER')),
        ),
        throwsFormatException,
      );
      expect(
        () => ReportComparison(a, ServiceReport.parse(raw, sample: true)),
        throwsFormatException,
      );
    },
  );
  test(
    'raw imports cannot turn into live diagnostic or reset eligibility',
    () async {
      final c = CareController(directory: dir);
      await c.initialize(scan: false);
      c.addComparisonReports(raw);
      expect(c.report, null);
      expect(c.liveValid, false);
      expect(c.comparisonReports.single.sample, true);
      c.dispose();
      final restored = CareController(directory: dir);
      await restored.initialize(scan: false);
      expect(restored.comparisonReports.length, 1);
      expect(restored.report, null);
      expect(restored.resetBlocked, contains('live diagnostic'));
      restored.dispose();
    },
  );
  test(
    'saved history JSON imports without trusting its redundant serial fields',
    () {
      final v = ServiceReport.parse(raw).toJson()..['serial'] = 'FORGED';
      final imported = importReports(jsonEncode({'report': v}));
      expect(imported.single.serial, 'DEMO-PRINTER');
      expect(
        () => importReports('x' * (2 * 1024 * 1024 + 1)),
        throwsFormatException,
      );
    },
  );
  test(
    'offline captured reply validates ordering and decodes without a transport',
    () {
      final profile = jsonDecode(
        File('assets/protocol.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final codec = CanonCodec(profile), key = hexBytes('010203');
      final frame = hexOf(
        codec.transform([0, 3, 1, 0x15, 0, ...List.filled(15, 0)], key),
      );
      final input = jsonEncode({
        'keyword': '010203',
        'opcode': 21,
        'frames': [frame],
      });
      final result = inspectCapture(input, profile);
      expect(result['complete'], true);
      expect(result['accepted'], true);
      expect(result['printerCommandsSent'], 0);
      expect(
        () => inspectCapture(
          jsonEncode({
            'keyword': '010203',
            'opcode': 21,
            'frames': [frame, frame],
          }),
          profile,
        ),
        throwsFormatException,
      );
      expect(
        () =>
            inspectCapture('{"keyword":"xx","opcode":21,"frames":[]}', profile),
        throwsFormatException,
      );
    },
  );
  test('shared diagnostic summary removes known identity, addresses and local paths', () {
    final result = redactedDiagnosticText(
      {
        'error': r'C:\Users\Owner\PixmaFixa helper 192.168.1.20',
        'detail': 'TEST12345 printer.local 34:9f:7b:00:00:00',
      },
      identifiers: ['TEST12345', 'printer.local'],
    );
    expect(result, isNot(contains('Owner')));
    expect(result, isNot(contains('192.168.1.20')));
    expect(result, isNot(contains('TEST12345')));
    expect(result, isNot(contains('printer.local')));
    expect(jsonDecode(result), isA<Map>());
  });
  test(
    'normal-mode usage fields preserve missing and invalid values as unknown',
    () {
      const response =
          '<?xml version="1.0"?><cmd xmlns:ivec="http://www.canon.com/ns/cmd/2008/07/common/" xmlns:vcn="http://www.canon.com/ns/cmd/2008/07/canon/">'
          '<ivec:contents><ivec:operation>GetStatusResponse</ivec:operation><ivec:param_set servicetype="device"><ivec:response>OK</ivec:response>'
          '<vcn:total_paper_num physicalinputbin="inputbin_p1">62</vcn:total_paper_num><vcn:total_paper_num physicalinputbin="inputbin_p2">1792</vcn:total_paper_num>'
          '<vcn:head_replacement_count color="Black">1</vcn:head_replacement_count><vcn:head_replacement_count color="Color">1</vcn:head_replacement_count>'
          '</ivec:param_set></ivec:contents></cmd>';
      final parsed = CanonUsage.parse(response);
      expect(parsed.totalPages, 1854);
      expect(parsed.frontPages, 1792);
      expect(parsed.rearPages, 62);
      expect(parsed.blackHeadCount, 1);
      final invalid = CanonUsage.parse(
        response.replaceFirst('>62<', '>-1<').replaceFirst('>1<', '>unknown<'),
      );
      expect(invalid.rearPages, null);
      expect(invalid.totalPages, null);
      expect(invalid.blackHeadCount, null);
      expect(
        () => CanonUsage.parse(
          response.replaceFirst('servicetype="device"', 'servicetype="print"'),
        ),
        throwsStateError,
      );
    },
  );
}
