import 'dart:convert';
import 'dart:typed_data';

import 'ipp_message.dart';

/// Only Get-Printer-Attributes is encoded. No print or maintenance operations.
class IppCodec {
  static const attributes = [
    'printer-name',
    'printer-info',
    'printer-make-and-model',
    'printer-uuid',
    'printer-firmware-name',
    'printer-firmware-string-version',
    'printer-serial-number',
    'printer-state',
    'printer-state-reasons',
    'printer-state-message',
    'printer-is-accepting-jobs',
    'marker-names',
    'marker-colors',
    'marker-types',
    'marker-levels',
    'sides-supported',
    'document-format-supported',
    'media-supported',
    'printer-resolution-supported',
    'color-supported',
  ];

  static Uint8List query(Uri printer, {int requestId = 1}) {
    final out = BytesBuilder();
    void word(int n) => out.add([(n >> 8) & 255, n & 255]);
    void attribute(int tag, String name, String value) {
      final n = utf8.encode(name), v = utf8.encode(value);
      out.addByte(tag);
      word(n.length);
      out.add(n);
      word(v.length);
      out.add(v);
    }

    out.add([
      2,
      0,
      0,
      0x0b,
      (requestId >> 24) & 255,
      (requestId >> 16) & 255,
      (requestId >> 8) & 255,
      requestId & 255,
      1,
    ]);
    attribute(0x47, 'attributes-charset', 'utf-8');
    attribute(0x48, 'attributes-natural-language', 'en');
    attribute(0x45, 'printer-uri', printer.toString());
    for (var i = 0; i < attributes.length; i++) {
      attribute(0x44, i == 0 ? 'requested-attributes' : '', attributes[i]);
    }
    out.addByte(3);
    return out.takeBytes();
  }

  static Map<String, List<Object?>> decode(
    List<int> packet, {
    int requestId = 1,
  }) {
    final result = <String, List<Object?>>{};
    for (final group in IppMessage.decode(
      packet,
      requestId: requestId,
    ).groups.where((g) => g.tag == 4)) {
      for (final entry in group.attributes.entries) {
        result.putIfAbsent(entry.key, () => []).addAll(entry.value);
      }
    }
    return result;
  }
}
