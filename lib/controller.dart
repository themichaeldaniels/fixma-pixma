import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/connection.dart';
import 'core/protocol.dart';
import 'core/report.dart';
import 'core/network_status.dart';
import 'core/printer_network.dart';
import 'core/ink_counter.dart';
import 'core/canon_maintenance.dart';
import 'core/print_queue.dart';
import 'core/model_support.dart';
import 'core/repair_record.dart';
import 'core/report_comparison.dart';
import 'core/capture_inspector.dart';
import 'core/canon_usage.dart';

part 'diagnostic_controller.dart';

class CanonControlCheck {
  final PrinterTarget target;
  final InkIdentity identity;
  final MaintenanceCapabilities capabilities;
  final CanonSettings settings;
  final DateTime checkedAt;
  CanonControlCheck(
    this.target,
    this.identity,
    this.capabilities,
    this.settings,
  ) : checkedAt = DateTime.now();
}

class InkResetCheck {
  final PrinterTarget target;
  final InkIdentity identity;
  final InkCounters counters;
  final DateTime checkedAt;
  InkResetCheck(this.target, this.identity, this.counters)
    : checkedAt = DateTime.now();
}

typedef PeerFactory = Future<PrinterPeer> Function(
  bool reset,
  void Function(Map<String, dynamic>) record,
);

class CareController extends ChangeNotifier {
  final Directory directory;
  final PeerFactory? peerFactory;
  final PrinterNetwork network;
  final InkCounterFactory inkFactory;
  final CanonMaintenanceFactory maintenanceFactory;
  final PrinterQueueService printerQueues;
  final WindowsQueueService windowsQueues;
  final Duration maintenancePollInterval;
  CanonControlCheck? canonControls;
  CareController({
    Directory? directory,
    this.peerFactory,
    PrinterNetwork? network,
    InkCounterFactory? inkFactory,
    CanonMaintenanceFactory? maintenanceFactory,
    PrinterQueueService? printerQueues,
    WindowsQueueService? windowsQueues,
    this.maintenancePollInterval = const Duration(seconds: 2),
  }) : printerQueues = printerQueues ?? IppQueueService(),
       windowsQueues = windowsQueues ?? NativeWindowsQueueService(),
       network = network ?? LocalPrinterNetwork(),
       inkFactory = inkFactory ?? CanonInkPeer.connect,
       maintenanceFactory = maintenanceFactory ?? LocalCanonMaintenance.connect,
       directory =
           directory ??
           Directory(
             '${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}${Platform.pathSeparator}PrinterCare',
           );
  ThemeMode themeMode = ThemeMode.system;
  Map<String, dynamic> profile = {};
  List<Map<String, dynamic>> devices = [], history = [];
  ServiceReport? report;
  List<PrinterTarget> networkPrinters = [];
  PrinterTarget? selectedPrinter;
  NetworkStatus? networkStatus;
  String networkError = '', usbError = '';
  bool networkRefreshing = false, autoRefresh = true;
  int successfulNetworkReads = 0;
  Timer? _monitor;
  bool get networkOnline =>
      networkStatus != null &&
      networkError.isEmpty &&
      networkStatus!.target.key == selectedPrinter?.key;
  bool busy = false, serviced = false, liveValid = false, priorAttempt = false;
  String progress = '', message = '', lastError = '', ip = '';
  Map<String, dynamic>? currentLog;
  File? currentFile;
  PrinterPeer? activePeer;
  bool disposed = false;
  @override
  void notifyListeners() {
    if (!disposed) super.notifyListeners();
  }

  List<WindowsQueue> localQueues = [];
  WindowsQueue? selectedQueue;
  QueueSnapshot? printerJobs, windowsJobs;
  String printerQueueError = '', windowsQueueError = '';
  List<ConnectionCheck> connectionChecks = [];
  DateTime? connectionCheckedAt;
  Set<String>? usbBaseline;
  InkIdentity? diagnosticIdentity;
  CanonUsage? canonUsage;
  List<RepairRecord> repairs = [];
  String repairLoadError = '';
  List<ServiceReport> importedReports = [];
  RepairStore get repairStore =>
      RepairStore(Directory('${directory.path}/repairs'));
  bool get canUseNetworkTools =>
      !busy && !networkRefreshing && selectedPrinter != null;

  Future<void> refreshQueues() async {
    if (busy || networkRefreshing) return;
    await run('queue status', () async {
      printerQueueError = '';
      windowsQueueError = '';
      printerJobs = null;
      windowsJobs = null;
      final target = selectedPrinter;
      if (target != null) {
        try {
          printerJobs = await printerQueues.read(target);
        } catch (e) {
          printerQueueError = cleanError(e);
        }
      } else {
        printerQueueError = 'Select a network printer in Overview.';
      }
      try {
        localQueues = await windowsQueues.list();
        final selected = selectedQueue;
        selectedQueue = selected == null
            ? null
            : localQueues
                  .where((q) => q.identity == selected.identity)
                  .firstOrNull;
        if (selectedQueue != null) {
          windowsJobs = await windowsQueues.read(selectedQueue!);
        }
      } catch (e) {
        windowsQueueError = cleanError(e);
      }
      record({
        'printerJobs': printerJobs?.jobs.length,
        'windowsQueues': localQueues.length,
        'printerError': printerQueueError,
        'windowsError': windowsQueueError,
      });
    });
  }

