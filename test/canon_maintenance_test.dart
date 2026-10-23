import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:printer_care/core/canon_maintenance.dart';
import 'package:printer_care/core/ink_counter.dart';
import 'package:printer_care/controller.dart';
import 'package:printer_care/core/network_status.dart';

import 'network_controller_test.dart' show TestNetwork;

String fixture(String name) =>
    File('test/fixtures/g7000-$name.xml').readAsStringSync();

class MaintenancePrinter implements CanonMaintenancePeer {
  final Directory folder;
  MaintenancePrinter(this.folder);
  String serial = 'TEST12345', state = 'idle';
  bool loseReply = false, otherSettingChanges = false;
  bool active = false;
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
  Future<CanonSettings> settings() async => CanonSettings({...values});
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
