import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/health/universal_health.dart';
import '../lib/health/windows_healing_monitor.dart';

void main() {
  test('score requires conclusive current-school evidence', () async {
    final engine = UniversalHealth();
    engine.register(
      HealthProvider(
        id: 'database',
        version: '2.0',
        check: (_) async => const HealthObservation(HealthState.unknown),
      ),
    );
    await engine.bind(const HealthContext('school-a', 'profile-a'));
    expect(healthScore(engine), isNull);
    engine.observe(
      'database',
      HealthObservation(HealthState.healthy, verifiedAt: engine.now()),
    );
    expect(healthScore(engine), 100);
    engine.observe(
      'database',
      const HealthObservation(
        HealthState.degraded,
        failure: HealthFailure.offline,
      ),
    );
    expect(healthScore(engine), 50);
    engine.observe(
      'database',
      const HealthObservation(
        HealthState.needsAttention,
        failure: HealthFailure.storage,
      ),
    );
    expect(healthScore(engine), 0);
    await engine.bind(const HealthContext('school-b', 'profile-b'));
    expect(healthScore(engine), isNull);
    await engine.dispose();
  });
  for (final size in [
    const Size(1366, 768),
    const Size(1600, 900),
    const Size(1920, 1080),
  ]) {
    testWidgets('responsive monitor $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = UniversalHealth();
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(home: WindowsHealingMonitor(engine: engine)),
        ),
      );
      await tester.pumpAndSettle();
      if (Platform.environment['HEALTH_PREVIEWS'] == '1') {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await tester.runAsync(() async {
          await Directory('build/healing-monitor').create(recursive: true);
          await File(
            'build/healing-monitor/unknown-${size.width.toInt()}x${size.height.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
        });
        image.dispose();
      }
      expect(find.text('Self-Healing Monitor'), findsOneWidget);
      expect(find.text('Status Unknown'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('View All'));
      await tester.pumpAndSettle();
      expect(find.text('No recorded events'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await engine.dispose();
    });
  }
}