  Future<void> chooseQueue(WindowsQueue? queue) async {
    if (busy || networkRefreshing) return;
    selectedQueue = queue;
    windowsJobs = null;
    windowsQueueError = '';
    if (queue == null) {
      notifyListeners();
      return;
    }
    await run('Windows queue status', () async {
      try {
        windowsJobs = await windowsQueues.read(queue);
      } catch (e) {
        windowsQueueError = cleanError(e);
      }
    });
  }

  Future<void> cancelJobs(
    QueueSnapshot snapshot,
    List<QueueJob> jobs, {
    required bool confirmed,
  }) async {
    if (!confirmed || busy || networkRefreshing || jobs.isEmpty) return;
    if (DateTime.now().difference(snapshot.readAt) >
        const Duration(minutes: 2)) {
      lastError = 'The queue view is out of date. Refresh it before canceling.';
      notifyListeners();
      return;
    }
    final isPrinter = identical(snapshot, printerJobs),
        isWindows = identical(snapshot, windowsJobs);
    if ((!isPrinter && !isWindows) ||
        !snapshot.cancelSupported ||
        jobs.map((j) => j.id).toSet().length != jobs.length ||
        jobs.any(
          (j) =>
              !snapshot.cancelable.any((v) => v.fingerprint == j.fingerprint),
        )) {
      lastError = 'The queue or job selection changed. Refresh and try again.';
      notifyListeners();
      return;
    }
    final target = selectedPrinter, queue = selectedQueue;
    if ((isPrinter && target?.key != snapshot.sourceKey) ||
        (isWindows && queue?.identity != snapshot.identity)) {
      return;
    }
    await run('cancel queue jobs', () async {
      currentLog!['queue'] = snapshot.label;
      currentLog!['jobs'] = jobs.map((j) => j.toJson()).toList();
      try {
        for (final job in jobs) {
          updateProgress('Canceling job ${job.id}');
          record({
            'jobId': job.id,
            'stage': 'Attempt recorded before dispatch',
          });
          if (isPrinter) {
            await printerQueues.cancel(target!, snapshot, job);
          } else {
            await windowsQueues.cancel(queue!, job);
          }
          record({'jobId': job.id, 'stage': 'Cancellation acknowledged'});
        }
        message =
            'Cancellation acknowledged for ${jobs.length} job${jobs.length == 1 ? '' : 's'}.';
      } catch (e) {
        record({'stage': 'Batch stopped; no retry', 'error': cleanError(e)});
        rethrow;
      } finally {
        try {
          final fresh = isPrinter
              ? await printerQueues.read(target!)
              : await windowsQueues.read(queue!);
          if (isPrinter) {
            printerJobs = fresh;
          } else {
            windowsJobs = fresh;
          }
          final pending = jobs
              .where(
                (j) => fresh.jobs.any((v) => v.fingerprint == j.fingerprint),
              )
              .length;
          record({'stillListed': pending});
          if (message.isNotEmpty) {
            message = pending == 0
                ? 'The selected jobs are no longer listed.'
                : '$message $pending still listed; refresh to check progress.';
          }
        } catch (e) {
          if (isPrinter) {
            printerJobs = null;
            printerQueueError = cleanError(e);
          } else {
            windowsJobs = null;
            windowsQueueError = cleanError(e);
          }
          if (message.isNotEmpty) {
            message =
                '$message Queue refresh failed; completion is unverified.';
          }
        }
      }
    });
  }

  Future<void> initialize({bool scan = true}) async {
    directory.createSync(recursive: true);
    profile = jsonDecode(
      await rootBundle.loadString('assets/protocol.json'),
    ) as Map<String, dynamic>;
    try {
      final prefs = jsonDecode(
        File('${directory.path}/settings.json').readAsStringSync(),
      ) as Map;
      themeMode = ThemeMode.values.firstWhere(
        (v) => v.name == prefs['theme'],
        orElse: () => ThemeMode.system,
      );
      ip = prefs['ip'] as String? ?? '';
      autoRefresh = prefs['autoRefresh'] as bool? ?? true;
      if (prefs['printer'] is Map) {
        selectedPrinter = PrinterTarget.fromJson(prefs['printer'] as Map);
      } else if (ip.isNotEmpty) {
        selectedPrinter = PrinterTarget.parse(ip);
      }
    } catch (_) {
      /* New installations follow Windows. */
    }
    refreshHistory();
    restoreRepairs();
    restoreComparisonReports();
    notifyListeners();
    if (scan) await discover();
  }

  void setTheme(ThemeMode value) {
    themeMode = value;
    saveSettings();
    notifyListeners();
  }

