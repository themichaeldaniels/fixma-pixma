import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'controller.dart';
import 'components.dart';
import 'theme.dart';
import 'overview.dart';
import 'maintenance.dart';
import 'queue_view.dart';
import 'diagnostics_view.dart';
import 'platform/appearance.dart';
import 'platform/save_report.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final smoke = arguments
      .where((v) => v.startsWith('--smoke-output='))
      .firstOrNull;
  final proof = arguments
      .where((v) => v.startsWith('--network-proof='))
      .firstOrNull;
  final diagnosticsProof = arguments
      .where((v) => v.startsWith('--diagnostics-proof='))
      .firstOrNull;
  final serviceProof = arguments
      .where((v) => v.startsWith('--service-proof='))
      .firstOrNull;
  final controller = CareController(
    directory:
        smoke == null &&
            proof == null &&
            diagnosticsProof == null &&
            serviceProof == null
        ? null
        : Directory.systemTemp.createTempSync('printer-care-launch-'),
  );
  var initialized = true;
  try {
    await controller.initialize(scan: false);
  } catch (e) {
    initialized = false;
    controller.lastError =
        'Could not open local application data. ${CareController.cleanError(e)}';
  }
  runApp(
    PrinterCare(
      controller: controller,
      initialPage: serviceProof != null
          ? 3
          : diagnosticsProof != null
          ? 6
          : 0,
    ),
  );
  if (!initialized) return;
  if (serviceProof != null) {
    // Explicit hardware diagnostic mode. A zero-counter reset is checked only
    // through the controller guard; no nonzero reset is ever invoked here.
    await controller.diagnose();
    final r = controller.report;
    final output = serviceProof.substring('--service-proof='.length);
    String? blocked;
    if (r != null && r.waste == 0 && controller.liveValid) {
      controller.setServiced(true);
      await controller.reset();
      blocked = controller.lastError;
    }
    final forbidden = controller.history.any(
      (h) => h['counterClearAttempted'] == true,
    );
    await File('$output.txt')
        .writeAsString(controller.exportText(), flush: true);
    await File(output).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': '0.8.1',
        'nativeLaunch': true,
        'report': r?.toJson(),
        'diagnosticCompleted': r != null && controller.liveValid && !r.sample,
        'historySaved': controller.history.any(
          (h) => h['kind'] == 'diagnostic' && h['status'] == 'Completed',
        ),
        'zeroCounterResetBlocked': blocked?.contains('already at zero') == true,
        'resetBlockReason': blocked,
        'counterClearAttempted': forbidden,
        'error': r == null ? controller.lastError : null,
        'isolatedDirectory': controller.directory.path,
      }),
      flush: true,
    );
    controller.dispose();
    exit(0);
  }
  await controller.discover();
  controller.startMonitoring();
  if (diagnosticsProof != null) {
    await controller.checkConnections();
    final output = diagnosticsProof.substring('--diagnostics-proof='.length);
    await File(output).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': '0.8.1',
        'nativeLaunch': true,
        'error': controller.lastError,
        'checks': controller.connectionChecks.map((v) => v.toJson()).toList(),
        'identity': controller.diagnosticIdentity?.toJson(),
        'usage': controller.canonUsage?.toJson(),
        'networkState': controller.networkStatus?.stateLabel,
        'usbInterfaces': controller.devices
            .map(
              (d) => {
                'service': d['service'],
                'product': d['path'].toString().contains('pid_12fe')
                    ? 'service'
                    : 'normal or unknown',
              },
            )
            .toList(),
        'printingStarted': false,
        'maintenanceStarted': false,
        'resetsSent': 0,
      }),
      flush: true,
    );
    await File('$output.public.json')
        .writeAsString(controller.diagnosticSummary(), flush: true);
    controller.dispose();
    exit(0);
  }
  if (proof != null) {
    final first = controller.networkStatus?.toJson();
    final deadline = DateTime.now().add(const Duration(seconds: 35));
    while (controller.successfulNetworkReads < 2 &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await controller.saveNetworkSnapshot();
    final restored = CareController(directory: controller.directory);
    await restored.initialize(scan: false);
    await restored.refreshNetwork();
    final proofPath = proof.substring('--network-proof='.length);
    await File('$proofPath.txt')
        .writeAsString(controller.exportText(), flush: true);
    await File(proofPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'freshInstall': true,
        'discovery': controller.networkPrinters.map((p) => p.toJson()).toList(),
        'firstReading': first,
        'automaticRefreshReads': controller.successfulNetworkReads,
        'latestReading': controller.networkStatus?.toJson(),
        'snapshotSaved': controller.history.any(
          (h) => h['kind'] == 'network snapshot',
        ),
        'restoredSelection': restored.selectedPrinter?.toJson(),
        'restoredOnline': restored.networkOnline,
        'restoredFirmware': restored.networkStatus?.firmware,
        'error': controller.networkError,
        'counterCommandsSent': 0,
        'printJobsSubmitted': 0,
      }),
      flush: true,
    );
    restored.dispose();
    if (smoke == null) {
      controller.dispose();
      exit(0);
    }
  }
  if (smoke != null) {
    await WidgetsBinding.instance.endOfFrame.timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );
    await File(smoke.substring('--smoke-output='.length)).writeAsString(
      jsonEncode({
        'launched': true,
        'theme': controller.themeMode.name,
        'usbInterfaces': controller.devices.length,
        'serviceInterfaces': controller.devices
            .where((d) => d['service'] == true)
            .length,
        'error': controller.lastError,
        'counterCommandsSent': false,
        'discoveredPrinters': controller.networkPrinters
            .map((p) => p.toJson())
            .toList(),
        'networkStatus': controller.networkStatus?.toJson(),
        'networkError': controller.networkError,
      }),
      flush: true,
    );
    controller.dispose();
    exit(0);
  }
}

