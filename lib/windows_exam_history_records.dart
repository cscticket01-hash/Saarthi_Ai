/// Legacy rows are accepted only from the caller's profile-scoped local ledger.
List<Map<String, dynamic>> windowsExamHistoryRecords(
  Iterable<Map<String, dynamic>> records, {
  required String schoolId,
  String query = '',
  String session = '',
}) {
  final needle = query.trim().toLowerCase();
  final rows = records
      .where((row) {
        final owner = row['schoolId']?.toString() ?? '';
        if (row['deleted'] == true ||
            row['_syncDeleted'] == true ||
            owner.isNotEmpty && owner != schoolId)
          return false;
        if (session.isNotEmpty &&
            (row['academicSession']?.toString() ?? '') != session)
          return false;
        return needle.isEmpty ||
            ['examName', 'studentClass', 'academicSession', 'examId'].any(
              (key) =>
                  (row[key]?.toString() ?? '').toLowerCase().contains(needle),
            );
      })
      .map((row) => Map<String, dynamic>.from(row))
      .toList();
  int stamp(Map<String, dynamic> row) =>
      int.tryParse(row['timestamp']?.toString() ?? '') ?? 0;
  rows.sort((a, b) {
    final order = stamp(b).compareTo(stamp(a));
    return order != 0
        ? order
        : (a['examId']?.toString() ?? '').compareTo(
            b['examId']?.toString() ?? '',
          );
  });
  return rows;
}

List<Map<String, dynamic>> windowsExamHistoryResults(
  Iterable<Map<String, dynamic>> results, {
  required String schoolId,
  required String examId,
}) =>
    results
        .where((row) {
          final owner = row['schoolId']?.toString() ?? '';
          return examId.isNotEmpty &&
              row['examId']?.toString() == examId &&
              row['deleted'] != true &&
              row['_syncDeleted'] != true &&
              (owner.isEmpty || owner == schoolId);
        })
        .map((row) => Map<String, dynamic>.from(row))
        .toList()
      ..sort(
        (a, b) => (a['studentName']?.toString() ?? '').compareTo(
          b['studentName']?.toString() ?? '',
        ),
      );
