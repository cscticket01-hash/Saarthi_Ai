/// Pure, platform-neutral salary payment correction checks.
///
/// The first recorded payment is immutable. Corrections are append-only
/// accounting events and cannot turn an unpaid amount into a claimed bank
/// transfer: the authorised school operator confirms the actual amount.
class SalaryPaymentCorrectionPolicy {
  static int wordCount(String text) =>
      text.trim().isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length;

  static String validateNote(String note) {
    final clean = note.trim().replaceAll(RegExp(r'\s+'), ' ');
    final words = wordCount(clean);
    if (words < 100 || words > 300) {
      throw FormatException(
        'Correction explanation must contain 100–300 words (currently $words).',
      );
    }
    if (clean.length > 3500) throw const FormatException('Correction explanation is too long.');
    return clean;
  }

  static int effectiveAmount(
      Map<String, dynamic> payment,
      Iterable<dynamic> corrections,
  ) {
    final id = payment['id']?.toString() ?? '';
    final original = payment['amountPaise'];
    if (id.isEmpty || original is! num || original.toInt() <= 0) {
      throw StateError('Original payment cannot be verified.');
    }
    var current = original.toInt();
    for (final entry in corrections) {
      if (entry is! Map || entry['paymentId'] != id) continue;
      final previous = entry['previousPaise'];
      final revised = entry['correctedPaise'];
      if (previous is! num || revised is! num ||
          previous.toInt() != current || revised.toInt() <= 0) {
        throw StateError('Payment correction history is inconsistent. Original retained.');
      }
      current = revised.toInt();
    }
    return current;
  }
}
