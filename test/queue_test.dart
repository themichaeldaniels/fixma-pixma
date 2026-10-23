import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixma_fixa/controller.dart';
import 'package:pixma_fixa/core/ipp_message.dart';
import 'package:pixma_fixa/core/network_status.dart';
import 'package:pixma_fixa/core/print_queue.dart';

Uint8List packet(
  List<(int, List<(int, String, Object)>)> groups, {
  int code = 0,
}) {
  final b = BytesBuilder()..add([2, 0, code >> 8, code & 255, 0, 0, 0, 1]);
  for (final (tag, attrs) in groups) {
    b.addByte(tag);
    for (final (type, name, value) in attrs) {
      b.add(IppMessage.attribute(type, name, value));
    }
  }
  b.addByte(3);
  return b.takeBytes();
}

List<(int, String, Object)> jobAttrs(int id, {String title = 'Document'}) => [
  (0x21, 'job-id', id),
  (0x45, 'job-uri', 'ipp://printer/ipp/print/job-$id'),
  (0x42, 'job-name', title),
  (0x42, 'job-originating-user-name', 'Test user'),
  (0x23, 'job-state', 3),
  (0x21, 'time-at-creation', 100),
];
QueueJob job(String key, int id) => QueueJob(
  sourceKey: key,
  id: id,
  title: 'Document $id',
  owner: 'Test user',
  state: 'Pending',
  created: 'Printer time 100',
  uri: 'ipp://printer/job-$id',
);

class FakePrinterQueue implements PrinterQueueService {
  final PrinterTarget target;
  late List<QueueJob> jobs;
  final canceled = <int>[];
  bool fail = false;
  FakePrinterQueue(this.target) {
    jobs = [job(target.key, 1), job(target.key, 2)];
  }
  @override
  Future<QueueSnapshot> read(PrinterTarget target) async => QueueSnapshot(
    sourceKey: target.key,
    label: 'Test printer',
    identity: 'uuid-test',
    jobs: List.of(jobs),
    cancelSupported: true,
  );
  @override
  Future<void> cancel(
    PrinterTarget target,
    QueueSnapshot snapshot,
    QueueJob job,
  ) async {
    canceled.add(job.id);
    if (fail) throw const SocketException('Reply lost');
    jobs.removeWhere((j) => j.id == job.id);
    if (job.id == 1) {
      jobs.add(
        QueueJob(
          sourceKey: target.key,
          id: 3,
          title: 'New arrival',
          owner: 'Test user',
          state: 'Pending',
          created: 'Printer time 101',
          uri: 'ipp://printer/job-3',
        ),
      );
    }
  }
}

class FakeWindowsQueue implements WindowsQueueService {
  @override
  Future<List<WindowsQueue>> list() async => [
    const WindowsQueue('Test USB', 'USB001', 'Test driver', '', 0),
  ];
  @override
  Future<QueueSnapshot> read(WindowsQueue q) async => QueueSnapshot(
    sourceKey: q.key,
    label: q.name,
    identity: q.identity,
    jobs: [],
  );
  @override
  Future<void> cancel(WindowsQueue q, QueueJob j) async =>
      throw UnimplementedError();
}

