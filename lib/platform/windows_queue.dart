import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../core/print_queue.dart';

/// Isolated in a short-lived process: spooler calls can block indefinitely.
class WindowsSpooler {
  final _dll = DynamicLibrary.open('winspool.drv');
  late final _lastError = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  late final _open = _dll
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>),
        int Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>)
      >('OpenPrinterW');
  late final _close = _dll
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'ClosePrinter',
      );
  late final _enum = _dll
      .lookupFunction<
        Int32 Function(
          Uint32,
          Pointer<Utf16>,
          Uint32,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Uint32>,
        ),
        int Function(
          int,
          Pointer<Utf16>,
          int,
          Pointer<Uint8>,
          int,
          Pointer<Uint32>,
          Pointer<Uint32>,
        )
      >('EnumPrintersW');
  late final _printer = _dll
      .lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<Uint8>, Uint32, Pointer<Uint32>),
        int Function(int, int, Pointer<Uint8>, int, Pointer<Uint32>)
      >('GetPrinterW');
  late final _jobs = _dll
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Uint32,
          Uint32,
          Uint32,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Uint32>,
        ),
        int Function(
          int,
          int,
          int,
          int,
          Pointer<Uint8>,
          int,
          Pointer<Uint32>,
          Pointer<Uint32>,
        )
      >('EnumJobsW');
  late final _job = _dll
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Uint32,
          Uint32,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
        ),
        int Function(int, int, int, Pointer<Uint8>, int, Pointer<Uint32>)
      >('GetJobW');
  late final _set = _dll
      .lookupFunction<
        Int32 Function(IntPtr, Uint32, Uint32, Pointer<Void>, Uint32),
        int Function(int, int, int, Pointer<Void>, int)
      >('SetJobW');
  WindowsSpooler() {
    if (!Platform.isWindows || sizeOf<IntPtr>() != 8) {
      throw UnsupportedError('Windows x64 is required.');
    }
    // Resolve before calls so symbol lookup cannot overwrite the last error.
    _lastError;
    _open;
    _close;
    _enum;
    _printer;
    _jobs;
    _job;
    _set;
  }
  T _buffer<T>(
    int Function(Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint32>) call,
    T Function(Pointer<Uint8>, int, int) parse,
  ) {
    final needed = calloc<Uint32>(), count = calloc<Uint32>();
    Pointer<Uint8> bytes = nullptr;
    try {
      final ok = call(nullptr, 0, needed, count), error = _lastError();
      if (ok == 0 && error != 122) {
        throw OSError('Windows spooler request failed', error);
      }
      final length = needed.value;
      if (length == 0) return parse(nullptr, 0, 0);
      if (length > 8 * 1024 * 1024) {
        throw StateError('Windows queue response is too large.');
      }
      bytes = calloc<Uint8>(length);
      if (call(bytes, length, needed, count) == 0) {
        throw OSError('Windows spooler request failed', _lastError());
      }
      return parse(bytes, length, count.value);
    } finally {
      calloc.free(bytes);
      calloc.free(needed);
      calloc.free(count);
    }
  }

  String _string(Pointer<Uint8> base, int length, int offset) {
    final address = (base + offset).cast<IntPtr>().value;
    if (address == 0) return '';
    if (address < base.address ||
        address >= base.address + length ||
        address.isOdd) {
      throw const FormatException('Invalid spooler string.');
    }
    final p = Pointer<Uint16>.fromAddress(address),
        max = ((base.address + length - address) ~/ 2).clamp(0, 32768);
    var n = 0;
    while (n < max && p[n] != 0) {
      n++;
    }
    if (n == max) throw const FormatException('Unterminated spooler string.');
    return String.fromCharCodes(p.asTypedList(n));
  }

  WindowsQueue _queue(Pointer<Uint8> b, int length, int offset) => WindowsQueue(
    _string(b, length, offset + 8),
    _string(b, length, offset + 24),
    _string(b, length, offset + 32),
    _string(b, length, offset),
    (b + offset + 104).cast<Uint32>().value,
  );
  List<WindowsQueue> list() => _buffer(
    (b, n, needed, count) => _enum(6, nullptr, 2, b, n, needed, count),
    (b, n, count) {
      if (count > 512 || count * 136 > n) {
        throw const FormatException('Invalid Windows printer list.');
      }
      return [for (var i = 0; i < count; i++) _queue(b, n, i * 136)]
          .where((q) => q.attributes & 0x4000 == 0)
          .toList();
    },
  );
  T _with<T>(WindowsQueue expected, T Function(int) body) {
    final name = expected.name.toNativeUtf16(), handle = calloc<IntPtr>();
    try {
      if (_open(name, handle, nullptr) == 0) {
        throw OSError('Cannot open this Windows queue', _lastError());
      }
      final fresh = _buffer(
        (b, n, needed, count) => _printer(handle.value, 2, b, n, needed),
        (b, n, count) {
          if (n < 136) {
            throw const FormatException('Incomplete printer identity.');
          }
          return _queue(b, n, 0);
        },
      );
      if (fresh.identity != expected.identity) {
        throw StateError(
          'This Windows queue changed. Refresh before continuing.',
        );
      }
      return body(handle.value);
    } finally {
      if (handle.value != 0) _close(handle.value);
      calloc.free(name);
      calloc.free(handle);
    }
  }

  QueueJob _parseJob(Pointer<Uint8> b, int n, int offset, WindowsQueue queue) {
    int d(int o) => (b + offset + o).cast<Uint32>().value;
    int s(int o) => (b + offset + o).cast<Uint16>().value;
    final flags = d(56), year = s(76);
    final created = year == 0
        ? ''
        : DateTime.utc(
            year,
            s(78),
            s(82),
            s(84),
            s(86),
            s(88),
            s(90),
          ).toIso8601String();
    final labels = <String>[];
    for (final e in {
      1: 'Paused',
      2: 'Error',
      4: 'Deleting',
      8: 'Spooling',
      16: 'Printing',
      32: 'Offline',
      64: 'Paper out',
      128: 'Printed',
      256: 'Deleted',
      512: 'Blocked',
      1024: 'Needs attention',
      4096: 'Complete',
    }.entries) {
      if (flags & e.key != 0) labels.add(e.value);
    }
    return QueueJob(
      sourceKey: queue.key,
      id: d(0),
      title: _string(b, n, offset + 32),
      owner: _string(b, n, offset + 24),
      state: labels.isEmpty ? 'Waiting' : labels.join(' · '),
      created: created,
      uri: queue.key,
      pages: d(68),
      printed: d(72),
      active: flags & (4 | 128 | 256 | 4096) == 0,
    );
  }

  Map<String, Object> read(WindowsQueue queue) => _with(
    queue,
    (h) => _buffer(
      (b, n, needed, count) => _jobs(h, 0, 201, 1, b, n, needed, count),
      (b, n, count) {
        if (count > 201 || count * 96 > n) {
          throw const FormatException('Invalid Windows job list.');
        }
        return {
          'jobs': [
            for (var i = 0; i < count.clamp(0, 200); i++)
              _parseJob(b, n, i * 96, queue).toJson(),
          ],
          'truncated': count > 200,
        };
      },
    ),
  );
  void cancel(WindowsQueue queue, QueueJob expected) => _with(queue, (h) {
    if (expected.sourceKey != queue.key ||
        !expected.active ||
        !expected.identifiable) {
      throw StateError('This job cannot be canceled.');
    }
    final fresh = _buffer(
      (b, n, needed, count) => _job(h, expected.id, 1, b, n, needed),
      (b, n, count) {
        if (n < 96) throw const FormatException('Incomplete job identity.');
        return _parseJob(b, n, 0, queue);
      },
    );
    if (fresh.fingerprint != expected.fingerprint || !fresh.active) {
      throw StateError('The job changed or finished. Refresh the queue.');
    }
    if (_set(h, expected.id, 0, nullptr, 5) == 0) {
      throw OSError('Windows could not delete this job', _lastError());
    }
  });
}
