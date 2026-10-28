import 'dart:convert';

import 'windows_theme_presets.dart';

import 'dart:io';

import 'package:flutter/material.dart';

/// Device-only presentation preference; never enters a school database/outbox.
class WindowsAppearance {
  static final brand = ValueNotifier<Color>(const Color(0xFF008C78));
  static String brandRevision = 'default';
  static String? presetId;
  static final changes = ValueNotifier<int>(0);
  static WindowsThemePreset? get preset => windowsThemePreset(presetId);
  static Color get accent => preset?.accent ?? primary;
  static String? get waveAsset => preset?.wave;
  static final mode = ValueNotifier<ThemeMode>(ThemeMode.dark);
  static ThemeMode get presetMode =>
      preset?.light == true ? ThemeMode.light : ThemeMode.dark;
  static File get preferenceFile => File(
    '${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}'
    '${Platform.pathSeparator}VidyaSaarthi${Platform.pathSeparator}windows_appearance.json',
  );

  static Future<void> restore({File? file}) async {
    try {
      final data = jsonDecode(await (file ?? preferenceFile).readAsString());
      applyBrand(data['brand'], persist: false);
      mode.value = presetMode;
    } catch (_) {
      /* First run or damaged preference uses the dark default. */
    }
  }

  // Persist only the selected preset/RGB. A legacy local mode cannot override it.
  static Future<void> _writes = Future<void>.value();
  static Future<void> persist({File? file}) {
    mode.value = presetMode;
    final destination = file ?? preferenceFile;
    final operation = _writes.catchError((Object _) {}).then((_) async {
      await destination.parent.create(recursive: true);
      await destination.writeAsString(
        jsonEncode({'brand': brandData}),
        flush: true,
      );
    });
    _writes = operation;
    return operation;
  }

  static Map<String, dynamic> get brandData => {
    'schemaVersion': 1,
    'red': (brand.value.r * 255).round(),
    'green': (brand.value.g * 255).round(),
    'blue': (brand.value.b * 255).round(),
    'revision': brandRevision,
    if (presetId != null) 'presetId': presetId,
  };
  static void applyBrand(dynamic value, {bool persist = true}) {
    if (value is! Map ||
        value['schemaVersion'] != 1 ||
        ![
          'red',
          'green',
          'blue',
        ].every((k) => value[k] is int && value[k] >= 0 && value[k] <= 255) ||
        value['revision'] is! String)
      return;
    final nextPreset = windowsThemePreset(
      value['presetId'] is String ? value['presetId'] : null,
    );
    presetId = nextPreset?.id;
    mode.value = presetMode;
    brandRevision = value['revision'];
    brand.value = Color.fromARGB(
      255,
      value['red'],
      value['green'],
      value['blue'],
    );
    changes.value++;
    if (persist) WindowsAppearance.persist().catchError((Object _) {});
  }

  static Color get primary =>
      theme(mode.value == ThemeMode.light ? Brightness.light : Brightness.dark)
          .colorScheme
          .primary;
  static Color get onContainer =>
      theme(mode.value == ThemeMode.light ? Brightness.light : Brightness.dark)
          .colorScheme
          .onPrimaryContainer;
  static Color get onPrimary =>
      theme(mode.value == ThemeMode.light ? Brightness.light : Brightness.dark)
          .colorScheme
          .onPrimary;
  static Color get surface => mode.value == ThemeMode.light
      ? Colors.white
      : preset?.darkSurface ?? const Color(0xFF172229);
  static double contrast(Color a, Color b) {
    final x = Color.alphaBlend(a, b).computeLuminance(),
        y = b.computeLuminance();
    return (x > y ? x + .05 : y + .05) / (x > y ? y + .05 : x + .05);
  }

