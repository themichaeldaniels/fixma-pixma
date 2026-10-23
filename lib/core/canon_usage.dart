import 'ink_counter.dart';

import 'package:xml/xml.dart';

/// Normal-mode usage fields observed on G7000 firmware 1.050. Missing fields
/// remain unknown; the counters do not measure tank or absorber ink volume.
class CanonUsage {
  final int? frontPages, rearPages, blackHeadCount, colorHeadCount;
  const CanonUsage(
    this.frontPages,
    this.rearPages,
    this.blackHeadCount,
    this.colorHeadCount,
  );
  static const query =
      '<?xml version="1.0" encoding="utf-8"?><cmd xmlns:ivec="http://www.canon.com/ns/cmd/2008/07/common/">'
      '<ivec:contents><ivec:operation>GetStatus</ivec:operation><ivec:param_set servicetype="device"></ivec:param_set></ivec:contents></cmd>';
  factory CanonUsage.parse(String response) {
    const ns = 'http://www.canon.com/ns/cmd/2008/07/canon/';
    final p = CanonInkPeer.reply(response, 'GetStatusResponse', 'device');
    int? value(String name, String attribute, String expected) {
      final text = p
          .findElements(name, namespace: ns)
          .where((e) => e.getAttribute(attribute) == expected)
          .singleOrNull
          ?.innerText;
      final n = int.tryParse(text ?? '');
      return n != null && n >= 0 && n <= 0x7fffffff ? n : null;
    }

    return CanonUsage(
      value('total_paper_num', 'physicalinputbin', 'inputbin_p2'),
      value('total_paper_num', 'physicalinputbin', 'inputbin_p1'),
      value('head_replacement_count', 'color', 'Black'),
      value('head_replacement_count', 'color', 'Color'),
    );
  }
  int? get totalPages =>
      frontPages == null || rearPages == null ? null : frontPages! + rearPages!;
  Map<String, dynamic> toJson() => {
    'frontPages': frontPages,
    'rearPages': rearPages,
    'totalPages': totalPages,
    'blackHeadCount': blackHeadCount,
    'colorHeadCount': colorHeadCount,
  };
  String get summary =>
      'Cassette: ${frontPages ?? 'not reported'} pages · Rear feed: ${rearPages ?? 'not reported'} pages. '
      'Head replacement counts reported by firmware: black ${blackHeadCount ?? 'unknown'}, color ${colorHeadCount ?? 'unknown'}.';
}
