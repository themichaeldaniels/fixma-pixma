import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'network_status.dart';

class DnsRecord {
  final String name;
  final int type;
  final Object value;
  final String source;
  const DnsRecord(this.name, this.type, this.value, this.source);
}

/// One discovery window has a fixed memory and packet budget, shared across
/// interfaces. Malformed packets consume the budget too.
class DiscoveryWindow {
  static const maxPackets = 256, maxRecords = 2048;
  final records = <DnsRecord>[];
  int packets = 0;
  bool get full => packets >= maxPackets || records.length >= maxRecords;
  void add(List<int> packet, String source) {
    if (full) return;
    packets++;
    final decoded = DiscoveryCodec.decode(packet, source);
    records.addAll(decoded.take(maxRecords - records.length));
  }
}

/// Bounded DNS decoding, including compressed names in additional records.
class DiscoveryCodec {
  static List<int> question(String name, int type) {
    final out = BytesBuilder()..add([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    var nameLength = 1;
    for (final label in name.split('.').where((s) => s.isNotEmpty)) {
      final value = utf8.encode(label);
      if (value.length > 63) throw const FormatException('DNS label too long.');
      nameLength += value.length + 1;
      if (nameLength > 255) throw const FormatException('DNS name too long.');
      out.addByte(value.length);
      out.add(value);
    }
    // Ephemeral source port + QU flag: receive unicast replies without claiming 5353.
    out.add([0, type >> 8, type & 255, 0x80, 1]);
    return out.takeBytes();
  }

  static List<DnsRecord> decode(List<int> packet, String source) {
    final data = Uint8List.fromList(packet),
        bytes = ByteData.sublistView(Uint8List.fromList(packet));
    void need(int at, int count) {
      if (at < 0 || at + count > data.length) {
        throw const FormatException('Incomplete DNS packet.');
      }
    }

    int word(int at) {
      need(at, 2);
      return bytes.getUint16(at);
    }

    (String, int) nameAt(int at) {
      final labels = <String>[], seen = <int>{};
      int? end;
      var expandedLength = 1;
      while (true) {
        need(at, 1);
        if (!seen.add(at) || seen.length > 128) {
          throw const FormatException('DNS compression loop.');
        }
        final length = data[at++];
        if (length == 0) return (labels.join('.'), end ?? at);
        if (length & 0xc0 == 0xc0) {
          need(at, 1);
          end ??= at + 1;
          at = ((length & 0x3f) << 8) | data[at];
          continue;
        }
        if (length > 63) throw const FormatException('Invalid DNS name.');
        expandedLength += length + 1;
        if (expandedLength > 255) {
          throw const FormatException('DNS name is too long.');
        }
        need(at, length);
        labels.add(
          utf8.decode(data.sublist(at, at + length), allowMalformed: true),
        );
        at += length;
      }
    }

    need(0, 12);
    if (data[2] & 0x80 == 0) return [];
    var pos = 12;
    final questions = word(4), count = word(6) + word(8) + word(10);
    if (questions + count > 512) {
      throw const FormatException('DNS packet too large.');
    }
    for (var i = 0; i < questions; i++) {
      pos = nameAt(pos).$2;
      need(pos, 4);
      pos += 4;
    }
    final result = <DnsRecord>[];
    for (var i = 0; i < count; i++) {
      final (name, end) = nameAt(pos);
      pos = end;
      need(pos, 10);
      final type = word(pos),
          length = word(pos + 8),
          ttl = bytes.getUint32(pos + 4);
      pos += 10;
      need(pos, length);
      final next = pos + length;
      Object? value;
      if (ttl == 0) {
        pos = next;
        continue;
      }
      if (type == 1 && length == 4) value = data.sublist(pos, next).join('.');
      if (type == 12) {
        final decoded = nameAt(pos);
        if (decoded.$2 != next) {
          throw const FormatException('Invalid DNS PTR size.');
        }
        value = decoded.$1;
      }
      if (type == 33 && length >= 7) {
        final decoded = nameAt(pos + 6);
        if (decoded.$2 != next) {
          throw const FormatException('Invalid DNS SRV size.');
        }
        value = {'port': word(pos + 4), 'host': decoded.$1};
      }
      if (type == 16) {
        final text = <String, String>{};
        while (pos < next) {
          final size = data[pos++];
          if (pos + size > next) {
            throw const FormatException('Invalid DNS TXT record.');
          }
          final entry = utf8.decode(
            data.sublist(pos, pos + size),
            allowMalformed: true,
          );
          pos += size;
          final equal = entry.indexOf('=');
          if (equal > 0) {
            text[entry.substring(0, equal).toLowerCase()] = entry.substring(
              equal + 1,
            );
          }
        }
        value = text;
      }
      if (value != null) result.add(DnsRecord(name, type, value, source));
      pos = next;
    }
    return result;
  }

  static List<PrinterTarget> targets(Iterable<DnsRecord> records) {
    final all = records.toList(), found = <String, PrinterTarget>{};
    for (final srv in all.where(
      (r) =>
          r.type == 33 &&
          (r.name.toLowerCase().contains('._ipp._tcp.') ||
              r.name.toLowerCase().contains('._ipps._tcp.')),
    )) {
      final info = srv.value as Map;
      if (info['port'] is! int ||
          (info['port'] as int) < 1 ||
          (info['port'] as int) > 65535) {
        continue;
      }
      final host = info['host'] as String;
      final address =
          all
                  .where(
                    (r) =>
                        r.type == 1 &&
                        r.name.toLowerCase() == host.toLowerCase(),
                  )
                  .firstOrNull
                  ?.value
              as String? ??
          srv.source;
      final txt =
          all
                  .where(
                    (r) =>
                        r.type == 16 &&
                        r.name.toLowerCase() == srv.name.toLowerCase(),
                  )
                  .firstOrNull
                  ?.value
              as Map? ??
          {};
      final path = txt['rp'] as String? ?? 'ipp/print';
      if (path.contains('://') ||
          path.contains('?') ||
          path.contains('#') ||
          ![4].contains(InternetAddress.tryParse(address)?.rawAddress.length)) {
        continue;
      }
      final secure = srv.name.toLowerCase().contains('._ipps.');
      final uri = Uri(
        scheme: secure ? 'ipps' : 'ipp',
        host: address,
        port: info['port'] as int,
        path: path.startsWith('/') ? path : '/$path',
      );
      final target = PrinterTarget(
        uri,
        discoveredName: srv.name.split('._ipp').first,
        discoveryId: (txt['uuid'] as String? ?? '').toLowerCase().replaceFirst(
          'urn:uuid:',
          '',
        ),
      );
      final identity = '${txt['uuid'] ?? address}/${uri.path}';
      // Prefer the advertised IPP endpoint when both services are published.
      if (!found.containsKey(identity) || !secure) found[identity] = target;
    }
    return found.values.toList()
      ..sort((a, b) => a.discoveredName.compareTo(b.discoveredName));
  }
}

Future<List<PrinterTarget>> discoverPrinters({
  Duration duration = const Duration(seconds: 3),
}) async {
  final window = DiscoveryWindow(),
      sockets = <RawDatagramSocket>[],
      listeners = <StreamSubscription<RawSocketEvent>>[];
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  final group = InternetAddress('224.0.0.251');
  try {
    for (final interface in interfaces.take(12)) {
      try {
        final socket = await RawDatagramSocket.bind(
          interface.addresses.first,
          0,
        );
        sockets.add(socket);
        socket.multicastHops = 255;
        socket.setRawOption(
          RawSocketOption(
            RawSocketOption.levelIPv4,
            RawSocketOption.IPv4MulticastInterface,
            interface.addresses.first.rawAddress,
          ),
        );
        listeners.add(
          socket.listen((event) {
            if (event != RawSocketEvent.read) return;
            Datagram? d;
            try {
              for (
                var batch = 0;
                batch < 64 && (d = socket.receive()) != null;
                batch++
              ) {
                if (window.full) {
                  socket.close();
                  return;
                }
                try {
                  window.add(d!.data, d.address.address);
                } on FormatException {
                  /* Ignore unrelated/malformed responses. */
                }
              }
            } on SocketException {
              // An interface can disappear while a discovery window is open.
            } on StateError {
              // A queued event can arrive after its socket was closed.
            }
          }, onError: (Object _) {}),
        );
      } on SocketException {
        /* Try the other interfaces and saved addresses. */
      }
    }
    void send(String name, int type) {
      if (window.full) return;
      List<int> query;
      try {
        query = DiscoveryCodec.question(name, type);
      } on FormatException {
        return;
      }
      for (final socket in sockets) {
        try {
          socket.send(query, group, 5353);
        } on SocketException {
          /* Interface went away. */
        } on StateError {
          /* Socket closed after an interface error. */
        }
      }
    }

    send('_ipp._tcp.local', 12);
    send('_ipps._tcp.local', 12);
    await Future<void>.delayed(duration ~/ 3);
    for (final ptr in window.records.where((r) => r.type == 12).toList()) {
      send(ptr.value as String, 33);
      send(ptr.value as String, 16);
    }
    await Future<void>.delayed(duration ~/ 3);
    for (final srv in window.records.where((r) => r.type == 33).toList()) {
      send((srv.value as Map)['host'] as String, 1);
    }
    await Future<void>.delayed(duration ~/ 3);
    return DiscoveryCodec.targets(window.records);
  } finally {
    for (final listener in listeners) {
      await listener.cancel();
    }
    for (final socket in sockets) {
      socket.close();
    }
  }
}
