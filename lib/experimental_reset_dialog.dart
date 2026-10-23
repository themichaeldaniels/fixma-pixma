import 'package:flutter/material.dart';

import 'components.dart';
import 'theme.dart';

const experimentalWasteResetNotice =
    'A nonzero waste-counter clear through this app has not been verified on hardware. The original protocol reset succeeded; app diagnostics and reset safeguards were tested.';

class ExperimentalResetDialog extends StatefulWidget {
  final String serial;
  final double counter;
  const ExperimentalResetDialog({
    super.key,
    required this.serial,
    required this.counter,
  });

  @override
  State<ExperimentalResetDialog> createState() =>
      _ExperimentalResetDialogState();
}

class _ExperimentalResetDialogState extends State<ExperimentalResetDialog> {
  bool accepted = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Reset this printer’s counter?'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const BadgeLabel('Experimental reset', warning: true),
            const SizedBox(height: 12),
            Text(
              experimentalWasteResetNotice,
              style: TextStyle(color: colors(context).warning, height: 1.5),
            ),
            const SizedBox(height: 16),
            Text(
              'Canon PIXMA G7020\n${widget.serial}\n\nThe current software counter is ${widget.counter.toStringAsFixed(1)}%. One clear command will be sent after a fresh connection check.\n\nKeep USB connected and leave the printer powered on until the result appears.',
              style: const TextStyle(height: 1.7),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: accepted,
              onChanged: (value) => setState(() => accepted = value ?? false),
              title: const Text('I understand this reset is experimental.'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: accepted ? () => Navigator.pop(context, true) : null,
        child: const Text('Reset counter'),
      ),
    ],
  );
}
