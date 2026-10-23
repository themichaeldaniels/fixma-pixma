import 'package:xml/xml.dart';

import 'canon_command.dart';
import 'ink_counter.dart';

const canonCommon = 'http://www.canon.com/ns/cmd/2008/07/common/';
const letterPaper = 'na_letter_8.5x11in';
const a4Paper = 'iso_a4_210x297mm';

enum CanonTask {
  nozzleCheck('Nozzle check', 'TestPrint', 'nozzle_check'),
  cleaning('Printhead cleaning', 'Cleaning', 'regular'),
  alignmentCheck('Alignment check', 'TestPrint', 'regi_check'),
  automaticAlignment(
    'Automatic printhead alignment',
    'TestPrint',
    'auto_registration',
  );

  final String label, operation, type;
  const CanonTask(this.label, this.operation, this.type);
  bool get usesPaper => this != cleaning;
  int get sheetCount => this == automaticAlignment
      ? 2
      : usesPaper
      ? 1
      : 0;
  Duration get completionTimeout =>
      Duration(minutes: this == automaticAlignment ? 10 : 5);
}

class MaintenanceCapabilities {
  final Map<String, Set<String>> printSizes;
  final Set<String> cleaningGroups;
  final Map<String, Map<String, int>> paperCounts;
  const MaintenanceCapabilities(
    this.printSizes,
    this.cleaningGroups, {
    this.paperCounts = const {},
  });
  bool supports(CanonTask task, String paper) => task == CanonTask.cleaning
      ? cleaningGroups.contains('all')
      : printSizes[task.type]?.contains(paper) == true &&
            (task != CanonTask.automaticAlignment ||
                paperCounts[task.type]?[paper] == task.sheetCount);

  static MaintenanceCapabilities parse(String xml) {
    final p = CanonInkPeer.reply(xml, 'GetCapabilityResponse', 'maintenance');
    final sizes = <String, Set<String>>{};
    final counts = <String, Map<String, int>>{};
    for (final type
        in p
            .findElements('TestPrint', namespace: canonCommon)
            .expand((e) => e.findElements('type', namespace: canonCommon))) {
      if (_text(type, 'inputbin') != 'inputbin_p2' ||
          _text(type, 'papertype') != 'stationery') {
        continue;
      }
      sizes[type.getAttribute('value') ?? ''] = _text(
        type,
        'papersize',
      ).split(',').toSet();
      counts[type.getAttribute('value') ?? ''] = {
        for (final n in type.findElements('papernum', namespace: canonCommon))
          if (int.tryParse(n.innerText.trim()) case final int count)
            n.getAttribute('papersize') ?? '': count,
      };
    }
    final regular = p
        .findElements('Cleaning', namespace: canonCommon)
        .expand((e) => e.findElements('type', namespace: canonCommon))
        .where((e) => e.getAttribute('value') == 'regular')
        .singleOrNull;
    return MaintenanceCapabilities(
      sizes,
      regular == null ? {} : _text(regular, 'inkgroup').split(',').toSet(),
      paperCounts: counts,
    );
  }
}

String _text(XmlElement p, String name) =>
    p
        .findElements(name, namespace: canonCommon)
        .singleOrNull
        ?.innerText
        .trim() ??
    '';

/// Only the user-facing settings we can read back independently.
class CanonSettings {
  final Map<String, String> values;
  final Map<String, int> alignment;
  const CanonSettings(this.values, {this.alignment = const {}});
  static const allowed = {
    'quiet': {'ON', 'OFF'},
    'autoPowerOn': {'ON', 'OFF'},
    'autoPowerOff': {'OFF', '15', '30', '60', '120', '240'},
    'paperGap': {'auto', 'wide'},
    'dryLevel': {'1', '2', '3', '4', '5'},
  };
  static const labels = {
    'quiet': 'Quiet mode',
    'autoPowerOn': 'Automatic power on',
    'autoPowerOff': 'Automatic power off',
    'paperGap': 'Prevent paper abrasion',
    'dryLevel': 'Ink drying wait',
  };
  static CanonSettings parse(String xml) {
    final p = CanonInkPeer.reply(xml, 'GetConfigurationResponse', 'device');
    final off = p
        .findElements('autopoweroff', namespace: canonCommon)
        .singleOrNull;
    final quiet = p
        .findElements('silentmode', namespace: canonCommon)
        .singleOrNull;
    final alignment = <String, int>{};
    for (final group in p.findElements(
      'setregistration',
      namespace: canonCommon,
    )) {
      for (final item in group.findElements('item', namespace: canonCommon)) {
        final sign = item.getAttribute('sign') ?? '';
        final value = int.tryParse(item.innerText.trim());
        if (RegExp(r'^[A-T]$').hasMatch(sign) &&
            value != null &&
            value.abs() <= 5) {
          alignment[sign] = value;
        }
      }
    }
    return CanonSettings({
      'quiet': quiet == null ? '' : _text(quiet, 'mode'),
      'autoPowerOn': _text(p, 'autopoweron'),
      'autoPowerOff': off == null
          ? ''
          : _text(off, 'mode') == 'OFF'
          ? 'OFF'
          : _text(off, 'time'),
      'paperGap': _text(p, 'papergap'),
      'dryLevel': _text(p, 'drylevel'),
    }, alignment: alignment);
  }

