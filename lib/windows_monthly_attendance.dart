/// Calendar-day attendance, not a repeated overall percentage for all months.
/// Duplicate QR scans/check-outs count once. Closed and future days do not count.
List<double> windowsMonthlyAttendance({
  required Iterable<Map<String, dynamic>> records,
  required Iterable<Map<String, dynamic>> calendar,
  required String role, required int people, required int startYear,
  required int rolloverMonth, required DateTime today,
}) {
  final result = List<double>.filled(12, 0);
  if (people <= 0) return result;
  final overrides = <String, bool>{for (final d in calendar)
    if (d['date'] is String && d['isOpen'] is bool) d['date'] as String: d['isOpen'] as bool};
  String key(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  bool open(DateTime d) => overrides[key(d)] ?? d.weekday != DateTime.sunday;
  final days = List<int>.filled(12, 0);
  final until = DateTime(today.year, today.month, today.day);
  for (var d = DateTime(startYear, rolloverMonth); d.isBefore(DateTime(startYear + 1, rolloverMonth)) && !d.isAfter(until); d = DateTime(d.year, d.month, d.day + 1)) {
    if (open(d)) days[d.month - 1]++;
  }
  final present = List<Set<String>>.generate(12, (_) => <String>{});
  for (final row in records) {
    if (row['role'] != role || row['checkIn'] == null || row['checkIn'] == 0) continue;
    final day = DateTime.tryParse(row['date']?.toString() ?? '');
    final id = row['personId']?.toString() ?? row['documentId']?.toString() ?? '';
    if (day == null || id.isEmpty || day.isAfter(until) || !open(day)) continue;
    if ((day.month >= rolloverMonth ? day.year : day.year - 1) != startYear) continue;
    present[day.month - 1].add('$id/${key(day)}');
  }
  for (var i = 0; i < 12; i++) {
    if (days[i] > 0) result[i] = (present[i].length * 100 / (people * days[i])).clamp(0, 100).toDouble();
  }
  return result;
}
