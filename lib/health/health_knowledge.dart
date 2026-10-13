import 'dart:convert';
import 'dart:async';
import 'universal_health.dart';
import 'knowledge/catalog_data.dart';

/// Declarative local guidance only. No action/command can be registered here.
class HealthKnowledgeRule {
  HealthKnowledgeRule(Map<String, dynamic> json)
      : data = _freeze(json) as Map<String, dynamic>;
  final Map<String, dynamic> data;
  String get id => data['id'] as String;
  String get component => data['component'] as String;
  String get name => data['name'] as String;
  String get level => data['level'] as String;
  String get solution => data['solution'] as String;
  String get verification => data['verification'] as String;
  String get playbook => data['playbook'] as String;
  static dynamic _freeze(dynamic value) {
    if (value is Map<String, dynamic>) return Map<String, dynamic>.unmodifiable(
        value.map((key, item) => MapEntry(key, _freeze(item))));
    if (value is List) return List<dynamic>.unmodifiable(value.map(_freeze));
    return value;
  }
}

class HealthKnowledge {
  HealthKnowledge._() {
    final decoded = jsonDecode(healthKnowledgeJson) as Map<String, dynamic>;
    rules = List.unmodifiable((decoded['rules'] as List).map(
      (r) => HealthKnowledgeRule(r as Map<String, dynamic>),
    ));
    for (final rule in rules) {
      final signature = rule.data['signature'] as Map<String, dynamic>;
      final code = signature['diagnosticCode'] as String? ?? '';
      if (code.isNotEmpty) {
        _codes[code] = rule;
        final source = rule.data['sourceCase'] as Map<String, dynamic>;
        final key = jsonEncode([rule.component, source['kind'], source['literal']]);
        _sourceIndex.putIfAbsent(key, () => []).add(rule);
        continue;
      }
      _index['${rule.component}/${signature['failure']}/${signature['ownerCategory']}'] = rule;
    }
  }
  // Lazy once, not JSON parsing or scanning rules on every frame/observation.
  static final instance = HealthKnowledge._();
  static const version = '2.1.0';
  late final List<HealthKnowledgeRule> rules;
  final Map<String, HealthKnowledgeRule> _index = {};
  final Map<String, HealthKnowledgeRule> _codes = {};
  final Map<String, List<HealthKnowledgeRule>> _sourceIndex = {};
  HealthKnowledgeRule? match(String component, HealthObservation observation) {
    if (observation.failure == HealthFailure.none ||
        observation.state == HealthState.healthy ||
        observation.state == HealthState.paused) return null;
    if (observation.diagnosticCode.isNotEmpty) {
      final rule = _codes[observation.safeDiagnosticCode];
      final signature = rule?.data['signature'] as Map<String, dynamic>?;
      return rule?.component == component &&
          signature?['failure'] == observation.failure.name &&
          signature?['ownerCategory'] == observation.safeOwnerCategory ? rule : null;
    }
    return _index['$component/${observation.failure.name}/${observation.safeOwnerCategory}'] ??
        _index['$component/${observation.failure.name}/'];
  }
  /// Exact local owner message, never fuzzy exception-text classification.
  /// Ambiguous identical literals require an explicit reviewed source context.
  /// This lookup retains no caller message and grants no repair authority.
  HealthKnowledgeRule? matchSourceCase(String component, String kind,
      String literal, {String? source}) {
    if (literal.length > 180 || kind.length > 32 || component.length > 48) return null;
    final candidates = _sourceIndex[jsonEncode([component, kind, literal])] ?? const [];
    if (source != null) {
      for (final rule in candidates) {
        if ((rule.data['sourceCase'] as Map)['path'] == source) return rule;
      }
      return null;
    }
    return candidates.length == 1 &&
        (candidates.single.data['sourceCase'] as Map)['origins'] == 1
        ? candidates.single : null;
  }
  String codeForError(String component, Object error) {
    String kind;
    Object? message;
    if (error is FormatException) {
      kind = 'FormatException'; message = error.message;
    } else if (error is TimeoutException) {
      kind = 'TimeoutException'; message = error.message;
    } else if (error is StateError) {
      kind = 'StateError'; message = error.message;
    } else if (error is ArgumentError) {
      kind = 'ArgumentError'; message = error.message;
    } else {
      return '';
    }
    return message is String ? matchSourceCase(component, kind, message)?.id ?? '' : '';
  }
  List<HealthKnowledgeRule> search(String query) {
    final term = query.trim().toLowerCase();
    if (term.length > 120) return const [];
    return rules.where((r) => '${r.id} ${r.name} ${r.component} ${r.solution} ${r.data['source']}'
        .toLowerCase().contains(term)).take(32).toList(growable: false);
  }
}

class HealthCauseCandidate {
  const HealthCauseCandidate(this.title, this.score, this.basis);
  final String title, basis;
  final int score; // Transparent heuristic evidence points, NOT probability.
}

/// Ranking is read-only and cannot change repair admission or grant authority.
List<HealthCauseCandidate> rankHealthCauses(
    String component, HealthObservation observation,
    Map<String, HealthObservation> observations) {
  final candidates = <HealthCauseCandidate>[];
  if ({HealthFailure.timeout, HealthFailure.server, HealthFailure.offline,
        HealthFailure.quota}.contains(observation.failure)) {
    candidates.add(HealthCauseCandidate('Owner transport/provider failure', 2,
        'Typed owner category ${observation.failure.name}; failing stage unconfirmed'));
  }
  final database = observations['database'];
  if (component != 'database' && database != null &&
      {HealthFailure.storage, HealthFailure.corrupt, HealthFailure.databaseLocked}
          .contains(database.failure)) {
    candidates.add(const HealthCauseCandidate('Concurrent local storage failure', 1,
        'Current database provider failure; correlation only'));
  }
  if (observation.safeMetrics['latencyMs'] != null &&
      observation.safeMetrics['latencyMs']! >= 45000) {
    candidates.add(const HealthCauseCandidate('Slow measured owner operation', 1,
        'At least 45000ms measured end-to-end; no stage/root cause proved'));
  }
  candidates.sort((a, b) => b.score.compareTo(a.score));
  return List.unmodifiable(candidates);
}
