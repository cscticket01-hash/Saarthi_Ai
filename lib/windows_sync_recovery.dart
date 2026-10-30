import 'package:http/http.dart' as http;
import 'school_profile_policy.dart';
import 'dart:async';
import 'dart:io';

import 'school_backend_transport.dart';
import 'sync_recovery_policy.dart';
import 'windows_connect/central_school_cloud.dart';

/// This verified publication conflict belongs to one card, not school access.
/// The existing published PDF must remain protected while other records sync.
class PublishedIdInputConflict extends StateError {
  PublishedIdInputConflict({this.schoolId, this.documentId, this.ownerRole,
    this.personId, this.personDocId, this.inputRevision, this.cloudRevision})
      : super('Published ID already exists with different inputs. '
            'Review the school-published card before replacing it; no new PDF was saved.');
  final String? schoolId, documentId, ownerRole, personId, personDocId, inputRevision, cloudRevision;
}

/// Preserve the original failure category across the document preparation stage.
class IdCardPreparationFailure extends StateError {
  IdCardPreparationFailure(this.cause)
      : super('ID card preparation incomplete: $cause');
  final Object cause;
}

/// A record request reads local database/credential files, not a document
/// attachment. Keep its I/O failure distinct from a missing upload original.
class RecordLocalStorageFailure implements Exception {
  const RecordLocalStorageFailure(this.cause);
  final FileSystemException cause;
  @override String toString() => 'Local record storage access failed. Original request retained.';
}

/// Only the known text-notice schema can repair the old fileMissing label.
/// A file-bearing record must keep its original missing-file protection.
bool textOnlyNoticeRequest(Map item) {
  if(item['collection']!='school_notices'||!{'set','update'}.contains(item['operation']))return false;
  bool text(Map data)=>data['title'] is String&&data['description'] is String&&
    data.keys.every((k)=>{'title','description','category','timestamp','lastEdited',
      'deliveryStatus','schoolId','id'}.contains(k)||k is String&&k.startsWith('_sync'))&&
    data.values.every((v)=>v==null||v is String||v is num||v is bool);
  return item['data'] is Map&&text(item['data'])&&
    (item['wireData']==null||item['wireMode']=='snapshot2'&&item['wireData'] is Map&&text(item['wireData']));
}

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

/// Fresh independent work can wake the owner after a record-local review.
/// Shared access/configuration failures still block all automatic admission.
bool canScheduleAfterSyncFailure({
  required SyncRecoveryDecision? recovery,
  required bool localMutation,
  required bool remoteWork,
  required bool integrityDue,
}) => recovery == null || recovery.retry ||
    recovery.independentRecords && (localMutation || remoteWork || integrityDue);

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
    'failureCode':error is RecordLocalStorageFailure ? 'RECORD_LOCAL_STORAGE_IO' : error is MissingSyncAcknowledgement ? 'ACK_UNVERIFIED' :
      error is CentralCloudException && const {
        'SCRIPT_DOCUMENT_REVISION_CONFLICT','RECORD_REVISION_CONFLICT',
        'OPERATION_ID_CONFLICT','SCRIPT_PERMISSION_DENIED','SCRIPT_QUOTA_EXCEEDED',
        'SCRIPT_TIMEOUT','SCRIPT_HTTP_ERROR','SCRIPT_IDENTITY_MISMATCH',
        'SCRIPT_EXTERNAL_EDIT_REVIEW_REQUIRED',
        'SCRIPT_RECORD_VERIFY_FAILED','SCRIPT_STORAGE_NOT_PREPARED',
        'SCHOOL_STORAGE_NOT_CONNECTED','SCRIPT_TRANSPORT_ERROR',
        'SCRIPT_RESPONSE_READ_FAILED','SCRIPT_OPERATION_FAILED',
        'SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED','SCRIPT_STUDENT_PARENT_PENDING',
        'SCRIPT_STUDENT_GENERATION_DELETED','SCRIPT_INVALID_SYNC_OPERATION',
        'SCRIPT_SHEET_RECOVERY_REQUIRED','SCRIPT_BLANK_SCHOOL_PROFILE',
        'SCRIPT_WORKBOOK_REVIEW_REQUIRED','SCRIPT_SYNC_STATE_UNAVAILABLE',
        'SCRIPT_SYNC_STATE_IDENTITY','STUDENT_SLOT_CONFLICT',
      }.contains(error.diagnosticCode) ? error.diagnosticCode : decision.kind.name,
    'failureHttpStatus':error is CentralCloudException ? error.status : null,
  };
}
const recoverablePendingCategories = {
  'localStorage',
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

/// A verified reconnect may reopen transport failures, never quota or review.
bool networkRecoveryCandidate(Map item) =>
    {'retry','needsAttention'}.contains(item['syncState']) &&
    {'networkPath','timeout'}.contains(item['failureCategory']);

SyncRecoveryDecision windowsSyncRecovery(Object error) {
  if (error is RecordLocalStorageFailure) return const SyncRecoveryDecision(
    SyncFailureKind.localStorage,retry:true);
  if (error is IdCardPreparationFailure) {
    return windowsSyncRecovery(error.cause);
  }
  if (error is PublishedIdInputConflict) {
    return SyncRecoveryDecision.classify(recordConflict: true);
  }
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
      retryAfterMs: error.retryAfterMs,
      recordConflict: error.recordConflict,
    );
  if (error is SchoolApiFailure)
    return SyncRecoveryDecision.classify(
      status: error.status,
      code: error.code,
      retryAfterMs: error.retryAfterMs,
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
