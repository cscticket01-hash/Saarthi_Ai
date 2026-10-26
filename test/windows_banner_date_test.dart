import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import '../lib/main_dashboard_screen_windows.dart' show WindowsLicenseSettingsPanel;
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/platform/platform_config.dart';

import '../lib/windows_license_gate.dart';
import '../lib/windows_platform_client.dart';

void main() {
  for (final savedOnDevice in [false, true]) {
    testWidgets('verified licence locks and renewal re-locks with local key $savedOnDevice', (tester) async {
      const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      FlutterSecureStorage.setMockInitialValues({
        CentralSchoolCloud.key: jsonEncode({'managed': true, 'schoolId': school,
          'projectId': platformProjectId, 'folderId': 'managed', 'uid': 'synthetic-school',
          'firebaseRefreshToken': 'synthetic-refresh', 'endpoint': 'https://unreachable.example/school-cloud'}),
        if (savedOnDevice) 'vidya_saarthi_windows_license_key_v1': 'VS-SYNTHETIC-EXAMPLE-1234',
      });
      final client = WindowsPlatformClient.instance, state = WindowsPlatformClient.instance.state;
      final previous = state.value;
      addTearDown(() => state.value = previous);
      state.value = WindowsLicenseState(allowed: false, activated: false,
          status: 'licensed', expiresAt: DateTime.now().add(const Duration(days: 30)));
      Future<void> openPanel() async {
        await tester.pumpWidget(const MaterialApp(home: Scaffold(
          body: SingleChildScrollView(child: WindowsLicenseSettingsPanel()))));
        await tester.pumpAndSettle();
      }
      Map<String, dynamic> verified({String schoolId = school}) => {
        'success': true, 'managed': true, 'schoolId': schoolId, 'uid': 'synthetic-school',
        'projectId': platformProjectId, 'allowed': true, 'activated': true, 'status': 'licensed',
        'expiresAt': DateTime.now().add(const Duration(days: 365)).millisecondsSinceEpoch,
        'serverTime': DateTime.now().millisecondsSinceEpoch,
      };
      void expectLocked() {
        expect(find.byKey(const ValueKey('windows-licence-locked')), findsOneWidget);
        expect(find.byKey(const ValueKey('windows-licence-remove')), findsNothing);
        expect(find.byType(TextField), findsNothing);
        expect(find.text('Save Licensing Key'), findsNothing);
        expect(find.text('Licence locked until renewal.'), findsOneWidget);
        expect(find.text('Licence verified and locked'), findsOneWidget);
      }
      await openPanel();
      expect(find.byType(TextField), findsOneWidget);
      await client.applyManagedActivation(verified());
      await tester.pumpAndSettle();
      expectLocked();
      await tester.pumpWidget(const SizedBox());
      await openPanel();
      expectLocked();
      // A foreign or unverified reply cannot unlock/replace the valid licence.
      final locked = state.value;
      await expectLater(client.applyManagedActivation(verified(schoolId: 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')), throwsStateError);
      await expectLater(client.applyManagedActivation({...verified(), 'activated': false}), throwsStateError);
      expect(identical(state.value, locked), true);
      state.value = WindowsLicenseState(allowed: false, activated: true,
          status: 'expired', expiresAt: DateTime.now().subtract(const Duration(seconds: 1)));
      await tester.pumpAndSettle();
      expect(find.text('Licence expired. Enter the new renewal key issued by the developer.'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byKey(const ValueKey('windows-licence-locked')), findsNothing);
      // Developer issues a fresh entitlement; it stays editable until verified.
      state.value = WindowsLicenseState(allowed: true, activated: false,
          status: 'licensed', expiresAt: DateTime.now().add(const Duration(days: 365)));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await client.applyManagedActivation(verified());
      await tester.pumpAndSettle();
      expectLocked();
      await tester.pumpWidget(const SizedBox());
      await openPanel();
      expectLocked();
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
