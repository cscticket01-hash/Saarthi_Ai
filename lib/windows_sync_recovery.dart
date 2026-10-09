import 'dart:async';
import 'dart:io';
import 'school_backend_transport.dart';
import 'sync_recovery_policy.dart';
import 'windows_connect/central_school_cloud.dart';

SyncRecoveryDecision windowsSyncRecovery(Object error) {
  if (error is CentralCloudException) return SyncRecoveryDecision.classify(
    status: error.status, code: error.diagnosticCode, recordConflict: error.recordConflict);
  if (error is SchoolApiFailure) return SyncRecoveryDecision.classify(status: error.status, code: error.code);
  if (error is TimeoutException) return SyncRecoveryDecision.classify(timedOut: true);
  if (error is SocketException || error is HttpException) return SyncRecoveryDecision.classify(networkPathFailed: true);
  // Only existing fixed client messages are recognized. Raw text is never exported.
  if (error is StateError && RegExp(r'record revision conflict|sync operation id conflict|items need conflict review',
      caseSensitive: false).hasMatch(error.toString())) {
    return SyncRecoveryDecision.classify(recordConflict: true);
  }
  return SyncRecoveryDecision.classify();
}
