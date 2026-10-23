import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixma_fixa/controller.dart';
import 'package:pixma_fixa/core/network_status.dart';
import 'package:pixma_fixa/core/print_queue.dart';
import 'package:pixma_fixa/main.dart';

class QueueCancellationRecorder extends CareController {
  QueueCancellationRecorder({required super.directory});
  final canceled = <int>[];
  @override
  Future<void> cancelJobs(
    QueueSnapshot snapshot,
    List<QueueJob> jobs, {
    required bool confirmed,
  }) async {
    expect(confirmed, true);
    canceled.addAll(jobs.map((job) => job.id));
  }
}

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
    dir = Directory.systemTemp.createTempSync('queue-ui-');
    c = CareController(directory: dir);
    c.selectedPrinter = PrinterTarget.parse('192.168.1.50');
  });
  tearDown(() {
    c.dispose();
    dir.deleteSync(recursive: true);
  });
  Future<void> show(
    WidgetTester t,
    String page, {
    double width = 1200,
    double scale = 1,
  }) async {
    t.view.physicalSize = Size(width, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: PixmaFixa(controller: c, nativeFrame: false),
      ),
    );
    await t.tap(find.text(page));
    await t.pumpAndSettle();
  }

  void queueFixture() {
    const q = WindowsQueue(
      'Canon G7000 series (USB)',
      'USB001',
      'Microsoft IPP Class Driver',
      '',
      576,
    );
    c.localQueues = [q];
    c.selectedQueue = q;
    c.printerJobs = QueueSnapshot(
      sourceKey: c.selectedPrinter!.key,
      label: 'Canon G7000 series',
      identity: 'uuid-test',
      jobs: [],
      cancelSupported: true,
      readAt: DateTime(2026, 10, 20, 12),
    );
    c.windowsJobs = QueueSnapshot(
      sourceKey: q.key,
      label: q.name,
      identity: q.identity,
      cancelSupported: true,
      readAt: DateTime(2026, 10, 20, 12),
      jobs: [
        QueueJob(
          sourceKey: q.key,
          id: 42,
          title: 'Project notes.pdf',
          owner: 'Test user',
          state: 'Paused',
          created: '2026-10-20T12:00:00Z',
          uri: q.key,
          pages: 3,
          printed: 0,
        ),
        QueueJob(
          sourceKey: q.key,
          id: 43,
          title: 'Meeting handout.pdf',
          owner: 'Test user',
          state: 'Waiting',
          created: '2026-10-20T12:01:00Z',
          uri: q.key,
          pages: 2,
          printed: 0,
        ),
      ],
    );
  }

  testWidgets('Unread queue dropdown always has a non-null sentinel', (
    t,
  ) async {
    await show(t, 'Queues');
    expect(
      t
          .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>),
          )
          .initialValue,
      '',
    );
    expect(find.text('Choose a Windows queue'), findsOneWidget);
    expect(t.takeException(), isNull);
    expect(find.text('Scan'), findsNothing);
    expect(find.text('Scan and save…'), findsNothing);
  });
  testWidgets(
    'Cancel listed jobs shows the exact source and jobs before dispatch',
    (t) async {
      queueFixture();
      await show(t, 'Queues');
      await t.tap(find.text('Cancel listed jobs'));
      await t.pumpAndSettle();
      expect(find.text('Cancel 2 listed jobs?'), findsOneWidget);
      expect(find.text('42 · Project notes.pdf'), findsOneWidget);
      expect(find.text('43 · Meeting handout.pdf'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(
            'I understand printer-side cancellation is experimental.',
          ),
        ),
        findsNothing,
      );
      await t.tap(find.text('Keep jobs'));
      await t.pumpAndSettle();
      expect(c.busy, false);
      expect(c.history, isEmpty);
    },
  );
  testWidgets(
    'printer-side cancellation requires a separate experimental acknowledgment',
    (t) async {
      c.dispose();
      final recorder = QueueCancellationRecorder(directory: dir);
      c = recorder;
      c.selectedPrinter = PrinterTarget.parse('192.168.1.50');
      c.printerJobs = QueueSnapshot(
        sourceKey: c.selectedPrinter!.key,
        label: 'Test printer',
        identity: 'uuid-test',
        cancelSupported: true,
        jobs: [
          QueueJob(
            sourceKey: c.selectedPrinter!.key,
            id: 7,
            title: 'Test page',
            owner: 'Test user',
            state: 'processing',
            created: '2026-10-20T12:00:00Z',
            uri: 'ipp://192.168.1.50/ipp/print/7',
          ),
        ],
      );
      await show(t, 'Queues');
      await t.tap(find.text('Cancel job'));
      await t.pumpAndSettle();
      expect(
        t
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Cancel jobs'),
            )
            .onPressed,
        isNull,
      );
      await t.tap(find.text('Keep jobs'));
      await t.pumpAndSettle();
      expect(recorder.canceled, isEmpty);
      await t.tap(find.text('Cancel job'));
      await t.pumpAndSettle();
      await t.tap(
        find.text('I understand printer-side cancellation is experimental.'),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel jobs'));
      await t.pumpAndSettle();
      expect(recorder.canceled, [7]);
    },
  );
  testWidgets('Queue view fits 900px with larger text', (t) async {
    queueFixture();
    await show(t, 'Queues', width: 900, scale: 1.3);
    expect(t.takeException(), isNull);
    for (final field in t.widgetList<DropdownButtonFormField<dynamic>>(
      find.byWidgetPredicate((w) => w is DropdownButtonFormField),
    )) {
      expect(field.initialValue, isNotNull);
    }
  });
  for (final (theme, mode) in [
    ('light', ThemeMode.light),
    ('dark', ThemeMode.dark),
  ]) {
    testWidgets('$theme queues screenshot', (t) async {
      c.themeMode = mode;
      queueFixture();
      await show(t, 'Queues');
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/queues-$theme.png'),
      );
    });
  }
}
