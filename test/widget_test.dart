import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:printer_care/controller.dart';
import 'package:printer_care/core/report.dart';
import 'package:printer_care/core/network_status.dart';
import 'package:printer_care/core/ink_counter.dart';
import 'package:printer_care/core/canon_maintenance.dart';
import 'package:printer_care/main.dart';

class VerifyRecorder extends CareController {
  VerifyRecorder({required super.directory});
  String? verifiedAddress;
  @override
  Future<void> verify(String address) async => verifiedAddress = address;
}

class RefillRecorder extends CareController {
  RefillRecorder({required super.directory});
  Set<String>? resetColors;
  @override
  Future<InkResetCheck?> prepareInkReset() async => InkResetCheck(
    selectedPrinter!,
    const InkIdentity('G7000 series', '1.050', 'TEST12345', {
      'BK',
      'C',
      'M',
      'Y',
    }),
    const InkCounters('idle', '', {'BK': 100, 'C': 30, 'M': 30, 'Y': 30}),
  );
  @override
  Future<void> resetInkCounts(
    InkResetCheck check,
    Set<String> colors, {
    required bool filledToUpperLine,
  }) async {
    expect(filledToUpperLine, true);
    resetColors = colors;
  }
}

class MaintenanceRecorder extends CareController {
  MaintenanceRecorder({required super.directory});
  CanonTask? lastTask;
  String? paper;
  @override
  Future<void> runCanonTask(
    CanonTask task, {
    required bool prepared,
    String paper = letterPaper,
  }) async {
    expect(prepared, true);
    lastTask = task;
    this.paper = paper;
  }
}

