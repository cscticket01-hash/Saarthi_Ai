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
  for (final incident in [false, true]) {
    testWidgets(
      incident
          ? 'incident preview and live binding'
          : 'healthy preview and filters',
      (tester) async {
        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var now = DateTime(2026, 10, 12, 10);
        final engine = UniversalHealth(now: () => now);
        engine.register(
          HealthProvider(
            id: 'database',
            version: '2.0',
            check: (_) async => const HealthObservation(HealthState.unknown),
          ),
        );
        await engine.bind(
          const HealthContext('preview-school', 'preview-profile'),
        );
        engine.observe(
          'database',
          HealthObservation(HealthState.healthy, verifiedAt: now),
        );
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(home: WindowsHealingMonitor(engine: engine)),
          ),
        );
        now = now.add(const Duration(minutes: 1));
        engine.observe(
          'database',
          incident
              ? const HealthObservation(
                  HealthState.degraded,
                  failure: HealthFailure.offline,
                )
              : HealthObservation(HealthState.healthy, verifiedAt: now),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(incident ? 'Attention Required' : 'System Healthy'),
          findsOneWidget,
        );
        expect(find.text(incident ? '50%' : '100%'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (Platform.environment['HEALTH_PREVIEWS'] == '1') {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await tester.runAsync(() async {
            await Directory('build/healing-monitor').create(recursive: true);
            await File(
              'build/healing-monitor/${incident ? 'warning' : 'healthy'}-1920x1080-TEST-FIXTURE.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
          });
          image.dispose();
        }
        await tester.tap(find.byType(DropdownButton<Duration>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Last 1 hour').last);
        await tester.pumpAndSettle();
        expect(find.text('Last 1 hour'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await engine.dispose();
      },
    );
  }
}
