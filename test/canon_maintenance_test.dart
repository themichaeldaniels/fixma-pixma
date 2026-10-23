import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixma_fixa/core/canon_maintenance.dart';
import 'package:pixma_fixa/core/ink_counter.dart';
import 'package:pixma_fixa/controller.dart';
import 'package:pixma_fixa/core/network_status.dart';

import 'network_controller_test.dart' show TestNetwork;

String fixture(String name) =>
    File('test/fixtures/g7000-$name.xml').readAsStringSync();

class MaintenancePrinter implements CanonMaintenancePeer {
  final Directory folder;
  MaintenancePrinter(this.folder);
  String serial = 'TEST12345', state = 'idle';
  bool loseReply = false,
      otherSettingChanges = false,
      failAlignmentReadback = false;
  bool active = false;
  CanonTask lastTask = CanonTask.cleaning;
  int polls = 0, commands = 0, closed = 0, settingWrites = 0;
  Map<String, String> values = CanonSettings.parse(fixture('device-settings'))
      .values;
  @override
  Future<InkIdentity> identity() async =>
      InkIdentity('G7000 series', '1.050', serial, inkNames.keys.toSet());
  @override
  Future<MaintenanceCapabilities> capabilities() async =>
      MaintenanceCapabilities.parse(fixture('maintenance-capability'));
  @override
  Future<CanonSettings> settings() async {
    if (failAlignmentReadback &&
        active &&
        lastTask == CanonTask.automaticAlignment) {
      throw StateError('Configuration unavailable');
    }
    return CanonSettings(
      {...values},
      alignment: {
        ...CanonSettings.parse(fixture('device-settings')).alignment,
        if (active && lastTask == CanonTask.automaticAlignment) 'G': 2,
      },
    );
  }

  @override
  Future<void> setSetting(String key, String value) async {
    settingWrites++;
    values[key] = value;
    if (otherSettingChanges) values['autoPowerOn'] = 'OFF';
  }

  @override
  Future<InkCounters> read() async => InkCounters(
    active && polls == 0 ? 'processing' : state,
    '',
    {'BK': 100, 'C': 100, 'M': 100, 'Y': 100},
  );
  @override
  Future<String> startJob() async => '12345678';
  @override
  Future<void> execute(CanonTask task, String job, String paper) async {
    final guard = File('${folder.path}/maintenance-$serial.json');
    expect(guard.existsSync(), true);
    expect((jsonDecode(guard.readAsStringSync()) as Map)['job'], job);
    commands++;
    lastTask = task;
    active = true;
    if (loseReply) throw const SocketException('Lost reply');
  }

  @override
  Future<void> endJob(String job) async {}
  @override
  Future<String> jobStatus(String job) async {
    return fixture(
          polls++ == 0
              ? 'maintenance-processing-response'
              : 'maintenance-finished-response',
        )
        .replaceAll(
          '<ivec:maintenance_operation>Cleaning</ivec:maintenance_operation>',
          '<ivec:maintenance_operation>${lastTask.operation}</ivec:maintenance_operation>',
        )
        .replaceAll(
          '<ivec:type>regular</ivec:type>',
          '<ivec:type>${lastTask.type}</ivec:type>',
        );
  }

