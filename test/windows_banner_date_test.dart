import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import '../lib/main_dashboard_screen_windows.dart' show WindowsLicenseSettingsPanel, WindowsLicenseStore;
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/platform/platform_config.dart';

import '../lib/windows_license_gate.dart';
import '../lib/windows_platform_client.dart';

void main() {
  for (final savedOnDevice in [false, true]) {
    testWidgets('same school licence actions with local key $savedOnDevice', (tester) async {
      const keyStorage = 'vidya_saarthi_windows_license_key_v1';
      FlutterSecureStorage.setMockInitialValues({
        CentralSchoolCloud.key: jsonEncode({'managed': true, 'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'projectId': platformProjectId, 'folderId': 'managed', 'uid': 'synthetic-school',
          'firebaseRefreshToken': 'synthetic-refresh', 'endpoint': 'https://unreachable.example/school-cloud'}),
        if (savedOnDevice) keyStorage: 'VS-SYNTHETIC-EXAMPLE-1234',
        if (savedOnDevice) 'vidya_saarthi_windows_license_saved_at_v1': '2026-10-16T12:00:00',
        if (savedOnDevice) 'vidya_saarthi_windows_license_status_v1': 'active',
      });
      final state = WindowsPlatformClient.instance.state;
      final previous = state.value;
      addTearDown(() => state.value = previous);
      final licensed = WindowsLicenseState(allowed: true, activated: true,
          status: 'licensed', expiresAt: DateTime(2027, 10, 16));
      state.value = licensed;
      Future<void> openPanel() async {
        await tester.pumpWidget(const MaterialApp(home: Scaffold(
          body: SingleChildScrollView(child: WindowsLicenseSettingsPanel()))));
        await tester.pumpAndSettle();
      }
      await openPanel();
      expect(find.text('License Activated ✓'), findsOneWidget);
      expect(find.text('Saved Key'), findsOneWidget);
      final remove = find.byKey(const ValueKey('windows-licence-remove'));
      expect(remove, findsOneWidget);
      expect(tester.widget<IconButton>(remove).onPressed, isNotNull);
      expect(find.byType(TextField), findsNothing);
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await WindowsLicenseStore.load())['key'],
          savedOnDevice ? 'VS-SYNTHETIC-EXAMPLE-1234' : '');
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect((await WindowsLicenseStore.load())['key'], '');
      expect(find.text('No key saved on this device'), findsOneWidget);
      expect(tester.widget<IconButton>(remove).onPressed, isNotNull);
      expect(identical(state.value, licensed), true,
          reason: 'Device cache removal must not revoke the school licence');
      // Reopening the same-version panel keeps the same features after removal.
      await tester.pumpWidget(const SizedBox());
      await openPanel();
      expect(remove, findsOneWidget);
      expect(find.text('License Activated ✓'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('skip banner displays saved trial end date at narrow width', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WindowsTrialBanner(
            licenseSkipped: true,
            state: WindowsLicenseState(
              allowed: true,
              status: 'trial',
              expiresAt: DateTime(2026, 10, 8),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Trial ends: 08/10/2026'), findsOneWidget);
    expect(find.text('License not activated — Activate now'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('unknown expiry is not presented as an invented end date', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WindowsTrialBanner(
            licenseSkipped: true,
            state: WindowsLicenseState(
              allowed: false,
              status: 'checking',
              expiresAt: DateTime(2026, 10, 3),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Expiry date pending verification'), findsOneWidget);
    expect(find.textContaining('03/10/2026'), findsNothing);
  });
}
