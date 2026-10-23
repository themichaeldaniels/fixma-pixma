import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixma_fixa/platform/open_support.dart';
import 'package:pixma_fixa/problem_report.dart';
import 'package:pixma_fixa/theme.dart';

void main() {
  Future<void> show(
    WidgetTester tester,
    Future<void> Function() launcher,
  ) async {
    tester.view.physicalSize = const Size(900, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: careTheme(Brightness.light),
        home: Scaffold(body: ReportProblemButton(openIssue: launcher)),
      ),
    );
    await tester.tap(find.text('Report a problem'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'report instructions explain reviewed JSON attachments without opening a browser',
    (tester) async {
      var opens = 0;
      await show(tester, () async {
        opens++;
      });
      expect(find.textContaining('Export diagnostic summary'), findsOneWidget);
      expect(
        find.textContaining('Reviewed diagnostic summary field'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Nothing is attached or submitted automatically'),
        findsOneWidget,
      );
      expect(opens, 0);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(opens, 0);
    },
  );

  testWidgets(
    'opening the issue form is explicit and cannot be dispatched twice while pending',
    (tester) async {
      var opens = 0;
      final pending = Completer<void>();
      await show(tester, () {
        opens++;
        return pending.future;
      });
      await tester.tap(find.text('Open GitHub issue form'));
      await tester.pump();
      expect(find.text('Opening browser...'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Opening browser...'),
      );
      expect(button.onPressed, null);
      expect(opens, 1);
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      final uri = Uri.parse(supportIssueUrl);
      expect(uri.scheme, 'https');
      expect(uri.host, 'github.com');
      expect(uri.path, '/themichaeldaniels/pixma-fixa/issues/new');
      expect(uri.queryParameters, {'template': 'model-support.yml'});
    },
  );

  testWidgets(
    'browser failure keeps instructions and offers a copyable link without retrying',
    (tester) async {
      var opens = 0;
      await show(tester, () async {
        opens++;
        throw StateError('No browser');
      });
      await tester.tap(find.text('Open GitHub issue form'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('browser could not be opened'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(SelectableText, supportIssueUrl),
        findsOneWidget,
      );
      expect(opens, 1);
      expect(tester.takeException(), null);
    },
  );

  testWidgets('closing during browser launch safely ignores a late failure', (
    tester,
  ) async {
    final pending = Completer<void>();
    await show(tester, () => pending.future);
    await tester.tap(find.text('Open GitHub issue form'));
    await tester.pump();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    pending.completeError(StateError('No browser'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), null);
  });
}
