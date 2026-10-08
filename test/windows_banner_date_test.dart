import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_license_gate.dart';
import '../lib/windows_platform_client.dart';

void main() {
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
