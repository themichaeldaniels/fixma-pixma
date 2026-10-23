import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:printer_care/core/discovery.dart';
import 'package:printer_care/core/ipp.dart';
import 'package:printer_care/core/network_status.dart';
import 'package:printer_care/core/printer_network.dart';

Map<String, List<Object?>> fixture() =>
    (jsonDecode(File('test/fixtures/g7000-ipp.json').readAsStringSync()) as Map)
        .map((k, v) => MapEntry(k as String, List<Object?>.from(v as List)));
NetworkStatus status({Map<String, List<Object?>>? attrs, String? web}) =>
    NetworkStatus(
      target: PrinterTarget.parse('192.168.1.50'),
      attributes: attrs ?? fixture(),
      canon: web == null ? null : CanonWebStatus.parse(web),
    );

List<int> response({int id = 1, int code = 0}) {
  final b = BytesBuilder()..add([2, 0, code >> 8, code & 255, 0, 0, 0, id, 4]);
  void attr(int tag, String name, List<int> value) {
    final n = utf8.encode(name);
    b.add([
      tag,
      n.length >> 8,
      n.length & 255,
      ...n,
      value.length >> 8,
      value.length & 255,
      ...value,
    ]);
  }

  attr(0x42, 'printer-name', utf8.encode('Desk printer'));
  attr(0x21, 'marker-levels', [0, 0, 0, 20]);
  attr(0x21, '', [255, 255, 255, 254]);
  b.addByte(3);
  return b.takeBytes();
}

