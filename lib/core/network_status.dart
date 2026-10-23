import 'dart:convert';

class PrinterTarget {
  final Uri uri;
  final String discoveredName;
  final String discoveryId;
  const PrinterTarget(
    this.uri, {
    this.discoveredName = '',
    this.discoveryId = '',
  });
  factory PrinterTarget.parse(String input) {
    final text = input.trim();
    final uri = Uri.tryParse(text.contains('://') ? text : 'ipp://$text');
    if (uri == null ||
        !['ipp', 'ipps'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535)) ||
        !RegExp(r'^[a-zA-Z0-9.:-]+$').hasMatch(uri.host)) {
      throw const FormatException(
        'Enter a printer IP address, hostname, or ipp:// address.',
      );
    }
    return PrinterTarget(
      uri.replace(
        port: uri.hasPort ? uri.port : 631,
        path: uri.path.isEmpty ? '/ipp/print' : uri.path,
      ),
    );
  }
  String get key => uri.toString();
  Map<String, dynamic> toJson() => {
    'uri': key,
    'name': discoveredName,
    'id': discoveryId,
  };
  factory PrinterTarget.fromJson(Map v) => PrinterTarget(
    PrinterTarget.parse(v['uri'] as String).uri,
    discoveredName: v['name'] as String? ?? '',
    discoveryId: v['id'] as String? ?? '',
  );
}

class InkSupply {
  final String name, color, type;
  final int? percent;
  final int? reportedLevel;
  const InkSupply({
    required this.name,
    required this.color,
    required this.type,
    this.percent,
    this.reportedLevel,
  });
  String get levelText => percent != null
      ? '$percent%'
      : reportedLevel == -3
      ? 'Level unknown'
      : 'Not reported';
  Map<String, dynamic> toJson() => {
    'name': name,
    'color': color,
    'type': type,
    'estimatedPercent': percent,
    'reportedLevel': reportedLevel,
  };
}

class PrinterIssue {
  final String title, detail;
  final bool warning;
  const PrinterIssue(this.title, this.detail, {this.warning = false});
  Map<String, dynamic> toJson() => {
    'title': title,
    'detail': detail,
    'warning': warning,
  };
}

class CanonWebStatus {
  final String? supportCode;
  final int? signal;
  final bool scanner, adf;
  const CanonWebStatus({
    this.supportCode,
    this.signal,
    this.scanner = false,
    this.adf = false,
  });
  factory CanonWebStatus.parse(String text) {
    if (!text.contains('g_prndoc')) {
      throw const FormatException('No Canon status information.');
    }
    final code = RegExp(r'\bERR=([A-Za-z0-9]+)')
        .firstMatch(text)
        ?.group(1)
        ?.toUpperCase();
    final signal = int.tryParse(
      RegExp(r'''\bg_signal_strength\s*=\s*['"]?(\d+)''')
              .firstMatch(text)
              ?.group(1) ??
          '',
    );
    return CanonWebStatus(
      supportCode: code == 'NO' ? null : code,
      signal: signal != null && signal >= 0 && signal <= 100 ? signal : null,
      scanner: RegExp(r'\bg_scanner\s*=\s*1\b').hasMatch(text),
      adf: RegExp(r'\bg_adf\s*=\s*1\b').hasMatch(text),
    );
  }
}

class NetworkStatus {
  final PrinterTarget target;
  final DateTime capturedAt;
  final Map<String, List<Object?>> attributes;
  final CanonWebStatus? canon;
  NetworkStatus({
    required this.target,
    required this.attributes,
    this.canon,
    DateTime? capturedAt,
  }) : capturedAt = capturedAt ?? DateTime.now();
  String text(String key) =>
      attributes[key]?.whereType<String>().firstOrNull ?? '';
  List<String> texts(String key) =>
      attributes[key]?.whereType<String>().toList() ?? [];
  String get name => text('printer-name').isNotEmpty
      ? text('printer-name')
      : target.discoveredName.isNotEmpty
      ? target.discoveredName
      : model;
  String get model => text('printer-make-and-model').isNotEmpty
      ? text('printer-make-and-model')
      : 'Network printer';
  String get firmware => text('printer-firmware-string-version').isEmpty
      ? 'Not reported'
      : text('printer-firmware-string-version');
  String get serial => text('printer-serial-number').isEmpty
      ? 'Not reported'
      : text('printer-serial-number');
  String get identity =>
      text('printer-uuid').isNotEmpty ? text('printer-uuid') : target.key;
  int? get state => attributes['printer-state']?.whereType<int>().firstOrNull;
  List<String> get reasons =>
      texts('printer-state-reasons').where((r) => r != 'none').toList();
  bool get duplex =>
      texts('sides-supported').any((s) => s.startsWith('two-sided'));
  List<InkSupply> get supplies {
    final names = texts('marker-names'),
        levels = attributes['marker-levels'] ?? [],
        cols = texts('marker-colors'),
        types = texts('marker-types');
    final count = [names.length, levels.length].reduce((a, b) => a > b ? a : b);
    return List.generate(count, (i) {
      final level = i < levels.length && levels[i] is int
          ? levels[i] as int
          : null;
      return InkSupply(
        name: i < names.length ? names[i] : 'Supply ${i + 1}',
        color: i < cols.length ? cols[i] : '',
        type: i < types.length ? types[i] : '',
        reportedLevel: level,
        percent: level != null && level >= 0 && level <= 100 ? level : null,
      );
    });
  }

