import 'package:http/http.dart' as http;
import 'school_profile_policy.dart';
import 'dart:async';
import 'dart:io';

import 'school_backend_transport.dart';
import 'sync_recovery_policy.dart';
import 'windows_connect/central_school_cloud.dart';

/// A successful transport response without a verified revision is not an ACK.
/// Retry retains the same operation ID so the server can return its prior receipt.
class MissingSyncAcknowledgement implements Exception {
  const MissingSyncAcknowledgement();
  @override
  String toString() =>
      'Verified cloud acknowledgement missing. Pending retained.';
}

class PendingSyncAttention implements Exception {
  const PendingSyncAttention(this.total, this.conflicts);
  final int total, conflicts;
  @override
  String toString() => '$total pending records need attention: '
      '$conflicts version conflicts, ${total - conflicts} other issues. '
      'Open full queue for each record\'s reason. Pending data retained.';
}

const automaticRecordRetryLimit = 5;

class PendingDocumentFileFailure extends FileSystemException {
  const PendingDocumentFileFailure() : super('Pending document file could not be read.');
}

/// Only a record-scoped failure may be deferred. Shared authentication,
/// identity, transport and quota failures still stop admission immediately.
bool independentDocumentFailure(Object error) =>
    error is MissingSyncAcknowledgement ||
    error is PendingDocumentFileFailure ||
    error is! FileSystemException &&
    windowsSyncRecovery(error).independentRecords;

Future<void> runDocumentAndDownloadStages({
  required Future<void> Function() documents,
  required Future<void> Function() download,
}) async {
  Object? retained;
  StackTrace? trace;
  try { await documents(); }
  catch (error, stack) {
    if (!independentDocumentFailure(error)) rethrow;
    retained = error; trace = stack;
  }
  await download();
  if (retained != null) Error.throwWithStackTrace(retained, trace!);
}

Map<String,dynamic> documentFailureDiagnostic(Object error, String stage) {
  final decision = windowsSyncRecovery(error);
  return {
    'failureStage':stage,
    'failureCode':error is MissingSyncAcknowledgement ? 'ACK_UNVERIFIED' :
      error is CentralCloudException && const {
        'SCRIPT_DOCUMENT_REVISION_CONFLICT','RECORD_REVISION_CONFLICT',
        'OPERATION_ID_CONFLICT','SCRIPT_PERMISSION_DENIED','SCRIPT_QUOTA_EXCEEDED',
        'SCRIPT_TIMEOUT','SCRIPT_HTTP_ERROR','SCRIPT_IDENTITY_MISMATCH',
        'SCRIPT_RECORD_VERIFY_FAILED','SCRIPT_STORAGE_NOT_PREPARED',
        'SCHOOL_STORAGE_NOT_CONNECTED','SCRIPT_TRANSPORT_ERROR',
        'SCRIPT_RESPONSE_READ_FAILED','SCRIPT_OPERATION_FAILED',
      }.contains(error.diagnosticCode) ? error.diagnosticCode : decision.kind.name,
    'failureHttpStatus':error is CentralCloudException ? error.status : null,
  };
}
const recoverablePendingCategories = {
  'networkPath',
  'timeout',
  'server',
  'quota',
};

/// Only diagnosed transport failures can be reopened automatically. Unknown,
/// authorization, configuration and real version conflicts require review.
bool recoverablePendingAttention(
  Map<String, dynamic> item, {
  bool explicitRetry = false,
}) =>
    item['syncState'] == 'needsAttention' &&
    recoverablePendingCategories.contains(item['failureCategory']) &&
    (explicitRetry ||
        (item['retryCount'] as num? ?? 0) < automaticRecordRetryLimit);

SyncRecoveryDecision windowsSyncRecovery(Object error) {
  if (error is PendingSyncAttention) {
    return SyncRecoveryDecision(
      error.conflicts > 0 ? SyncFailureKind.conflict : SyncFailureKind.unknown,
      review: true,
      independentRecords: true,
    );
  }
  if (error is BlankSchoolProfile) return SyncRecoveryDecision.classify(code:'BLANK_SCHOOL_PROFILE');
  if (error is FileSystemException || error is StateError && error.message == 'Pending document file is missing.') {
    return SyncRecoveryDecision.classify(code:'FILE_UNREADABLE');
  }
  if (error is StateError && {'Invalid document ID.', 'Document revision missing.', 'Valid school exact location required.'}.contains(error.message)) {
    return SyncRecoveryDecision.classify(status:422);
  }
  if (error is MissingSyncAcknowledgement) {
    return const SyncRecoveryDecision(SyncFailureKind.server, retry: true);
  }
  if (error is CentralCloudException)
    return SyncRecoveryDecision.classify(
      status: error.status,
      code: error.diagnosticCode,
      recordConflict: error.recordConflict,
    );
  if (error is SchoolApiFailure)
    return SyncRecoveryDecision.classify(
      status: error.status,
      code: error.code,
    );
  if (error is CentralRequestTimeout) {
    return SyncRecoveryDecision(SyncFailureKind.timeout, retry: true,
        timeoutStage: switch (error.stage) {
          CentralTimeoutStage.responseHeaders => SyncTimeoutStage.responseHeaders,
          CentralTimeoutStage.responseBody => SyncTimeoutStage.responseBody,
        });
  }
  if (error is TimeoutException)
    return SyncRecoveryDecision.classify(timedOut: true);
  if (error is SocketException || error is HttpException || error is http.ClientException)
    return SyncRecoveryDecision.classify(networkPathFailed: true);
  // Only existing fixed client messages are recognized. Raw text is never exported.
  if (error is StateError &&
      RegExp(
        r'record revision conflict|sync operation id conflict|items need conflict review|Newer cloud document retained; resolve version conflict',
        caseSensitive: false,
      ).hasMatch(error.toString())) {
    return SyncRecoveryDecision.classify(recordConflict: true);
  }
  return SyncRecoveryDecision.classify();
}

/// A delta checkpoint certifies the cloud revision, not the continued existence
/// of the local cache. Missing live IDs require a fresh authoritative read.
/// Explicit tombstones and queued edits/deletes are never treated as accidents.
String managedRecoveryRevision(
  Map<String, dynamic>? manifest,
  Set<String> localIds,
  Set<String> pendingIds,
) {
  final revision = manifest?['revision']?.toString() ?? '';
  final expected = manifest?['ids'];
  final deleted = (manifest?['deletedIds'] as List? ?? [])
      .whereType<String>()
      .toSet();
  if (expected is List &&
      expected.whereType<String>().any(
        (id) =>
            !deleted.contains(id) &&
            !pendingIds.contains(id) &&
            !localIds.contains(id),
      ))
    return '';
  return revision;
}
