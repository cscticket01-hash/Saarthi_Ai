import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/main_android.dart' as app;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android first screen renders while notification initialization is blocked', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final previous = FlutterLocalNotificationsPlatform.instance;
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
      expect(find.text('Scan your school ID'), findsOneWidget);
      expect(initializeCalls, 1);
      expect(pending.isCompleted, false);
      pending.complete(true);
      await tester.pump();
    } finally {
      if (!pending.isCompleted) pending.complete(true);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      FlutterLocalNotificationsPlatform.instance = previous;
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