  List<PrinterIssue> get issues {
    final result = <PrinterIssue>[];
    final code = canon?.supportCode;
    if (code != null) {
      result.add(
        PrinterIssue('Support code $code', switch (code) {
          '5B00' => 'The printer reports its waste-ink absorber counter is full. Service the absorber before considering a counter reset.',
          '1000' || '1003' => 'The printer reports a paper-feed problem. Check its display and paper supply.',
          '1300' => 'The printer reports a paper jam. Follow the instructions on its display.',
          '1641' =>
            'The estimated remaining ink may be low. Visually check the tanks.',
          _ =>
            'Check the printer display for instructions for this support code.',
        }),
      );
    }
    for (final reason in reasons.toSet()) {
      final base = reason.replaceFirst(RegExp(r'-(error|warning|report)$'), '');
      final (title, detail) = switch (base) {
        'media-empty' || 'media-needed' => (
          'Paper needed',
          'Load paper in the selected feed and check the paper-size setting.',
        ),
        'media-jam' => (
          'Paper jam',
          'Check the printer display and remove jammed paper as instructed.',
        ),
        'cover-open' ||
        'door-open' => ('Cover open', 'Close the indicated printer cover.'),
        'marker-supply-low' || 'toner-low' => (
          'Ink or toner low',
          'Check the indicated supply before refilling or replacing it.',
        ),
        'marker-supply-empty' || 'toner-empty' => (
          'Ink or toner empty',
          'Check the indicated supply and follow the printer instructions.',
        ),
        'paused' => (
          'Printer paused',
          'Resume printing from the printer or print queue.',
        ),
        'offline' => (
          'Printer offline',
          'Check power and the network connection.',
        ),
        'spool-area-full' => (
          'Printer spool storage unavailable',
          'The printer is not accepting new jobs. Read its queues and check the printer display if no jobs are listed.',
        ),
        _ => (
          base.replaceAll('-', ' '),
          'Reported by the printer. Check its display for details.',
        ),
      };
      result.add(
        PrinterIssue(
          title,
          detail,
          warning:
              reason.endsWith('-warning') ||
              reason.endsWith('-report') ||
              base.endsWith('-low'),
        ),
      );
    }
    if (state == 5 && result.isEmpty) {
      result.add(
        const PrinterIssue(
          'Printer stopped',
          'The printer needs attention. Check its display.',
        ),
      );
    }
    return result;
  }

  String get stateLabel => issues.any((i) => !i.warning)
      ? 'Needs attention'
      : attributes['printer-is-accepting-jobs']?.firstOrNull == false &&
            state != 5
      ? 'Busy'
      : state == 3
      ? 'Ready'
      : state == 4
      ? 'Printing'
      : state == 5
      ? 'Stopped'
      : 'Status unknown';
  Map<String, dynamic> toJson() => {
    'capturedAt': capturedAt.toIso8601String(),
    'target': target.toJson(),
    'name': name,
    'model': model,
    'firmware': firmware,
    'state': stateLabel,
    'supplies': supplies.map((s) => s.toJson()).toList(),
    'supplyLevelNote': 'Printer-reported estimates; physical tank levels are not measured by this app. Estimates may remain unchanged after refilling.',
    'currentIssues': issues.map((i) => i.toJson()).toList(),
    'canonStatusAvailable': canon != null,
    'canonSupportCode': canon?.supportCode,
    'wifiSignalPercent': canon?.signal,
    'attributes': attributes,
  };
  String exportText() =>
      'PIXMA FIXA - NETWORK STATUS\nCaptured: ${capturedAt.toIso8601String()}\nPrinter: $name\nModel: $model\nFirmware: $firmware\nAddress: ${target.uri.host}\nStatus: $stateLabel\n\nEstimated supplies\nPrinter-reported estimates, not measured tank levels. Refilling may not update these counts.\n${supplies.map((s) => '${s.name}: ${s.levelText}').join('\n')}\n\nCurrent issues\n${issues.isEmpty ? 'No current errors reported.' : issues.map((i) => '${i.title}: ${i.detail}').join('\n')}\n\n${const JsonEncoder.withIndent('  ').convert(toJson())}';
}