void main() {
  test(
    'Refusing jobs is busy even with no visible queue or Canon support code',
    () {
      final attrs = fixture()
        ..['printer-state'] = [4]
        ..['printer-is-accepting-jobs'] = [false]
        ..['printer-state-reasons'] = ['spool-area-full-report'];
      final current = status(attrs: attrs);
      expect(current.stateLabel, 'Busy');
      expect(current.issues.single.title, 'Printer spool storage unavailable');
      attrs['printer-is-accepting-jobs'] = [true];
      attrs['printer-state-reasons'] = ['none'];
      expect(status(attrs: attrs).stateLabel, 'Printing');
    },
  );
  test('IPP query encodes only the read-only attribute operation', () {
    final bytes = IppCodec.query(Uri.parse('ipp://192.168.1.50:631/ipp/print'));
    expect(bytes.sublist(0, 8), [2, 0, 0, 11, 0, 0, 0, 1]);
    expect(bytes.last, 3);
    expect(latin1.decode(bytes), contains('printer-firmware-string-version'));
  });
  test(
    'IPP repeated values, signed unknowns, request matching, and bounds',
    () {
      expect(IppCodec.decode(response())['marker-levels'], [20, -2]);
      expect(() => IppCodec.decode(response(id: 2)), throwsFormatException);
      expect(() => IppCodec.decode(response(code: 0x400)), throwsStateError);
      final packet = response();
      for (var i = 0; i < packet.length; i++) {
        expect(
          () => IppCodec.decode(packet.sublist(0, i)),
          throwsFormatException,
          reason: 'truncated at $i',
        );
      }
    },
  );
  test(
    'G7000 supplies align by marker order and missing fields stay unknown',
    () {
      final s = status();
      expect(s.model, 'Canon G7000 series');
      expect(s.firmware, '1.050');
      expect(s.supplies.map((s) => s.percent), [20, 30, 30, 30]);
      final attrs = fixture()..['marker-levels'] = [-1, -2, -3, 0];
      final readings = status(attrs: attrs).supplies;
      expect(readings.map((s) => s.percent), [null, null, null, 0]);
      expect(readings[2].levelText, 'Level unknown');
      expect(readings[3].levelText, '0%');
      attrs.remove('marker-levels');
      attrs.remove('printer-firmware-string-version');
      expect(
        status(attrs: attrs).supplies.every((s) => s.percent == null),
        true,
      );
      expect(status(attrs: attrs).firmware, 'Not reported');
    },
  );
  test(
    'current support code uses live Canon status, not stored error history',
    () {
      expect(
        status(
          web:
              "var g_prndoc='0'; var g_err_url='http://canon/ERR=NO'; ER0=5B00",
        ).issues,
        isEmpty,
      );
      final fault = status(
        web: "var g_prndoc='23296'; var g_err_url='http://canon/ERR=5B00';",
      );
      expect(fault.stateLabel, 'Needs attention');
      expect(fault.issues.single.title, 'Support code 5B00');
      final attrs = fixture()
        ..['printer-state-reasons'] = [
          'media-jam-error',
          'marker-supply-low-warning',
        ];
      expect(status(attrs: attrs).issues.map((i) => i.title), [
        'Paper jam',
        'Ink or toner low',
      ]);
      expect(status(attrs: attrs).stateLabel, 'Needs attention');
      attrs['printer-state-reasons'] = ['none'];
      attrs['printer-state'] = [5];
      expect(status(attrs: attrs).issues.single.title, 'Printer stopped');
    },
  );
  test('address entry accepts hostname, explicit port and URI; rejects credentials and redirects', () {
    expect(PrinterTarget.parse('printer.local').uri.port, 631);
    expect(PrinterTarget.parse('192.168.1.50:8631').uri.port, 8631);
    expect(
      PrinterTarget.parse('ipps://printer.local/ipp/print').uri.scheme,
      'ipps',
    );
    for (final value in [
      'http://example.com',
      'ipp://user:pass@printer.local',
      'printer name',
      'ipp://printer.local/a?x=1',
    ]) {
      expect(() => PrinterTarget.parse(value), throwsFormatException);
    }
  });
  test(
    'DNS-SD records preserve advertised path and port, deduplicate IPP/IPPS',
    () {
      final records = [
        const DnsRecord('Printer._ipp._tcp.local', 33, {
          'port': 8631,
          'host': 'printer.local',
        }, '192.168.1.50'),
        const DnsRecord('Printer._ipp._tcp.local', 16, {
          'rp': 'custom/print',
          'uuid': 'same',
        }, '192.168.1.50'),
        const DnsRecord('printer.local', 1, '192.168.1.51', '192.168.1.50'),
        const DnsRecord('Printer._ipps._tcp.local', 33, {
          'port': 443,
          'host': 'printer.local',
        }, '192.168.1.50'),
        const DnsRecord('Printer._ipps._tcp.local', 16, {
          'rp': 'custom/print',
          'uuid': 'same',
        }, '192.168.1.50'),
      ];
      expect(
        DiscoveryCodec.targets(records).single.key,
        'ipp://192.168.1.51:8631/custom/print',
      );
      expect(DiscoveryCodec.question('_ipp._tcp.local', 12).sublist(12), [
        4,
        95,
        105,
        112,
        112,
        4,
        95,
        116,
        99,
        112,
        5,
        108,
        111,
        99,
        97,
        108,
        0,
        0,
        12,
        128,
        1,
      ]);
    },
  );
  test('DNS decoder rejects pointer loops and truncated records', () {
    final loop = [
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
      192,
      12,
      0,
      1,
      0,
      1,
      0,
      0,
      0,
      120,
      0,
      4,
      1,
      2,
      3,
      4,
    ];
    expect(
      () => DiscoveryCodec.decode(loop, '192.168.1.50'),
      throwsFormatException,
    );
    for (var n = 0; n < 12; n++) {
      expect(
        () => DiscoveryCodec.decode(List.filled(n, 0), 'x'),
        throwsFormatException,
      );
    }
  });
  test(
    'HTTP transport sends an IPP read request to the advertised endpoint',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(request.method, 'POST');
        expect(request.uri.path, '/custom/print');
        final data = await request.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(data.sublist(2, 4), [0, 11]);
        request.response.headers.contentType = ContentType(
          'application',
          'ipp',
        );
        request.response.add(response());
        await request.response.close();
      });
      final reading = await LocalPrinterNetwork().read(
        PrinterTarget(Uri.parse('ipp://127.0.0.1:${server.port}/custom/print')),
      );
      expect(reading.name, 'Desk printer');
      expect(reading.supplies[0].percent, 20);
    },
  );
}
