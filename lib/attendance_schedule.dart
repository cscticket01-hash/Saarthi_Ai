/// School attendance uses India time, independent of the device timezone.
DateTime attendanceIndiaTime(DateTime at) =>
    at.toUtc().add(const Duration(hours: 5, minutes: 30));

String attendanceDay(DateTime at) =>
    attendanceIndiaTime(at).toIso8601String().substring(0, 10);

bool attendanceWindowAllows(dynamic schedule, DateTime at) {
  if (schedule == null) return true; // Existing schools: no window configured.
  if (schedule is! Map) return false;
  if (schedule['enabled'] == false) return true;
  final start = schedule['startMinute'], end = schedule['endMinute'];
  if (schedule['enabled'] != true ||
      start is! int ||
      end is! int ||
      start < 0 ||
      end > 1440 ||
      start >= end)
    return false;
  final india = attendanceIndiaTime(at);
  final minute = india.hour * 60 + india.minute;
  return minute >= start && minute < end;
}
