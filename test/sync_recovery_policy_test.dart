import 'package:flutter_test/flutter_test.dart';
import '../lib/sync_recovery_policy.dart';
import '../lib/windows_sync_recovery.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import 'dart:async';
import 'package:fake_async/fake_async.dart';
import '../lib/windows_sync_schedule.dart';

void main() {
  test('notice delete after wrapped card conflict dispatches automatically; idle and shared failures do not', () {
    fakeAsync((clock) {
      var runs = 0;
      final dispatch = WindowsSyncDispatch(() => runs++);
      final conflict = windowsSyncRecovery(IdCardPreparationFailure(PublishedIdInputConflict()));
      void deletedNotice(SyncRecoveryDecision decision) {
        if (canScheduleAfterSyncFailure(recovery: decision, localMutation: true,
            remoteWork: false, integrityDue: false)) {
          dispatch.request(const Duration(milliseconds: 250), localMutation: true);
        }
      }
      expect(canScheduleAfterSyncFailure(recovery: conflict, localMutation: false,
          remoteWork: false, integrityDue: false), false);
      // Three durable deletes coalesce into one automatic owner run, with no
      // manual Sync Now, hourly tick or retry of the conflicting card.
      for (var i = 0; i < 3; i++) deletedNotice(conflict);
      clock.elapse(const Duration(milliseconds: 249));
      expect(runs, 0);
      clock.elapse(const Duration(milliseconds: 1));
      expect(runs, 1);
      clock.elapse(const Duration(minutes: 1));
      expect(runs, 1);
      for (final decision in [
        windowsSyncRecovery(IdCardPreparationFailure(CentralCloudException(403, 'school_cloud', 'denied'))),
        SyncRecoveryDecision.classify(code: 'SCRIPT_WORKBOOK_IDENTITY_MISMATCH'),
        windowsSyncRecovery(IdCardPreparationFailure(StateError('Unknown failure'))),
      ]) deletedNotice(decision);
      clock.elapse(const Duration(seconds: 1));
      expect(runs, 1);
      dispatch.cancel();
    });
  });
  test('card input conflict survives preparation wrapping without blocking independent notice mutations', () {
    final conflict = PublishedIdInputConflict();
    final wrapped = IdCardPreparationFailure(conflict);
    final decision = windowsSyncRecovery(wrapped);
    expect(identical(wrapped.cause, conflict), true);
    expect(decision.kind, SyncFailureKind.conflict);
    expect(decision.review, true);
    expect(decision.retry, false, reason: 'Never repeatedly regenerate or overwrite the published card');
    expect(decision.independentRecords, true, reason: 'Fresh notice deletes must remain automatically admissible');
    expect(independentDocumentFailure(wrapped), true);
    expect(wrapped.toString(), contains('no new PDF was saved'));
  });
  test('preparation wrapper preserves shared access, quota and unknown failure guards', () {
    for (final error in <Object>[
      CentralCloudException(403, 'school_cloud', 'denied'),
      CentralCloudException(429, 'school_cloud', 'quota'),
      StateError('Unknown preparation failure'),
      StateError('Published ID already exists with different inputs'),
    ]) {
      final before = windowsSyncRecovery(error);
      final after = windowsSyncRecovery(IdCardPreparationFailure(error));
      expect(after.kind, before.kind);
      expect(after.retry, before.retry);
      expect(after.independentRecords, false);
    }
  });
  test('fixed timeout stages survive owner diagnosis without changing retry authority', () {
    for (final stage in CentralTimeoutStage.values) {
      final decision = windowsSyncRecovery(CentralRequestTimeout(stage));
      expect(decision.kind, SyncFailureKind.timeout);
      expect(decision.retry, true);
      expect(decision.review, false);
      expect(decision.timeoutStage.name, stage.name);
      expect(decision.delay(1, jitter: 0), const Duration(seconds: 5));
    }
    expect(windowsSyncRecovery(TimeoutException('private owner details')).timeoutStage,
        SyncTimeoutStage.unknown);
    expect(SyncRecoveryDecision.classify(status: 504).timeoutStage, SyncTimeoutStage.unknown);
  });
  test('hourly checkpoint becomes due on missed sleep interval and clock rollback', () {
    final start = DateTime.utc(2026, 10, 9, 10);
    expect(syncCheckpointDue(null, start), true);
    expect(syncCheckpointDue(start, start.add(const Duration(minutes: 59))), false);
    expect(syncCheckpointDue(start, start.add(const Duration(hours: 1))), true);
    expect(syncCheckpointDue(start, start.add(const Duration(hours: 8))), true);
    expect(syncCheckpointDue(start, start.subtract(const Duration(minutes: 1))), true);
  });
  test('server outage and timeout are distinct from a failed network path', () {
    final server = SyncRecoveryDecision.classify(status: 502, code: 'SCRIPT_OPERATION_FAILED');
    expect(server.kind, SyncFailureKind.server);
    expect(server.retry, true);
    expect(SyncRecoveryDecision.classify(status: 502, code: 'SCRIPT_MIGRATION_PENDING').retry, true);
    expect(server.message.toLowerCase(), isNot(contains('no internet')));
    expect(SyncRecoveryDecision.classify(timedOut: true).kind, SyncFailureKind.timeout);
    expect(SyncRecoveryDecision.classify(networkPathFailed: true).kind, SyncFailureKind.networkPath);
  });
  test('configuration, authorization and financial conflicts never auto overwrite', () {
    for (final code in ['SCRIPT_PERMISSION_DENIED', 'SCRIPT_WORKBOOK_IDENTITY_MISMATCH',
      'SCRIPT_DOCUMENT_REVISION_CONFLICT', 'SCRIPT_RECORD_VERIFY_FAILED', 'SCRIPT_TYPE_ERROR']) {
      final decision = SyncRecoveryDecision.classify(status: 502, code: code);
      expect(decision.retry, false, reason: code);
      expect(decision.review, true, reason: code);
    }
    expect(SyncRecoveryDecision.classify(status: 409).kind, SyncFailureKind.conflict);
    expect(SyncRecoveryDecision.classify(status: 403).kind, SyncFailureKind.authorization);
    expect(SyncRecoveryDecision.classify(status: 409, code: 'SCHOOL_STORAGE_NOT_CONNECTED').kind, SyncFailureKind.configuration);
    expect(SyncRecoveryDecision.classify(status: 409).independentRecords, true);
    expect(SyncRecoveryDecision.classify(status: 403).independentRecords, false);
    expect(SyncRecoveryDecision.classify(status: 502, code: 'SCRIPT_WORKBOOK_IDENTITY_MISMATCH').independentRecords, false);
    expect(SyncRecoveryDecision.classify().retry, false);
  });
  test('retry jitter stays bounded and quota recovery waits longer', () {
    final normal = SyncRecoveryDecision.classify(status: 503);
    final quota = SyncRecoveryDecision.classify(status: 429);
    expect(normal.delay(1, jitter: 0), const Duration(seconds: 5));
    expect(normal.delay(1, jitter: 1), const Duration(milliseconds: 6250));
    expect(normal.delay(100, jitter: 1), const Duration(seconds: 300));
    expect(quota.delay(1, jitter: 0), const Duration(seconds: 60));
    expect(quota.delay(100, jitter: 1), const Duration(seconds: 900));
  });
  test('adaptive transport contracts under slow/partial responses and grows only on complete fast evidence', () {
    var limit = 10;
    for (var i = 0; i < 8; i++) {
      limit = managedBatchWindow(current: limit, requestMicros: 9000000, complete: true);
    }
    expect(limit, 2);
    expect(managedBatchWindow(current: 10, requestMicros: 500000, complete: false), 5);
    expect(managedBatchWindow(current: 4, requestMicros: 0, complete: true), 4);
    expect(managedBatchWindow(current: 4, requestMicros: 4000000, complete: true), 4);
    for (var i = 0; i < 20; i++) {
      limit = managedBatchWindow(current: limit, requestMicros: 500000, complete: true);
    }
    expect(limit, 10);
  });

}
