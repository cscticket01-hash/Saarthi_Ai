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

  static Uint8List? portrait(Uint8List? original) {
    if (original == null) return null;
    final outcome = DocumentProcessingEngine.portraitUpload({'bytes': original});
    return outcome['optimized'] as Uint8List;
  }

  // Isolate-friendly adapter for an individual print-region budget.
  // No extra compressor: every path still runs through branding().
  static Uint8List? brandingSized(Map<String, dynamic> request) => branding(
    request['bytes'] as Uint8List?,
    maxPrintEdge: request['maxPrintEdge'] as int,
  );

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
