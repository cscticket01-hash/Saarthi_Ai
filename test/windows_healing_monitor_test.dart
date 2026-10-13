import '../lib/health/health_history_io.dart';
import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/health/universal_health.dart';
import '../lib/health/windows_healing_monitor.dart';

void main() {
  testWidgets('Run diagnostics shows progress then all component results', (tester) async {
    final engine = UniversalHealth(), release = Completer<void>();
    final checked = <String>[];
    for (var i = 0; i < 11; i++) {
      engine.register(HealthProvider(id: 'component-$i', version: '2.0', check: (_) async {
        if (i == 0) await release.future;
        checked.add('component-$i');
        return const HealthObservation(HealthState.unknown);
      }));
    }
    await engine.bind(const HealthContext('school-a', 'profile-a'));
    await tester.pumpWidget(MaterialApp(home: WindowsHealingMonitor(engine: engine)));
    await tester.tap(find.text('Run diagnostics'));
    await tester.pump();
    expect(find.text('Running diagnostics…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    release.complete();
    await tester.pumpAndSettle();
    expect(checked.length, 11);
    expect(find.text('Diagnostics results'), findsOneWidget);
    expect(find.text('Checked 11 components. Skipped 0 busy components.'), findsOneWidget);
    expect(find.text('component-10: unknown · none'), findsOneWidget);
    expect(find.text('Run diagnostics'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await engine.dispose();
  });

  testWidgets('unbound diagnostics explains why no check can run', (tester) async {
    final engine = UniversalHealth();
    await tester.pumpWidget(MaterialApp(home: WindowsHealingMonitor(engine: engine)));
    await tester.tap(find.text('Run diagnostics'));
    await tester.pumpAndSettle();
    expect(find.text('Diagnostics results'), findsOneWidget);
    expect(find.textContaining('no school is bound'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await engine.dispose();
  });
  test('monitoring label follows an actual running bound supervisor', () async {
    final engine = UniversalHealth();
    expect(monitoringHeadline(engine),contains('inactive'));
    engine.register(HealthProvider(id:'database',version:'2.0',check:(_)async=>const HealthObservation(HealthState.unknown)));
    await engine.bind(const HealthContext('school-a','profile-a'));
    expect(engine.monitoringActive,isFalse);
    engine.start();
    expect(engine.monitoringActive,isTrue);
    expect(monitoringHeadline(engine),'Monitoring active · auto-repair off');
    engine.pause();
    expect(engine.monitoringActive,isFalse);
    expect(monitoringHeadline(engine),'Monitoring Paused');
    await engine.dispose();
  });

  test('background trend survives restart, pauses and school changes without a page', () async {
    final directory = await Directory.systemTemp.createTemp('health-trend-fixture');
    var at = DateTime.utc(2026, 10, 12);
    final store = FileHealthSamples(() async => directory);
    final engine = UniversalHealth(now:()=>at)..sampleStore=store;
    engine.register(HealthProvider(id:'database',version:'2.0',check:(_)async=>const HealthObservation(HealthState.unknown)));
    await engine.bind(const HealthContext('a','a'));
    await engine.sampleHistoryLoaded;
    at = at.add(const Duration(minutes:1));
    engine.observe('database', HealthObservation(HealthState.healthy,verifiedAt:at));
    await engine.flushHistory();
    expect(engine.samples.last.score,100);
    engine.pause();
    expect(engine.samples.last.score,100);
    final saved = await store.loadSamples(const HealthContext('a','a'));
    expect(saved.last.score,100);
    await engine.bind(const HealthContext('b','b'));
    await engine.sampleHistoryLoaded;
    expect(engine.samples.every((p)=>p.score==null),isTrue);
    await engine.flushHistory();
    expect((await store.loadSamples(const HealthContext('b','b'))).every((p)=>p.score==null),isTrue);
    await engine.dispose();
    await directory.delete(recursive:true);
  });

  setUpAll(() async {
    final root = Platform.environment['FLUTTER_ROOT'];
    if (root != null) {
      final font = FontLoader('Roboto');
      font.addFont(
        Future.value(
          (await File(
            '$root/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
          ).readAsBytes()).buffer.asByteData(),
        ),
      );
      await font.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(
        Future.value(
          (await File(
            '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes()).buffer.asByteData(),
        ),
      );
      await icons.load();
    }
  });
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
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await (() async {
            await Directory('build/healing-monitor').create(recursive: true);
            await File(
              'build/healing-monitor/unknown-${size.width.toInt()}x${size.height.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
          })();
          image.dispose();
        });
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
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await (() async {
              await Directory('build/healing-monitor').create(recursive: true);
              await File(
                'build/healing-monitor/${incident ? 'warning' : 'healthy'}-1920x1080-TEST-FIXTURE.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
            })();
            image.dispose();
          });
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
