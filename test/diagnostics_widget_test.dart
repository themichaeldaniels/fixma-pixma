import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixma_fixa/controller.dart';
import 'package:pixma_fixa/core/model_support.dart';
import 'package:pixma_fixa/core/repair_record.dart';
import 'package:pixma_fixa/core/report.dart';
import 'package:pixma_fixa/main.dart';

void main() {
  late Directory dir;
  late CareController c;
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
  setUp(() {
    dir = Directory.systemTemp.createTempSync('care-diagnostic-ui-');
    c = CareController(directory: dir);
    c.connectionCheckedAt = DateTime(2026, 10, 20, 10, 15);
    c.connectionChecks = const [
      ConnectionCheck(
        'Local network',
        'Busy',
        'Canon G7000 series · firmware 1.050',
        attention: true,
      ),
      ConnectionCheck(
        'Printer queue',
        '0 visible jobs',
        'An empty queue does not clear a device-level Busy state.',
      ),
    ];
    c.repairs = [
      RepairRecord(
          id: 'repair-123',
          serial: 'DEMO-PRINTER',
          model: 'G7000 series',
          firmware: '1.050',
          createdAt: DateTime(2026, 10, 20, 9, 50),
          beforeCounter: 100,
        )
        ..acknowledged = true
        ..afterCounter = 0,
    ];
    final raw = File('assets/sample-report.txt').readAsStringSync();
    c.importedReports = [
      ServiceReport.parse(
        raw.replaceFirst('D=000.0', 'D=100.0'),
        sample: true,
        capturedAt: DateTime(2026, 10, 19, 9),
      ),
      ServiceReport.parse(
        raw,
        sample: true,
        capturedAt: DateTime(2026, 10, 20, 10),
      ),
    ];
  });
  tearDown(() {
    c.dispose();
    dir.deleteSync(recursive: true);
  });
  Future<void> show(
    WidgetTester t, {
    double width = 1280,
    double scale = 1,
  }) async {
    t.view.physicalSize = Size(width, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      PixmaFixa(controller: c, nativeFrame: false, initialPage: 6),
    );
    await t.pumpAndSettle();
    // System accessibility text scaling, while keeping this test's window size.
    if (scale != 1) {
      t.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      await t.pumpAndSettle();
    }
  }

  testWidgets('service guide fits a small window with larger text', (t) async {
    await show(t, width: 900, scale: 1.4);
    await t.tap(find.text('G7020 service mode guide'));
    await t.pumpAndSettle();
    expect(t.widget<AlertDialog>(find.byType(AlertDialog)).scrollable, true);
    expect(
      find.textContaining('press and release Stop six times'),
      findsOneWidget,
    );
    expect(find.textContaining('green power LED'), findsOneWidget);
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(t.takeException(), null);
  });

  testWidgets(
    'repair confirmation is explicit and persists while status remains pending',
    (t) async {
      await show(t);
      await t.tap(find.text('Repair follow-ups'));
      await t.pumpAndSettle();
      await t.tap(find.text('I restarted with Power'));
      await t.pumpAndSettle();
      expect(c.repairs.single.restartConfirmed, false);
      await t.tap(find.text('Restart completed'));
      await t.pumpAndSettle();
      expect(c.repairs.single.stage, 'Status check pending');
      expect(c.repairs.single.verified, false);
      expect(find.text('Read status after restart'), findsOneWidget);
      expect(t.takeException(), null);
    },
  );
  testWidgets('comparison dropdowns select reports and render actual deltas', (
    t,
  ) async {
    await show(t);
    await t.tap(find.text('Compare reports'));
    await t.pumpAndSettle();
    final fields = find.byType(DropdownButtonFormField<String>);
    await t.tap(fields.at(0));
    await t.pumpAndSettle();
    await t.tap(find.textContaining('10/19/2026').last);
    await t.pumpAndSettle();
    await t.tap(fields.at(1));
    await t.pumpAndSettle();
    await t.tap(find.textContaining('10/20/2026').last);
    await t.pumpAndSettle();
    expect(find.text('-100.0 points'), findsOneWidget);
    expect(c.liveValid, false);
    expect(t.takeException(), null);
  });
  testWidgets(
    'narrow layout and enlarged text keep all diagnostics accessible',
    (t) async {
      await show(t, width: 760, scale: 1.4);
      for (final tab in [
        'Repair follow-ups',
        'Compare reports',
        'Model support',
      ]) {
        await t.tap(find.text(tab));
        await t.pumpAndSettle();
        expect(t.takeException(), null);
      }
    },
  );
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('diagnostic pages ${mode.name} visual check', (t) async {
      c.themeMode = mode;
      await show(t);
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/diagnostics-${mode.name}.png'),
      );
      await t.tap(find.text('Repair follow-ups'));
      await t.pumpAndSettle();
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/repairs-${mode.name}.png'),
      );
    });
  }
}
