import 'dart:async';

import 'package:flutter/material.dart';

import 'components.dart';
import 'core/software_update.dart';
import 'platform/open_support.dart';
import 'theme.dart';
import 'update_controller.dart';

Future<void> showSoftwareUpdates(
  BuildContext context,
  UpdateController updates, {
  Future<void> Function(String)? openRelease,
  bool check = true,
}) async {
  if (check) unawaited(updates.check());
  await showDialog<void>(
    context: context,
    builder: (_) => _UpdatesDialog(
      updates: updates,
      openRelease: openRelease ?? openSoftwareRelease,
    ),
  );
}

class UpdateNotice extends StatelessWidget {
  final UpdateController updates;
  const UpdateNotice({super.key, required this.updates});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Panel(
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            'Fixma Pixma ${updates.available!.version.text} is available.',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          TextButton(
            onPressed: () =>
                showSoftwareUpdates(context, updates, check: false),
            child: const Text('View update'),
          ),
          IconButton(
            tooltip: 'Dismiss update notice',
            onPressed: updates.dismissNotice,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    ),
  );
}

class _UpdatesDialog extends StatefulWidget {
  final UpdateController updates;
  final Future<void> Function(String) openRelease;
  const _UpdatesDialog({required this.updates, required this.openRelease});
  @override
  State<_UpdatesDialog> createState() => _UpdatesDialogState();
}

class _UpdatesDialogState extends State<_UpdatesDialog> {
  bool opening = false;
  String? browserError;
  Future<void> open() async {
    if (opening) return;
    final release = widget.updates.available;
    if (release == null) return;
    setState(() {
      opening = true;
      browserError = null;
    });
    try {
      await widget.openRelease(release.tag);
    } catch (_) {
      if (mounted) {
        setState(
          () => browserError =
              'The browser could not be opened. Copy the release link below.',
        );
      }
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.updates,
    builder: (context, _) {
      final u = widget.updates;
      final release = u.available;
      return AlertDialog(
        scrollable: true,
        title: const Text('Software updates'),
        content: SizedBox(
          width: 480,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Installed version: ${u.installed}'),
              const SizedBox(height: 16),
              Text(
                u.checking
                    ? 'Checking GitHub for updates...'
                    : u.error.isNotEmpty
                    ? u.error
                    : release != null
                    ? 'Version ${release.version.text} is available.'
                    : u.completed
                    ? 'No newer Windows release was found.'
                    : 'Check GitHub for a newer Windows release.',
              ),
              if (ReleaseVersion.tryParse(u.installed)?.isPrerelease ==
                  true) ...[
                const SizedBox(height: 8),
                Text(
                  'Beta updates are included for this beta build.',
                  style: TextStyle(color: colors(context).muted),
                ),
              ],
              const SizedBox(height: 16),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Check automatically once a day'),
                value: u.automatic,
                onChanged: (v) => u.setAutomatic(v ?? false),
              ),
              const Text(
                'Off by default. Checks contact GitHub while the app is open. No printer data, reports or history are sent.',
              ),
              if (u.preferenceError.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  u.preferenceError,
                  style: TextStyle(color: colors(context).warning),
                ),
              ],
              if (release != null) ...[
                const SizedBox(height: 16),
                const Text(
                  'Installation is manual. Finish any printer operation, close the app, extract the complete Windows ZIP into a new folder, then run fixma_pixma.exe. Existing local settings and history are preserved.',
                ),
              ],
              if (browserError != null) ...[
                const SizedBox(height: 12),
                Text(browserError!),
                if (release != null) SelectableText(release.page.toString()),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: u.checking ? null : () => u.check(),
            child: Text(u.checking ? 'Checking...' : 'Check for updates'),
          ),
          if (release != null)
            FilledButton.icon(
              onPressed: opening ? null : open,
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('View release'),
            ),
        ],
      );
    },
  );
}
