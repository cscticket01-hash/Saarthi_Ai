import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_sync_performance.dart';

void main() {
  testWidgets('no invented timings before a real sample', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: WindowsSyncPerformance(summary: {}))));
    await tester.tap(find.text('Measured sync timings')); await tester.pumpAndSettle();
    expect(find.text('No measured samples yet.'), findsOneWidget);
    expect(find.byType(DataTable), findsNothing);
  });
  testWidgets('durations use their measured units and unknown data cannot enter the table', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WindowsSyncPerformance(summary: {
      'cloudAckMicros': {'samples': 2, 'p50': 1000, 'p95': 2000, 'p99': 2000},
      'edgeQueueWaitMillis': {'samples': 1, 'p50': 350, 'p95': 350, 'p99': 350},
      'private-school-name': {'samples': 1, 'p50': 9, 'p95': 9, 'p99': 9},
      'syncCycleMicros': {'samples': 0, 'p50': -1},
    }))));
    await tester.tap(find.text('Measured sync timings')); await tester.pumpAndSettle();
    expect(find.text('1.0 ms'), findsOneWidget);
    expect(find.text('2.0 ms'), findsNWidgets(2));
    expect(find.text('350.0 ms'), findsNWidgets(3));
    expect(find.text('private-school-name'), findsNothing);
    expect(find.text('Completed sync cycle'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
