import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_info.dart';
import '../core/software_update.dart';
import '../core/update_package.dart';
import 'update_process.dart';

Map<String, dynamic> readUpdateJson(File file) {
  if (file.lengthSync() > 2 * 1024 * 1024) {
    throw const FormatException('Update state is too large.');
  }
  return Map<String, dynamic>.from(jsonDecode(file.readAsStringSync()) as Map);
}

void writeUpdateJson(File file, Map<String, dynamic> value) {
  file.parent.createSync(recursive: true);
  final temporary = File('${file.path}.$pid.tmp');
  temporary.writeAsStringSync(jsonEncode(value), flush: true);
  temporary.renameSync(file.path);
}

Directory updateSession(Directory state, String token) {
  if (!validUpdateToken(token)) {
    throw const FormatException('Invalid update token.');
  }
  return Directory('${state.path}/updates/$token');
}

Directory updateApplication(Directory state, String token) {
  if (!validUpdateToken(token)) {
    throw const FormatException('Invalid update token.');
  }
  return Directory('${state.path}/application/$token');
}

Map<String, dynamic> readUpdatePlan(File file) {
  final data = readUpdateJson(file);
  final token = file.parent.uri.pathSegments.where((v) => v.isNotEmpty).last;
  if (data['schemaVersion'] != 1 ||
      data['token'] != token ||
      !validUpdateToken(token) ||
      data['applicationToken'] is! String ||
      !validUpdateToken(data['applicationToken']) ||
      data['version'] is! String ||
      ReleaseVersion.tryParse(data['version']) == null ||
      data['previousVersion'] is! String ||
      ReleaseVersion.tryParse(data['previousVersion']) == null ||
      data['parentPid'] is! int ||
      data['parentPid'] <= 0 ||
      data['parentExe'] is! String ||
      !data['parentExe']
          .toLowerCase()
          .replaceAll(r'\', '/')
          .endsWith('/fixma_pixma.exe')) {
    throw const FormatException('Invalid update plan.');
  }
  return data;
}

Future<UpdateProcess> launchUpdateApplication(
  Directory state,
  Map<String, dynamic> plan, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final folder = updateApplication(state, plan['applicationToken']);
  final executable = File('${folder.path}/fixma_pixma.exe');
  final ready = File(
    '${updateSession(state, plan['token']).path}/app-ready.json',
  );
  if (ready.existsSync()) {
    throw const FormatException('A startup acknowledgment already exists.');
  }
  final child = await Process.start(
    executable.path,
    ['--update-ready=${plan['token']}'],
    mode: ProcessStartMode.detached,
    workingDirectory: folder.path,
  );
  final handle = UpdateProcess.open(
    child.pid,
    executable.path,
    terminate: true,
  );
  try {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!handle.alive) {
        throw StateError('The updated application did not start.');
      }
      if (ready.existsSync()) {
        final ack = readUpdateJson(ready);
        if (ack['version'] != plan['version'] || ack['pid'] != child.pid) {
          throw const FormatException('Invalid startup acknowledgment.');
        }
        return handle;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('The updated application did not confirm startup.');
  } catch (_) {
    if (handle.alive) handle.terminate();
    handle.close();
    rethrow;
  }
}

Future<void> acknowledgeUpdateStartup(
  Directory state,
  List<String> arguments, {
  String version = applicationVersion,
  String? executable,
}) async {
  final argument = arguments
      .where((v) => v.startsWith('--update-ready='))
      .firstOrNull;
  if (argument == null) return;
  final token = argument.substring('--update-ready='.length);
  final session = updateSession(state, token);
  final plan = readUpdatePlan(File('${session.path}/plan.json'));
  final expected = File(
    '${updateApplication(state, plan['applicationToken']).path}/fixma_pixma.exe',
  );
  if (plan['version'] != version ||
      expected.resolveSymbolicLinksSync().toLowerCase() !=
          File(executable ?? Platform.resolvedExecutable)
              .resolveSymbolicLinksSync()
              .toLowerCase()) {
    throw const FormatException(
      'The updated application identity does not match.',
    );
  }
  writeUpdateJson(File('${session.path}/app-ready.json'), {
    'version': version,
    'pid': pid,
  });
}

Future<bool> forwardInstalledUpdate(
  Directory state,
  String installed,
  List<String> arguments,
) async {
  if (arguments.any(
    (v) =>
        v.startsWith('--update-ready=') ||
        v.startsWith('--smoke-output=') ||
        v.startsWith('--network-proof=') ||
        v.startsWith('--service-proof=') ||
        v.startsWith('--diagnostics-proof='),
  )) {
    return false;
  }
  final pointer = File('${state.path}/application/current.json');
  if (!pointer.existsSync()) return false;
  final current = readUpdateJson(pointer);
  final target = current['version'] is String
      ? ReleaseVersion.tryParse(current['version'])
      : null;
  final own = ReleaseVersion.tryParse(installed);
  if (current['schemaVersion'] != 1 ||
      target == null ||
      own == null ||
      target.compareTo(own) <= 0 ||
      current['token'] is! String ||
      !validUpdateToken(current['token'])) {
    return false;
  }
  final folder = updateApplication(state, current['token']);
  await verifyInstalledFolder(folder, target.text);
  final token = newUpdateToken();
  // One fresh nonce identifies both the plan folder and its startup acknowledgment.
  final actualSession = updateSession(state, token)
    ..createSync(recursive: true);
  final plan = {
    'schemaVersion': 1,
    'token': token,
    'applicationToken': current['token'],
    'version': target.text,
    'previousVersion': installed,
    'parentPid': pid,
    'parentExe': File(Platform.resolvedExecutable).resolveSymbolicLinksSync(),
  };
  writeUpdateJson(File('${actualSession.path}/plan.json'), plan);
  final child = await launchUpdateApplication(state, plan);
  child.close();
  return true;
}

class NativeUpdateInstaller {
  final Directory state;
  NativeUpdateInstaller(this.state);
  Future<void> handoff(
    PreparedUpdate prepared,
    String installed,
    Future<void> Function() stopAndExit,
  ) async {
    if (!Platform.isWindows ||
        !Platform.resolvedExecutable.toLowerCase().endsWith(
          'fixma_pixma.exe',
        ) ||
        prepared.state.absolute.path != state.absolute.path) {
      throw const UpdateCheckException(
        'In-app installation requires the complete Windows release.',
      );
    }
    if (prepared.release.version.compareTo(
          ReleaseVersion.tryParse(installed)!,
        ) <=
        0) {
      throw const UpdateCheckException(
        'This update is not newer than the installed version.',
      );
    }
    await verifyInstalledFolder(
      prepared.application,
      prepared.release.version.text,
    );
    final updater = File(
      '${File(Platform.resolvedExecutable).parent.path}/fixma_pixma_updater.exe',
    );
    if (!updater.existsSync()) {
      throw const UpdateCheckException(
        'The update helper is missing. Extract the complete Windows package and try again.',
      );
    }
    final copied = await updater.copy('${prepared.session.path}/updater.exe');
    final plan = {
      'schemaVersion': 1,
      'token': prepared.token,
      'applicationToken': prepared.token,
      'version': prepared.release.version.text,
      'previousVersion': installed,
      'parentPid': pid,
      'parentExe': File(Platform.resolvedExecutable).resolveSymbolicLinksSync(),
    };
    final path = File('${prepared.session.path}/plan.json');
    writeUpdateJson(path, plan);
    await Process.start(
      copied.path,
      [path.path],
      mode: ProcessStartMode.detached,
      workingDirectory: prepared.session.path,
    );
    final ready = File('${prepared.session.path}/helper-ready.json');
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!ready.existsSync() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!ready.existsSync() || readUpdateJson(ready)['ok'] != true) {
      File('${prepared.session.path}/cancel').writeAsStringSync('cancel');
      throw const UpdateCheckException(
        'The update helper could not prepare installation. The current version is still running.',
      );
    }
    try {
      await stopAndExit();
    } catch (_) {
      File('${prepared.session.path}/cancel').writeAsStringSync('cancel');
      rethrow;
    }
  }
}

