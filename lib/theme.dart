import 'package:flutter/material.dart';

class CareColors extends ThemeExtension<CareColors> {
  final Color background, panel, rail, line, ink, muted, accent, tint, warning;
  const CareColors({
    required this.background,
    required this.panel,
    required this.rail,
    required this.line,
    required this.ink,
    required this.muted,
    required this.accent,
    required this.tint,
    required this.warning,
  });
  static const light = CareColors(
    background: Color(0xfff4f5f6),
    panel: Color(0xffffffff),
    rail: Color(0xffeceef0),
    line: Color(0xffd8dcdf),
    ink: Color(0xff23292e),
    muted: Color(0xff687078),
    accent: Color(0xff286653),
    tint: Color(0xffe8f0ec),
    warning: Color(0xff966529),
  );
  static const dark = CareColors(
    background: Color(0xff1c1f22),
    panel: Color(0xff25292d),
    rail: Color(0xff22262a),
    line: Color(0xff3c4248),
    ink: Color(0xffe5e8eb),
    muted: Color(0xffa4adb5),
    accent: Color(0xff9acbb7),
    tint: Color(0xff2a3c34),
    warning: Color(0xffdbb87f),
  );
  @override
  CareColors copyWith() => this;
  @override
  CareColors lerp(covariant CareColors? other, double t) =>
      t < .5 ? this : other ?? this;
}

CareColors colors(BuildContext c) => Theme.of(c).extension<CareColors>()!;
ThemeData careTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? CareColors.dark : CareColors.light;
  final base = ThemeData(
    brightness: brightness,
    useMaterial3: true,
    fontFamily: 'Source Sans 3',
    colorScheme: ColorScheme.fromSeed(
      seedColor: p.accent,
      brightness: brightness,
      surface: p.panel,
    ),
  );
  return base.copyWith(
    scaffoldBackgroundColor: p.background,
    extensions: [p],
    textTheme: base.textTheme.apply(bodyColor: p.ink, displayColor: p.ink),
    dividerColor: p.line,
    visualDensity: VisualDensity.compact,
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        textStyle: const TextStyle(
          fontFamily: 'Source Sans 3',
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: brightness == Brightness.dark
            ? const Color(0xff142820)
            : Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        textStyle: const TextStyle(
          fontFamily: 'Source Sans 3',
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        side: BorderSide(color: p.line),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.panel,
      labelStyle: TextStyle(color: p.muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: p.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: p.line),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
  );
}
