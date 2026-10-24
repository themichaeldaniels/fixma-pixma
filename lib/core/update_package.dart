import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'software_update.dart';

class UpdateCancelled implements Exception {}

class UpdateCancellation {
  bool cancelled = false;
  void Function()? abort;
  void cancel() {
    cancelled = true;
    abort?.call();
  }

  void check() {
    if (cancelled) throw UpdateCancelled();
  }
}

const updateExecutables = {
  'fixma_pixma.exe',
  'fixma_pixma_worker.exe',
  'fixma_pixma_queue.exe',
  'fixma_pixma_updater.exe',
};
const updateRootFiles = {
  ...updateExecutables,
  'flutter_windows.dll',
  'native_assets.json',
  'msvcp140.dll',
  'vcruntime140.dll',
  'vcruntime140_1.dll',
  'README.md',
  'START-HERE.txt',
  'PENDING-WORK.txt',
  'BETA-NOTES.md',
  'TESTING.md',
  'VALIDATION.md',
  'REVIEW.md',
  'SUPPORT.md',
  'LICENSE',
  'THIRD_PARTY_NOTICES.txt',
};
const requiredUpdateFiles = {
  ...updateExecutables,
  'flutter_windows.dll',
  'msvcp140.dll',
  'vcruntime140.dll',
  'vcruntime140_1.dll',
  'data/app.so',
  'data/icudtl.dat',
  'data/flutter_assets/AssetManifest.bin',
};

String newUpdateToken() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
bool validUpdateToken(String token) =>
    RegExp(r'^[0-9a-f]{32}$').hasMatch(token);

String safePackagePath(String name) {
  if (name.startsWith('/') ||
      name.startsWith(r'\') ||
      name.length > 240 ||
      RegExp(r'[<>:"|?*\x00-\x1f]').hasMatch(name)) {
    throw const FormatException('Unsafe update path.');
  }
  final normalized = name.replaceAll(r'\', '/').replaceFirst(RegExp(r'/$'), '');
  final parts = normalized.split('/');
  if (parts.length > 20 ||
      parts.any(
        (p) =>
            p.isEmpty ||
            p == '.' ||
            p == '..' ||
            p.endsWith('.') ||
            p.endsWith(' ') ||
            p.length > 128 ||
            RegExp(
              r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)',
              caseSensitive: false,
            ).hasMatch(p),
      )) {
    throw const FormatException('Unsafe update path.');
  }
  return normalized;
}

/// Only fixed HTTPS release hosts are followed; no credentials are sent.
bool trustedUpdateDownloadUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.userInfo.isEmpty &&
    (!uri.hasPort || uri.port == 443) &&
    uri.fragment.isEmpty &&
    const {
      'github.com',
      'release-assets.githubusercontent.com',
      'objects.githubusercontent.com',
    }.contains(uri.host);

Future<String> fileSha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

class PreparedUpdate {
  final SoftwareRelease release;
  final Directory state;
  final String token;
  const PreparedUpdate(this.release, this.state, this.token);
  Directory get session => Directory('${state.path}/updates/$token');
  Directory get application => Directory('${state.path}/application/$token');
  File get zip => File('${session.path}/package.zip');
}

class UpdatePackageManager {
  final Directory state;
  final HttpClient Function() createClient;
  final Duration timeout;
  UpdatePackageManager(
    this.state, {
    HttpClient Function()? createClient,
    this.timeout = const Duration(minutes: 5),
  }) : createClient = createClient ?? HttpClient.new;

  Future<PreparedUpdate> download(
    SoftwareRelease release,
    UpdateCancellation cancellation,
    void Function(int, int) progress,
  ) async {
    if (!release.canDownload) {
      throw const UpdateCheckException(
        'This release has no verified download. Open its release page instead.',
      );
    }
    final prepared = PreparedUpdate(release, state, newUpdateToken());
    prepared.session.createSync(recursive: true);
    final client = createClient();
    cancellation.abort = () => client.close(force: true);
    try {
      await _download(
        client,
        prepared,
        cancellation,
        progress,
      ).timeout(timeout);
      cancellation.check();
      if (await fileSha256(prepared.zip) != release.packageHash) {
        throw const UpdateCheckException(
          'The download failed its SHA-256 check. It was not installed. Try downloading again.',
        );
      }
      cancellation.check();
      final zipPath = prepared.zip.path, folder = prepared.application.path;
      final version = release.version.text;
      await extractUpdateInBackground(zipPath, folder, version);
      cancellation.check();
      return prepared;
    } catch (e) {
      await discard(prepared);
      if (cancellation.cancelled) throw UpdateCancelled();
      if (e is UpdateCheckException) rethrow;
      throw const UpdateCheckException(
        'The update could not be downloaded or unpacked. Check the connection and available disk space, then try again.',
      );
    } finally {
      cancellation.abort = null;
      client.close(force: true);
    }
  }

  Future<void> _download(
    HttpClient client,
    PreparedUpdate p,
    UpdateCancellation cancel,
    void Function(int, int) progress,
  ) async {
    var uri = p.release.packageUri;
    HttpClientResponse? response;
    for (var redirects = 0; redirects <= 5; redirects++) {
      cancel.check();
      if (!trustedUpdateDownloadUri(uri)) {
        throw const UpdateCheckException(
          'GitHub returned an unsupported download address. Open the release page instead.',
        );
      }
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'FixmaPixma');
      final reply = await request.close();
      if (const {301, 302, 303, 307, 308}.contains(reply.statusCode)) {
        final location = reply.headers.value(HttpHeaders.locationHeader);
        if (location == null || redirects == 5) {
          throw const FormatException('Invalid redirect.');
        }
        uri = uri.resolve(location);
        await reply.drain<void>().timeout(const Duration(seconds: 10));
        continue;
      }
      response = reply;
      break;
    }
    if (response == null || response.statusCode != 200) {
      throw const UpdateCheckException(
        'GitHub could not provide the update package. Try again later.',
      );
    }
    final expected = p.release.packageSize!;
    if (response.contentLength >= 0 && response.contentLength != expected) {
      throw const FormatException('Unexpected download length.');
    }
    final output = await p.zip.open(mode: FileMode.writeOnly);
    var received = 0;
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        cancel.check();
        received += chunk.length;
        if (received > expected) {
          throw const FormatException('Download too large.');
        }
        await output.writeFrom(chunk);
        progress(received, expected);
      }
      if (received != expected) {
        throw const FormatException('Incomplete download.');
      }
      await output.flush();
    } finally {
      await output.close();
    }
  }

  Future<void> discard(PreparedUpdate prepared) async {
    if (prepared.state.absolute.path != state.absolute.path ||
        !validUpdateToken(prepared.token)) {
      return;
    }
    // These exact per-download children are owned by this manager, never printer data.
    for (final folder in [prepared.session, prepared.application]) {
      try {
        if (FileSystemEntity.typeSync(folder.path, followLinks: false) ==
            FileSystemEntityType.directory) {
          await folder.delete(recursive: true);
        }
      } catch (_) {
        /* Failed cleanup does not make an unverified package installable. */
      }
    }
  }
}

