import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixma_fixa/controller.dart';
import 'package:pixma_fixa/core/capture_inspector.dart';
import 'package:pixma_fixa/core/network_status.dart';

void main() {
  late Directory temp;
  late CareController c;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('pixma-fixa-support-');
    c = CareController(directory: temp);
  });
  tearDown(() {
    c.dispose();
    temp.deleteSync(recursive: true);
  });

  test('unknown-model support summary preserves useful fields and omits private payloads', () {
    final target = PrinterTarget(
      Uri.parse('ipp://private-printer.local:631/ipp/private-room'),
      discoveredName: 'Private room printer',
      discoveryId: '00000000-0000-1000-8000-001122334455',
    );
    c.selectedPrinter = target;
    c.networkPrinters = [target];
    c.networkStatus = NetworkStatus(
      target: target,
      attributes: {
        'printer-make-and-model': ['Canon TESTMODEL'],
        'printer-firmware-string-version': ['9.999'],
        'printer-serial-number': ['PRIVATE-SERIAL'],
        'printer-name': ['Private room printer'],
        'printer-uuid': [target.discoveryId],
        'printer-state': [3],
        'document-format-supported': ['application/pdf'],
        'sides-supported': ['one-sided'],
        'printer-more-info': ['secret-url-not-allowed'],
      },
    );
    c.lastError = 'Cannot reach ${target.key}; PRIVATE-SERIAL failed.';
    c.history = [
      {
        'kind': 'Canon controls',
        'status': 'Stopped',
        'started': '2026-10-23T12:00:00Z',
        'error': 'raw-history-error-not-included',
        'events': [
          {'raw': 'private-packet'},
        ],
        'jobTitle': 'private-document',
      },
    ];
    final text = c.diagnosticSummary();
    final data = jsonDecode(text) as Map;
    expect(data['schemaVersion'], 2);
    expect(data['networkPrinter']['reportedModel'], 'Canon TESTMODEL');
    expect(data['networkPrinter']['firmware'], '9.999');
    expect(data['networkPrinter']['verifiedFirmwareProfile'], false);
    expect(
      data['networkPrinter']['advertisedCapabilities']['document-format-supported'],
      ['application/pdf'],
    );
    expect(data['recentOperations'][0]['status'], 'Stopped');
    expect(data['recentOperations'][0]['failed'], true);
    for (final private in [
      'PRIVATE-SERIAL',
      'private-printer.local',
      'private-room',
      'Private room printer',
      target.discoveryId,
      'private-packet',
      'private-document',
      'secret-url-not-allowed',
      'raw-history-error-not-included',
    ]) {
      expect(text, isNot(contains(private)), reason: private);
    }
    expect(c.canCheckInkReset, false);
    expect(c.liveValid, false);
  });

  test('summary bounds capabilities and history and keeps missing identity unknown', () {
    final target = PrinterTarget.parse('192.0.2.10');
    c.networkStatus = NetworkStatus(
      target: target,
      attributes: {'media-supported': List.filled(1000, 'x' * 2000)},
    );
    c.history = List.generate(
      100,
      (_) => {
        'kind': 'diagnostic',
        'status': 'Stopped',
        'finished': {'raw': 'excluded'},
      },
    );
    final data = jsonDecode(c.diagnosticSummary()) as Map;
    expect(data['networkPrinter']['reportedModel'], isNull);
    expect(data['networkPrinter']['firmware'], isNull);
    final media =
        data['networkPrinter']['advertisedCapabilities']['media-supported']
            as List;
    expect(media.length, 64);
    expect(media.first.length, 256);
    expect(data['recentOperations'].length, 20);
    expect((data['recentOperations'][0] as Map).containsKey('finished'), false);
    expect(data['serviceReport'], isNull);
  });

  test('redaction removes the full URI before its shorter hostname', () {
    final text = redactedDiagnosticText(
      {'error': 'ipp://printer.local/ipp/private-path printer.local'},
      identifiers: ['printer.local', 'ipp://printer.local/ipp/private-path'],
    );
    expect(text, isNot(contains('private-path')));
    expect(text, isNot(contains('printer.local')));
    expect(jsonDecode(text), isA<Map>());
  });
}
