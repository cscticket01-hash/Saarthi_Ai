/// Resolution starts the retention clock; reopening clears it.
int complaintMillis(dynamic value) {
  if (value is num) return value.toInt();
  if (value is DateTime) return value.millisecondsSinceEpoch;
  if (value is String)
    return DateTime.tryParse(value)?.millisecondsSinceEpoch ?? 0;
  try {
    return (value.toMillis() as num).toInt();
  } catch (_) {}
  try {
    return (value.millisecondsSinceEpoch as num).toInt();
  } catch (_) {}
  return 0;
}

DateTime? complaintExpiry(Map row) {
  final start = complaintMillis(row['resolvedAt']);
  if (row['status'] != 'resolved' || start <= 0) return null;
  final date = DateTime.fromMillisecondsSinceEpoch(start, isUtc: true);
  final month = DateTime.utc(date.year, date.month + 3, 1);
  final last = DateTime.utc(month.year, month.month + 1, 0).day;
  return DateTime.utc(
    month.year,
    month.month,
    date.day > last ? last : date.day,
    date.hour,
    date.minute,
    date.second,
    date.millisecond,
    date.microsecond,
  );
}

bool complaintExpired(Map row, [DateTime? now]) {
  final end = complaintExpiry(row);
  return row['purging'] == true ||
      end != null && !end.isAfter(now ?? DateTime.now());
}
