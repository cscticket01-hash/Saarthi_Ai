/// Read-only projection of the active school's existing expense records.
/// No alternate ledger, queue write, deletion or cloud acknowledgement.
List<Map<String, dynamic>> windowsExpenseHistory(
  Iterable<Map<String, dynamic>> records, {
  required String schoolId,
  String query = '',
}) {
  final search = query.trim().toLowerCase();
  final rows = records
      .where((row) {
        if (row['deleted'] == true || row['_syncDeleted'] == true) return false;
        final owner = row['schoolId']?.toString() ?? '';
        if (owner.isNotEmpty && owner != schoolId) return false;
        return search.isEmpty ||
            ['expenseId', 'title', 'category', 'paidTo', 'note', 'dateText', 'amount'].any(
              (key) =>
                  (row[key]?.toString() ?? '').toLowerCase().contains(search),
            );
      })
      .map((row) => Map<String, dynamic>.from(row))
      .toList();
  rows.sort((a, b) {
    final order = _expenseTime(b).compareTo(_expenseTime(a));
    return order != 0
        ? order
        : (b['expenseId']?.toString() ?? '').compareTo(
            a['expenseId']?.toString() ?? '',
          );
  });
  return rows;
}

/// Transaction date is distinct from creation/synchronization time.
DateTime? windowsExpenseDate(Map<String,dynamic> row) {
  final date = row['dateText']?.toString().trim() ?? '';
  final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(date);
  final local = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$').firstMatch(date);
  if (iso != null || local != null) {
    final match = iso ?? local!;
    final year = int.parse(match[iso != null ? 1 : 3]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[iso != null ? 3 : 1]!);
    final parsed = DateTime(year, month, day);
    if (parsed.year == year && parsed.month == month && parsed.day == day) return parsed;
  }
  final raw = row['timestamp'];
  final timestamp = raw is num ? raw : num.tryParse(raw?.toString() ?? '');
  if (timestamp != null && timestamp.isFinite && timestamp > 0 && timestamp <= 8640000000000000) {
    return DateTime.fromMillisecondsSinceEpoch(timestamp.toInt());
  }
  return null;
}

int _expenseTime(Map<String,dynamic> row) =>
    windowsExpenseDate(row)?.millisecondsSinceEpoch ?? 0;

/// Totals use integer paise; corrupt or nonpositive amounts are not counted.
int windowsExpensePaise(Map<String,dynamic> row) {
  final amount = num.tryParse(row['amount']?.toString() ?? '');
  if (amount == null || !amount.isFinite || amount <= 0 || amount > 999999999.99) return 0;
  return (amount * 100).round();
}
