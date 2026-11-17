import 'dart:math';

import 'platform/platform_config.dart';

/// Firebase administrator proof may be sent only to Google Apps Script hosts.
void requireSchoolBackendUri(Uri uri) {
  if (uri.scheme != 'https' || uri.userInfo.isNotEmpty ||
      !{'script.google.com', 'script.googleusercontent.com'}.contains(uri.host)) {
    throw StateError('Untrusted school backend or redirect was blocked.');
  }
}

void requireSchoolProjectId(String project) {
  if(project == platformProjectId || !RegExp(r'^[a-z][a-z0-9-]{4,61}[a-z0-9]$').hasMatch(project)) {
    throw StateError('Use this school’s separate Firebase project. The developer Firebase is only for website monitoring and licensing.');
  }
}

/// Safe, typed transport evidence. Never includes raw server response text.
class SchoolApiFailure implements Exception {
  SchoolApiFailure(this.status, {String code = '', String requestId = '', int retryAfterMs = 0})
      : retryAfterMs = retryAfterMs > 0 ? retryAfterMs :
          (({503, 507}.contains(status) && code == 'R2_CAPACITY_EXCEEDED') ? 3600000 : 0),
        code = RegExp(r'^[A-Z_]{1,80}      !{'SCRIPT_TYPE_ERROR', 'SCRIPT_PARSE_ERROR', 'SCRIPT_DOCUMENT_REVISION_REQUIRED',
        'SCRIPT_IDENTITY_MISMATCH', 'SCRIPT_MIGRATION_CONFLICT', 'SCRIPT_MISSING_MIGRATED_TAB',
        'SCRIPT_RECORD_VERIFY_FAILED', 'SCRIPT_STORAGE_NOT_PREPARED',
        'SCRIPT_WORKBOOK_IDENTITY_MISMATCH', 'SCRIPT_DOCUMENT_REVISION_CONFLICT',
        'SCRIPT_WORKBOOK_REVIEW_REQUIRED', 'SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED',
        'SCRIPT_PERMISSION_DENIED'}.contains(code);
  String get userMessage => storageFull
      ? 'Cloudflare school storage reached the 8 GB limit. Local pending data is safe; automatic retry will resume when space is available.'
      : code.startsWith('SCRIPT_')
      ? 'School Google storage could not complete the request. Cached data is retained; contact the school if this continues.'
      : 'School server is temporarily unavailable (HTTP $status). Cached data is retained.';
  @override
  String toString() => '$userMessage${code.isEmpty ? '' : ' [$code]'}';
}

Duration schoolRetryDelay(int failures, {double? jitter, bool quota = false}) {
  final base = ((quota ? 60 : 5) * (1 << (failures - 1).clamp(0, 6).toInt()));
  final cap = quota ? 900 : 300;
  return Duration(milliseconds: (base * 1000 * (1 + (jitter ?? Random().nextDouble()).clamp(0, 1) * .25)).clamp(5000, cap * 1000).toInt());
}).hasMatch(code) ? code : '',
        requestId = RegExp(r'^[a-f0-9-]{36}      !{'SCRIPT_TYPE_ERROR', 'SCRIPT_PARSE_ERROR', 'SCRIPT_DOCUMENT_REVISION_REQUIRED',
        'SCRIPT_IDENTITY_MISMATCH', 'SCRIPT_MIGRATION_CONFLICT', 'SCRIPT_MISSING_MIGRATED_TAB',
        'SCRIPT_RECORD_VERIFY_FAILED', 'SCRIPT_STORAGE_NOT_PREPARED',
        'SCRIPT_WORKBOOK_IDENTITY_MISMATCH', 'SCRIPT_DOCUMENT_REVISION_CONFLICT',
        'SCRIPT_WORKBOOK_REVIEW_REQUIRED', 'SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED',
        'SCRIPT_PERMISSION_DENIED'}.contains(code);
  String get userMessage => code.startsWith('SCRIPT_')
      ? 'School Google storage could not complete the request. Cached data is retained; contact the school if this continues.'
      : 'School server is temporarily unavailable (HTTP $status). Cached data is retained.';
  @override
  String toString() => '$userMessage${code.isEmpty ? '' : ' [$code]'}';
}

Duration schoolRetryDelay(int failures, {double? jitter, bool quota = false}) {
  final base = ((quota ? 60 : 5) * (1 << (failures - 1).clamp(0, 6).toInt()));
  final cap = quota ? 900 : 300;
  return Duration(milliseconds: (base * 1000 * (1 + (jitter ?? Random().nextDouble()).clamp(0, 1) * .25)).clamp(5000, cap * 1000).toInt());
}).hasMatch(requestId) ? requestId : '';
  final int status;
  final int retryAfterMs;
  final String code, requestId;
  bool get storageFull => {503, 507}.contains(status) && code == 'R2_CAPACITY_EXCEEDED';
  bool get retryable => storageFull || ({429, 502, 503, 504}.contains(status) &&
      !{'SCRIPT_TYPE_ERROR', 'SCRIPT_PARSE_ERROR', 'SCRIPT_DOCUMENT_REVISION_REQUIRED',
        'SCRIPT_IDENTITY_MISMATCH', 'SCRIPT_MIGRATION_CONFLICT', 'SCRIPT_MISSING_MIGRATED_TAB',
        'SCRIPT_RECORD_VERIFY_FAILED', 'SCRIPT_STORAGE_NOT_PREPARED',
        'SCRIPT_WORKBOOK_IDENTITY_MISMATCH', 'SCRIPT_DOCUMENT_REVISION_CONFLICT',
        'SCRIPT_WORKBOOK_REVIEW_REQUIRED', 'SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED',
        'SCRIPT_PERMISSION_DENIED'}.contains(code);
  String get userMessage => code.startsWith('SCRIPT_')
      ? 'School Google storage could not complete the request. Cached data is retained; contact the school if this continues.'
      : 'School server is temporarily unavailable (HTTP $status). Cached data is retained.';
  @override
  String toString() => '$userMessage${code.isEmpty ? '' : ' [$code]'}';
}

Duration schoolRetryDelay(int failures, {double? jitter, bool quota = false}) {
  final base = ((quota ? 60 : 5) * (1 << (failures - 1).clamp(0, 6).toInt()));
  final cap = quota ? 900 : 300;
  return Duration(milliseconds: (base * 1000 * (1 + (jitter ?? Random().nextDouble()).clamp(0, 1) * .25)).clamp(5000, cap * 1000).toInt());
}