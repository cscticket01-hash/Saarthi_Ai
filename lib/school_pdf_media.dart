import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'document_processing_engine.dart';

/// Compress *embedded images* before PDF creation, not entire PDF pages.
/// QR/text remain vector/searchable, page geometry is unaffected, and original
/// school-uploaded media remains untouched. Generated PDF size is still
/// measured separately by SchoolMediaBudgets.
class SchoolPdfMedia {
  SchoolPdfMedia._();

  /// Reduce a finished ID PDF's decorative front/back bitmap without
  /// modifying the original template, source assets, vector fields or QR.
  /// Card backgrounds are composited over white by the existing renderer;
  /// flattening PNG transparency against the same white is visually exact.
  /// Never upscale artwork. Keep a 300dpi physical-page ceiling and JPEG
  /// quality >= 90 for color printed CR80 cards.
  static Uint8List cardBackground(
    Uint8List source, {
    required double widthMm,
    required double heightMm,
  }) {
    final decoded = img.decodeImage(source);
    if (decoded == null || widthMm <= 0 || heightMm <= 0 ||
        widthMm > 500 || heightMm > 500 ||
        decoded.width <= 0 || decoded.height <= 0 ||
        decoded.width * decoded.height > 20000000) {
      throw const FormatException('Invalid physical ID card background.');
    }
    final rotated = img.bakeOrientation(decoded);
    final maxWidth = (widthMm * 300 / 25.4).ceil();
    final maxHeight = (heightMm * 300 / 25.4).ceil();
    final scale = math.min(1.0, math.min(
      maxWidth / rotated.width, maxHeight / rotated.height));
    final frame = scale < 1
        ? img.copyResize(rotated,
            width: math.max(1, (rotated.width * scale).round()),
            height: math.max(1, (rotated.height * scale).round()),
            interpolation: img.Interpolation.average)
        : rotated;
    final rgb = frame.convert(numChannels: 4);
    // The ID page underneath is already solid white.
    for (final p in rgb) {
      final alpha = p.a / 255;
      p.r = p.r * alpha + 255 * (1 - alpha);
      p.g = p.g * alpha + 255 * (1 - alpha);
      p.b = p.b * alpha + 255 * (1 - alpha);
      p.a = 255;
    }
    final jpeg = Uint8List.fromList(img.encodeJpg(
      rgb.convert(numChannels: 3), quality: 92));
    // A lossless source that is already smaller stays pixel-identical.
    // JPEG only replaces the bitmap when it actually reduces the PDF.
    return jpeg.length < source.length ? jpeg : source;
  }

  static Uint8List? portrait(Uint8List? original) {
    if (original == null) return null;
    final outcome = DocumentProcessingEngine.portraitUpload({'bytes': original});
    return outcome['optimized'] as Uint8List;
  }

  static Uint8List? branding(Uint8List? original, {int maxPrintEdge = 256}) {
    if (original == null) return null;
    final outcome = DocumentProcessingEngine.brandingUpload({'bytes': original});
    final compressed = outcome['optimized'] as Uint8List;
    final decoded = img.decodeImage(compressed);
    if (decoded == null) throw const FormatException('Invalid optimized school branding.');
    final edge = math.max(decoded.width, decoded.height);
    if (edge <= maxPrintEdge) return compressed;
    final frame = img.copyResize(decoded,
      width: decoded.width >= decoded.height ? maxPrintEdge : null,
      height: decoded.height > decoded.width ? maxPrintEdge : null,
      interpolation: img.Interpolation.average);
    // Downsample once for the actual physical print region. Retain alpha for
    // seals/signatures rather than replacing paper transparency with white.
    var transparent = false;
    for (final pixel in frame) {
      if (pixel.a < 255) { transparent = true; break; }
    }
    final encoded = Uint8List.fromList(transparent
      ? img.encodePng(frame, level: 9)
      : img.encodeJpg(frame.convert(numChannels: 3), quality: 90));
    if (encoded.length > DocumentProcessingEngine.brandingTarget) {
      throw const FormatException(
        'School print branding exceeded 30 KB without safe reduction.');
    }
    return encoded;
  }
}