  static String display(String key, String value) =>
      value != 'time' && allowed[key]?.contains(value) != true
      ? 'Not reported'
      : switch (key) {
          'autoPowerOff' => value == 'OFF' ? 'Disabled' : '$value minutes',
          'paperGap' => value == 'wide' ? 'On' : 'Automatic',
          'dryLevel' =>
            {
                  '1': 'Shortest',
                  '2': 'Short',
                  '3': 'Standard',
                  '4': 'Long',
                  '5': 'Longest',
                }[value] ??
                'Not reported',
          _ =>
            value == 'ON'
                ? 'On'
                : value == 'OFF'
                ? 'Off'
                : value == 'time'
                ? 'Scheduled on printer'
                : 'Not reported',
        };
}

abstract interface class CanonMaintenancePeer {
  Future<InkIdentity> identity();
  Future<InkCounters> read();
  Future<MaintenanceCapabilities> capabilities();
  Future<CanonSettings> settings();
  Future<void> setSetting(String key, String value);
  Future<String> startJob();
  Future<void> execute(CanonTask task, String job, String paper);
  Future<void> endJob(String job);
  Future<String> jobStatus(String job);
  Future<void> close();
}

typedef CanonMaintenanceFactory = Future<CanonMaintenancePeer> Function(
  String host,
);

class MaintenanceJob {
  final String progress;
  final bool completed, failed, matched, absent;
  const MaintenanceJob(
    this.progress, {
    this.completed = false,
    this.failed = false,
    this.matched = false,
    this.absent = false,
  });
  Map<String, dynamic> toJson() => {
    'progress': progress,
    'completed': completed,
    'failed': failed,
    'matched': matched,
    'absent': absent,
  };
  static MaintenanceJob parse(String xml, String job, CanonTask task) {
    final p = CanonInkPeer.reply(xml, 'GetStatusResponse', 'maintenance');
    final info = p
        .findElements('jobinfo', namespace: canonCommon)
        .where((e) => e.getAttribute('jobID') == job)
        .singleOrNull;
    if (info == null) {
      if (p
          .findElements('jobinfo', namespace: canonCommon)
          .any((e) => (e.getAttribute('jobID') ?? '').isNotEmpty)) {
        throw StateError('A different maintenance job is active.');
      }
      return const MaintenanceJob('No active maintenance job', absent: true);
    }
    if (_text(info, 'maintenance_operation') != task.operation ||
        _text(info, 'type') != task.type) {
      throw StateError(
        'Printer maintenance result belongs to a different task.',
      );
    }
    final progress = _text(info, 'jobprogress');
    return MaintenanceJob(
      progress,
      matched: true,
      completed: progress == 'completed',
      failed: {'aborted', 'canceled', 'cancelled', 'failed'}.contains(progress),
    );
  }
}

class LocalCanonMaintenance implements CanonMaintenancePeer {
  final CanonCommandConnection connection;
  InkIdentity? _identity;
  MaintenanceCapabilities? _capabilities;
  String? _job;
  LocalCanonMaintenance(this.connection);
  static Future<LocalCanonMaintenance> connect(String host) async =>
      LocalCanonMaintenance(await CanonCommandConnection.connect(host));

  static String command(String operation, String service, String content) =>
      '<?xml version="1.0" encoding="utf-8"?><cmd xmlns:ivec="$canonCommon">'
      '<ivec:contents><ivec:operation>$operation</ivec:operation>'
      '<ivec:param_set servicetype="$service">$content</ivec:param_set></ivec:contents></cmd>';
  Future<String> _exchange(String op, String service, [String content = '']) =>
      connection.exchange(command(op, service, content));
  @override
  Future<InkIdentity> identity() async => _identity =
      CanonInkPeer.parseIdentity(await _exchange('GetCapability', 'device'));
  @override
  Future<InkCounters> read() async =>
      CanonInkPeer.parseCounters(await _exchange('GetStatus', 'print'));
  @override
  Future<MaintenanceCapabilities> capabilities() async =>
      _capabilities = MaintenanceCapabilities.parse(
        await _exchange('GetCapability', 'maintenance'),
      );
  @override
  Future<CanonSettings> settings() async =>
      CanonSettings.parse(await _exchange('GetConfiguration', 'device'));
  void _supported() {
    if (_identity?.supported != true) {
      throw StateError('Unsupported Canon maintenance profile.');
    }
  }

