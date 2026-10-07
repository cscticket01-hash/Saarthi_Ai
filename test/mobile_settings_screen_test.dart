import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/mobile/settings_screen.dart';
void main() {
  final update = {'versionName':'1.0.496', 'versionCode':496,
    'apkUrl':'https://github.com/cscticket01-hash/Saarthi_Ai/releases/download/android-v1.0.496/Vidya-Saarthi-v1.0.496.apk'};
  testWidgets('About shows installed version, build and shipped changes', (t) async {
    await t.pumpWidget(MaterialApp(home: MobileSettingsScreen(version:'1.0.495-review',build:495,
      checkUpdate: () async => {'update':update}, installUpdate: (_) async {})));
    await t.tap(find.text('About')); await t.pumpAndSettle();
    expect(find.text('Vidya Saarthi'), findsOneWidget);
    expect(find.text('Installed version: 1.0.495-review'), findsOneWidget);
    expect(find.text('Build: 495'), findsOneWidget);
    expect(find.text("What's New"), findsOneWidget);
  });
  testWidgets('Update button executes provider and delegates verified result to installer', (t) async {
    var calls = 0, installs = 0;
    await t.pumpWidget(MaterialApp(home: MobileSettingsScreen(version:'1.0.495-review',build:495,
      checkUpdate: () async { calls++; return {'update':update}; },
      installUpdate: (u) async { expect(u, update); installs++; })));
    await t.tap(find.text('App Update')); await t.pumpAndSettle();
    await t.tap(find.text('Check for Updates')); await t.pumpAndSettle();
    expect(calls, 1); expect(find.text('Latest version: 1.0.496'), findsOneWidget);
    await t.tap(find.text('Download update')); await t.pumpAndSettle(); expect(installs, 1);
  });
  testWidgets('Update failures remain retryable', (t) async {
    await t.pumpWidget(MaterialApp(home: MobileAppUpdateScreen(version:'test',build:495,
      checkUpdate: () async => throw StateError('offline'), installUpdate: (_) async {})));
    await t.tap(find.text('Check for Updates')); await t.pumpAndSettle();
    expect(find.text('Unable to check updates. Please try again.'), findsOneWidget);
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Check for Updates')).onPressed, isNotNull);
  });
  testWidgets('Brand fits narrow header without internal school ID or refresh', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(appBar: null,
      body: SizedBox(width: 220, child: VidyaSaarthiBrand()))));
    expect(find.text('Vidya Saarthi'), findsOneWidget); expect(t.takeException(), isNull);
    expect(find.byIcon(Icons.refresh), findsNothing);
  });
}
