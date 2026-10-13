import 'dart:convert';
import 'dart:io';
import '../lib/health/health_knowledge.dart';
import '../lib/health/universal_health.dart';

void main() {
  final memory = ProcessInfo.currentRss;
  final startup = Stopwatch()..start();
  final knowledge = HealthKnowledge.instance;
  startup.stop();
  const signal = HealthObservation(HealthState.degraded,
      failure: HealthFailure.timeout, ownerCategory: 'timeout');
  String? baseline() {
    for (final rule in knowledge.rules) {
      final s = rule.data['signature'] as Map<String, dynamic>;
      if (s['component'] == 'smart-sync' && s['failure'] == 'timeout' && s['ownerCategory'] == 'timeout') return rule.id;
    }
    return null;
  }
  for (var n = 0; n < 10000; n++) { baseline(); knowledge.match('smart-sync', signal); }
  final linear = Stopwatch()..start();
  var baselineMatches = 0;
  for (var n = 0; n < 100000; n++) { if (baseline() != null) baselineMatches++; }
  linear.stop();
  final indexed = Stopwatch()..start();
  var indexedMatches = 0;
  for (var n = 0; n < 100000; n++) {
    if (knowledge.match('smart-sync', signal) != null) indexedMatches++;
  }
  indexed.stop();
  final report = {'fixture': 'Synthetic Dart process; linear reference versus indexed matcher. Not physical-device acceptance.',
    'actualCatalogRules': knowledge.rules.length, 'observations': 100000,
    'linearMicros': linear.elapsedMicroseconds, 'indexedMicros': indexed.elapsedMicroseconds,
    'baselineMatches': baselineMatches, 'indexedMatches': indexedMatches,
    'coldCatalogMicros': startup.elapsedMicroseconds,
    'processRssDeltaBytes': ProcessInfo.currentRss-memory,
    'physicalUiBlockingMillis': null, 'physicalLowEndWindowsOverhead': null};
  final file = File('build/universal-health/knowledge-benchmark.json');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  print(jsonEncode(report));
  if (baselineMatches != 100000 || indexedMatches != baselineMatches) throw StateError('Matcher parity failed');
}
