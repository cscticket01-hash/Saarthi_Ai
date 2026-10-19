import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// Device-only presentation preference; never enters a school database/outbox.
class WindowsAppearance {
  static final mode = ValueNotifier<ThemeMode>(ThemeMode.dark);
  static File get preferenceFile => File(
    '${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}'
    '${Platform.pathSeparator}VidyaSaarthi${Platform.pathSeparator}windows_appearance.json',
  );

  static Future<void> restore({File? file}) async {
    try {
      final data = jsonDecode(await (file ?? preferenceFile).readAsString());
      mode.value = data['mode'] == 'light' ? ThemeMode.light : ThemeMode.dark;
    } catch (_) {
      /* First run or damaged preference uses the dark default. */
    }
  }

  // Serialize writes so rapid toggles cannot persist an older selection last.
  static Future<void> _writes = Future<void>.value();
  static Future<void> select(ThemeMode value, {File? file}) {
    if (value != ThemeMode.dark && value != ThemeMode.light)
      return Future.value();
    mode.value = value;
    final destination = file ?? preferenceFile;
    final operation = _writes.catchError((Object _) {}).then((_) async {
      await destination.parent.create(recursive: true);
      await destination.writeAsString(
        jsonEncode({'mode': value.name}),
        flush: true,
      );
    });
    _writes = operation;
    return operation;
  }

  static void watch(BuildContext context) {
    Theme.of(context);
  }

  static ThemeData theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return ThemeData(
      brightness: brightness,
      useMaterial3: true,
      fontFamily: 'Segoe UI',
      fontFamilyFallback: const ['Nirmala UI', 'Arial'],
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF008C78),
        brightness: brightness,
        surface: dark ? const Color(0xFF172229) : const Color(0xFFFFFFFF),
      ),
      scaffoldBackgroundColor: dark
          ? const Color(0xFF0B141A)
          : const Color(0xFFF3F5F7),
      appBarTheme: AppBarTheme(
        backgroundColor: dark ? const Color(0xFF1F2C34) : Colors.white,
        foregroundColor: dark ? Colors.white : const Color(0xFF172229),
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF101B22) : const Color(0xFFF0F3F5),
        border: const OutlineInputBorder(),
      ),
    );
  }

  /// Legacy UI neutral tones only. Semantic accents and alpha are retained.
  /// Used by native widgets, never by photos, painters or document exports.
  static Color resolve(Color source) {
    if (mode.value != ThemeMode.light) return source;
    final r = source.r, g = source.g, b = source.b;
    final high = [r, g, b].reduce((a, b) => a > b ? a : b);
    final low = [r, g, b].reduce((a, b) => a < b ? a : b);
    if (high <= .46 && high - low < .42) {
      final light = .97 - high * .24;
      return Color.from(alpha: source.a, red: light, green: light, blue: light);
    }
    if (low >= .55 && high - low < .31) {
      final dark = .10 + (1 - low) * .5;
      return Color.from(
        alpha: source.a,
        red: dark,
        green: dark + .025,
        blue: dark + .04,
      );
    }
    return source;
  }
}

class WindowsAppearanceCard extends StatefulWidget {
  const WindowsAppearanceCard({super.key});
  @override
  State<WindowsAppearanceCard> createState() => _WindowsAppearanceCardState();
}

class _WindowsAppearanceCardState extends State<WindowsAppearanceCard> {
  Future<void> _select(ThemeMode mode) async {
    try {
      await WindowsAppearance.select(mode);
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Theme applied. Could not save this preference; please try again.',
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
    valueListenable: WindowsAppearance.mode,
    builder: (context, mode, _) => Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final heading = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  mode == ThemeMode.dark
                      ? Icons.dark_mode_outlined
                      : Icons.light_mode_outlined,
                ),
                const SizedBox(width: 12),
                const Flexible(
                  child: Text(
                    'Appearance',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            );
            final choices = Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Dark Mode'),
                  selected: mode == ThemeMode.dark,
                  onSelected: (_) => _select(ThemeMode.dark),
                ),
                ChoiceChip(
                  label: const Text('Light Mode'),
                  selected: mode == ThemeMode.light,
                  onSelected: (_) => _select(ThemeMode.light),
                ),
              ],
            );
            if (constraints.maxWidth < 560 ||
                MediaQuery.textScalerOf(context).scale(1) > 1.3) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [heading, const SizedBox(height: 12), choices],
              );
            }
            return Row(
              children: [
                Expanded(child: heading),
                choices,
              ],
            );
          },
        ),
      ),
    ),
  );
}
