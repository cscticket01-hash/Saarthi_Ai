/// Separate durable upload rows from inbound record/file work and change hints.
///
/// A change signal means "check the cloud", not "one record is uploading".
/// It cannot be cleared without the existing verified reconciliation path.
/// Only metadata from the currently selected school contributes to a count.
Map<String, int> windowsIncomingPendingBreakdown({
  required String schoolId,
  required Iterable<Map<String, dynamic>> downloads,
  required bool remoteChangeQueued,
  Map<String, dynamic>? binaryStatus,
}) {
  int boundedCount(Object? value) => value is num && value.isFinite
      ? value.toInt().clamp(0, 1000000000).toInt()
      : 0;
  final validSchool = schoolId.isNotEmpty;
  var records = 0;
  if (validSchool) {
    for (final row in downloads) {
      if (row['schoolId'] == schoolId && row['state'] != 'verified') {
        records += boundedCount(row['remaining']);
      }
    }
  }
  final remoteChecks = validSchool && remoteChangeQueued ? 1 : 0;
  final files = validSchool &&
          binaryStatus?['schoolId'] == schoolId &&
          binaryStatus?['inventory'] != null &&
          binaryStatus?['inventory'] != 'UNKNOWN'
      ? boundedCount(binaryStatus?['pending']) +
          boundedCount(binaryStatus?['failed']) +
          boundedCount(binaryStatus?['interrupted'])
      : 0;
  return {
    'recordDownloads': records,
    'remoteChecks': remoteChecks,
    'mediaFiles': files,
    'total': records + remoteChecks + files,
  };
}

/// Select at most one stale, own-school download for *verified* recovery.
/// "downloading" can be left behind by a crash; "needsReview" is still real
/// unverified work. Neither is an upload ACK or a reason to clear a queue.
/// Two attempts per unchanged collection revision, >=15 minutes apart, prevent
/// the self-healer from repeatedly rereading a large school collection.
List<String> windowsStalledDownloadRepairTargets({
  required String schoolId,
  required Iterable<Map<String, dynamic>> downloads,
  required Set<String> allowedCollections,
  required int nowMillis,
}) {
  if (schoolId.isEmpty) return const [];
  final candidates = downloads.where((row) {
    if (row['schoolId'] != schoolId ||
        !allowedCollections.contains(row['collection']) ||
        !{'downloading', 'needsReview'}.contains(row['state'])) return false;
    final remaining = row['remaining'];
    final observed = row['observedAt'];
    if (remaining is! num || remaining <= 0 ||
        observed is! num || observed <= 0 ||
        nowMillis - observed.toInt() < const Duration(minutes: 2).inMilliseconds) {
      return false;
    }
    final attempts = (row['repairAttempts'] as num? ?? 0).toInt();
    final last = (row['repairLastAttemptAt'] as num? ?? 0).toInt();
    return attempts < 2 &&
        (last <= 0 ||
         nowMillis - last >= const Duration(minutes: 15).inMilliseconds);
  }).toList()
    ..sort((a,b) => (a['observedAt'] as num).compareTo(b['observedAt'] as num));
  return [
    for (final row in candidates.take(1)) row['collection'] as String,
  ];
}

/// Short, truthful wording for the circular display. A remote change hint is
/// not a queued upload. The detailed status panel shows every component.
String windowsSyncFlowPendingText(
  int uploads,
  Map<String, dynamic> inbound,
) {
  final records = (inbound['recordDownloads'] as num? ?? 0).toInt();
  final signals = (inbound['remoteChecks'] as num? ?? 0).toInt();
  final files = (inbound['mediaFiles'] as num? ?? 0).toInt();
  if (uploads > 0) return '$uploads uploads';
  if (records > 0 && signals == 0 && files == 0) return '$records downloads';
  if (signals > 0 && records == 0 && files == 0) return 'Cloud check queued';
  if (files > 0 && records == 0 && signals == 0) return '$files files to verify';
  if (records + signals + files > 0) return 'Incoming work';
  return '0 pending';
}

/// A manual request must revisit already-blocked own-school conflicts even
/// when the cloud collection head has not changed since the last download.
Set<String> manualConflictReadCollections(Iterable<Map<String,dynamic>> rows, {
  required String school,
  required Set<String> allowed,
}) => {
  for(final row in rows)
    if(school.isNotEmpty && row['schoolId']==school &&
       row['syncState']=='conflict' && allowed.contains(row['collection']))
      row['collection'] as String,
};

