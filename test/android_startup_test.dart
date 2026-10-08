import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/main_android.dart' as app;
import '../lib/mobile/startup_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('blocked secure restore paints a screen without granting access', (tester) async {
    final pending = Completer<void>();
    var readyCalls = 0;
    await tester.pumpWidget(MobileStartupGate(
      restore: () => pending.future,
      readyBuilder: (_) => const MaterialApp(home: Text('Protected dashboard')),
      onReady: () => readyCalls++,
    ));
    expect(find.text('Opening your saved school session…'), findsOneWidget);
    expect(find.text('Protected dashboard'), findsNothing);
    await tester.pump(const Duration(seconds: 9));
    expect(find.textContaining('Secure storage is taking longer'), findsOneWidget);
    expect(readyCalls, 0);
    pending.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Protected dashboard'), findsOneWidget);
    expect(readyCalls, 1);
  });

  testWidgets('secure restore failure is visible and retry does not overlap', (tester) async {
    var calls = 0;
    final retry = Completer<void>();
    await tester.pumpWidget(MobileStartupGate(
      restore: () { calls++; return calls == 1 ? Future<void>.error(StateError('storage')) : retry.future; },
      readyBuilder: (_) => const MaterialApp(home: Text('Protected dashboard')),
    ));
    await tester.pump();
    expect(find.textContaining('saved data has not been cleared'), findsOneWidget);
    expect(find.text('Protected dashboard'), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(calls, 2);
    expect(find.text('Protected dashboard'), findsNothing);
    retry.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Protected dashboard'), findsOneWidget);
  });

  testWidgets('Android first screen renders while notification initialization is blocked', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterLocalNotificationsPlatform.instance = AndroidFlutterLocalNotificationsPlugin();
    final pending = Completer<bool>();
    var initializeCalls = 0;
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'initialize') {
        initializeCalls++;
        return pending.future;
      }
      return null;
    });
    try {
      await tester.runAsync(() => app.main().timeout(const Duration(seconds: 2)));
      await tester.pump();
      await tester.pump();
      expect(find.text('Scan your school ID'), findsOneWidget);
      expect(initializeCalls, 1);
      expect(pending.isCompleted, false);
      pending.complete(true);
      await tester.pump();
    } finally {
      if (!pending.isCompleted) pending.complete(true);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
