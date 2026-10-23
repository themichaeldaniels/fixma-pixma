import 'package:flutter/material.dart';

import 'components.dart';
import 'controller.dart';
import 'core/network_status.dart';
import 'core/ink_counter.dart';
import 'theme.dart';
import 'action_feedback.dart';

class PrinterOverview extends StatelessWidget {
  final CareController controller;
  final VoidCallback openService;
  const PrinterOverview({
    super.key,
    required this.controller,
    required this.openService,
  });
  CareController get c => controller;

  @override
  Widget build(BuildContext context) {
    final p = colors(context), status = c.networkStatus;
    final locked = c.busy || c.networkRefreshing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Printer overview',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            letterSpacing: -.2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Device information, estimated ink, and current printer status.',
          style: TextStyle(fontSize: 14, color: p.muted, height: 1.6),
        ),
        const SizedBox(height: 18),
        Panel(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status?.model ??
                          c.selectedPrinter?.discoveredName.nonEmpty ??
                          'Find your printer',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      c.selectedPrinter?.uri.host ??
                          'Automatic discovery on your local network',
                      style: TextStyle(fontSize: 13, color: p.muted),
                    ),
                  ],
                ),
              ),
              if (c.networkPrinters.length > 1)
                PopupMenuButton<PrinterTarget>(
                  tooltip: 'Choose printer',
                  onSelected: locked
                      ? null
                      : (target) => networkAction(
                          context,
                          () => c.selectPrinter(target),
                        ),
                  itemBuilder: (_) => [
                    for (final printer in c.networkPrinters)
                      PopupMenuItem(
                        value: printer,
                        child: Text(
                          '${printer.discoveredName.nonEmpty ?? printer.uri.host} · ${printer.uri.host}',
                        ),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Icon(Icons.expand_more, color: p.ink),
                  ),
                ),
              OutlinedButton.icon(
                onPressed: locked ? null : () => findNetworkPrinter(context),
                icon: const Icon(Icons.search, size: 17),
                label: const Text('Find printers'),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: locked || c.selectedPrinter == null
                    ? null
                    : () => networkAction(context, c.refreshNetwork),
                icon: const Icon(Icons.refresh, size: 17),
                label: Text(
                  c.networkRefreshing ? 'Refreshing…' : 'Refresh now',
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: locked ? null : () => addAddress(context),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add by address'),
              ),
              const Spacer(),
              Text(
                'Auto refresh · 15 seconds',
                style: TextStyle(fontSize: 12, color: p.muted),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 32,
                child: Semantics(
                  label: 'Automatic status refresh',
                  child: Switch(
                    value: c.autoRefresh,
                    onChanged: c.setAutoRefresh,
                  ),
                ),
              ),
            ],
          ),
        ),
        LayoutBuilder(
          builder: (context, box) {
            final device = deviceInfo(context, status);
            final readings = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                currentStatus(context, status),
                const SizedBox(height: 18),
                inkLevels(context, status),
                const SizedBox(height: 18),
                if (status != null)
                  capabilities(context, status)
                else
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SectionLabel('USB service diagnostics'),
                        const SizedBox(height: 8),
                        Text(
                          c.devices.any((d) => d['service'] == true)
                              ? 'A Canon service-mode USB interface is connected.'
                              : 'Waste-counter readings and resets require USB + manual service mode on the verified G7020. They are not available over Wi-Fi.',
                          style: TextStyle(
                            color: p.muted,
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: openService,
                          child: const Text('Open service report'),
                        ),
                      ],
                    ),
                  ),
              ],
            );
            return box.maxWidth < 720
                ? Column(
                    children: [device, const SizedBox(height: 18), readings],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 236, child: device),
                      const SizedBox(width: 20),
                      Expanded(child: readings),
                    ],
                  );
          },
        ),
      ],
    );
  }

  Widget deviceInfo(BuildContext context, NetworkStatus? s) {
    final p = colors(context);
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('Device information'),
          const SizedBox(height: 16),
          for (final (name, value) in [
            ('Printer name', s?.name ?? 'Not read'),
            ('Reported model', s?.model ?? 'Not read'),
            ('Firmware', s?.firmware ?? 'Not read'),
            ('Serial number', s?.serial ?? 'Not reported'),
            ('Network address', c.selectedPrinter?.uri.host ?? 'Not connected'),
            (
              'Connection',
              c.networkOnline
                  ? 'Local network'
                  : s != null
                  ? 'Offline · last reading'
                  : 'Not connected',
            ),
            if (s?.canon?.signal != null)
              ('Wi-Fi signal', '${s!.canon!.signal}%'),
          ]) ...[
            Text(name, style: TextStyle(fontSize: 12, color: p.muted)),
            const SizedBox(height: 3),
            SelectableText(
              value,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
          ],
          Divider(height: 1, color: p.line),
          const SizedBox(height: 10),
          Text(
            'Names and firmware are read from the printer.',
            style: TextStyle(fontSize: 12, height: 1.5, color: p.muted),
          ),
        ],
      ),
    );
  }

  Widget currentStatus(BuildContext context, NetworkStatus? s) {
    final p = colors(context), online = c.networkOnline;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: SectionLabel('Current status')),
              BadgeLabel(
                s == null
                    ? 'Not connected'
                    : online
                    ? s.stateLabel
                    : 'Offline',
                warning: s != null && (!online || s.issues.isNotEmpty),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (c.networkError.isNotEmpty) ...[
            Text(
              c.networkError,
              style: TextStyle(color: p.warning, fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 6),
          ],
          if (s == null)
            Text(
              c.busy ? 'Looking for printers on this network…' : 'No network printer connected. Check that it is on the same network, or add its address.',
              style: TextStyle(fontSize: 14, color: p.muted, height: 1.5),
            )
          else ...[
            if (!online)
              Text(
                'The information below is from the last successful check.',
                style: TextStyle(fontSize: 13, color: p.muted),
              ),
            if (s.issues.isEmpty)
              Text(
                online && s.state != null
                    ? 'No current errors reported.'
                    : 'No errors were reported at the last check.',
                style: TextStyle(fontSize: 14, color: p.ink),
              )
            else
              for (final issue in s.issues)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, size: 17, color: p.warning),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              issue.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              issue.detail,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.5,
                                color: p.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            const SizedBox(height: 9),
            Text(
              '${online ? 'Checked' : 'Last seen'} ${date(s.capturedAt)}${s.canon != null && s.canon!.supportCode == null ? ' · Canon reports no support code' : ''}',
              style: TextStyle(fontSize: 12, color: p.muted),
            ),
          ],
        ],
      ),
    );
  }

  Widget inkLevels(BuildContext context, NetworkStatus? s) {
    final p = colors(context), supplies = s?.supplies ?? [];
    final ink = supplies.every(
      (s) => s.type.isEmpty || s.type.startsWith('ink'),
    );
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SectionLabel(
                  ink ? 'Printer ink estimates' : 'Estimated supplies',
                ),
              ),
              if (s?.model.toLowerCase().contains('canon g7000') == true &&
                  s?.firmware == '1.050')
                OutlinedButton(
                  onPressed: c.canCheckInkReset
                      ? () => resetRefilledInk(context)
                      : null,
                  child: const Text('Reset ink counts'),
                ),
            ],
          ),
          const SizedBox(height: 15),
          if (supplies.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                s == null
                    ? 'Ink estimates appear after connecting to a supported printer.'
                    : 'This printer does not report individual supply levels.',
                style: TextStyle(color: p.muted, fontSize: 14, height: 1.5),
              ),
            )
          else
            for (final supply in supplies)
              Padding(
                padding: const EdgeInsets.only(bottom: 15),
                child: Semantics(
                  label: '${supply.name}, ${supply.levelText}, estimated',
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: supplyColor(supply.color, p),
                          borderRadius: BorderRadius.circular(2),
                          border: Border.all(
                            color: p.muted.withValues(alpha: .4),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 112,
                        child: Text(
                          supply.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, color: p.ink),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: LinearProgressIndicator(
                          value: (supply.percent ?? 0) / 100,
                          minHeight: 6,
                          color: c.networkOnline
                              ? supplyColor(supply.color, p)
                              : p.muted,
                          backgroundColor: p.line,
                        ),
                      ),
                      const SizedBox(width: 14),
                      SizedBox(
                        width: 92,
                        child: Text(
                          supply.levelText,
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          Divider(height: 1, color: p.line),
          const SizedBox(height: 10),
          Text(
            'These are the printer’s stored estimates, not a measurement of ink in the tanks. Refilling may not update them. Check the tanks visually.',
            style: TextStyle(fontSize: 12.5, color: p.muted, height: 1.5),
          ),
          if (ink && s != null)
            TextButton(
              onPressed: () => refillHelp(context, s),
              child: const Text('Recently refilled?'),
            ),
          if (s != null && !c.networkOnline)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Offline - showing the last reported levels.',
                style: TextStyle(fontSize: 12.5, color: p.warning),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> resetRefilledInk(BuildContext context) async {
    InkResetCheck? check;
    final ready = await printerAction(
      context,
      title: 'Could not check remaining-ink counts',
      action: () async {
        check = await c.prepareInkReset();
      },
      error: () => c.lastError,
      help: networkRequirement,
    );
    if (!ready) return;
    final fresh = check;
    if (fresh == null || !context.mounted) return;
    final selected = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _InkRefillDialog(check: fresh),
    );
    if (selected == null || !context.mounted) return;
    await printerAction(
      context,
      title: 'Remaining-ink reset did not complete',
      action: () => c.resetInkCounts(fresh, selected, filledToUpperLine: true),
      error: () => c.lastError,
      help: networkRequirement,
      mayHaveSentCommand: true,
    );
  }

  Future<void> networkAction(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    await printerAction(
      context,
      title: 'Could not connect to the network printer',
      action: action,
      error: () => c.networkError,
      help: networkRequirement,
    );
  }

  Future<void> findNetworkPrinter(BuildContext context) async {
    await printerAction(
      context,
      title: 'No reachable network printer found',
      action: c.discover,
      error: () => c.networkError.isNotEmpty
          ? c.networkError
          : c.networkOnline
          ? ''
          : 'No reachable network printer was found. Try Add by address if automatic discovery is unavailable.',
      help: networkRequirement,
    );
  }

  Future<void> refillHelp(BuildContext context, NetworkStatus s) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('After an ink refill'),
          content: SizedBox(
            width: 490,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'The printer tracks estimated ink use. Adding ink does not necessarily update its remaining-ink count.',
                  ),
                  const SizedBox(height: 16),
                  if (s.model.toLowerCase().contains('canon g7000') &&
                      s.firmware == '1.050') ...[
                    const Text(
                      'In Pixma Fixa',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Close this guide and choose Reset ink counts in the ink panel. Select the refilled colors and confirm their tanks are at the upper line. The app verifies the result with the printer.',
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (s.model.toLowerCase().contains('g7000') ||
                      s.model.toLowerCase().contains('g7020')) ...[
                    const Text(
                      'Using the G7020 printer controls',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '1. Press Setup on the printer.\n\n'
                      '2. Select Ink level monitor with the arrow buttons, then press OK.\n\n'
                      '3. Choose Reset ink lev. count and press OK.\n\n'
                      '4. Choose all colors only if every tank is filled to the upper line. Otherwise, follow the individual color prompts and confirm only the colors you refilled.',
                    ),
                    const SizedBox(height: 12),
                    const SelectableText(
                      'Canon instructions: support.usa.canon.com/kb/s/article/ART175839',
                      style: TextStyle(fontSize: 12),
                    ),
                  ] else
                    const Text(
                      'Follow your printer’s instructions for resetting the remaining-ink count. Confirm a color only when its tank has been refilled to the specified upper line.',
                    ),
                  const SizedBox(height: 16),
                  const Text(
                    'This is separate from the waste-ink absorber counter. This guide does not send a reset command. After completing the steps on the printer, close this guide and use Refresh now.',
                  ),
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

  Widget capabilities(BuildContext context, NetworkStatus s) {
    final p = colors(context);
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: SectionLabel('Reported capabilities')),
              TextButton.icon(
                onPressed: c.busy || !c.networkOnline
                    ? null
                    : c.saveNetworkSnapshot,
                icon: const Icon(Icons.save_alt, size: 16),
                label: const Text('Save snapshot'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          property(
            context,
            'Two-sided printing',
            s.duplex
                ? 'Supported'
                : s.texts('sides-supported').isEmpty
                ? 'Not reported'
                : 'Not advertised',
          ),
          property(
            context,
            'Paper sizes',
            s.texts('media-supported').isEmpty
                ? 'Not reported'
                : '${s.texts('media-supported').length} advertised sizes',
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Printer details'),
                content: SizedBox(
                  width: 640,
                  height: 420,
                  child: SingleChildScrollView(
                    child: SelectableText(
                      s.exportText(),
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
            child: const Text('View all reported details'),
          ),
          Text(
            'Manage stuck jobs in Queues and run printer check patterns in Maintenance.',
            style: TextStyle(fontSize: 12, color: p.muted, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget property(BuildContext context, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 13, color: colors(context).muted),
          ),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );

  Color supplyColor(String hex, CareColors p) {
    if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) return p.accent;
    final value = int.parse(hex.substring(1), radix: 16);
    // Preserve a visible black supply bar on dark surfaces.
    return value == 0 && p == CareColors.dark
        ? const Color(0xffc1c7cd)
        : Color(0xff000000 | value);
  }

  Future<void> addAddress(BuildContext context) async {
    final input = TextEditingController();
    final address = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Connect to a printer'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Use this if automatic discovery is blocked on your network.',
                style: TextStyle(fontSize: 14, height: 1.5),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: input,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'IP address or printer hostname',
                  hintText: '192.168.1.50 or ipp://printer.local/ipp/print',
                ),
                onSubmitted: (v) => Navigator.pop(ctx, v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, input.text),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    // The route finishes its exit animation before the editing controller is disposed.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    input.dispose();
    if (address != null && address.trim().isNotEmpty && context.mounted) {
      await networkAction(context, () => c.connectAddress(address));
    }
  }
}

class _InkRefillDialog extends StatefulWidget {
  final InkResetCheck check;
  const _InkRefillDialog({required this.check});
  @override
  State<_InkRefillDialog> createState() => _InkRefillDialogState();
}

class _InkRefillDialogState extends State<_InkRefillDialog> {
  final selected = <String>{};
  bool filled = false;
  @override
  Widget build(BuildContext context) {
    final available = inkNames.keys
        .where(
          (c) =>
              widget.check.counters.levels[c] != null &&
              widget.check.counters.levels[c] != 100,
        )
        .toSet();
    return AlertDialog(
      title: const Text('Reset remaining-ink counts'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.check.identity.model} · Firmware ${widget.check.identity.firmware}',
                style: TextStyle(color: colors(context).muted, fontSize: 13),
              ),
              const SizedBox(height: 16),
              const Text(
                'Uses Wi-Fi or Ethernet in normal mode; USB and service mode are not needed. Choose the tanks you refilled to the upper line. Their remaining-ink counts will be reset to full.',
              ),
              const SizedBox(height: 8),
              if (available.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() {
                    if (selected.containsAll(available)) {
                      selected.clear();
                    } else {
                      selected.addAll(available);
                    }
                  }),
                  child: Text(
                    selected.containsAll(available)
                        ? 'Clear selection'
                        : 'Select all refilled colors',
                  ),
                ),
              for (final entry in inkNames.entries)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(entry.value),
                  subtitle: Text(
                    widget.check.counters.levels[entry.key] == 100
                        ? 'Already reports full'
                        : widget.check.counters.levels[entry.key] == null
                        ? 'Count not reported'
                        : 'Stored estimate: ${widget.check.counters.levels[entry.key]}%',
                  ),
                  value: selected.contains(entry.key),
                  onChanged: available.contains(entry.key)
                      ? (value) => setState(() {
                          if (value == true) {
                            selected.add(entry.key);
                          } else {
                            selected.remove(entry.key);
                          }
                        })
                      : null,
                ),
              const Divider(),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: filled,
                onChanged: (value) => setState(() => filled = value == true),
                title: const Text(
                  'The selected tanks are filled to the upper line.',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'The app reads the counts back after resetting. This does not reset the waste-ink absorber counter.',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  color: colors(context).muted,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: filled && selected.isNotEmpty
              ? () => Navigator.pop(context, {...selected})
              : null,
          child: const Text('Reset selected counts'),
        ),
      ],
    );
  }
}

extension on String {
  String? get nonEmpty => isEmpty ? null : this;
}
