import 'windows_secure_storage.dart';

class PromotionSessionPolicy {
  static const monthKey =
      'vidya_saarthi_windows_academic_year_rollover_month_v1';
  static int _lastMonth = 1;
  static Future<int> rolloverMonth() async {
    try {
      final raw = await const WindowsSecureStorage().read(key: monthKey);
      _lastMonth = int.tryParse(raw ?? '') == 4 ? 4 : 1;
    } catch (_) {}
    return _lastMonth;
  }

  static int startYear(DateTime date, int month) =>
      date.month >= (month == 4 ? 4 : 1) ? date.year : date.year - 1;
  static String label(DateTime date, int month) {
    final year = startYear(date, month);
    return '$year-${year + 1}';
  }

  static bool matches(
    Map<String, dynamic> exam,
    DateTime now,
    int month, {
    bool allowPreviousSession = false,
  }) {
    if (exam['completed'] == false ||
        {'draft', 'scheduled', 'in_progress'}.contains(exam['status']))
      return false;
    final session = exam['academicSession']?.toString().trim();
    if (session != null && session.isNotEmpty) {
      final parsed = RegExp(r'^(\d{4})\s*[-–/]\s*(\d{2}|\d{4})$')
          .firstMatch(session);
      if (parsed == null) return false;
      final first = int.parse(parsed.group(1)!),
          last = int.parse(parsed.group(2)!);
      return (first == startYear(now, month) ||
              (allowPreviousSession && first == startYear(now, month) - 1)) &&
          (last == first + 1 || last == (first + 1) % 100);
    }
    final timestamp = exam['timestamp'];
    if (timestamp is num && timestamp.isFinite) {
      final created = DateTime.fromMillisecondsSinceEpoch(timestamp.toInt());
      return created.isBefore(now.add(const Duration(minutes: 5))) &&
          (startYear(created, month) == startYear(now, month) ||
              (allowPreviousSession &&
                  startYear(created, month) == startYear(now, month) - 1));
    }
    // Old definitions without date/session remain compatible. Applying them
    // still requires a saved final result and the correct live pupil identity.
    return true;
  }
}
