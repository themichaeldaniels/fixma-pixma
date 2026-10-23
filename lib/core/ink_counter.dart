import 'package:xml/xml.dart';

import 'canon_command.dart';
import 'model_support.dart';

const inkNames = {'BK': 'Black', 'C': 'Cyan', 'M': 'Magenta', 'Y': 'Yellow'};
const _common = 'http://www.canon.com/ns/cmd/2008/07/common/';
const _canon = 'http://www.canon.com/ns/cmd/2008/07/canon/';

class InkIdentity {
  final String model, firmware, serial;
  final Set<String> resetColors;
  const InkIdentity(this.model, this.firmware, this.serial, this.resetColors);
  bool get supported =>
      model == 'G7000 series' &&
      ModelSupport.find(model)?.matchesFirmware(firmware) == true &&
      serial.isNotEmpty &&
      inkNames.keys.every(resetColors.contains);
  Map<String, dynamic> toJson() => {
    'model': model,
    'firmware': firmware,
    'serial': serial,
    'resetColors': resetColors.toList(),
  };
}

class InkCounters {
  final String state, supportCode;
  final Map<String, int?> levels;
  const InkCounters(this.state, this.supportCode, this.levels);
  bool get ready => state == 'idle' && supportCode.isEmpty;
  Map<String, dynamic> toJson() => {
    'state': state,
    'supportCode': supportCode,
    'levels': levels,
  };
}

abstract interface class InkCounterPeer {
  Future<InkIdentity> identity();
  Future<InkCounters> read();
  Future<void> resetColor(String color);
  Future<void> close();
}

typedef InkCounterFactory = Future<InkCounterPeer> Function(String host);

/// Only the recovered normal-mode queries and per-color full-refill command.
/// A connection never retries writes or follows HTTP redirects.
class CanonInkPeer implements InkCounterPeer {
  final CanonCommandConnection connection;
  InkIdentity? _identity;
  CanonInkPeer._(this.connection);
  set observe(void Function(String request, String response)? callback) =>
      connection.observe = callback;
  static Future<CanonInkPeer> connect(String host, {int port = 80}) async =>
      CanonInkPeer._(await CanonCommandConnection.connect(host, port: port));

  static String query(String operation, String service) {
    if (!((operation == 'GetCapability' && service == 'device') ||
        (operation == 'GetStatus' && service == 'print'))) {
      throw ArgumentError('Unsupported ink-counter query');
    }
    return _xml(operation, service, '');
  }

  static String resetCommand(String color) {
    if (!inkNames.containsKey(color)) {
      throw ArgumentError('Unsupported ink color');
    }
    return _xml(
      'VendorCmd',
      'device',
      '<vcn:ijoperation>ResetCounter</vcn:ijoperation>'
          '<vcn:type id="ink"><vcn:resetink>$color</vcn:resetink></vcn:type>',
    );
  }

  static String _xml(String operation, String service, String content) =>
      '<?xml version="1.0" encoding="utf-8"?><cmd xmlns:ivec="$_common" xmlns:vcn="$_canon">'
      '<ivec:contents><ivec:operation>$operation</ivec:operation>'
      '<ivec:param_set servicetype="$service">$content</ivec:param_set></ivec:contents></cmd>';

  static XmlElement reply(String text, String operation, String service) {
    if (text.length > 1024 * 1024 ||
        RegExp(r'<!DOCTYPE|<!ENTITY', caseSensitive: false).hasMatch(text)) {
      throw const FormatException('Unsupported printer XML response.');
    }
    final document = XmlDocument.parse(text);
    final root = document.rootElement;
    final contents = root.findElements('contents', namespace: _common).single;
    if (root.name.qualified != 'cmd' ||
        contents
                .findElements('operation', namespace: _common)
                .single
                .innerText !=
            operation) {
      throw const FormatException('Unexpected printer operation response.');
    }
    final params = contents
        .findElements('param_set', namespace: _common)
        .single;
    if (params.getAttribute('servicetype') != service ||
        params.findElements('response', namespace: _common).single.innerText !=
            'OK') {
      throw StateError(
        'The printer rejected the Canon request (${params.findElements('response_detail', namespace: _common).singleOrNull?.innerText ?? 'No detail'}).',
      );
    }
    return params;
  }

  static InkIdentity parseIdentity(String text) {
    final p = reply(text, 'GetCapabilityResponse', 'device');
    String value(String name) =>
        p
            .findElements(name, namespace: _common)
            .singleOrNull
            ?.innerText
            .trim() ??
        '';
    final reset = p
        .findElements('ResetCounter', namespace: _canon)
        .singleOrNull;
    final type = reset
        ?.findElements('type', namespace: _canon)
        .where((e) => e.getAttribute('id') == 'ink')
        .singleOrNull;
    final colors =
        type
            ?.findElements('resetink', namespace: _canon)
            .singleOrNull
            ?.innerText
            .split(',')
            .map((s) => s.trim())
            .toSet() ??
        <String>{};
    return InkIdentity(
      value('model'),
      value('firmver'),
      value('product_serialnumber'),
      value('manufacturer').toUpperCase() == 'CANON' ? colors : {},
    );
  }

  static InkCounters parseCounters(String text) {
    final p = reply(text, 'GetStatusResponse', 'print');
    final values = <String, int?>{};
    for (final marker
        in p
            .findElements('marker_info', namespace: _common)
            .expand((e) => e.findElements('ink', namespace: _common))) {
      var color = marker
          .findElements('color', namespace: _common)
          .single
          .innerText;
      if (color == 'PGBK') color = 'BK';
      if (!inkNames.containsKey(color)) continue;
      if (values.containsKey(color)) {
        throw const FormatException('Duplicate ink color.');
      }
      final level = int.tryParse(
        marker.findElements('level', namespace: _common).single.innerText,
      );
      values[color] = level != null && level >= 0 && level <= 100
          ? level
          : null;
    }
    return InkCounters(
      p.findElements('status', namespace: _common).single.innerText,
      p
              .findElements('current_support_code', namespace: _common)
              .singleOrNull
              ?.innerText ??
          '',
      values,
    );
  }

  @override
  Future<InkIdentity> identity() async => _identity = parseIdentity(
    await _exchange(query('GetCapability', 'device')),
  );
  @override
  Future<InkCounters> read() async =>
      parseCounters(await _exchange(query('GetStatus', 'print')));
  @override
  Future<void> resetColor(String color) async {
    if (_identity?.supported != true ||
        !_identity!.resetColors.contains(color)) {
      throw StateError(
        'This printer has not passed the supported ink-reset capability check.',
      );
    }
    checkResetReply(await _exchange(resetCommand(color)));
  }

  static void checkResetReply(String text) {
    final params = reply(text, 'VendorCmdResponse', 'device');
    if (params
                .findElements('ijoperation', namespace: _canon)
                .single
                .innerText !=
            'ResetCounterResponse' ||
        params.findElements('ijresponse', namespace: _canon).single.innerText !=
            'OK') {
      throw StateError(
        'The printer did not acknowledge the ink-counter reset.',
      );
    }
  }

  Future<String> _exchange(String xml) => connection.exchange(xml);
  @override
  Future<void> close() => connection.close();
}
