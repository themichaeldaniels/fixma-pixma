import 'package:flutter/material.dart';

import 'platform/open_support.dart';
import 'theme.dart';

class ReportProblemButton extends StatelessWidget {
  final Future<void> Function()? openIssue;
  const ReportProblemButton({super.key, this.openIssue});

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: () => showDialog<void>(
      context: context,
      builder: (_) =>
          _ProblemReportDialog(openIssue: openIssue ?? openSupportIssue),
    ),
    icon: const Icon(Icons.open_in_new, size: 16),
    label: const Text('Report a problem'),
  );
}

class _ProblemReportDialog extends StatefulWidget {
  final Future<void> Function() openIssue;
  const _ProblemReportDialog({required this.openIssue});

  @override
  State<_ProblemReportDialog> createState() => _ProblemReportDialogState();
}

class _ProblemReportDialogState extends State<_ProblemReportDialog> {
  bool opening = false;
  String? error;

  Future<void> open() async {
    if (opening) return;
    setState(() {
      opening = true;
      error = null;
    });
    try {
      await widget.openIssue();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          opening = false;
          error = 'The browser could not be opened. Copy the link below into your browser.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Report a problem'),
    scrollable: true,
    content: SizedBox(
      width: 500,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Reports from other models are welcome. Hardware testing covers only the G7020, firmware 1.050.',
            style: TextStyle(height: 1.5),
          ),
          const SizedBox(height: 16),
          const Text(
            '1. In Diagnostics > Connection, run connection checks, then choose Export diagnostic summary.\n\n'
            '2. Open the .json file in Notepad and review it. Known identifiers are redacted, but check for serial numbers, personal information and private network details.\n\n'
            '3. Open the GitHub issue form below. Describe what happened, include the exact printer model and firmware, then drag the reviewed .json file into the Reviewed diagnostic summary field, or use its attachment control.',
            style: TextStyle(height: 1.5),
          ),
          const SizedBox(height: 16),
          Text(
            'Nothing is attached or submitted automatically. Do not share the full history folder or raw service report. GitHub sign-in is required to submit; repository access is also required while the project is private.',
            style: TextStyle(color: colors(context).muted, height: 1.5),
          ),
          if (error != null) ...[
            const SizedBox(height: 16),
            Text(error!, style: TextStyle(color: colors(context).warning)),
            const SizedBox(height: 8),
            const SelectableText(supportIssueUrl),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
      FilledButton.icon(
        onPressed: opening ? null : open,
        icon: const Icon(Icons.open_in_new, size: 16),
        label: Text(opening ? 'Opening browser...' : 'Open GitHub issue form'),
      ),
    ],
  );
}
