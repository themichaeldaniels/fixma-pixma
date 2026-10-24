import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_info.dart';

class ReleaseVersion implements Comparable<ReleaseVersion> {
  final List<int> numbers;
  final List<String> prerelease;
  final String text;
  const ReleaseVersion._(this.numbers, this.prerelease, this.text);

  static ReleaseVersion? tryParse(String input) {
    if (input.length > 128) return null;
    final match = RegExp(
      r'^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
    ).firstMatch(input);
    if (match == null || match.end != input.length) return null;
    final pre = match[4]?.split('.') ?? <String>[];
    if (pre.any((p) => RegExp(r'^0[0-9]+$').hasMatch(p))) return null;
    final numbers = [for (var i = 1; i <= 3; i++) int.tryParse(match[i]!)];
    if (numbers.any((v) => v == null)) return null;
    return ReleaseVersion._(
      numbers.cast<int>(),
      pre,
      input.startsWith('v') ? input.substring(1) : input,
    );
  }

  bool get isPrerelease => prerelease.isNotEmpty;
  @override
  int compareTo(ReleaseVersion other) {
    for (var i = 0; i < 3; i++) {
      final c = numbers[i].compareTo(other.numbers[i]);
      if (c != 0) return c;
    }
    if (!isPrerelease || !other.isPrerelease) {
      return isPrerelease == other.isPrerelease
          ? 0
          : isPrerelease
          ? -1
          : 1;
    }
    for (var i = 0; i < prerelease.length && i < other.prerelease.length; i++) {
      final a = prerelease[i], b = other.prerelease[i];
      final an = RegExp(r'^[0-9]+$').hasMatch(a);
      final bn = RegExp(r'^[0-9]+$').hasMatch(b);
      final c = an && bn
          ? (a.length == b.length
                ? a.compareTo(b)
                : a.length.compareTo(b.length))
          : an != bn
          ? an
                ? -1
                : 1
          : a.compareTo(b);
      if (c != 0) return c;
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }
}

Uri releasePageUri(String tag) {
  if (ReleaseVersion.tryParse(tag) == null) {
    throw const FormatException('Invalid release version.');
  }
  return Uri.parse('$repositoryUrl/releases/tag/${Uri.encodeComponent(tag)}');
}

class SoftwareRelease {
  final String tag;
  final ReleaseVersion version;
  const SoftwareRelease._(this.tag, this.version);
  Uri get page => releasePageUri(tag);
}

SoftwareRelease? findSoftwareUpdate(List<dynamic> releases, String installed) {
  final current = ReleaseVersion.tryParse(installed);
  if (current == null) {
    throw const FormatException('Invalid installed version.');
  }
  SoftwareRelease? newest;
  for (final item in releases.take(100)) {
    if (item is! Map ||
        item['draft'] != false ||
        item['published_at'] is! String ||
        DateTime.tryParse(item['published_at']) == null ||
        item['prerelease'] is! bool) {
      continue;
    }
    final tag = item['tag_name'];
    if (tag is! String) continue;
    final version = ReleaseVersion.tryParse(tag);
    if (version == null ||
        version.compareTo(current) <= 0 ||
        (!current.isPrerelease &&
            (version.isPrerelease || item['prerelease'] == true))) {
      continue;
    }
    final assets = item['assets'];
    if (assets is! List ||
        !assets
            .take(100)
            .any(
              (a) =>
                  a is Map &&
                  a['name'] == 'FixmaPixma-Windows-${version.text}.zip' &&
                  a['state'] == 'uploaded' &&
                  a['size'] is int &&
                  a['size'] > 0,
            )) {
      continue;
    }
    if (newest == null || version.compareTo(newest.version) > 0) {
      newest = SoftwareRelease._(tag, version);
    }
  }
  return newest;
}

class UpdateCheckException implements Exception {
  final String message;
  const UpdateCheckException(this.message);
  @override
  String toString() => message;
}

class SoftwareUpdateService {
  final HttpClient Function() createClient;
  final Duration timeout;
  SoftwareUpdateService({
    HttpClient Function()? createClient,
    this.timeout = const Duration(seconds: 12),
  }) : createClient = createClient ?? HttpClient.new;

  Future<SoftwareRelease?> check(String installed) async {
    final current = ReleaseVersion.tryParse(installed);
    if (current == null) {
      throw const UpdateCheckException(
        'The installed version is not recognized.',
      );
    }
    final client = createClient();
    try {
      return await _fetch(
        client,
        installed,
        current.isPrerelease,
      ).timeout(timeout);
    } on UpdateCheckException {
      rethrow;
    } on FormatException {
      throw const UpdateCheckException(
        'The update response was not recognized. Try again later.',
      );
    } catch (_) {
      throw const UpdateCheckException(
        'Could not check for updates. Check your internet connection and try again.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<SoftwareRelease?> _fetch(
    HttpClient client,
    String installed,
    bool beta,
  ) async {
    final uri = Uri.https(
      'api.github.com',
      '/repos${Uri.parse(repositoryUrl).path}/releases${beta ? '' : '/latest'}',
      beta ? {'per_page': '100'} : null,
    );
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    request.headers.set(HttpHeaders.userAgentHeader, 'FixmaPixma/$installed');
    request.headers.set('X-GitHub-Api-Version', '2022-11-28');
    final response = await request.close();
    if (!beta && response.statusCode == 404) return null;
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw const UpdateCheckException(
        'GitHub is limiting update checks. Try again later.',
      );
    }
    if (response.statusCode != 200) {
      throw const UpdateCheckException(
        'GitHub could not provide update information. Try again later.',
      );
    }
    const maximumBytes = 4 * 1024 * 1024;
    if (response.contentLength > maximumBytes) {
      throw const FormatException('Response too large.');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > maximumBytes) {
        throw const FormatException('Response too large.');
      }
      bytes.addAll(chunk);
    }
    final data = jsonDecode(utf8.decode(bytes));
    if ((beta && data is! List) || (!beta && data is! Map)) {
      throw const FormatException('Unexpected release response.');
    }
    return findSoftwareUpdate(beta ? data as List : [data], installed);
  }
}
