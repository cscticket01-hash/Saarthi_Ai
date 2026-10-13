import 'dart:convert';
import 'dart:io';
import '../lib/health/health_knowledge.dart';
import '../lib/health/universal_health.dart';

void main() {
  final memory = ProcessInfo.currentRss;
  final startup = Stopwatch()..start();
  final knowledge = HealthKnowledge.instance;
  startup.stop();
  final signals = [for (final rule in knowledge.rules)
    HealthObservation(HealthState.degraded,
        failure: HealthFailure.values.byName((rule.data['signature'] as Map)['failure'] as String),
        ownerCategory: (rule.data['signature'] as Map)['ownerCategory'] as String,
        diagnosticCode: (rule.data['signature'] as Map)['diagnosticCode'] as String? ?? '')];
  String? baseline(int index) {
    final signal = signals[index], component = knowledge.rules[index].component;
    for (final rule in knowledge.rules) {
      final s = rule.data['signature'] as Map<String, dynamic>;
      if (s['component'] == component && s['failure'] == signal.failure.name &&
          s['ownerCategory'] == signal.safeOwnerCategory &&
          (s['diagnosticCode'] ?? '') == signal.diagnosticCode) return rule.id;
    }
    return null;
  }
  for (var n = 0; n < 10000; n++) {
    final i = n % signals.length;
    baseline(i); knowledge.match(knowledge.rules[i].component, signals[i]);
  }
  final linear = Stopwatch()..start();
  var baselineMatches = 0;
  for (var n = 0; n < 100000; n++) { if (baseline(n % signals.length) != null) baselineMatches++; }
  linear.stop();
  final indexed = Stopwatch()..start();
  var indexedMatches = 0;
  final distinctMatches = <String>{};
  for (var n = 0; n < 100000; n++) {
    final i = n % signals.length;
    final match = knowledge.match(knowledge.rules[i].component, signals[i]);
    if (match?.id != knowledge.rules[i].id) throw StateError('Mixed-catalog matcher parity failed');
    if (match != null) { indexedMatches++; distinctMatches.add(match.id); }
  }
  indexed.stop();
  final report = {'fixture': 'Synthetic Dart process; linear reference versus indexed matcher. Not physical-device acceptance.',
    'actualCatalogRules': knowledge.rules.length, 'distinctMatchedRules': distinctMatches.length, 'observations': 100000,
    'linearMicros': linear.elapsedMicroseconds, 'indexedMicros': indexed.elapsedMicroseconds,
    'baselineMatches': baselineMatches, 'indexedMatches': indexedMatches,
    'coldCatalogMicros': startup.elapsedMicroseconds,
    'processRssDeltaBytes': ProcessInfo.currentRss-memory,
    'physicalUiBlockingMillis': null, 'physicalLowEndWindowsOverhead': null};
  final file = File('build/universal-health/knowledge-benchmark.json');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  print(jsonEncode(report));
  if (knowledge.rules.length != 1000 || distinctMatches.length != 1000 || baselineMatches != 100000 || indexedMatches != baselineMatches) throw StateError('Matcher parity failed');
}