class PrinterCare extends StatefulWidget {
  final CareController controller;
  final bool nativeFrame;
  final int initialPage;
  const PrinterCare({
    super.key,
    required this.controller,
    this.nativeFrame = true,
    this.initialPage = 0,
  });
  @override
  State<PrinterCare> createState() => _PrinterCareState();
}

class _PrinterCareState extends State<PrinterCare> with WidgetsBindingObserver {
  int page = 0;
  int diagnosticTab = 0;
  late final TextEditingController ipInput;
  CareController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    page = widget.initialPage;
    ipInput = TextEditingController(text: c.ip);
    WidgetsBinding.instance.addObserver(this);
    c.addListener(changed);
  }

  void changed() {
    if (mounted) {
      if (ipInput.text.isEmpty && c.ip.isNotEmpty) ipInput.text = c.ip;
      setState(() {});
    }
  }

  @override
  void didChangePlatformBrightness() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ipInput.dispose();
    c.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark =
        c.themeMode == ThemeMode.dark ||
        (c.themeMode == ThemeMode.system &&
            WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                Brightness.dark);
    if (widget.nativeFrame) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setWindowsDarkFrame(dark);
      });
    }
    return MaterialApp(
      title: 'Printer Care',
      debugShowCheckedModeBanner: false,
      theme: careTheme(Brightness.light),
      darkTheme: careTheme(Brightness.dark),
      themeMode: c.themeMode,
      home: Builder(
        builder: (context) => Scaffold(
          body: LayoutBuilder(
            builder: (context, constraints) {
              return Column(
                children: [
                  header(context),
                  navigation(context),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1220),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (c.busy) busyPanel(context),
                              if (c.message.isNotEmpty ||
                                  c.lastError.isNotEmpty)
                                notice(context),
                              if (page == 0)
                                PrinterOverview(
                                  controller: c,
                                  openService: () => setState(() => page = 3),
                                ),
                              if (page == 3) overview(context),
                              if (page == 1) maintenance(context),
                              if (page == 2) history(context),
                              if (page == 4) QueueView(controller: c),
                              if (page == 6)
                                DiagnosticsView(
                                  key: ValueKey(diagnosticTab),
                                  controller: c,
                                  initialTab: diagnosticTab,
                                  serviceGuide: () => instructions(context),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    decoration: BoxDecoration(
                      color: colors(context).rail,
                      border: Border(
                        top: BorderSide(color: colors(context).line),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.usb, size: 14, color: colors(context).muted),
                        const SizedBox(width: 7),
                        Text(
                          c.busy
                              ? 'Working…'
                              : c.networkOnline
                              ? 'Connected · Local network'
                              : 'USB and local network',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors(context).muted,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          'Local device access     |     Version 0.8.1',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors(context).muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget navigation(BuildContext context) {
    final p = colors(context);
    return Container(
      height: 43,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: p.panel,
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final (i, label, icon) in [
              (0, 'Overview', Icons.print_outlined),
              (4, 'Queues', Icons.list_alt_outlined),
              (3, 'Service report', Icons.description_outlined),
              (1, 'Maintenance', Icons.build_outlined),
              (2, 'History', Icons.history),
              (6, 'Diagnostics', Icons.monitor_heart_outlined),
            ])
              Semantics(
                button: true,
                selected: page == i,
                child: InkWell(
                  onTap: () => setState(() => page = i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: page == i ? p.accent : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          icon,
                          size: 17,
                          color: page == i ? p.accent : p.muted,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: page == i
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: page == i ? p.ink : p.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget header(BuildContext context) {
    final p = colors(context);
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: Row(
        children: [
          Icon(Icons.print_outlined, size: 22, color: p.accent),
          const SizedBox(width: 10),
          const Text(
            'Printer Care',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 18),
          Container(width: 1, height: 20, color: p.line),
          const SizedBox(width: 18),
          Text(
            'Printer diagnostics',
            style: TextStyle(fontSize: 13, color: p.muted),
          ),
          const Spacer(),
          if (c.report != null || c.networkStatus != null)
            TextButton.icon(
              onPressed: c.busy ? null : () => export(context),
              icon: const Icon(Icons.file_download_outlined, size: 18),
              label: const Text('Export report'),
            ),
          const SizedBox(width: 12),
          Container(height: 28, width: 1, color: p.line),
          const SizedBox(width: 12),
          PopupMenuButton<ThemeMode>(
            tooltip: 'Appearance',
            initialValue: c.themeMode,
            onSelected: c.setTheme,
            itemBuilder: (_) => [
              for (final (mode, label, icon) in [
                (
                  ThemeMode.system,
                  'Follow device',
                  Icons.brightness_auto_outlined,
                ),
                (ThemeMode.light, 'Light', Icons.light_mode_outlined),
                (ThemeMode.dark, 'Dark', Icons.dark_mode_outlined),
              ])
                PopupMenuItem(
                  value: mode,
                  child: Row(
                    children: [
                      Icon(icon, size: 18),
                      const SizedBox(width: 12),
                      Text(label),
                      const SizedBox(width: 20),
                      if (c.themeMode == mode)
                        const Icon(Icons.check, size: 17),
                    ],
                  ),
                ),
            ],
            child: Semantics(
              button: true,
              label: 'Appearance: ${c.themeMode.name}',
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(
                      switch (c.themeMode) {
                        ThemeMode.system => Icons.brightness_auto_outlined,
                        ThemeMode.light => Icons.light_mode_outlined,
                        ThemeMode.dark => Icons.dark_mode_outlined,
                      },
                      size: 20,
                      color: p.ink,
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.keyboard_arrow_down, size: 16),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget busyPanel(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Panel(
      child: Row(
        children: [
          SizedBox(
            width: 19,
            height: 19,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors(context).accent,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              c.progress.isEmpty ? 'Looking for your printer…' : c.progress,
            ),
          ),
          TextButton(
            onPressed: c.activePeer == null ? null : c.stop,
            child: const Text('Stop waiting'),
          ),
        ],
      ),
    ),
  );
  Widget notice(BuildContext context) {
    final p = colors(context), error = c.lastError.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: error ? p.warning.withValues(alpha: .08) : p.tint,
          border: Border.all(
            color: error ? p.warning.withValues(alpha: .35) : p.line,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              error ? Icons.info_outline : Icons.check_circle_outline,
              color: error ? p.warning : p.accent,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                error ? c.lastError : c.message,
                style: const TextStyle(height: 1.6, fontSize: 13.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget pageTitle(BuildContext context, String title, String description) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 24,
                letterSpacing: -.2,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              description,
              style: TextStyle(
                fontSize: 14,
                height: 1.6,
                color: colors(context).muted,
              ),
            ),
          ],
        ),
      );
  Widget overview(BuildContext context) {
    final p = colors(context), r = c.report;
    final service = c.devices.any((d) => d['service'] == true);
    final state = r?.sample == true
        ? 'Sample report'
        : service
        ? 'Service mode detected'
        : c.devices.isNotEmpty
        ? 'Normal mode detected'
        : 'Waiting for USB';
    final device = Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('Device information'),
          const SizedBox(height: 16),
          for (final (label, value) in [
            (
              'Model',
              r != null
                  ? 'Canon G7000 series${r.sample ? ' · sample' : ''}'
                  : c.networkStatus?.model ?? 'Not identified',
            ),
            (
              'Service family',
              r != null ? 'G7000 series' : 'Run diagnostics to identify',
            ),
            ('Firmware', r?.firmware ?? 'Not read'),
            ('Serial number', r?.serial ?? 'Not read'),
            (
              'Connection',
              r?.sample == true
                  ? 'Sample data'
                  : service
                  ? 'USB / Service mode'
                  : c.devices.isNotEmpty
                  ? 'USB / Normal mode'
                  : 'Not connected',
            ),
          ]) ...[
            Text(label, style: TextStyle(fontSize: 12, color: p.muted)),
            const SizedBox(height: 3),
            SelectableText(
              value,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 17),
          ],
          Divider(height: 1, color: p.line),
          const SizedBox(height: 13),
          TextButton.icon(
            onPressed: () => instructions(context),
            icon: const Icon(Icons.help_outline, size: 16),
            label: const Text('Service mode guide'),
          ),
        ],
      ),
    );
    final report = r == null
        ? Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionLabel('Service report'),
                const SizedBox(height: 22),
                const Text(
                  'No diagnostic report',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Put the printer in service mode, connect its USB cable, then run diagnostics to read the waste counter and usage records.',
                  style: TextStyle(fontSize: 14, height: 1.6, color: p.muted),
                ),
                const SizedBox(height: 22),
                OutlinedButton.icon(
                  onPressed: c.busy ? null : c.sample,
                  icon: const Icon(Icons.description_outlined, size: 17),
                  label: const Text('Open sample report'),
                ),
              ],
            ),
          )
        : Panel(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 13, 12, 13),
                  child: Row(
                    children: [
                      const Expanded(child: SectionLabel('Service report')),
                      Text(
                        'Captured ${date(r.capturedAt)}',
                        style: TextStyle(fontSize: 12, color: p.muted),
                      ),
                      const SizedBox(width: 12),
                      TextButton(
                        onPressed: () => rawReport(context),
                        child: const Text('View full report'),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: p.tint.withValues(alpha: .6),
                    border: Border(
                      top: BorderSide(color: p.line),
                      bottom: BorderSide(color: p.line),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Waste-ink counter',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            '${r.waste?.toStringAsFixed(1) ?? ' - '}%',
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      LinearProgressIndicator(
                        value: r.waste == null
                            ? 0
                            : (r.waste! / 100).clamp(0, 1),
                        minHeight: 4,
                        color: p.accent,
                        backgroundColor: p.line,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Firmware estimate of absorber use; not a physical ink measurement.',
                        style: TextStyle(fontSize: 12.5, color: p.muted),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionLabel('Usage records'),
                      const SizedBox(height: 8),
                      detail(context, 'Printed pages', number(r.pages)),
                      detail(context, 'Recorded copies', number(r.copies)),
                      detail(
                        context,
                        'Pages from front cassette',
                        number(r.frontPages),
                      ),
                      detail(
                        context,
                        'Pages from rear feed',
                        number(r.rearPages),
                      ),
                      detail(
                        context,
                        'Recorded counter resets',
                        r.resetCount?.toString() ?? ' - ',
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionLabel('Stored error history'),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final code in r.errorCodes.toSet())
                            BadgeLabel(code, warning: code == '5B00'),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Historical entries may remain after repair. These are not the current printer status.',
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.5,
                          color: p.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        pageTitle(
          context,
          'G7020 service diagnostics',
          'Read the G7000 USB service profile. Network status is available on Overview.',
        ),
        Panel(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Canon PIXMA G7020',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    BadgeLabel(state, warning: r?.sample == true),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: c.busy ? null : c.discover,
                icon: const Icon(Icons.refresh, size: 17),
                label: const Text('Find printer'),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: c.busy ? null : c.diagnose,
                icon: const Icon(Icons.manage_search, size: 18),
                label: const Text('Run diagnostics'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, box) => box.maxWidth < 720
              ? Column(children: [report, const SizedBox(height: 20), device])
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 236, child: device),
                    const SizedBox(width: 20),
                    Expanded(child: report),
                  ],
                ),
        ),
      ],
    );
  }

  Widget detail(BuildContext context, String label, String value) {
    final p = colors(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: p.line.withValues(alpha: .65)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(color: p.muted, fontSize: 14)),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget maintenanceSection(
    BuildContext context,
    String title,
    String note,
    Widget content,
  ) {
    final p = colors(context);
    return Padding(
      padding: const EdgeInsets.all(22),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 200,
            child: Padding(
              padding: const EdgeInsets.only(right: 26),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    note,
                    style: TextStyle(fontSize: 13, color: p.muted, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
          Expanded(child: content),
        ],
      ),
    );
  }

  Widget maintenance(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        pageTitle(
          context,
          'Printer maintenance',
          'Check print quality, clean the printhead, and adjust Canon settings.',
        ),
        CanonMaintenancePanel(controller: c),
        const SizedBox(height: 24),
        Panel(
          padding: EdgeInsets.zero,
          child: Material(
            color: Colors.transparent,
            child: ExpansionTile(
              title: const Text(
                'Waste-ink absorber',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Advanced · USB service mode',
                style: TextStyle(fontSize: 13),
              ),
              childrenPadding: const EdgeInsets.all(20),
              children: [wasteMaintenance(context)],
            ),
          ),
        ),
      ],
    );
  }

  Widget wasteMaintenance(BuildContext context) {
    final p = colors(context), r = c.report;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        pageTitle(
          context,
          'Waste-counter reset',
          'Read a current report, confirm absorber servicing, then reset the counter.',
        ),
        Panel(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              maintenanceSection(
                context,
                '1. Read the printer',
                'Requires a USB connection in service mode.',
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Run a fresh diagnostic to verify the model, firmware, and current counter.',
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: c.busy ? null : c.diagnose,
                          icon: const Icon(Icons.manage_search, size: 18),
                          label: const Text('Run diagnostics'),
                        ),
                        TextButton(
                          onPressed: () => instructions(context),
                          child: const Text('Enter service mode'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: p.line),
              maintenanceSection(
                context,
                '2. Reset the counter',
                'The counter is a software estimate of absorber use.',
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'Waste-ink absorber',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 14),
                        if (r != null)
                          BadgeLabel(
                            '${r.waste?.toStringAsFixed(1) ?? ' - '}%${r.sample ? ' · sample' : ''}',
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Clean or replace the absorber before resetting its counter.',
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: c.serviced,
                      onChanged: c.busy || r == null || r.sample
                          ? null
                          : (v) => c.setServiced(v ?? false),
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text(
                        'The ink absorber has been serviced.',
                        style: TextStyle(fontSize: 14),
                      ),
                    ),
                    const SizedBox(height: 6),
                    FilledButton.icon(
                      onPressed: c.busy || c.resetBlocked != null
                          ? null
                          : () => confirmReset(context),
                      icon: const Icon(Icons.restart_alt, size: 18),
                      label: const Text('Reset waste counter'),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      c.resetBlocked ?? 'Ready for one reset attempt. The attempt is recorded before sending the command.',
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: p.line),
              maintenanceSection(
                context,
                '3. Verify after restart',
                'Complete this step at the printer.',
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'After an acknowledged reset, shut down with Power and start normally. Confirm the display is clear and try a normal print.',
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: ipInput,
                            onChanged: (v) => c.ip = v,
                            decoration: const InputDecoration(
                              labelText: 'Printer IP address (optional)',
                              hintText: '192.168.1.50',
                              prefixIcon: Icon(Icons.lan_outlined, size: 18),
                              isDense: true,
                            ),
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton(
                          onPressed: c.busy
                              ? null
                              : () => c.verify(ipInput.text),
                          child: const Text('Check status'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget history(BuildContext context) {
    final p = colors(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        pageTitle(
          context,
          'Service history',
          'Diagnostics and reset attempts are saved on this computer.',
        ),
        if (c.repairs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: OutlinedButton.icon(
              onPressed: () => setState(() {
                diagnosticTab = 1;
                page = 6;
              }),
              icon: const Icon(Icons.fact_check_outlined, size: 18),
              label: Text(
                'Repair follow-ups · ${c.repairs.where((r) => !r.verified).length} pending',
              ),
            ),
          ),
        Panel(
          child: c.history.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 44),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(Icons.history_rounded, size: 36, color: p.accent),
                        const SizedBox(height: 18),
                        const Text(
                          'No saved reports',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Run a diagnostic to save your first report.',
                          style: TextStyle(color: p.muted),
                        ),
                      ],
                    ),
                  ),
                )
              : Column(
                  children: [
                    for (final entry in c.history)
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 10,
                        ),
                        leading: Icon(
                          entry['kind'] == 'reset'
                              ? Icons.restart_alt
                              : Icons.description_outlined,
                          color: p.accent,
                        ),
                        title: Text(
                          entry['kind'] == 'reset'
                              ? 'Counter reset'
                              : entry['kind'] == 'diagnostic'
                              ? 'Diagnostic report'
                              : entry['kind'] == 'ink refill reset'
                              ? 'Ink refill reset'
                              : entry['kind'] == 'network snapshot'
                              ? 'Printer status snapshot'
                              : entry['kind'] == 'connection checks'
                              ? 'Connection checks'
                              : entry['kind'] == 'repair verification'
                              ? 'Repair verification'
                              : entry['kind'] == 'restart check'
                              ? 'Restart status check'
                              : entry['kind'] as String,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 7),
                          child: Text(
                            date(DateTime.parse(entry['started'] as String)),
                            style: TextStyle(fontSize: 12, color: p.muted),
                          ),
                        ),
                        trailing: BadgeLabel(
                          entry['status'] as String,
                          warning: entry['status'] == 'Stopped',
                        ),
                        onTap: () => showDialog<void>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Service record'),
                            content: SizedBox(
                              width: 600,
                              child: SingleChildScrollView(
                                child: SelectableText(
                                  '${entry['kind']} · ${entry['status']}\n\n${entry['error'] ?? 'Operation completed.'}\n${entry['beforeCounter'] != null ? 'Before: ${entry['beforeCounter']}%\nAfter: ${entry['afterCounter'] ?? 'Unverified'}%' : ''}${entry['kind'] == 'ink refill reset' ? '\nSelected: ${(entry['selectedColors'] as List?)?.join(', ') ?? 'Not recorded'}\nBefore: ${(entry['before'] as Map?)?['levels'] ?? 'Not read'}\nAfter: ${(entry['after'] as Map?)?['levels'] ?? 'Not verified'}\nReadback verified: ${entry['verified'] == true ? 'Yes' : 'No'}' : ''}\n\n${entry['network'] != null ? const JsonEncoder.withIndent('  ').convert(entry['network']) : (entry['report'] as Map?)?['raw'] ?? 'The detailed exchange is retained in the local history file.'}',
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
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 20),
        Text(
          'Stored in ${c.directory.path}',
          style: TextStyle(fontSize: 12, height: 1.6, color: p.muted),
        ),
      ],
    );
  }

  Future<void> export(BuildContext context) async {
    try {
      final path = saveReportPath();
      if (path != null) {
        await File(path).writeAsString(c.exportText(), flush: true);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Service report saved.')),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(CareController.cleanError(e))));
      }
    }
  }

  Future<void> confirmReset(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset this printer’s counter?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            'Canon PIXMA G7020\n${c.report!.serial}\n\nThe current software counter is ${c.report!.waste!.toStringAsFixed(1)}%. One clear command will be sent after a fresh connection check.\n\nKeep USB connected and leave the printer powered on until the result appears.',
            style: const TextStyle(height: 1.7),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset counter'),
          ),
        ],
      ),
    );
    if (confirmed == true) await c.reset();
  }

  Future<void> instructions(BuildContext context) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Enter service mode'),
      content: const SizedBox(
        width: 440,
        child: Text(
          'For the verified PIXMA G7020 procedure:\n\n1. Connect USB and turn the printer off.\n2. Hold Power.\n3. While holding Power, press Stop six times.\n4. Release Power and let the mechanism settle.\n\nThe LCD should be black. Run diagnostics when it is ready. The diagnostic reads a report over USB; it does not request a printed page.',
          style: TextStyle(height: 1.8),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Done'),
        ),
      ],
    ),
  );
  Future<void> rawReport(BuildContext context) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(
        c.report!.sample ? 'Sample service report' : 'Service report',
      ),
      content: SizedBox(
        width: 660,
        height: 420,
        child: SingleChildScrollView(
          child: SelectableText(
            c.report!.raw,
            style: const TextStyle(
              fontFamily: 'Consolas',
              fontSize: 12,
              height: 1.6,
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
  );
}
