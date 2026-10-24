import 'dart:io';

import 'package:fixma_pixma/platform/install_update.dart';

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows || arguments.length != 1) {
    exitCode = 2;
    return;
  }
  try {
    await runUpdatePlan(File(arguments.single));
  } catch (_) {
    exitCode = 2;
  }
}
