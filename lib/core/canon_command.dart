import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Persistent, bounded Canon CHMP transport. Never retries writes.
class CanonCommandConnection {
  final Socket _socket;
  final StreamIterator<Uint8List> _input;
  final String host;
  List<int> _buffer = [];
  int _offset = 0;
  bool _closed = false;
  void Function(String request, String response)? observe;
  CanonCommandConnection._(this._socket, this.host)
    : _input = StreamIterator(_socket);
  static Future<CanonCommandConnection> connect(
    String host, {
    int port = 80,
  }) async => CanonCommandConnection._(
    await Socket.connect(host, port, timeout: const Duration(seconds: 5)),
    host,
  );
  Future<String> exchange(String xml) async {
    if (_closed) throw StateError('Printer connection is closed.');
    try {
      return await (() async {
        const endpoint = '/canon/ij/command2/port1';
        await _request('POST', utf8.encode(xml), endpoint);
        final response = utf8.decode(await _request('GET', const [], endpoint));
        observe?.call(xml, response);
        return response;
      })().timeout(const Duration(seconds: 12));
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<List<int>> _request(
    String method,
    List<int> payload,
    String endpoint,
  ) async {
    final request =
        '$method $endpoint HTTP/1.1\r\nHost: $host\r\n'
        'X-CHMP-Version: 1.3.0\r\nContent-Type: application/octet-stream\r\n'
        'Connection: Keep-Alive\r\n${method == 'POST' ? 'Content-Length: ${payload.length}\r\n' : ''}\r\n';
    _socket.add(ascii.encode(request));
    if (payload.isNotEmpty) _socket.add(payload);
    await _socket.flush();
    final first = await _line();
    final headers = <String, String>{};
    var total = first.length;
    for (var i = 0; ; i++) {
      final line = await _line();
      total += line.length;
      if (i >= 64 || total > 16384) {
        throw const FormatException('Printer HTTP headers are too large.');
      }
      if (line.isEmpty) break;
      final colon = line.indexOf(':');
      if (colon < 1) {
        throw const FormatException('Invalid printer HTTP header.');
      }
      final key = line.substring(0, colon).toLowerCase();
      if (headers.containsKey(key)) {
        throw const FormatException('Duplicate printer HTTP header.');
      }
      headers[key] = line.substring(colon + 1).trim();
    }
    if (!RegExp(r'^HTTP/1\.[01] 200(?: |$)').hasMatch(first)) {
      throw StateError(
        'Printer command transport refused $method on $endpoint ($first).',
      );
    }
    final result = BytesBuilder();
    if (headers['transfer-encoding'] == 'chunked') {
      if (headers.containsKey('content-length')) {
        throw const FormatException('Ambiguous printer response length.');
      }
      for (var chunks = 0; chunks < 65536; chunks++) {
        final line = await _line();
        final count = int.parse(line.split(';').first, radix: 16);
        if (count < 0 || count + result.length > 1024 * 1024) {
          throw const FormatException('Printer reply is too large.');
        }
        if (count == 0) {
          if ((await _line()).isNotEmpty) {
            throw const FormatException('Unexpected printer trailers.');
          }
          return result.takeBytes();
        }
        result.add(await _exact(count));
        if ((await _line()).isNotEmpty) {
          throw const FormatException('Invalid printer chunk terminator.');
        }
      }
      throw const FormatException('Too many printer response chunks.');
    }
    if (headers.containsKey('transfer-encoding')) {
      throw const FormatException('Unsupported printer transfer encoding.');
    }
    // Canon POST acknowledgments have no body length and no body.
    final count = int.parse(headers['content-length'] ?? '0');
    return _exact(count);
  }

  Future<List<int>> _exact(int count) async {
    if (count < 0 || count > 1024 * 1024) {
      throw const FormatException('Invalid printer response size.');
    }
    final out = BytesBuilder();
    while (count > 0) {
      if (_offset == _buffer.length) {
        if (!await _input.moveNext().timeout(const Duration(seconds: 5))) {
          throw const SocketException('Printer closed the command connection.');
        }
        _buffer = _input.current;
        _offset = 0;
        if (_buffer.isEmpty) continue;
      }
      final available = _buffer.length - _offset;
      final take = count < available ? count : available;
      out.add(_buffer.sublist(_offset, _offset + take));
      _offset += take;
      count -= take;
    }
    return out.takeBytes();
  }

  Future<String> _line() async {
    final bytes = <int>[];
    for (var i = 0; i < 8192; i++) {
      final next = (await _exact(1)).single;
      if (next == 10 && bytes.isNotEmpty && bytes.last == 13) {
        return ascii.decode(bytes.sublist(0, bytes.length - 1));
      }
      bytes.add(next);
    }
    throw const FormatException('Printer HTTP line is too long.');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
    await _input.cancel();
  }
}
