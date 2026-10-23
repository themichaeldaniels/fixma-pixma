import 'dart:convert';

import 'protocol.dart';

/// Offline-only: this module imports no I/O or connection classes. Input is a
/// single received reply sequence, never a script or set of outbound commands.
Map<String, dynamic> inspectCapture(
  String input,
  Map<String, dynamic> profile,
) {
  if (input.length > 256 * 1024) {
    throw const FormatException('Capture is limited to 256 KB.');
  }
  final v = jsonDecode(input);
  if (v is! Map ||
      v['keyword'] is! String ||
      v['opcode'] is! int ||
      v['frames'] is! List) {
    throw const FormatException(
      'Use JSON with keyword, numeric opcode, and received frames.',
    );
  }
  List<int> bytes(String s, {int? size}) {
    if (!RegExp(r'^(?:[0-9a-fA-F]{2})+$').hasMatch(s) ||
        (size != null && s.length != size * 2)) {
      throw const FormatException('Invalid hexadecimal bytes.');
    }
    return hexBytes(s);
  }

  final key = bytes(v['keyword'] as String, size: 3),
      opcode = v['opcode'] as int;
  if (opcode < 0 || opcode > 255 || (v['frames'] as List).length > 4096) {
    throw const FormatException('Invalid reply sequence.');
  }
  final assembler = ReplyAssembler(CanonCodec(profile), key, opcode);
  CanonReply? reply;
  for (final frame in v['frames'] as List) {
    if (frame is! String || frame.length != 40) {
      throw const FormatException(
        'Each received frame must contain exactly 20 bytes.',
      );
    }
    if (reply != null) {
      throw const FormatException(
        'Unexpected frames after the completed reply.',
      );
    }
    reply = assembler.feed(bytes(frame, size: 20));
  }
  return {
    'complete': reply != null,
    'opcode': opcode,
    'accepted': reply?.accepted,
    'status': reply?.reason ?? 'Incomplete reply',
    'dataBytes': reply?.data.length ?? assembler.bytes.length,
    'decodedHex': reply == null ? '' : hexOf(reply.data),
    'printerCommandsSent': 0,
  };
}

String redactedDiagnosticText(
  Object value, {
  Iterable<String> identifiers = const [],
}) {
  var text = const JsonEncoder.withIndent('  ').convert(value);
  final privateValues =
      identifiers
          .where((v) => v.length >= 4 && v != 'Not reported')
          .toSet()
          .toList()
        ..sort((a, b) => b.length.compareTo(a.length));
  for (final id in privateValues) {
    final escaped = jsonEncode(id);
    text = text.replaceAll(
      escaped.substring(1, escaped.length - 1),
      '[private]',
    );
  }
  return text
      .replaceAll(RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b'), '[address]')
      .replaceAll(
        RegExp(
          r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b',
          caseSensitive: false,
        ),
        '[device ID]',
      )
      .replaceAll(
        RegExp(r'\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b', caseSensitive: false),
        '[hardware address]',
      )
      .replaceAll(RegExp(r'[A-Za-z]:\\[^"\r\n]*'), '[local path]');
}
