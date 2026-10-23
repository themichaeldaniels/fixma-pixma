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

/// Known identifiers are collected from structured evidence only. Raw captures
/// are neither included in a summary nor interpreted as executable content.
Set<String> knownDiagnosticIdentifiers(Iterable<Object?> evidence) {
  final found = <String>{}, models = <String>{};
  var remaining = 50000;
  void visit(Object? value, int depth) {
    if (depth > 16 || remaining-- <= 0 || found.length >= 2048) return;
    if (value is Map) {
      for (final entry in value.entries) {
        if (remaining <= 0 || found.length >= 2048) break;
        final key = entry.key.toString().toLowerCase();
        final data = entry.value;
        final strings = data is String
            ? [data]
            : data is List
            ? data.whereType<String>().take(256)
            : <String>[];
        for (final data in strings) {
          if (key == 'model' || key == 'printer-make-and-model') {
            models.add(data);
          }
          if (const {
            'serial',
            'product_serialnumber',
            'printer-serial-number',
            'printer-uuid',
            'uuid',
            'host',
            'discoveryid',
            'discoveredname',
            'printer-name',
            'name',
            'owner',
            'job-originating-user-name',
            'title',
            'job-name',
            'queue',
            'uri',
            'path',
            'sourcekey',
            'token',
          }.contains(key)) {
            found.add(data);
            final uri = Uri.tryParse(data);
            if (uri != null && uri.host.isNotEmpty) found.add(uri.host);
          }
        }
        visit(data, depth + 1);
      }
    } else if (value is List) {
      for (final item in value) {
        if (remaining <= 0) break;
        visit(item, depth + 1);
      }
    }
  }

  for (final item in evidence) {
    if (remaining <= 0) break;
    visit(item, 0);
  }
  return found..removeAll(models);
}

String redactedDiagnosticText(
  Object value, {
  Iterable<String> identifiers = const [],
}) {
  final privateValues =
      identifiers
          .where((v) => v.length >= 4 && v != 'Not reported')
          .toSet()
          .toList()
        ..sort((a, b) => b.length.compareTo(a.length));
  final known = privateValues.isEmpty
      ? null
      : RegExp(
          privateValues.map(RegExp.escape).join('|'),
          caseSensitive: false,
        );
  String redactString(String text) {
    // Work on decoded strings, then encode once. Substitution must never alter
    // JSON syntax, field names, numbers or booleans.
    text = text
        .replaceAll(
          RegExp(
            r'''(?:https?|ipps?|file)://[^\s<>"']+''',
            caseSensitive: false,
          ),
          '[address]',
        )
        .replaceAll(
          RegExp(
            r'''[A-Za-z]:[\\/][^\r\n]*|\\\\[^\r\n]*|/(?:Users|home)/[^\r\n]*''',
          ),
          '[local path]',
        )
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
        .replaceAll(
          RegExp(
            r'\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
            caseSensitive: false,
          ),
          '[email]',
        );
    return known == null ? text : text.replaceAll(known, '[private]');
  }

  Object? redact(Object? item) {
    if (item is String) return redactString(item);
    if (item is List) return item.map(redact).toList();
    if (item is Map) return item.map((key, v) => MapEntry(key, redact(v)));
    return item;
  }

  return const JsonEncoder.withIndent('  ')
      .convert(redact(jsonDecode(jsonEncode(value))));
}