  static Color foreground(Color source) {
    if (source.a == 0) return source;
    var color = resolve(source).withValues(alpha: 1);
    final scheme = theme(
      mode.value == ThemeMode.light ? Brightness.light : Brightness.dark,
    ).colorScheme;
    final surfaces = [
      surface,
      scheme.primaryContainer,
      scheme.surfaceContainerHighest,
      mode.value == ThemeMode.light
          ? const Color(0xFFE0E0E0)
          : const Color(0xFF252525),
    ];
    bool readable(Color c) => surfaces.every((bg) => contrast(c, bg) >= 4.5);
    if (readable(color)) return color;
    final target = mode.value == ThemeMode.light ? Colors.black : Colors.white;
    for (var i = 1; i <= 20; i++) {
      final adjusted = Color.lerp(color, target, i / 20)!;
      if (readable(adjusted)) return adjusted;
    }
    return target;
  }

  static Color onColor(Color color) {
    final bg = Color.alphaBlend(color, surface);
    return contrast(Colors.white, bg) >= contrast(Colors.black, bg)
        ? Colors.white
        : Colors.black;
  }

  static Color get disabledSurface =>
      theme(mode.value == ThemeMode.light ? Brightness.light : Brightness.dark)
          .colorScheme
          .surfaceContainerHighest;
  static List<Color> gradientColors(List<Color> source) {
    final scheme = theme(
      mode.value == ThemeMode.light ? Brightness.light : Brightness.dark,
    ).colorScheme;
    return List.generate(
      source.length,
      (i) => Color.lerp(
        scheme.surface,
        scheme.primaryContainer,
        source.length < 2 ? 1 : i / (source.length - 1),
      )!,
    );
  }

  static Color shadow(Color source) => Colors.black.withValues(
    alpha: source.a.clamp(0.0, mode.value == ThemeMode.light ? .12 : .4),
  );
  static Color outline(Color source) {
    if (source.a == 0) return source;
    final high = [source.r, source.g, source.b].reduce((a, b) => a > b ? a : b),
        low = [source.r, source.g, source.b].reduce((a, b) => a < b ? a : b);
    if (high - low > .35 && high > .55) return foreground(source);
    return theme(
      mode.value == ThemeMode.light ? Brightness.light : Brightness.dark,
    ).colorScheme.outline;
  }

  static Color background(Color source) {
    if (source.a == 0) return source;
    final high = [source.r, source.g, source.b].reduce((a, b) => a > b ? a : b);
    final low = [source.r, source.g, source.b].reduce((a, b) => a < b ? a : b);
    if (high - low < .42 && high <= .46) return resolve(source);
    final scheme = theme(
      mode.value == ThemeMode.light ? Brightness.light : Brightness.dark,
    ).colorScheme;
    if (low >= .55 && high - low < .31)
      return surface.withValues(alpha: source.a);
    return scheme.primaryContainer.withValues(alpha: source.a);
  }

  static void watch(BuildContext context) {
    Theme.of(context);
  }

