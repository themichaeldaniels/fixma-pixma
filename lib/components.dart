import 'package:flutter/material.dart';

import 'theme.dart';

class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });
  @override
  Widget build(BuildContext context) {
    final p = colors(context);
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: p.line),
      ),
      child: child,
    );
  }
}

class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      color: colors(context).muted,
      fontSize: 14,
      letterSpacing: 0,
      fontWeight: FontWeight.w600,
    ),
  );
}

class BadgeLabel extends StatelessWidget {
  final String text;
  final bool warning;
  const BadgeLabel(this.text, {super.key, this.warning = false});
  @override
  Widget build(BuildContext context) {
    final p = colors(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: warning ? p.warning.withValues(alpha: .12) : p.tint,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: warning ? p.warning : p.accent,
        ),
      ),
    );
  }
}

String number(int? n) => n == null
    ? ' - '
    : n.toString().replaceAllMapped(
        RegExp(r'\B(?=(\d{3})+(?!\d))'),
        (_) => ',',
      );
String date(DateTime d) {
  final v = d.toLocal();
  return '${v.month.toString().padLeft(2, '0')}/${v.day.toString().padLeft(2, '0')}/${v.year}  ${v.hour.toString().padLeft(2, '0')}:${v.minute.toString().padLeft(2, '0')}';
}
