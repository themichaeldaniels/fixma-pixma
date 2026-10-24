import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fixma_pixma/app_info.dart';
import 'package:fixma_pixma/controller.dart';
import 'package:fixma_pixma/core/software_update.dart';
import 'package:fixma_pixma/main.dart';
import 'package:fixma_pixma/platform/open_support.dart';
import 'package:fixma_pixma/software_updates.dart';
import 'package:fixma_pixma/theme.dart';
import 'package:fixma_pixma/update_controller.dart';

Map<String, Object?> release(
  String version, {
  bool? beta,
  bool draft = false,
}) => {
  'tag_name': 'v$version',
  'draft': draft,
  'prerelease': beta ?? version.contains('-'),
  'published_at': '2026-10-23T12:00:00Z',
  'assets': [
    {
      'name': 'FixmaPixma-Windows-$version.zip',
      'state': 'uploaded',
      'size': 100,
    },
  ],
};

class RealHttpOverrides extends HttpOverrides {}

class RoutedClient extends Fake implements HttpClient {
  final HttpClient delegate = RealHttpOverrides().createHttpClient(null);
  final Uri local;
  Uri? requested;
  bool closed = false;
  RoutedClient(this.local);
  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    requested = url;
    return delegate.getUrl(local);
  }

  @override
  void close({bool force = false}) {
    closed = true;
    delegate.close(force: force);
  }
}