  static final _themes = <(int, Brightness, String?), ThemeData>{};
  static ThemeData theme(Brightness brightness) {
    final key = (brand.value.toARGB32(), brightness, presetId);
    final cached = _themes[key];
    if (cached != null) return cached;
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: brand.value,
      brightness: brightness,
      surface: dark
          ? preset?.darkSurface ?? const Color(0xFF172229)
          : Colors.white,
    );
    final result = ThemeData(
      brightness: brightness,
      useMaterial3: true,
      fontFamily: 'Segoe UI',
      fontFamilyFallback: const ['Nirmala UI', 'Arial'],
      colorScheme: scheme,
      textTheme: Typography.material2021(platform: TargetPlatform.windows).black
          .apply(
            fontFamily: 'Segoe UI',
            bodyColor: scheme.onSurface,
            displayColor: scheme.onSurface,
          ),
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      dividerColor: scheme.outlineVariant,
      cardTheme: CardThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: preset == null
                ? scheme.outlineVariant
                : accent.withValues(alpha: .35),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        contentTextStyle: TextStyle(
          fontFamily: 'Segoe UI',
          color: scheme.onSurface,
        ),
        actionTextColor: scheme.primary,
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor: WidgetStatePropertyAll(scheme.surfaceContainerHighest),
        headingTextStyle: TextStyle(
          fontFamily: 'Segoe UI',
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
        dataTextStyle: TextStyle(
          fontFamily: 'Segoe UI',
          color: scheme.onSurface,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: TextStyle(
          fontFamily: 'Segoe UI',
          color: scheme.onInverseSurface,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surface,
        textStyle: TextStyle(fontFamily: 'Segoe UI', color: scheme.onSurface),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: TextStyle(fontFamily: 'Segoe UI', color: scheme.onSurface),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        selectedColor: scheme.primaryContainer,
        labelStyle: TextStyle(fontFamily: 'Segoe UI', color: scheme.onSurface),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          disabledBackgroundColor: scheme.surfaceContainerHighest,
          disabledForegroundColor: scheme.onSurfaceVariant,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          disabledBackgroundColor: scheme.surfaceContainerHighest,
          disabledForegroundColor: scheme.onSurfaceVariant,
        ),
      ),
      scaffoldBackgroundColor: dark
          ? preset?.darkBackground ?? const Color(0xFF0B141A)
          : presetId == 'mint-light'
          ? const Color(0xFFECFAF7)
          : const Color(0xFFF3F5F7),
      appBarTheme: AppBarTheme(
        backgroundColor: dark
            ? preset?.darkBackground ?? const Color(0xFF1F2C34)
            : Colors.white,
        foregroundColor: dark ? Colors.white : const Color(0xFF172229),
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark
            ? Color.lerp(surface, Colors.black, .22)
            : presetId == 'mint-light'
            ? const Color(0xFFF5FCFA)
            : const Color(0xFFF0F3F5),
        border: const OutlineInputBorder(),
      ),
    );
    if (_themes.length > 12) _themes.clear();
    _themes[key] = result;
    return result;
  }

  /// Legacy UI neutral tones only. Semantic accents and alpha are retained.
  /// Used by native widgets, never by photos, painters or document exports.
  static Color resolve(Color source) {
    if (source.a == 0) return source;
    // Already-generated brand shades must not be reclassified as status colours.
    if ((source.toARGB32() & 0xFFFFFF) == (primary.toARGB32() & 0xFFFFFF))
      return source;
    final dark = mode.value != ThemeMode.light;
    final r = source.r, g = source.g, b = source.b;
    final high = [r, g, b].reduce((a, b) => a > b ? a : b),
        low = [r, g, b].reduce((a, b) => a < b ? a : b);
    if (high - low < .42 && high <= .46) {
      // Uniform neutral surfaces retain hierarchy without per-page colour casts.
      if (preset != null) {
        final bg = dark
            ? Color.lerp(
                preset!.darkBackground,
                preset!.darkSurface,
                (high / .46).clamp(0, 1),
              )!
            : Color.lerp(Colors.white, const Color(0xFFE3F5F0), high)!;
        return bg.withValues(alpha: source.a);
      }
      final level = dark ? (.035 + high * .22) : (.99 - high * .15);
      return Color.from(alpha: source.a, red: level, green: level, blue: level);
    }
    if (low >= .55 && high - low < .31) {
      return (dark ? const Color(0xFFE8EDF2) : const Color(0xFF172229))
          .withValues(alpha: source.a);
    }
    if (high - low < .12)
      return (dark ? const Color(0xFFB7C3CD) : const Color(0xFF465561))
          .withValues(alpha: source.a);
    // Preserve success/warning/destructive meaning. Other legacy feature accents
    // converge to the developer brand instead of purple/blue page themes.
    if (r > g * 1.35 && r > b * 1.15)
      return (dark ? const Color(0xFFFF8A80) : const Color(0xFFB3261E))
          .withValues(alpha: source.a);
    if (r > .6 && g > .32 && b < .4)
      return (dark ? const Color(0xFFFFD180) : const Color(0xFF805000))
          .withValues(alpha: source.a);
    if (g > r * 1.4 && g > b * 1.3)
      return (dark ? const Color(0xFF7BE0A7) : const Color(0xFF166534))
          .withValues(alpha: source.a);
    return primary.withValues(alpha: source.a);
  }
}
