import 'universal_health.dart';
import 'health_knowledge.dart';

/// Evidence-based candidates, never authority to execute a repair.
class HealthDiagnosis {
  const HealthDiagnosis(
    this.component,
    this.failure,
    this.evidence,
    this.possibleSharedCause,
  );
  final String component, evidence;
  final HealthFailure failure;
  final String? possibleSharedCause;
  String get reason => HealthDiagnostics.guidance(component, failure).$1;
  String get nextAction => HealthDiagnostics.guidance(component, failure).$2;
  String get sourceLocation => HealthDiagnostics.source(component, failure);
  String get sourceMeaning =>
      'Reviewed source entry points to inspect; an exact faulty line is not confirmed by this component signal.';
}

class HealthDiagnostics {
  static (String, String) guidance(
    String component,
    HealthFailure failure,
  ) => switch (failure) {
    HealthFailure.conflict => (
      'The owner retained different local/cloud versions. This is a data-version conflict; a code defect is not established.',
      'Open Sync & Backup → Review. Read both authenticated versions. If identical, use the verified already-synced path; if different, choose only after comparing. Keep document originals; do not force a winner.',
    ),
    HealthFailure.offline ||
    HealthFailure.timeout ||
    HealthFailure.server ||
    HealthFailure.quota => (
      'The owner observed a transport/server/quota failure; the provider-side cause or exact code line is unconfirmed.',
      component == 'smart-sync'
          ? 'Existing Sync Engine retries the same operation with bounded backoff and verified ACK. Keep the queue. If repeated, export diagnostics and correlate the request reference with Render and owner Apps Script logs; quota waits must not be bypassed.'
          : 'Keep the original input and owner operation. Automatic business retry is not registered by this guardian for this component. Collect owner diagnostics; respect quota/backoff and do not launch duplicate work.',
    ),
    HealthFailure.authorization || HealthFailure.identity => (
      'Authorization or school identity verification failed.',
      'Verify the current school account, licence and owner Script permissions. Do not change school identity or bypass authorization. Export the sanitized error reference for support.',
    ),
    HealthFailure.configuration => (
      'The owner requires configuration or input review; use its typed category below to distinguish them.',
      'Check the school storage connection, deployed Script protocol and missing fields. Never replace a complete cloud school profile with blank local data. Export diagnostics to identify the rejected entry/code.',
    ),
    HealthFailure.storage ||
    HealthFailure.corrupt ||
    HealthFailure.databaseLocked => (
      'Storage access/integrity needs attention; exact cause is unconfirmed.',
      'Retain originals and database. Verify original-file availability and free space; collect owner storage diagnostics. Do not reset the database, delete records or clear the queue.',
    ),
    HealthFailure.worker => (
      'A registered worker/timer or derived view did not meet its owner check.',
      const {
            'sync-scheduler',
            'health-report-timer',
            'monitor-worker',
            'sync-view',
          }.contains(component)
          ? 'Reviewed timer/view repairs run automatically within persisted cooldown limits. If still unresolved, inspect repair history for blocked, unverified, timeout or circuit-open evidence and the owner source below.'
          : 'No reviewed worker restart is registered for this component. Preserve its in-flight work and inspect the component owner diagnostics before adding a safe recovery interface.',
    ),
    HealthFailure.decoding || HealthFailure.rendering => (
      'The owner observed a decoding/rendering failure; exact failing input or line is unconfirmed.',
      'Keep the original file. Check supported file format and owner processing logs. Do not upload a broken replacement or treat a render as cloud verification.',
    ),
    HealthFailure.overloaded => (
      'The owner reported workload pressure.',
      'Let in-flight work settle; collect measured latency/resource samples. Do not launch duplicate work.',
    ),
    _ => (
      'No sufficiently specific failure evidence is available.',
      'Run diagnostics and export owner evidence. Root cause and exact code line remain Unknown.',
    ),
  };
  static String source(String component, HealthFailure failure) {
    if (component == 'sync-scheduler')
      return 'lib/windows_sync_engine.dart → repairAutomaticSchedule; lib/windows_sync_schedule.dart → repairReconciliationTimer';
    if (component == 'health-report-timer')
      return 'lib/health/health_reporter.dart → repairTimer / report';
    if (component == 'monitor-worker')
      return 'lib/health/health_runtime.dart → monitorProvider; lib/health/universal_health.dart → restartMonitor';
    if (component == 'sync-view')
      return 'lib/health/windows_health_adapter.dart → refresh-sync-view; lib/windows_sync_engine.dart → refreshDetails';
    if (component == 'smart-sync')
      return failure == HealthFailure.conflict
          ? 'lib/windows_sync_engine.dart → syncNow; lib/windows_sync_conflict_review.dart → verify / alreadySynced / commit; lib/windows_sync_comparison.dart → compareSyncVersions'
          : 'lib/windows_sync_recovery.dart → windowsSyncRecovery; lib/sync_recovery_policy.dart → SyncRecoveryDecision.classify; functions/managed-schools.js → signedRequest; school-backend/managed/SaarthiManagedAdapter.gs';
    return switch (component) {
      'database' =>
        'lib/storage/windows_sqlite_store.dart; lib/windows_local_storage.dart',
      'documents' || 'inventory' => 'lib/document_pipeline.dart; lib/windows_backend_bridge.dart → flushDocumentPending',
      'id-card' => 'lib/id_card_engine.dart',
      'qr' => 'lib/qr_authentication_engine.dart',
      'attendance' =>
        'lib/mobile/attendance_store.dart; lib/mobile/school_session.dart',
      'notices' =>
        'lib/windows_notice_delivery.dart; lib/mobile/school_session.dart',
      'startup' => 'lib/main_windows.dart; lib/main_android.dart',
      _ => 'Provider source is not registered in the reviewed support map; exact location Unknown.',
    };
  }

