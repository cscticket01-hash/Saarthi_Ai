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
      body: WindowsDriveHourlyNotice(summary: evidence))));
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
      body: WindowsDriveHourlyNotice(summary: summary(count: 0)))));
    expect(find.byKey(const ValueKey('hourly-verified-drive')), findsNothing);
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: WindowsDriveHourlyNotice(summary: summary(count: 9, scope: 'history25')))));
    expect(find.byKey(const ValueKey('hourly-verified-drive')), findsNothing);
  });
}
