import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixma_fixa/experimental_reset_dialog.dart';
import 'package:pixma_fixa/theme.dart';

void main() {
  for (final accept in [false, true]) {
    testWidgets(
      'experimental reset requires explicit opt-in; confirm=$accept',
      (tester) async {
        bool? result;
        await tester.pumpWidget(
          MaterialApp(
            theme: careTheme(Brightness.light),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showDialog<bool>(
                      context: context,
                      builder: (_) => const ExperimentalResetDialog(
                        serial: 'TEST-PRINTER',
                        counter: 12.5,
                      ),
                    );
                  },
                  child: const Text('Open reset'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open reset'));
        await tester.pumpAndSettle();
        expect(find.text('Experimental reset'), findsOneWidget);
        expect(find.text(experimentalWasteResetNotice), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Reset counter'),
              )
              .onPressed,
          isNull,
        );
        if (accept) {
          await tester.ensureVisible(
            find.text('I understand this reset is experimental.'),
          );
          await tester.tap(
            find.text('I understand this reset is experimental.'),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Reset counter'));
        } else {
          await tester.tap(find.text('Cancel'));
        }
        await tester.pumpAndSettle();
        expect(result, accept);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
