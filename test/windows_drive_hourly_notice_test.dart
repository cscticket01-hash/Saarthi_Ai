import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_drive_hourly_notice.dart';

void main() {
  Map<String, dynamic> summary({required int count, String scope = 'liveRecordBackups'}) {
    final end = (DateTime.now().millisecondsSinceEpoch ~/ 3600000) * 3600000;
    return {
      'scope': scope,
      'liveProtocol': 1,
      'hourStart': end - 3600000,
      'hourEnd': end,
      'verifiedCount': count,
    };
  }

  testWidgets('shows only authenticated, completed-hour Drive records for five seconds', (tester) async {
    final evidence = summary(count: 20);
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: WindowsDriveHourlyNotice(summary: evidence,
        nowMillis: () => (evidence['hourEnd'] as int) + 1000))));
    expect(find.textContaining('20 live records'), findsOneWidget);
    expect(find.byKey(const ValueKey('hourly-verified-drive')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(find.byKey(const ValueKey('hourly-verified-drive')), findsNothing);
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: WindowsDriveHourlyNotice(summary: evidence))));
    expect(find.byKey(const ValueKey('hourly-verified-drive')), findsNothing);
  });

  testWidgets('never displays pending counts or unverified summary scopes', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: WindowsDriveHourlyNotice(summary: summary(count: 0),
        nowMillis: () => ((DateTime.now().millisecondsSinceEpoch ~/ 3600000) * 3600000) + 1000))));
    expect(find.byKey(const ValueKey('hourly-verified-drive')), findsNothing);
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: WindowsDriveHourlyNotice(summary: summary(count: 9, scope: 'history25'),
        nowMillis: () => ((DateTime.now().millisecondsSinceEpoch ~/ 3600000) * 3600000) + 1000))));
    expect(find.byKey(const ValueKey('hourly-verified-drive')), findsNothing);
  });
  testWidgets('R2 report covers several lanes but never claims historical legacy uploads', (tester) async {
    final end = (DateTime.now().millisecondsSinceEpoch ~/ 3600000) * 3600000;
    final report = {
      'version': 1,
      'scope': 'r2VerifiedDeliveries',
      'coverage': 'r2-staged-only',
      'partial': true,
      'hourStart': end - 3600000,
      'hourEnd': end,
      'verifiedCount': 4,
      'breakdown': {'records': 1, 'files': 2, 'attendance': 1},
    };
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      WindowsDriveHourlyNotice(summary: report, nowMillis: () => end + 1000))));
    expect(find.textContaining('4 R2-staged transfers'), findsOneWidget);
    expect(find.textContaining('legacy backups excluded'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(find.byKey(const ValueKey('hourly-verified-drive')), findsNothing);
  });

  testWidgets('report missing truthful partial scope is refused', (tester) async {
    final end = (DateTime.now().millisecondsSinceEpoch ~/ 3600000) * 3600000;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      WindowsDriveHourlyNotice(summary: {
        'version': 1, 'scope': 'r2VerifiedDeliveries',
        'partial': false, 'coverage': 'r2-staged-only',
        'hourStart': end - 3600000, 'hourEnd': end,
        'verifiedCount': 10,
      }, nowMillis: () => end + 1000))));
    expect(find.byKey(const ValueKey('hourly-verified-drive')), findsNothing);
  });

}
