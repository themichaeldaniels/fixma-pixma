import 'package:flutter/material.dart';

import 'components.dart';
import 'controller.dart';
import 'core/canon_maintenance.dart';
import 'theme.dart';

class CanonMaintenancePanel extends StatelessWidget {
  final CareController controller;
  const CanonMaintenancePanel({super.key, required this.controller});
  @override
  Widget build(BuildContext context) {
    final c = controller, p = colors(context), check = controller.canonControls;
    final valid = check != null && check.target.key == c.selectedPrinter?.key;
    final enabled = valid && c.canReadCanonControls;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Panel(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      valid ? check.identity.model : 'Canon printer controls',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      valid
                          ? 'Firmware ${check.identity.firmware} · ${check.identity.serial}'
                          : 'Use your printer normally on the local network. Read its controls to begin.',
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                    if (!c.networkOnline)
                      Text(
                        'Select an online printer in Overview.',
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 18),
              OutlinedButton.icon(
                onPressed: c.canReadCanonControls ? c.loadCanonControls : null,
                icon: const Icon(Icons.refresh, size: 17),
                label: Text(
                  valid ? 'Reload controls' : 'Read printer controls',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Panel(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _taskRow(
                context,
                CanonTask.nozzleCheck,
                'Print one sheet to inspect the black grid and color bands.',
                'Print nozzle check',
                enabled,
              ),
              Divider(height: 1, color: p.line),
              _taskRow(
                context,
                CanonTask.cleaning,
                'Run a standard cleaning cycle for all colors. Uses ink; run only when needed.',
                'Clean printhead',
                enabled,
              ),
              Divider(height: 1, color: p.line),
              _taskRow(
                context,
                CanonTask.alignmentCheck,
                'Print the current alignment values on one sheet.',
                'Print alignment check',
                enabled,
              ),
              Divider(height: 1, color: p.line),
              _taskRow(
                context,
                CanonTask.automaticAlignment,
                'Print two sheets and let the printer adjust alignment automatically. Takes about 4 to 5 minutes.',
                'Align printhead',
                enabled,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'After cleaning, print a nozzle check and examine the sheet. Gaps in the black grid or missing color bands can indicate clogged nozzles.',
          style: TextStyle(color: p.muted, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 24),
        const SectionLabel('Printer settings'),
        const SizedBox(height: 10),
        if (!valid)
          Panel(
            child: Text(
              'Read printer controls to view quiet mode, power settings, paper clearance, and drying wait.',
              style: TextStyle(color: p.muted, fontSize: 13, height: 1.5),
            ),
          )
        else
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final key in CanonSettings.allowed.keys) ...[
                  if (key != CanonSettings.allowed.keys.first)
                    Divider(height: 1, color: p.line),
                  _CanonSettingRow(
                    key: ValueKey('${check.checkedAt}-$key'),
                    controller: c,
                    name: key,
                    value: valid ? check.settings.values[key] ?? '' : '',
                    enabled: enabled,
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _taskRow(
    BuildContext context,
    CanonTask task,
    String note,
    String button,
    bool enabled,
  ) {
    final p = colors(context), check = controller.canonControls;
    final supported =
        check?.capabilities.supports(task, letterPaper) == true ||
        check?.capabilities.supports(task, a4Paper) == true;
    final action = OutlinedButton(
      onPressed: enabled && supported ? () => _confirm(context, task) : null,
      child: Text(button),
    );
    return Padding(
      padding: const EdgeInsets.all(20),
      child: LayoutBuilder(
        builder: (context, box) {
          final description = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                task.label,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                note,
                style: TextStyle(color: p.muted, fontSize: 13, height: 1.5),
              ),
            ],
          );
          return box.maxWidth < 620
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [description, const SizedBox(height: 12), action],
                )
              : Row(
                  children: [
                    Expanded(child: description),
                    const SizedBox(width: 24),
                    SizedBox(width: 190, child: action),
                  ],
                );
        },
      ),
    );
  }

  Future<void> _confirm(BuildContext context, CanonTask task) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _TaskDialog(task: task),
    );
    if (result != null) {
      await controller.runCanonTask(task, prepared: true, paper: result);
    }
  }
}

class _TaskDialog extends StatefulWidget {
  final CanonTask task;
  const _TaskDialog({required this.task});
  @override
  State<_TaskDialog> createState() => _TaskDialogState();
}

class _TaskDialogState extends State<_TaskDialog> {
  String paper = letterPaper;
  bool ready = false;
  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    return AlertDialog(
      title: Text(task.label),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                task == CanonTask.automaticAlignment
                    ? 'Load two sheets of plain Letter or A4 paper in the front cassette and open the output tray. The printer will print and read its alignment patterns, then save the adjustment automatically. Allow about 4 to 5 minutes. Leave the printer powered on and do not use it until this finishes.'
                    : task.usesPaper
                    ? 'Load one sheet of plain Letter or A4 paper in the front cassette. Open the output tray. The printer will print its own check pattern.'
                    : 'This runs one standard cleaning cycle for all colors. Leave the printer powered on until it finishes. Cleaning uses ink.',
                style: const TextStyle(fontSize: 14, height: 1.6),
              ),
              if (task.usesPaper) ...[
                const SizedBox(height: 18),
                DropdownButtonFormField<String>(
                  initialValue: paper,
                  decoration: const InputDecoration(
                    labelText: 'Paper in the cassette',
                  ),
                  items: const [
                    DropdownMenuItem(value: letterPaper, child: Text('Letter')),
                    DropdownMenuItem(value: a4Paper, child: Text('A4')),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => paper = v);
                  },
                ),
              ],
              const SizedBox(height: 14),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: ready,
                onChanged: (v) => setState(() => ready = v ?? false),
                title: Text(
                  task == CanonTask.automaticAlignment
                      ? 'Two sheets are loaded, the output tray is open, and the tanks contain enough ink.'
                      : task.usesPaper
                      ? 'The paper and output tray are ready.'
                      : 'I checked that the tanks contain enough ink.',
                  style: const TextStyle(fontSize: 14),
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
          onPressed: ready ? () => Navigator.pop(context, paper) : null,
          child: Text(
            task == CanonTask.automaticAlignment
                ? 'Start alignment'
                : task.usesPaper
                ? 'Print check'
                : 'Start cleaning',
          ),
        ),
      ],
    );
  }
}

