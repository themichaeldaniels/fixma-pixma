import 'dart:convert';
import 'dart:io';

import 'package:printer_care/core/ink_counter.dart';

Future<void> main(List<String> args) async {
  String? option(String name) => args
      .where((s) => s.startsWith('$name='))
      .firstOrNull
      ?.substring(name.length + 1);
  final host = option('--host');
  if (host == null || host.trim().isEmpty) {
    throw ArgumentError('An explicit --host printer address is required.');
  }
  final reset = option('--reset');
  final output = option('--output');
  if (reset != null &&
      (!inkNames.containsKey(reset) ||
          !args.contains('--confirm-full-refill') ||
          output == null)) {
    throw ArgumentError(
      'Reset requires one supported color, --confirm-full-refill, and a new --output file.',
    );
  }
  final result = <String, dynamic>{
    'host': host,
    'started': DateTime.now().toIso8601String(),
    'resetCommandsSent': 0,
  };
  File? record;
  if (output != null) {
    record = File(output);
    if (reset != null && record.existsSync()) {
      throw StateError('This reset proof already exists. Do not replay it.');
    }
  }
  void save() => record?.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(result),
    flush: true,
  );
  final peer = await CanonInkPeer.connect(host);
  peer.observe = (request, response) {
    (result['exchanges'] ??= <Map<String, dynamic>>[]).add({
      'request': request,
      'response': response,
    });
    save();
  };
  try {
    final identity = await peer.identity();
    result['identity'] = identity.toJson();
    final before = await peer.read();
    result['before'] = before.toJson();
    save();
    if (reset != null) {
      if (!identity.supported ||
          !before.ready ||
          before.levels.length != 4 ||
          before.levels[reset] == null ||
          before.levels[reset] == 100) {
        throw StateError(
          'Printer identity, readiness or counter precondition failed.',
        );
      }
      result['color'] = reset;
      result['attemptRecordedBeforeSend'] = true;
      result['resetCommandsSent'] = 1;
      save();
      await peer.resetColor(reset);
      result['acknowledged'] = true;
      save();
      final after = await peer.read();
      result['after'] = after.toJson();
      result['verified'] =
          after.levels[reset] == 100 &&
          inkNames.keys
              .where((c) => c != reset)
              .every((c) => after.levels[c] == before.levels[c]);
      if (result['verified'] != true) {
        throw StateError('Reset readback was not verified. Do not repeat.');
      }
    }
  } catch (e) {
    result['error'] = e.toString();
    exitCode = 1;
  } finally {
    await peer.close();
    result['finished'] = DateTime.now().toIso8601String();
    save();
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
  }
}
