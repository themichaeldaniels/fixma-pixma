import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// Keep the native Windows frame in the same appearance as the Flutter content.
void setWindowsDarkFrame(bool dark) {
  if (!Platform.isWindows) return;
  final title = 'Printer Care'.toNativeUtf16(), value = calloc<Int32>();
  final owner = calloc<Uint32>();
  try {
    final user = DynamicLibrary.open('user32.dll');
    final hwnd = user
        .lookupFunction<
          IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
          int Function(Pointer<Utf16>, Pointer<Utf16>)
        >('FindWindowW')(nullptr, title);
    if (hwnd == 0) return;
    user.lookupFunction<
      Uint32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)
    >('GetWindowThreadProcessId')(hwnd, owner);
    if (owner.value != pid) return;
    value.value = dark ? 1 : 0;
    DynamicLibrary.open('dwmapi.dll').lookupFunction<
      Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32),
      int Function(int, int, Pointer<Void>, int)
    >('DwmSetWindowAttribute')(hwnd, 20, value.cast(), 4);
  } finally {
    calloc.free(title);
    calloc.free(value);
    calloc.free(owner);
  }
}
