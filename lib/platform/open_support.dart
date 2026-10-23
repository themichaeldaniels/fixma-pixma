import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const supportIssueUrl =
    'https://github.com/themichaeldaniels/fixma-pixma/issues/new?template=model-support.yml';

/// Opens only the fixed issue form. No diagnostic data is added to the URL.
Future<void> openSupportIssue() async {
  if (!Platform.isWindows) {
    throw UnsupportedError('Open this link in your browser instead.');
  }
  final verb = 'open'.toNativeUtf16();
  final url = supportIssueUrl.toNativeUtf16();
  final com = DynamicLibrary.open('ole32.dll');
  var uninitialize = false;
  try {
    final initialized = com
        .lookupFunction<
          Int32 Function(Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int)
        >('CoInitializeEx')(nullptr, 2);
    uninitialize = initialized >= 0;
    // An existing COM apartment can also serve the browser handoff.
    if (initialized < 0 && initialized != -2147417850) {
      throw OSError('Windows could not initialize browser access', initialized);
    }
    final result = DynamicLibrary.open('shell32.dll')
        .lookupFunction<
          IntPtr Function(
            Pointer<Void>,
            Pointer<Utf16>,
            Pointer<Utf16>,
            Pointer<Utf16>,
            Pointer<Utf16>,
            Int32,
          ),
          int Function(
            Pointer<Void>,
            Pointer<Utf16>,
            Pointer<Utf16>,
            Pointer<Utf16>,
            Pointer<Utf16>,
            int,
          )
        >('ShellExecuteW')(nullptr, verb, url, nullptr, nullptr, 1);
    if (result <= 32) {
      throw OSError('Windows could not open the default browser', result);
    }
  } finally {
    if (uninitialize) {
      com.lookupFunction<Void Function(), void Function()>('CoUninitialize')();
    }
    calloc.free(verb);
    calloc.free(url);
  }
}
