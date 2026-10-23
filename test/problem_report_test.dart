import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixma_fixa/controller.dart';
import 'package:pixma_fixa/platform/open_support.dart';
import 'package:pixma_fixa/platform/save_diagnostic.dart';
import 'package:pixma_fixa/problem_report.dart';
import 'package:pixma_fixa/theme.dart';

void main() {
  const savedFile = 'C:/Reports/diagnostic.json';
  Future<void> show(
    WidgetTester tester, {
    Future<String?> Function()? save,
    Future<void> Function()? launch,
  }) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: careTheme(Brightness.light),
        home: Scaffold(
          body: ReportProblemButton(
            saveReport: save ?? () async => savedFile,
            openIssue: launch ?? () async {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('Report a problem'));
    await tester.pumpAndSettle();
  }

  Future<void> start(WidgetTester tester) async {
    await tester.tap(find.text('Save report and open issue form'));
    await tester.pumpAndSettle();
  }

  testWidgets('closing instructions does not save or open anything', (
    tester,
  ) async {
    var saves = 0, opens = 0;
    await show(
      tester,
      save: () async {
        saves++;
        return savedFile;
      },
      launch: () async {
        opens++;
      },
    );
    expect(
      find.textContaining('Reviewed diagnostic summary field'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Nothing is attached or submitted automatically'),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(saves, 0);
    expect(opens, 0);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('saves before opening GitHub and keeps the saved path visible', (
    tester,
  ) async {
    final calls = <String>[];
    await show(
      tester,
      save: () async {
        calls.add('save');
        return savedFile;
      },
      launch: () async {
        calls.add('open');
      },
    );
    await start(tester);
    expect(calls, ['save', 'open']);
    expect(find.widgetWithText(SelectableText, savedFile), findsOneWidget);
    expect(find.textContaining('issue form was opened'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    final uri = Uri.parse(supportIssueUrl);
    expect(uri.scheme, 'https');
    expect(uri.host, 'github.com');
    expect(uri.path.endsWith('/pixma-fixa/issues/new'), true);
    expect(uri.queryParameters, {'template': 'model-support.yml'});
  });

  testWidgets(
    'canceling save does not launch GitHub and allows another attempt',
    (tester) async {
      var opens = 0;
      await show(
        tester,
        save: () async => null,
        launch: () async {
          opens++;
        },
      );
      await start(tester);
      expect(opens, 0);
      expect(find.text('Save report and open issue form'), findsOneWidget);
      expect(find.textContaining('report could not be saved'), findsNothing);
    },
  );

  testWidgets('save failure shows the actual error and never opens GitHub', (
    tester,
  ) async {
    var opens = 0;
    await show(
      tester,
      save: () async {
        throw const FileSystemException('Disk is full');
      },
      launch: () async {
        opens++;
      },
    );
    await start(tester);
    expect(opens, 0);
    expect(find.textContaining('Disk is full'), findsOneWidget);
    expect(find.text('Save report and open issue form'), findsOneWidget);
    expect(find.text(supportIssueUrl), findsNothing);
  });

  testWidgets(
    'browser failure retains the saved report and retries without saving again',
    (tester) async {
      var saves = 0, opens = 0;
      await show(
        tester,
        save: () async {
          saves++;
          return savedFile;
        },
        launch: () async {
          opens++;
          if (opens == 1) throw StateError('No browser');
        },
      );
      await start(tester);
      expect(
        find.widgetWithText(SelectableText, supportIssueUrl),
        findsOneWidget,
      );
      expect(find.widgetWithText(SelectableText, savedFile), findsOneWidget);
      await tester.tap(find.text('Open GitHub issue form'));
      await tester.pumpAndSettle();
      expect(saves, 1);
      expect(opens, 2);
      expect(find.textContaining('issue form was opened'), findsOneWidget);
    },
  );

  testWidgets('pending save cannot be dispatched twice or open GitHub early', (
    tester,
  ) async {
    final pending = Completer<String?>();
    var saves = 0, opens = 0;
    await show(
      tester,
      save: () {
        saves++;
        return pending.future;
      },
      launch: () async {
        opens++;
      },
    );
    await tester.tap(find.text('Save report and open issue form'));
    await tester.pump();
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Saving report...'),
    );
    expect(button.onPressed, null);
    expect(saves, 1);
    expect(opens, 0);
    pending.complete(savedFile);
    await tester.pumpAndSettle();
    expect(opens, 1);
  });

  testWidgets('closing during save prevents the subsequent browser launch', (
    tester,
  ) async {
    final pending = Completer<String?>();
    var opens = 0;
    await show(
      tester,
      save: () => pending.future,
      launch: () async {
        opens++;
      },
    );
    await tester.tap(find.text('Save report and open issue form'));
    await tester.pump();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    pending.complete(savedFile);
    await tester.pumpAndSettle();
    expect(opens, 0);
    expect(tester.takeException(), null);
  });

  testWidgets('closing during browser launch safely ignores a late failure', (
    tester,
  ) async {
    final pending = Completer<void>();
    await show(tester, launch: () => pending.future);
    await tester.tap(find.text('Save report and open issue form'));
    await tester.pump();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    pending.completeError(StateError('No browser'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), null);
  });

  test(
    'saved report preserves the error snapshot and uses production redaction',
    () async {
      final temp = Directory.systemTemp.createTempSync('support-save-');
      final c = CareController(directory: temp);
      try {
        c.lastError = 'Connection failed at 192.0.2.5';
        c.busy = true;
        final path = '${temp.path}/diagnostic.json';
        final saved = await saveDiagnosticSummary(
          c,
          choosePath: () {
            c.lastError = 'Later state';
            return path;
          },
        );
        final raw = File(path).readAsStringSync();
        final summary = jsonDecode(raw) as Map;
        expect(saved, path);
        expect(
          summary['currentErrors']['operation'],
          'Connection failed at [address]',
        );
        expect(raw, isNot(contains('192.0.2.5')));
        expect(c.lastError, 'Later state');
        expect(c.busy, true);
        expect(c.history, isEmpty);
      } finally {
        c.dispose();
        temp.deleteSync(recursive: true);
      }
    },
  );

  test(
    'canceling the native path selection writes no diagnostic file',
    () async {
      final temp = Directory.systemTemp.createTempSync('support-cancel-');
      final c = CareController(directory: temp);
      try {
        final before = temp.listSync().map((f) => f.path).toSet();
        expect(await saveDiagnosticSummary(c, choosePath: () => null), null);
        expect(temp.listSync().map((f) => f.path).toSet(), before);
      } finally {
        c.dispose();
        temp.deleteSync(recursive: true);
      }
    },
  );
}
