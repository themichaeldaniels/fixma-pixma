// Reimplementation of the recovered Canon protocol. See THIRD_PARTY_NOTICES.txt.
import 'dart:typed_data';

String hexOf(List<int> bytes) =>
    bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
List<int> hexBytes(String text) {
  if (text.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(text)) {
    throw const FormatException('Expected complete hexadecimal bytes.');
  }
  return [
    for (var i = 0; i < text.length; i += 2)
      int.parse(text.substring(i, i + 2), radix: 16),
  ];
}

class CanonCodec {
  final Map<String, dynamic> spec;
  CanonCodec(this.spec);
  Uint8List transform(
    List<int> input,
    List<int> keyword, {
    bool decode = false,
  }) {
    if (input.length > 20 || keyword.length > 4) {
      throw StateError('Invalid protocol fragment length.');
    }
    final key = [...keyword, ...List.filled(4 - keyword.length, 0)];
    final bound = [
      for (final j in spec['keywordIndex'])
        (spec['keywordCodes'][j] as int) ^ key[j as int],
    ];
    var seed = 0;
    for (final b in bound) {
      seed = ((seed << 8) | b) & 0xffffffff;
    }
    final index = List<int>.from(
      spec['indexes'][seed % (spec['indexes'] as List).length] as List,
    );
    final codes = List<int>.from(
      spec['codes'][seed % (spec['codes'] as List).length] as List,
    );
    final programs = spec['shifts'] as List;
    final shifts = <int>[];
    for (final program in programs[seed % programs.length] as List) {
      var n = seed;
      for (final action in program as List) {
        final v = action['value'] as int;
        n = switch (action['op']) {
          '=' => v,
          '&' => n & v,
          '%' => n % v,
          '+' => n + v,
          '-' => n - v,
          '*' => n * v,
          '/' => n ~/ v,
          '|' => n | v,
          '^' => n ^ v,
          _ => throw StateError('Unknown codec operator.'),
        };
        n &= 0xffffffff;
      }
      shifts.add(n);
    }
    final source = [...input, ...List.filled(20 - input.length, 0)];
    final out = Uint8List(20);
    for (var i = 0; i < 20; i++) {
      final j = index[i];
      final mask =
          ((seed >> (shifts[j % shifts.length] & 31)) ^ codes[j]) & 255;
      if (decode) {
        out[j] = source[i] ^ mask;
      } else {
        out[i] = source[j] ^ mask;
      }
    }
    return out;
  }

  Uint8List envelope(List<int> operand) {
    if (operand.isEmpty) throw StateError('Empty command.');
    final f =
        (spec['functions'] as Map)[hexOf(operand.take(1).toList())] as Map?;
    if (f == null || operand.length - 1 > (f['indexes'] as List).length) {
      throw StateError('Unsupported command.');
    }
    var state = 0x12345678;
    final out = Uint8List(20)..setRange(0, 4, [0, 18, 1, operand.first]);
    for (var i = 4; i < 20; i++) {
      state = (state * 0x343fd + 0x269ec3) & 0xffffffff;
      out[i] = (state >> 16) & 255;
    }
    final special = f['special'] as List;
    for (var i = 0; i < special.length; i += 2) {
      out[4 + (special[i] as int)] = special[i + 1] as int;
    }
    for (var i = 1; i < operand.length; i++) {
      out[4 + (f['indexes'][i - 1] as int)] = operand[i];
    }
    return out;
  }

  Uint8List encode(List<int> operand, List<int> keyword) => Uint8List.fromList([
    0x85,
    0,
    0,
    ...transform(envelope(operand), keyword),
  ]);
}

class CanonReply {
  final int opcode, status;
  final List<int> data;
  CanonReply(this.opcode, this.status, this.data);
  bool get accepted => status == 0;
  String get reason => switch (status) {
    0 => 'Accepted',
    1 => 'Printer is not ready',
    255 => 'Command is not supported',
    _ => 'Unknown printer status ($status)',
  };
}

class ReplyAssembler {
  final CanonCodec codec;
  final List<int> keyword;
  final int opcode;
  int? expected;
  final bytes = <int>[];
  bool completed = false;
  ReplyAssembler(this.codec, this.keyword, this.opcode);
  CanonReply? feed(List<int> raw) {
    if (completed) throw StateError('Reply already completed.');
    if (raw.isEmpty) {
      if (expected != null) throw StateError('Empty continuation packet.');
      return null;
    }
    if (raw.length != 20) throw StateError('Incomplete printer reply frame.');
    final decoded = codec.transform(raw, keyword, decode: true);
    if (expected == null) {
      final length = (decoded[0] << 8) | decoded[1];
      if (length < 3) throw StateError('Malformed printer reply.');
      expected = length - 1;
      bytes.addAll(decoded.skip(3));
    } else {
      bytes.addAll(decoded);
    }
    if (bytes.length < expected!) return null;
    if (bytes[0] != opcode) {
      throw StateError('The printer replied to a different command.');
    }
    completed = true;
    return CanonReply(opcode, bytes[1], bytes.sublist(2, expected!));
  }
}