void _preflightZip(File file) {
  final length = file.lengthSync();
  if (length < 22 || length > 256 * 1024 * 1024) {
    throw const FormatException('Invalid package size.');
  }
  final input = file.openSync();
  try {
    final start = max(0, length - 65557);
    input.setPositionSync(start);
    final tail = input.readSync(length - start);
    final bytes = ByteData.sublistView(tail);
    for (var i = tail.length - 22; i >= 0; i--) {
      if (bytes.getUint32(i, Endian.little) != 0x06054b50 ||
          i + 22 + bytes.getUint16(i + 20, Endian.little) != tail.length) {
        continue;
      }
      final count = bytes.getUint16(i + 10, Endian.little);
      if (bytes.getUint16(i + 4, Endian.little) != 0 ||
          bytes.getUint16(i + 6, Endian.little) != 0 ||
          count == 0 ||
          count > 5000 ||
          bytes.getUint16(i + 8, Endian.little) != count ||
          bytes.getUint32(i + 12, Endian.little) > 8 * 1024 * 1024 ||
          bytes.getUint32(i + 16, Endian.little) +
                  bytes.getUint32(i + 12, Endian.little) >
              start + i) {
        throw const FormatException('Unsupported archive structure.');
      }
      return;
    }
    throw const FormatException('Invalid ZIP directory.');
  } finally {
    input.closeSync();
  }
}

