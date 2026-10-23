import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'discovery.dart';
import 'ipp.dart';
import 'network_status.dart';

abstract interface class PrinterNetwork {
  Future<List<PrinterTarget>> discover();
  Future<NetworkStatus> read(PrinterTarget target);
}

class LocalPrinterNetwork implements PrinterNetwork {
  @override
  Future<List<PrinterTarget>> discover() => discoverPrinters();

  @override
  Future<NetworkStatus> read(PrinterTarget target) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    client.findProxy = (_) => 'DIRECT';
    Future<Uint8List> body(HttpClientResponse response) async {
      final out = BytesBuilder();
      await for (final chunk in response) {
        if (out.length + chunk.length > 1024 * 1024) {
          throw const FormatException('Printer status response is too large.');
        }
        out.add(chunk);
      }
      return out.takeBytes();
    }

    try {
      Future<NetworkStatus> query() async {
        final uri = target.uri.replace(
          scheme: target.uri.scheme == 'ipps' ? 'https' : 'http',
        );
        final request = await client.postUrl(uri);
        request.followRedirects = false;
        request.headers.contentType = ContentType('application', 'ipp');
        request.add(IppCodec.query(target.uri));
        final response = await request.close();
        if (response.statusCode != 200 ||
            response.headers.contentType?.mimeType != 'application/ipp') {
          throw StateError(
            'Printer status is unavailable (HTTP ${response.statusCode}). Check its address and network connection.',
          );
        }
        final attrs = IppCodec.decode(await body(response));
        if (!['printer-name', 'printer-make-and-model'].any(
          (k) =>
              attrs[k]?.whereType<String>().any((v) => v.isNotEmpty) ?? false,
        )) {
          throw const FormatException(
            'The device did not identify itself as a printer.',
          );
        }
        CanonWebStatus? canon;
        final model = attrs['printer-make-and-model']?.join(' ') ?? '';
        if (model.toLowerCase().contains('canon')) {
          try {
            final web = await client
                .getUrl(
                  Uri(
                    scheme: 'http',
                    host: target.uri.host,
                    path: '/JS_MDL/model.js',
                  ),
                )
                .timeout(const Duration(seconds: 2));
            web.followRedirects = false;
            web.headers.set('Cache-Control', 'no-cache');
            final reply = await web.close().timeout(const Duration(seconds: 2));
            if (reply.statusCode == 200) {
              canon = CanonWebStatus.parse(
                utf8.decode(
                  await body(reply).timeout(const Duration(seconds: 2)),
                  allowMalformed: true,
                ),
              );
            }
          } catch (_) {
            /* Standard IPP status remains useful without Canon's web interface. */
          }
        }
        return NetworkStatus(target: target, attributes: attrs, canon: canon);
      }

      return await query().timeout(const Duration(seconds: 9));
    } finally {
      client.close(force: true);
    }
  }
}