void main() {
  setUpAll(() async {
    final font = FontLoader('Source Sans 3');
    for (final weight in ['Regular', 'Semibold', 'Bold']) {
      font.addFont(rootBundle.load('assets/fonts/SourceSans3-$weight.ttf'));
    }
    await font.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  late Directory temp;
  late CareController controller;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('printer-care-ui-');
    controller = CareController(directory: temp);
  });
  tearDown(() {
    controller.dispose();
    temp.deleteSync(recursive: true);
  });
  Future<void> show(
    WidgetTester tester, {
    bool sample = true,
    bool live = false,
    Size size = const Size(1280, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (sample) {
      controller.report = ServiceReport.parse(
        File('assets/sample-report.txt').readAsStringSync(),
        sample: true,
        capturedAt: DateTime(2026, 10, 20, 9, 50),
      );
    }
    if (live) {
      final target = PrinterTarget(
        Uri.parse('ipp://192.168.1.50:631/ipp/print'),
        discoveredName: 'Canon G7000 series',
      );
      final attrs =
          (jsonDecode(
            File('test/fixtures/g7000-ipp.json').readAsStringSync(),
          ) as Map).map(
            (k, v) => MapEntry(k as String, List<Object?>.from(v as List)),
          );
      controller.selectedPrinter = target;
      controller.networkPrinters = [target];
      controller.networkStatus = NetworkStatus(
        target: target,
        attributes: attrs,
        canon: CanonWebStatus(
          supportCode: null,
          signal: 64,
          scanner: true,
          adf: true,
        ),
        capturedAt: DateTime(2026, 10, 20, 12, 0),
      );
    }
    await tester.pumpWidget(
      PrinterCare(controller: controller, nativeFrame: false),
    );
    await tester.pumpAndSettle();
    if (sample) {
      await tester.tap(find.text('Service report'));
      await tester.pumpAndSettle();
    }
  }

  testWidgets(
    'IP field keeps accessibility edits through rebuilds and submits displayed value',
    (tester) async {
      final recorder = VerifyRecorder(directory: temp);
      addTearDown(recorder.dispose);
      await tester.pumpWidget(
        PrinterCare(controller: recorder, nativeFrame: false),
      );
      await tester.tap(find.text('Maintenance'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Waste-ink absorber'));
      await tester.tap(find.text('Waste-ink absorber'));
      await tester.pumpAndSettle();
      final input = tester
          .widget<TextFormField>(find.byType(TextFormField))
          .controller!;
      // Windows accessibility can replace the editing value without onChanged.
      input.text = '192.168.1.50';
      expect(recorder.ip, isEmpty);
      recorder.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        '192.168.1.50',
      );
      await tester.ensureVisible(find.text('Check status'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check status'));
      await tester.pumpAndSettle();
      expect(recorder.verifiedAddress, '192.168.1.50');
    },
  );

  testWidgets('system default follows live Windows brightness changes', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await show(tester);
    expect(controller.themeMode, ThemeMode.system);
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.light,
    );
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.dark,
    );
  });
  testWidgets(
    'appearance menu provides persistent light, dark, and system choices',
    (tester) async {
      await show(tester);
      await tester.tap(find.byTooltip('Appearance'));
      await tester.pumpAndSettle();
      expect(find.text('Follow device'), findsOneWidget);
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      expect(controller.themeMode, ThemeMode.dark);
      expect(
        File('${temp.path}/settings.json').readAsStringSync(),
        contains('dark'),
      );
      expect(
        Theme.of(tester.element(find.byType(Scaffold))).brightness,
        Brightness.dark,
      );
    },
  );
  testWidgets('sample report clearly labeled and reset disabled', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('Sample report'), findsOneWidget);
    expect(find.text('1,854'), findsOneWidget);
    await tester.tap(find.text('Maintenance'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Waste-ink absorber'));
    await tester.tap(find.text('Waste-ink absorber'));
    await tester.pumpAndSettle();
    final reset = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Reset waste counter'),
    );
    expect(reset.onPressed, null);
    expect(find.text('Run a live diagnostic first.'), findsOneWidget);
  });
  testWidgets('empty state is honest and renders at 900px', (tester) async {
    await show(tester, sample: false, size: const Size(900, 760));
    expect(find.text('Find your printer'), findsOneWidget);
    expect(find.text('Not connected'), findsWidgets);
    expect(tester.takeException(), null);
  });
  testWidgets(
    'live overview displays device firmware, ink, and current errors separately',
    (tester) async {
      await show(tester, sample: false, live: true);
      expect(find.text('20%'), findsOneWidget);
      expect(find.text('30%'), findsNWidgets(3));
      expect(find.text('1.050'), findsOneWidget);
      expect(find.text('No current errors reported.'), findsOneWidget);
      final old = controller.networkStatus!;
      controller.networkStatus = NetworkStatus(
        target: old.target,
        attributes: {
          ...old.attributes,
          'printer-state-reasons': ['media-jam-error'],
        },
        capturedAt: old.capturedAt,
      );
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Paper jam'), findsOneWidget);
      expect(find.text('Needs attention'), findsOneWidget);
      expect(find.text('No current errors reported.'), findsNothing);
      controller.networkError = 'Printer is unreachable';
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('Ready'), findsNothing);
      expect(
        find.text('Offline - showing the last reported levels.'),
        findsOneWidget,
      );
    },
  );
  testWidgets('live overview fits minimum window and larger text', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await show(tester, sample: false, live: true, size: const Size(900, 680));
    expect(tester.takeException(), null);
  });
  testWidgets(
    'ink reset dialog requires selected colors and refill confirmation',
    (tester) async {
      controller.dispose();
      final recorder = RefillRecorder(directory: temp);
      controller = recorder;
      await show(tester, sample: false, live: true);
      await tester.tap(find.text('Reset ink counts'));
      await tester.pumpAndSettle();
      expect(find.text('Reset remaining-ink counts'), findsOneWidget);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Black'),
            )
            .onChanged,
        null,
      );
      final action = find.widgetWithText(FilledButton, 'Reset selected counts');
      expect(tester.widget<FilledButton>(action).onPressed, null);
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Cyan'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(action).onPressed, null);
      await tester.tap(
        find.text('The selected tanks are filled to the upper line.'),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(action).onPressed, isNotNull);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(recorder.resetColors, {'C'});
      expect(tester.takeException(), null);
    },
  );
  testWidgets('refill guide explains stale estimates without changing counts', (
    tester,
  ) async {
    await show(tester, sample: false, live: true);
    await tester.ensureVisible(find.text('Recently refilled?'));
    await tester.tap(find.text('Recently refilled?'));
    await tester.pumpAndSettle();
    expect(find.text('After an ink refill'), findsOneWidget);
    expect(find.textContaining('Reset ink lev. count'), findsOneWidget);
    expect(
      find.textContaining('does not send a reset command'),
      findsOneWidget,
    );
    expect(controller.networkStatus!.supplies.first.percent, 20);
    expect(controller.report, isNull);
    expect(controller.resetBlocked, isNotNull);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('20%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'maintenance confirmation requires preparation before one command',
    (tester) async {
      controller.dispose();
      final recorder = MaintenanceRecorder(directory: temp);
      controller = recorder;
      await show(tester, sample: false, live: true, size: const Size(900, 680));
      controller.canonControls = CanonControlCheck(
        controller.selectedPrinter!,
        const InkIdentity('G7000 series', '1.050', 'TEST12345', {
          'BK',
          'C',
          'M',
          'Y',
        }),
        MaintenanceCapabilities.parse(
          File('test/fixtures/g7000-maintenance-capability.xml')
              .readAsStringSync(),
        ),
        CanonSettings.parse(
          File('test/fixtures/g7000-device-settings.xml').readAsStringSync(),
        ),
      );
      await tester.tap(find.text('Maintenance'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), null);
      await tester.tap(find.text('Print nozzle check'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Print check'),
            )
            .onPressed,
        null,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(recorder.lastTask, null);
      await tester.tap(find.text('Print nozzle check'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('The paper and output tray are ready.'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Print check'));
      await tester.pumpAndSettle();
      expect(recorder.lastTask, CanonTask.nozzleCheck);
      await tester.ensureVisible(find.text('Align printhead'));
      await tester.tap(find.text('Align printhead'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Load two sheets'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Start alignment'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(recorder.lastTask, CanonTask.nozzleCheck);
      await tester.tap(find.text('Align printhead'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(
          'Two sheets are loaded, the output tray is open, and the tanks contain enough ink.',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start alignment'));
      await tester.pumpAndSettle();
      expect(recorder.lastTask, CanonTask.automaticAlignment);
      expect(recorder.paper, letterPaper);
      await tester.ensureVisible(find.text('Clean printhead'));
      await tester.tap(find.text('Clean printhead'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Start cleaning'),
            )
            .onPressed,
        null,
      );
      expect(
        find.text('I checked that the tanks contain enough ink.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(recorder.lastTask, CanonTask.automaticAlignment);
    },
  );

  testWidgets(
    'unread Canon settings do not create dropdowns with null values',
    (tester) async {
      await show(tester, sample: false, live: true);
      await tester.tap(find.text('Maintenance'));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.text('Read printer controls'), findsOneWidget);
      expect(tester.takeException(), null);
    },
  );
  testWidgets(
    'scheduled quiet mode is preserved as a non-null current choice',
    (tester) async {
      await show(tester, sample: false, live: true);
      controller.canonControls = CanonControlCheck(
        controller.selectedPrinter!,
        const InkIdentity('G7000 series', '1.050', 'TEST12345', {
          'BK',
          'C',
          'M',
          'Y',
        }),
        MaintenanceCapabilities.parse(
          File('test/fixtures/g7000-maintenance-capability.xml')
              .readAsStringSync(),
        ),
        CanonSettings({
          ...CanonSettings.parse(
            File('test/fixtures/g7000-device-settings.xml').readAsStringSync(),
          ).values,
          'quiet': 'time',
        }),
      );
      await tester.tap(find.text('Maintenance'));
      await tester.pumpAndSettle();
      expect(find.text('Scheduled on printer'), findsWidgets);
      expect(tester.takeException(), null);
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byType(DropdownButton<String>).first,
            )
            .value,
        'time',
      );
    },
  );

  testWidgets('compact report remains aligned at minimum window width', (
    tester,
  ) async {
    await show(tester, size: const Size(900, 680));
    expect(tester.takeException(), null);
    await tester.tap(find.text('Maintenance'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), null);
  });
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('${mode.name} maintenance screenshot', (tester) async {
      controller.themeMode = mode;
      await show(tester);
      await tester.tap(find.text('Maintenance'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), null);
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/maintenance-${mode.name}.png'),
      );
    });
    testWidgets('${mode.name} service report screenshot', (tester) async {
      controller.themeMode = mode;
      await show(tester);
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/service-${mode.name}.png'),
      );
    });
    testWidgets('${mode.name} live overview screenshot', (tester) async {
      controller.themeMode = mode;
      await show(tester, sample: false, live: true);
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/overview-${mode.name}.png'),
      );
    });
  }
}
