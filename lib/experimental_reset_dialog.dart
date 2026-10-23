import 'package:flutter/material.dart';

import 'components.dart';
import 'theme.dart';
import 'action_feedback.dart';

const experimentalWasteResetNotice =
    'A nonzero waste-counter clear through this app has not been verified on hardware. The original protocol reset succeeded; app diagnostics and reset safeguards were tested.';

const wasteInkSpillWarning =
    'Resetting the counter does not empty or repair the waste-ink pads. If the pads are saturated, blocked or full of ink, replace them before resetting the counter or running Ink Flush on the printer. Ink Flush and cleaning send more waste ink into the absorber. Continuing with full or blocked pads can make ink spill out of the printer. This app resets the waste counter; it does not run Ink Flush.';

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
  bool spillAccepted = false;

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
            const Text(usbServiceRequirement, style: TextStyle(height: 1.5)),
            const SizedBox(height: 16),
            Text(
              'Ink spill warning',
              style: TextStyle(
                color: colors(context).warning,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(wasteInkSpillWarning, style: TextStyle(height: 1.5)),
            const SizedBox(height: 16),
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
              value: spillAccepted,
              onChanged: (value) =>
                  setState(() => spillAccepted = value ?? false),
              title: const Text(
                'I understand that full or blocked pads can spill ink.',
              ),
            ),
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
        onPressed: accepted && spillAccepted
            ? () => Navigator.pop(context, true)
            : null,
        child: const Text('Reset counter'),
      ),
    ],
  );
}