void main() {
  test('IPP preserves separate job groups, state, and creation identity', () {
    final jobs = IppQueueService.parseJobs(
      IppMessage.decode(
        packet([(2, jobAttrs(7)), (2, jobAttrs(8, title: 'Second page'))]),
      ),
      'printer',
    );
    expect(jobs.map((j) => j.id), [7, 8]);
    expect(jobs[1].title, 'Second page');
    expect(jobs.every((j) => j.identifiable && j.active), true);
    expect(
      () => IppQueueService.parseJobs(
        IppMessage.decode(packet([(2, jobAttrs(7)), (2, jobAttrs(7))])),
        'printer',
      ),
      throwsFormatException,
    );
  });
  test('IPP allows individual cancel and listing, never purge or print', () {
    final uri = Uri.parse('ipp://printer:631/ipp/print');
    expect(IppQueueService.cancelRequest(uri, 12).sublist(0, 4), [2, 0, 0, 8]);
    expect(
      latin1.decode(IppQueueService.listRequest(uri)),
      contains('not-completed'),
    );
    for (final op in [2, 6, 18]) {
      expect(() => IppMessage.request(op, uri, []), throwsArgumentError);
    }
    expect(() => IppQueueService.cancelRequest(uri, 0), throwsArgumentError);
  });
  test(
    'IPP identity is reread and a reused job ID is never canceled',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final target = PrinterTarget.parse(
        'ipp://127.0.0.1:${server.port}/ipp/print',
      );
      var changed = false;
      final ops = <int>[];
      server.listen((r) async {
        final body = await r.fold<List<int>>([], (a, b) => a..addAll(b)),
            op = body[3];
        ops.add(op);
        r.response.headers.contentType = ContentType('application', 'ipp');
        r.response.add(switch (op) {
          11 => packet([
            (
              4,
              [
                (0x42, 'printer-name', 'Test printer'),
                (0x45, 'printer-uuid', 'urn:uuid:test'),
                (0x23, 'operations-supported', 8),
                (0x23, '', 9),
                (0x23, '', 10),
              ],
            ),
          ]),
          10 => packet([(2, jobAttrs(1))]),
          9 => packet([
            (2, jobAttrs(1, title: changed ? 'Replacement' : 'Document')),
          ]),
          _ => packet([]),
        });
        await r.response.close();
      });
      addTearDown(() => server.close(force: true));
      final service = IppQueueService(), snapshot = await service.read(target);
      changed = true;
      await expectLater(
        service.cancel(target, snapshot, snapshot.jobs.single),
        throwsStateError,
      );
      expect(ops, [11, 10, 11, 9]);
      changed = false;
      await service.cancel(target, snapshot, snapshot.jobs.single);
      expect(ops.last, 8);
      expect(ops.where((o) => o == 8).length, 1);
    },
  );
  test(
    'Queue batch cancels the confirmed list and leaves new arrivals',
    () async {
      final dir = Directory.systemTemp.createTempSync('queue-test-'),
          target = PrinterTarget.parse('192.168.1.50');
      final backend = FakePrinterQueue(target),
          c = CareController(
            directory: dir,
            printerQueues: backend,
            windowsQueues: FakeWindowsQueue(),
          );
      addTearDown(() {
        c.dispose();
        dir.deleteSync(recursive: true);
      });
      c.selectedPrinter = target;
      await c.refreshQueues();
      expect(c.selectedQueue, isNull);
      expect(c.localQueues.single.port, 'USB001');
      final snapshot = c.printerJobs!;
      await c.cancelJobs(snapshot, snapshot.jobs, confirmed: false);
      expect(backend.canceled, isEmpty);
      await c.cancelJobs(snapshot, snapshot.jobs, confirmed: true);
      expect(backend.canceled, [1, 2]);
      expect(c.printerJobs!.jobs.single.id, 3);
      expect(c.lastError, isEmpty);
      expect(
        c.history.first['events'],
        contains(containsPair('stage', 'Attempt recorded before dispatch')),
      );
    },
  );
  test('A lost cancel reply stops the batch without retrying', () async {
    final dir = Directory.systemTemp.createTempSync('queue-test-'),
        target = PrinterTarget.parse('192.168.1.50');
    final backend = FakePrinterQueue(target)..fail = true,
        c = CareController(
          directory: dir,
          printerQueues: backend,
          windowsQueues: FakeWindowsQueue(),
        );
    addTearDown(() {
      c.dispose();
      dir.deleteSync(recursive: true);
    });
    c.selectedPrinter = target;
    await c.refreshQueues();
    await c.cancelJobs(c.printerJobs!, c.printerJobs!.jobs, confirmed: true);
    expect(backend.canceled, [1]);
    expect(c.lastError, contains('Reply lost'));
    expect(c.history.first['status'], 'Stopped');
  });
  test('Expired queue confirmation cannot dispatch', () async {
    final dir = Directory.systemTemp.createTempSync('queue-test-'),
        target = PrinterTarget.parse('192.168.1.50');
    final backend = FakePrinterQueue(target),
        c = CareController(
          directory: dir,
          printerQueues: backend,
          windowsQueues: FakeWindowsQueue(),
        );
    addTearDown(() {
      c.dispose();
      dir.deleteSync(recursive: true);
    });
    c.selectedPrinter = target;
    c.printerJobs = QueueSnapshot(
      sourceKey: target.key,
      label: 'Test',
      identity: 'uuid',
      jobs: backend.jobs,
      cancelSupported: true,
      readAt: DateTime(2020),
    );
    await c.cancelJobs(c.printerJobs!, c.printerJobs!.jobs, confirmed: true);
    expect(backend.canceled, isEmpty);
    expect(c.lastError, contains('out of date'));
  });
}