class _CanonSettingRow extends StatefulWidget {
  final CareController controller;
  final String name, value;
  final bool enabled;
  const _CanonSettingRow({
    super.key,
    required this.controller,
    required this.name,
    required this.value,
    required this.enabled,
  });
  @override
  State<_CanonSettingRow> createState() => _CanonSettingRowState();
}

class _CanonSettingRowState extends State<_CanonSettingRow> {
  String? selected;
  @override
  Widget build(BuildContext context) {
    final p = colors(context),
        key = widget.name,
        allowed = CanonSettings.allowed[key]!;
    selected ??= widget.value;
    final notes = {
      'quiet': 'Reduce operating noise. Printing may be slower.',
      'autoPowerOn': 'Wake the printer when a print job arrives.',
      'autoPowerOff':
          'Turn off after inactivity. Fax use may keep the printer on.',
      'paperGap': 'Increase printhead clearance if paper rubs or smears.',
      'dryLevel': 'Allow more time for ink to dry between pages.',
    };
    final editor = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 180,
          child: DropdownButtonFormField<String>(
            initialValue: selected,
            isExpanded: true,
            hint: Text(
              CanonSettings.display(key, widget.value),
              style: const TextStyle(fontSize: 13),
            ),
            decoration: InputDecoration(
              isDense: true,
              labelText: CanonSettings.labels[key],
            ),
            items: [
              if (!allowed.contains(widget.value))
                DropdownMenuItem(
                  value: widget.value,
                  enabled: false,
                  child: Text(
                    CanonSettings.display(key, widget.value),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              for (final value in allowed)
                DropdownMenuItem(
                  value: value,
                  child: Text(
                    CanonSettings.display(key, value),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
            ],
            onChanged: widget.enabled
                ? (v) => setState(() => selected = v)
                : null,
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton(
          onPressed:
              widget.enabled &&
                  allowed.contains(selected) &&
                  selected != widget.value
              ? () => widget.controller.saveCanonSetting(key, selected!)
              : null,
          child: const Text('Apply'),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.all(20),
      child: LayoutBuilder(
        builder: (context, box) {
          final description = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                CanonSettings.labels[key]!,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                notes[key]!,
                style: TextStyle(color: p.muted, fontSize: 13, height: 1.5),
              ),
              if (widget.value.isNotEmpty)
                Text(
                  'Current: ${CanonSettings.display(key, widget.value)}',
                  style: TextStyle(color: p.muted, fontSize: 12, height: 1.8),
                ),
            ],
          );
          return box.maxWidth < 670
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [description, const SizedBox(height: 14), editor],
                )
              : Row(
                  children: [
                    Expanded(child: description),
                    const SizedBox(width: 24),
                    editor,
                  ],
                );
        },
      ),
    );
  }
}
