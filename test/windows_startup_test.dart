import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/main_windows.dart';
import '../lib/windows_license_gate.dart';
import '../lib/windows_local_session.dart';
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
    expect(find.byKey(const ValueKey('license-skip-button')), findsNothing);
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
    await tester.pumpAndSettle();
    expect(find.text('Activate Vidya Saarthi'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
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

  testWidgets('real app renders a full-width startup and opens local setup on skip',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _skipLicence(tester);

    expect(tester.getSize(find.byType(Navigator).first).width, 1400);
    expect(find.textContaining('Free trial:'), findsOneWidget);

    expect(find.text('CREATE LOCAL SETTINGS LOCK'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(3));
    expect(tester.getSize(find.byType(TextField).first).width, greaterThan(300));
    expect(find.text('Create Lock & Open App').hitTestable(), findsOneWidget);
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
    expect(find.byKey(const ValueKey('license-skip-button')), findsNothing);
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
    await tester.tap(find.byKey(const ValueKey('license-skip-button')));
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
    await tester.tap(find.byKey(const ValueKey('license-skip-button')));
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

  testWidgets('full app routes and language changes retain their usable width',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(VidyaSaarthiWindowsApp(
      initializeConnections: () async {},
    ));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(WindowsFirstRunSecuritySetup));
    Navigator.of(context).pushNamed('/local-login');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Existing school admin');
    ui.WindowsUiLanguage.change('hi');
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(Navigator).first).width, 1200);
    expect(find.text('Existing school admin'), findsOneWidget);
    expect(tester.getSize(find.byType(TextField).first).width, greaterThan(300));
    expect(tester.takeException(), isNull);
  });
}
