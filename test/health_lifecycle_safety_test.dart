import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/health/universal_health.dart';

const school = HealthContext('school-A', 'profile-A');

class DelayedHistory implements HealthHistoryStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  final data = <String, List<HealthEvent>>{};
  @override
  Future<List<HealthEvent>> load(HealthContext context) async =>
      List.of(data[context.fingerprint] ?? []);
  @override
  Future<void> save(HealthContext context, List<HealthEvent> events) async {
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    data[context.fingerprint] = List.of(events);
  }
}

class DelayedSamples implements HealthSampleStore {
  final release = Completer<void>();
  final writes = <List<HealthSample>>[];
  @override
  Future<List<HealthSample>> loadSamples(HealthContext context) async => [];
  @override
  Future<void> saveSamples(
    HealthContext context,
    List<HealthSample> samples,
  ) async {
    writes.add(List.of(samples));
    if (writes.length == 1) await release.future;
  }
}

void main() {
  test(
    'school rebind waits for the old admission before loading repair budgets',
    () async {
      final store = DelayedHistory();
      final engine = UniversalHealth(store: store);
      var executions = 0;
      engine.register(
        HealthProvider(
          id: 'worker',
          version: '2.0',
          check: (_) async => const HealthObservation(HealthState.unknown),
          playbooks: [
            RecoveryPlaybook(
              id: 'restart',
              kind: RecoveryKind.statelessWorker,
              failures: {HealthFailure.worker},
              precondition: (_) async => true,
              execute: (_) async {
                executions++;
              },
              verify: (_) async => true,
            ),
          ],
        ),
      );
      try {
        await engine.bind(school);
        engine.observe(
          'worker',
          const HealthObservation(
            HealthState.degraded,
            failure: HealthFailure.worker,
          ),
        );
        // The observation write holds the storage owner while repair admission
        // is coalesced behind it. Neither may disappear on A -> B -> A.
        await store.entered.future;
        final repair = engine.recover('worker');
        await Future<void>.delayed(Duration.zero);
        final other = engine.bind(const HealthContext('school-B', 'profile-B'));
        final rebound = engine.bind(school);
        expect(engine.admissionHistoryVerified, false);
        store.release.complete();
        await Future.wait([other, rebound]);
        expect(await repair, false);
        expect(executions, 0);
        expect(engine.history.any((e) => e.stage == 'started'), true);
        expect(engine.pendingQuarantineVerification, 1);
        engine.observe(
          'worker',
          const HealthObservation(
            HealthState.degraded,
            failure: HealthFailure.worker,
          ),
        );
        expect(await engine.recover('worker'), false);
        expect(executions, 0);
      } finally {
        if (!store.release.isCompleted) store.release.complete();
        await engine.dispose();
      }
    },
  );

  test(
    'slow trend storage retains one pending snapshot instead of every minute',
    () async {
      var time = DateTime.utc(2026, 10, 13);
      final samples = DelayedSamples();
      final engine = UniversalHealth(now: () => time)..sampleStore = samples;
      engine.register(
        HealthProvider(
          id: 'worker',
          version: '2.0',
          check: (_) async => const HealthObservation(HealthState.unknown),
        ),
      );
      try {
        await engine.bind(school);
        await engine.sampleHistoryLoaded;
        for (var i = 0; i < 120; i++) {
          time = time.add(const Duration(minutes: 1));
          engine.observe(
            'worker',
            HealthObservation(HealthState.healthy, verifiedAt: time),
          );
        }
        expect(samples.writes.length, 1);
        samples.release.complete();
        await engine.flushHistory();
        expect(samples.writes.length, 2);
        expect(samples.writes.last.length, 121);
        expect(samples.writes.last.last.at, time);
        expect(samples.writes.last.last.score, 100);
      } finally {
        if (!samples.release.isCompleted) samples.release.complete();
        await engine.dispose();
      }
    },
  );

  test(
    'pause cancels monitor wakeups and resume restores the running timer',
    () {
      fakeAsync((clock) {
        var checks = 0;
        final engine = UniversalHealth(
          now: () => clock.getClock(DateTime.utc(2026)).now(),
        );
        engine.register(
          HealthProvider(
            id: 'worker',
            version: '2.0',
            check: (_) async {
              checks++;
              return const HealthObservation(HealthState.unknown);
            },
          ),
        );
        engine.bind(school);
        clock.flushMicrotasks();
        engine.start();
        clock.elapse(Duration.zero);
        expect(clock.periodicTimerCount, 2);
        engine.pause();
        expect(clock.periodicTimerCount, 0);
        clock.elapse(const Duration(hours: 2));
        expect(checks, 0);
        engine.resume();
        clock.flushMicrotasks();
        clock.elapse(Duration.zero);
        expect(engine.monitoringActive, true);
        expect(clock.periodicTimerCount, 2);
        final resumedChecks = checks;
        clock.elapse(const Duration(seconds: 31));
        expect(checks, greaterThan(resumedChecks));
        engine.stop();
        clock.flushMicrotasks();
        expect(clock.periodicTimerCount, 0);
        engine.resume();
        clock.flushMicrotasks();
        expect(clock.periodicTimerCount, 0);
        engine.dispose();
        clock.flushMicrotasks();
      });
    },
  );
}