/// Derive display state from durable queue rows. An ACK event alone never
/// removes a row: only its version-checked durable completion can do that.
String projectWindowsSyncState(
  List<Map<String, dynamic>> rows, {
  required int nowMillis,
  bool syncing = false,
  bool paused = false,
  bool blocked = false,
  bool offline = false,
  bool failed = false,
  bool reviewRequired = false,
  int incomingPending = 0,
}) {
  if (paused) return 'paused';
  if (syncing) return 'syncing';
  if (blocked ||
      reviewRequired ||
      rows.any(
        (r) => {
          'conflict',
          'needsAttention',
          'needsReview',
          'rejected',
          'failed',
        }.contains(r['syncState'] ?? r['state']),
      )) {
    return 'needsAttention';
  }
  if (offline) return 'offline';
  if (failed) return 'waiting';
  if (rows.isEmpty) return incomingPending>0?'pending':'idle';
  if (rows.every(
    (r) =>
        r['_queueCollection'] == '_windows_google_outbox' ||
        r['retryAtMillis'] is int && (r['retryAtMillis'] as int) > nowMillis,
  )) {
    return 'waiting';
  }
  return 'pending';
}

/// Earliest future row deadline. Review-only and legacy managed rows do not
/// trigger repeated sends; startup/reconnect still reconcile retained data.
int? nextWindowsQueueRetry(List<Map<String, dynamic>> rows, int nowMillis) {
  int? earliest;
  for (final row in rows) {
    if (row['_queueCollection'] == '_windows_google_outbox' ||
        {
          'conflict',
          'needsAttention',
          'needsReview',
          'rejected',
          'failed',
        }.contains(row['syncState'] ?? row['state']))
      continue;
    final deadline = row['retryAtMillis'];
    if (deadline is int &&
        deadline > nowMillis &&
        (earliest == null || deadline < earliest))
      earliest = deadline;
  }
  return earliest;
}

/// Queue state describes outstanding work, never proof of cloud completeness.
Map<String, Map<String, dynamic>> windowsSyncLanes(
  List<Map<String, dynamic>> rows,
  int nowMillis,
) {
  final groups = <String, List<Map<String, dynamic>>>{
    'records': [],
    'documents': [],
    'other': [],
  };
  for (final row in rows) {
    final queue = row['_queueCollection'];
    final lane =
        queue == '_windows_document_outbox' || row['collection'] == 'documents'
        ? 'documents'
        : queue == '_windows_firebase_outbox'
        ? 'records'
        : 'other';
    groups[lane]!.add(row);
  }
  return groups.map(
    (key, items) => MapEntry(key, {
      'pending': items.length,
      'retry': items.where((r) => r['syncState'] == 'retry').length,
      'review': items
          .where(
            (r) => {
              'conflict',
              'needsAttention',
              'needsReview',
              'rejected',
              'failed',
            }.contains(r['syncState'] ?? r['state']),
          )
          .length,
      'nextRetryMillis': nextWindowsQueueRetry(items, nowMillis),
    }),
  );
}

