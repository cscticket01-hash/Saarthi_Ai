import 'sync_recovery_policy.dart';

String syncRetryTime(DateTime deadline, DateTime now) {
  final local = deadline.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  final seconds = deadline.difference(now).inSeconds;
  return seconds <= 0
      ? '$stamp · due; waiting for engine admission'
      : '$stamp · in ${(seconds / 60).ceil()} min';
}

/// Display evidence only. Never schedules work, exposes raw errors or grants ACKs.
String pendingSyncDiagnostic(
  Map item, {
  required DateTime now,
  DateTime? providerRetry,
  DateTime? pausedUntil,
  bool automatic = true,
  bool syncing = false,
}) {
  final state = item['syncState'] ?? item['state'];
  final kind = SyncFailureKind.values.where(
    (k) => k.name == item['failureCategory'],
  );
  final reason = state == 'conflict'
      ? 'Local and cloud versions need review; both copies are retained.'
      : kind.isNotEmpty
      ? SyncRecoveryDecision(kind.first).message
      : {
          'conflict',
          'needsAttention',
          'needsReview',
          'rejected',
          'failed',
        }.contains(state)
      ? 'This item needs review; the original pending work is retained.'
      : 'Saved locally; waiting for sync admission.';
  if ({
        'conflict',
        'needsAttention',
        'needsReview',
        'rejected',
        'failed',
      }.contains(state) ||
      item['_queueCollection'] == '_windows_google_outbox') {
    return 'Reason: $reason\nNext retry: no automatic send scheduled; review this item.';
  }
  if (!automatic)
    return 'Reason: automatic sync is off.\nNext retry: enable automatic sync or use Sync Now.';
  if (pausedUntil != null && pausedUntil.isAfter(now)) {
    return 'Reason: sync is paused.\nPause ends: ${syncRetryTime(pausedUntil, now)}; retry remains subject to provider limits.';
  }
  DateTime? deadline;
  final millis = item['retryAtMillis'];
  if (millis is int && millis > 0)
    deadline = DateTime.fromMillisecondsSinceEpoch(millis);
  if (providerRetry != null &&
      providerRetry.isAfter(now) &&
      (deadline == null || providerRetry.isAfter(deadline)))
    deadline = providerRetry;
  if (deadline != null)
    return 'Reason: $reason\nNext retry: ${syncRetryTime(deadline, now)}';
  return 'Reason: $reason\nNext retry: ${syncing ? 'engine is processing queued work' : 'on the next admitted sync; no fixed retry time recorded'}.';
}

String adaptiveSyncDiagnostic(Map? evidence) {
  if (evidence == null)
    return 'Adaptive batching: waiting for a verified batch measurement.';
  final next = evidence['nextLimit'], micros = evidence['requestMicros'];
  if (next is! int ||
      next < 2 ||
      next > 10 ||
      micros is! num ||
      !micros.isFinite ||
      micros < 0) {
    return 'Adaptive batching: measurement unavailable.';
  }
  final reason = switch (evidence['adjustmentReason']) {
    'reduce_error' => 'Errors or incomplete receipts: reducing pressure',
    'reduce_slow' => 'Slow response: reducing pressure',
    'grow_fast' => 'Fast verified response: increasing batch size',
    _ => 'Keeping the current safe batch size',
  };
  return 'Adaptive batching: $next records per batch (maximum 10).\n$reason. Last broker response: ${(micros / 1000000).toStringAsFixed(2)} s.';
}

/// Compact overview card: static supported range plus last measured adjustment.
String adaptiveSyncCard(Map? evidence) {
  const range = 'Batch range: 2–10 records';
  if (evidence == null) return '$range\nStatus: Waiting for a batch measurement.';
  final next = evidence['nextLimit'];
  if (next is! int || next < 2 || next > 10) {
    return '$range\nStatus: Measurement unavailable.';
  }
  final adjustment = switch (evidence['adjustmentReason']) {
    'reduce_error' => 'Reduced · errors or incomplete receipts',
    'reduce_slow' => 'Reduced · slow response',
    'grow_fast' => 'Increased · fast verified response',
    'hold' => 'Holding safe batch size',
    _ => 'Adjustment not recorded',
  };
  return '$range\nNext batch: $next records\nLast adjustment: $adjustment';
}