  static List<String> report(UniversalHealth engine) => [
    for (final d in diagnose(engine))
      '${d.component}: ${d.failure.name}\n${d.reason}\nOwner category: ${engine.observations[d.component]?.safeOwnerCategory.isNotEmpty == true ? engine.observations[d.component]!.safeOwnerCategory : "Unknown"}\nMeasured owner counters: ${engine.observations[d.component]?.safeMetrics}\nEvidence: ${d.evidence}\nRepair history: ${engine.history.where((e) => e.component == d.component && e.stage != "observed").map((e) => e.stage).toSet().join(", ")}\nNext action: ${d.nextAction}\nSource: ${d.sourceLocation}\n${d.sourceMeaning}${d.possibleSharedCause == null ? "" : "\n${d.possibleSharedCause}"}\n${knowledgeReport(engine, d.component, engine.observations[d.component]!)}',
  ];
  static String knowledgeReport(UniversalHealth engine, String component,
      HealthObservation observation) {
    final rule = HealthKnowledge.instance.match(component, observation);
    final causes = rankHealthCauses(component, observation, engine.observations);
    final learning = rule == null || rule.playbook.isEmpty ? null :
        HealthRepairLearning.forPlaybook(engine.history, component, rule.playbook, engine.now());
    return 'Knowledge: ${rule?.id ?? "Unrecognized; no matching reviewed rule"}\n'
        'Registered capability IDs: ${engine.repairCapabilities(component).join(", ")}; independent owner admission is required\n'
        'Measured client deadline stage: ${observation.safeOwnerStage.isEmpty ? "Unknown" : observation.safeOwnerStage}; upstream root cause unconfirmed\n'
        '${rule == null ? "Escalation only" : "Level ${rule.level}: ${rule.solution}"}\n'
        'Verification: ${rule?.verification ?? "Collect fresh owner evidence; no repair is authorized"}\n'
        'Hypotheses (evidence points, not probability): ${causes.isEmpty ? "Unknown" : causes.map((c) => "${c.title}: ${c.score} (${c.basis})").join("; ")}\n'
        '${learning == null ? "No attributed repair-learning evidence" : "Retained attributed attempts: ${learning.started}; verified: ${learning.verified}; failed: ${learning.failed}; recurring failures: ${learning.recurrences}; mean verified duration ms: ${learning.meanVerifiedMillis ?? "Unknown"}"}';
  }
  static List<HealthDiagnosis> diagnose(UniversalHealth engine) {
    final observations = engine.observations, history = engine.history;
    final storage = observations['database'];
    return [
      for (final entry in observations.entries)
        if (entry.value.failure != HealthFailure.none)
          HealthDiagnosis(
            entry.key,
            entry.value.failure,
            '${history.where((e) => e.component == entry.key && e.failure == entry.value.failure && e.stage == 'observed').length} retained distinct observations; ${history.where((e) => e.component == entry.key && e.stage == 'unverified').length} unverified repair outcomes',
            entry.key != 'database' &&
                    storage != null &&
                    {
                      HealthFailure.storage,
                      HealthFailure.databaseLocked,
                      HealthFailure.corrupt,
                    }.contains(storage.failure)
                ? 'Concurrent database failure; correlation only, root cause unconfirmed'
                : null,
          ),
    ];
  }

  /// Explicit optional advisor. Only component enums and bounded counts leave
  /// this interface. No credentials, school IDs, file paths, operations or stacks.
  /// Returned text is untrusted advice; it has no reference to recovery execution.
  static Future<String?> advisory(
    UniversalHealth engine,
    Future<String> Function(Map<String, dynamic>)? advisor,
  ) async {
    if (advisor == null) return null;
    final request = {
      'schema': 2,
      'components': [
        for (final e in engine.observations.entries.take(32))
          {
            'id': e.key,
            'state': e.value.state.name,
            'failure': e.value.failure.name,
          },
      ],
      'retainedEvents': engine.history.length,
    };
    try {
      final advice = await advisor(request).timeout(const Duration(seconds: 5));
      if (advice.length > 2000 ||
          advice.contains(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]')))
        return null;
      return advice;
    } catch (_) {
      return null;
    }
  }
}
