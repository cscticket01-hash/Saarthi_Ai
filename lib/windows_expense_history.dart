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
            ['title', 'category', 'paidTo', 'note', 'dateText', 'amount'].any(
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

int _expenseTime(Map<String, dynamic> row) {
  final raw = row['timestamp'];
  final timestamp = raw is num ? raw : num.tryParse(raw?.toString() ?? '');
  if (timestamp != null && timestamp.isFinite && timestamp > 0)
    return timestamp.toInt();
  final date = row['dateText']?.toString() ?? '';
  final iso = DateTime.tryParse(date);
  if (iso != null) return iso.millisecondsSinceEpoch;
  final match = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$').firstMatch(date);
  if (match == null) return 0;
  final day = int.parse(match[1]!),
      month = int.parse(match[2]!),
      year = int.parse(match[3]!);
  final parsed = DateTime(year, month, day);
  return parsed.year == year && parsed.month == month && parsed.day == day
      ? parsed.millisecondsSinceEpoch
      : 0;
}
