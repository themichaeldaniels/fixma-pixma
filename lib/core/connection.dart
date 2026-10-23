import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'model_support.dart';

abstract interface class PrinterPeer {
  Future<dynamic> call(String op, [Map<String, dynamic> arguments = const {}]);
  Future<void> close();
}

class WorkerPeer implements PrinterPeer {
  final Process process;
  final StreamIterator<String> replies;
  final void Function(Map<String, dynamic>) record;
  bool stopped = false;
  Future<void>? _closing;
  WorkerPeer._(this.process, this.replies, this.record);
  static Future<WorkerPeer> start(
    Map<String, dynamic> profile, {
    bool reset = false,
    required void Function(Map<String, dynamic>) record,
  }) async {
    final folder = File(Platform.resolvedExecutable).parent.path;
    final path =
        Platform.environment['PRINTERCARE_WORKER'] ??
        '$folder${Platform.pathSeparator}printer_care_worker.exe';
    if (!File(path).existsSync()) {
      throw StateError(
        'The Windows connection helper is missing. Extract the entire application folder.',
      );
    }
    final p = await Process.start(path, [], mode: ProcessStartMode.normal);
    p.stdin.done.catchError((Object _) {});
    p.stderr.transform(utf8.decoder).listen((s) => record({'workerError': s}));
    final peer = WorkerPeer._(
      p,
      StreamIterator(
        p.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
      record,
    );
    try {
      await peer.call('init', {'profile': profile, 'reset': reset});
      return peer;
    } catch (_) {
      await peer.close();
      rethrow;
    }
  }

  @override
  Future<dynamic> call(
    String op, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (stopped) throw StateError('USB worker is closed.');
    final request = {'op': op, ...arguments};
    if (op != 'poll' && op != 'init') {
      record({'time': DateTime.now().toIso8601String(), 'request': request});
    }
    process.stdin.writeln(jsonEncode(request));
    try {
      if (!await replies.moveNext().timeout(const Duration(seconds: 12))) {
        throw StateError('The USB helper exited unexpectedly.');
      }
      final response = jsonDecode(replies.current) as Map<String, dynamic>;
      if (op != 'poll' ||
          response['ok'] != true ||
          ((response['value'] as Map?)?['raw'] ?? '') != '') {
        record({
          'time': DateTime.now().toIso8601String(),
          'operation': op,
          'response': response,
        });
      }
      if (response['ok'] != true) throw StateError(response['error'] as String);
      return response['value'];
    } on TimeoutException {
      process.kill();
      stopped = true;
      throw StateError(
        'Windows USB timed out. The connection was stopped. A pending reset must not be repeated automatically.',
      );
    }
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    if (!stopped) {
      stopped = true;
      process.stdin.writeln(jsonEncode({'op': 'close'}));
    }
    try {
      await process.stdin.close().timeout(
        const Duration(seconds: 1),
        onTimeout: () {},
      );
    } catch (_) {
      process.kill();
    }
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {
      process.kill();
    }
    await replies.cancel();
  }
}

Future<Map<String, dynamic>> exchange(
  PrinterPeer peer,
  String operand, {
  required void Function(String) progress,
  Duration timeout = const Duration(minutes: 10),
  Future<void> Function(Duration)? pause,
}) async {
  await peer.call('command', {'operand': operand});
  final end = DateTime.now().add(timeout);
  var continuation = false, nextUpdate = DateTime.now();
  final sleep = pause ?? (Duration d) => Future<void>.delayed(d);
  while (DateTime.now().isBefore(end)) {
    final interval = Duration(milliseconds: continuation ? 50 : 100);
    await sleep(interval);
    final value = Map<String, dynamic>.from(await peer.call('poll') as Map);
    await sleep(interval);
    continuation = value['continuation'] == true;
    final reply = value['reply'] as Map?;
    if (reply != null) {
      if (reply['accepted'] != true) {
        throw StateError(reply['reason'] as String);
      }
      return Map<String, dynamic>.from(reply);
    }
    if (DateTime.now().isAfter(nextUpdate)) {
      progress(
        'Waiting for the printer · ${end.difference(DateTime.now()).inSeconds}s remaining',
      );
      nextUpdate = DateTime.now().add(const Duration(seconds: 5));
    }
  }
  throw StateError(
    'No complete acknowledgment received. No subsequent command was sent.',
  );
}

class ResetRules {
  static String? blocked({
    required bool live,
    required double? counter,
    required String firmware,
    required bool priorAttempt,
    required bool serviced,
    required DateTime capturedAt,
  }) {
    if (!live) return 'Run a live diagnostic first.';
    if (counter == null) {
      return 'The diagnostic did not return a counter value.';
    }
    if (!counter.isFinite || counter < 0) {
      return 'The diagnostic returned an invalid counter value.';
    }
    if (counter <= 0) {
      return 'The counter is already at zero. No reset is needed.';
    }
    if (!ModelSupport.profiles.first.matchesFirmware(firmware)) {
      return 'Reset is verified with G7020 firmware 1.050.';
    }
    if (priorAttempt) {
      return 'A reset attempt is already recorded. Review its result in History.';
    }
    final age = DateTime.now().difference(capturedAt);
    if (age.isNegative || age > const Duration(minutes: 30)) {
      return 'Run a fresh diagnostic before resetting.';
    }
    if (!serviced) return 'Confirm the ink absorber has been serviced.';
    return null;
  }
}
