import 'dart:convert';

import 'report.dart';

class ReportComparison {
  final ServiceReport before, after;
  ReportComparison(this.before, this.after) {
    if (before.serial != after.serial) {
      throw const FormatException('Choose two reports from the same printer.');
    }
    if (before.sample != after.sample) {
      throw const FormatException(
        'Sample and real reports cannot be compared.',
      );
    }
    if (before.capturedAt.isAfter(after.capturedAt)) {
      throw const FormatException(
        'The baseline must be older than the comparison report.',
      );
    }
  }
  List<(String, String, String, String)> get rows {
    String count(num? v) => v == null ? 'Not reported' : '$v';
    String delta(num? a, num? b, {bool percent = false}) =>
        a == null || b == null
        ? 'Unknown'
        : '${b - a > 0 ? '+' : ''}${percent ? (b - a).toStringAsFixed(1) : b - a}${percent ? ' points' : ''}';
    return [
      (
        'Firmware',
        before.firmware,
        after.firmware,
        before.firmware == after.firmware ? 'Unchanged' : 'Changed',
      ),
      (
        'Waste estimate',
        before.waste == null
            ? 'Not reported'
            : '${before.waste!.toStringAsFixed(1)}%',
        after.waste == null
            ? 'Not reported'
            : '${after.waste!.toStringAsFixed(1)}%',
        delta(before.waste, after.waste, percent: true),
      ),
      for (final (label, a, b) in [
        ('Total pages', before.pages, after.pages),
        ('Copies', before.copies, after.copies),
        ('Rear-feed pages', before.rearPages, after.rearPages),
        ('Cassette pages', before.frontPages, after.frontPages),
        ('Counter clears', before.resetCount, after.resetCount),
      ])
        (label, count(a), count(b), delta(a, b)),
      (
        'Stored errors',
        before.errorCodes.isEmpty
            ? 'None reported'
            : before.errorCodes.join(', '),
        after.errorCodes.isEmpty
            ? 'None reported'
            : after.errorCodes.join(', '),
        before.errorCodes.join(',') == after.errorCodes.join(',')
            ? 'Unchanged'
            : 'Changed',
      ),
    ];
  }
}

/// Imports are comparison-only data. They never become a live reset report.
List<ServiceReport> importReports(String input) {
  if (input.length > 2 * 1024 * 1024) {
    throw const FormatException('Report import is limited to 2 MB.');
  }
  final text = input.trim();
  final reports = <ServiceReport>[];
  if (text.startsWith('{') || text.startsWith('[')) {
    final value = jsonDecode(text);
    void add(Object? v) {
      if (v is! Map) return;
      if (v['raw'] is String) {
        reports.add(ServiceReport.fromJson(Map<String, dynamic>.from(v)));
      }
      if (v['report'] is Map) add(v['report']);
    }

    if (value is List) {
      for (final v in value.take(200)) {
        add(v);
      }
    } else if (value is Map) {
      add(value);
      if (value['history'] is List) {
        for (final v in (value['history'] as List).take(200)) {
          add(v);
        }
      }
    }
  } else {
    // A pasted raw/exported report has no trusted timestamp or sample identity.
    // Mark it imported sample data so it cannot be confused with live evidence.
    reports.add(ServiceReport.parse(text, sample: true));
  }
  if (reports.isEmpty) {
    throw const FormatException('No compatible G7000 service report found.');
  }
  return reports;
}
