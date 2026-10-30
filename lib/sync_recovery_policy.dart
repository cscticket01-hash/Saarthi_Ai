import 'school_backend_transport.dart';

enum SyncFailureKind {
  networkPath,
  timeout,
  server,
  quota,
  authorization,
  configuration,
  conflict,
  validation,
  fileMissing,
  localStorage,
  unknown,
}

enum SyncTimeoutStage { unknown, responseHeaders, responseBody }

bool syncCheckpointDue(DateTime? lastVerified, DateTime now) =>
    lastVerified == null ||
    lastVerified.isAfter(now) ||
    now.difference(lastVerified) >= const Duration(hours: 1);

/// Transport window only: never changes retries, dependencies or ACK authority.
/// Slow/partial requests reduce pressure; only a complete fast response grows.
int managedBatchWindow({
  required int current,
  required int requestMicros,
  required bool complete,
}) {
  final bounded = current.clamp(2, 10).toInt();
  if (!complete || requestMicros >= 8000000) {
    return (bounded ~/ 2).clamp(2, 10).toInt();
  }
  if (requestMicros >= 5000000) return (bounded - 1).clamp(2, 10).toInt();
  if (requestMicros > 0 && requestMicros <= 2000000) {
    return (bounded + 1).clamp(2, 10).toInt();
  }
  return bounded;
}

/// A newer provider minimum must never be shortened by an older retry timer.
DateTime syncRetryDeadline({required DateTime now, required Duration delay, DateTime? previous}) {
  final requiredAt = now.add(delay);
  return previous != null && previous.isAfter(requiredAt) ? previous : requiredAt;
}

/// Only same-school, bounded local quota evidence can close admission.
DateTime? restoredProviderDeadline(Map<String, dynamic>? row, String school, DateTime now) {
  final start = row?['observedAtMillis'], end = row?['retryAtMillis'];
  if (row?['schoolId'] != school || row?['version'] != 1 ||
      start is! int || end is! int || start > now.millisecondsSinceEpoch ||
      end <= start || end - start > const Duration(days: 1).inMilliseconds ||
      end <= now.millisecondsSinceEpoch) return null;
  return DateTime.fromMillisecondsSinceEpoch(end);
}

/// Deterministic recovery decisions. A decision never deletes or acknowledges data.
class SyncRecoveryDecision {
  const SyncRecoveryDecision(
    this.kind, {
    this.retry = false,
    this.retryAfterMs = 0,
    this.review = false,
    this.independentRecords = false,
    this.timeoutStage = SyncTimeoutStage.unknown,
  });
  final SyncFailureKind kind;
  final int retryAfterMs;
  final bool retry, review, independentRecords;
  // Fixed local diagnostic metadata; never changes retry/ACK authority.
  final SyncTimeoutStage timeoutStage;
  String get message => switch (kind) {
    SyncFailureKind.networkPath =>
      'Cannot reach the school server. Local data remains available.',
    SyncFailureKind.timeout =>
      'School server response timed out. Pending data is retained.',
    SyncFailureKind.server =>
      'School server could not complete sync. Automatic recovery will retry.',
    SyncFailureKind.quota => 'School cloud request limit reached. Recovery is waiting before retrying.',
    SyncFailureKind.authorization =>
      'School authorization needs verification. Pending data is retained.',
    SyncFailureKind.configuration =>
      'School storage configuration needs administrator attention.',
    SyncFailureKind.conflict => 'Versions conflict. Administrator review is required; both copies are retained.',
    SyncFailureKind.validation => 'Invalid pending data. Correct the record before retrying.',
    SyncFailureKind.localStorage => 'Local storage or credentials could not be accessed. Pending data is retained; retry is bounded.',
    SyncFailureKind.fileMissing => 'Pending file could not be read. Restore access to the original file before retrying.',
    SyncFailureKind.unknown =>
      'Sync needs diagnosis. Pending data is retained.',
  };
  Duration delay(int attempts, {double? jitter}) {
    final local = schoolRetryDelay(
      attempts,
      jitter: jitter,
      quota: kind == SyncFailureKind.quota,
    );
    final minimum = Duration(milliseconds: retryAfterMs.clamp(0, 86400000).toInt());
    return local < minimum ? minimum : local;
  }

