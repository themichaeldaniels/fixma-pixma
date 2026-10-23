class ServiceReport {
  final String raw, serial, firmware;
  final double? waste;
  final int? pages, copies, rearPages, frontPages, resetCount;
  final List<String> errorCodes;
  final DateTime capturedAt;
  final bool sample;
  ServiceReport({
    required this.raw,
    required this.serial,
    required this.firmware,
    required this.waste,
    required this.pages,
    required this.copies,
    required this.rearPages,
    required this.frontPages,
    required this.resetCount,
    required this.errorCodes,
    required this.capturedAt,
    this.sample = false,
  });
  factory ServiceReport.parse(
    String raw, {
    bool sample = false,
    DateTime? capturedAt,
  }) {
    String? match(String p) =>
        RegExp(p, multiLine: true).firstMatch(raw)?.group(1);
    int? count(String p) => int.tryParse(match(p) ?? '');
    if (!raw.contains('G7000') || match(r'SN=([^\s]+)') == null) {
      throw const FormatException('Not a G7000 service report.');
    }
    return ServiceReport(
      raw: raw,
      serial: match(r'SN=([^\s]+)')!,
      firmware: match(r'\bV(\d+\.\d+)') ?? 'Unknown',
      waste: double.tryParse(match(r'^D=([\d.]+)') ?? ''),
      pages: count(r'TPAGE\(TTL=(\d+)'),
      copies: count(r'TPAGE\(TTL=\d+ COPY=(\d+)'),
      rearPages: count(r'ASF PAGE\(ALL=(\d+)'),
      frontPages: count(r'FR PAGE\(ALL=(\d+)'),
      resetCount: count(r'^D CLR=(\d+)'),
      errorCodes: RegExp(r'\bER\d=([A-Fa-f0-9]{4})')
          .allMatches(raw)
          .map((m) => m.group(1)!.toUpperCase())
          .toList(),
      capturedAt: capturedAt ?? DateTime.now(),
      sample: sample,
    );
  }
  Map<String, dynamic> toJson() => {
    'raw': raw,
    'sample': sample,
    'capturedAt': capturedAt.toIso8601String(),
    'serial': serial,
    'firmware': firmware,
    'waste': waste,
    'pages': pages,
  };
  factory ServiceReport.fromJson(Map<String, dynamic> v) => ServiceReport.parse(
    v['raw'] as String,
    sample: v['sample'] as bool? ?? false,
    capturedAt: DateTime.parse(v['capturedAt'] as String),
  );
}
