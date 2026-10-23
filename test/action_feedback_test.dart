import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixma_fixa/action_feedback.dart';
import 'package:pixma_fixa/controller.dart';
import 'package:pixma_fixa/core/network_status.dart';
import 'package:pixma_fixa/main.dart';
import 'package:pixma_fixa/theme.dart';

class DisconnectedPrinter extends CareController {
  DisconnectedPrinter({required super.directory});
  int attempts = 0;

  @override
  Future<void> discover() async {
    attempts++;
  }

  @override
  Future<void> diagnose() async {
    attempts++;
    throw StateError(
      'Put the printer in service mode and connect USB, then try again.',
    );
  }

  @override
  Future<void> refreshNetwork() async {
    attempts++;
    networkError = 'Cannot reach this printer. Connection timed out.';
    notifyListeners();
  }
}

void main() {
  late Directory temp;
  late DisconnectedPrinter controller;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('pixma-fixa-feedback-');
    controller = DisconnectedPrinter(directory: temp);
  });
  tearDown(() {
    controller.dispose();
    temp.deleteSync(recursive: true);
  });
  Future<void> showApp(WidgetTester tester, {int page = 0}) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      PixmaFixa(controller: controller, nativeFrame: false, initialPage: page),
    );
  }

  testWidgets(
    'USB diagnostic failure explains the cable and service-mode requirement once',
    (tester) async {
      await showApp(tester, page: 3);
      await tester.tap(find.text('Run diagnostics'));
      await tester.pumpAndSettle();
      expect(find.text('USB service diagnostics failed'), findsOneWidget);
      expect(find.text(usbServiceRequirement), findsOneWidget);
      expect(controller.attempts, 1);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.attempts, 1);
    },
  );

  testWidgets(
    'normal USB mode is explained after an explicit service-printer search',
    (tester) async {
      controller.devices = [
        {'service': false},
      ];
      await showApp(tester, page: 3);
      await tester.tap(find.text('Find printer'));
      await tester.pumpAndSettle();
      expect(find.text('USB service printer not available'), findsOneWidget);
      expect(
        find.text(
          'A USB printer was found, but its service-mode interface is not available.',
        ),
        findsOneWidget,
      );
      expect(find.text(usbServiceRequirement), findsOneWidget);
      expect(controller.attempts, 1);
    },
  );

  testWidgets(
    'background network errors stay inline; manual refresh shows the returned failure',
    (tester) async {
      controller.selectedPrinter = PrinterTarget.parse('192.0.2.10');
      await showApp(tester);
      controller.networkError = 'Cannot reach this printer.';
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text('Refresh now'));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not connect to the network printer'),
        findsOneWidget,
      );
      expect(find.text(networkRequirement), findsOneWidget);
      expect(
        find.text('Cannot reach this printer. Connection timed out.'),
        findsWidgets,
      );
      expect(controller.attempts, 1);
    },
  );

  testWidgets(
    'mutation failure warns about uncertain delivery and never retries',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: careTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => printerAction(
                  context,
                  title: 'Reset did not complete',
                  action: () async {
                    attempts++;
                    throw TimeoutException('Acknowledgment not received.');
                  },
                  error: () => '',
                  help: usbServiceRequirement,
                  mayHaveSentCommand: true,
                ),
                child: const Text('Attempt'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Attempt'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('does not prove the printer ignored'),
        findsOneWidget,
      );
      expect(attempts, 1);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(attempts, 1);
    },
  );

  testWidgets(
    'an action that finishes after its screen is removed does not open a dialog',
    (tester) async {
      final completion = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => printerAction(
                  context,
                  title: 'Failure',
                  action: () => completion.future,
                  error: () => 'Disconnected',
                  help: networkRequirement,
                ),
                child: const Text('Start'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Start'));
      await tester.pumpWidget(const SizedBox());
      completion.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
