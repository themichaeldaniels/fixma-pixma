import 'package:flutter/material.dart';

import 'controller.dart';
import 'platform/open_support.dart';
import 'theme.dart';

class ReportProblemButton extends StatelessWidget {
  final Future<String?> Function() saveReport;
  final Future<void> Function()? openIssue;
  const ReportProblemButton({
    super.key,
    required this.saveReport,
    this.openIssue,
  });

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: () => showDialog<void>(
      context: context,
      builder: (_) => _ProblemReportDialog(
        saveReport: saveReport,
        openIssue: openIssue ?? openSupportIssue,
      ),
    ),
    icon: const Icon(Icons.open_in_new, size: 16),
    label: const Text('Report a problem'),
  );
}

class _ProblemReportDialog extends StatefulWidget {
  final Future<String?> Function() saveReport;
  final Future<void> Function() openIssue;
  const _ProblemReportDialog({
    required this.saveReport,
    required this.openIssue,
  });

  @override
  State<_ProblemReportDialog> createState() => _ProblemReportDialogState();
}

class _ProblemReportDialogState extends State<_ProblemReportDialog> {
  bool opening = false;
  bool issueOpened = false;
  bool browserFailed = false;
  String? savedPath;
  String? error;

  Future<void> open() async {
    if (opening) return;
    setState(() {
      opening = true;
      error = null;
      browserFailed = false;
    });
    if (savedPath == null) {
      try {
        final path = await widget.saveReport();
        if (!mounted) return;
        if (path == null) {
          setState(() => opening = false);
          return;
        }
        setState(() => savedPath = path);
      } catch (e) {
        if (mounted) {
          setState(() {
            opening = false;
            error =
                'The report could not be saved. ${CareController.cleanError(e)} Choose another location and try again.';
          });
        }
        return;
      }
    }
    try {
      await widget.openIssue();
      if (mounted) {
        setState(() {
          opening = false;
          issueOpened = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          opening = false;
          browserFailed = true;
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
          if (savedPath != null) ...[
            Text(
              issueOpened
                  ? 'Report saved. The issue form was opened in your browser.'
                  : 'Report saved. Attach this file to your issue after reviewing it.',
              style: const TextStyle(fontWeight: FontWeight.w600, height: 1.5),
            ),
            const SizedBox(height: 8),
            SelectableText(savedPath!),
            const SizedBox(height: 16),
          ],
          Text(
            '${savedPath == null ? '1. Choose Save report and open issue form. Pick where to save the diagnostic .json file.' : '1. Your diagnostic .json file is saved at the path above.'} '
            'It includes the readings and errors already captured by the app; no printer commands are sent.\n\n'
            '2. Open the .json file in Notepad and review it. Known identifiers are redacted, but check for serial numbers, personal information and private network details.\n\n'
            '3. In the GitHub issue form, describe what happened and include the exact printer model and firmware. Drag the reviewed .json file into the Reviewed diagnostic summary field, or use its attachment control.',
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
            if (browserFailed) ...[
              const SizedBox(height: 8),
              const SelectableText(supportIssueUrl),
            ],
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
        label: Text(
          opening
              ? savedPath == null
                    ? 'Saving report...'
                    : 'Opening browser...'
              : savedPath == null
              ? 'Save report and open issue form'
              : 'Open GitHub issue form',
        ),
      ),
    ],
  );
}
