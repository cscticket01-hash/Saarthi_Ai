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
