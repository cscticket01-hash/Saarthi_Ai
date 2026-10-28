// Dependency-free regression checks: no Flutter bootstrap, network or packages.
import '../../lib/sync_recovery_policy.dart';
import '../../lib/cloud_transfer_status.dart';
void check(bool value, String message) { if (!value) throw StateError(message); }
void main() {
  final now = DateTime.utc(2026, 10, 28);
  final short = now.add(const Duration(seconds: 5));
  final long = now.add(const Duration(minutes: 5));
  check(syncRetryDeadline(now: now, previous: short, delay: const Duration(minutes: 2)) == now.add(const Duration(minutes: 2)), 'Older timer shortened provider wait');
  check(syncRetryDeadline(now: now, previous: long, delay: const Duration(minutes: 2)) == long, 'Longer existing deadline lost');
  check(syncRetryDeadline(now: now, previous: now.subtract(const Duration(seconds: 5)), delay: const Duration(minutes: 2)) == now.add(const Duration(minutes: 2)), 'Expired timer retained');
  final row = <String, dynamic>{'version': 1, 'schoolId': 'own', 'observedAtMillis': now.millisecondsSinceEpoch, 'retryAtMillis': long.millisecondsSinceEpoch};
  check(restoredProviderDeadline(row, 'own', now)?.isAtSameMomentAs(long) == true, 'Restart lost deadline');
  check(restoredProviderDeadline(row, 'foreign', now) == null, 'Foreign school gate applied');
  check(restoredProviderDeadline(row, 'own', long) == null, 'Expired gate restored');
  check(restoredProviderDeadline({...row, 'observedAtMillis': now.add(const Duration(minutes: 1)).millisecondsSinceEpoch}, 'own', now) == null, 'Future observation accepted');
  check(restoredProviderDeadline({...row, 'retryAtMillis': now.add(const Duration(days: 2)).millisecondsSinceEpoch}, 'own', now) == null, 'Unbounded deadline accepted');
  for (final code in ['SCRIPT_QUOTA_EXCEEDED', 'CLOUDFLARE_QUOTA_EXCEEDED', 'FIREBASE_QUOTA_EXCEEDED']) {
    final decision = SyncRecoveryDecision.classify(status: 429, code: code, retryAfterMs: 120000);
    check(decision.retry && decision.kind == SyncFailureKind.quota && decision.delay(1, jitter: 0) == const Duration(minutes: 2), 'Provider wait not honored');
  }
  check(SyncRecoveryDecision.classify(status: 403).review, 'Access denial bypassed');
  check(SyncRecoveryDecision.classify(status: 409).review, 'Conflict bypassed');
  check(cloudTransferMessage({'unavailable': true})?.contains('unavailable') == true, 'First status failure hidden');
  check(cloudTransferMessage({'enabled': true})?.contains('not verified') == true, 'Incomplete status falsely cleared');
  final good = <String, dynamic>{'enabled': true, 'notices': {'pending': 0, 'needsAttention': 0}, 'delivery': {'pendingPartitions': 0}};
  check(cloudTransferMessage(good) == null, 'Completed status not cleared');
  check(cloudTransferMessage({...good, 'notices': {'pending': 1, 'needsAttention': 0}})?.contains('pending') == true, 'Pending transfer hidden');
  check(cloudTransferMessage({...good, 'notices': {'pending': 0, 'needsAttention': 2}})?.contains('review') == true, 'Unresolved error hidden');
  check(cloudTransferMessage({'enabled': false}) == null, 'Disabled lane shown');
  print('PASS: retry deadlines, restart/school isolation, quota delays, conflicts and transfer-status recovery');
}
