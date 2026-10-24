import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// A retained process handle prevents PID reuse while waiting for shutdown.
class UpdateProcess {
  final Pointer<Void> handle;
  UpdateProcess._(this.handle);
  static final _kernel = DynamicLibrary.open('kernel32.dll');
  static UpdateProcess open(
    int pid,
    String executable, {
    bool terminate = false,
  }) {
    if (!Platform.isWindows || pid <= 0) {
      throw StateError('Windows process access is unavailable.');
    }
    final open = _kernel
        .lookupFunction<
          Pointer<Void> Function(Uint32, Int32, Uint32),
          Pointer<Void> Function(int, int, int)
        >('OpenProcess');
    final handle = open(0x00100000 | 0x1000 | (terminate ? 1 : 0), 0, pid);
    if (handle == nullptr) {
      throw StateError('The application process is unavailable.');
    }
    final process = UpdateProcess._(handle);
    final buffer = calloc<Uint16>(32768),
        length = calloc<Uint32>()..value = 32768;
    try {
      final query = _kernel
          .lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Uint32,
              Pointer<Uint16>,
              Pointer<Uint32>,
            ),
            int Function(Pointer<Void>, int, Pointer<Uint16>, Pointer<Uint32>)
          >('QueryFullProcessImageNameW');
      if (query(handle, 0, buffer, length) == 0 ||
          File(buffer.cast<Utf16>().toDartString())
                  .resolveSymbolicLinksSync()
                  .toLowerCase() !=
              File(executable).resolveSymbolicLinksSync().toLowerCase()) {
        throw StateError('The application process changed.');
      }
      return process;
    } catch (_) {
      process.close();
      rethrow;
    } finally {
      calloc.free(buffer);
      calloc.free(length);
    }
  }

  bool get alive =>
      _kernel.lookupFunction<
        Uint32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('WaitForSingleObject')(handle, 0) ==
      258;
  void terminate() {
    _kernel.lookupFunction<
      Int32 Function(Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int)
    >('TerminateProcess')(handle, 1);
  }

  void close() {
    _kernel.lookupFunction<
      Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)
    >('CloseHandle')(handle);
  }
}
