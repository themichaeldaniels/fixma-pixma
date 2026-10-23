import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class _OpenFile extends Struct {
  @Uint32()
  external int size;
  @IntPtr()
  external int owner;
  @IntPtr()
  external int instance;
  external Pointer<Utf16> filter;
  external Pointer<Utf16> customFilter;
  @Uint32()
  external int maxCustomFilter;
  @Uint32()
  external int filterIndex;
  external Pointer<Utf16> file;
  @Uint32()
  external int maxFile;
  external Pointer<Utf16> fileTitle;
  @Uint32()
  external int maxFileTitle;
  external Pointer<Utf16> initialDirectory;
  external Pointer<Utf16> title;
  @Uint32()
  external int flags;
  @Uint16()
  external int fileOffset;
  @Uint16()
  external int extensionOffset;
  external Pointer<Utf16> defaultExtension;
  @IntPtr()
  external int customData;
  external Pointer<Void> hook;
  external Pointer<Utf16> templateName;
  external Pointer<Void> reserved;
  @Uint32()
  external int reservedValue;
  @Uint32()
  external int flagsEx;
}

String? saveReportPath() => saveDocumentPath(
  titleText: 'Save service report',
  extensionText: 'txt',
  description: 'Text reports',
);

String? saveDocumentPath({
  required String titleText,
  required String extensionText,
  required String description,
}) {
  if (!Platform.isWindows) {
    throw UnsupportedError('Export is currently available on Windows.');
  }
  final dialog = calloc<_OpenFile>(), path = calloc<Uint16>(32768);
  final filter = '$description\x00*.$extensionText\x00\x00'.toNativeUtf16();
  final title = titleText.toNativeUtf16(),
      extension = extensionText.toNativeUtf16();
  try {
    final name =
        'PixmaFixa-${DateTime.now().toIso8601String().substring(0, 10)}.$extensionText';
    path.asTypedList(name.length).setAll(0, name.codeUnits);
    dialog.ref.size = sizeOf<_OpenFile>();
    dialog.ref.filter = filter;
    dialog.ref.filterIndex = 1;
    dialog.ref.file = path.cast();
    dialog.ref.maxFile = 32768;
    dialog.ref.title = title;
    dialog.ref.defaultExtension = extension;
    dialog.ref.flags = 0x80000 | 0x800 | 0x2 | 0x8;
    final api = DynamicLibrary.open('comdlg32.dll');
    final ok = api
        .lookupFunction<
          Int32 Function(Pointer<_OpenFile>),
          int Function(Pointer<_OpenFile>)
        >('GetSaveFileNameW')(dialog);
    if (ok == 0) {
      final err = api.lookupFunction<Uint32 Function(), int Function()>(
        'CommDlgExtendedError',
      )();
      if (err != 0) throw OSError('Windows save dialog failed', err);
      return null;
    }
    return path.cast<Utf16>().toDartString();
  } finally {
    calloc.free(dialog);
    calloc.free(path);
    calloc.free(filter);
    calloc.free(title);
    calloc.free(extension);
  }
}
