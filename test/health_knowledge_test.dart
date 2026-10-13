import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import '../lib/health/universal_health.dart';
import '../lib/health/health_knowledge.dart';
import '../lib/health/knowledge/catalog_data.dart';

class KnowledgeHistory implements HealthHistoryStore {
  final scopes = <String, List<HealthEvent>>{};
  @override
  Future<List<HealthEvent>> load(HealthContext scope) async =>
      List.of(scopes[scope.fingerprint] ?? []);
  @override
  Future<void> save(HealthContext scope, List<HealthEvent> events) async {
    scopes[scope.fingerprint] = List.of(events);
  }
}

void main() {
  final knowledge = HealthKnowledge.instance;
  final raw = jsonDecode(healthKnowledgeJson) as Map<String, dynamic>;
  for (final rule in knowledge.rules) {
    test('exact typed signal reaches ${rule.id}; healthy/paused cannot match', () {
      final signature = rule.data['signature'] as Map<String, dynamic>;
      final failure = HealthFailure.values.byName(signature['failure'] as String);
      final category = signature['ownerCategory'] as String;
      expect(knowledge.match(rule.component, HealthObservation(
          HealthState.degraded, failure: failure, ownerCategory: category))?.id, rule.id);
      for (final state in [HealthState.healthy, HealthState.paused]) {
        expect(knowledge.match(rule.component, HealthObservation(
            state, failure: failure, ownerCategory: category)), isNull);
      }
      expect(knowledge.match('unregistered-component', HealthObservation(
          HealthState.degraded, failure: failure, ownerCategory: category)), isNull);
    });
  }
  test('coverage is actual; search and returned rules are bounded', () {
    expect(knowledge.rules.length, (raw['rules'] as List).length);
    expect(knowledge.rules.length, lessThan(1000));
    expect(knowledge.search('quota').single.id, 'sh-smart-sync-quota');
    expect(knowledge.search('x' * 121), isEmpty);
    expect(knowledge.rules.map((r) => r.id).toSet().length, knowledge.rules.length);
    expect(() => knowledge.rules.clear(), throwsUnsupportedError);
  });
  test('45-second measured latency ranks hypotheses, never confirms upstream cause', () {
    const observation = HealthObservation(HealthState.degraded,
        failure: HealthFailure.timeout, metrics: {'latencyMs': 45000});
    final ranked = rankHealthCauses('smart-sync', observation, const {
      'database': HealthObservation(HealthState.needsAttention, failure: HealthFailure.storage),
    });
    expect(ranked.first.score, 2);
    expect(ranked.length, 3);
    expect(ranked.map((c) => c.basis).join(' '), contains('unconfirmed'));
    expect(ranked.map((c) => c.basis).join(' '), contains('correlation only'));
  });
  test('unrecognized category cannot claim a known Sync repair', () {
    expect(knowledge.match('smart-sync', const HealthObservation(
        HealthState.needsAttention, failure: HealthFailure.timeout,
        ownerCategory: 'secret student raw error')), isNull);
  });
  test('learning requires an attributed admission and at most one terminal', () {
    final now = DateTime.utc(2026, 10, 13);
    HealthEvent event(String stage, int seconds, {String playbook = 'safe'}) =>
        HealthEvent('worker', HealthFailure.worker, stage,
            now.add(Duration(seconds: seconds)), 'a' * 64, playbook: playbook);
    final history = [event('verified', -20), event('started', -15),
      event('verified', -14), event('verified', -13),
      event('started', -10), event('unverified', -9),
      event('started', -5, playbook: 'other'), event('verified', -4, playbook: 'other'),
      event('started', 1), event('verified', 2)];
    final learning = HealthRepairLearning.forPlaybook(history, 'worker', 'safe', now);
    expect([learning.started, learning.verified, learning.failed], [2, 1, 1]);
    expect(learning.preference, -1);
  });
  test('new playbook audit metadata round trips; legacy events remain readable', () {
    final event = HealthEvent('worker', HealthFailure.worker, 'started',
        DateTime.utc(2026, 10, 13), 'a' * 64, playbook: 'safe-timer');
    expect(HealthEvent.parse(event.toJson())?.playbook, 'safe-timer');
    final legacy = Map<String, dynamic>.of(event.toJson())..remove('playbook');
    expect(HealthEvent.parse(legacy)?.playbook, '');
    expect(HealthEvent.parse({...event.toJson(), 'playbook': 'execute shell command'}), isNull);
  });
  test('old provider versions and other failure classes cannot influence learning', () {
    final now = DateTime.utc(2026, 10, 13);
    final history = [for (final stage in ['started', 'verified'])
      HealthEvent('worker', HealthFailure.timeout, stage, now, 'a' * 64,
          playbook: 'safe', providerVersion: '2.0')];
    expect(HealthRepairLearning.forPlaybook(history, 'worker', 'safe', now,
        providerVersion: '2.1').verified, 0);
    expect(HealthRepairLearning.forPlaybook(history, 'worker', 'safe', now,
        failure: HealthFailure.worker).verified, 0);
  });
  test('blank school or installation identity never admits automatic or manual repair', () async {
    final engine = UniversalHealth(store: KnowledgeHistory());
    var executions = 0;
    engine.register(HealthProvider(id: 'worker', version: '2.1',
      check: (_) async => const HealthObservation(HealthState.unknown),
      playbooks: [RecoveryPlaybook(id: 'safe', kind: RecoveryKind.statelessWorker,
        failures: {HealthFailure.worker}, precondition: (_) async => true,
        execute: (_) async { executions++; }, verify: (_) async => true)]));
    try {
      for (final scope in [const HealthContext('', 'installation'),
          const HealthContext('school', ''), const HealthContext(' ', 'installation')]) {
        await engine.bind(scope);
        engine.observe('worker', const HealthObservation(HealthState.degraded, failure: HealthFailure.worker));
        expect(await engine.recover('worker'), false);
        expect(await engine.recover('worker', automatic: false), false);
        expect(engine.history.any((event) => event.stage == 'started'), false);
      }
      expect(executions, 0);
    } finally { await engine.dispose(); }
  });
  test('school-scoped verified history ranks only registered alternatives', () async {
    final store = KnowledgeHistory();
    final now = DateTime.utc(2026, 10, 13);
    const schoolA = HealthContext('A', 'installation-A');
    final executed = <String>[];
    store.scopes[schoolA.fingerprint] = [
      HealthEvent('worker', HealthFailure.worker, 'started', now.subtract(const Duration(minutes: 30)), 'a' * 64, playbook: 'second', providerVersion: '2.1'),
      HealthEvent('worker', HealthFailure.worker, 'verified', now.subtract(const Duration(minutes: 29)), 'b' * 64, playbook: 'second', providerVersion: '2.1'),
    ];
    final engine = UniversalHealth(store: store, now: () => now);
    RecoveryPlaybook play(String id) => RecoveryPlaybook(id: id,
      kind: RecoveryKind.statelessWorker, failures: {HealthFailure.worker},
      precondition: (lease) async => lease.valid,
      execute: (lease) async { lease.check(); executed.add(id); },
      verify: (lease) async => lease.valid);
    engine.register(HealthProvider(id: 'worker', version: '2.1',
      check: (_) async => const HealthObservation(HealthState.unknown),
      playbooks: [play('first'), play('second')]));
    try {
      await engine.bind(schoolA);
      engine.observe('worker', const HealthObservation(HealthState.degraded, failure: HealthFailure.worker));
      expect(await engine.recover('worker'), true);
      expect(executed, ['second']);
      expect(engine.history.last.playbook, 'second');
      engine.observe('worker', const HealthObservation(HealthState.degraded, failure: HealthFailure.worker));
      expect(await engine.recover('worker'), false); // learning cannot defeat circuit
      await engine.bind(const HealthContext('B', 'installation-B'));
      engine.observe('worker', const HealthObservation(HealthState.degraded, failure: HealthFailure.worker));
      expect(await engine.recover('worker'), true);
      expect(executed, ['second', 'first']);
    } finally { await engine.dispose(); }
  });
}
