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
  if (requestMicros > 0 && requestMicros <= 2000000) {
    return (bounded + 1).clamp(2, 10).toInt();
  }
  return bounded;
}

/// Deterministic recovery decisions. A decision never deletes or acknowledges data.
class SyncRecoveryDecision {
  const SyncRecoveryDecision(
    this.kind, {
    this.retry = false,
    this.review = false,
    this.independentRecords = false,
    this.timeoutStage = SyncTimeoutStage.unknown,
  });
  final SyncFailureKind kind;
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
    SyncFailureKind.fileMissing => 'Pending file could not be read. Restore access to the original file before retrying.',
    SyncFailureKind.unknown =>
      'Sync needs diagnosis. Pending data is retained.',
  };
  Duration delay(int attempts, {double? jitter}) => schoolRetryDelay(
    attempts,
    jitter: jitter,
    quota: kind == SyncFailureKind.quota,
  );

  static SyncRecoveryDecision classify({
    int? status,
    String code = '',
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
