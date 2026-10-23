import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'ipp_message.dart';
import 'network_status.dart';

class QueueJob {
  final String sourceKey, title, owner, state, created, uri, token;
  final int id;
  final int? pages, printed;
  final bool active;
  const QueueJob({
    required this.sourceKey,
    required this.id,
    required this.title,
    required this.owner,
    required this.state,
    required this.created,
    this.uri = '',
    this.token = '',
    this.pages,
    this.printed,
    this.active = true,
  });
  bool get identifiable =>
      id > 0 && (token.isNotEmpty || (created.isNotEmpty && uri.isNotEmpty));
  String get fingerprint =>
      jsonEncode([sourceKey, id, token, uri, created, title, owner]);
  Map<String, dynamic> toJson() => {
    'sourceKey': sourceKey,
    'id': id,
    'title': title,
    'owner': owner,
    'state': state,
    'created': created,
    'uri': uri,
    'token': token,
    'pages': pages,
    'printed': printed,
    'active': active,
  };
  factory QueueJob.fromJson(Map v) => QueueJob(
    sourceKey: v['sourceKey'] as String,
    id: v['id'] as int,
    title: v['title'] as String,
    owner: v['owner'] as String,
    state: v['state'] as String,
    created: v['created'] as String,
    uri: v['uri'] as String? ?? '',
    token: v['token'] as String? ?? '',
    pages: v['pages'] as int?,
    printed: v['printed'] as int?,
    active: v['active'] == true,
  );
}

class WindowsQueue {
  final String name, port, driver, server;
  final int attributes;
  const WindowsQueue(
    this.name,
    this.port,
    this.driver,
    this.server,
    this.attributes,
  );
  String get key => 'windows:$name';
  String get identity => jsonEncode([name, port, driver, server, attributes]);
  Map<String, dynamic> toJson() => {
    'name': name,
    'port': port,
    'driver': driver,
    'server': server,
    'attributes': attributes,
  };
  factory WindowsQueue.fromJson(Map v) => WindowsQueue(
    v['name'] as String,
    v['port'] as String,
    v['driver'] as String,
    v['server'] as String,
    v['attributes'] as int,
  );
}

class QueueSnapshot {
  final String sourceKey, label, identity;
  final List<QueueJob> jobs;
  final bool cancelSupported, truncated;
  final DateTime readAt;
  QueueSnapshot({
    required this.sourceKey,
    required this.label,
    required this.identity,
    required this.jobs,
    this.cancelSupported = false,
    this.truncated = false,
    DateTime? readAt,
  }) : readAt = readAt ?? DateTime.now();
  List<QueueJob> get cancelable => cancelSupported
      ? jobs.where((j) => j.active && j.identifiable).toList()
      : [];
  Map<String, dynamic> toJson() => {
    'sourceKey': sourceKey,
    'label': label,
    'identity': identity,
    'jobs': jobs.map((j) => j.toJson()).toList(),
    'cancelSupported': cancelSupported,
    'truncated': truncated,
    'readAt': readAt.toIso8601String(),
  };
}

abstract interface class PrinterQueueService {
  Future<QueueSnapshot> read(PrinterTarget target);
  Future<void> cancel(
    PrinterTarget target,
    QueueSnapshot snapshot,
    QueueJob job,
  );
}

abstract interface class WindowsQueueService {
  Future<List<WindowsQueue>> list();
  Future<QueueSnapshot> read(WindowsQueue queue);
  Future<void> cancel(WindowsQueue queue, QueueJob job);
}

