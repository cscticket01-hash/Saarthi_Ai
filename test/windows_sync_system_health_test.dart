import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_sync_system_health.dart';

void main() {
  testWidgets('disposing a real probe cancels its outstanding deadline', (tester) async {
    final probe = SyncInternetProbe();
    final pending = probe.check();
    probe.dispose();
    expect(await pending, InternetHealth.unknown);
  });

  testWidgets('offline hides services; reconnection shows only verified results', (tester) async {
    var network = InternetHealth.offline;
    var repair = SyncHealth.failed;
    var serverChecks = 0;
    await tester.pumpWidget(MaterialApp(home: MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: Scaffold(body: WindowsSyncSystemHealth(
        internetProbe: () async => network,
        schoolServer: () async { serverChecks++; return SyncHealth.healthy; },
        selfRepair: () async => repair,
        mobileServer: () async => SyncHealth.unknown,
        isCurrentSchool: () => true,
      )),
    )));
    await tester.pump();
    expect(find.text('System Offline'), findsOneWidget);
    expect(find.text('School Server'), findsNothing);
    expect(serverChecks, 0);
    network = InternetHealth.connected;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('System Offline'), findsNothing);
    expect(find.text('Student Android App Server'), findsOneWidget);
    expect(find.byTooltip('Verified'), findsNWidgets(2));
    expect(find.byTooltip('Failed'), findsOneWidget);
    expect(find.byTooltip('Not verified / paused'), findsOneWidget);
    repair = SyncHealth.healthy;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.byTooltip('Verified'), findsNWidgets(3));
    network = InternetHealth.offline;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('System Offline'), findsOneWidget);
    expect(find.byTooltip('Verified'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
