import 'dart:typed_data';

/// Size ceilings for *new derived* school documents and school branding.
/// 1 KB = 1024 bytes. A failed budget keeps the source and never pretends
/// that a truncated, unreadable, or lower-quality PDF was uploaded.
class SchoolMediaBudgets {
  SchoolMediaBudgets._();

  // Strict business contract: front + back with photo (if supplied), QR,
  // text and branding must fit one complete 85 KiB PDF. Never silently raise
  // the limit, truncate bytes, or send an oversized card to cloud storage.
  // A failed render remains local for a safe retry/review.
  static const int idCard = 85 * 1024;
  static const int reportCard = 150 * 1024;
  static const int receipt = 30 * 1024;
  static const int branding = 30 * 1024;

  static int? pdfLimit(String kind) {
    switch (kind) {
      case 'studentId':
      case 'teacherId':
      case 'otherStaffId':
      case 'idCard':
        return idCard;
      case 'reportCard':
      case 'marksheet':
        return reportCard;
      case 'receipt':
      case 'feeReceipt':
      case 'expenseReceipt':
      case 'expenses':
        return receipt;
      default:
        return null; // Financial originals, bulk sheets and other documents.
    }
  }

  /// Verify the basic PDF envelope before a newly rendered school document
  /// enters the durable sync queue. Never rewrite arbitrary PDF bytes to meet
  /// a budget: vector text, school signatures and QR must stay intact.
  static Uint8List verifyGeneratedPdf(String kind, Uint8List bytes) {
    final hasHeader = bytes.length >= 16 &&
        bytes[0] == 0x25 && bytes[1] == 0x50 &&
        bytes[2] == 0x44 && bytes[3] == 0x46 && bytes[4] == 0x2d;
    final tailStart = bytes.length > 2048 ? bytes.length - 2048 : 0;
    final hasEof = bytes.length >= 16 &&
        String.fromCharCodes(bytes.sublist(tailStart)).contains('%%EOF');
    if (!hasHeader || !hasEof) {
      throw const FormatException(
        'Generated school PDF is incomplete; local document retained for retry.',
      );
    }
    return enforcePdf(kind, bytes);
  }

  static Uint8List enforcePdf(String kind, Uint8List bytes) {
    final limit = pdfLimit(kind);
    if (limit != null && bytes.lengthInBytes > limit) {
      final actualKb = (bytes.lengthInBytes / 1024).toStringAsFixed(1);
      throw FormatException(
        '$kind PDF is $actualKb KB, above the ${limit ~/ 1024} KB limit. '
        'The original is retained. Use a smaller high-quality photo or '
        'template; the app will not damage text, QR, signatures, or layout.',
      );
    }
    return bytes;
  }
}
