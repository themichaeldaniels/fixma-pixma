import 'dart:convert';
import 'dart:typed_data';

class IppError extends StateError {
  final int status;
  IppError(this.status)
    : super('Printer refused the request (IPP 0x${status.toRadixString(16)}).');
}

class IppGroup {
  final int tag;
  final Map<String, List<Object?>> attributes;
  IppGroup(this.tag, this.attributes);
}

class IppMessage {
  final List<IppGroup> groups;
  IppMessage(this.groups);
  static Uint8List attribute(int tag, String name, Object value) {
    final n = utf8.encode(name);
    final v = value is bool
        ? [value ? 1 : 0]
        : value is int
        ? [value >> 24 & 255, value >> 16 & 255, value >> 8 & 255, value & 255]
        : utf8.encode(value as String);
    if (n.length > 65535 || v.length > 65535) {
      throw ArgumentError('IPP attribute too long.');
    }
    return Uint8List.fromList([
      tag,
      n.length >> 8,
      n.length & 255,
      ...n,
      v.length >> 8,
      v.length & 255,
      ...v,
    ]);
  }

  /// Only status, job listing, job identity and individual cancellation.
  static Uint8List request(
    int operation,
    Uri printer,
    List<Uint8List> extras, {
    int id = 1,
  }) {
    if (!{8, 9, 10, 11}.contains(operation) || id <= 0 || id > 0x7fffffff) {
      throw ArgumentError('Unsupported IPP operation.');
    }
    final b = BytesBuilder()
      ..add([
        2,
        0,
        0,
        operation,
        id >> 24 & 255,
        id >> 16 & 255,
        id >> 8 & 255,
        id & 255,
        1,
      ]);
    b.add(attribute(0x47, 'attributes-charset', 'utf-8'));
    b.add(attribute(0x48, 'attributes-natural-language', 'en'));
    b.add(attribute(0x45, 'printer-uri', printer.toString()));
    for (final e in extras) {
      b.add(e);
    }
    b.addByte(3);
    return b.takeBytes();
  }

  static IppMessage decode(List<int> packet, {int requestId = 1}) {
    if (packet.length < 9 || packet.length > 1024 * 1024) {
      throw const FormatException('Invalid IPP response size.');
    }
    final data = Uint8List.fromList(packet),
        view = ByteData.sublistView(Uint8List.fromList(packet));
    if (!{1, 2}.contains(data[0]) || view.getUint32(4) != requestId) {
      throw const FormatException('IPP response does not match the request.');
    }
    final status = view.getUint16(2);
    if (status > 255) throw IppError(status);
    int offset = 8, depth = 0, attributeCount = 0;
    final groups = <IppGroup>[];
    IppGroup? group;
    var name = '';
    void need(int n) {
      if (n < 0 || offset + n > data.length) {
        throw const FormatException('Incomplete IPP response.');
      }
    }

    int word() {
      need(2);
      final v = view.getUint16(offset);
      offset += 2;
      return v;
    }

    Uint8List block(int n) {
      need(n);
      final v = Uint8List.sublistView(data, offset, offset + n);
      offset += n;
      return v;
    }

    while (offset < data.length) {
      final tag = data[offset++];
      if (tag == 3) {
        if (depth != 0) throw const FormatException('Unclosed IPP collection.');
        return IppMessage(groups);
      }
      if (tag < 16) {
        if (depth != 0 || tag == 0 || groups.length >= 1024) {
          throw const FormatException('Invalid IPP group.');
        }
        group = IppGroup(tag, {});
        groups.add(group);
        name = '';
        continue;
      }
      if (group == null || ++attributeCount > 16384) {
        throw const FormatException('Invalid IPP attributes.');
      }
      final n = word();
      if (n > 0) name = utf8.decode(block(n), allowMalformed: true);
      final v = block(word());
      if (tag == 0x34) {
        if (++depth > 8) {
          throw const FormatException('IPP collection too deep.');
        }
        continue;
      }
      if (tag == 0x37) {
        if (depth == 0) throw const FormatException('Invalid IPP collection.');
        depth--;
        continue;
      }
      if (depth > 0 || name.isEmpty) continue;
      Object? value;
      if (tag == 0x21 || tag == 0x23) {
        if (v.length != 4) throw const FormatException('Invalid IPP integer.');
        value = ByteData.sublistView(v).getInt32(0);
      } else if (tag == 0x22) {
        if (v.length != 1 || v[0] > 1) {
          throw const FormatException('Invalid IPP boolean.');
        }
        value = v[0] != 0;
      } else if (tag == 0x32 && v.length == 9) {
        final b = ByteData.sublistView(v);
        value =
            '${b.getInt32(0)} × ${b.getInt32(4)} ${v[8] == 3 ? 'dpi' : 'dpcm'}';
      } else if (tag == 0x31 && v.length == 11) {
        final year = (v[0] << 8) | v[1];
        if (year > 0 &&
            v[2] >= 1 &&
            v[2] <= 12 &&
            v[3] >= 1 &&
            v[3] <= 31 &&
            v[4] < 24 &&
            v[5] < 60 &&
            v[6] <= 60 &&
            {43, 45}.contains(v[8])) {
          value =
              '${year.toString().padLeft(4, '0')}-${v[2].toString().padLeft(2, '0')}-${v[3].toString().padLeft(2, '0')}T${v[4].toString().padLeft(2, '0')}:${v[5].toString().padLeft(2, '0')}:${v[6].toString().padLeft(2, '0')}.${v[7]}${String.fromCharCode(v[8])}${v[9].toString().padLeft(2, '0')}:${v[10].toString().padLeft(2, '0')}';
        }
      } else if (tag >= 0x40 && tag <= 0x49 || tag == 0x30) {
        value = utf8.decode(v, allowMalformed: true);
      }
      group.attributes.putIfAbsent(name, () => []).add(value);
    }
    throw const FormatException('IPP response has no end marker.');
  }
}
