import 'dart:async';
import 'universal_health.dart';

/// Optional observation: a guardian failure cannot change the business result.
class HealthRuntime {
  static UniversalHealth get engine => UniversalHealth.instance;
  static const components = ['startup','database','smart-sync','sync-view','id-card','qr','inventory','documents','attendance','notices','monitor-worker'];
  static void registerPassive() {
    if (engine.registeredCount != 0) return;
    for (final id in components) {
      engine.register(HealthProvider(id:id, version:'2.0', check:(_) async => engine.observations[id] ?? const HealthObservation(HealthState.unknown)));
    }
  }
  static HealthFailure classify(Object error) {
    if (error is TimeoutException) return HealthFailure.timeout;
    if (error is FormatException) return HealthFailure.decoding;
    // No raw exception, stack, path, source bytes or message is retained.
    return HealthFailure.unknown;
  }
  static Future<T> measure<T>(String component, Future<T> Function() operation) async {
    final context = engine.context, generation=engine.epoch, watch = Stopwatch()..start();
    try {
      final result = await operation();
      if (context != null && generation==engine.epoch && engine.context?.same(context) == true) {
        try { engine.observe(component, HealthObservation(HealthState.healthy, verifiedAt:DateTime.now(), metrics:{'latencyMs':watch.elapsedMicroseconds/1000})); } catch (_) {}
      }
      return result;
    } catch (e) {
      if (context != null && generation==engine.epoch && engine.context?.same(context) == true) {
        try { engine.observe(component, HealthObservation(HealthState.needsAttention, failure:classify(e), metrics:{'latencyMs':watch.elapsedMicroseconds/1000})); } catch (_) {}
      }
      rethrow;
    }
  }
  static T measureSync<T>(String component, T Function() operation) {
    final bound=engine.context;
    try {
      final value=operation();
      if(bound!=null) { try {engine.observe(component,HealthObservation(HealthState.healthy,verifiedAt:DateTime.now()));}catch(_){} }
      return value;
    }catch(e){if(bound!=null){try{engine.observe(component,HealthObservation(HealthState.needsAttention,failure:classify(e)));}catch(_){}}rethrow;}
  }
}