class IppQueueService implements PrinterQueueService {
  static const jobAttributes = [
    'job-id',
    'job-uri',
    'job-uuid',
    'job-name',
    'job-originating-user-name',
    'job-state',
    'job-state-reasons',
    'job-impressions',
    'job-impressions-completed',
    'time-at-creation',
    'date-time-at-creation',
  ];
  static String _text(Map<String, List<Object?>> a, String k) =>
      a[k]?.whereType<String>().firstOrNull ?? '';
  static int? _number(Map<String, List<Object?>> a, String k) =>
      a[k]?.whereType<int>().firstOrNull;
  static List<Uint8List> _requested(List<String> keys) => [
    for (var i = 0; i < keys.length; i++)
      IppMessage.attribute(0x44, i == 0 ? 'requested-attributes' : '', keys[i]),
  ];
  static Uint8List listRequest(Uri uri, {int id = 1}) =>
      IppMessage.request(10, uri, [
        IppMessage.attribute(
          0x42,
          'requesting-user-name',
          Platform.environment['USERNAME'] ?? 'FixmaPixma',
        ),
        IppMessage.attribute(0x44, 'which-jobs', 'not-completed'),
        IppMessage.attribute(0x22, 'my-jobs', false),
        IppMessage.attribute(0x21, 'limit', 201),
        ..._requested(jobAttributes),
      ], id: id);
  static Uint8List cancelRequest(Uri uri, int jobId, {int id = 1}) {
    if (jobId < 1 || jobId > 0x7fffffff) {
      throw ArgumentError('Invalid job identifier.');
    }
    return IppMessage.request(8, uri, [
      IppMessage.attribute(0x21, 'job-id', jobId),
      IppMessage.attribute(
        0x42,
        'requesting-user-name',
        Platform.environment['USERNAME'] ?? 'FixmaPixma',
      ),
    ], id: id);
  }

  static List<QueueJob> parseJobs(IppMessage message, String sourceKey) {
    final jobs = <QueueJob>[];
    final ids = <int>{};
    for (final g in message.groups.where((g) => g.tag == 2)) {
      final a = g.attributes,
          id = _number(g.attributes, 'job-id'),
          state = _number(a, 'job-state');
      if (id == null || id < 1 || !ids.add(id)) {
        throw const FormatException(
          'Invalid or duplicate printer job identifier.',
        );
      }
      final date = _text(a, 'date-time-at-creation');
      final seconds = _number(a, 'time-at-creation');
      jobs.add(
        QueueJob(
          sourceKey: sourceKey,
          id: id,
          title: _text(a, 'job-name').isEmpty
              ? 'Untitled job'
              : _text(a, 'job-name'),
          owner: _text(a, 'job-originating-user-name'),
          state: switch (state) {
            3 => 'Pending',
            4 => 'Held',
            5 => 'Printing',
            6 => 'Stopped',
            7 => 'Canceled',
            8 => 'Aborted',
            9 => 'Completed',
            _ => 'Unknown',
          },
          active: state != null && state >= 3 && state <= 6,
          created: date.isNotEmpty
              ? date
              : seconds == null
              ? ''
              : 'Printer time $seconds',
          uri: _text(a, 'job-uri'),
          token: _text(a, 'job-uuid'),
          pages: _number(a, 'job-impressions'),
          printed: _number(a, 'job-impressions-completed'),
        ),
      );
    }
    return jobs;
  }

