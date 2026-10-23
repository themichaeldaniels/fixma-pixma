/// Feature evidence is independent of protocol discovery. A candidate profile
/// never grants a maintenance command; transport allowlists remain authoritative.
class ModelSupport {
  final String family, label, firmware, note;
  final bool verified;
  final List<(String, String)> features;
  const ModelSupport(
    this.family,
    this.label,
    this.firmware,
    this.note,
    this.verified,
    this.features,
  );

  static const profiles = [
    ModelSupport(
      'G7000 series',
      'Canon PIXMA G7020 / G7000 series',
      '1.050',
      'Validated on the connected G7020. Family names alone do not prove compatibility with every regional model.',
      true,
      [
        ('Identity, firmware, ink estimates', 'Hardware verified'),
        ('Page and head replacement counters', 'Read-only firmware counters'),
        ('Remaining-ink reset', 'Hardware verified'),
        ('Standard cleaning and five settings', 'Hardware verified'),
        ('Nozzle and alignment checks', 'Both sheets physically verified'),
        ('Windows queue cancellation', 'Held Canon spool job verified'),
        (
          'Network queues',
          'Listing verified; zero-document cancellation acknowledged',
        ),
        (
          'Waste-counter protocol',
          'Physical reset verified; native USB report and guards verified',
        ),
        ('Full EEPROM backup', 'Command unresolved'),
      ],
    ),
    ModelSupport(
      'G6000 series',
      'Canon PIXMA G6020 / G6000 series',
      '1.070',
      'Upstream research candidate. No service or reset commands enabled by this profile.',
      false,
      [
        (
          'Upstream waste-counter reset',
          'Reported validated on upstream G6020',
        ),
        ('Printer Care support', 'Hardware validation required'),
        ('Full EEPROM backup', 'Upstream command unresolved'),
      ],
    ),
  ];

  static ModelSupport? find(String model) {
    final normalized = model.trim().replaceFirst(
      RegExp(r'^Canon\s+', caseSensitive: false),
      '',
    );
    return profiles
        .where(
          (p) =>
              p.family.toLowerCase() == normalized.toLowerCase() ||
              (p.verified && normalized.toUpperCase() == 'PIXMA G7020') ||
              (!p.verified && normalized.toUpperCase() == 'PIXMA G6020'),
        )
        .firstOrNull;
  }

  bool matchesFirmware(String version) => verified && version == firmware;
  static String usbProduct(String path) =>
      RegExp(
        r'pid_([0-9a-f]{4})',
        caseSensitive: false,
      ).firstMatch(path)?.group(1)?.toUpperCase() ??
      'Unknown';
}

class ConnectionCheck {
  final String area, status, detail;
  final bool attention;
  const ConnectionCheck(
    this.area,
    this.status,
    this.detail, {
    this.attention = false,
  });
  Map<String, dynamic> toJson() => {
    'area': area,
    'status': status,
    'detail': detail,
    'attention': attention,
  };
}

List<ConnectionCheck> usbChecks(
  List<Map<String, dynamic>> devices,
  Set<String>? baseline,
  String error,
) {
  final checks = <ConnectionCheck>[];
  if (error.isNotEmpty) {
    checks.add(
      ConnectionCheck('Windows USB', 'Unavailable', error, attention: true),
    );
    return checks;
  }
  final service = devices.where((d) => d['service'] == true).length;
  checks.add(
    ConnectionCheck(
      'Windows USB',
      devices.isEmpty
          ? 'No Canon USB printer found'
          : '${devices.length} Canon interface(s)',
      'This check lists Windows printer interfaces. It does not change drivers or enter service mode.',
      attention: devices.isEmpty,
    ),
  );
  checks.add(
    ConnectionCheck(
      'Service connection',
      service == 1
          ? 'Service identity detected'
          : service > 1
          ? 'Multiple service printers'
          : 'Normal mode or disconnected',
      service == 1
          ? 'The shared service USB identity is present. Run diagnostics to verify the model before any service operation.'
          : service > 1
          ? 'Connect one service-mode Canon at a time.'
          : 'Normal mode is correct for network maintenance. For service diagnostics, use the model-specific Power and Stop procedure, then check again.',
      attention: service > 1,
    ),
  );
  if (baseline != null) {
    final now = devices.map((d) => d['path'] as String).toSet();
    final added = now.difference(baseline).length,
        removed = baseline.difference(now).length;
    checks.add(
      ConnectionCheck(
        'USB identity change',
        added + removed == 0
            ? 'No change since baseline'
            : '$added added · $removed removed',
        'USB changes are connection evidence; they do not identify a model or prove a repair.',
      ),
    );
  }
  return checks;
}
