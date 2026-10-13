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
      final code = signature['diagnosticCode'] as String? ?? '';
      expect(knowledge.match(rule.component, HealthObservation(
          HealthState.degraded, failure: failure, ownerCategory: category, diagnosticCode: code))?.id, rule.id);
      for (final state in [HealthState.healthy, HealthState.paused]) {
        expect(knowledge.match(rule.component, HealthObservation(
            state, failure: failure, ownerCategory: category, diagnosticCode: code)), isNull);
      }
      expect(knowledge.match('unregistered-component', HealthObservation(
          HealthState.degraded, failure: failure, ownerCategory: category, diagnosticCode: code)), isNull);
      if (code.isNotEmpty) {
        final source = rule.data['sourceCase'] as Map<String, dynamic>;
        expect(knowledge.matchSourceCase(rule.component, source['kind'] as String,
            source['literal'] as String, source: source['path'] as String)?.id, rule.id);
        expect(knowledge.matchSourceCase(rule.component, source['kind'] as String,
            '${source['literal']} private student', source: source['path'] as String), isNull);
        expect(knowledge.matchSourceCase(rule.component, source['kind'] as String,
            source['literal'] as String, source: 'lib/unrelated_owner.dart'), isNull);
        expect(knowledge.match(rule.component, HealthObservation(HealthState.degraded,
            failure: HealthFailure.worker, diagnosticCode: code)), isNull);
      }
    });
  }
  test('coverage is actual; search and returned rules are bounded', () {
    expect(knowledge.rules.length, (raw['rules'] as List).length);
    expect(knowledge.rules.length, 1000);
    expect(knowledge.rules.where((r) => r.level == 'A').length, 4);
    expect(knowledge.search('quota').map((r) => r.id), contains('sh-smart-sync-quota'));
    expect(knowledge.search('').length, 32);
    expect(knowledge.search('x' * 121), isEmpty);
    expect(knowledge.rules.map((r) => r.id).toSet().length, knowledge.rules.length);
    expect(() => knowledge.rules.clear(), throwsUnsupportedError);
    expect(() => (knowledge.rules.first.data['signature'] as Map)['failure'] = 'worker', throwsUnsupportedError);
    expect(() => (knowledge.rules.first.data['source'] as List).clear(), throwsUnsupportedError);
  });
  test('unregistered and raw diagnostic IDs fail closed rather than match a fallback', () {
    for (final code in ['sh-src-${'0' * 20}', 'private student name']) {
      expect(knowledge.match('smart-sync', HealthObservation(HealthState.degraded,
          failure: HealthFailure.timeout, ownerCategory: 'timeout', diagnosticCode: code)), isNull);
    }
  });
  test('only fixed client deadline stages survive observation normalization', () async {
    final engine = UniversalHealth();
    engine.register(HealthProvider(id: 'smart-sync', version: '2.1',
      check: (_) async => const HealthObservation(HealthState.unknown)));
    try {
      await engine.bind(const HealthContext('school-a', 'profile-a'));
      for (final stage in ['responseHeaders', 'responseBody', 'private credential']) {
        engine.observe('smart-sync', HealthObservation(HealthState.degraded,
          failure: HealthFailure.timeout, ownerCategory: 'timeout', ownerStage: stage));
        expect(engine.observations['smart-sync']!.safeOwnerStage,
            stage == 'private credential' ? '' : stage);
      }
    } finally { await engine.dispose(); }
  });
  test('identical messages in multiple owners require the explicit source', () {
    final groups = <String, List<HealthKnowledgeRule>>{};
    for (final rule in knowledge.rules.where((r) => r.data.containsKey('sourceCase'))) {
      final source = rule.data['sourceCase'] as Map;
      groups.putIfAbsent(jsonEncode([rule.component, source['kind'], source['literal']]), () => []).add(rule);
    }
    final ambiguous = groups.values.where((g) => g.length > 1).first;
    final rule = ambiguous.first, source = ambiguous.first.data['sourceCase'] as Map;
    expect(knowledge.matchSourceCase(rule.component, source['kind'] as String, source['literal'] as String), isNull);
    expect(knowledge.matchSourceCase(rule.component, source['kind'] as String,
        source['literal'] as String, source: source['path'] as String)?.id, rule.id);
  });
  test('runtime error matching retains only a catalog ID and requires an exact typed literal', () {
    final rule = knowledge.rules.firstWhere((r) =>
        r.component == 'id-card' && (r.data['sourceCase'] as Map?)?['kind'] == 'FormatException');
    final literal = (rule.data['sourceCase'] as Map)['literal'] as String;
    // May be ambiguous: explicit context lookup above resolves those safely.
    final expected = knowledge.matchSourceCase('id-card', 'FormatException', literal)?.id ?? '';
    expect(knowledge.codeForError('id-card', FormatException(literal)), expected);
    expect(knowledge.codeForError('id-card', FormatException('$literal private student')), '');
    expect(knowledge.codeForError('id-card', StateError(literal)), '');
    expect(knowledge.codeForError('foreign-owner', FormatException(literal)), '');
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
  test('unfiltered learning never pairs terminals from a different version or failure', () {
    final now = DateTime.utc(2026, 10, 13);
    final history = [
      HealthEvent('worker', HealthFailure.worker, 'started', now, 'a' * 64,
          playbook: 'safe', providerVersion: '2.1'),
      HealthEvent('worker', HealthFailure.timeout, 'verified', now, 'b' * 64,
          playbook: 'safe', providerVersion: '2.1'),
      HealthEvent('worker', HealthFailure.worker, 'verified', now, 'b' * 64,
          playbook: 'safe', providerVersion: '2.0'),
    ];
    final learning = HealthRepairLearning.forPlaybook(history, 'worker', 'safe', now);
    expect([learning.started, learning.verified, learning.failed], [1, 0, 0]);
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
