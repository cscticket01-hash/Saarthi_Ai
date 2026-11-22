import 'cloudflare_record_handoff.dart';
import 'windows_platform_client.dart';
import 'windows_shared_repair_knowledge.dart';
import 'windows_repair_memory.dart';
import 'windows_sync_comparison.dart';
import 'dart:async';
import 'dart:io';

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
  // A failed transport may be retained as needsAttention. Its stored
  // provider deadline still applies after process restart/reconnect.
  // Sync Now may probe a non-quota record, but never bypass a quota minimum.
  if(!{'retry','needsAttention'}.contains(item['syncState']))return true;
  final deadline=item['retryAtMillis'];
  if(deadline is! int||deadline<=now.millisecondsSinceEpoch)return true;
  return explicitRetry&&item['failureCategory']!='quota';
}

/// An unclassified failed notice delete can be retried only after an
/// authenticated point read proves either its unchanged original CAS baseline
/// or the tombstone for this exact immutable operation. This is NOT an ACK.
bool verifiedUnknownNoticeDeleteReadback(
  Map item, Object? remote, String school,
) {
  if (item['schoolId'] != school ||
      item['collection'] != 'school_notices' ||
      item['operation'] != 'delete' ||
      item['syncState'] != 'needsAttention' ||
      item['failureCategory'] != 'unknown' ||
      item['baseCloudRevision'] is! String ||
      (item['baseCloudRevision'] as String).isEmpty ||
      item['operationId'] is! String ||
      remote is! Map ||
      remote['schoolId'] != school ||
      remote['_syncRevision'] is! String ||
      (remote['_syncRevision'] as String).isEmpty) {
    return false;
  }
  return remote['_syncRevision'] == item['baseCloudRevision'] &&
          remote['_syncDeleted'] != true ||
      remote['_syncDeleted'] == true &&
          remote['_syncOperationId'] == item['operationId'];
}

/// Match the existing Worker's independent record-resource policy for expense
/// and attendance mutations, in addition to text/calendar device admissions.
/// Parent, fee, file, delete and atomic bundle dependencies remain barriers.
const parallelAttendanceExpenseCollections = {
  'school_expenses', 'attendance_records', 'attendance_logs', 'teacher_attendance',
};
/// Limit device concurrency to already versioned, metadata-only changes
/// for established person owners. Lifecycle/slot changes and new admissions
/// keep the existing serial owner. The Worker still orders provider commits.
bool independentExistingPersonPatch(Map item) {
  if(!{'students_directory','teachers_directory'}.contains(item['collection']) ||
      item['createIntent']==true || item['updateIntent']!=true ||
      item['baseCloudRevision'] is! String ||
      (item['baseCloudRevision'] as String).isEmpty ||
      RegExp(r'^(cf-|live-)').hasMatch(item['baseCloudRevision']) ||
      item['fieldPatch'] is! Map ||
      (item['wireData']!=null && (item['wireMode']!='fieldPatch1' ||
        item['wireData'] is! Map || item['wireData']['_syncFieldPatch'] is! Map)))return false;
  final patch=item['fieldPatch'] as Map;
  final set=patch['set'], remove=patch['remove'], identity=patch['identity'];
  final ownerKey=item['collection']=='students_directory'?'mobileStableId':'teacherId';
  if(patch['version']!=1 || set is! Map || remove is! List || remove.isNotEmpty ||
      identity is! Map || identity[ownerKey] is! String ||
      (identity[ownerKey] as String).isEmpty || item['data'] is! Map ||
      identity[ownerKey]!=item['data'][ownerKey])return false;
  // Only non-identity contact fields; never change roll/class, generation,
  // status, salary, guardian binding, media, or other shared resources.
  const allowed={'phone','email','address','contactNumber','alternatePhone'};
  final fields=set.entries.where((e)=>e.key!='updatedAt').toList();
  return fields.isNotEmpty && fields.every((e)=>allowed.contains(e.key) &&
      e.value is String && !(e.value as String).startsWith('data:'));
}

