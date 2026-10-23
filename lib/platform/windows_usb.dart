import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _GetN = IntPtr Function(Pointer<Uint8>, Pointer<Utf16>, IntPtr, Uint32);
typedef _GetD = int Function(Pointer<Uint8>, Pointer<Utf16>, int, int);
typedef _EnumN = Int32 Function(
  IntPtr,
  Pointer<Void>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint8>,
);
typedef _EnumD = int Function(
  int,
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
);
typedef _DetailN = Int32 Function(
  IntPtr,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _DetailD = int Function(
  int,
  Pointer<Uint8>,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _CloseN = Int32 Function(IntPtr);
typedef _CloseD = int Function(int);
typedef _ErrorN = Uint32 Function();
typedef _ErrorD = int Function();
typedef _OpenN = IntPtr Function(
  Pointer<Utf16>,
  Uint32,
  Uint32,
  Pointer<Void>,
  Uint32,
  Uint32,
  IntPtr,
);
typedef _OpenD = int Function(
  Pointer<Utf16>,
  int,
  int,
  Pointer<Void>,
  int,
  int,
  int,
);
typedef _IoN = Int32 Function(
  IntPtr,
  Uint32,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _IoD = int Function(
  int,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
  Pointer<Void>,
);

class WindowsUsb {
  final kernel = DynamicLibrary.open('kernel32.dll');
  late final _ErrorD _lastError;
  WindowsUsb() {
    // Resolve before any Win32 operation: resolving a symbol itself can change
    // the thread's last-error value (including ERROR_NO_MORE_ITEMS).
    _lastError = kernel.lookupFunction<_ErrorN, _ErrorD>('GetLastError');
  }
  int? handle;
  int get error => _lastError();
  List<String> enumerate() {
    final api = DynamicLibrary.open('setupapi.dll');
    final guid = calloc<Uint8>(16),
        info = calloc<Uint8>(32),
        needed = calloc<Uint32>();
    guid.asTypedList(16).setAll(0, [
      0xad,
      0x8f,
      0xd7,
      0x28,
      0x12,
      0x5a,
      0xd1,
      0x11,
      0xae,
      0x5b,
      0,
      0,
      0xf8,
      3,
      0xa8,
      0xc2,
    ]);
    final get = api.lookupFunction<_GetN, _GetD>('SetupDiGetClassDevsW');
    final en = api.lookupFunction<_EnumN, _EnumD>(
      'SetupDiEnumDeviceInterfaces',
    );
    final detail = api.lookupFunction<_DetailN, _DetailD>(
      'SetupDiGetDeviceInterfaceDetailW',
    );
    final destroy = api.lookupFunction<_CloseN, _CloseD>(
      'SetupDiDestroyDeviceInfoList',
    );
    final devices = get(guid, nullptr, 0, 0x12);
    if (devices == -1) {
      calloc.free(guid);
      calloc.free(info);
      calloc.free(needed);
      throw OSError('USB enumeration failed', error);
    }
    final paths = <String>[];
    try {
      for (var i = 0; ; i++) {
        info.cast<Uint32>().value = sizeOf<IntPtr>() == 8 ? 32 : 28;
        if (en(devices, nullptr, guid, i, info) == 0) {
          final code = error;
          if (code == 259) break;
          throw OSError('USB enumeration failed', code);
        }
        detail(devices, info, nullptr, 0, needed, nullptr);
        if (needed.value == 0 || needed.value > 65536) {
          throw StateError('Invalid USB interface detail size.');
        }
        final buffer = calloc<Uint8>(needed.value);
        try {
          buffer.cast<Uint32>().value = sizeOf<IntPtr>() == 8 ? 8 : 6;
          if (detail(devices, info, buffer, needed.value, nullptr, nullptr) ==
              0) {
            throw OSError('USB interface lookup failed', error);
          }
          paths.add((buffer + 4).cast<Utf16>().toDartString());
        } finally {
          calloc.free(buffer);
        }
      }
      return paths;
    } finally {
      destroy(devices);
      calloc.free(guid);
      calloc.free(info);
      calloc.free(needed);
    }
  }

  void open(String path) {
    if (handle != null || !path.toLowerCase().contains('vid_04a9&pid_12fe')) {
      throw StateError('A Canon service-mode interface is required.');
    }
    final p = path.toNativeUtf16();
    try {
      final h = kernel.lookupFunction<_OpenN, _OpenD>('CreateFileW')(
        p,
        0xc0000000,
        3,
        nullptr,
        3,
        0xa0000000,
        0,
      );
      if (h == -1) {
        throw OSError(
          'Cannot open the printer. Close other service utilities and reconnect USB.',
          error,
        );
      }
      handle = h;
    } finally {
      calloc.free(p);
    }
  }

  Uint8List ioctl(int code, [List<int> data = const [], int capacity = 5000]) {
    if (handle == null) throw StateError('USB connection is closed.');
    final input = calloc<Uint8>(data.isEmpty ? 1 : data.length),
        output = calloc<Uint8>(capacity == 0 ? 1 : capacity),
        count = calloc<Uint32>();
    try {
      input.asTypedList(data.length).setAll(0, data);
      final ok = kernel.lookupFunction<_IoN, _IoD>('DeviceIoControl')(
        handle!,
        code,
        data.isEmpty ? nullptr : input,
        data.length,
        capacity == 0 ? nullptr : output,
        capacity,
        count,
        nullptr,
      );
      if (ok == 0) {
        throw OSError(
          'The Windows printer driver did not complete the request',
          error,
        );
      }
      if (count.value > capacity) {
        throw StateError('Invalid driver output length.');
      }
      return Uint8List.fromList(output.asTypedList(count.value));
    } finally {
      calloc.free(input);
      calloc.free(output);
      calloc.free(count);
    }
  }

  void close() {
    if (handle != null) {
      kernel.lookupFunction<_CloseN, _CloseD>('CloseHandle')(handle!);
      handle = null;
    }
  }
}
