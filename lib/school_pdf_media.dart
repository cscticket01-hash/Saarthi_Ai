import 'dart:typed_data';

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

  static Uint8List? branding(Uint8List? original) {
    if (original == null) return null;
    final outcome = DocumentProcessingEngine.brandingUpload({'bytes': original});
    return outcome['optimized'] as Uint8List;
  }
}
