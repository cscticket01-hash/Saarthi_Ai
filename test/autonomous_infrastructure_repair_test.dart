import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/health/windows_health_adapter.dart';

import '../lib/health/universal_health.dart';
import '../lib/health/owner_timer_provider.dart';
import '../lib/health/health_reporter.dart';
import '../lib/health/health_runtime.dart';
import '../lib/windows_sync_schedule.dart';
import '../lib/windows_sync_engine.dart';

class RepairHistory implements HealthHistoryStore {
  final records = <String, List<HealthEvent>>{};
  @override
  Future<List<HealthEvent>> load(HealthContext c) async =>
      List.of(records[c.fingerprint] ?? []);
  @override
  Future<void> save(HealthContext c, List<HealthEvent> e) async {
    records[c.fingerprint] = List.of(e);
  }
}

class ControlledTimer implements Timer {
  ControlledTimer(this.callback);
  final void Function() callback;
  bool live = true;
  @override
  void cancel() {
    live = false;
  }

  @override
  bool get isActive => live;
  @override
  int get tick => 0;
  void fire() {
    if (live) {
      live = false;
      callback();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('dispatch restoration respects withdrawn admission and current retry floors', () {
    final due = DateTime.utc(2026, 10, 13);
    expect(
      canRestoreOwnerDispatch(retryAllowed: true, admittedAt: due),
      isTrue,
    );
    expect(
      canRestoreOwnerDispatch(retryAllowed: false, admittedAt: due),
      isFalse,
    );
    expect(
      canRestoreOwnerDispatch(retryAllowed: true, admittedAt: null),
      isFalse,
    );
    expect(
      canRestoreOwnerDispatch(
        retryAllowed: true,
        admittedAt: due,
        nextRetry: due.add(const Duration(seconds: 1)),
      ),
      isFalse,
    );
    expect(
      canRestoreOwnerDispatch(
        retryAllowed: true,
        admittedAt: due,
        quotaRetry: due.add(const Duration(seconds: 1)),
      ),
      isFalse,
    );
    expect(
      canRestoreOwnerDispatch(
        retryAllowed: true,
        admittedAt: due,
        nextRetry: due,
        quotaRetry: due.subtract(const Duration(seconds: 1)),
      ),
      isTrue,
    );
  });
  const scope = HealthContext('school-A', 'profile-A');
  test('refresh-sync-view: real owner projection repair preserves queue and denies stale scope', () async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    final db = FirebaseFirestore.instance;
    const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    await db.switchProfile(
      'healing-view-fixture',
      identity: {'schoolSyncId': school},
    );
    await db.collection('teachers_directory').doc('fixture').set({
      'name': 'TEST',
    });
    final adapter = WindowsHealthAdapter.instance;
    final owner = WindowsSyncEngine.instance;
    final engine = UniversalHealth(store: RepairHistory());
    engine.register(adapter.syncViewProvider());
    await engine.bind(adapter.current());
    final before = jsonEncode(
      (await db.collection('_windows_firebase_outbox').get()).docs
          .map((row) => {'id': row.id, 'value': row.data()})
          .toList(),
    );
    try {
      // Owner stays uninitialized: no cloud connection or report is admitted.
      owner.details.value = {};
      await engine.check('sync-view');
      expect(await engine.recover('sync-view'), true);
      expect(owner.details.value['pending'], 1);
      expect(owner.details.value['verifiedReceiptCount'], 0);
      expect(engine.history.last.stage, 'verified');
      final after = jsonEncode(
        (await db.collection('_windows_firebase_outbox').get()).docs
            .map((row) => {'id': row.id, 'value': row.data()})
            .toList(),
      );
      expect(after, before);
      expect(await engine.recover('sync-view'), false);
      await engine.bind(const HealthContext('school-other', 'profile-other'));
      owner.details.value = {};
      engine.observe(
        'sync-view',
        const HealthObservation(
          HealthState.degraded,
          failure: HealthFailure.worker,
        ),
      );
      expect(await engine.recover('sync-view'), false);
      expect(owner.details.value, isEmpty);
      engine.pause();
      expect(await engine.recover('sync-view'), false);
    } finally {
      await engine.dispose();
    }
  });
  test(
    'restart-monitor-timer: real heartbeat owner recovery and pause denial',
    () async {
      final now = DateTime.utc(2026, 10, 13);
      final engine = UniversalHealth(store: RepairHistory(), now: () => now);
      engine.register(HealthRuntime.monitorProvider(engine));
      await engine.bind(scope);
      try {
        await engine.check('monitor-worker');
        expect(engine.lastHeartbeat, isNull);
        expect(await engine.recover('monitor-worker'), true);
        expect(engine.lastHeartbeat, now);
        expect(engine.monitoringActive, true);
        expect(engine.history.last.stage, 'verified');
        engine.pause();
        engine.lastHeartbeat = now.subtract(const Duration(minutes: 3));
        expect(await engine.recover('monitor-worker'), false);
        expect(engine.monitoringActive, false);
      } finally {
        await engine.dispose();
      }
    },
  );
  for (final entry in {
    'sync-retry-dispatch': 'restore-admitted-dispatch',
    'sync-checkpoint-timer': 'restore-checkpoint-deadline',
    'health-delivery-scheduler': 'restore-health-delivery',
    'mobile-context-timer': 'restore-context-observer',
  }.entries) {
    test(
      '${entry.value}: admission, repeat, school, pause, verification and restart budget',
      () async {
        final history = RepairHistory(),
            protected = {
              'students': [1, 2],
              'fees': 99,
              'queue': [
                {'id': 'stable', 'revision': 7},
              ],
            };
        final before = jsonEncode(protected);
        var running = false, enabled = true, calls = 0;
        final now = DateTime.utc(2026, 10, 13);
        HealthProvider provider() => ownerTimerProvider(
          id: entry.key,
          playbook: entry.value,
          sameScope: (c) => c.same(scope),
          expected: () => enabled,
          running: () => running,
          restart: (_) {
            calls++;
            running = true;
          },
          now: () => now,
        );
        final engine = UniversalHealth(store: history, now: () => now)
          ..register(provider());
        try {
          await engine.bind(scope);
          await engine.check(entry.key);
          expect(await engine.recover(entry.key), true);
          expect(calls, 1);
          expect(await engine.recover(entry.key), false);
          expect(calls, 1);
          expect(engine.history.last.stage, 'verified');
          expect(engine.history.last.elapsedMillis, isNotNull);
          await engine.flushHistory();
          final restarted = UniversalHealth(store: history, now: () => now)
            ..register(provider());
          try {
            running = false;
            await restarted.bind(scope);
            await restarted.check(entry.key);
            expect(await restarted.recover(entry.key), false);
            expect(calls, 1);
            await restarted.bind(const HealthContext('school-B', 'profile-B'));
            await restarted.check(entry.key);
            expect(await restarted.recover(entry.key), false);
            expect(calls, 1);
          } finally {
            await restarted.dispose();
          }
          await engine.bind(const HealthContext('school-A', 'profile-other'));
          engine.observe(
            entry.key,
            const HealthObservation(
              HealthState.degraded,
              failure: HealthFailure.worker,
            ),
          );
          expect(await engine.recover(entry.key), false);
          expect(calls, 1);
          await engine.bind(scope);
          enabled = false;
          await engine.check(entry.key);
          expect(await engine.recover(entry.key), false);
          expect(engine.observations[entry.key]!.state, HealthState.paused);
          engine.pause();
          expect(await engine.recover(entry.key), false);
          expect(jsonEncode(protected), before);
        } finally {
          await engine.dispose();
        }
      },
    );
    test(
      '${entry.value}: failed owner restoration cannot become Healthy',
      () async {
        final engine = UniversalHealth(store: RepairHistory());
        engine.register(
          ownerTimerProvider(
            id: entry.key,
            playbook: entry.value,
            sameScope: (c) => c.same(scope),
            expected: () => true,
            running: () => false,
            restart: (_) {},
            now: engine.now,
          ),
        );
        try {
          await engine.bind(scope);
          await engine.check(entry.key);
          expect(await engine.recover(entry.key), false);
          expect(
            engine.observations[entry.key]!.state,
            HealthState.needsAttention,
          );
          expect(engine.history.last.stage, 'unverified');
        } finally {
          await engine.dispose();
        }
      },
    );
  }
  test('captured dispatch deadline survives cancellation; no immediate or duplicate sync', () {
    var time = DateTime.utc(2026, 10, 13), calls = 0;
    final timers = <ControlledTimer>[], delays = <Duration>[];
    final dispatch = WindowsSyncDispatch(
      () => calls++,
      now: () => time,
      once: (delay, cb) {
        delays.add(delay);
        final t = ControlledTimer(cb);
        timers.add(t);
        return t;
      },
    );
    dispatch.request(const Duration(minutes: 15));
    final due = dispatch.scheduledAt;
    timers.single.cancel();
    time = time.add(const Duration(minutes: 4));
    dispatch.repair();
    dispatch.repair();
    expect(calls, 0);
    expect(timers.length, 2);
    expect(dispatch.scheduledAt, due);
    expect(delays.last, const Duration(minutes: 11));
    timers.last.fire();
    expect(calls, 1);
    dispatch.repair();
    expect(timers.length, 2);
    dispatch.cancel();
    expect(dispatch.expected, false);
  });
  test(
    'checkpoint restoration preserves the verified anchor and other timers',
    () {
      final now = DateTime.utc(2026, 10, 13),
          timers = <ControlledTimer>[],
          delays = <Duration>[];
      var requests = 0;
      final schedule = WindowsSyncSchedule(
        (_) {
          requests++;
        },
        now: () => now,
        once: (d, cb) {
          delays.add(d);
          final t = ControlledTimer(cb);
          timers.add(t);
          return t;
        },
      );
      schedule.start(const Duration(minutes: 4));
      final reconciliation = schedule.reconciliation, hourly = schedule.hourly;
      schedule.armCheckpoint(now.subtract(const Duration(minutes: 20)));
      timers.single.cancel();
      schedule.repairCheckpoint();
      schedule.repairCheckpoint();
      expect(delays.last, const Duration(minutes: 40));
      expect(timers.length, 2);
      expect(requests, 0);
      expect(identical(reconciliation, schedule.reconciliation), true);
      expect(identical(hourly, schedule.hourly), true);
      schedule.stop();
      expect(schedule.checkpointExpected, false);
    },
  );
  test('elapsed captured checkpoint restores once through owner dispatch', () {
    var now = DateTime.utc(2026, 10, 13), requests = 0;
    final timers = <ControlledTimer>[], delays = <Duration>[];
    final schedule = WindowsSyncSchedule(
      (_) => requests++,
      now: () => now,
      once: (delay, callback) {
        delays.add(delay);
        final timer = ControlledTimer(callback);
        timers.add(timer);
        return timer;
      },
    );
    schedule.start(const Duration(minutes: 4));
    final reconciliation = schedule.reconciliation;
    schedule.armCheckpoint(now.subtract(const Duration(minutes: 59)));
    timers.single.cancel();
    now = now.add(const Duration(minutes: 2));
    expect(schedule.checkpointExpected, true);
    schedule.repairCheckpoint();
    schedule.repairCheckpoint();
    expect(delays.last, Duration.zero);
    expect(timers.length, 2);
    expect(requests, 0);
    expect(identical(schedule.reconciliation, reconciliation), true);
    timers.last.fire();
    expect(requests, 1);
    expect(schedule.checkpointExpected, false);
    schedule.repairCheckpoint();
    expect(timers.length, 2);
    schedule.stop();
    expect(schedule.checkpointExpected, false);
  });
  test(
    'Sync owner rejects repair before school activation without admitting work',
    () {
      final owner = WindowsSyncEngine.instance;
      expect(
        () => owner.repairRetryDispatch(school: 'foreign', profile: 'foreign'),
        throwsStateError,
      );
      expect(
        () =>
            owner.repairCheckpointTimer(school: 'foreign', profile: 'foreign'),
        throwsStateError,
      );
    },
  );
  test('diagnostic transient retry retains persisted budget and permission latch across restart', () async {
    SharedPreferences.setMockInitialValues({});
    var now = DateTime.utc(2026, 10, 13), calls = 0;
    final timers = <ControlledTimer>[], delays = <Duration>[];
    final engine = UniversalHealth(store: RepairHistory(), now: () => now);
    await engine.bind(scope);
    HealthReporter reporter(HealthSendResult result) => HealthReporter(
      engine,
      platform: 'windows',
      version: '2.1',
      now: () => now,
      once: (d, cb) {
        delays.add(d);
        final t = ControlledTimer(cb);
        timers.add(t);
        return t;
      },
      send: (_, __) async {
        calls++;
        return result;
      },
    );
    final first = reporter(HealthSendResult.retryable);
    await first.start();
    try {
      await first.report();
      expect(calls, 1);
      expect(first.retryRunning, true);
      timers.single.cancel();
      first.repairRetry();
      first.repairRetry();
      expect(timers.length, 2);
      expect(delays.last, const Duration(minutes: 10));
      expect(calls, 1);
      first.pause();
      final restored = reporter(HealthSendResult.accepted);
      await restored.start();
      try {
        await restored.report();
        expect(calls, 1);
        expect(restored.retryRunning, true);
        now = now.add(const Duration(minutes: 10));
        await restored.report();
        expect(calls, 2);
        expect(restored.retryExpected, false);
        expect(restored.deliveryObservation.state, HealthState.healthy);
      } finally {
        restored.pause();
      }
      now = now.add(const Duration(minutes: 5));
      final denied = reporter(HealthSendResult.attention);
      await denied.start();
      try {
        await denied.report();
        expect(calls, 3);
        expect(denied.deliveryObservation.failure, HealthFailure.authorization);
      } finally {
        denied.pause();
      }
      final blocked = reporter(HealthSendResult.accepted);
      await blocked.start();
      try {
        await blocked.report();
        expect(calls, 3);
        blocked.repairRetry();
        expect(blocked.retryExpected, false);
      } finally {
        blocked.pause();
      }
    } finally {
      first.pause();
      await engine.dispose();
    }
  });
  test('unsettled diagnostic transport blocks every duplicate and never reports accepted', () async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    final engine = UniversalHealth(store: RepairHistory());
    await engine.bind(scope);
    final pending = Completer<HealthSendResult>();
    final reporter = HealthReporter(
      engine,
      platform: 'windows',
      version: '2.1',
      send: (_, __) {
        calls++;
        return pending.future;
      },
    );
    await reporter.start();
    final first = reporter.report();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await reporter.report();
    reporter.repairRetry();
    expect(calls, 1);
    expect(reporter.retryExpected, false);
    pending.complete(HealthSendResult.accepted);
    await first;
    reporter.pause();
    await engine.dispose();
  });
  test(
    'malformed persisted diagnostic budget fails closed without an auth reset',
    () async {
      SharedPreferences.setMockInitialValues({
        'universal_health_delivery_budget_v2_${scope.fingerprint}': '{bad',
      });
      final engine = UniversalHealth(store: RepairHistory());
      await engine.bind(scope);
      var calls = 0;
      final reporter = HealthReporter(
        engine,
        platform: 'windows',
        version: '2.1',
        send: (_, __) async {
          calls++;
          return HealthSendResult.accepted;
        },
      );
      await reporter.start();
      await reporter.report();
      expect(calls, 0);
      expect(reporter.deliveryObservation.state, HealthState.needsAttention);
      reporter.pause();
      await engine.dispose();
    },
  );
  test('verified duration and recurrence suppress preference without creating authority', () {
    final now = DateTime.utc(2026, 10, 13);
    HealthEvent event(
      String stage,
      int second, {
      String version = '2.1',
      int? ms,
    }) => HealthEvent(
      'worker',
      HealthFailure.worker,
      stage,
      now.add(Duration(seconds: second)),
      'a' * 64,
      playbook: stage == 'observed' ? '' : 'safe',
      providerVersion: version,
      elapsedMillis: ms,
    );
    final history = [
      event('started', -120),
      event('verified', -119, ms: 25),
      event('observed', -100),
      event('observed', -99),
      event('verified', -90, ms: 999),
    ];
    final learned = HealthRepairLearning.forPlaybook(
      history,
      'worker',
      'safe',
      now,
      providerVersion: '2.1',
    );
    expect(learned.verified, 1);
    expect(learned.recurrences, 1);
    expect(learned.meanVerifiedMillis, 25);
    expect(learned.preference, -1);
    expect(
      HealthEvent.parse({...history[1].toJson(), 'elapsedMillis': -1}),
      isNull,
    );
    expect(
      HealthEvent.parse({
        ...history[1].toJson(),
        'diagnosticCode': 'private name',
      }),
      isNull,
    );
  });
}
