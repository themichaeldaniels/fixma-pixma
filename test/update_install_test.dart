import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fixma_pixma/app_info.dart';
import 'package:fixma_pixma/controller.dart';
import 'package:fixma_pixma/core/software_update.dart';
import 'package:fixma_pixma/core/update_package.dart';
import 'package:fixma_pixma/platform/install_update.dart';
import 'package:fixma_pixma/software_updates.dart';
import 'package:fixma_pixma/theme.dart';
import 'package:fixma_pixma/update_controller.dart';

const testVersion = '1.0.0-beta.1';
List<int> packageBytes({List<ArchiveFile> extra = const [], String? omit}) {
  final archive = Archive();
  for (final name in requiredUpdateFiles) {
    if (name == omit) continue;
    final content = name.endsWith('.exe') || name.endsWith('.dll')
        ? [0x4d, 0x5a, 1, 2]
        : utf8.encode('package data');
    archive.add(
      ArchiveFile(
        'FixmaPixma-Windows-$testVersion/$name',
        content.length,
        content,
      ),
    );
  }
  archive.add(
    ArchiveFile(
      'FixmaPixma-Windows-$testVersion/native_assets.json',
      2,
      utf8.encode('{}'),
    ),
  );
  for (final entry in extra) {
    archive.add(entry);
  }
  return ZipEncoder().encode(archive);
}

SoftwareRelease candidate(List<int> bytes, {String? digest, int? size}) =>
    findSoftwareUpdate([
      {
        'tag_name': 'v$testVersion',
        'draft': false,
        'prerelease': true,
        'published_at': '2026-10-24T12:00:00Z',
        'assets': [
          {
            'name': 'FixmaPixma-Windows-$testVersion.zip',
            'state': 'uploaded',
            'size': size ?? bytes.length,
            'digest': 'sha256:${digest ?? sha256.convert(bytes)}',
          },
        ],
      },
    ], applicationVersion)!;

class ActualHttp extends HttpOverrides {}

class DownloadClient extends Fake implements HttpClient {
  final delegate = ActualHttp().createHttpClient(null);
  final Uri local;
  final requests = <Uri>[];
  bool closed = false;
  DownloadClient(this.local);
  @override
  Future<HttpClientRequest> getUrl(Uri uri) {
    requests.add(uri);
    return delegate.getUrl(local);
  }

  @override
  void close({bool force = false}) {
    closed = true;
    delegate.close(force: force);
  }
}

class FakePackages extends UpdatePackageManager {
  final Future<PreparedUpdate> Function(UpdateCancellation) prepare;
  FakePackages(super.state, this.prepare);
  @override
  Future<PreparedUpdate> download(
    SoftwareRelease r,
    UpdateCancellation c,
    void Function(int, int) progress,
  ) => prepare(c);
}