void extractUpdatePackage(String zipPath, String destination, String version) {
  _preflightZip(File(zipPath));
  final folder = Directory(destination);
  if (FileSystemEntity.typeSync(destination, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw const FormatException('Update destination already exists.');
  }
  final input = InputFileStream(zipPath);
  try {
    final zip = ZipDirectory()..read(input);
    if (zip.fileHeaders.length != zip.totalCentralDirectoryEntries ||
        zip.fileHeaders.length > 5000) {
      throw const FormatException('Incomplete ZIP directory.');
    }
    final root = 'FixmaPixma-Windows-$version';
    final paths = <String>{}, files = <String, ZipFileHeader>{};
    var size = 0;
    for (final h in zip.fileHeaders) {
      final name = safePackagePath(h.filename);
      final type = (h.externalFileAttributes >> 16) & 0xf000;
      if (h.file == null ||
          h.file!.filename != h.filename ||
          (h.generalPurposeBitFlag & 1) != 0 ||
          !const {0, 8}.contains(h.compressionMethod) ||
          !const {0, 0x8000, 0x4000}.contains(type) ||
          (h.externalFileAttributes & 0x400) != 0 ||
          h.uncompressedSize < 0 ||
          h.uncompressedSize > 128 * 1024 * 1024) {
        throw const FormatException('Unsupported ZIP entry.');
      }
      if (!paths.add(name.toLowerCase())) {
        throw const FormatException('Duplicate ZIP path.');
      }
      if (name == root &&
          (h.filename.endsWith('/') || h.filename.endsWith(r'\'))) {
        continue;
      }
      if (!name.startsWith('$root/')) {
        throw const FormatException('Unexpected package root.');
      }
      final relative = name.substring(root.length + 1);
      final directory = h.filename.endsWith('/') || h.filename.endsWith(r'\');
      if (relative != 'data' &&
          !relative.startsWith('data/') &&
          !updateRootFiles.contains(relative)) {
        throw const FormatException('Unexpected package file.');
      }
      if (directory) continue;
      size += h.uncompressedSize;
      if (size > 512 * 1024 * 1024) {
        throw const FormatException('Update expands too far.');
      }
      files[relative] = h;
    }
    if (!requiredUpdateFiles.every(
      (name) => files.containsKey(name) && files[name]!.uncompressedSize > 0,
    )) {
      throw const FormatException(
        'The update is missing required application files.',
      );
    }
    final lowerFiles = files.keys.map((v) => v.toLowerCase()).toSet();
    for (final name in files.keys) {
      final parts = name.split('/');
      for (var i = 1; i < parts.length; i++) {
        if (lowerFiles.contains(parts.take(i).join('/').toLowerCase())) {
          throw const FormatException('File/directory conflict.');
        }
      }
    }
    folder.createSync(recursive: true);
    final manifest = <Map<String, Object>>[];
    for (final entry in files.entries) {
      final target = File('${folder.path}/${entry.key}');
      target.parent.createSync(recursive: true);
      final output = OutputFileStream(target.path);
      try {
        entry.value.file!.decompress(output);
      } finally {
        output.closeSync();
      }
      if (target.lengthSync() != entry.value.uncompressedSize ||
          !entry.value.file!.verifyCrc32()) {
        throw const FormatException('Invalid extracted file.');
      }
      if (entry.key.endsWith('.exe') || entry.key.endsWith('.dll')) {
        final executable = target.openSync();
        try {
          if (executable.readByteSync() != 0x4d ||
              executable.readByteSync() != 0x5a) {
            throw const FormatException('Invalid executable.');
          }
        } finally {
          executable.closeSync();
        }
      }
      manifest.add({
        'path': entry.key,
        'bytes': target.lengthSync(),
        'sha256': sha256.convert(target.readAsBytesSync()).toString(),
      });
    }
    File('${folder.path}/install.json').writeAsStringSync(
      jsonEncode({'schemaVersion': 1, 'version': version, 'files': manifest}),
      flush: true,
    );
  } finally {
    input.closeSync();
  }
}

Future<void> verifyInstalledFolder(Directory folder, String version) async {
  final file = File('${folder.path}/install.json');
  if (file.lengthSync() > 2 * 1024 * 1024) {
    throw const FormatException('Invalid installed manifest.');
  }
  final data = jsonDecode(file.readAsStringSync());
  if (data is! Map ||
      data['schemaVersion'] != 1 ||
      data['version'] != version ||
      data['files'] is! List) {
    throw const FormatException('Invalid installed manifest.');
  }
  final entries = data['files'] as List;
  if (entries.length > 5000) {
    throw const FormatException('Invalid installed manifest.');
  }
  final paths = <String>{};
  var total = 0;
  for (final item in entries) {
    if (item is! Map ||
        item['path'] is! String ||
        item['bytes'] is! int ||
        item['sha256'] is! String) {
      throw const FormatException('Invalid installed entry.');
    }
    final name = safePackagePath(item['path']);
    if ((!name.startsWith('data/') && !updateRootFiles.contains(name)) ||
        !paths.add(name.toLowerCase())) {
      throw const FormatException('Unexpected installed path.');
    }
    final target = File('${folder.path}/$name');
    if (FileSystemEntity.typeSync(target.path, followLinks: false) !=
            FileSystemEntityType.file ||
        target.lengthSync() != item['bytes']) {
      throw const FormatException('Installed file changed.');
    }
    // Canonical paths also reject junctions in parent directories.
    if (!target.resolveSymbolicLinksSync().toLowerCase().startsWith(
      '${folder.resolveSymbolicLinksSync()}${Platform.pathSeparator}'
          .toLowerCase(),
    )) {
      throw const FormatException('Linked installed path.');
    }
    total += target.lengthSync();
    if (total > 512 * 1024 * 1024 ||
        await fileSha256(target) != item['sha256']) {
      throw const FormatException('Installed file changed.');
    }
  }
  if (!requiredUpdateFiles.every(
    (name) => paths.contains(name.toLowerCase()),
  )) {
    throw const FormatException('Incomplete installed application.');
  }
}

// Keep the isolate closure separate from the live HTTP client context.
Future<void> extractUpdateInBackground(
  String zip,
  String folder,
  String version,
) => Isolate.run(() => extractUpdatePackage(zip, folder, version));
