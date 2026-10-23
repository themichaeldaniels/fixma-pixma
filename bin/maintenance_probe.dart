import 'dart:convert';
import 'dart:io';

import 'package:pixma_fixa/core/canon_command.dart';
import 'package:pixma_fixa/core/canon_maintenance.dart';

Future<void> main(List<String> args) async {
  String? option(String key) => args
      .where((s) => s.startsWith('$key='))
      .firstOrNull
      ?.substring(key.length + 1);
  final host = option('--host');
  final output = option('--output');
  if (host == null || output == null) {
    throw ArgumentError('Require --host and a new --output file.');
  }
  final file = File(output);
  if (file.existsSync()) {
    throw StateError('Proof already exists; do not replay.');
  }
  final taskName = option('--task');
  final task = taskName == null ? null : CanonTask.values.byName(taskName);
  if (task != null && !args.contains('--confirm-test')) {
    throw ArgumentError('Explicit --confirm-test is required.');
  }
  // Reserve before connecting; two concurrent probes cannot share a proof file.
  file.createSync(exclusive: true);
  final result = <String, dynamic>{
    'started': DateTime.now().toIso8601String(),
    'exchanges': [],
    'commandsSent': 0,
  };
  void save() => file.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(result),
    flush: true,
  );
  final connection = await CanonCommandConnection.connect(host);
  connection.observe = (request, response) {
    (result['exchanges'] as List).add({
      'at': DateTime.now().toIso8601String(),
      'request': request,
      'response': response,
    });
    save();
  };
  final peer = LocalCanonMaintenance(connection);
  String? job;
  try {
    final identity = await peer.identity();
    result['identity'] = identity.toJson();
    final caps = await peer.capabilities();
    final settings = await peer.settings();
    result['settings'] = settings.values;
    result['alignmentBefore'] = settings.alignment;
    final before = await peer.read();
    result['before'] = before.toJson();
    save();
    if (args.contains('--settings-test')) {
      if (!args.contains('--confirm-test') ||
          !identity.supported ||
          !before.ready) {
        throw StateError(
          'Settings test requires explicit confirmation and an idle supported printer.',
        );
      }
      result['settingTests'] = <Map<String, dynamic>>[];
      final alternatives = {
        'quiet': 'ON',
        'autoPowerOn': 'OFF',
        'autoPowerOff': '240',
        'paperGap': 'wide',
        'dryLevel': '4',
      };
      for (final key in alternatives.keys) {
        final original = await peer.settings();
        final value = alternatives[key]!;
        if (original.values[key] == value ||
            !CanonSettings.allowed[key]!.contains(original.values[key])) {
          throw StateError('Unexpected initial setting; no blind test change.');
        }
        final test = <String, dynamic>{
          'setting': key,
          'before': original.values,
          'requested': value,
        };
        (result['settingTests'] as List).add(test);
        try {
          test['attempted'] = true;
          save();
          await peer.setSetting(key, value);
          final after = await peer.settings();
          test['after'] = after.values;
          if (after.values[key] != value ||
              original.values.keys
                  .where((k) => k != key)
                  .any((k) => original.values[k] != after.values[k])) {
            throw StateError('Setting readback mismatch.');
          }
          test['verified'] = true;
          save();
        } finally {
          await peer.setSetting(key, original.values[key]!);
          final restored = await peer.settings();
          test['restored'] = restored.values;
          test['restoreVerified'] = original.values.keys.every(
            (k) => original.values[k] == restored.values[k],
          );
          save();
          if (test['restoreVerified'] != true) {
            throw StateError('Original settings were not restored.');
          }
        }
      }
    }
    if (task != null) {
      if (!identity.supported ||
          !before.ready ||
          !caps.supports(task, letterPaper)) {
        throw StateError('Unsupported or busy printer.');
      }
      job = await peer.startJob();
      result['job'] = job;
      result['commandsSent'] = 1;
      result['task'] = task.name;
      save();
      await peer.execute(task, job, letterPaper);
      result['acknowledged'] = true;
      save();
      await peer.endJob(job);
      final finishedJob = job;
      job = null;
      var busySeen = false;
      var matchingJobSeen = false;
      final deadline = DateTime.now().add(task.completionTimeout);
      while (DateTime.now().isBefore(deadline)) {
        final status = await peer.read();
        result['after'] = status.toJson();
        busySeen |= !status.ready;
        result['busyObserved'] = busySeen;
        result['jobStatus'] = await peer.jobStatus(finishedJob);
        final progress = MaintenanceJob.parse(
          result['jobStatus'] as String,
          finishedJob,
          task,
        );
        matchingJobSeen |=
            progress.matched && progress.progress == 'processing';
        result['matchingJobSeen'] = matchingJobSeen;
        save();
        stdout.writeln(
          '${DateTime.now().toIso8601String()} ${status.state} ${status.supportCode}',
        );
        if (status.supportCode.isNotEmpty || progress.failed) {
          throw StateError(
            'Maintenance stopped or printer reports an error. No task was repeated.',
          );
        }
        if (status.ready &&
            (progress.completed || (matchingJobSeen && progress.absent))) {
          result['verified'] = true;
          if (task == CanonTask.automaticAlignment) {
            result['alignmentAfter'] = (await peer.settings()).alignment;
          }
          break;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (result['verified'] != true) {
        throw StateError(
          'Matching maintenance completion was not observed. No task was repeated.',
        );
      }
    }
  } catch (e) {
    result['error'] = e.toString();
    exitCode = 1;
  } finally {
    if (job != null) {
      try {
        await peer.endJob(job);
      } catch (e) {
        result['closeError'] = e.toString();
      }
    }
    await peer.close();
    result['finished'] = DateTime.now().toIso8601String();
    save();
    stdout.writeln(jsonEncode(Map.from(result)..remove('exchanges')));
  }
}