  static void _validJob(String job) {
    if (!RegExp(r'^\d{8}$').hasMatch(job)) {
      throw ArgumentError('Invalid maintenance job identifier.');
    }
  }

  static String taskContent(CanonTask task, String job, String paper) {
    _validJob(job);
    if (!{letterPaper, a4Paper}.contains(paper)) {
      throw ArgumentError('Choose Letter or A4.');
    }
    return '<ivec:jobID>$job</ivec:jobID><ivec:type>${task.type}</ivec:type>'
        '${task.usesPaper ? '<ivec:inputbin>inputbin_p2</ivec:inputbin><ivec:papersize>$paper</ivec:papersize><ivec:papertype>stationery</ivec:papertype>' : '<ivec:inkgroup>all</ivec:inkgroup>'}';
  }

  static String settingContent(String key, String value) {
    if (CanonSettings.allowed[key]?.contains(value) != true) {
      throw ArgumentError('Unsupported printer setting.');
    }
    return switch (key) {
      'quiet' =>
        '<ivec:silentmode><ivec:mode>$value</ivec:mode></ivec:silentmode>',
      'autoPowerOn' => '<ivec:autopoweron>$value</ivec:autopoweron>',
      'autoPowerOff' =>
        '<ivec:autopoweroff><ivec:mode>${value == 'OFF' ? 'OFF' : 'ON'}</ivec:mode>${value == 'OFF' ? '' : '<ivec:time>$value</ivec:time>'}</ivec:autopoweroff>',
      'paperGap' => '<ivec:papergap>$value</ivec:papergap>',
      'dryLevel' => '<ivec:drylevel>$value</ivec:drylevel>',
      _ => throw ArgumentError('Unsupported printer setting.'),
    };
  }

  @override
  Future<void> setSetting(String key, String value) async {
    _supported();
    final content = settingContent(key, value);
    if (_job != null) throw StateError('A maintenance job is already open.');
    final requested = (DateTime.now().microsecondsSinceEpoch % 100000000)
        .toString()
        .padLeft(8, '0');
    final start = CanonInkPeer.reply(
      await _exchange(
        'StartJob',
        'device',
        '<ivec:jobID>$requested</ivec:jobID><ivec:bidi>1</ivec:bidi>',
      ),
      'StartJobResponse',
      'device',
    );
    if (_text(start, 'jobID') != requested) {
      throw StateError('Device settings session changed.');
    }
    try {
      CanonInkPeer.reply(
        await _exchange(
          'SetConfiguration',
          'device',
          '<ivec:jobID>$requested</ivec:jobID>$content',
        ),
        'SetConfigurationResponse',
        'device',
      );
    } finally {
      final end = CanonInkPeer.reply(
        await _exchange(
          'EndJob',
          'device',
          '<ivec:jobID>$requested</ivec:jobID>',
        ),
        'EndJobResponse',
        'device',
      );
      if (_text(end, 'jobID') != requested) {
        throw StateError('Device settings session did not close.');
      }
    }
  }

  @override
  Future<String> startJob() async {
    _supported();
    if (_job != null) throw StateError('A maintenance job is already open.');
    final requested = (DateTime.now().microsecondsSinceEpoch % 100000000)
        .toString()
        .padLeft(8, '0');
    final p = CanonInkPeer.reply(
      await _exchange(
        'StartJob',
        'maintenance',
        '<ivec:jobID>$requested</ivec:jobID><ivec:bidi>1</ivec:bidi>',
      ),
      'StartJobResponse',
      'maintenance',
    );
    final job = _text(p, 'jobID');
    _validJob(job);
    if (job != requested) {
      throw StateError('Printer returned a different maintenance job.');
    }
    return _job = job;
  }

  @override
  Future<void> execute(CanonTask task, String job, String paper) async {
    _supported();
    if (_job != job || _capabilities?.supports(task, paper) != true) {
      throw StateError('Maintenance session or capability check failed.');
    }
    CanonInkPeer.reply(
      await _exchange(
        task.operation,
        'maintenance',
        taskContent(task, job, paper),
      ),
      '${task.operation}Response',
      'maintenance',
    );
  }

  @override
  Future<void> endJob(String job) async {
    _validJob(job);
    if (_job != job) throw StateError('Maintenance session changed.');
    final p = CanonInkPeer.reply(
      await _exchange('EndJob', 'maintenance', '<ivec:jobID>$job</ivec:jobID>'),
      'EndJobResponse',
      'maintenance',
    );
    if (_text(p, 'jobID') != job) {
      throw StateError('Printer ended a different job.');
    }
    _job = null;
  }

  @override
  Future<String> jobStatus(String job) async {
    _validJob(job);
    final xml = await _exchange(
      'GetStatus',
      'maintenance',
      '<ivec:jobID>$job</ivec:jobID>',
    );
    CanonInkPeer.reply(xml, 'GetStatusResponse', 'maintenance');
    return xml;
  }

  @override
  Future<void> close() => connection.close();
}
