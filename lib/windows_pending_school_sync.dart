import 'windows_platform_client.dart';
import 'windows_shared_repair_knowledge.dart';
import 'windows_repair_memory.dart';
import 'windows_sync_comparison.dart';
import 'dart:async';

import 'windows_local_firestore.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_sync_recovery.dart';
import 'sync_recovery_policy.dart';

bool isRecordSyncConflict(Object error) => error is CentralCloudException
    ? error.recordConflict
    : error is StateError &&
          RegExp(
            r'record revision conflict|sync operation id conflict',
            caseSensitive: false,
          ).hasMatch(error.toString());

/// The stored retry deadline is an admission boundary, never a claimed send time.
bool pendingRecordBackoffDue(
  Map<String, dynamic> item,
  DateTime now, {
  bool explicitRetry = false,
}) {
  final deadline = item['retryAtMillis'];
  return explicitRetry ||
      item['syncState'] != 'retry' ||
      deadline is! int ||
      deadline <= now.millisecondsSinceEpoch;
}

/// Publish the durable queue for one immutable local school profile.
/// Failure leaves the queued record intact; acknowledgement is version-checked.
class WindowsPendingSchoolSync {
  static const automaticRepairProbeLimit = 5;
  /// Read-only diagnosis followed by existing CAS owners. No inferred ACK,
  /// credential repair, queue reset, or blind same-field conflict overwrite.
  static Future<int> repair({
    required String profileId,
    required String school,
    required Future<Map<String, dynamic>> Function(String, String) read,
    bool Function()? canAdmit,
    void Function(Map<String, dynamic>)? onActivity,
    DateTime Function()? now,
    bool explicitRetry = false,
    String? Function(String module,String category)? learnedAction,
    Duration probeTimeout = const Duration(seconds: 40),
  }) async {
    if (probeTimeout <= Duration.zero) {
      throw ArgumentError.value(probeTimeout, 'probeTimeout');
    }
    final db = FirebaseFirestore.instance, clock = now ?? DateTime.now;
    void scope() {
      if (db.activeProfileId != profileId ||
          db.activeProfileIdentity['schoolSyncId'] != school)
        throw StateError('School changed during repair.');
    }

    scope();
    final rows = await db.collection('_windows_firebase_outbox').get();
    scope();
    var probes = 0, repaired = 0;
    final repairRows=rows.docs.toList()..sort((a,b){
      int priority(Map row)=>learnedAction?.call(row['collection']?.toString()??'',row['failureCategory']?.toString()??'conflict')==null?1:0;
      return priority(a.data()).compareTo(priority(b.data()));
    });
    for (final row in repairRows) {
      if (probes >= 5 || canAdmit?.call() == false) break;
      scope();
      final item = row.data(),
          state = item['syncState'],
          category = item['failureCategory'];
      if (item['schoolId'] != school ||
          !{'conflict', 'needsAttention'}.contains(state) ||
          state != 'conflict' &&
              !{'networkPath', 'timeout', 'server'}.contains(category) ||
          !{'set', 'update', 'delete'}.contains(item['operation']) ||
          item['collection'] == 'documents' ||
          item['operationId'] is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{16,100}$')
              .hasMatch(item['operationId'] as String) ||
          item['baseCloudRevision'] is! String)
        continue;
      final journal = db
          .collection('_windows_sync_status')
          .doc('repair-${item['operationId']}');
      final prior = (await journal.get()).data();
      scope();
      if (prior != null &&
          (prior['schoolId'] != school ||
              prior['operationId'] != item['operationId'])) {
        throw StateError('Repair journal identity unverified.');
      }
      final learned = learnedAction?.call(item['collection'] as String, category?.toString() ?? 'conflict');
      // One learned replay per immutable operation; server CAS/idempotency remain
      // authoritative. Quota/auth/configuration/conflict never use this shortcut.
      if (learned == 'replay_original' && state == 'needsAttention' &&
          {'networkPath','timeout','server'}.contains(category) &&
          (item['retryAtMillis'] as num? ?? 0) <= clock().millisecondsSinceEpoch &&
          prior?['learnedReplayOperation'] != item['operationId']) {
        await journal.set({'schoolId':school,'operationId':item['operationId'],
          'learnedReplayOperation':item['operationId']}, const SetOptions(merge:true));
        scope();
        if(await db.recordOutboxFailure(row.reference,item,state:'retry',
            failureCategory:category as String,retryCount:0,
            retryAtMillis:clock().millisecondsSinceEpoch,
            error:'Previously verified transport action: replay the original immutable request.')) {
          onActivity?.call({'schoolId':school,'collection':item['collection'],
            'documentId':item['documentId'],'operationId':item['operationId'],
            'queueCollection':'_windows_firebase_outbox','stage':'learnedActionApplied',
            'failureCategory':category,'at':clock().millisecondsSinceEpoch});
          repaired++;probes++;continue;
        }
      }
      final legacyFeeProbe = legacyFeePublicationCandidate(item) && prior?['legacyFeePublicationProbeVersion'] != 2;
      final runtimeProbe = admitUpdatedRuntimeProbe(prior, WindowsPlatformClient.version);
      final inputSignature = syncPayloadHash({
        'schoolId': school, 'collection': item['collection'],
        'documentId': item['documentId'], 'operationId': item['operationId'],
        'operation': item['operation'], 'baseCloudRevision': item['baseCloudRevision'],
        'data': item['data'],
      });
      final manifest = (await db.collection('_windows_sync_manifest')
        .doc(item['collection'] as String).get()).data();
      scope();
      final head = manifest?['revision'] is String ? manifest!['revision'] as String : null;
      if (repeatedRepairProbe(prior, signature: inputSignature,
          cloudRevision: head, now: clock().millisecondsSinceEpoch,
          explicitRetry: explicitRetry || legacyFeeProbe || runtimeProbe, cooldownSeconds: WindowsSharedRepairKnowledge.value(
            'record_probe_cooldown',school,module:item['collection'] as String,category:'conflict'))) continue;
      // Budget survives restarts and hourly reconciliation. Manual diagnosis
      // admits one more bounded probe; it never resets history or grants ACK.
      if (!explicitRetry && !legacyFeeProbe && !runtimeProbe &&
          (prior?['attempts'] as num? ?? 0) >= automaticRepairProbeLimit) {
        if (prior?['outcome'] != 'probe_budget_exhausted') {
          await journal.set({
            'outcome': 'probe_budget_exhausted',
            'reviewRequired': true,
            'lastProbeAt': clock().millisecondsSinceEpoch,
          }, const SetOptions(merge: true));
          scope();
          onActivity?.call({
            'schoolId': school,
            'operationId': item['operationId'],
            'queueCollection': '_windows_firebase_outbox', 'queueId': row.id,
            'collection': item['collection'], 'documentId': item['documentId'],
            'stage': 'repairDiagnosed',
            'outcome': 'probe_budget_exhausted',
            'failureCategory': category ?? 'conflict',
            'at': clock().millisecondsSinceEpoch,
          });
        }
        continue;
      }
      if (!explicitRetry && !legacyFeeProbe && !runtimeProbe &&
          (prior?['nextProbeAt'] as num? ?? 0) > clock().millisecondsSinceEpoch)
        continue;
      final attempts = (prior?['attempts'] as num? ?? 0).toInt() + 1;
      final delay = Duration(
        minutes: (5 * (1 << attempts.clamp(0, 4).toInt())).clamp(5, 60).toInt(),
      );
      await journal.set({
        'schoolId': school,
        'operationId': item['operationId'],
        if (legacyFeeProbe || prior?['legacyFeePublicationProbeVersion'] == 2) 'legacyFeePublicationProbeVersion': 2,
        'attempts': attempts,
        if(prior?['learnedReplayOperation'] is String) 'learnedReplayOperation':prior!['learnedReplayOperation'],
        'diagnosedAppVersion': WindowsPlatformClient.version,
        'runtimeUpgradeProbes': ((prior?['runtimeUpgradeProbes'] as num?) ?? 0).toInt() + (runtimeProbe ? 1 : 0),
        'nextProbeAt': clock().add(delay).millisecondsSinceEpoch,
        'outcome': 'diagnosing',
        'inputSignature': inputSignature,
        'cloudManifestRevision': head,
      });
      scope();
      probes++;
      // A read-only probe must never turn a transport failure into a queue
      // acknowledgement. Only record-scoped transient failures can be skipped;
      // shared network failures halt this pass, and authorization/quota/
      // configuration/identity failures still reach the authoritative owner.
      Map<String, dynamic> response;
      try {
        response = await read(
          item['collection'] as String,
          item['documentId'] as String,
        ).timeout(probeTimeout);
      } catch (error) {
        scope();
        final decision = windowsSyncRecovery(error);
        if (!{
          SyncFailureKind.networkPath,
          SyncFailureKind.timeout,
          SyncFailureKind.server,
        }.contains(decision.kind)) {
          await journal.set({
            'outcome': 'probe_blocked',
            'failureCategory': decision.kind.name,
          }, const SetOptions(merge: true));
          scope();
          rethrow;
        }
        // The previously persisted nextProbeAt is a durable cooldown. Keep
        // the exact original operation, its payload, and all local edits.
        await journal.set({
          'outcome': 'probe_deferred',
          'failureCategory': decision.kind.name,
          'lastProbeAt': clock().millisecondsSinceEpoch,
        }, const SetOptions(merge: true));
        scope();
        onActivity?.call({
          'schoolId': school,
          'queueCollection': '_windows_firebase_outbox',
          'queueId': row.id,
          'operationId': item['operationId'],
          'collection': item['collection'], 'documentId': item['documentId'],
          'stage': 'repairDiagnosed',
          'outcome': 'probe_deferred',
          'failureCategory': decision.kind.name,
          'at': clock().millisecondsSinceEpoch,
        });
        // A disconnected network is shared across records: avoid hammering
        // the provider. A timed-out/5xx record probe may be record-specific,
        // so independent, already-eligible rows may still be diagnosed.
        if (decision.kind == SyncFailureKind.networkPath) break;
        continue;
      }
      scope();
      if (response['schoolId'] != school ||
          response['syncProtocol'] != 2 ||
          response['pointRead'] != true ||
          response['records'] is! Map ||
          (response['records'] as Map).keys.any((k) => k != item['documentId']))
        throw StateError('Repair readback unverified; original retained.');
      final remote = response['records'][item['documentId']];
      if (remote != null) {
        if (remote is! Map ||
            remote['schoolId'] != school ||
            remote['_syncRevision'] is! String ||
            (remote['_syncRevision'] as String).isEmpty)
          throw StateError('Repair cloud identity unverified.');
        await db.recordOutboxConflict(row.reference, item, {
          ...Map<String, dynamic>.from(remote),
          'id': item['documentId'],
        });
        scope();
      }
      final current = (await row.reference.get()).data();
      scope();
      var outcome = 'review_required';
      if (current == null) {
        outcome = 'verified_cloud_reconciled';
        repaired++;
      } else if (current['operationId'] == item['operationId'] &&
          current['syncState'] == 'pending') {
        outcome = 'retry_admitted';
        repaired++;
      } else if (current['operationId'] == item['operationId'] &&
          current['syncState'] == 'needsAttention' &&
          {
            'networkPath',
            'timeout',
            'server',
          }.contains(current['failureCategory']) &&
          (remote == null
              ? item['baseCloudRevision'] == ''
              : remote['_syncRevision'] == item['baseCloudRevision'])) {
        if (await db.recordOutboxFailure(
          row.reference,
          current,
          state: 'retry',
          error: 'Authenticated repair readback verified; original request retained.',
          failureCategory: current['failureCategory'] as String,
          retryCount: 0,
          retryAtMillis: clock().millisecondsSinceEpoch,
        )) {
          outcome = 'retry_admitted';
          repaired++;
        }
      }
      await journal.set({
        'outcome': outcome,
        'verifiedReadbackAt': clock().millisecondsSinceEpoch,
      }, const SetOptions(merge: true));
      scope();
      onActivity?.call({
        'schoolId': school,
        'queueCollection': '_windows_firebase_outbox',
        'queueId': row.id,
        'operationId': item['operationId'],
        'collection': item['collection'], 'documentId': item['documentId'],
        'failureCategory': category ?? 'conflict',
        'stage': 'repairDiagnosed',
        'outcome': outcome,
        'at': clock().millisecondsSinceEpoch,
      });
    }
    return repaired;
  }