  void saveSettings() {
    try {
      final temporary = File('${directory.path}/settings.json.tmp');
      temporary.writeAsStringSync(
        jsonEncode({
          'theme': themeMode.name,
          'ip': ip,
          'printer': selectedPrinter?.toJson(),
          'autoRefresh': autoRefresh,
        }),
        flush: true,
      );
      temporary.renameSync('${directory.path}/settings.json');
    } catch (e) {
      lastError = 'Could not save preferences. ${cleanError(e)}';
    }
  }

  void setServiced(bool value) {
    serviced = value;
    notifyListeners();
  }

  void refreshHistory() {
    final folder = Directory('${directory.path}/history');
    history = [];
    if (!folder.existsSync()) return;
    try {
      final files =
          folder
              .listSync(followLinks: false)
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .toList()
            ..sort((a, b) => b.path.compareTo(a.path));
      for (final file in files.take(200)) {
        try {
          if (file.lengthSync() > 16 * 1024 * 1024) continue;
          final value = jsonDecode(file.readAsStringSync());
          if (value is! Map<String, dynamic> ||
              value['started'] is! String ||
              DateTime.tryParse(value['started'] as String) == null ||
              value['kind'] is! String ||
              value['status'] is! String ||
              (value['events'] != null && value['events'] is! List) ||
              (value['report'] != null && value['report'] is! Map) ||
              (value['before'] != null && value['before'] is! Map) ||
              (value['after'] != null && value['after'] is! Map) ||
              (value['selectedColors'] != null &&
                  value['selectedColors'] is! List)) {
            continue;
          }
          history.add(value);
        } catch (_) {
          // One damaged record must not prevent startup or hide other history.
        }
      }
      history.sort(
        (a, b) => (b['started'] as String).compareTo(a['started'] as String),
      );
    } catch (e) {
      lastError = 'Could not read history. ${cleanError(e)}';
    }
  }

  void record(Map<String, dynamic> value) {
    currentLog?['events'].add(value);
    saveLog();
  }

