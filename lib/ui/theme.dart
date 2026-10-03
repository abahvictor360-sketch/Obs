import 'package:flutter/material.dart';

/// Colors modelled on OBS Studio's default "Yami" theme.
class ObsColors {
  static const bg = Color(0xFF1F2128);
  static const panel = Color(0xFF272A33);
  static const panelAlt = Color(0xFF31343F);
  static const header = Color(0xFF1A1C22);
  static const border = Color(0xFF3C404D);
  static const accent = Color(0xFF476BD7);
  static const accentDim = Color(0xFF2E4590);
  static const live = Color(0xFFD7334B);
  static const rec = Color(0xFFE0603A);
  static const ok = Color(0xFF3FB950);
  static const warn = Color(0xFFE3B341);
  static const text = Color(0xFFE6E7EB);
  static const textDim = Color(0xFF9EA3B0);
  static const selection = Color(0xFFE5383B);
}

ThemeData buildObsTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: ObsColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: ObsColors.accent,
    surface: ObsColors.panel,
    onSurface: ObsColors.text,
    error: ObsColors.live,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: ObsColors.bg,
    canvasColor: ObsColors.panel,
    dividerColor: ObsColors.border,
    dividerTheme: const DividerThemeData(color: ObsColors.border, space: 1, thickness: 1),
    visualDensity: VisualDensity.standard,
    // Tablet-friendly touch targets everywhere.
    materialTapTargetSize: MaterialTapTargetSize.padded,
    listTileTheme: const ListTileThemeData(
      dense: false,
      selectedColor: ObsColors.text,
      selectedTileColor: ObsColors.accentDim,
      iconColor: ObsColors.textDim,
      textColor: ObsColors.text,
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: ObsColors.accent,
      thumbColor: ObsColors.text,
      inactiveTrackColor: ObsColors.border,
      trackHeight: 4,
    ),
    dialogTheme: const DialogThemeData(backgroundColor: ObsColors.panel),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: ObsColors.panel,
      showDragHandle: true,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: ObsColors.header,
      border: OutlineInputBorder(borderSide: BorderSide(color: ObsColors.border)),
      enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: ObsColors.border)),
    ),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 600)),
  );
}
