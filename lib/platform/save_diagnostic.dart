import 'dart:io';

import '../controller.dart';
import 'save_report.dart';

/// Captures the current evidence before showing the save dialog. No printer
/// operation runs here, so reporting a failure does not clear its error state.
Future<String?> saveDiagnosticSummary(
  CareController controller, {
  String? Function()? choosePath,
}) async {
  final summary = controller.diagnosticSummary();
  final path =
      (choosePath ??
      () => saveDocumentPath(
        titleText: 'Save diagnostic summary',
        extensionText: 'json',
        description: 'Diagnostic summary',
      ))();
  if (path == null) return null;
  await File(path).writeAsString(summary, flush: true);
  return path;
}
