import 'dart:async';
import 'dart:io';

import 'school_backend_transport.dart';
import 'sync_recovery_policy.dart';
import 'windows_connect/central_school_cloud.dart';

SyncRecoveryDecision windowsSyncRecovery(Object error) {
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
  if (error is SocketException || error is HttpException)
    return SyncRecoveryDecision.classify(networkPathFailed: true);
  // Only existing fixed client messages are recognized. Raw text is never exported.
  if (error is StateError &&
      RegExp(
        r'record revision conflict|sync operation id conflict|items need conflict review',
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