String documentFailureExplanation(Map row) {
  const messages = {
    'FIELD_DELTA_UNAVAILABLE':'Field-only sync support or a verified baseline is required. The saved edit is retained.',
    'RECORD_LOCAL_STORAGE_IO': 'Local database or credential access failed. The original request is retained for bounded retry.',
    'ACK_UNVERIFIED':
        'Server acknowledgement or readback did not verify. Pending retained.',
    'SCRIPT_DOCUMENT_REVISION_CONFLICT':
        'Document version changed. Review both versions.',
    'RECORD_REVISION_CONFLICT':
        'Cloud record version changed. Review both versions.',
    'OPERATION_ID_CONFLICT': 'Operation identity differs. Review required.',
    'SCRIPT_PERMISSION_DENIED': 'School Drive permission was denied.',
    'SCRIPT_QUOTA_EXCEEDED': 'School storage request limit reached.',
    'SCRIPT_TIMEOUT': 'School Script timed out; completion remains unverified.',
    'SCRIPT_HTTP_ERROR': 'School Script returned an HTTP error.',
    'SCRIPT_IDENTITY_MISMATCH': 'School Script identity did not match.',
    'SCRIPT_RECORD_VERIFY_FAILED': 'School record verification failed.',
    'SCRIPT_STORAGE_NOT_PREPARED': 'School storage is not prepared.',
    'SCHOOL_STORAGE_NOT_CONNECTED': 'School storage is not connected.',
    'SCRIPT_TRANSPORT_ERROR': 'School Script could not be reached.',
    'SCRIPT_RESPONSE_READ_FAILED': 'School Script response could not be read.',
    'SCRIPT_OPERATION_FAILED': 'School Script did not complete the operation.',
    'SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED': 'Legacy or duplicate school record needs review.',
    'SCRIPT_STUDENT_PARENT_PENDING': 'Student parent record must sync before its child records.',
    'SCRIPT_STUDENT_GENERATION_DELETED': 'This student generation was deleted; stale upload retained for review.',
    'SCRIPT_INVALID_SYNC_OPERATION': 'School Script rejected the saved operation format.',
    'SCRIPT_SHEET_RECOVERY_REQUIRED': 'Verified school Sheet recovery is required.',
    'SCRIPT_BLANK_SCHOOL_PROFILE': 'Required school profile fields are missing.',
    'SCRIPT_WORKBOOK_REVIEW_REQUIRED': 'School workbook identity requires review.',
    'SCRIPT_SYNC_STATE_UNAVAILABLE': 'School sync state could not be verified.',
    'SCRIPT_SYNC_STATE_IDENTITY': 'School sync state identity differs.',
    'STUDENT_SLOT_CONFLICT': 'Student class, section or roll is already occupied.',
    'fileMissing':
        'Local file could not be read. Restore access to the original file.',
  };
  const stages = {
    'prepare': 'Prepare document',
    'readLocalFile': 'Read local file',
    'requestAndReadback': 'Server request / cloud readback',
    'verifyAcknowledgement': 'Verify acknowledgement',
    'commitLocalReceipt': 'Save local receipt',
    'recordRequestAndAck': 'Send saved record / verify acknowledgement',
  };
  final parts = <String>[];
  if (messages[row['failureCode']] != null)
    parts.add(messages[row['failureCode']]!);
  if (stages[row['failureStage']] != null)
    parts.add('Step: ${stages[row['failureStage']]}');
  final osCode=row['failureOsErrorCode'];
  if(row['failureCode']=='RECORD_LOCAL_STORAGE_IO'&&osCode is int&&osCode>=0&&osCode<=65535)
    parts.add('Local storage OS code: $osCode');
  final status = row['failureHttpStatus'];
  if (status is int && status >= 400 && status <= 599)
    parts.add('HTTP $status');
  return parts.join('\n');
}

/// Decisions use retained evidence; they neither grant ACK authority nor pick
/// a winning version. The existing owner still performs every actual request.
Map<String, dynamic> smartSyncDecision(
  Map row, {
  required String school,
  required int nowMillis,
  bool respectBackoff = true,
}) {
  Map<String, dynamic> decision(String action, String reason, bool attempt) => {
    'action': action,
    'reason': reason,
    'canAttempt': attempt,
  };
  if (row['schoolId'] != null && row['schoolId'] != school)
    return decision(
      'Blocked',
      'School identity differs. Reopen the correct school.',
      false,
    );
  final state = row['syncState'] ?? row['state'];
  if (state == 'conflict')
    return decision(
      'Review versions',
      'Local and cloud evidence differ. Both versions remain retained.',
      false,
    );
  if ({'needsAttention', 'needsReview', 'rejected', 'failed'}.contains(state)) {
    if (row['failureCategory'] == 'fileMissing')
      return decision(
        'Restore local file',
        'Original file must be readable before retry.',
        false,
      );
    if (row['failureCategory'] == 'authorization')
      return decision(
        'Verify access',
        'School authorization must be verified.',
        false,
      );
    return decision(
      'Diagnose',
      'Review the classified failure before another attempt.',
      false,
    );
  }
  if (row['_queueCollection'] == '_windows_google_outbox')
    return decision(
      'Review legacy work',
      'This request belongs to the legacy storage path.',
      false,
    );
  final deadline = row['retryAtMillis'];
  if (respectBackoff && deadline is num && deadline > nowMillis)
    return decision(
      'Wait for retry',
      'Respect the saved retry deadline; avoid repeated requests.',
      false,
    );
  if (row['parentDeletionOperationId'] is String &&
      row['ownerDeleteBaselineVerified'] != true)
    return decision(
      'Verify parent deletion',
      'Document deletion waits for verified parent-deletion evidence.',
      true,
    );
  if (row['failureCode'] == 'ACK_UNVERIFIED')
    return decision(
      'Verify receipt',
      'Retry the same operation identity; only a matching cloud readback can complete it.',
      true,
    );
  return decision(
    'Sync when admitted',
    'Use the existing school-scoped queue and revision checks.',
    true,
  );
}

/// Automatic publication must not undo a local or observed cloud deletion.
/// Explicit operator publication/review retains its separate authority.
bool holdAutomaticIdCard(Map? local, Map? pending, Map? cloud, String school) =>
    local?['deleted'] == true ||
    pending?['deleted'] == true ||
    {'conflict', 'needsAttention'}.contains(pending?['syncState']) ||
    (cloud?['schoolId'] == school && cloud?['_syncDeleted'] == true);
