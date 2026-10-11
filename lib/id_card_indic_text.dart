import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Indic grapheme shaping is performed by Flutter/Skia (HarfBuzz) before
/// embedding the field as a high-resolution PNG in the PDF. This avoids the
/// naive per-codepoint PDF positioning that breaks combining marks.
///
/// This uses INSTALLED OS fallback fonts, so Bengali/Assamese/Devanagari font
/// coverage and native print quality must still be inspected on real devices.
/// It intentionally leaves Latin-only text on the existing searchable PDF path.
class IdCardIndicText {
  static bool needsShaping(String text) =>
      RegExp(r'[\u0900-\u097F\u0980-\u09FF]').hasMatch(text);

  static Future<Uint8List?> rasterize(
    String text, {
    required double width,
    required double height,
    required double fontSize,
    required double minFontSize,
    required int maxLines,
    required String align,
  }) async {
    if (!needsShaping(text)) return null;
    if (text.runes.length > 400 ||
        !width.isFinite || !height.isFinite ||
        !fontSize.isFinite || !minFontSize.isFinite ||
        width <= 0 || height <= 0 ||
        width > 10000 || height > 10000 ||
        minFontSize <= 0 || fontSize < minFontSize ||
        maxLines < 1 || maxLines > 10) {
      throw const FormatException('Invalid multilingual ID text region');
    }
    final scale = [3.0, 1500.0 / width, 1500.0 / height]
        .reduce((a, b) => a < b ? a : b);
    if (scale < .5) {
      throw const FormatException('Multilingual print region is too large');
    }
    final pxW = (width * scale).ceil();
    final pxH = (height * scale).ceil();
    final hasBengali = RegExp(r'[\u0980-\u09FF]').hasMatch(text);
    final language = hasBengali ? 'bn' : 'hi';
    TextPainter? painter;
    var font = fontSize;
    try {
      while (font >= minFontSize - .01) {
        final candidate = TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              color: const ui.Color(0xFF000000),
              fontSize: font,
              height: 1.16,
              fontFamilyFallback: const [
                'Nirmala UI',
                'Noto Sans Bengali',
                'Noto Sans Devanagari',
                'Noto Sans',
                'Arial Unicode MS',
              ],
              locale: ui.Locale(language),
            ),
          ),
          textDirection: ui.TextDirection.ltr,
          maxLines: maxLines,
          textAlign: align == 'center'
              ? TextAlign.center
              : align == 'right'
              ? TextAlign.right
              : TextAlign.left,
        )..layout(maxWidth: width);
        if (!candidate.didExceedMaxLines &&
            candidate.height <= height &&
            candidate.width <= width) {
          painter = candidate;
          break;
        }
        candidate.dispose();
        font -= .5;
      }
      if (painter == null) {
        throw const FormatException('Indic text cannot fit readable region');
      }
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.scale(scale);
      painter.paint(canvas, const ui.Offset(0, 0));
      final picture = recorder.endRecording();
      final image = await picture.toImage(pxW, pxH);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) {
          throw const FormatException('Indic text could not be rasterized');
        }
        return data.buffer.asUint8List();
      } finally {
        image.dispose();
        picture.dispose();
      }
    } finally {
      painter?.dispose();
    }
  }
}
