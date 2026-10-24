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
    barrierDismissible: false,
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
      return PopScope(
        canPop: !u.installing,
        child: AlertDialog(
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
                    'Download the update here, then choose Install and restart when printer operations have finished. Settings, history and reset guards stay in place. The previous version is kept until the new one confirms startup.',
                  ),
                ],
                if (u.downloading || u.installStatus.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(u.installStatus),
                  if (u.downloading) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: u.downloadBytes > 0
                          ? u.downloadedBytes / u.downloadBytes
                          : null,
                    ),
                    TextButton(
                      onPressed: u.cancelDownload,
                      child: const Text('Cancel download'),
                    ),
                  ],
                ],
                if (u.prepared != null &&
                    !(u.printerIdle?.call() ?? false)) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Finish the current printer operation before installing. Your verified download is ready when the printer is idle.',
                  ),
                ],
                if (release != null && !release.canDownload) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'This release has no verified in-app download. Use View release to download it manually.',
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
              onPressed: u.installing ? null : () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            TextButton(
              onPressed: u.checking || u.downloading || u.installing
                  ? null
                  : () => u.check(),
              child: Text(u.checking ? 'Checking...' : 'Check for updates'),
            ),
            if (release != null && release.canDownload && u.prepared == null)
              FilledButton.icon(
                onPressed: u.checking || u.downloading || u.installing
                    ? null
                    : u.download,
                icon: const Icon(Icons.download, size: 16),
                label: const Text('Download update'),
              ),
            if (u.prepared != null)
              FilledButton.icon(
                onPressed: u.canInstall
                    ? () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Install update and restart?'),
                            content: const Text(
                              'Fixma Pixma will close and restart with the verified update. Finish all printer operations first. Your settings, history and reset guards will be preserved.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Install and restart'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true && mounted) await u.install();
                      }
                    : null,
                icon: const Icon(Icons.restart_alt, size: 16),
                label: Text(
                  u.installing ? 'Restarting...' : 'Install and restart',
                ),
              ),
            if (release != null)
              TextButton.icon(
                onPressed: opening || u.installing ? null : open,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('View release'),
              ),
          ],
        ),
      );
    },
  );
}
