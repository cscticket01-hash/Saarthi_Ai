/// Sync Engine 3.0's record-only PDF contract.
///
/// Ordinary student, teacher, staff, fee and exam saves do not prepare,
/// render, enqueue, upload or repair a newly generated PDF. A user-initiated
/// Download PDF action may render a fresh, local PDF from saved records.
/// Historical user-uploaded and previously published PDFs remain readable;
/// existing outbox owners may still deliver the original retained bytes.
class WindowsPdfGenerationPolicy {
  const WindowsPdfGenerationPolicy._();

  /// Hard-off. Never turn this on as a performance workaround or migration.
  static const bool generateOnRecordSave = false;
}