  @override
  Future<void> close() async {
    closed++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('captured capability enables only supported print patterns and standard cleaning', () {
    final c = MaintenanceCapabilities.parse(fixture('maintenance-capability'));
    expect(c.supports(CanonTask.nozzleCheck, letterPaper), true);
    expect(c.supports(CanonTask.alignmentCheck, a4Paper), true);
    expect(c.supports(CanonTask.nozzleCheck, 'photo'), false);
    expect(c.cleaningGroups, {'all', 'group1', 'group2'});
    final missing = MaintenanceCapabilities.parse(
      fixture('maintenance-capability')
          .replaceAll('inputbin_p2', 'inputbin_p1'),
    );
    expect(missing.supports(CanonTask.nozzleCheck, letterPaper), false);
  });
  test('standard cleaning packet equals the physically tested command', () {
    final generated = LocalCanonMaintenance.command(
      'Cleaning',
      'maintenance',
      LocalCanonMaintenance.taskContent(
        CanonTask.cleaning,
        '12345678',
        letterPaper,
      ),
    );
    expect(generated, fixture('cleaning-request-request'));
    expect(generated, contains('<ivec:inkgroup>all</ivec:inkgroup>'));
    expect(generated, isNot(contains('deep')));
    expect(
      () => LocalCanonMaintenance.taskContent(
        CanonTask.nozzleCheck,
        '</cmd>',
        letterPaper,
      ),
      throwsArgumentError,
    );
    expect(
      () => LocalCanonMaintenance.taskContent(
        CanonTask.nozzleCheck,
        '12345678',
        'photo',
      ),
      throwsArgumentError,
    );
  });
  test('nozzle packet selects one plain sheet from the cassette', () {
    final text = LocalCanonMaintenance.taskContent(
      CanonTask.nozzleCheck,
      '12345678',
      letterPaper,
    );
    expect(text, contains('<ivec:type>nozzle_check</ivec:type>'));
    expect(text, contains('<ivec:inputbin>inputbin_p2</ivec:inputbin>'));
    expect(text, contains(letterPaper));
  });
  test(
    'automatic alignment requires the advertised two-sheet cassette capability',
    () {
      final xml = fixture('maintenance-capability');
      final supported = MaintenanceCapabilities.parse(xml);
      for (final paper in [letterPaper, a4Paper]) {
        expect(supported.supports(CanonTask.automaticAlignment, paper), true);
        expect(supported.paperCounts['auto_registration']?[paper], 2);
      }
      for (final broken in [
        xml.replaceAll('auto_registration', 'other'),
        xml.replaceAll('>2</ivec:papernum>', '>1</ivec:papernum>'),
        xml.replaceAll('inputbin_p2', 'inputbin_p1'),
        xml.replaceAll(RegExp(r'<ivec:papernum[^>]*>2</ivec:papernum>'), ''),
      ]) {
        expect(
          MaintenanceCapabilities.parse(broken)
              .supports(CanonTask.automaticAlignment, letterPaper),
          false,
        );
      }
    },
  );
  test('automatic alignment command selects calibration and allows sufficient completion time', () {
    expect(
      LocalCanonMaintenance.taskContent(
        CanonTask.automaticAlignment,
        '12345678',
        a4Paper,
      ),
      '<ivec:jobID>12345678</ivec:jobID><ivec:type>auto_registration</ivec:type>'
      '<ivec:inputbin>inputbin_p2</ivec:inputbin><ivec:papersize>iso_a4_210x297mm</ivec:papersize><ivec:papertype>stationery</ivec:papertype>',
    );
    expect(CanonTask.automaticAlignment.operation, 'TestPrint');
    expect(CanonTask.automaticAlignment.sheetCount, 2);
    expect(
      CanonTask.automaticAlignment.completionTimeout,
      const Duration(minutes: 10),
    );
    expect(CanonTask.alignmentCheck.sheetCount, 1);
  });
  test('alignment readback preserves zero and signed values, ignoring unknown or invalid items', () {
    final xml = fixture('device-settings');
    final alignment = CanonSettings.parse(xml).alignment;
    expect(alignment.length, 20);
    expect(alignment['A'], 0);
    expect(alignment['G'], 5);
    expect(alignment['H'], -5);
    expect(
      CanonSettings.parse(xml.replaceAll('sign="A">0', 'sign="A">unknown'))
          .alignment
          .containsKey('A'),
      false,
    );
    expect(
      CanonSettings.parse(xml.replaceAll('sign="A">0', 'sign="A">99')).alignment
          .containsKey('A'),
      false,
    );
  });
  test('alignment completion must match auto_registration rather than a check print', () {
    final xml = fixture('maintenance-processing-response')
        .replaceAll('Cleaning', 'TestPrint')
        .replaceAll('regular', 'auto_registration');
    expect(
      MaintenanceJob.parse(
        xml,
        '12345678',
        CanonTask.automaticAlignment,
      ).matched,
      true,
    );
    expect(
      () => MaintenanceJob.parse(xml, '12345678', CanonTask.alignmentCheck),
      throwsStateError,
    );
  });
  test('settings parse named values; settings generator rejects arbitrary commands', () {
    final s = CanonSettings.parse(fixture('device-settings'));
    expect(s.values, {
      'quiet': 'OFF',
      'autoPowerOn': 'ON',
      'autoPowerOff': 'OFF',
      'paperGap': 'auto',
      'dryLevel': '3',
    });
    expect(
      LocalCanonMaintenance.settingContent('autoPowerOff', '30'),
      contains('<ivec:time>30</ivec:time>'),
    );
    expect(
      () => LocalCanonMaintenance.settingContent('firmware', 'erase'),
      throwsArgumentError,
    );
    expect(
      () => LocalCanonMaintenance.settingContent('quiet', '<anything>'),
      throwsArgumentError,
    );
  });
  test('completion requires the matching job, operation and type', () {
    final processing = fixture('maintenance-processing-response');
    final p = MaintenanceJob.parse(processing, '12345678', CanonTask.cleaning);
    expect(p.matched, true);
    expect(p.completed, false);
    expect(p.progress, 'processing');
    expect(
      () => MaintenanceJob.parse(processing, '87654321', CanonTask.cleaning),
      throwsStateError,
    );
    expect(
      () => MaintenanceJob.parse(processing, '12345678', CanonTask.nozzleCheck),
      throwsStateError,
    );
    expect(
      MaintenanceJob.parse(
        fixture('maintenance-finished-response'),
        '12345678',
        CanonTask.cleaning,
      ).absent,
      true,
    );
  });
  group('maintenance controller', () {
    late Directory folder;
    late CareController c;
    late MaintenancePrinter printer;
    late TestNetwork network;
    setUp(() async {
      folder = Directory.systemTemp.createTempSync('canon-maintenance-test-');
      printer = MaintenancePrinter(folder);
      network = TestNetwork();
      c = CareController(
        directory: folder,
        network: network,
        maintenanceFactory: (_) async => printer,
        maintenancePollInterval: Duration.zero,
      );
      await c.initialize(scan: false);
      await c.selectPrinter(network.targets.single);
      await c.loadCanonControls();
    });
    tearDown(() {
      c.dispose();
      folder.deleteSync(recursive: true);
    });
    test('switching printers discards cached maintenance controls', () async {
      expect(c.canonControls, isNotNull);
      await c.selectPrinter(PrinterTarget.parse('192.168.1.51'));
      expect(c.canonControls, null);
      await c.runCanonTask(CanonTask.cleaning, prepared: true);
      expect(printer.commands, 0);
    });
    test(
      'one standard cycle waits for matching busy-to-idle completion',
      () async {
        await c.runCanonTask(CanonTask.cleaning, prepared: true);
        expect(printer.commands, 1);
        expect(c.history.first['verified'], true);
        expect(c.history.first['status'], 'Completed');
        expect(c.history.first['counterClearAttempted'], false);
        expect(
          File('${folder.path}/maintenance-TEST12345.json').existsSync(),
          false,
        );
      },
    );
    test(
      'confirmation, fresh identity and readiness are required before dispatch',
      () async {
        await c.runCanonTask(CanonTask.cleaning, prepared: false);
        expect(printer.commands, 0);
        printer.serial = 'CHANGED';
        await c.runCanonTask(CanonTask.cleaning, prepared: true);
        expect(printer.commands, 0);
        printer.serial = 'TEST12345';
        printer.state = 'processing';
        await c.runCanonTask(CanonTask.cleaning, prepared: true);
        expect(printer.commands, 0);
      },
    );
    test('automatic alignment records before and after adjustments after matching completion', () async {
      await c.runCanonTask(CanonTask.automaticAlignment, prepared: true);
      expect(printer.commands, 1);
      final record = c.history.first;
      expect(record['status'], 'Completed');
      expect(record['verified'], true);
      expect(record['sheetCount'], 2);
      expect(record['alignmentBefore']['G'], 5);
      expect(record['alignmentAfter']['G'], 2);
      expect(c.canonControls!.settings.alignment['G'], 2);
      expect(c.message, contains('finished its adjustment'));
    });
    test('automatic alignment cannot start unprepared or repeat after lost acknowledgment', () async {
      await c.runCanonTask(CanonTask.automaticAlignment, prepared: false);
      expect(printer.commands, 0);
      printer.loseReply = true;
      await c.runCanonTask(CanonTask.automaticAlignment, prepared: true);
      expect(printer.commands, 1);
      printer.active = false;
      printer.loseReply = false;
      await c.runCanonTask(CanonTask.automaticAlignment, prepared: true);
      expect(printer.commands, 1);
      expect(c.lastError, contains('uncertain'));
    });
    test('successful alignment remains completed if optional adjustment readback is unavailable', () async {
      printer.failAlignmentReadback = true;
      await c.runCanonTask(CanonTask.automaticAlignment, prepared: true);
      expect(printer.commands, 1);
      expect(c.history.first['verified'], true);
      expect(c.history.first['status'], 'Completed');
      expect(
        c.history.first['alignmentReadbackError'],
        contains('Configuration unavailable'),
      );
      expect(c.canonControls, isNull);
      expect(c.lastError, isEmpty);
    });
    test('lost acknowledgment is never replayed; durable guard survives new controller', () async {
      printer.loseReply = true;
      await c.runCanonTask(CanonTask.cleaning, prepared: true);
      expect(printer.commands, 1);
      expect(c.history.first['status'], 'Stopped');
      printer.active = false;
      printer.loseReply = false;
      c.dispose();
      c = CareController(
        directory: folder,
        network: network,
        maintenanceFactory: (_) async => printer,
        maintenancePollInterval: Duration.zero,
      );
      await c.initialize(scan: false);
      await c.selectPrinter(network.targets.single);
      await c.loadCanonControls();
      await c.runCanonTask(CanonTask.cleaning, prepared: true);
      expect(printer.commands, 1);
      expect(c.lastError, contains('uncertain'));
    });
    test(
      'selected setting readback and untouched other values are required',
      () async {
        await c.saveCanonSetting('quiet', 'ON');
        expect(printer.settingWrites, 1);
        expect(c.history.first['verified'], true);
        expect(c.canonControls!.settings.values['quiet'], 'ON');
        await c.saveCanonSetting('quiet', 'ON');
        expect(printer.settingWrites, 1);
        printer.otherSettingChanges = true;
        await c.saveCanonSetting('quiet', 'OFF');
        expect(printer.settingWrites, 2);
        expect(c.history.first['status'], 'Stopped');
        expect(c.history.first['verified'], isNot(true));
      },
    );
  });
}
