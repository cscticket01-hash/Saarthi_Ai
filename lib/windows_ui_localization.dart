import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart' as m;
import 'package:flutter/foundation.dart';
import 'windows_html_shim.dart' as html;
import 'windows_ui_translations.dart';

class WindowsUiLanguage {
  static const key = 'vidya_windows_language_v1';
  static final changed = ValueNotifier<String>(_read());
  static File get _preferenceFile => File('${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}${Platform.pathSeparator}VidyaSaarthi${Platform.pathSeparator}windows_ui_preferences.json');
  static String _read() {
    String? saved;
    try {
      if (_preferenceFile.existsSync()) saved = (jsonDecode(_preferenceFile.readAsStringSync()) as Map)['language']?.toString();
    } catch (_) {}
    saved ??= html.window.localStorage[key];
    return const {'en', 'hi', 'bn', 'as'}.contains(saved) ? saved! : 'en';
  }
  static String get current => changed.value;
  static void restore() => changed.value = _read();
  static void change(String language) {
    if (!const {'en', 'hi', 'bn', 'as'}.contains(language)) return;
    // Device UI preferences are independent of the active school data namespace.
    try {
      _preferenceFile.parent.createSync(recursive: true);
      _preferenceFile.writeAsStringSync(jsonEncode({'language': language}), flush: true);
    } catch (_) {}
    html.window.localStorage[key] = language;
    changed.value = language;
  }
  static String translate(String value) {
    if (current == 'en') return value;
    final exact = (windowsUiTranslations[value] ?? windowsUiTranslations[value.trim()] ?? windowsUiTranslations[value.replaceAll(' *', '')])?[current];
    if (exact != null) return exact;
    // Template parameters (names, dates and counts) are kept verbatim.
    for (final entry in windowsUiTranslations.entries) {
      if (!entry.key.contains('{0}')) continue;
      final parts = entry.key.split(RegExp(r'\{[0-9]+\}'));
      final pattern = parts.map(RegExp.escape).join('(.*?)');
      final match = RegExp('^$pattern'+r'$').firstMatch(value);
      if (match == null) continue;
      var result = entry.value[current] ?? value;
      for (var i = 0; i < match.groupCount; i++) result = result.replaceAll('{$i}', match.group(i + 1)!);
      return result;
    }
    // Preserve leading error details while translating the UI explanation.
    if (value.startsWith('Bad state: ')) return translate(value.substring(11));
    for (final separator in const [' • ', ': ', '\n']) {
      if (value.contains(separator)) return value.split(separator).map(translate).join(separator);
    }
    return value;
  }
}

/// Reacts to language changes even under const routes and dialogs. Application
/// data such as student names and notice bodies can opt out with translate:false.
class Text extends m.StatelessWidget {
  const Text(this.data, {super.key, this.translate = true,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaleFactor,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor });
  final String data;
  final bool translate;
  final m.TextStyle? style;
  final m.StrutStyle? strutStyle;
  final m.TextAlign? textAlign;
  final m.TextDirection? textDirection;
  final m.Locale? locale;
  final bool? softWrap;
  final m.TextOverflow? overflow;
  final double? textScaleFactor;
  final m.TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final String? semanticsIdentifier;
  final m.TextWidthBasis? textWidthBasis;
  final m.TextHeightBehavior? textHeightBehavior;
  final m.Color? selectionColor;
  @override
  m.Widget build(m.BuildContext context) => m.ValueListenableBuilder<String>(
    valueListenable: WindowsUiLanguage.changed,
    builder: (context, language, _) => m.Text(translate ? WindowsUiLanguage.translate(data) : data,
      style: style,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      locale: locale,
      softWrap: softWrap,
      overflow: overflow,
      textScaleFactor: textScaleFactor,
      textScaler: textScaler,
      maxLines: maxLines,
      semanticsLabel: semanticsLabel,
      semanticsIdentifier: semanticsIdentifier,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor ));
}

/// Field labels/hints translate at rendering time. The MaterialApp locale update
/// rebuilds InputDecorators without losing controllers, route state or focus.
class InputDecoration extends m.InputDecoration {
  const InputDecoration({
    super.icon,
    super.iconColor,
    super.label,
    super.labelText,
    super.labelStyle,
    super.floatingLabelStyle,
    super.helper,
    super.helperText,
    super.helperStyle,
    super.helperMaxLines,
    super.hintText,
    super.hintStyle,
    super.hintTextDirection,
    super.hintMaxLines,
    super.hintFadeDuration,
    super.maintainHintHeight = true,
    super.maintainHintSize = true,
    super.error,
    super.errorText,
    super.errorStyle,
    super.errorMaxLines,
    super.floatingLabelBehavior,
    super.floatingLabelAlignment,
    super.isCollapsed,
    super.isDense,
    super.contentPadding,
    super.prefixIcon,
    super.prefixIconConstraints,
    super.prefix,
    super.prefixText,
    super.prefixStyle,
    super.prefixIconColor,
    super.suffixIcon,
    super.suffix,
    super.suffixText,
    super.suffixStyle,
    super.suffixIconColor,
    super.suffixIconConstraints,
    super.counter,
    super.counterText,
    super.counterStyle,
    super.filled,
    super.fillColor,
    super.focusColor,
    super.hoverColor,
    super.errorBorder,
    super.focusedBorder,
    super.focusedErrorBorder,
    super.disabledBorder,
    super.enabledBorder,
    super.border,
    super.enabled = true,
    super.semanticCounterText,
    super.alignLabelWithHint,
    super.constraints });
  @override
  m.InputDecoration applyDefaults(Object theme) => super.applyDefaults(theme).copyWith(
    labelText: labelText == null ? null : WindowsUiLanguage.translate(labelText!),
    hintText: hintText == null ? null : WindowsUiLanguage.translate(hintText!),
    helperText: helperText == null ? null : WindowsUiLanguage.translate(helperText!),
    errorText: errorText == null ? null : WindowsUiLanguage.translate(errorText!),
    counterText: counterText == null ? null : WindowsUiLanguage.translate(counterText!),
  );
}
