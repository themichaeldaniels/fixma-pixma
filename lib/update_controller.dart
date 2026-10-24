import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_info.dart';
import 'core/software_update.dart';
import 'core/update_package.dart';

class UpdateController extends ChangeNotifier {
  final Directory directory;
  final String installed;
  final Future<SoftwareRelease?> Function(String) fetch;
  final DateTime Function() now;
  final bool schedule;
  bool automatic = false, checking = false, completed = false;
  bool _disposed = false, _initialized = false;
  String error = '', preferenceError = '';
  DateTime? lastAttempt;
  SoftwareRelease? available;
  String? dismissedTag;
  Timer? _timer;
  final bool Function()? printerIdle;
  final Future<void> Function(PreparedUpdate)? installHandler;
  final UpdatePackageManager packages;
  PreparedUpdate? prepared;
  UpdateCancellation? _cancellation;
  bool downloading = false, installing = false, installFailure = false;
  int downloadedBytes = 0, downloadBytes = 0;
  String installStatus = '';
  String? _seenInstallToken;
  bool get canInstall =>
      !checking &&
      !downloading &&
      !installing &&
      prepared != null &&
      installHandler != null &&
      (printerIdle?.call() ?? false);
  void printerStateChanged() => _notify();

  UpdateController({
    required this.directory,
    this.installed = applicationVersion,
    Future<SoftwareRelease?> Function(String)? fetch,
    DateTime Function()? now,
    this.schedule = true,
    this.printerIdle,
    this.installHandler,
    UpdatePackageManager? packages,
  }) : packages = packages ?? UpdatePackageManager(directory),
       fetch = fetch ?? SoftwareUpdateService().check,
       now = now ?? DateTime.now;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  File get _preferences => File('${directory.path}/updates.json');
  void initialize() {
    if (_disposed || _initialized) return;
    _initialized = true;
    try {
      if (_preferences.lengthSync() <= 8192) {
        final data = jsonDecode(_preferences.readAsStringSync());
        if (data is Map) {
          automatic = data['automatic'] == true;
          final last = data['lastAttempt'];
          if (last is String) lastAttempt = DateTime.tryParse(last)?.toUtc();
          _seenInstallToken = data['seenInstallToken'] is String
              ? data['seenInstallToken']
              : null;
        }
      }
    } catch (_) {
      /* New or damaged preferences leave checks disabled. */
    }
    try {
      final result = File('${directory.path}/updates/last-result.json');
      if (result.existsSync() && result.lengthSync() < 8192) {
        final data = jsonDecode(result.readAsStringSync());
        if (data is Map &&
            data['token'] is String &&
            validUpdateToken(data['token']) &&
            data['token'] != _seenInstallToken &&
            data['status'] == 'failed') {
          _seenInstallToken = data['token'];
          installFailure = true;
          error = 'The update could not start. The previous version and printer data were preserved. Close other copies, check available disk space and try again.';
          _save();
        }
      }
    } catch (_) {
      /* A damaged update result does not block the utility. */
    }
    _schedule();
    if (!installFailure) unawaited(checkIfDue());
  }

  bool _save() {
    try {
      directory.createSync(recursive: true);
      final temporary = File('${_preferences.path}.$pid.tmp');
      temporary.writeAsStringSync(
        jsonEncode({
          'automatic': automatic,
          'seenInstallToken': _seenInstallToken,
          'lastAttempt': lastAttempt?.toUtc().toIso8601String(),
        }),
        flush: true,
      );
      temporary.renameSync(_preferences.path);
      preferenceError = '';
      return true;
    } catch (_) {
      preferenceError = 'Update preferences could not be saved. Check that local application data is writable.';
      return false;
    }
  }

  void _schedule() {
    _timer?.cancel();
    _timer = automatic && schedule && !_disposed
        ? Timer.periodic(
            const Duration(hours: 1),
            (_) => unawaited(checkIfDue()),
          )
        : null;
  }

  void setAutomatic(bool value) {
    if (_disposed) return;
    final previous = automatic;
    automatic = value;
    if (!_save()) automatic = previous;
    _schedule();
    _notify();
    if (automatic) unawaited(checkIfDue());
  }

  Future<void> checkIfDue() async {
    if (_disposed || !automatic || checking || downloading || installing) {
      return;
    }
    final age = lastAttempt == null
        ? null
        : now().toUtc().difference(lastAttempt!);
    if (age != null && age < const Duration(days: 1)) return;
    await check(background: true);
  }

  Future<void> check({bool background = false}) async {
    if (_disposed || checking || downloading || installing) return;
    checking = true;
    error = '';
    lastAttempt = now().toUtc();
    final saved = _save();
    if (background && !saved) {
      checking = false;
      _notify();
      return;
    }
    _notify();
    try {
      final release = await fetch(installed);
      if (_disposed) return;
      if (prepared != null && prepared!.release.tag != release?.tag) {
        final stale = prepared!;
        prepared = null;
        installStatus = '';
        await packages.discard(stale);
        if (_disposed) return;
      }
      available = release;
      completed = true;
    } catch (e) {
      if (_disposed) return;
      error = e is UpdateCheckException
          ? e.message
          : 'Could not check for updates. Try again later.';
    } finally {
      checking = false;
      _notify();
    }
  }

  Future<void> download() async {
    if (_disposed ||
        checking ||
        downloading ||
        installing ||
        available == null) {
      return;
    }
    final selected = available!;
    downloading = true;
    error = '';
    installStatus = 'Downloading update...';
    downloadedBytes = 0;
    downloadBytes = selected.packageSize ?? 0;
    final cancel = UpdateCancellation();
    _cancellation = cancel;
    _notify();
    try {
      if (prepared != null) {
        await packages.discard(prepared!);
        prepared = null;
      }
      final result = await packages.download(selected, cancel, (
        received,
        total,
      ) {
        if (_disposed) return;
        downloadedBytes = received;
        downloadBytes = total;
        installStatus = received == total
            ? 'Verifying and unpacking update...'
            : 'Downloading update...';
        _notify();
      });
      if (_disposed) {
        await packages.discard(result);
        return;
      }
      prepared = result;
      installStatus = 'Download verified. Ready to install.';
    } on UpdateCancelled {
      installStatus = 'Download canceled.';
    } catch (e) {
      installStatus = '';
      error = e is UpdateCheckException ? e.message : 'The update could not be prepared. Try again or open the release page.';
    } finally {
      downloading = false;
      _cancellation = null;
      _notify();
    }
  }

  void cancelDownload() {
    _cancellation?.cancel();
  }

  Future<void> install() async {
    if (_disposed || !canInstall) return;
    installing = true;
    error = '';
    installStatus = 'Preparing restart...';
    _notify();
    try {
      await installHandler!(prepared!);
    } catch (_) {
      error = 'The update could not be installed. Finish printer operations, close other copies and try again. The current version and local data were preserved.';
      prepared = null;
      installStatus = '';
    } finally {
      installing = false;
      _notify();
    }
  }

  void dismissNotice() {
    dismissedTag = available?.tag;
    _notify();
  }

  bool get showNotice => available != null && available!.tag != dismissedTag;
  @override
  void dispose() {
    _disposed = true;
    _cancellation?.cancel();
    _timer?.cancel();
    super.dispose();
  }
}
