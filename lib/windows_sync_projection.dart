/// Derive display state from durable queue rows. An ACK event alone never
/// removes a row: only its version-checked durable completion can do that.
String projectWindowsSyncState(List<Map<String, dynamic>> rows,
    {required int nowMillis, bool syncing = false, bool paused = false,
    bool blocked = false, bool offline = false, bool failed = false,
    bool reviewRequired = false}) {
  if (syncing) return 'syncing';
  if (paused) return 'paused';
  if (blocked || reviewRequired || rows.any((r) => {'conflict', 'needsAttention', 'needsReview',
      'rejected', 'failed'}.contains(r['syncState'] ?? r['state']))) {
    return 'needsAttention';
  }
  if (offline) return 'offline';
  if (failed) return 'waiting';
  if (rows.isEmpty) return 'idle';
  if (rows.every((r) => r['_queueCollection'] == '_windows_google_outbox' ||
      r['retryAtMillis'] is int && (r['retryAtMillis'] as int) > nowMillis)) {
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
        {'conflict','needsAttention','needsReview','rejected','failed'}
            .contains(row['syncState'] ?? row['state'])) continue;
    final deadline = row['retryAtMillis'];
    if (deadline is int && deadline > nowMillis &&
        (earliest == null || deadline < earliest)) earliest = deadline;
  }
  return earliest;
}

/// Queue state describes outstanding work, never proof of cloud completeness.
Map<String,Map<String,dynamic>> windowsSyncLanes(List<Map<String,dynamic>> rows,
    int nowMillis) {
  final groups=<String,List<Map<String,dynamic>>>{'records':[], 'documents':[], 'other':[]};
  for(final row in rows) {
    final queue=row['_queueCollection'];
    final lane=queue=='_windows_document_outbox'||row['collection']=='documents'
        ? 'documents' : queue=='_windows_firebase_outbox' ? 'records' : 'other';
    groups[lane]!.add(row);
  }
  return groups.map((key,items)=>MapEntry(key,{
    'pending':items.length,
    'retry':items.where((r)=>r['syncState']=='retry').length,
    'review':items.where((r)=>{'conflict','needsAttention','needsReview','rejected','failed'}
      .contains(r['syncState']??r['state'])).length,
    'nextRetryMillis':nextWindowsQueueRetry(items,nowMillis),
  }));
}

String documentFailureExplanation(Map row) {
  const messages={
    'ACK_UNVERIFIED':'Server acknowledgement or readback did not verify. Pending retained.',
    'SCRIPT_DOCUMENT_REVISION_CONFLICT':'Document version changed. Review both versions.',
    'RECORD_REVISION_CONFLICT':'Cloud record version changed. Review both versions.',
    'OPERATION_ID_CONFLICT':'Operation identity differs. Review required.',
    'SCRIPT_PERMISSION_DENIED':'School Drive permission was denied.',
    'SCRIPT_QUOTA_EXCEEDED':'School storage request limit reached.',
    'SCRIPT_TIMEOUT':'School Script timed out; completion remains unverified.',
    'SCRIPT_HTTP_ERROR':'School Script returned an HTTP error.',
    'SCRIPT_IDENTITY_MISMATCH':'School Script identity did not match.',
    'SCRIPT_RECORD_VERIFY_FAILED':'School record verification failed.',
    'SCRIPT_STORAGE_NOT_PREPARED':'School storage is not prepared.',
    'SCHOOL_STORAGE_NOT_CONNECTED':'School storage is not connected.',
    'SCRIPT_TRANSPORT_ERROR':'School Script could not be reached.',
    'SCRIPT_RESPONSE_READ_FAILED':'School Script response could not be read.',
    'SCRIPT_OPERATION_FAILED':'School Script did not complete the operation.',
    'fileMissing':'Local file could not be read. Restore access to the original file.',
  };
  const stages={'prepare':'Prepare document','readLocalFile':'Read local file',
    'requestAndReadback':'Server request / cloud readback',
    'verifyAcknowledgement':'Verify acknowledgement','commitLocalReceipt':'Save local receipt'};
  final parts=<String>[];
  if(messages[row['failureCode']]!=null)parts.add(messages[row['failureCode']]!);
  if(stages[row['failureStage']]!=null)parts.add('Step: ${stages[row['failureStage']]}');
  final status=row['failureHttpStatus'];
  if(status is int&&status>=400&&status<=599)parts.add('HTTP $status');
  return parts.join('\n');
}
