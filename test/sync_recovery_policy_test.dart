import 'package:flutter_test/flutter_test.dart';
import '../lib/sync_recovery_policy.dart';
import '../lib/windows_sync_recovery.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import 'dart:async';

void main() {
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
