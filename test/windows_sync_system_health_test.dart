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

  testWidgets('session monitor does not replay unchanged status and retains off-page recovery', (tester) async {
    var repair = SyncHealth.healthy;
    var network = InternetHealth.connected;
    final monitor = WindowsSyncHealthMonitor(
      internetProbe: () async => network,
      schoolServer: () async => SyncHealth.healthy,
      selfRepair: () async => repair,
      mobileServer: () async => SyncHealth.healthy,
      isCurrentSchool: () => true,
    );
    Widget page() => MaterialApp(home: Scaffold(body: WindowsSyncSystemHealth(
      monitor: monitor,
      schoolServer: () async => SyncHealth.healthy,
      selfRepair: () async => repair,
      mobileServer: () async => SyncHealth.healthy,
      isCurrentSchool: () => true,
    )));
    final pulses = find.byWidgetPredicate((w) => w is TweenAnimationBuilder<double>);
    await tester.pumpWidget(page());
    await tester.pump();
    expect(pulses, findsNWidgets(4));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    await tester.pump();
    expect(pulses, findsNothing);
    await tester.pump(const Duration(seconds: 5));
    expect(pulses, findsNothing);

    repair = SyncHealth.failed;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.byTooltip('Failed'), findsOneWidget);
    expect(pulses, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    repair = SyncHealth.healthy;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    await tester.pumpWidget(page());
    await tester.pump();
    expect(find.byTooltip('Verified'), findsNWidgets(4));
    expect(pulses, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    await tester.pump();
    expect(pulses, findsNothing);

    // Failure and recovery both occur while no health widget is mounted.
    await tester.pumpWidget(const SizedBox());
    repair = SyncHealth.failed;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    repair = SyncHealth.healthy;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    await tester.pumpWidget(page());
    await tester.pump();
    expect(find.byTooltip('Verified'), findsNWidgets(4));
    expect(pulses, findsOneWidget);

    network = InternetHealth.offline;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('System Offline'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    await tester.pump();
    expect(find.text('System Offline'), findsOneWidget);
    expect(find.byKey(const ValueKey('offline-0')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    monitor.dispose();
  });
}