/// Installs into a new managed folder. The previous program and user data stay intact.
Future<void> runUpdatePlan(File planFile) async {
  final plan = readUpdatePlan(planFile);
  final state = planFile.parent.parent.parent;
  if (planFile.parent.parent.uri.pathSegments.where((v) => v.isNotEmpty).last !=
      'updates') {
    throw const FormatException('Invalid update state folder.');
  }
  final session = updateSession(state, plan['token']);
  final folder = updateApplication(state, plan['applicationToken']);
  final parent = UpdateProcess.open(plan['parentPid'], plan['parentExe']);
  RandomAccessFile? operationLock;
  UpdateProcess? child;
  var parentExited = false, committed = false;
  try {
    if (ReleaseVersion.tryParse(plan['version'])!
            .compareTo(ReleaseVersion.tryParse(plan['previousVersion'])!) <=
        0) {
      throw const FormatException('Not an upgrade.');
    }
    if (File('${session.path}/cancel').existsSync()) {
      throw StateError('Installation was canceled.');
    }
    await verifyInstalledFolder(folder, plan['version']);
    writeUpdateJson(File('${session.path}/helper-ready.json'), {'ok': true});
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (parent.alive) {
      if (File('${session.path}/cancel').existsSync() ||
          DateTime.now().isAfter(deadline)) {
        throw StateError('The application did not close.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    parentExited = true;
    if (File('${session.path}/cancel').existsSync()) {
      throw StateError('Installation was canceled.');
    }
    operationLock = File('${state.path}/operation.lock')
        .openSync(mode: FileMode.append);
    operationLock.lockSync(FileLock.exclusive);
    final pointer = File('${state.path}/application/current.json');
    final previous = pointer.existsSync() ? readUpdateJson(pointer) : null;
    if (previous != null &&
        previous['version'] is String &&
        (ReleaseVersion.tryParse(previous['version'])
                    ?.compareTo(ReleaseVersion.tryParse(plan['version'])!) ??
                0) >
            0) {
      throw StateError('A newer update is already installed.');
    }
    await verifyInstalledFolder(folder, plan['version']);
    child = await launchUpdateApplication(state, plan);
    writeUpdateJson(pointer, {
      'schemaVersion': 1,
      'token': plan['applicationToken'],
      'version': plan['version'],
      if (previous != null)
        'previous': {
          'token': previous['token'],
          'version': previous['version'],
        },
    });
    committed = true;
    try {
      writeUpdateJson(File('${state.path}/updates/last-result.json'), {
        'token': plan['token'],
        'status': 'complete',
        'version': plan['version'],
      });
    } catch (_) {}
    try {
      File('${session.path}/package.zip').deleteSync();
    } catch (_) {}
  } catch (_) {
    if (!committed && child != null && child.alive) child.terminate();
    try {
      writeUpdateJson(File('${session.path}/helper-ready.json'), {'ok': false});
    } catch (_) {}
    try {
      writeUpdateJson(File('${state.path}/updates/last-result.json'), {
        'token': plan['token'],
        'status': 'failed',
        'version': plan['version'],
        'message': 'The update could not start. The previous version and printer data were preserved. Close other copies, check available disk space and try again.',
      });
    } catch (_) {}
    if (parentExited && !committed) {
      try {
        await Process.start(
          plan['parentExe'],
          ['--update-result=${plan['token']}'],
          mode: ProcessStartMode.detached,
          workingDirectory: File(plan['parentExe']).parent.path,
        );
      } catch (_) {}
    }
    rethrow;
  } finally {
    child?.close();
    parent.close();
    operationLock?.closeSync();
  }
}
