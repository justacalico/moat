import 'package:flutter/material.dart';

/// Restrained, platform-native theme: near-stock Material 3 with Apple-style
/// neutrals, hairline dividers and one accent color the user can change.
/// No gradients, no decorative color noise.
class MoatTheme {
  MoatTheme._(); // coverage:ignore-line

  static const accentChoices = <int>[
    0xFF0A84FF, // blue
    0xFF30D158, // green
    0xFFFF9F0A, // orange
    0xFFFF453A, // red
    0xFFBF5AF2, // purple
    0xFF64D2FF, // teal
    0xFFFF375F, // pink
    0xFF98989D, // graphite
  ];

  /// Note color chips — muted tints that read in both themes.
  static const noteColorsLight = <int>[
    0xFFFFF3D6, // sand
    0xFFE4F3E4, // mint
    0xFFE0ECFB, // sky
    0xFFFBE4E4, // rose
    0xFFF0E6FA, // lilac
    0xFFE9E9EB, // stone
  ];

  static const noteColorsDark = <int>[
    0xFF3B3320,
    0xFF24382A,
    0xFF223144,
    0xFF402626,
    0xFF322544,
    0xFF2F2F32,
  ];

  static const folderColors = <int>[
    0xFF0A84FF,
    0xFF30D158,
    0xFFFF9F0A,
    0xFFFF453A,
    0xFFBF5AF2,
    0xFF64D2FF,
  ];

  static Color? noteColor(int index, Brightness brightness) {
    if (index < 0) return null;
    final palette =
        brightness == Brightness.light ? noteColorsLight : noteColorsDark;
    return Color(palette[index % palette.length]);
  }

  static Color folderColor(int index) =>
      Color(folderColors[index % folderColors.length]);

  static ThemeData light(int accent) =>
      _build(Brightness.light, Color(accent));

  static ThemeData dark(int accent) =>
      _build(Brightness.dark, Color(accent));

  static ThemeData _build(Brightness brightness, Color accent) {
    final isDark = brightness == Brightness.dark;
    final scaffold = isDark ? const Color(0xFF000000) : const Color(0xFFF5F5F7);
    final surface = isDark ? const Color(0xFF1C1C1E) : Colors.white;
    final text = isDark ? const Color(0xFFF2F2F7) : const Color(0xFF1D1D1F);
    final hairline =
        isDark ? const Color(0xFF38383A) : const Color(0xFFDCDCE0);

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: brightness,
        surface: surface,
      ),
    );

    return base.copyWith(
      scaffoldBackgroundColor: scaffold,
      dividerColor: hairline,
      dividerTheme: DividerThemeData(color: hairline, thickness: 0.5, space: 0.5),
      colorScheme: base.colorScheme.copyWith(
        primary: accent,
        surface: surface,
        surfaceContainerHighest:
            isDark ? const Color(0xFF2C2C2E) : const Color(0xFFEBEBF0),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scaffold,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: text,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: hairline, width: 0.5),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? const Color(0xFF2C2C2E) : const Color(0xFF1D1D1F),
        contentTextStyle:
            TextStyle(color: isDark ? text : Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: text,
        displayColor: text,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor:
            isDark ? const Color(0xFF2C2C2E) : const Color(0xFFEBEBF0),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        isDense: true,
      ),
      listTileTheme: const ListTileThemeData(
        dense: true,
        horizontalTitleGap: 12,
      ),
    );
  }
}