  void saveLog() {
    if (currentFile != null && currentLog != null) {
      currentFile!.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(currentLog),
        flush: true,
      );
    }
  }

  void updateProgress(String text) {
    progress = text;
    notifyListeners();
  }

  Future<PrinterPeer> peer({bool reset = false}) async {
    final p = peerFactory == null
        ? await WorkerPeer.start(profile, reset: reset, record: record)
        : await peerFactory!(reset, record);
    activePeer = p;
    return p;
  }

  Future<void> discover() async {
    if (busy || networkRefreshing) return;
    busy = true;
    lastError = '';
    progress = 'Discovering USB and network printers';
    notifyListeners();
    try {
      final results = await Future.wait([
        _discoverUsb(),
        network
            .discover()
            .catchError((Object _) => <PrinterTarget>[])
            .then((v) => v as Object),
      ]);
      final found = results[1] as List<PrinterTarget>;
      final savedId = selectedPrinter?.discoveryId;
      if (savedId != null && savedId.isNotEmpty) {
        selectedPrinter =
            found.where((p) => p.discoveryId == savedId).firstOrNull ??
            selectedPrinter;
      }
      final merged = <String, PrinterTarget>{
        for (final printer in found) printer.key: printer,
      };
      if (selectedPrinter != null) {
        merged.putIfAbsent(selectedPrinter!.key, () => selectedPrinter!);
      }
      networkPrinters = merged.values.toList();
      selectedPrinter ??= found.firstOrNull;
      if (selectedPrinter != null) await _readNetwork();
    } catch (e) {
      networkError = cleanError(e);
    } finally {
      busy = false;
      progress = '';
      notifyListeners();
    }
  }

  Future<Object> _discoverUsb() async {
    PrinterPeer? p;
    try {
      p = await WorkerPeer.start(profile, record: (_) {});
      devices = List<Map<String, dynamic>>.from(
        (await p.call('scan') as List).map(
          (v) => Map<String, dynamic>.from(v as Map),
        ),
      );
      usbError = '';
    } catch (e) {
      usbError = cleanError(e);
      devices = [];
    } finally {
      await p?.close();
    }
    return true;
  }

  Future<void> _readNetwork() async {
    final target = selectedPrinter;
    if (target == null || disposed) return;
    networkRefreshing = true;
    notifyListeners();
    try {
      final value = await network.read(target);
      if (disposed || target.key != selectedPrinter?.key) return;
      if (networkStatus != null && networkStatus!.identity != value.identity) {
        canonControls = null;
        diagnosticIdentity = null;
        canonUsage = null;
        connectionChecks = [];
        connectionCheckedAt = null;
      }
      networkStatus = value;
      networkError = '';
      successfulNetworkReads++;
      final uuid = value.text('printer-uuid');
      if (uuid.isNotEmpty) {
        selectedPrinter = PrinterTarget(
          target.uri,
          discoveredName: target.discoveredName,
          discoveryId: uuid.toLowerCase().replaceFirst('urn:uuid:', ''),
        );
      }
      ip = target.uri.host;
      saveSettings();
    } catch (e) {
      if (!disposed && target.key == selectedPrinter?.key) {
        networkError = 'Cannot reach this printer. ${cleanError(e)}';
      }
    } finally {
      networkRefreshing = false;
      notifyListeners();
    }
  }

  Future<void> refreshNetwork() async {
    if (busy || networkRefreshing || disposed) return;
    await _readNetwork();
  }

  Future<void> selectPrinter(PrinterTarget target) async {
    if (busy || networkRefreshing) return;
    if (selectedPrinter?.key != target.key) {
      canonControls = null;
      networkStatus = null;
      diagnosticIdentity = null;
      canonUsage = null;
      connectionChecks = [];
      connectionCheckedAt = null;
      printerJobs = null;
    }
    selectedPrinter = target;
    networkError = '';
    if (!networkPrinters.any((p) => p.key == target.key)) {
      networkPrinters.add(target);
    }
    saveSettings();
    await refreshNetwork();
  }

  Future<void> connectAddress(String address) async {
    try {
      await selectPrinter(PrinterTarget.parse(address));
    } catch (e) {
      networkError = cleanError(e);
      notifyListeners();
    }
  }

  void startMonitoring() {
    _monitor?.cancel();
    if (autoRefresh && !disposed) {
      _monitor = Timer.periodic(
        const Duration(seconds: 15),
        (_) => unawaited(refreshNetwork()),
      );
    }
  }

  void setAutoRefresh(bool value) {
    autoRefresh = value;
    saveSettings();
    startMonitoring();
    notifyListeners();
  }

  Future<void> saveNetworkSnapshot() async {
    if (!networkOnline || busy) return;
    final snapshot = networkStatus!.toJson();
    await run('network snapshot', () async {
      currentLog!['network'] = snapshot;
      message = 'Printer status snapshot saved to History.';
    });
  }

  bool get canCheckInkReset =>
      networkOnline &&
      !busy &&
      !networkRefreshing &&
      networkStatus!.model.toLowerCase().contains('canon g7000') &&
      networkStatus!.firmware == '1.050';

  Future<InkResetCheck?> prepareInkReset() async {
    if (!canCheckInkReset) return null;
    final target = selectedPrinter!;
    busy = true;
    lastError = '';
    message = '';
    progress = 'Checking ink-reset support';
    notifyListeners();
    InkCounterPeer? peer;
    try {
      peer = await inkFactory(target.uri.host);
      final identity = await peer.identity();
      final counters = await peer.read();
      if (!identity.supported) {
        throw StateError(
          'This printer or firmware does not support the verified ink-reset profile.',
        );
      }
      if (!counters.ready) {
        throw StateError(
          'Wait until the printer is idle and clear its current error before resetting ink counts.',
        );
      }
      return InkResetCheck(target, identity, counters);
    } catch (e) {
      lastError = cleanError(e);
      return null;
    } finally {
      await peer?.close();
      busy = false;
      progress = '';
      notifyListeners();
    }
  }

  File _inkGuard(String serial) => File(
    '${directory.path}/ink-refill-${serial.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.json',
  );

  Future<void> resetInkCounts(
    InkResetCheck check,
    Set<String> colors, {
    required bool filledToUpperLine,
  }) async {
    if (busy || networkRefreshing || disposed) return;
    if (!filledToUpperLine ||
        colors.isEmpty ||
        colors.any((color) => !inkNames.containsKey(color)) ||
        check.target.key != selectedPrinter?.key ||
        DateTime.now().difference(check.checkedAt) >
            const Duration(minutes: 2)) {
      lastError = 'Choose the refilled colors, confirm the upper line, and run a fresh ink check.';
      notifyListeners();
      return;
    }
    await run('ink refill reset', () async {
      InkCounterPeer? peer;
      try {
        peer = await inkFactory(check.target.uri.host);
        final identity = await peer.identity();
        if (!identity.supported ||
            identity.serial != check.identity.serial ||
            identity.model != check.identity.model ||
            identity.firmware != check.identity.firmware) {
          throw StateError(
            'Printer identity changed. Check the selected printer again.',
          );
        }
        final before = await peer.read();
        if (!before.ready ||
            colors.any((color) => before.levels[color] == null)) {
          throw StateError(
            'Printer is busy, has an error, or did not report the selected counters.',
          );
        }
        currentLog!['printer'] = identity.toJson();
        currentLog!['target'] = check.target.toJson();
        currentLog!['selectedColors'] = inkNames.keys
            .where(colors.contains)
            .toList();
        currentLog!['before'] = before.toJson();
        currentLog!['filledToUpperLine'] = true;
        final guard = _inkGuard(identity.serial);
        Map<String, dynamic> pending = {};
        if (guard.existsSync()) {
          pending = Map<String, dynamic>.from(
            jsonDecode(guard.readAsStringSync()) as Map,
          );
        }
        for (final color in pending.keys.toList()) {
          if (before.levels[color] == 100) pending.remove(color);
        }
        if (guard.existsSync()) {
          guard.writeAsStringSync(jsonEncode(pending), flush: true);
        }
        if (colors.any(pending.containsKey)) {
          throw StateError(
            'A previous refill reset has not been verified. Refresh the printer after restarting it; do not repeat the reset.',
          );
        }
        var current = before;
        for (final color in inkNames.keys.where(colors.contains)) {
          if (current.levels[color] == 100) {
            record({
              'color': color,
              'result': 'Already reports full; no command sent',
            });
            continue;
          }
          if (!current.ready) {
            throw StateError(
              'The printer is no longer idle. Remaining colors were not reset.',
            );
          }
          updateProgress(
            'Resetting ${inkNames[color]!.toLowerCase()} ink count',
          );
          pending[color] = {
            'attemptedAt': DateTime.now().toIso8601String(),
            'before': current.levels[color],
          };
          guard.writeAsStringSync(jsonEncode(pending), flush: true);
          currentLog!['inkCounterAttempted'] = true;
          record({'color': color, 'stage': 'Attempt recorded before dispatch'});
          await peer.resetColor(color);
          record({'color': color, 'stage': 'Printer acknowledged reset'});
          final previous = current;
          // Poll readings only. Never resend the mutation after a timeout.
          for (var attempt = 0; attempt < 5; attempt++) {
            if (attempt > 0) {
              await Future<void>.delayed(const Duration(seconds: 1));
            }
            current = await peer.read();
            if (current.levels[color] == 100) break;
          }
          currentLog!['after'] = current.toJson();
          saveLog();
          if (current.levels[color] != 100) {
            throw StateError(
              'The printer acknowledged the ${inkNames[color]!.toLowerCase()} reset, but its estimate has not changed to full. Restart the printer and refresh. No reset was repeated.',
            );
          }
          if (inkNames.keys
              .where((c) => c != color)
              .any((c) => current.levels[c] != previous.levels[c])) {
            throw StateError(
              'An unselected ink estimate changed. Check the saved report before any further reset.',
            );
          }
          pending.remove(color);
          guard.writeAsStringSync(jsonEncode(pending), flush: true);
          record({'color': color, 'result': 'Verified at 100%'});
        }
        currentLog!['verified'] = true;
        currentLog!['after'] = current.toJson();
        message = 'Selected ink counts now report full. Readback verified with the printer.';
      } finally {
        await peer?.close();
        await _readNetwork();
        if (networkStatus != null) {
          currentLog!['network'] = networkStatus!.toJson();
        }
      }
    });
  }

  bool get canReadCanonControls => canCheckInkReset;

  Future<void> loadCanonControls() async {
    if (!canReadCanonControls) return;
    final target = selectedPrinter!;
    await run('Canon controls', () async {
      final peer = await maintenanceFactory(target.uri.host);
      try {
        final identity = await peer.identity();
        if (!identity.supported) {
          throw StateError(
            'This model or firmware has not been verified for Canon controls.',
          );
        }
        final capabilities = await peer.capabilities();
        final settings = await peer.settings();
        final guard = _maintenanceGuard(identity.serial);
        if (guard.existsSync()) {
          final pending = jsonDecode(guard.readAsStringSync()) as Map;
          final task = CanonTask.values.byName(pending['task'] as String);
          final status = await peer.read();
          final job = MaintenanceJob.parse(
            await peer.jobStatus(pending['job'] as String),
            pending['job'] as String,
            task,
          );
          if (status.ready &&
              (job.completed ||
                  (job.absent && pending['matchedJobSeen'] == true))) {
            record({
              'previousTask': task.name,
              'result': 'Printer returned idle after observed maintenance job',
            });
            guard.deleteSync();
          }
        }
        canonControls = CanonControlCheck(
          target,
          identity,
          capabilities,
          settings,
        );
        currentLog!['printer'] = identity.toJson();
        currentLog!['settings'] = settings.values;
        message = 'Canon controls loaded from the printer.';
      } finally {
        await peer.close();
      }
    });
  }

  bool _validCanonCheck(CanonControlCheck check) =>
      check.target.key == selectedPrinter?.key &&
      DateTime.now().difference(check.checkedAt) < const Duration(minutes: 10);

  Future<InkIdentity> _checkCanonIdentity(
    CanonMaintenancePeer peer,
    CanonControlCheck check,
  ) async {
    final identity = await peer.identity();
    if (!identity.supported ||
        identity.serial != check.identity.serial ||
        identity.model != check.identity.model ||
        identity.firmware != check.identity.firmware) {
      throw StateError('Printer identity changed. Reload Canon controls.');
    }
    return identity;
  }

  File _maintenanceGuard(String serial) => File(
    '${directory.path}/maintenance-${serial.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.json',
  );

  Future<void> runCanonTask(
    CanonTask task, {
    required bool prepared,
    String paper = letterPaper,
  }) async {
    if (busy || networkRefreshing || disposed) return;
    final check = canonControls;
    if (check == null ||
        !_validCanonCheck(check) ||
        !prepared ||
        !{letterPaper, a4Paper}.contains(paper) ||
        !check.capabilities.supports(task, paper)) {
      lastError = 'Reload Canon controls and confirm the task preparation.';
      notifyListeners();
      return;
    }
    await run(task.label, () async {
      final peer = await maintenanceFactory(check.target.uri.host);
      String? job;
      try {
        final identity = await _checkCanonIdentity(peer, check);
        final caps = await peer.capabilities();
        final before = await peer.read();
        if (!caps.supports(task, paper) ||
            !before.ready ||
            inkNames.keys.any((color) => (before.levels[color] ?? 0) <= 0)) {
          throw StateError(
            'The printer must be idle, error-free, and report ink available in all four colors.',
          );
        }
        final guard = _maintenanceGuard(identity.serial);
        if (guard.existsSync()) {
          throw StateError(
            'A previous maintenance result is uncertain. Check History and the printer before another task.',
          );
        }
        currentLog!['printer'] = identity.toJson();
        currentLog!['target'] = check.target.toJson();
        currentLog!['task'] = task.name;
        currentLog!['paper'] = task.usesPaper ? paper : null;
        currentLog!['before'] = before.toJson();
        if (task == CanonTask.automaticAlignment) {
          currentLog!['alignmentBefore'] = (await peer.settings()).alignment;
        }
        currentLog!['sheetCount'] = task.sheetCount;
        job = await peer.startJob();
        currentLog!['job'] = job;
        guard.writeAsStringSync(
          jsonEncode({
            'job': job,
            'task': task.name,
            'attemptedAt': DateTime.now().toIso8601String(),
          }),
          flush: true,
        );
        currentLog!['maintenanceCommandAttempted'] = true;
        record({'stage': 'Attempt recorded before dispatch', 'job': job});
        updateProgress('Starting ${task.label.toLowerCase()}');
        await peer.execute(task, job, paper);
        currentLog!['acknowledged'] = true;
        record({'stage': 'Printer acknowledged task'});
        await peer.endJob(job);
        final expectedJob = job;
        job = null;
        var matchedJobSeen = false;
        final deadline = DateTime.now().add(task.completionTimeout);
        while (DateTime.now().isBefore(deadline)) {
          final status = await peer.read();
          final jobXml = await peer.jobStatus(expectedJob);
          final result = MaintenanceJob.parse(jobXml, expectedJob, task);
          matchedJobSeen |= result.matched && result.progress == 'processing';
          guard.writeAsStringSync(
            jsonEncode({
              'job': expectedJob,
              'task': task.name,
              'matchedJobSeen': matchedJobSeen,
            }),
            flush: true,
          );
          currentLog!['after'] = status.toJson();
          currentLog!['jobStatus'] = result.toJson();
          saveLog();
          if (result.failed || status.supportCode.isNotEmpty) {
            throw StateError(
              'Printer stopped this task${status.supportCode.isEmpty ? '' : ' with code ${status.supportCode}'}. Check the printer. The command was not repeated.',
            );
          }
          if (status.ready &&
              (result.completed || (matchedJobSeen && result.absent))) {
            guard.deleteSync();
            currentLog!['verified'] = true;
            if (task == CanonTask.automaticAlignment) {
              canonControls = null;
              try {
                final afterSettings = await peer.settings();
                currentLog!['alignmentAfter'] = afterSettings.alignment;
                canonControls = CanonControlCheck(
                  check.target,
                  identity,
                  caps,
                  afterSettings,
                );
              } catch (e) {
                currentLog!['alignmentReadbackError'] = cleanError(e);
              }
            }
            message = task == CanonTask.automaticAlignment
                ? 'Automatic printhead alignment completed. The printer finished its adjustment and is ready.'
                : task.usesPaper
                ? '${task.label} completed. Examine the printed sheet; print quality needs a visual check.'
                : 'Printhead cleaning completed. Print a nozzle check to examine the result.';
            return;
          }
          updateProgress(
            '${task.label} · ${result.progress.isEmpty ? 'waiting for printer' : result.progress}',
          );
          await Future<void>.delayed(maintenancePollInterval);
        }
        throw StateError(
          'The task was acknowledged, but completion is unverified. No command was repeated. Check the printer and History.',
        );
      } finally {
        if (job != null) {
          try {
            await peer.endJob(job);
          } catch (e) {
            record({'sessionCloseError': cleanError(e)});
          }
        }
        await peer.close();
        await _readNetwork();
        currentLog!['network'] = networkStatus?.toJson();
      }
    });
  }

  Future<void> saveCanonSetting(String key, String value) async {
    if (busy || networkRefreshing || disposed) return;
    final check = canonControls;
    if (check == null ||
        !_validCanonCheck(check) ||
        CanonSettings.allowed[key]?.contains(value) != true) {
      lastError = 'Reload Canon controls before applying a supported setting.';
      notifyListeners();
      return;
    }
    await run('Printer setting', () async {
      final peer = await maintenanceFactory(check.target.uri.host);
      try {
        final identity = await _checkCanonIdentity(peer, check);
        if (!(await peer.read()).ready) {
          throw StateError(
            'Wait until the printer is idle and clear any current error.',
          );
        }
        final before = await peer.settings();
        currentLog!['printer'] = identity.toJson();
        currentLog!['setting'] = key;
        currentLog!['beforeSettings'] = before.values;
        currentLog!['requestedValue'] = value;
        if (before.values[key] == value) {
          currentLog!['verified'] = true;
          message =
              'The printer already uses that setting. No change was sent.';
          return;
        }
        currentLog!['settingChangeAttempted'] = true;
        record({'stage': 'Attempt recorded before dispatch'});
        await peer.setSetting(key, value);
        final after = await peer.settings();
        currentLog!['afterSettings'] = after.values;
        canonControls = CanonControlCheck(
          check.target,
          identity,
          check.capabilities,
          after,
        );
        if (after.values[key] != value ||
            before.values.keys
                .where((k) => k != key)
                .any((k) => before.values[k] != after.values[k])) {
          throw StateError(
            'Setting readback did not match the selected change. Reload Canon controls; no change was retried.',
          );
        }
        currentLog!['verified'] = true;
        message =
            '${CanonSettings.labels[key]} saved and read back from the printer.';
      } finally {
        await peer.close();
      }
    });
  }

  Future<void> sample() async {
    if (busy) return;
    report = ServiceReport.parse(
      await rootBundle.loadString('assets/sample-report.txt'),
      sample: true,
    );
    liveValid = false;
    serviced = false;
    priorAttempt = false;
    message = 'Sample report loaded. No printer commands were sent.';
    lastError = '';
    notifyListeners();
  }

  Future<void> run(String kind, Future<void> Function() body) async {
    if (busy || disposed) return;
    busy = true;
    lastError = '';
    message = '';
    progress = 'Connecting to the printer';
    notifyListeners();
    currentLog = {
      'kind': kind,
      'started': DateTime.now().toIso8601String(),
      'status': 'In progress',
      'events': <Map<String, dynamic>>[],
      'counterClearAttempted': false,
    };
    RandomAccessFile? operationLock;
    try {
      // Serialize transactions across application instances sharing this state.
      // A crashed process releases the OS lock; durable reset guards remain.
      operationLock = File('${directory.path}/operation.lock')
          .openSync(mode: FileMode.append);
      try {
        operationLock.lockSync(FileLock.exclusive);
      } on FileSystemException {
        throw StateError(
          'Another Printer Care instance is working. Wait for it to finish.',
        );
      }
      final folder = Directory('${directory.path}/history')
        ..createSync(recursive: true);
      currentFile = File(
        '${folder.path}/${DateTime.now().microsecondsSinceEpoch}-$kind.json',
      );
      saveLog();
      await body();
      if (currentLog!['status'] == 'In progress') {
        currentLog!['status'] = 'Completed';
      }
    } catch (e) {
      lastError = cleanError(e);
      currentLog!['status'] = 'Stopped';
      currentLog!['error'] = lastError;
    } finally {
      try {
        await activePeer?.close();
      } catch (e) {
        lastError = 'Connection cleanup failed. ${cleanError(e)}';
        currentLog!['status'] = 'Stopped';
        currentLog!['error'] = lastError;
      }
      try {
        currentLog!['finished'] = DateTime.now().toIso8601String();
        saveLog();
      } catch (e) {
        lastError = 'Could not save operation history. ${cleanError(e)}';
      } finally {
        try {
          operationLock?.closeSync();
        } catch (_) {
          // The operating system also releases this lock on process exit.
        }
        activePeer = null;
        currentFile = null;
        currentLog = null;
        busy = false;
        progress = '';
        refreshHistory();
        restoreRepairs();
        notifyListeners();
      }
    }
  }

  Future<ServiceReport> readReport({String? expectedSerial}) async {
    final p = await peer();
    try {
      final identity = Map<String, dynamic>.from(
        await p.call('open', {'expectedSerial': expectedSerial}) as Map,
      );
      record({'identity': identity});
      await p.call('session');
      updateProgress('Checking the service connection');
      await exchange(p, '10077c', progress: updateProgress);
      updateProgress('Reading the service report');
      final result = await exchange(p, '15', progress: updateProgress);
      final text = latin1
          .decode(hexBytes(result['data'] as String))
          .replaceAll('\r', '')
          .replaceAll('\x00', '');
      final parsed = ServiceReport.parse(text);
      if (parsed.serial != identity['serial']) {
        throw StateError(
          'The service report does not match the connected printer.',
        );
      }
      return parsed;
    } finally {
      await p.close();
      if (activePeer == p) activePeer = null;
    }
  }

  void acceptReport(ServiceReport value) {
    report = value;
    liveValid = true;
    serviced = false;
    priorAttempt = guard(value.serial).existsSync();
    currentLog?['report'] = value.toJson();
    saveLog();
  }

  Future<void> diagnose() async {
    if (busy) return;
    liveValid = false;
    await run('diagnostic', () async {
      acceptReport(await readReport());
      message = 'Diagnostic complete. The service report has been saved.';
    });
  }

  File guard(String serial) => File(
    '${directory.path}/reset-${serial.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.json',
  );
  String? get resetBlocked => report == null
      ? 'Run a live diagnostic first.'
      : ResetRules.blocked(
          live: liveValid && !report!.sample,
          counter: report!.waste,
          firmware: report!.firmware,
          priorAttempt: priorAttempt,
          serviced: serviced,
          capturedAt: report!.capturedAt,
        );
  Future<void> reset() async {
    if (busy) return;
    if (resetBlocked != null) {
      lastError = resetBlocked!;
      notifyListeners();
      return;
    }
    final before = report!;
    await run('reset', () async {
      final p = await peer(reset: true);
      await p.call('open', {'expectedSerial': before.serial});
      await p.call('session');
      updateProgress('Validating a fresh service session');
      await exchange(p, '10077c', progress: updateProgress);
      final marker = guard(before.serial);
      marker.createSync(exclusive: true);
      marker.writeAsStringSync(
        jsonEncode({
          'serial': before.serial,
          'time': DateTime.now().toIso8601String(),
          'state': 'Clear about to be sent; result unknown',
        }),
        flush: true,
      );
      priorAttempt = true;
      final repair = RepairRecord(
        id: 'repair-${DateTime.now().microsecondsSinceEpoch}',
        serial: before.serial,
        model: 'G7000 series',
        firmware: before.firmware,
        createdAt: DateTime.now(),
        beforeCounter: before.waste,
      );
      repairStore.write(repair);
      currentLog!['repairId'] = repair.id;
      currentLog!['counterClearAttempted'] = true;
      currentLog!['beforeCounter'] = before.waste;
      saveLog();
      updateProgress('Resetting the waste counter');
      await exchange(p, '0d0000', progress: updateProgress);
      currentLog!['clearAcknowledged'] = true;
      repair.acknowledged = true;
      repairStore.write(repair);
      saveLog();
      marker.writeAsStringSync(
        jsonEncode({
          'serial': before.serial,
          'time': DateTime.now().toIso8601String(),
          'state': 'Clear acknowledged; restart verification pending',
        }),
        flush: true,
      );
      await p.close();
      activePeer = null;
      try {
        updateProgress('Reading the counter after reset');
        acceptReport(await readReport(expectedSerial: before.serial));
        currentLog!['afterCounter'] = report!.waste;
        repair.afterCounter = report!.waste;
        repairStore.write(repair);
        if (report!.waste != 0) {
          throw StateError(
            'The clear was acknowledged, but the counter did not read zero. Do not repeat the reset.',
          );
        }
        message = 'Counter reset to 0.0%. Use Power to shut down fully, then start normally and check the display.';
      } catch (e) {
        message = 'The clear was acknowledged. Restart verification is still required.';
        rethrow;
      } finally {
        restoreRepairs();
      }
    });
  }

  Future<void> stop() async {
    await activePeer?.close();
  }

  Future<void> verify(String address) async {
    if (busy) return;
    final parts = address.trim().split('.');
    if (parts.length != 4 ||
        parts.any(
          (v) =>
              int.tryParse(v) == null || int.parse(v) < 0 || int.parse(v) > 255,
        )) {
      lastError = 'Enter the printer’s IPv4 address, for example 192.168.1.50.';
      notifyListeners();
      return;
    }
    ip = address.trim();
    saveSettings();
    await run('restart check', () async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      client.findProxy = (_) => 'DIRECT';
      try {
        final request = await client.getUrl(
          Uri.parse('http://$ip/JS_MDL/model.js'),
        );
        request.followRedirects = false;
        request.headers.set('Cache-Control', 'no-cache');
        final response = await request.close().timeout(
          const Duration(seconds: 8),
        );
        final bytes = await (() async {
          final data = <int>[];
          await for (final chunk in response) {
            if (data.length + chunk.length > 1024 * 1024) {
              throw const FormatException(
                'Printer status response is too large.',
              );
            }
            data.addAll(chunk);
          }
          return data;
        })().timeout(const Duration(seconds: 8));
        final text = utf8.decode(bytes, allowMalformed: true);
        if (response.statusCode != 200 ||
            !text.contains('G7000') ||
            !text.contains('g_prndoc')) {
          throw StateError(
            'The G7000 status page was not found. Confirm the printer’s IP address.',
          );
        }
        final full =
            RegExp(r'ERR=5[Bb]00').hasMatch(text) ||
            RegExp("g_prndoc\\s*=\\s*['\"]23296").hasMatch(text);
        currentLog!['error5b00Present'] = full;
        message = full
            ? '5B00 is still reported. Keep the saved log; do not repeat the reset.'
            : '5B00 is absent from the web status. Confirm the LCD is clear and try a normal print.';
      } finally {
        client.close(force: true);
      }
    });
  }

  String exportText() {
    final r = report;
    final live = networkStatus;
    return '${live == null ? '' : '${live.exportText()}\nConnection: ${networkOnline ? 'Online at export' : 'Offline - last known reading'}\n\n'}${r == null ? '' : 'PRINTER CARE - ${r.sample ? 'SAMPLE REPORT' : 'SERVICE REPORT'}\nCaptured: ${r.capturedAt.toIso8601String()}\n\n${r.raw}\n\n'}Local history\n${const JsonEncoder.withIndent('  ').convert(history)}';
  }

  static String cleanError(Object e) => e.toString().replaceFirst(
    RegExp(r'^(?:(?:Bad state|StateError|FormatException|Exception): )+'),
    '',
  );
  @override
  void dispose() {
    disposed = true;
    _monitor?.cancel();
    activePeer?.close();
    super.dispose();
  }
}
