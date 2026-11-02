import 'dart:typed_data';

/// Size ceilings for *new derived* school documents and school branding.
/// 1 KB = 1024 bytes. A failed budget keeps the source and never pretends
/// that a truncated, unreadable, or lower-quality PDF was uploaded.
class SchoolMediaBudgets {
  SchoolMediaBudgets._();

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
