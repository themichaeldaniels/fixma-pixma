import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_info.dart';
import 'core/software_update.dart';

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

  UpdateController({
    required this.directory,
    this.installed = applicationVersion,
    Future<SoftwareRelease?> Function(String)? fetch,
    DateTime Function()? now,
    this.schedule = true,
  }) : fetch = fetch ?? SoftwareUpdateService().check,
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
        }
      }
    } catch (_) {
      /* New or damaged preferences leave checks disabled. */
    }
    _schedule();
    unawaited(checkIfDue());
  }

  bool _save() {
    try {
      directory.createSync(recursive: true);
      final temporary = File('${_preferences.path}.$pid.tmp');
      temporary.writeAsStringSync(
        jsonEncode({
          'automatic': automatic,
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
    if (_disposed || !automatic || checking) return;
    final age = lastAttempt == null
        ? null
        : now().toUtc().difference(lastAttempt!);
    if (age != null && age < const Duration(days: 1)) return;
    await check(background: true);
  }

  Future<void> check({bool background = false}) async {
    if (_disposed || checking) return;
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

  void dismissNotice() {
    dismissedTag = available?.tag;
    _notify();
  }

  bool get showNotice => available != null && available!.tag != dismissedTag;
  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
