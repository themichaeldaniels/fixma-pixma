import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:printer_care/core/protocol.dart';
import 'package:printer_care/core/report.dart';
import 'package:printer_care/core/connection.dart';

void main() {
  final spec = jsonDecode(
    File('assets/protocol.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final codec = CanonCodec(spec), key = hexBytes('e47c5a');
  test('36 independent known-frame vectors and inverse decoding', () {
    final vectors = jsonDecode(
      File('test/fixtures/protocol_vectors.json').readAsStringSync(),
    ) as List;
    for (final row in vectors) {
      expect(
        hexOf(
          codec.encode(
            hexBytes(row['operand'] as String),
            hexBytes(row['keyword'] as String),
          ),
        ),
        row['frame'],
      );
      expect(
        hexOf(
          codec.transform(
            hexBytes((row['frame'] as String).substring(6)),
            hexBytes(row['keyword'] as String),
            decode: true,
          ),
        ),
        row['envelope'],
      );
    }
  });
  test('captured G7000 version decodes with resolution profile', () {
    final resolution = Map<String, dynamic>.from(spec['resolution'] as Map);
    final bytes = CanonCodec(resolution).transform(
      hexBytes('e790c0848ba047873c2d4741b0d8d6d4b357beeb'),
      List<int>.from(resolution['keyword'] as List),
      decode: true,
    );
    expect(latin1.decode(bytes).split('\x00').first, 'G7000 series');
  });
  test('continuation assembly preserves complete 63-byte response', () {
    final body = [0x15, 0, ...List.generate(61, (i) => i)],
        framed = [0, 64, 1, ...body];
    final a = ReplyAssembler(codec, key, 0x15);
    CanonReply? result;
    for (var i = 0; i < framed.length; i += 20) {
      result = a.feed(
        codec.transform(
          framed.sublist(i, (i + 20).clamp(0, framed.length)),
          key,
        ),
      );
    }
    expect(result!.accepted, true);
    expect(result.data, List.generate(61, (i) => i));
  });
  test('empty first polls are pending; empty continuation is rejected', () {
    final a = ReplyAssembler(codec, key, 0x15);
    expect(a.feed([]), null);
    a.feed(codec.transform([0, 40, 1, 0x15, 0], key));
    expect(() => a.feed([]), throwsStateError);
  });
  test('wrong opcode and malformed frame are rejected', () {
    expect(
      () => ReplyAssembler(
        codec,
        key,
        0x10,
      ).feed(codec.transform([0, 3, 1, 0x15, 0], key)),
      throwsStateError,
    );
    expect(
      () => ReplyAssembler(
        codec,
        key,
        0x10,
      ).feed(codec.transform(List.filled(20, 0), key)),
      throwsStateError,
    );
  });
  test('unknown, unsupported, and not-ready states are never success', () {
    for (final status in [1, 2, 255]) {
      final result = ReplyAssembler(
        codec,
        key,
        0x10,
      ).feed(codec.transform([0, 3, 1, 0x10, status], key));
      expect(result!.accepted, false);
    }
  });
  test('service report parses usage and distinguishes error history', () {
    final r = ServiceReport.parse(
      File('assets/sample-report.txt').readAsStringSync(),
      sample: true,
    );
    expect(r.waste, 0);
    expect(r.pages, 1854);
    expect(r.copies, 40);
    expect(r.frontPages, 1792);
    expect(r.rearPages, 62);
    expect(r.errorCodes, contains('5B00'));
    expect(r.sample, true);
    expect(r.resetCount, 1);
  });
  test('non-Canon text is not accepted as a service report', () {
    expect(() => ServiceReport.parse('D=100.0'), throwsFormatException);
  });
  String? rule({
    bool live = true,
    double? counter = 100,
    String firmware = '1.050',
    bool prior = false,
    bool serviced = true,
    DateTime? capturedAt,
  }) => ResetRules.blocked(
    live: live,
    counter: counter,
    firmware: firmware,
    priorAttempt: prior,
    serviced: serviced,
    capturedAt: capturedAt ?? DateTime.now(),
  );
  test('sample and stale reports cannot enable reset', () {
    expect(rule(live: false), isNotNull);
    expect(
      rule(capturedAt: DateTime.now().subtract(const Duration(hours: 1))),
      isNotNull,
    );
  });
  test('zero or absent counter cannot enable reset', () {
    expect(rule(counter: 0), isNotNull);
    expect(rule(counter: null), isNotNull);
  });
  test('firmware, servicing, and one-shot guard are enforced', () {
    expect(rule(firmware: '1.999'), isNotNull);
    expect(rule(prior: true), isNotNull);
    expect(rule(serviced: false), isNotNull);
    expect(rule(), null);
  });
  test('a rejected selector never sends a subsequent command', () async {
    final fake = RejectedPeer();
    await expectLater(
      exchange(fake, '10077c', progress: (_) {}, pause: (_) async {}),
      throwsStateError,
    );
    expect(fake.operations, ['command', 'poll']);
  });
}

class RejectedPeer implements PrinterPeer {
  final operations = <String>[];
  @override
  Future<dynamic> call(
    String op, [
    Map<String, dynamic> args = const {},
  ]) async {
    operations.add(op);
    if (op == 'poll') {
      return {
        'continuation': false,
        'reply': {'accepted': false, 'reason': 'Not ready'},
      };
    }
    return {};
  }

  @override
  Future<void> close() async {}
}