  Future<IppMessage> _post(PrinterTarget target, Uint8List payload) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    client.findProxy = (_) => 'DIRECT';
    try {
      return await (() async {
        final request = await client.postUrl(
          target.uri.replace(
            scheme: target.uri.scheme == 'ipps' ? 'https' : 'http',
          ),
        );
        request.followRedirects = false;
        request.headers.contentType = ContentType('application', 'ipp');
        request.add(payload);
        final response = await request.close();
        if (response.statusCode != 200 ||
            response.headers.contentType?.mimeType != 'application/ipp') {
          throw StateError(
            'Queue request failed (HTTP ${response.statusCode}).',
          );
        }
        final bytes = BytesBuilder();
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 1024 * 1024) {
            throw const FormatException('Queue response too large.');
          }
          bytes.add(chunk);
        }
        return IppMessage.decode(bytes.takeBytes());
      })().timeout(const Duration(seconds: 12));
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, List<Object?>>> _identity(PrinterTarget target) async {
    final message = await _post(
      target,
      IppMessage.request(
        11,
        target.uri,
        _requested(['printer-name', 'printer-uuid', 'operations-supported']),
      ),
    );
    return message.groups.where((g) => g.tag == 4).single.attributes;
  }

  @override
  Future<QueueSnapshot> read(PrinterTarget target) async {
    final identity = await _identity(target),
        ops = identity['operations-supported'] ?? [];
    if (!ops.contains(10)) {
      throw StateError('This printer does not advertise job listing.');
    }
    final response = await _post(target, listRequest(target.uri));
    final jobs = parseJobs(response, target.key);
    final uuid = _text(identity, 'printer-uuid');
    if (target.discoveryId.isNotEmpty &&
        uuid.isNotEmpty &&
        uuid.toLowerCase().replaceFirst('urn:uuid:', '') !=
            target.discoveryId.toLowerCase()) {
      throw StateError(
        'The printer at this address has changed. Rediscover it in Overview.',
      );
    }
    return QueueSnapshot(
      sourceKey: target.key,
      label: _text(identity, 'printer-name'),
      identity: uuid,
      jobs: jobs.take(200).toList(),
      truncated: jobs.length > 200,
      cancelSupported: ops.contains(8) && uuid.isNotEmpty,
    );
  }

  @override
  Future<void> cancel(
    PrinterTarget target,
    QueueSnapshot snapshot,
    QueueJob job,
  ) async {
    if (!snapshot.cancelSupported ||
        target.key != snapshot.sourceKey ||
        job.sourceKey != target.key ||
        !job.identifiable ||
        !job.active) {
      throw StateError('This job is not eligible for cancellation.');
    }
    final identity = await _identity(target);
    if (_text(identity, 'printer-uuid') != snapshot.identity ||
        !(identity['operations-supported'] ?? []).contains(8)) {
      throw StateError('Printer identity or cancellation support changed.');
    }
    final fresh = await _post(
      target,
      IppMessage.request(9, target.uri, [
        IppMessage.attribute(0x21, 'job-id', job.id),
        ..._requested(jobAttributes),
      ]),
    );
    final current = parseJobs(fresh, target.key).single;
    if (current.fingerprint != job.fingerprint || !current.active) {
      throw StateError(
        'The job changed or finished. Refresh the queue before canceling.',
      );
    }
    await _post(target, cancelRequest(target.uri, job.id));
  }
}

class NativeWindowsQueueService implements WindowsQueueService {
  final String? executable;
  NativeWindowsQueueService({this.executable});
  Future<dynamic> _call(Map<String, dynamic> request) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows queues are available on Windows.');
    }
    final path =
        executable ??
        Platform.environment['PRINTERCARE_QUEUE_WORKER'] ??
        '${File(Platform.resolvedExecutable).parent.path}/fixma_pixma_queue.exe';
    if (!File(path).existsSync()) {
      throw StateError(
        'The Windows queue helper is missing. Extract the entire app folder.',
      );
    }
    final process = await Process.start(path, []);
    process.stdin.done.catchError((Object _) {});
    final output = StringBuffer();
    var length = 0;
    final done = process.stdout.transform(utf8.decoder).listen((s) {
      length += s.length;
      if (length > 2 * 1024 * 1024) {
        process.kill();
      } else {
        output.write(s);
      }
    }).asFuture<void>();
    final errors = process.stderr.drain<void>();
    try {
      process.stdin.writeln(jsonEncode(request));
      await process.stdin.close();
      await Future.wait([process.exitCode, done, errors])
          .timeout(const Duration(seconds: 15));
      final result = jsonDecode(output.toString()) as Map;
      if (result['ok'] != true) {
        throw StateError(
          result['error'] as String? ?? 'Windows queue request failed.',
        );
      }
      return result['value'];
    } on Object {
      process.kill();
      rethrow;
    }
  }

  @override
  Future<List<WindowsQueue>> list() async =>
      (await _call({'op': 'list'}) as List)
          .map((v) => WindowsQueue.fromJson(v as Map))
          .toList();
  @override
  Future<QueueSnapshot> read(WindowsQueue queue) async {
    final result = await _call({'op': 'jobs', 'queue': queue.toJson()}) as Map;
    return QueueSnapshot(
      sourceKey: queue.key,
      label: queue.name,
      identity: queue.identity,
      jobs: (result['jobs'] as List)
          .map((v) => QueueJob.fromJson(v as Map))
          .toList(),
      cancelSupported: true,
      truncated: result['truncated'] == true,
    );
  }

  @override
  Future<void> cancel(WindowsQueue queue, QueueJob job) async {
    await _call({'op': 'cancel', 'queue': queue.toJson(), 'job': job.toJson()});
  }
}