void main() {
  late Directory directory;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('fixma-updates-');
  });
  tearDown(() {
    directory.deleteSync(recursive: true);
  });

  test('shared application version matches the package release', () {
    final manifest = File('pubspec.yaml').readAsStringSync();
    expect(
      RegExp(r'^version: ([^+\s]+)', multiLine: true).firstMatch(manifest)![1],
      applicationVersion,
    );
  });

  test('semantic versions compare numeric beta identifiers and ignore build metadata', () {
    final ordered = [
      '0.9.0-alpha',
      '0.9.0-alpha.1',
      '0.9.0-alpha.beta',
      '0.9.0-beta.2',
      '0.9.0-beta.9',
      '0.9.0-beta.10',
      '0.9.0',
      '0.10.0',
      '1.0.0',
    ];
    for (var i = 1; i < ordered.length; i++) {
      expect(
        ReleaseVersion.tryParse(ordered[i])!
            .compareTo(ReleaseVersion.tryParse(ordered[i - 1])!),
        greaterThan(0),
      );
    }
    expect(
      ReleaseVersion.tryParse('v1.0.0+24')!
          .compareTo(ReleaseVersion.tryParse('1.0.0+99')!),
      0,
    );
    expect(
      ReleaseVersion.tryParse('1.0.0-999999999999999999999')!
          .compareTo(ReleaseVersion.tryParse('1.0.0-1000000000000000000000')!),
      lessThan(0),
    );
  });

  test(
    'malformed versions and external browser targets are rejected',
    () async {
      for (final bad in [
        '01.0.0',
        '1.0',
        '1.0.0-beta.01',
        '1.0.0\n',
        '1.0.0/../../issues',
        'https://example.org',
        '1.0.0-',
      ]) {
        expect(ReleaseVersion.tryParse(bad), null, reason: bad);
        expect(() => releasePageUri(bad), throwsFormatException);
      }
      expect(
        () => openSoftwareRelease('file:///private'),
        throwsFormatException,
      );
    },
  );

  test(
    'beta clients find numeric newest release regardless of API ordering',
    () {
      final found = findSoftwareUpdate([
        release('0.9.0-beta.9'),
        release('0.9.0-beta.11'),
        release('0.9.0-beta.10'),
      ], '0.9.0-beta.8');
      expect(found!.tag, 'v0.9.0-beta.11');
      expect(found.page, releasePageUri('v0.9.0-beta.11'));
    },
  );

  test('stable clients exclude beta flags and tags; beta clients can graduate to stable', () {
    expect(
      findSoftwareUpdate([
        release('1.1.0-beta.1'),
        release('1.1.0', beta: true),
        release('1.0.1'),
      ], '1.0.0')!.tag,
      'v1.0.1',
    );
    expect(
      findSoftwareUpdate([
        release('0.9.0-beta.11'),
        release('0.9.0'),
      ], '0.9.0-beta.10')!.tag,
      'v0.9.0',
    );
  });

  test('drafts, older versions, missing assets and incomplete releases are not updates', () {
    final noAsset = release('1.2.0')..['assets'] = [];
    final pending = release('1.3.0')
      ..['assets'] = [
        {'name': 'FixmaPixma-Windows-1.3.0.zip', 'state': 'new', 'size': 0},
      ];
    final unpublished = release('1.4.0')..['published_at'] = null;
    expect(
      findSoftwareUpdate([
        null,
        {},
        release('1.0.0'),
        release('0.9.0'),
        release('2.0.0', draft: true),
        noAsset,
        pending,
        unpublished,
      ], '1.0.0'),
      null,
    );
  });

  test('release URLs are derived from the fixed repository, ignoring supplied links', () {
    final data = release('1.0.1')..['html_url'] = 'https://example.org/unsafe';
    final found = findSoftwareUpdate([data], '1.0.0')!;
    expect(found.page.host, 'github.com');
    expect(found.page.toString(), '$repositoryUrl/releases/tag/v1.0.1');
    expect(found.page.query, isEmpty);
  });

  Future<(SoftwareUpdateService, RoutedClient, HttpServer)> server(
    void Function(HttpRequest) respond, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    host.listen(respond);
    final client = RoutedClient(Uri.parse('http://127.0.0.1:${host.port}/'));
    addTearDown(() async {
      client.close(force: true);
      await host.close(force: true);
    });
    return (
      SoftwareUpdateService(createClient: () => client, timeout: timeout),
      client,
      host,
    );
  }

  test('anonymous bounded GET requests include beta releases and no printer payload', () async {
    late HttpRequest request;
    final (service, client, _) = await server((r) {
      request = r;
      r.response.write(jsonEncode([release('1.0.0-beta.2')]));
      unawaited(r.response.close());
    });
    expect((await service.check('1.0.0-beta.1'))!.tag, 'v1.0.0-beta.2');
    expect(client.requested!.scheme, 'https');
    expect(client.requested!.host, 'api.github.com');
    expect(
      client.requested!.path,
      '/repos${Uri.parse(repositoryUrl).path}/releases',
    );
    expect(client.requested!.queryParameters, {'per_page': '100'});
    expect(request.method, 'GET');
    expect(request.contentLength, anyOf(0, -1));
    expect(request.headers.value(HttpHeaders.authorizationHeader), null);
    expect(
      request.headers.value(HttpHeaders.userAgentHeader),
      'FixmaPixma/1.0.0-beta.1',
    );
    expect(client.closed, true);
  });

  test('stable channel uses latest endpoint and handles no published stable version', () async {
    final (service, client, _) = await server((r) {
      r.response.statusCode = 404;
      unawaited(r.response.close());
    });
    expect(await service.check('1.0.0'), null);
    expect(client.requested!.path.endsWith('/releases/latest'), true);
  });

  test('rate limits return useful errors and close the client', () async {
    final (service, client, _) = await server((r) {
      r.response.statusCode = 429;
      unawaited(r.response.close());
    });
    await expectLater(
      service.check('1.0.0-beta.1'),
      throwsA(
        isA<UpdateCheckException>().having(
          (e) => e.message,
          'message',
          contains('limiting'),
        ),
      ),
    );
    expect(client.closed, true);
  });

  test('redirects never follow external endpoints', () async {
    final (service, client, _) = await server((r) {
      r.response.statusCode = 302;
      r.response.headers.set('location', 'https://example.org/unsafe');
      unawaited(r.response.close());
    });
    await expectLater(
      service.check('1.0.0-beta.1'),
      throwsA(isA<UpdateCheckException>()),
    );
    expect(client.closed, true);
  });

  test('invalid response schema and malformed JSON are failures rather than up-to-date results', () async {
    var payload = '{}';
    final (service, _, _) = await server((r) {
      r.response.write(payload);
      unawaited(r.response.close());
    });
    await expectLater(
      service.check('1.0.0-beta.1'),
      throwsA(isA<UpdateCheckException>()),
    );
    payload = '{broken';
    // Each service check creates and closes a separate HTTP client.
    final (broken, _, _) = await server((r) {
      r.response.write(payload);
      unawaited(r.response.close());
    });
    await expectLater(
      broken.check('1.0.0-beta.1'),
      throwsA(isA<UpdateCheckException>()),
    );
  });

  test('response size limits cover chunked responses', () async {
    final (service, client, _) = await server((r) {
      r.response.headers.chunkedTransferEncoding = true;
      r.response.add(List.filled(4 * 1024 * 1024 + 1, 32));
      unawaited(r.response.close());
    });
    await expectLater(
      service.check('1.0.0-beta.1'),
      throwsA(isA<UpdateCheckException>()),
    );
    expect(client.closed, true);
  });

  test('timeouts close stalled HTTP requests', () async {
    final (service, client, _) = await server(
      (_) {},
      timeout: const Duration(milliseconds: 50),
    );
    await expectLater(
      service.check('1.0.0-beta.1'),
      throwsA(isA<UpdateCheckException>()),
    );
    expect(client.closed, true);
  });

  test(
    'new installations make no update requests and settings persist separately',
    () async {
      var calls = 0;
      final u = UpdateController(
        directory: directory,
        schedule: false,
        fetch: (_) async {
          calls++;
          return null;
        },
      );
      u.initialize();
      await u.checkIfDue();
      expect(calls, 0);
      expect(u.automatic, false);
      final oldSettings = File('${directory.path}/settings.json')
        ..writeAsStringSync('{"theme":"dark"}');
      u.setAutomatic(true);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      expect(oldSettings.readAsStringSync(), '{"theme":"dark"}');
      u.dispose();
      final restored = UpdateController(
        directory: directory,
        schedule: false,
        fetch: (_) async {
          calls++;
          return null;
        },
      );
      addTearDown(restored.dispose);
      restored.initialize();
      await restored.checkIfDue();
      expect(restored.automatic, true);
      expect(calls, 1);
    },
  );

  test('automatic checks are limited to daily attempts, including failures and rollback', () async {
    var clock = DateTime.utc(2026, 10, 23), calls = 0;
    final u = UpdateController(
      directory: directory,
      schedule: false,
      now: () => clock,
      fetch: (_) async {
        calls++;
        throw const UpdateCheckException('Offline');
      },
    );
    addTearDown(u.dispose);
    u.setAutomatic(true);
    await Future<void>.delayed(Duration.zero);
    await u.checkIfDue();
    expect(calls, 1);
    clock = clock.subtract(const Duration(days: 2));
    await u.checkIfDue();
    expect(calls, 1);
    clock = clock.add(const Duration(days: 3));
    await u.checkIfDue();
    expect(calls, 2);
    await u.check();
    expect(calls, 3); // Explicit checks remain available.
  });

  test(
    'concurrent checks share one request and disposal ignores late completion',
    () async {
      var calls = 0;
      final pending = Completer<SoftwareRelease?>();
      final u = UpdateController(
        directory: directory,
        schedule: false,
        fetch: (_) {
          calls++;
          return pending.future;
        },
      );
      var notifications = 0;
      u.addListener(() => notifications++);
      final first = u.check();
      await u.check();
      expect(calls, 1);
      u.dispose();
      final before = notifications;
      pending.complete(
        findSoftwareUpdate([release('1.0.0')], applicationVersion),
      );
      await first;
      expect(notifications, before);
      expect(u.available, null);
    },
  );

  test(
    'damaged or oversized update preferences do not enable network access',
    () async {
      final prefs = File('${directory.path}/updates.json');
      for (final data in [
        '{bad',
        'x' * 9000,
        '[true]',
        '{"automatic":"true"}',
      ]) {
        prefs.writeAsStringSync(data);
        var calls = 0;
        final u = UpdateController(
          directory: directory,
          schedule: false,
          fetch: (_) async {
            calls++;
            return null;
          },
        );
        u.initialize();
        await u.checkIfDue();
        expect(u.automatic, false);
        expect(calls, 0);
        u.dispose();
      }
    },
  );

  test('failed preference writes leave manual checks usable and automatic checks off', () async {
    final blocked = File('${directory.path}/blocked')
      ..writeAsStringSync('keep');
    var calls = 0;
    final u = UpdateController(
      directory: Directory(blocked.path),
      schedule: false,
      fetch: (_) async {
        calls++;
        return null;
      },
    );
    addTearDown(u.dispose);
    u.setAutomatic(true);
    expect(u.automatic, false);
    expect(u.preferenceError, isNotEmpty);
    await u.check();
    expect(calls, 1);
    expect(blocked.readAsStringSync(), 'keep');
  });

  testWidgets(
    'manual checks show results and preserve the existing printer error',
    (tester) async {
      final care = CareController(directory: directory)
        ..lastError = 'Existing printer error';
      final u = UpdateController(
        directory: directory,
        schedule: false,
        fetch: (_) async => null,
      );
      addTearDown(care.dispose);
      addTearDown(u.dispose);
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        FixmaPixma(controller: care, updates: u, nativeFrame: false),
      );
      await tester.tap(find.byTooltip('Check for updates'));
      await tester.pumpAndSettle();
      expect(find.text('No newer Windows release was found.'), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        false,
      );
      expect(care.lastError, 'Existing printer error');
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    'persisted opt-in checks safely during app initialization and can dismiss notice',
    (tester) async {
      File('${directory.path}/updates.json')
          .writeAsStringSync('{"automatic":true}');
      final care = CareController(directory: directory);
      final u = UpdateController(
        directory: directory,
        schedule: false,
        fetch: (_) async =>
            findSoftwareUpdate([release('1.0.0')], applicationVersion),
      );
      addTearDown(care.dispose);
      addTearDown(u.dispose);
      await tester.pumpWidget(
        FixmaPixma(controller: care, updates: u, nativeFrame: false),
      );
      await tester.pumpAndSettle();
      expect(find.text('Fixma Pixma 1.0.0 is available.'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss update notice'));
      await tester.pumpAndSettle();
      expect(find.text('Fixma Pixma 1.0.0 is available.'), findsNothing);
      expect(u.available, isNotNull);
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    'browser failures keep the fixed release link and never duplicate launch',
    (tester) async {
      final u = UpdateController(
        directory: directory,
        schedule: false,
        fetch: (_) async =>
            findSoftwareUpdate([release('1.0.0')], applicationVersion),
      );
      addTearDown(u.dispose);
      await u.check();
      final opening = Completer<void>();
      var opens = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: careTheme(Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showSoftwareUpdates(
                  context,
                  u,
                  check: false,
                  openRelease: (tag) {
                    opens++;
                    expect(tag, 'v1.0.0');
                    return opening.future;
                  },
                ),
                child: const Text('Updates'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Updates'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View release'));
      await tester.pump();
      await tester.tap(find.text('View release'));
      expect(opens, 1);
      opening.completeError(StateError('browser failed'));
      await tester.pumpAndSettle();
      expect(find.text('$repositoryUrl/releases/tag/v1.0.0'), findsOneWidget);
      expect(
        find.textContaining('browser could not be opened'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'offline manual failure is visible and closing during a check is safe',
    (tester) async {
      final pending = Completer<SoftwareRelease?>();
      final u = UpdateController(
        directory: directory,
        schedule: false,
        fetch: (_) => pending.future,
      );
      addTearDown(u.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: careTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showSoftwareUpdates(context, u),
                child: const Text('Updates'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Updates'));
      await tester.pumpAndSettle();
      expect(find.text('Checking GitHub for updates...'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      pending.completeError(const UpdateCheckException('Offline'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), null);
      expect(u.error, 'Offline');
      await tester.tap(find.text('Updates'));
      await tester.pumpAndSettle();
      expect(find.text('Offline'), findsOneWidget);
    },
  );
}
