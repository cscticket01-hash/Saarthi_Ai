import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// Device-only presentation preference; never enters a school database/outbox.
class WindowsAppearance {
  static final brand = ValueNotifier<Color>(const Color(0xFF008C78));
  static String brandRevision = 'default';
  static final mode = ValueNotifier<ThemeMode>(ThemeMode.dark);
  static File get preferenceFile => File(
    '${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}'
    '${Platform.pathSeparator}VidyaSaarthi${Platform.pathSeparator}windows_appearance.json',
  );

  static Future<void> restore({File? file}) async {
    try {
      final data = jsonDecode(await (file ?? preferenceFile).readAsString());
      applyBrand(data['brand'], persist: false);
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
        jsonEncode({'mode': mode.value.name, 'brand': brandData}),
        flush: true,
      );
    });
    _writes = operation;
    return operation;
  }

  static Map<String, dynamic> get brandData => {'schemaVersion':1,
    'red': (brand.value.r * 255).round(), 'green': (brand.value.g * 255).round(),
    'blue': (brand.value.b * 255).round(), 'revision':brandRevision};
  static void applyBrand(dynamic value, {bool persist = true}) {
    if (value is! Map || value['schemaVersion'] != 1 ||
        !['red','green','blue'].every((k) => value[k] is int && value[k] >= 0 && value[k] <= 255) ||
        value['revision'] is! String) return;
    brandRevision = value['revision'];
    brand.value = Color.fromARGB(255, value['red'], value['green'], value['blue']);
    if (persist) select(mode.value).catchError((Object _) {});
  }
  static Color get primary => theme(mode.value == ThemeMode.light ? Brightness.light : Brightness.dark).colorScheme.primary;
  static Color get onContainer => theme(mode.value == ThemeMode.light ? Brightness.light : Brightness.dark).colorScheme.onPrimaryContainer;
  static Color get onPrimary => theme(mode.value == ThemeMode.light ? Brightness.light : Brightness.dark).colorScheme.onPrimary;
  static Color get surface => mode.value == ThemeMode.light ? Colors.white : const Color(0xFF172229);
  static double contrast(Color a, Color b) {
    final x = Color.alphaBlend(a,b).computeLuminance(), y = b.computeLuminance();
    return (x>y ? x+.05 : y+.05)/(x>y ? y+.05 : x+.05);
  }
  static Color foreground(Color source) {
    if (source.a == 0) return source;
    var color=resolve(source).withValues(alpha:1);
    final scheme=theme(mode.value==ThemeMode.light?Brightness.light:Brightness.dark).colorScheme;
    final surfaces=[surface,scheme.primaryContainer,scheme.surfaceContainerHighest,
      mode.value==ThemeMode.light?const Color(0xFFE0E0E0):const Color(0xFF252525)];
    bool readable(Color c)=>surfaces.every((bg)=>contrast(c,bg)>=4.5);
    if (readable(color)) return color;
    final target=mode.value==ThemeMode.light ? Colors.black : Colors.white;
    for(var i=1;i<=20;i++) {
      final adjusted=Color.lerp(color,target,i/20)!;
      if(readable(adjusted)) return adjusted;
    }
    return target;
  }
  static Color onColor(Color color) {
    final bg=Color.alphaBlend(color,surface);
    return contrast(Colors.white,bg)>=contrast(Colors.black,bg)?Colors.white:Colors.black;
  }
  static Color get disabledSurface => theme(mode.value==ThemeMode.light?Brightness.light:Brightness.dark).colorScheme.surfaceContainerHighest;
  static List<Color> gradientColors(List<Color> source) {
    final scheme=theme(mode.value==ThemeMode.light?Brightness.light:Brightness.dark).colorScheme;
    return List.generate(source.length,(i)=>Color.lerp(scheme.surface,scheme.primaryContainer,
      source.length<2?1:i/(source.length-1))!);
  }
  static Color shadow(Color source) => Colors.black.withValues(alpha: source.a.clamp(0.0,mode.value == ThemeMode.light ? .12 : .4));
  static Color outline(Color source) {
    if(source.a==0)return source;
    final high=[source.r,source.g,source.b].reduce((a,b)=>a>b?a:b),low=[source.r,source.g,source.b].reduce((a,b)=>a<b?a:b);
    if(high-low>.35 && high>.55)return foreground(source);
    return theme(mode.value==ThemeMode.light?Brightness.light:Brightness.dark).colorScheme.outline;
  }
  static Color background(Color source) {
    if(source.a==0) return source;
    final high=[source.r,source.g,source.b].reduce((a,b)=>a>b?a:b);
    final low=[source.r,source.g,source.b].reduce((a,b)=>a<b?a:b);
    if(high-low<.42 && high<=.46) return resolve(source);
    final scheme=theme(mode.value==ThemeMode.light?Brightness.light:Brightness.dark).colorScheme;
    if(low>=.55 && high-low<.31) return surface.withValues(alpha:source.a);
    return scheme.primaryContainer.withValues(alpha:source.a);
  }
  static void watch(BuildContext context) {
    Theme.of(context);
  }

  static final _themes=<(int,Brightness),ThemeData>{};
  static ThemeData theme(Brightness brightness) {
    final key=(brand.value.toARGB32(),brightness);
    final cached=_themes[key];
    if(cached!=null)return cached;
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(seedColor: brand.value, brightness: brightness,
      surface: dark ? const Color(0xFF172229) : Colors.white);
    final result=ThemeData(
      brightness: brightness,
      useMaterial3: true,
      fontFamily: 'Segoe UI',
      fontFamilyFallback: const ['Nirmala UI', 'Arial'],
      colorScheme: scheme,
      textTheme: Typography.material2021(platform: TargetPlatform.windows).black.apply(
        fontFamily: 'Segoe UI', bodyColor: scheme.onSurface, displayColor: scheme.onSurface),
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      dividerColor: scheme.outlineVariant,
      cardTheme: CardThemeData(color: scheme.surface, surfaceTintColor: Colors.transparent),
      dialogTheme: DialogThemeData(backgroundColor: scheme.surface, surfaceTintColor: Colors.transparent),
      snackBarTheme: SnackBarThemeData(backgroundColor: scheme.surfaceContainerHighest,
        contentTextStyle: TextStyle(fontFamily: 'Segoe UI', color: scheme.onSurface), actionTextColor: scheme.primary),
      dataTableTheme: DataTableThemeData(headingRowColor: WidgetStatePropertyAll(scheme.surfaceContainerHighest),
        headingTextStyle: TextStyle(fontFamily: 'Segoe UI', color: scheme.onSurface, fontWeight: FontWeight.w700),
        dataTextStyle: TextStyle(fontFamily: 'Segoe UI', color: scheme.onSurface)),
      tooltipTheme: TooltipThemeData(decoration: BoxDecoration(color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(6)), textStyle: TextStyle(fontFamily: 'Segoe UI', color: scheme.onInverseSurface)),
      popupMenuTheme: PopupMenuThemeData(color: scheme.surface, textStyle: TextStyle(fontFamily: 'Segoe UI', color: scheme.onSurface)),
      dropdownMenuTheme: DropdownMenuThemeData(textStyle: TextStyle(fontFamily: 'Segoe UI', color: scheme.onSurface)),
      chipTheme: ChipThemeData(backgroundColor: scheme.surfaceContainerHighest,
        selectedColor: scheme.primaryContainer, labelStyle: TextStyle(fontFamily: 'Segoe UI', color: scheme.onSurface)),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
      elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(backgroundColor:scheme.primary,foregroundColor:scheme.onPrimary,
        disabledBackgroundColor:scheme.surfaceContainerHighest,disabledForegroundColor:scheme.onSurfaceVariant)),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(backgroundColor:scheme.primary,foregroundColor:scheme.onPrimary,
        disabledBackgroundColor:scheme.surfaceContainerHighest,disabledForegroundColor:scheme.onSurfaceVariant)),
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
    if(_themes.length>12)_themes.clear();
    _themes[key]=result;
    return result;
  }

  /// Legacy UI neutral tones only. Semantic accents and alpha are retained.
  /// Used by native widgets, never by photos, painters or document exports.
  static Color resolve(Color source) {
    if (source.a == 0) return source;
    // Already-generated brand shades must not be reclassified as status colours.
    if ((source.toARGB32() & 0xFFFFFF) == (primary.toARGB32() & 0xFFFFFF)) return source;
    final dark = mode.value != ThemeMode.light;
    final r = source.r, g = source.g, b = source.b;
    final high = [r,g,b].reduce((a,b)=>a>b?a:b), low=[r,g,b].reduce((a,b)=>a<b?a:b);
    if (high-low < .42 && high <= .46) {
      // Uniform neutral surfaces retain hierarchy without per-page colour casts.
      final level = dark ? (.035 + high * .22) : (.99 - high * .15);
      return Color.from(alpha:source.a,red:level,green:level,blue:level);
    }
    if (low >= .55 && high-low < .31) {
      return (dark ? const Color(0xFFE8EDF2) : const Color(0xFF172229)).withValues(alpha:source.a);
    }
    if (high-low < .12) return (dark ? const Color(0xFFB7C3CD) : const Color(0xFF465561)).withValues(alpha:source.a);
    // Preserve success/warning/destructive meaning. Other legacy feature accents
    // converge to the developer brand instead of purple/blue page themes.
    if (r > g * 1.35 && r > b * 1.15) return (dark ? const Color(0xFFFF8A80) : const Color(0xFFB3261E)).withValues(alpha:source.a);
    if (r > .6 && g > .32 && b < .4) return (dark ? const Color(0xFFFFD180) : const Color(0xFF805000)).withValues(alpha:source.a);
    if (g > r * 1.4 && g > b * 1.3) return (dark ? const Color(0xFF7BE0A7) : const Color(0xFF166534)).withValues(alpha:source.a);
    return primary.withValues(alpha:source.a);

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
                    style: TextStyle(fontFamily: 'Segoe UI', fontSize: 18, fontWeight: FontWeight.w600),
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
