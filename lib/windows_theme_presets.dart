import 'package:flutter/material.dart';

/// Stable identifiers shared with the broker's validated preset allowlist.
class WindowsThemePreset {
  const WindowsThemePreset(
    this.id,
    this.name,
    this.seed,
    this.accent,
    this.darkSurface,
    this.darkBackground, {
    this.light = false,
  });
  final String id, name;
  final Color seed, accent, darkSurface, darkBackground;
  final bool light;
  // Stable ID preserves already-published school themes when the visual\n  // treatment evolves from Midnight Glass to Liquid Glass.
  // Screenshot/animation fallbacks use existing verified dark-blue resources,
  // so every existing page keeps rendering without missing binary assets.
  String get image => 'assets/theme_preset_${id == 'midnight-glass' ? 'electric-blue' : id == 'aurora-liquid-glass' ? 'mint-light' : id}.webp';
  String get wave => 'assets/theme_wave_${id == 'midnight-glass' ? 'electric-blue' : id == 'aurora-liquid-glass' ? 'mint-light' : id}.webp';
}

const windowsThemePresets = <WindowsThemePreset>[
  WindowsThemePreset(
    'midnight-glass',
    'Liquid Glass',
    Color(0xFF8DDBEB),
    Color(0xFFB1C7FF),
    Color(0xFF21384A),
    Color(0xFF06121F),
    light: false,
  ),
  WindowsThemePreset(
    'neon-teal',
    'Neon Teal',
    Color(0xFF00D9C0),
    Color(0xFF49FFF0),
    Color(0xFF0B2026),
    Color(0xFF031014),
    light: false,
  ),
  WindowsThemePreset(
    'electric-blue',
    'Electric Blue',
    Color(0xFF168BFF),
    Color(0xFF00CCFF),
    Color(0xFF0B1838),
    Color(0xFF030C22),
    light: false,
  ),
  WindowsThemePreset(
    'mint-light',
    'Mint Light',
    Color(0xFF008C78),
    Color(0xFF44C6AC),
    Color(0xFF12332F),
    Color(0xFF071B18),
    light: true,
  ),
  WindowsThemePreset(
    'sunset-ember',
    'Sunset Ember',
    Color(0xFFFF705B),
    Color(0xFFFFB267),
    Color(0xFF231A20),
    Color(0xFF141215),
    light: false,
  ),
  WindowsThemePreset(
    'aurora-violet',
    'Aurora Violet',
    Color(0xFF8B5CFF),
    Color(0xFF00D9FA),
    Color(0xFF141D40),
    Color(0xFF060C25),
    light: false,
  ),
  WindowsThemePreset(
    'aurora-liquid-glass',
    'Aurora Liquid Glass',
    Color(0xFF436AE8),
    Color(0xFF7B73E8),
    Color(0xFF17243D),
    Color(0xFFD5E3FF),
    light: true,
  ),
  WindowsThemePreset(
    'emerald-gold',
    'Emerald Gold',
    Color(0xFFD8BB65),
    Color(0xFF00B96B),
    Color(0xFF0C221B),
    Color(0xFF030D09),
    light: false,
  ),
];
WindowsThemePreset? windowsThemePreset(String? id) {
  for (final preset in windowsThemePresets) {
    if (preset.id == id) return preset;
  }
  return null;
}
