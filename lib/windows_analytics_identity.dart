/// Analytics identities are scoped by the caller's selected school profile.
/// Distinct immutable student IDs must never be collapsed by a shared name.
String windowsAnalyticsStudentIdentity(Map<String, dynamic> record, int position) {
  String value(List<String> keys) {
    for (final key in keys) {
      final text = record[key]?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
  }
  final stable = value(const ['uniqueStudentId', 'studentUid', 'studentUidTest',
    'studentId', 'admissionNo', 'admissionNumber']);
  if (stable.isNotEmpty) return 'uid:$stable';
  final document = value(const ['_analyticsDocId']);
  if (document.isNotEmpty) return 'doc:$document';
  // Missing IDs are unknown identity, not evidence that matching names belong
  // to the same child. Count separate records until their identities are fixed.
  return 'unknown:$position';
}

List<Map<String, dynamic>> windowsAnalyticsUniqueStudents(List<Map<String, dynamic>> records) {
  final unique = <String, Map<String, dynamic>>{};
  for (var i = 0; i < records.length; i++) {
    unique.putIfAbsent(windowsAnalyticsStudentIdentity(records[i], i), () => records[i]);
  }
  return unique.values.toList();
}
