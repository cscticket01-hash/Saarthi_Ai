import 'dart:async';
import 'universal_health.dart';
import 'health_knowledge.dart';
import 'document_worker_owner.dart';

/// Optional observation: a guardian failure cannot change the business result.
class HealthRuntime {
  static UniversalHealth get engine => UniversalHealth.instance;
  static const components = ['startup','database','smart-sync','sync-view','id-card','qr','inventory','documents','attendance','notices','monitor-worker'];
  static HealthProvider monitorProvider(UniversalHealth guardian)=>HealthProvider(id:'monitor-worker',version:'2.0',check:(_)async {
    final heartbeat=guardian.lastHeartbeat;
    return heartbeat!=null&&guardian.now().difference(heartbeat)<const Duration(seconds:90)?HealthObservation(HealthState.healthy,verifiedAt:heartbeat):const HealthObservation(HealthState.degraded,failure:HealthFailure.worker);
  },playbooks:[RecoveryPlaybook(id:'restart-monitor-timer',kind:RecoveryKind.statelessWorker,failures:{HealthFailure.worker},precondition:(lease)async=>lease.valid&&!guardian.paused,execute:guardian.restartMonitor,verify:(lease)async=>lease.valid&&guardian.lastHeartbeat!=null&&guardian.now().difference(guardian.lastHeartbeat!)<const Duration(seconds:5))]);
  static void registerPassive() {
    if (engine.registeredCount != 0) return;
    for (final id in components) {
      if(id=='monitor-worker'){engine.register(monitorProvider(engine));continue;}
      engine.register(HealthProvider(id:id, version:'2.0', check:(_) async => engine.observations[id] ?? const HealthObservation(HealthState.unknown)));
    }
    engine.register(DocumentWorkerOwner.instance.provider());
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
        try { engine.observe(component, HealthObservation(HealthState.needsAttention, failure:classify(e), diagnosticCode:HealthKnowledge.instance.codeForError(component, e), metrics:{'latencyMs':watch.elapsedMicroseconds/1000})); } catch (_) {}
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
    }catch(e){if(bound!=null){try{engine.observe(component,HealthObservation(HealthState.needsAttention,failure:classify(e),diagnosticCode:HealthKnowledge.instance.codeForError(component, e)));}catch(_){}}rethrow;}
  }
}
