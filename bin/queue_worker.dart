import 'dart:convert';
import 'dart:io';

import 'package:fixma_pixma/core/print_queue.dart';
import 'package:fixma_pixma/platform/windows_queue.dart';

Future<void> main() async {
  try {
    final line = await stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    if (line.length > 65536) throw const FormatException('Request too large.');
    final request = jsonDecode(line) as Map, spooler = WindowsSpooler();
    Object? result;
    switch (request['op']) {
      case 'list':
        result = spooler.list().map((q) => q.toJson()).toList();
      case 'jobs':
        result = spooler.read(WindowsQueue.fromJson(request['queue'] as Map));
      case 'cancel':
        spooler.cancel(
          WindowsQueue.fromJson(request['queue'] as Map),
          QueueJob.fromJson(request['job'] as Map),
        );
        result = true;
      default:
        throw UnsupportedError('Unknown queue operation.');
    }
    stdout.writeln(jsonEncode({'ok': true, 'value': result}));
  } catch (e) {
    stdout.writeln(jsonEncode({'ok': false, 'error': e.toString()}));
    exitCode = 1;
  }
}
