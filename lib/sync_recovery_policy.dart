import 'school_backend_transport.dart';

enum SyncFailureKind { networkPath, timeout, server, quota, authorization, configuration, conflict, unknown }

bool syncCheckpointDue(DateTime? lastVerified, DateTime now) => lastVerified == null ||
    lastVerified.isAfter(now) || now.difference(lastVerified) >= const Duration(hours: 1);

/// Deterministic recovery decisions. A decision never deletes or acknowledges data.
class SyncRecoveryDecision {
  const SyncRecoveryDecision(this.kind, {this.retry = false, this.review = false, this.independentRecords = false});
  final SyncFailureKind kind;
  final bool retry, review, independentRecords;
  String get message => switch (kind) {
    SyncFailureKind.networkPath => 'Cannot reach the school server. Local data remains available.',
    SyncFailureKind.timeout => 'School server response timed out. Pending data is retained.',
    SyncFailureKind.server => 'School server could not complete sync. Automatic recovery will retry.',
    SyncFailureKind.quota => 'School cloud request limit reached. Recovery is waiting before retrying.',
    SyncFailureKind.authorization => 'School authorization needs verification. Pending data is retained.',
    SyncFailureKind.configuration => 'School storage configuration needs administrator attention.',
    SyncFailureKind.conflict => 'Versions conflict. Administrator review is required; both copies are retained.',
    SyncFailureKind.unknown => 'Sync needs diagnosis. Pending data is retained.',
  };
  Duration delay(int attempts, {double? jitter}) => schoolRetryDelay(attempts,
      jitter: jitter, quota: kind == SyncFailureKind.quota);

  static SyncRecoveryDecision classify({int? status, String code = '', bool timedOut = false,
      bool networkPathFailed = false, bool recordConflict = false}) {
    if (recordConflict || code.contains('REVISION_CONFLICT') || code == 'OPERATION_ID_CONFLICT') {
      return const SyncRecoveryDecision(SyncFailureKind.conflict, review: true, independentRecords: true);
    }
    if (status == 401 || status == 403 || code == 'SCRIPT_PERMISSION_DENIED') {
      return const SyncRecoveryDecision(SyncFailureKind.authorization, review: true);
    }
    if ({'SCRIPT_IDENTITY_MISMATCH', 'SCRIPT_WORKBOOK_IDENTITY_MISMATCH',
      'SCRIPT_TYPE_ERROR', 'SCRIPT_PARSE_ERROR', 'SCRIPT_DOCUMENT_REVISION_REQUIRED', 'SCRIPT_MIGRATION_CONFLICT', 'SCRIPT_MISSING_MIGRATED_TAB',
      'SCRIPT_RECORD_VERIFY_FAILED', 'SCRIPT_STORAGE_NOT_PREPARED', 'SCRIPT_WORKBOOK_REVIEW_REQUIRED',
      'SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED', 'SCHOOL_STORAGE_NOT_CONNECTED',
      'TEST_ENVIRONMENT_MISMATCH'}.contains(code)) {
      return SyncRecoveryDecision(SyncFailureKind.configuration, review: true,
        independentRecords: {'SCRIPT_RECORD_VERIFY_FAILED', 'SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED'}.contains(code));
    }
    if (status == 409) return const SyncRecoveryDecision(SyncFailureKind.conflict, review: true, independentRecords: true);
    if (status == 429 || code == 'SCRIPT_QUOTA_EXCEEDED') {
      return const SyncRecoveryDecision(SyncFailureKind.quota, retry: true);
    }
    if (timedOut || code == 'SCRIPT_TIMEOUT' || status == 504) {
      return const SyncRecoveryDecision(SyncFailureKind.timeout, retry: true);
    }
    if (networkPathFailed) return const SyncRecoveryDecision(SyncFailureKind.networkPath, retry: true);
    if (status == 502 || status == 503) return const SyncRecoveryDecision(SyncFailureKind.server, retry: true);
    return const SyncRecoveryDecision(SyncFailureKind.unknown);
  }
}