  static Future<void> flush({
    required String profileId,
    required Future<void> Function(
      String collection,
      String id,
      String operation,
      Map<String, dynamic>? data,
    )
    send,
    Future<String> Function(Map<String, dynamic> item)? sendVersioned,
    Future<Map<String, dynamic>?> Function(
      DocumentReference<Map<String, dynamic>>,
      Map<String, dynamic>,
    )?
    prepareVersioned,
    Map<String, dynamic>? Function(Map<String, dynamic>)? canonicalForAck,
    bool Function()? canAdmit,
    String? onlyQueueId,
    String? onlyOperationId,
    bool respectBackoff = false,
    bool diagnoseUnclassified = false,
    void Function(Map<String, dynamic>)? onActivity,
  }) async {
    final db = FirebaseFirestore.instance;
    void report(
      String stage,
      String queueId,
      Map<String, dynamic> item, {
      String? category,
      DateTime? retryAt,
      int? elapsedMicros,
    }) {
      try {
        onActivity?.call({
          'queueCollection': '_windows_firebase_outbox',
          'queueId': queueId,
          'collection': item['collection'],
          'documentId': item['documentId'],
          'operationId': item['operationId'],
          'schoolId':
              item['schoolId'] ?? db.activeProfileIdentity['schoolSyncId'],
          'stage': stage,
          'at': DateTime.now().millisecondsSinceEpoch,
          'isRetryable':
              stage == 'retry' &&
              recoverablePendingCategories.contains(category),
          if (category != null) 'failureCategory': category,
          if (retryAt != null) 'retryAt': retryAt.millisecondsSinceEpoch,
          if (elapsedMicros != null) 'elapsedMicros': elapsedMicros,
        });
      } catch (_) {
        /* Observers never affect queue integrity or ACKs. */
      }
    }

    void unchanged() {
      if (db.activeProfileId != profileId)
        throw StateError('School changed during sync.');
    }

    unchanged();
    final snapshot = await db.collection('_windows_firebase_outbox').get();
    unchanged();
    int time(Map<String, dynamic> d) {
      final value = d['queuedAt'];
      return value is Timestamp
          ? value.millisecondsSinceEpoch
          : value is num
          ? value.toInt()
          : 0;
    }

    int priority(Map<String, dynamic> d) {
      final collection = d['collection'];
      if (collection == 'students_directory') return -1;
      if ({
        'attendance_records',
        'attendance_logs',
        'teacher_attendance',
      }.contains(collection))
        return 0;
      if ({
        'fee_ledger',
        'fee_payments',
        'school_expenses',
        'teacher_salary',
      }.contains(collection))
        return 1;
      return collection == 'documents' ? 3 : 2;
    }

    final docs = snapshot.docs.toList()
      ..sort((a, b) {
        final order = priority(a.data()).compareTo(priority(b.data()));
        return order != 0 ? order : time(a.data()).compareTo(time(b.data()));
      });
    Object? firstDeferred;
    for (final queued in docs) {
      unchanged();
      queued.reference.requireOriginProfile();
      if (onlyQueueId != null && queued.id != onlyQueueId) continue;
      if (canAdmit?.call() == false) break;
      var item = queued.data();
      if (sendVersioned != null &&
          item['schoolId'] != null &&
          item['schoolId'] != db.activeProfileIdentity['schoolSyncId']) {
        report('needsAttention', queued.id, item, category: 'configuration');
        throw StateError(
          'Pending operation belongs to another school; original binding retained.',
        );
      }
      if (onlyOperationId != null && item['operationId'] != onlyOperationId)
        continue;
      if (respectBackoff &&
          !pendingRecordBackoffDue(
            item,
            DateTime.now(),
            explicitRetry: onlyOperationId != null,
          ))
        continue;
      final collection = item['collection']?.toString() ?? '';
      final id = item['documentId']?.toString() ?? '';
      final operation = item['operation']?.toString() ?? '';
      final raw = item['data'];
      if (collection.isEmpty ||
          id.isEmpty ||
          !{'set', 'update', 'delete'}.contains(operation) ||
          operation != 'delete' && raw is! Map) {
        await db.recordOutboxFailure(
          queued.reference,
          item,
          state: 'needsAttention',
          failureCategory: 'configuration',
          error: 'Invalid pending sync record retained for recovery.',
        );
        report('needsAttention', queued.id, item, category: 'configuration');
        continue;
      }
      if (sendVersioned != null &&
          (item['operationId'] == null || item['schoolId'] == null)) {
        final ownSchool = db.activeProfileIdentity['schoolSyncId'];
        if (ownSchool is! String || ownSchool.isEmpty)
          throw StateError('School identity required for queue migration.');
        // Migration is serialized with local writes and refuses foreign bindings.
        final migrated = await db.migrateOutboxIdentity(
          queued.reference,
          item,
          schoolId: ownSchool,
        );
        unchanged();
        if (migrated == null)
          continue; // A newer durable edit owns this row now.
        item = migrated;
      }
      if (recoverablePendingAttention(
        item,
        explicitRetry: onlyOperationId != null,
      )) {
        // Serialized CAS: a concurrent local edit or administrator review wins.
        final repaired = await db.recordOutboxFailure(
          queued.reference,
          item,
          state: 'retry',
          failureCategory: item['failureCategory'] as String,
          retryCount: (item['retryCount'] as num? ?? 0).toInt(),
          retryAtMillis: DateTime.now().millisecondsSinceEpoch,
          error: 'Known transport failure safely reopened; original operation retained.',
        );
        unchanged();
        if (!repaired) continue;
        final current = (await queued.reference.get()).data();
        unchanged();
        if (current == null || current['operationId'] != item['operationId'])
          continue;
        item = current;
        report(
          'automaticRepair',
          queued.id,
          item,
          category: item['failureCategory'] as String,
        );
      }
      // Explicit Sync Now can re-diagnose a legacy blocked request whose
      // category was never persisted. Preserve its exact operation/CAS base;
      // never rebase it or treat a successful transport response as an ACK.
      final diagnoseLegacy =
          diagnoseUnclassified &&
          sendVersioned != null &&
          item['syncState'] == 'needsAttention' &&
          (item['failureCategory'] == null || item['failureCategory'] == '') &&
          {'set', 'delete'}.contains(operation) &&
          collection != 'documents' &&
          item['schoolId'] == db.activeProfileIdentity['schoolSyncId'] &&
          item['operationId'] is String &&
          RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(item['operationId']) &&
          item['baseCloudRevision'] is String;
      if (item['syncState'] == 'conflict' ||
          item['syncState'] == 'needsAttention' && !diagnoseLegacy)
        continue;
      if (canAdmit?.call() == false) break;
      String? revision;
      final watch = Stopwatch()..start();
      report('cloudRequest', queued.id, item);
      try {
        if (sendVersioned != null) {
          final prior = item['priorDeletion'];
          if (prior is Map) {
            if (prior['schoolId'] != item['schoolId'] ||
                prior['collection'] != collection ||
                prior['documentId'] != id ||
                prior['operation'] != 'delete' ||
                prior['operationId'] is! String ||
                prior['baseCloudRevision'] is! String) {
              throw StateError(
                'Original same-school deletion dependency required.',
              );
            }
            final deletion = Map<String, dynamic>.from(prior);
            final deletedRevision = await sendVersioned(deletion);
            unchanged();
            if (deletedRevision.trim().isEmpty)
              throw const MissingSyncAcknowledgement();
            await db.acknowledgeOutbox(
              queued.reference,
              deletion,
              revision: deletedRevision,
            );
            final current = (await queued.reference.get()).data();
            unchanged();
            if (current == null ||
                current['operationId'] != item['operationId'])
              continue;
            item = current;
            if (item['priorDeletion'] != null)
              throw StateError('Deletion acknowledgement not durable.');
          }
          if (prepareVersioned != null && item['operation'] != 'delete') {
            final bound = await prepareVersioned(queued.reference, item);
            unchanged();
            if (bound == null) continue;
            item = bound;
          }
          final response = sendVersioned(item);
          report('waitingForAck', queued.id, item);
          revision = await response;
          if (revision.trim().isEmpty) throw const MissingSyncAcknowledgement();
        } else {
          final response = send(
            collection,
            id,
            operation,
            raw is Map ? Map<String, dynamic>.from(raw) : null,
          );
          report('waitingForResponse', queued.id, item);
          await response;
        }
      } catch (e) {
        unchanged();
        final decision = windowsSyncRecovery(e);
        final recordConflict =
            isRecordSyncConflict(e) ||
            decision.kind == SyncFailureKind.conflict;
        final code = e is CentralCloudException ? e.diagnosticCode : '';
        final attempts = (item['retryCount'] as num? ?? 0).toInt() + 1;
        final automaticRetry =
            decision.retry && attempts < automaticRecordRetryLimit;
        final retryAt = automaticRetry
            ? DateTime.now().add(decision.delay(attempts))
            : null;
        if (decision.kind == SyncFailureKind.timeout) {
          report(
            'timeout',
            queued.id,
            item,
            category: decision.kind.name,
            elapsedMicros: watch.elapsedMicroseconds,
          );
        }
        report(
          recordConflict
              ? 'conflict'
              : decision.kind == SyncFailureKind.authorization
              ? 'unauthorized'
              : automaticRetry
              ? 'retry'
              : 'needsAttention',
          queued.id,
          item,
          category: decision.kind.name,
          retryAt: retryAt,
          elapsedMicros: watch.elapsedMicroseconds,
        );
        await db.recordOutboxFailure(
          queued.reference,
          item,
          state: recordConflict
              ? 'conflict'
              : automaticRetry
              ? 'retry'
              : 'needsAttention',
          failureCategory: decision.kind.name,
          retryCount: attempts,
          retryAtMillis: retryAt?.millisecondsSinceEpoch,
          error: e.toString(),
          diagnostic: documentFailureDiagnostic(e, 'recordRequestAndAck'),
        );
        if (decision.independentRecords ||
            recordConflict ||
            {
              'SCRIPT_RECORD_VERIFY_FAILED',
              'SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED',
            }.contains(code)) {
          firstDeferred ??= e;
          continue; // Independent rows must not be starved by a conflict.
        }
        rethrow;
      }
      unchanged();
      await db.acknowledgeOutbox(
        queued.reference,
        item,
        revision: revision,
        canonicalRecord: canonicalForAck?.call(item),
      );
      watch.stop();
      report(
        sendVersioned != null ? 'verified' : 'requestCompleted',
        queued.id,
        item,
        elapsedMicros: watch.elapsedMicroseconds,
      );
    }
    if (firstDeferred != null) throw firstDeferred;
  }
}
