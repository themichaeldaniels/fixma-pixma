import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fixma_pixma/core/ink_counter.dart';
import 'package:xml/xml.dart';

String fixture(String name) =>
    File('test/fixtures/g7000-ink-$name.xml').readAsStringSync();

void main() {
  test('reset request matches the captured successful G7020 command', () {
    final vector = jsonDecode(
      File('test/fixtures/g7000-ink-reset.json').readAsStringSync(),
    ) as Map;
    expect(
      XmlDocument.parse(CanonInkPeer.resetCommand('BK')).rootElement
          .toXmlString(),
      XmlDocument.parse(vector['request'] as String).rootElement.toXmlString(),
    );
    CanonInkPeer.checkResetReply(vector['response'] as String);
    expect(vector['before']['PGBK'], '20');
    expect(vector['after'], {'PGBK': '100', 'C': '30', 'M': '30', 'Y': '30'});
    expect(vector['verified'], true);
  });
  test('outer OK cannot hide a rejected or missing vendor acknowledgment', () {
    final vector = jsonDecode(
      File('test/fixtures/g7000-ink-reset.json').readAsStringSync(),
    ) as Map;
    final reply = vector['response'] as String;
    for (final bad in [
      reply.replaceFirst('<vcn:ijresponse>OK', '<vcn:ijresponse>NG'),
      reply.replaceAll('ResetCounterResponse', 'CleaningResponse'),
      reply.replaceFirst('<vcn:ijresponse>OK</vcn:ijresponse>', ''),
    ]) {
      expect(() => CanonInkPeer.checkResetReply(bad), throwsA(anything));
    }
  });
  test('G7000 capabilities advertise a supported per-color refill reset', () {
    final identity = CanonInkPeer.parseIdentity(fixture('capability'));
    expect(identity.supported, true);
    expect(identity.resetColors, containsAll(['BK', 'C', 'M', 'Y']));
    expect(
      CanonInkPeer.parseIdentity(
        fixture('capability').replaceAll('1.050', '2.000'),
      ).supported,
      false,
    );
    expect(
      CanonInkPeer.parseIdentity(
        fixture('capability').replaceAll('G7000 series', 'G3000 series'),
      ).supported,
      false,
    );
  });
  test(
    'stored counters parse by named color and signed unknown stays unknown',
    () {
      final status = CanonInkPeer.parseCounters(fixture('status'));
      expect(status.levels, {'BK': 20, 'C': 30, 'M': 30, 'Y': 30});
      expect(status.ready, true);
      expect(
        CanonInkPeer.parseCounters(
          fixture('status').replaceFirst('<ivec:level>20', '<ivec:level>-3'),
        ).levels['BK'],
        null,
      );
      expect(
        CanonInkPeer.parseCounters(
          fixture('status').replaceFirst('>idle<', '>processing<'),
        ).ready,
        false,
      );
      expect(
        CanonInkPeer.parseCounters(
          fixture('status').replaceFirst(
            '<ivec:current_support_code/>',
            '<ivec:current_support_code>5B00</ivec:current_support_code>',
          ),
        ).ready,
        false,
      );
    },
  );
  test('reset codec accepts only one of the four full-refill colors', () {
    for (final color in inkNames.keys) {
      final command = CanonInkPeer.resetCommand(color);
      expect(command, contains('servicetype="device"'));
      expect(command, contains('<vcn:resetink>$color</vcn:resetink>'));
      expect(command, contains('<vcn:type id="ink">'));
      expect(command, isNot(contains('StartJob')));
    }
    for (final color in ['all', 'BK,C', '<cmd>', '50', '']) {
      expect(() => CanonInkPeer.resetCommand(color), throwsArgumentError);
    }
    expect(
      () => CanonInkPeer.query('SetConfiguration', 'device'),
      throwsArgumentError,
    );
  });
  test('XML replies reject wrong operations, service, namespaces and DTD', () {
    final text = fixture('status');
    for (final bad in [
      text.replaceAll('GetStatusResponse', 'VendorCmdResponse'),
      text.replaceAll('servicetype="print"', 'servicetype="device"'),
      text.replaceAll(
        'http://www.canon.com/ns/cmd/2008/07/common/',
        'http://example.invalid/',
      ),
      '<!DOCTYPE cmd [<!ENTITY x "x">]>$text',
      text.replaceFirst('>OK<', '>NG<'),
    ]) {
      expect(() => CanonInkPeer.parseCounters(bad), throwsA(anything));
    }
  });
  test(
    'CHMP handles a bodyless POST acknowledgment and fragmented chunked XML',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      final serving = server.first.then((socket) async {
        var pending = <int>[];
        await for (final chunk in socket) {
          pending.addAll(chunk);
          while (true) {
            final text = latin1.decode(pending);
            final end = text.indexOf('\r\n\r\n');
            if (end < 0) break;
            final headers = text.substring(0, end);
            final length = int.parse(
              RegExp(r'Content-Length: (\d+)').firstMatch(headers)?.group(1) ??
                  '0',
            );
            if (pending.length < end + 4 + length) break;
            final request = latin1.decode(pending.sublist(0, end + 4 + length));
            pending = pending.sublist(end + 4 + length);
            requests.add(request);
            if (headers.startsWith('POST ')) {
              socket.write('HTTP/1.1 200 OK\r\nX-CHMP-Version: 1.3.0\r\n\r\n');
            } else {
              final body = utf8.encode(fixture('capability'));
              socket.write(
                'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n',
              );
              for (var i = 0; i < body.length; i += 13) {
                final part = body.sublist(
                  i,
                  i + 13 < body.length ? i + 13 : body.length,
                );
                socket.write('${part.length.toRadixString(16)}\r\n');
                socket.add(part);
                socket.write('\r\n');
                await socket.flush();
              }
              socket.write('0\r\n\r\n');
            }
            await socket.flush();
          }
        }
      });
      final peer = await CanonInkPeer.connect('127.0.0.1', port: server.port);
      try {
        final identity = await peer.identity();
        expect(identity.supported, true);
        expect(requests.length, 2);
        expect(requests.first, contains('X-CHMP-Version: 1.3.0'));
        expect(
          requests.first,
          contains('<ivec:operation>GetCapability</ivec:operation>'),
        );
        expect(requests.last, startsWith('GET /canon/ij/command2/port1'));
      } finally {
        await peer.close();
        await server.close();
        await serving;
      }
    },
  );
  test('unrecognized printer cannot dispatch an ink reset', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final connected = server.first;
    final peer = await CanonInkPeer.connect('127.0.0.1', port: server.port);
    final socket = await connected;
    try {
      await expectLater(peer.resetColor('BK'), throwsStateError);
    } finally {
      await peer.close();
      socket.destroy();
      await server.close();
    }
  });
}
