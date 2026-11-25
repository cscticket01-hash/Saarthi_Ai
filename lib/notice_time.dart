import 'school_timestamp.dart';

/// Notice timestamps are absolute instants. Display is always IST, regardless
/// of the reader's operating-system time zone. Unknown history is never replaced
/// with the time at which the app happens to open or synchronize.
int? noticeMillis(Object? value) {
  int? at;
  if (value is Timestamp) {
    at = value.millisecondsSinceEpoch;
  } else if (value is DateTime) {
    at = value.millisecondsSinceEpoch;
  } else if (value is num && value.isFinite) {
    at = value.toInt();
    if (at >= 1000000000 && at < 100000000000) at *= 1000;
  } else if (value is Map) {
    final seconds = value['seconds'] ?? value['_seconds'];
    final nanos = value['nanoseconds'] ?? value['_nanoseconds'];
    if (seconds is num && seconds.isFinite) {
      at = seconds.toInt() * 1000 +
          (nanos is num && nanos.isFinite ? nanos.toInt() ~/ 1000000 : 0);
    }
  } else if (value is String) {
    final text = value.trim();
    final numeric = int.tryParse(text);
    if (numeric != null) return noticeMillis(numeric);
    // Date-only strings and timestamps without a known zone cannot prove time.
    if (RegExp(r'[T ]\d{2}:\d{2}.*(?:Z|[+-]\d{2}:?\d{2})$', caseSensitive: false).hasMatch(text)) {
      at = DateTime.tryParse(text)?.millisecondsSinceEpoch;
    }
  }
  return at != null && at >= 100000000000 && at < 253402300800000 ? at : null;
}

int? noticeCreatedMillis(Map<String, dynamic> notice) =>
    noticeMillis(notice['timestamp']) ?? noticeMillis(notice['createdAt']);

int? noticePublishedMillis(Map<String, dynamic> notice) =>
    noticeMillis(notice['publishedAt']);

int? noticeOrderMillis(Map<String, dynamic> notice) =>
    noticePublishedMillis(notice) ?? noticeCreatedMillis(notice);

int? noticeEditedMillis(Map<String, dynamic> notice) {
  final original = noticeCreatedMillis(notice);
  final edited = noticeMillis(notice['lastEdited']);
  return edited != null && (original == null || edited > original) ? edited : null;
}

String formatNoticeIst(int? millis) {
  if (millis == null) return 'Date/time unavailable';
  final d = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true)
      .add(const Duration(hours: 5, minutes: 30));
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '${d.day.toString().padLeft(2, '0')} ${months[d.month - 1]} ${d.year} · ${hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'} IST';
}

String noticeDateLabel(Map<String, dynamic> notice) {
  final published = noticePublishedMillis(notice);
  final original = noticeCreatedMillis(notice);
  if (published != null) return 'Published: ${formatNoticeIst(published)}';
  if (original == null) return 'Date/time unavailable';
  return '${notice['noticeTimeVersion'] == 1 ? 'Created' : 'Notice date'}: ${formatNoticeIst(original)}';
}

String? noticeEditLabel(Map<String, dynamic> notice) {
  final edited = noticeEditedMillis(notice);
  return edited == null ? null : 'Edited: ${formatNoticeIst(edited)}';
}

List<Map<String, dynamic>> sortedNoticeRows(Iterable<Map<String, dynamic>> rows) =>
    rows.toList()..sort((a, b) => (noticeOrderMillis(b) ?? 0).compareTo(noticeOrderMillis(a) ?? 0));

/// Keep the initial creation date stable. Never assign a publish receipt on
/// the device: offline creation and successful server acceptance differ.
Map<String, dynamic> noticeSaveTimes(Map<String, dynamic>? existing,
    Map<String, dynamic> incoming, int now) {
  final result = Map<String, dynamic>.of(incoming)
    ..remove('timestamp')..remove('createdAt')..remove('publishedAt')
    ..remove('lastEdited')..remove('noticeTimeVersion');
  if (existing == null) {
    final original = noticeCreatedMillis(incoming) ?? now;
    result.addAll({'timestamp': original, 'createdAt': original, 'noticeTimeVersion': 1});
  } else {
    final original = noticeCreatedMillis(existing);
    if (original != null) {
      result['timestamp'] = original;
      result['createdAt'] = original;
    }
    if (noticePublishedMillis(existing) case final int published) {
      result['publishedAt'] = published;
    }
    if (existing['noticeTimeVersion'] == 1) result['noticeTimeVersion'] = 1;
    result['lastEdited'] = now;
  }
  return result;
}