bool parallelContainsInlineMedia(Object? value,[int depth=0]) {
  if(depth>12)return true;
  if(value is String)return value.startsWith('data:');
  if(value is Map)return value.values.any((v)=>parallelContainsInlineMedia(v,depth+1));
  if(value is List)return value.any((v)=>parallelContainsInlineMedia(v,depth+1));
  return false;
}

bool canParallelStageRecord(Map item, String school, {
  required bool edgeDeliverySupported,
}) =>
    eligibleForRecordHandoff(item, school,
        edgeDeliverySupported: edgeDeliverySupported) &&
    ({'school_notices', 'school_calendar'}.contains(item['collection']) ||
      parallelAttendanceExpenseCollections.contains(item['collection']) ||
      independentExistingPersonPatch(item)) &&
    !parallelContainsInlineMedia(item['data']) &&
    {'pending', 'retry'}.contains(item['syncState']) &&
    item['documentId'] is String &&
    (item['documentId'] as String).isNotEmpty &&
    pendingRecordBackoffDue(Map<String, dynamic>.from(item), DateTime.now());

/// Existing Worker treats school expenses as independent resources. A
/// non-atomic fee/person/document row in this device's outbox is not a parent
/// of an expense. Let the broker durably accept independent expenses without
/// waiting for unrelated provider work, while retaining explicit local
/// deletion, reservation, supersession and school isolation barriers.
bool canStageExpensePastUnrelatedOwners(
  Map candidate, Iterable<Map<String,dynamic>> outbox, String school,
) {
  if(candidate['collection']!='school_expenses' ||
      candidate['schoolId']!=school ||
      candidate['operation']!='set')return false;
  for(final row in outbox) {
    if(row['schoolId']!=school ||
       row['atomicBundleId']!=null ||
       row['priorDeletion']!=null ||
       row['priorCloudWrite']!=null ||
       row['operation']=='delete')return false;
    if(row['collection']=='school_expenses' &&
       row['documentId']==candidate['documentId'] &&
       row['operationId']!=candidate['operationId'])return false;
  }
  return true;
}

