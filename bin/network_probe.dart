import 'dart:convert';
import 'dart:io';

import 'package:fixma_pixma/core/printer_network.dart';
import 'package:fixma_pixma/core/network_status.dart';

Future<void> main(List<String> args) async {
  final network = LocalPrinterNetwork();
  final discovered = await network.discover();
  final manual = args.where((a) => !a.startsWith('--')).firstOrNull;
  final targets = manual == null ? discovered : [PrinterTarget.parse(manual)];
  final readings = <Map<String, dynamic>>[];
  for (final target in targets) {
    try {
      readings.add((await network.read(target)).toJson());
    } catch (e) {
      readings.add({'target': target.toJson(), 'error': '$e'});
    }
  }
  final proof = {
    'discovery': discovered.map((t) => t.toJson()).toList(),
    'readings': readings,
    'readOnly': true,
    'printJobsSubmitted': 0,
    'counterCommandsSent': 0,
  };
  final text = const JsonEncoder.withIndent('  ').convert(proof);
  final output = args.where((a) => a.startsWith('--output=')).firstOrNull;
  if (output != null) File(output.substring(9)).writeAsStringSync(text);
  stdout.writeln(text);
  if (readings.isEmpty || readings.every((r) => r.containsKey('error'))) {
    exitCode = 1;
  }
}
