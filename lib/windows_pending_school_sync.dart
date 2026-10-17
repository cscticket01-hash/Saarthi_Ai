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
    bool Function()? canAdmit,
    String? onlyQueueId,
    String? onlyOperationId,
    bool respectBackoff = false,
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
      if(collection=='students_directory')return -1;
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
      if (item['syncState'] == 'conflict' ||
          item['syncState'] == 'needsAttention')
        continue;
      if (canAdmit?.call() == false) break;
      String? revision;
      final watch = Stopwatch()..start();
      report('cloudRequest', queued.id, item);
      try {
        if (sendVersioned != null) {
          final prior = item['priorDeletion'];
          if (prior is Map) {
            if (prior['schoolId'] != item['schoolId'] || prior['collection'] != collection ||
                prior['documentId'] != id || prior['operation'] != 'delete' ||
                prior['operationId'] is! String || prior['baseCloudRevision'] is! String) {
              throw StateError('Original same-school deletion dependency required.');
            }
            final deletion = Map<String,dynamic>.from(prior);
            final deletedRevision = await sendVersioned(deletion);
            unchanged();
            if (deletedRevision.trim().isEmpty) throw const MissingSyncAcknowledgement();
            await db.acknowledgeOutbox(queued.reference,deletion,revision:deletedRevision);
            final current = (await queued.reference.get()).data();
            unchanged();
            if (current == null || current['operationId'] != item['operationId']) continue;
            item = current;
            if (item['priorDeletion'] != null) throw StateError('Deletion acknowledgement not durable.');
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
        );
        if (decision.independentRecords || recordConflict ||
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
      await db.acknowledgeOutbox(queued.reference, item, revision: revision);
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
