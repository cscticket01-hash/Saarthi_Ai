/// School-scoped, selected-month fee ledger visibility policy.
///
/// This is strictly a *display* filter. It does not update, discard or
/// acknowledge payments. A partial installment is already a payment, so the
/// student is no longer in the "not yet paid" queue. Other student/ledger
/// stream ownership and duplicate-payment protection remain unchanged.
bool showInUnpaidStudentList(Map<String, dynamic>? ledger) {
  if (ledger == null) return true;
  final amount = ledger['totalPaid'];
  final paid = amount is num
      ? amount.toDouble()
      : double.tryParse(amount?.toString() ?? '') ?? 0.0;
  if (paid > 0) return false;
  final status = (ledger['status'] ?? '').toString().toUpperCase();
  if (status == 'PAID' || status == 'PARTIAL' || status == 'PARTIAL PAID') {
    return false;
  }
  final paymentId = ledger['lastPaymentId']?.toString().trim() ?? '';
  return paymentId.isEmpty;
}