/// Attendance can be admitted alongside unrelated fee, file and notice
/// backlog, but never ahead of an unresolved person/school-settings owner.
bool canStageAttendancePastUnrelatedOwners(
  Map candidate, Iterable<Map<String,dynamic>> outbox, String school,
) {
  if(!{'attendance_records','attendance_logs','teacher_attendance'}
      .contains(candidate['collection']) ||
      candidate['schoolId']!=school || candidate['operation']!='set')
    return false;
  for(final row in outbox) {
    if(row['schoolId']!=school ||
        row['atomicBundleId']!=null ||
        row['priorDeletion']!=null ||
        row['priorCloudWrite']!=null ||
        row['operation']=='delete' ||
        {'students_directory','teachers_directory','school_config','school_settings'}
            .contains(row['collection']))return false;
    if(row['collection']==candidate['collection'] &&
       row['documentId']==candidate['documentId'] &&
       row['operationId']!=candidate['operationId'])return false;
  }
  return true;
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
      // Only the exact atomic bundle owner can repair this reserved operation.
      if(item['atomicBundleId']!=null || item['priorCloudWrite']!=null)continue;
      // Existing unknown notices must not be stuck forever. Probe only the
      // original same-school DELETE; no automatic replay without readback.
      final unknownNoticeDelete = state == 'needsAttention' &&
          category == 'unknown' &&
          item['collection'] == 'school_notices' &&
          item['operation'] == 'delete' &&
          item['baseCloudRevision'] is String &&
          (item['baseCloudRevision'] as String).isNotEmpty;
      if (item['schoolId'] != school ||
          !{'conflict', 'needsAttention'}.contains(state) ||
          state != 'conflict' &&
              !{'networkPath', 'timeout', 'server'}.contains(category) &&
              !unknownNoticeDelete ||
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
      // One authenticated recovery attempt per immutable unknown deletion.
      // The journal survives restarts and manual Sync Now requests.
      if (unknownNoticeDelete &&
          prior?['unknownNoticeDeleteReplayV1'] == true) continue;
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
      if (unknownNoticeDelete) {
        var outcome = 'review_required';
        final current = (await row.reference.get()).data();
        scope();
        final currentSignature = current == null ? null : syncPayloadHash({
          'schoolId': school, 'collection': current['collection'],
          'documentId': current['documentId'],
          'operationId': current['operationId'],
          'operation': current['operation'],
          'baseCloudRevision': current['baseCloudRevision'],
          'data': current['data'],
        });
        if (verifiedUnknownNoticeDeleteReadback(item, remote, school) &&
            current != null && currentSignature == inputSignature &&
            current['syncState'] == 'needsAttention' &&
            current['failureCategory'] == 'unknown') {
          // The original operation ID and CAS revision are unchanged. The
          // server must still return the real verified deletion receipt.
          final admitted = await db.recordOutboxFailure(
            row.reference, current,
            state: 'retry', failureCategory: 'server',
            retryCount: 0,
            retryAtMillis: clock().millisecondsSinceEpoch,
            error: 'Authenticated notice deletion readback verified; original operation retained for authoritative retry.',
          );
          scope();
          if (admitted) {
            await journal.set({'unknownNoticeDeleteReplayV1': true},
                const SetOptions(merge: true));
            scope();
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
          'schoolId': school, 'queueCollection': '_windows_firebase_outbox',
          'queueId': row.id, 'operationId': item['operationId'],
          'collection': item['collection'],
          'documentId': item['documentId'],
          'failureCategory': 'unknown',
          'stage': 'repairDiagnosed', 'outcome': outcome,
          'at': clock().millisecondsSinceEpoch,
        });
        continue;
      }
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
    bool Function(Map<String, dynamic>)? parallelAdmission,
    void Function(Map<String, dynamic>)? onActivity,
  }) async {
    final db = FirebaseFirestore.instance;
    final school = db.activeProfileIdentity['schoolSyncId'];
    void report(
      String stage,
      String queueId,
      Map<String, dynamic> item, {
      String? category,
      String? failureCode,
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
          if (failureCode != null && RegExp(r'^[A-Z0-9_]{5,64}$').hasMatch(failureCode))
            'failureCode': failureCode,
          if (retryAt != null) 'retryAt': retryAt.millisecondsSinceEpoch,
          if (elapsedMicros != null) 'elapsedMicros': elapsedMicros,
        });
      } catch (_) {
        /* Observers never affect queue integrity or ACKs. */
      }
    }

    void unchanged() {
      if (db.activeProfileId != profileId ||
          db.activeProfileIdentity['schoolSyncId'] != school)
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
      if (collection == 'students_directory' || collection=='teachers_directory') return -1;
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
    // Recover the original authorized stage after an app/process restart,
    // without sending a second business mutation. One school-scoped snapshot
    // per flush; the durable CAS remains the only local handoff owner.
    final stagedJournals = sendVersioned != null && school is String
        ? (await db.collection('_windows_drive_deliveries').get()).docs
            .map((row) => row.data())
            .where((row) => row['schoolId'] == school &&
                row['handoffAuthorized'] == true && row['state'] == 'pending')
            .toList()
        : <Map<String,dynamic>>[];
    unchanged();
    Object? firstDeferred;
    Future<void> process(QueryDocumentSnapshot<Map<String, dynamic>> queued) async {
      unchanged();
      queued.reference.requireOriginProfile();
      if (onlyQueueId != null && queued.id != onlyQueueId) return;
      if (canAdmit?.call() == false) return;
      var item = queued.data();
      // Cloudflare owns this immutable original. The device never submits a
      // second mutation merely to poll Google Drive; the receipt journal can
      // settle it when the authenticated provider proof eventually arrives.
      if(item['syncState']=='cloudAccepted')return;
      if(item['priorCloudWrite']!=null)return; // Existing receipt owner releases predecessor.
      if (school is String && sendVersioned != null) {
        final bound = stagedJournals.where((journal) =>
            recoverableStagedRecordJournal(item,journal,school) ||
            recoverableStagedPhotoJournal(item,journal,school)).toList();
        if (bound.isNotEmpty) {
          final identities = bound.map((row) => row['ticketId']).toSet();
          if (identities.length != 1)
            throw StateError('Multiple staged operation identities retained for review.');
          final journal=bound.first;
          final saved = await db.recordOutboxCloudHandoff(queued.reference,
              item,ticketId:identities.single as String,
              lane:journal['lane'] as String,
              mediaSourceHash:journal['mediaSourceHash'] as String?,
              mediaFileSha256:journal['fileSha256'] as String?);
          unchanged();
          if (saved) report('cloudflareAccepted',queued.id,item);
          // A failed CAS means an edit or another recovery owner won. Never
          // send the stale snapshot after observing an authenticated ticket.
          return;
        }
      }
      // This exact original operation belongs to the isolated atomic
      // Person/Card recovery owner. Never issue a second independent upload.
      if(item['atomicBundleId']!=null) {
        if(item['atomicBundleId'] is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(item['atomicBundleId']) ||
            !{'reserved','committed'}.contains(item['atomicState']) ||
            item['schoolId']!=db.activeProfileIdentity['schoolSyncId'])
          throw StateError('Atomic outbox reservation requires school review.');
        return;
      }
      if (sendVersioned != null &&
          item['schoolId'] != null &&
          item['schoolId'] != db.activeProfileIdentity['schoolSyncId']) {
        report('needsAttention', queued.id, item, category: 'configuration');
        throw StateError(
          'Pending operation belongs to another school; original binding retained.',
        );
      }
      if (onlyOperationId != null && item['operationId'] != onlyOperationId)
        return;
      // A manual Sync Now can bypass a local transport backoff, but cannot
      // override a provider quota minimum. Keep the immutable pending request
      // until the saved deadline even when the caller disables normal backoff.
      if ((respectBackoff || item['failureCategory'] == 'quota') &&
          !pendingRecordBackoffDue(
            item,
            DateTime.now(),
            explicitRetry: onlyOperationId != null,
          ))
        return;
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
        return;
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
          return; // A newer durable edit owns this row now.
        item = migrated;
      }
      // Older clients called every filesystem error a missing attachment.
      // Text notices have no attachment. Reopen once, preserving the exact
      // immutable operation, revision and prepared wire request for server CAS.
      if(item['syncState']=='needsAttention'&&item['failureCategory']=='fileMissing'&&
          textOnlyNoticeRequest(item)&&(item['retryCount'] as num? ?? 0)<automaticRecordRetryLimit&&
          item['schoolId']==db.activeProfileIdentity['schoolSyncId']&&
          item['operationId'] is String&&RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(item['operationId'])&&
          item['baseCloudRevision'] is String) {
        final journal=db.collection('_windows_sync_status').doc('repair-${item['operationId']}');
        final prior=(await journal.get()).data();unchanged();
        if(prior==null||prior['schoolId']==item['schoolId']&&prior['operationId']==item['operationId']) {
          if(prior?['noticeFileClassificationVersion']!=1) {
            await journal.set({'schoolId':item['schoolId'],'operationId':item['operationId'],
              'noticeFileClassificationVersion':1,'originalFailureCategory':'fileMissing'},const SetOptions(merge:true));
            unchanged();
            final admitted=await db.recordOutboxFailure(queued.reference,item,state:'retry',
              failureCategory:'localStorage',retryAtMillis:DateTime.now().millisecondsSinceEpoch,
              error:'Text notice has no local attachment. Original request retained for bounded storage retry.',
              diagnostic:{'failureStage':'recordRequestAndAck','failureCode':'RECORD_LOCAL_STORAGE_IO'});
            unchanged();
            if(!admitted)return;
            final current=(await queued.reference.get()).data();unchanged();
            if(current==null||current['operationId']!=item['operationId'])return;
            item=current;
            report('automaticRepair',queued.id,item,category:'localStorage');
          }
        }
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
        if (!repaired) return;
        final current = (await queued.reference.get()).data();
        unchanged();
        if (current == null || current['operationId'] != item['operationId'])
          return;
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
        return;
      if (canAdmit?.call() == false) return;
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
            // Nested deletes must complete before a replacement is admitted.
            // This local transport hint is not part of the original CAS record.
            final deletedRevision = await sendVersioned({
              ...deletion, 'requireCanonicalDeleteReceipt': true,
            });
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
              return;
            item = current;
            if (item['priorDeletion'] != null)
              throw StateError('Deletion acknowledgement not durable.');
          }
          if (prepareVersioned != null && item['operation'] != 'delete') {
            final bound = await prepareVersioned(queued.reference, item);
            unchanged();
            if (bound == null) return;
            item = bound;
          }
          // Preparation can await a point read or local wire-data binding.
          // Recheck admission before starting a new network mutation.
          unchanged();
          if (canAdmit?.call() == false) return;
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
      } on CloudflareRecordHandoff catch (accepted) {
        unchanged();
        if(item['schoolId']!=accepted.school||
            item['collection']!=accepted.collection||
            item['documentId']!=accepted.id||
            item['operationId']!=accepted.operationId) {
          throw StateError('Cloudflare handoff changed original operation identity.');
        }
        final saved=await db.recordOutboxCloudHandoff(
          queued.reference,item,ticketId:accepted.ticketId,
          lane:accepted.lane,
          mediaSourceHash:accepted.mediaSourceHash,
          mediaFileSha256:accepted.mediaFileSha256);
        unchanged();
        watch.stop();
        if(saved)report('cloudflareAccepted',queued.id,item,
            elapsedMicros:watch.elapsedMicroseconds);
        return; // No canonical revision / no outbox deletion.
      } catch (caught, stack) {
        unchanged();
        final e = caught is FileSystemException && caught is! PendingDocumentFileFailure &&
            collection!='documents' ? RecordLocalStorageFailure(caught) : caught;
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
          failureCode: code,
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
          return; // Independent rows must not be starved by a conflict.
        }
        Error.throwWithStackTrace(e,stack);
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
    // A bounded window is drained before newer or dependent operations are
    // admitted. The existing CAS, receipt journal, and row retry paths remain
    // the sole ACK owners. A fatal error drains in-flight work and stops admission.
    // Never parallelize attendance/expenses while a person lifecycle, atomic
    // reservation, delete or foreign/unbound record is unresolved locally.
    // The Worker still independently enforces its resource barriers.
    final scopedRows=docs.map((row)=>row.data()).toList(growable:false);
    final dependentBarrier = docs.any((row) {
      final item = row.data();
      return item['schoolId'] != school ||
          item['atomicBundleId'] != null ||
          item['operation'] == 'delete' ||
          item['priorDeletion'] != null || item['priorCloudWrite']!=null ||
          ({'students_directory','teachers_directory'}.contains(item['collection']) &&
            !independentExistingPersonPatch(item)) ||
          {'school_config',
            'school_settings','fee_payments','fee_ledger','teacher_salary',
            'documents'}.contains(item['collection']);
    });
    var offset = 0;
    while (offset < docs.length) {
      unchanged();
      if (canAdmit?.call() == false) break;
      final first = docs[offset++];
      bool independent(QueryDocumentSnapshot<Map<String, dynamic>> row) =>
          sendVersioned != null && onlyQueueId == null &&
          onlyOperationId == null &&
          (!dependentBarrier ||
            (school is String &&
             (canStageExpensePastUnrelatedOwners(row.data(),scopedRows,school) ||
              canStageAttendancePastUnrelatedOwners(row.data(),scopedRows,school))) ||
            (!parallelAttendanceExpenseCollections.contains(row.data()['collection']) &&
             !independentExistingPersonPatch(row.data()))) &&
          (parallelAdmission?.call(row.data()) ?? false);
      if (!independent(first)) {
        await process(first);
        continue;
      }
      final window = [first];
      final keys = <String>{};
      String key(QueryDocumentSnapshot<Map<String, dynamic>> row) {
        final data = row.data();
        return "${data['collection']}/${data['documentId']}";
      }
      keys.add(key(first));
      while (offset < docs.length && window.length < 3 &&
          canAdmit?.call() != false && independent(docs[offset]) &&
          keys.add(key(docs[offset]))) {
        window.add(docs[offset++]);
      }
      await Future.wait<void>(window.map(process), eagerError: false);
    }
    final deferred = firstDeferred;
    if (deferred != null) throw deferred;
  }
}
