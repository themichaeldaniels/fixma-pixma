import 'package:flutter/material.dart';

import 'controller.dart';
import 'theme.dart';

const usbServiceRequirement =
    'Connect the printer to this PC with a USB data cable and put it in service mode manually. Wi-Fi cannot read or reset the waste-ink counter in this app.';
const networkRequirement =
    'Keep the printer powered on in normal mode, on the same local network as this PC. Check its Wi-Fi or Ethernet connection, then select it in Overview or add its address. Service mode is not used for network maintenance.';

// Only explicit user actions call this helper. Background refresh stays inline.
Future<bool> printerAction(
  BuildContext context, {
  required String title,
  required Future<void> Function() action,
  required String Function() error,
  required String help,
  bool mayHaveSentCommand = false,
}) async {
  String details;
  try {
    await action();
    details = error().trim();
  } catch (e) {
    details = CareController.cleanError(e);
  }
  if (details.isEmpty) return true;
  if (!context.mounted) return false;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(details, style: const TextStyle(height: 1.5)),
              const SizedBox(height: 16),
              Text(help, style: const TextStyle(height: 1.5)),
              if (mayHaveSentCommand) ...[
                const SizedBox(height: 16),
                Text(
                  'Check the operation history and printer state before retrying. A timeout does not prove the printer ignored the command. An uncertain operation is not repeated automatically.',
                  style: TextStyle(color: colors(context).warning, height: 1.5),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
  return false;
}