  static SyncRecoveryDecision classify({
    int? status,
    String code = '',
    int retryAfterMs = 0,
    bool timedOut = false,
    bool networkPathFailed = false,
    bool recordConflict = false,
  }) {
    if ({'FILE_MISSING','FILE_UNREADABLE'}.contains(code)) {
      return const SyncRecoveryDecision(SyncFailureKind.fileMissing, review:true, independentRecords:true);
    }
    if (recordConflict ||
        code.contains('REVISION_CONFLICT') ||
        code == 'OPERATION_ID_CONFLICT') {
      return const SyncRecoveryDecision(
        SyncFailureKind.conflict,
        review: true,
        independentRecords: true,
      );
    }
    if (status == 401 || status == 403 || code == 'SCRIPT_PERMISSION_DENIED') {
      return const SyncRecoveryDecision(
        SyncFailureKind.authorization,
        review: true,
      );
    }
    if (status == 429 || {'SCRIPT_QUOTA_EXCEEDED', 'CLOUDFLARE_QUOTA_EXCEEDED',
      'FIREBASE_QUOTA_EXCEEDED', 'RESOURCE_EXHAUSTED', 'resource-exhausted',
      'firestore/resource-exhausted'}.contains(code)) {
      return SyncRecoveryDecision(SyncFailureKind.quota, retry: true, retryAfterMs: retryAfterMs);
    }
    if ({
      'SCRIPT_SYNC_STATE_IDENTITY',
      'SCRIPT_SYNC_STATE_UNAVAILABLE',
      'SCRIPT_IDENTITY_MISMATCH',
      'SCRIPT_WORKBOOK_IDENTITY_MISMATCH',
      'SCRIPT_TYPE_ERROR',
      'SCRIPT_PARSE_ERROR',
      'SCRIPT_DOCUMENT_REVISION_REQUIRED',
      'SCRIPT_MIGRATION_CONFLICT',
      'SCRIPT_MISSING_MIGRATED_TAB',
      'SCRIPT_EXTERNAL_EDIT_REVIEW_REQUIRED',
      'SCRIPT_RECORD_VERIFY_FAILED',
      'SCRIPT_STORAGE_NOT_PREPARED',
      'SCRIPT_WORKBOOK_REVIEW_REQUIRED',
      'SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED',
      'SCHOOL_STORAGE_NOT_CONNECTED',
      'TEST_ENVIRONMENT_MISMATCH',
    }.contains(code)) {
      return SyncRecoveryDecision(
        SyncFailureKind.configuration,
        review: true,
        independentRecords: {
          'SCRIPT_EXTERNAL_EDIT_REVIEW_REQUIRED',
          'SCRIPT_RECORD_VERIFY_FAILED',
          'SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED',
        }.contains(code),
      );
    }
    if (status == 400 || status == 422 || {'BLANK_SCHOOL_PROFILE','SCRIPT_BLANK_SCHOOL_PROFILE','SCRIPT_INVALID_SYNC_OPERATION','SCRIPT_EMPTY_PROFILE_OVERWRITE'}.contains(code)) {
      return const SyncRecoveryDecision(SyncFailureKind.validation, review:true, independentRecords:true);
    }
    if (status == 409)
      return const SyncRecoveryDecision(
        SyncFailureKind.conflict,
        review: true,
        independentRecords: true,
      );
    if (status == 429 || code == 'SCRIPT_QUOTA_EXCEEDED') {
      return const SyncRecoveryDecision(SyncFailureKind.quota, retry: true);
    }
    if (timedOut || code == 'SCRIPT_TIMEOUT' || status == 504) {
      return const SyncRecoveryDecision(SyncFailureKind.timeout, retry: true);
    }
    if (networkPathFailed)
      return const SyncRecoveryDecision(
        SyncFailureKind.networkPath,
        retry: true,
      );
    if (status != null && status >= 500 && status <= 599)
      return const SyncRecoveryDecision(SyncFailureKind.server, retry: true);
    return const SyncRecoveryDecision(SyncFailureKind.unknown);
  }
}
