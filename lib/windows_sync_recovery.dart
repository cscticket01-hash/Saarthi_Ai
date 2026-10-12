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

const automaticRecordRetryLimit = 5;
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
