import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/mobile/attendance_history.dart';

void main() {
  test(
    'cloud ACK invalidates history without a manual refresh and coalesces notifications',
    () async {
      final signal = ValueNotifier(0);
      var ack = '', calls = 0;
      final requests = <Completer<List<Map<String, dynamic>>>>[];
      final history = AttendanceHistoryController(
        load: (_) {
          calls++;
          final request = Completer<List<Map<String, dynamic>>>();
          requests.add(request);
          return request.future;
        },
        cached: (_) => null,
        confirmations: signal,
        confirmationKey: () => ack,
      );
      final initial = history.selectMonth('2026-10');
      expect(history.ready, false);
      expect(calls, 1);
      // ACK arrives while an old read is in flight. One trailing read is essential.
      ack = 'verified-cloud-ACK';
      signal.value++;
      signal.value++;
      requests[0].complete([]);
      await initial;
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
      requests[1].complete([
        {'date': '2026-10-19', 'checkIn': 123},
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(history.rows.where((r) => r['checkIn'] != null).length, 1);
      expect(history.ready, true);
      signal.value++;
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
      history.dispose();
      signal.dispose();
    },
  );
  test(
    'cached confirmed count displays immediately and survives failed refresh',
    () async {
      final signal = ValueNotifier(0);
      final history = AttendanceHistoryController(
        load: (_) async => throw StateError('offline'),
        cached: (_) => [
          {'date': '2026-10-19', 'checkIn': 123},
        ],
        confirmations: signal,
        confirmationKey: () => '',
      );
      final load = history.selectMonth('2026-10');
      expect(history.ready, true);
      expect(history.rows.length, 1);
      await load;
      expect(history.rows.length, 1);
      expect(history.error, isNotNull);
      history.dispose();
      signal.dispose();
    },
  );
  test('month switch rejects late previous-month responses', () async {
    final signal = ValueNotifier(0);
    final old = Completer<List<Map<String, dynamic>>>();
    final history = AttendanceHistoryController(
      load: (month) => month == '2026-09'
          ? old.future
          : Future.value([
              {'date': '2026-10-19', 'checkIn': 123},
            ]),
      cached: (_) => null,
      confirmations: signal,
      confirmationKey: () => '',
    );
    final prior = history.selectMonth('2026-09');
    await history.selectMonth('2026-10');
    old.complete([
      {'date': '2026-09-01', 'checkIn': 1},
    ]);
    await prior;
    expect(history.rows.single['date'], '2026-10-19');
    history.dispose();
    signal.dispose();
  });
}