void main() {
  late Directory directory;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('fixma-install-');
  });
  tearDown(() {
    directory.deleteSync(recursive: true);
  });
  File saveZip(List<int> bytes) =>
      File('${directory.path}/package.zip')..writeAsBytesSync(bytes);

  test(
    'valid complete package is extracted to a new folder and all hashes verify',
    () async {
      final output = Directory('${directory.path}/staged');
      extractUpdatePackage(
        saveZip(packageBytes()).path,
        output.path,
        testVersion,
      );
      await verifyInstalledFolder(output, testVersion);
      expect(File('${output.path}/install.json').existsSync(), true);
      expect(File('${output.path}/fixma_pixma_updater.exe').existsSync(), true);
    },
  );
  test(
    'release selection uses the validated uploaded asset when names repeat',
    () {
      final result = findSoftwareUpdate([
        {
          'tag_name': 'v$testVersion',
          'draft': false,
          'prerelease': true,
          'published_at': '2026-10-24T00:00:00Z',
          'assets': [
            {
              'name': 'FixmaPixma-Windows-$testVersion.zip',
              'state': 'new',
              'size': 'invalid',
            },
            {
              'name': 'FixmaPixma-Windows-$testVersion.zip',
              'state': 'uploaded',
              'size': 123,
              'digest': 'sha256:${'a' * 64}',
            },
          ],
        },
      ], applicationVersion);
      expect(result?.packageSize, 123);
      expect(result?.canDownload, true);
    },
  );
  test('a fresh check discards a prepared version when the available release changes', () async {
    final release = candidate(packageBytes());
    final u = UpdateController(
      directory: directory,
      schedule: false,
      fetch: (_) async => null,
    );
    addTearDown(u.dispose);
    u.available = release;
    u.prepared = PreparedUpdate(release, directory, 'a' * 32);
    await u.check();
    expect(u.prepared, null);
    expect(u.available, null);
  });
  test('file hashing matches the independent SHA-256 test vector', () async {
    final file = File('${directory.path}/abc')..writeAsStringSync('abc');
    expect(
      await fileSha256(file),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });
  test('unsafe Windows paths and alternate data streams are rejected', () {
    for (final path in [
      '../escape',
      '/absolute',
      r'C:\outside',
      r'\\server\share',
      'x/../y',
      'x//y',
      'data/file:stream',
      'data/NUL.txt',
      'data/COM1',
      'data/trailing.',
      'data/trailing ',
      'data/a\u0000b',
    ]) {
      expect(() => safePackagePath(path), throwsFormatException, reason: path);
    }
  });
  test('traversal, extra roots and unexpected executables cannot escape extraction', () {
    final sentinel = File('${directory.path}/sentinel')
      ..writeAsStringSync('keep');
    for (final path in [
      '../sentinel',
      'Other/sentinel',
      'FixmaPixma-Windows-$testVersion/evil.exe',
    ]) {
      final bytes = packageBytes(
        extra: [
          ArchiveFile(path, 1, [1]),
        ],
      );
      expect(
        () => extractUpdatePackage(
          saveZip(bytes).path,
          '${directory.path}/out',
          testVersion,
        ),
        throwsFormatException,
      );
      expect(Directory('${directory.path}/out').existsSync(), false);
      expect(sentinel.readAsStringSync(), 'keep');
    }
  });
  test(
    'case collisions and symlink entries are rejected before extraction',
    () {
      final collision = packageBytes(
        extra: [
          ArchiveFile('FixmaPixma-Windows-$testVersion/FIXMA_PIXMA.EXE', 2, [
            1,
            2,
          ]),
        ],
      );
      expect(
        () => extractUpdatePackage(
          saveZip(collision).path,
          '${directory.path}/collision',
          testVersion,
        ),
        throwsFormatException,
      );
      final link =
          ArchiveFile('FixmaPixma-Windows-$testVersion/data/link', 4, [
              1,
              2,
              3,
              4,
            ])
            ..mode = 0xa1ff
            ..symbolicLink = '../outside';
      expect(
        () => extractUpdatePackage(
          saveZip(packageBytes(extra: [link])).path,
          '${directory.path}/linked',
          testVersion,
        ),
        throwsFormatException,
      );
      expect(Directory('${directory.path}/linked').existsSync(), false);
    },
  );
  test(
    'missing helpers and existing destinations are refused without overwrite',
    () {
      expect(
        () => extractUpdatePackage(
          saveZip(packageBytes(omit: 'fixma_pixma_updater.exe')).path,
          '${directory.path}/missing',
          testVersion,
        ),
        throwsFormatException,
      );
      final existing = Directory('${directory.path}/existing')..createSync();
      final keep = File('${existing.path}/keep')..writeAsStringSync('keep');
      expect(
        () => extractUpdatePackage(
          saveZip(packageBytes()).path,
          existing.path,
          testVersion,
        ),
        throwsFormatException,
      );
      expect(keep.readAsStringSync(), 'keep');
    },
  );
  test('oversized entry count is rejected before directory decoding', () {
    final bytes = packageBytes();
    final offset = bytes.length - 22;
    bytes[offset + 8] = 0xff;
    bytes[offset + 9] = 0x7f;
    bytes[offset + 10] = 0xff;
    bytes[offset + 11] = 0x7f;
    expect(
      () => extractUpdatePackage(
        saveZip(bytes).path,
        '${directory.path}/oversized',
        testVersion,
      ),
      throwsFormatException,
    );
  });
  test(
    'modified installed data and wrong manifest versions fail verification',
    () async {
      final output = Directory('${directory.path}/staged');
      extractUpdatePackage(
        saveZip(packageBytes()).path,
        output.path,
        testVersion,
      );
      await expectLater(
        verifyInstalledFolder(output, '2.0.0'),
        throwsFormatException,
      );
      File('${output.path}/data/app.so').writeAsStringSync('tampered');
      await expectLater(
        verifyInstalledFolder(output, testVersion),
        throwsFormatException,
      );
    },
  );
  test(
    'download addresses reject HTTP, credentials, external hosts and fragments',
    () {
      for (final url in [
        'http://github.com/file',
        'https://github.com.evil.example/a',
        'https://user:pass@github.com/file',
        'https://github.com:444/file',
        'https://github.com/file#x',
      ]) {
        expect(trustedUpdateDownloadUri(Uri.parse(url)), false);
      }
      expect(
        trustedUpdateDownloadUri(
          Uri.parse(
            'https://release-assets.githubusercontent.com/file?token=sample',
          ),
        ),
        true,
      );
    },
  );

  Future<(UpdatePackageManager, DownloadClient)> network(
    void Function(HttpRequest) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handler);
    final client = DownloadClient(
      Uri.parse('http://127.0.0.1:${server.port}/'),
    );
    addTearDown(() async {
      client.close(force: true);
      await server.close(force: true);
    });
    return (
      UpdatePackageManager(directory, createClient: () => client),
      client,
    );
  }

  test('download follows the GitHub CDN, checks digest and prepares a complete package', () async {
    final bytes = packageBytes();
    var requests = 0;
    final (manager, client) = await network((r) {
      requests++;
      expect(r.method, 'GET');
      expect(r.headers.value(HttpHeaders.authorizationHeader), null);
      if (requests == 1) {
        r.response.statusCode = 302;
        r.response.headers.set(
          'location',
          'https://release-assets.githubusercontent.com/file?token=sample',
        );
      } else {
        r.response.add(bytes);
      }
      unawaited(r.response.close());
    });
    var received = 0;
    final prepared = await manager.download(
      candidate(bytes),
      UpdateCancellation(),
      (done, total) {
        received = done;
        expect(done, lessThanOrEqualTo(total));
      },
    );
    expect(received, bytes.length);
    expect(requests, 2);
    expect(client.closed, true);
    await verifyInstalledFolder(prepared.application, testVersion);
    expect(
      File('${directory.path}/application/current.json').existsSync(),
      false,
    );
  });
  test('external redirects are refused before another request', () async {
    final (manager, client) = await network((r) {
      r.response.statusCode = 302;
      r.response.headers.set('location', 'https://example.org/package');
      unawaited(r.response.close());
    });
    await expectLater(
      manager.download(
        candidate(packageBytes()),
        UpdateCancellation(),
        (_, _) {},
      ),
      throwsA(isA<UpdateCheckException>()),
    );
    expect(client.requests.length, 1);
  });
  test(
    'corrupt hashes and truncated downloads never select an application',
    () async {
      final history = File('${directory.path}/history.json')
        ..writeAsStringSync('keep');
      final bytes = packageBytes();
      final (manager, _) = await network((r) {
        r.response.add(bytes);
        unawaited(r.response.close());
      });
      await expectLater(
        manager.download(
          candidate(bytes, digest: '0' * 64),
          UpdateCancellation(),
          (_, _) {},
        ),
        throwsA(
          isA<UpdateCheckException>().having(
            (e) => e.message,
            'message',
            contains('SHA-256'),
          ),
        ),
      );
      final (short, _) = await network((r) {
        r.response.add(bytes.take(20).toList());
        unawaited(r.response.close());
      });
      await expectLater(
        short.download(candidate(bytes), UpdateCancellation(), (_, _) {}),
        throwsA(isA<UpdateCheckException>()),
      );
      expect(
        File('${directory.path}/application/current.json').existsSync(),
        false,
      );
      expect(history.readAsStringSync(), 'keep');
    },
  );
  test(
    'canceling a transfer prevents installation and closes the connection',
    () async {
      final bytes = packageBytes();
      final (manager, client) = await network((r) {
        r.response.add(bytes);
        unawaited(r.response.close());
      });
      final cancel = UpdateCancellation();
      await expectLater(
        manager.download(candidate(bytes), cancel, (_, _) => cancel.cancel()),
        throwsA(isA<UpdateCancelled>()),
      );
      expect(client.closed, true);
      expect(
        File('${directory.path}/application/current.json').existsSync(),
        false,
      );
    },
  );
  test(
    'absent or oversized download metadata keeps the release-page fallback',
    () {
      final release = candidate(packageBytes(), digest: 'bad');
      expect(release.canDownload, false);
      expect(
        candidate(packageBytes(), size: 300 * 1024 * 1024).canDownload,
        false,
      );
      expect(release.page.host, 'github.com');
    },
  );
  test('an active printer action and another instance block installation reservation', () {
    final care = CareController(directory: directory);
    addTearDown(care.dispose);
    care.busy = true;
    expect(care.reserveSoftwareUpdate, throwsStateError);
    care.busy = false;
    final lease = care.reserveSoftwareUpdate();
    expect(care.busy, true);
    final other = CareController(directory: directory);
    addTearDown(other.dispose);
    expect(other.reserveSoftwareUpdate, throwsStateError);
    care.releaseSoftwareUpdate(lease);
    expect(care.busy, false);
    expect(Directory('${directory.path}/history').existsSync(), false);
  });
  test(
    'startup acknowledgment is bound to a nonce, version and exact application',
    () async {
      const token = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final session = updateSession(directory, token)
        ..createSync(recursive: true);
      final app = updateApplication(directory, token)
        ..createSync(recursive: true);
      final executable = File('${app.path}/fixma_pixma.exe')
        ..writeAsStringSync('MZ');
      writeUpdateJson(File('${session.path}/plan.json'), {
        'schemaVersion': 1,
        'token': token,
        'applicationToken': token,
        'version': testVersion,
        'previousVersion': applicationVersion,
        'parentPid': pid,
        'parentExe': executable.path,
      });
      await expectLater(
        acknowledgeUpdateStartup(
          directory,
          ['--update-ready=$token'],
          version: '2.0.0',
          executable: executable.path,
        ),
        throwsFormatException,
      );
      expect(File('${session.path}/app-ready.json').existsSync(), false);
      await acknowledgeUpdateStartup(
        directory,
        ['--update-ready=$token'],
        version: testVersion,
        executable: executable.path,
      );
      expect(
        readUpdateJson(File('${session.path}/app-ready.json'))['pid'],
        pid,
      );
      await expectLater(
        acknowledgeUpdateStartup(directory, ['--update-ready=../../escape']),
        throwsFormatException,
      );
    },
  );
  test(
    'forwarding ignores proof modes and never downgrades to an older pointer',
    () async {
      final app = Directory('${directory.path}/application')..createSync();
      writeUpdateJson(File('${app.path}/current.json'), {
        'version': '0.1.0',
        'token': 'a' * 32,
      });
      expect(
        await forwardInstalledUpdate(directory, applicationVersion, []),
        false,
      );
      expect(
        await forwardInstalledUpdate(directory, applicationVersion, [
          '--smoke-output=proof',
        ]),
        false,
      );
    },
  );
  test('controller keeps downloads separate from printer data and rechecks idle before installation', () async {
    final release = candidate(packageBytes());
    var idle = false, installs = 0;
    final prepared = PreparedUpdate(release, directory, 'a' * 32);
    final u = UpdateController(
      directory: directory,
      schedule: false,
      printerIdle: () => idle,
      installHandler: (_) async {
        installs++;
      },
      packages: FakePackages(directory, (_) async => prepared),
    );
    addTearDown(u.dispose);
    u.available = release;
    await u.download();
    expect(u.prepared, prepared);
    await u.install();
    expect(installs, 0);
    idle = true;
    await u.install();
    expect(installs, 1);
    expect(Directory('${directory.path}/history').existsSync(), false);
  });
  test('handoff failures preserve the running app and require a new prepared download', () async {
    final release = candidate(packageBytes());
    final u = UpdateController(
      directory: directory,
      schedule: false,
      printerIdle: () => true,
      installHandler: (_) async => throw StateError('cannot start'),
      packages: FakePackages(
        directory,
        (_) async => PreparedUpdate(release, directory, 'a' * 32),
      ),
    );
    addTearDown(u.dispose);
    u.available = release;
    await u.download();
    await u.install();
    expect(u.prepared, null);
    expect(u.error, contains('preserved'));
    expect(u.installing, false);
  });
  test('failed installation outcomes are shown once without leaking raw result messages', () {
    final file = File('${directory.path}/updates/last-result.json')
      ..parent.createSync(recursive: true);
    writeUpdateJson(file, {
      'status': 'failed',
      'token': 'a' * 32,
      'message': 'private input',
    });
    final u = UpdateController(directory: directory, schedule: false);
    u.initialize();
    expect(u.installFailure, true);
    expect(u.error, isNot(contains('private input')));
    u.dispose();
    final next = UpdateController(directory: directory, schedule: false);
    addTearDown(next.dispose);
    next.initialize();
    expect(next.installFailure, false);
  });
  testWidgets(
    'installation needs a verified download, idle printer and final confirmation',
    (tester) async {
      final release = candidate(packageBytes());
      var idle = false, installs = 0;
      final pending = Completer<void>();
      final u = UpdateController(
        directory: directory,
        schedule: false,
        printerIdle: () => idle,
        installHandler: (_) {
          installs++;
          return pending.future;
        },
        packages: FakePackages(
          directory,
          (_) async => PreparedUpdate(release, directory, 'a' * 32),
        ),
      );
      addTearDown(u.dispose);
      u.available = release;
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: careTheme(Brightness.light),
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => showSoftwareUpdates(ctx, u, check: false),
                child: const Text('Updates'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Updates'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download update'));
      await tester.pumpAndSettle();
      expect(find.text('Download verified. Ready to install.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Install and restart'),
            )
            .onPressed,
        null,
      );
      idle = true;
      u.printerStateChanged();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install and restart'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(installs, 0);
      await tester.tap(find.text('Install and restart'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Install and restart').last,
      );
      await tester.pumpAndSettle();
      expect(installs, 1);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Restarting...'),
            )
            .onPressed,
        null,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Software updates'), findsOneWidget);
      pending.completeError(StateError('failed'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('current version and local data were preserved'),
        findsOneWidget,
      );
      expect(tester.takeException(), null);
    },
  );
}
