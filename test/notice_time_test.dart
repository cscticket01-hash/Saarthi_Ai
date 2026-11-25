import 'package:flutter_test/flutter_test.dart';
import '../lib/notice_time.dart';
import '../lib/school_timestamp.dart';

void main() {
  final initial = DateTime.utc(2026, 11, 25, 10, 5).millisecondsSinceEpoch;
  final later = initial + 3600000;
  test('IST is identical for numeric, timestamp and serialized values', () {
    for (final input in [initial, initial.toString(), initial ~/ 1000,
      Timestamp.fromDate(DateTime.fromMillisecondsSinceEpoch(initial, isUtc: true)),
      {'seconds': initial ~/ 1000}, '2026-11-25T10:05:00Z']) {
      expect(formatNoticeIst(noticeMillis(input)), '25 Nov 2026 · 03:35 PM IST');
    }
    expect(formatNoticeIst(noticeMillis('2026-11-25')), 'Date/time unavailable');
  });
  test('editing retains original time and a separate edit time', () {
    final first = noticeSaveTimes(null, {'title': 'Original'}, initial);
    expect(noticeEditLabel(first), isNull);
    final edit = noticeSaveTimes(first, {'title': 'Edited', 'timestamp': later}, later);
    expect(edit['timestamp'], initial);
    expect(edit['lastEdited'], later);
    expect(noticeDateLabel(edit), 'Created: 25 Nov 2026 · 03:35 PM IST');
    expect(noticeEditLabel(edit), 'Edited: 25 Nov 2026 · 04:35 PM IST');
    expect(edit.containsKey('publishedAt'), isFalse);
  });
  test('never invent publication proof for an offline save; preserve existing proof', () {
    final first = noticeSaveTimes(null, {'publishedAt': later}, initial);
    expect(first['publishedAt'], isNull);
    final edit = noticeSaveTimes({...first, 'publishedAt': later}, {}, later + 1000);
    expect(edit['publishedAt'], later);
    expect(noticeDateLabel(edit), 'Published: 25 Nov 2026 · 04:35 PM IST');
  });
  test('legacy unknown time remains unknown; latest original notice comes first', () {
    final legacy = noticeSaveTimes({'title': 'Old'}, {}, later);
    expect(legacy.containsKey('timestamp'), isFalse);
    expect(noticeDateLabel(legacy), 'Date/time unavailable');
    final a = {'title': 'A', 'timestamp': initial, 'lastEdited': later + 5000};
    final b = {'title': 'B', 'timestamp': later};
    expect(sortedNoticeRows([a, b, legacy]).map((r) => r['title']).take(2), ['B', 'A']);
  });
}
