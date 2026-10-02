import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/main_windows.dart';
import '../lib/windows_license_gate.dart';
import '../lib/windows_admin_setup.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_local_session.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_local_settings.dart';
import '../lib/windows_online_startup.dart';
import '../lib/windows_platform_client.dart';
import '../lib/windows_ui_localization.dart' as ui;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsLocalSecurity.initialize();
    await WindowsLocalSession.initialize();
    ui.WindowsUiLanguage.change('en');
    WindowsPlatformClient.skippedOverride = null;
    WindowsAdminSetup.completedOverride = null;
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    // Create the shared local database/write queue outside a widget test's
    // FakeAsync zone, so later tests cannot inherit a dead callback clock.
    await FirebaseFirestore.instance.collection('school_config')
        .doc('school_profile_cache').get();
    WindowsPlatformClient.instance.state.value = WindowsLicenseState(
      allowed: true,
      status: 'trial',
      expiresAt: DateTime.now().add(const Duration(days: 5)),
    );
  });

  tearDown(() => ui.WindowsUiLanguage.change('en'));

  Future<void> _skipLicence(WidgetTester tester) async {
    WindowsPlatformClient.skippedOverride = true;
    WindowsAdminSetup.completedOverride = true;
    await tester.pumpWidget(VidyaSaarthiWindowsApp(
      initializeConnections: () async {},
    ));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('licence key screen is shown first with only Activate and Skip',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(VidyaSaarthiWindowsApp(
      initializeConnections: () async {},
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('Activate Vidya Saarthi'), findsOneWidget);
    expect(find.textContaining('Activate / Verify license').hitTestable(), findsOneWidget);
    final skip = find.byKey(const ValueKey('license-skip-button'));
    expect(skip.hitTestable(), findsOneWidget);
    // Removed from the first screen: connection settings, Check again, login errors.
    expect(find.text('School connection settings'), findsNothing);
    expect(find.text('Check again'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('skip opens local-first Admin Setup on a fresh install',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    WindowsPlatformClient.skippedOverride = false;
    WindowsAdminSetup.completedOverride = false;
    await tester.pumpWidget(VidyaSaarthiWindowsApp(
      initializeConnections: () async {},
    ));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('license-skip-button')));
    await tester.pump();
    await tester.pump();

    expect(find.text('Admin Setup'), findsOneWidget);
    expect(find.text('School Name *'), findsOneWidget);
    expect(find.text('Principal Name *'), findsOneWidget);
    expect(find.text('Admin Password *'), findsOneWidget);
    expect(find.text('School Logo'), findsOneWidget);
    expect(find.text('School Seal'), findsOneWidget);
    expect(find.text('Principal / Authorized Signature'), findsOneWidget);
    expect(find.text('Save & Open App').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('skipped licence keeps a red warning until activation',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _skipLicence(tester);

    final banner = find.byKey(const ValueKey('license-not-activated-banner'));
    expect(banner, findsOneWidget);
    expect(find.text('License not activated — Activate now'), findsOneWidget);
    expect(tester.getTopLeft(banner).dy, lessThan(60));

    await tester.tap(banner);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Activate Vidya Saarthi'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('License not activated — Activate now'), findsOneWidget);

    // A valid activation removes the warning.
    WindowsPlatformClient.skippedOverride = false;
    WindowsPlatformClient.instance.state.value = WindowsLicenseState(
        allowed: true,
        status: 'licensed',
        expiresAt: DateTime.now().add(const Duration(days: 365)));
    await tester.pump();
    expect(find.text('License not activated — Activate now'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('existing installs go straight to the locked app after skip',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      'vidya_saarthi_windows_admin_id_v1': 'School Admin',
      'vidya_saarthi_windows_admin_password_v1': 'saved-password',
      WindowsPlatformClient.licenseSkippedKey: 'true',
    });
    await WindowsLocalSecurity.initialize();
    WindowsAdminSetup.completedOverride = true;
    await tester.pumpWidget(VidyaSaarthiWindowsApp(
      initializeConnections: () async {},
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('Vidya Saarthi Locked'), findsOneWidget);
    expect(find.text('Unlock App'), findsOneWidget);
    expect(find.text('Admin Setup'), findsNothing);
    await tester.enterText(find.byType(TextField), 'wrong-password');
    await tester.tap(find.text('Unlock App'));
    await tester.pump();
    expect(find.text('Galat App Password.'), findsOneWidget);
    expect(WindowsLocalSecurity.verifyPassword('saved-password'), isTrue);
    expect(find.text('License not activated — Activate now'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expired licences cannot reach the startup skip button', (tester) async {
    WindowsPlatformClient.instance.state.value = WindowsLicenseState(
      allowed: false,
      status: 'expired',
      expiresAt: DateTime.now().subtract(const Duration(days: 1)),
    );
    var checks = 0;
    await tester.pumpWidget(VidyaSaarthiWindowsApp(
      initializeConnections: () async { checks++; },
    ));
    await tester.pump();
    expect(find.byKey(const ValueKey('license-skip-button')), findsNothing);
    expect(find.text('Activate Vidya Saarthi'), findsOneWidget);
    expect(checks, 0);
    expect(tester.getSize(find.byType(WindowsLicenseGate)).width, 800);
    expect(tester.takeException(), isNull);
  });

  testWidgets('successful optional check opens the app automatically', (tester) async {
    await tester.pumpWidget(MaterialApp(home: WindowsOnlineStartupGate(
      initializeConnections: () async {},
      child: const Scaffold(body: Text('Local app')),
    )));
    await tester.pump();
    expect(find.text('Local app'), findsOneWidget);
    expect(find.byKey(const ValueKey('windows-startup-skip')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('connection failure offers retry and a working skip', (tester) async {
    var checks = 0;
    await tester.pumpWidget(MaterialApp(home: WindowsOnlineStartupGate(
      initializeConnections: () async {
        checks++;
        throw StateError('School network unavailable');
      },
      child: const Scaffold(body: Text('Local app')),
    )));
    await tester.pump();
    expect(find.text('Online check is unavailable. You can still open the app.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('windows-startup-retry')));
    await tester.pump();
    expect(checks, 2);
    await tester.tap(find.byKey(const ValueKey('windows-startup-skip')));
    await tester.pump();
    expect(find.text('Local app'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late online completion cannot interrupt a skipped startup', (tester) async {
    final check = Completer<void>();
    await tester.pumpWidget(MaterialApp(home: WindowsOnlineStartupGate(
      initializeConnections: () => check.future,
      child: const Scaffold(body: TextField()),
    )));
    await tester.tap(find.byKey(const ValueKey('windows-startup-skip')));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Keep my work');
    check.complete();
    await tester.pump();
    expect(find.text('Keep my work'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('slow connection times out visibly and skip works in a short window',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final check = Completer<void>();
    await tester.pumpWidget(MaterialApp(home: WindowsOnlineStartupGate(
      initializeConnections: () => check.future,
      child: const Scaffold(body: Text('Local app')),
    )));
    await tester.pump(const Duration(seconds: 9));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final skip = find.byKey(const ValueKey('windows-startup-skip'));
    await tester.ensureVisible(skip);
    await tester.tap(skip);
    await tester.pump();
    expect(find.text('Local app'), findsOneWidget);
    check.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('offline setup saves a password and opens home without waiting for cloud',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final check = Completer<void>();
    WindowsPlatformClient.skippedOverride = false;
    WindowsAdminSetup.completedOverride = false;
    await tester.pumpWidget(VidyaSaarthiWindowsApp(initializeConnections: () => check.future));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('license-skip-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Offline School');
    await tester.enterText(fields.at(1), 'Principal One');
    await tester.enterText(fields.at(2), '1234');
    await tester.enterText(fields.at(3), '1234');
    await tester.tap(find.text('Save & Open App'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('at least 6 characters'), findsOneWidget);
    expect(WindowsLocalSecurity.configured, isFalse);
    await tester.enterText(fields.at(2), 'secure-password');
    await tester.enterText(fields.at(3), 'secure-password');
    await tester.tap(find.text('Save & Open App'));
    // Disk IO runs in real time; Flutter callback continuations and frames run
    // in the test's fake clock. Advance both until the save and route finish.
    for (var i = 0; i < 100 && find.text('Digital Notice Board').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(WindowsLocalSecurity.verifyPassword('secure-password'), isTrue,
        reason: tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join(' | '));
    expect(find.text('Digital Notice Board'), findsOneWidget);
    expect(find.text('License not activated — Activate now'), findsOneWidget);
    expect(find.text('Admin Setup'), findsNothing);
    expect(find.text('Checking school connections. You can open the app offline.'), findsNothing);
    check.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
