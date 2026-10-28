// Pure policy checks: no Flutter bootstrap, network or package downloads.
import '../../lib/sync_recovery_policy.dart';
import '../../lib/sync_pending_diagnostics.dart';

void check(bool value, String label) {
  if (!value) throw StateError(label);
}

void main() {
  final now = DateTime(2026, 10, 29, 12);
  final retry = now.add(const Duration(minutes: 2));
  final row = <String, dynamic>{
    'syncState': 'retry',
    'failureCategory': 'networkPath',
    'retryAtMillis': retry.millisecondsSinceEpoch,
  };
  final text = pendingSyncDiagnostic(row, now: now);
  check(
    text.contains('Cannot reach') && text.contains('in 2 min'),
    'Reason or retry countdown missing',
  );
  check(
    pendingSyncDiagnostic(
      row,
      now: now,
      providerRetry: now.add(const Duration(minutes: 5)),
    ).contains('in 5 min'),
    'Shared quota wait shortened',
  );
  check(
    pendingSyncDiagnostic({
      ...row,
      'syncState': 'conflict',
    }, now: now).contains('no automatic send scheduled'),
    'Conflict shown as auto retry',
  );
  check(
    pendingSyncDiagnostic(
      row,
      now: now,
      automatic: false,
    ).contains('automatic sync is off'),
    'Automatic-off not visible',
  );
  check(
    pendingSyncDiagnostic(
      row,
      now: now,
      pausedUntil: retry,
    ).contains('Pause ends'),
    'Pause not visible',
  );
  check(
    pendingSyncDiagnostic({
      'syncState': 'pending',
    }, now: now).contains('no fixed retry time'),
    'Invented pending deadline',
  );
  check(
    pendingSyncDiagnostic(row, now: retry).contains('due; waiting'),
    'Overdue labelled complete',
  );
  check(
    !pendingSyncDiagnostic({
      ...row,
      'lastError': 'PRIVATE_TOKEN',
    }, now: now).contains('PRIVATE_TOKEN'),
    'Raw server error exposed',
  );
  var size = 2;
  for (var i = 0; i < 20; i++)
    size = managedBatchWindow(
      current: size,
      requestMicros: 500000,
      complete: true,
    );
  check(size == 10, 'Fast full responses did not grow within cap');
  check(
    managedBatchWindow(current: 10, requestMicros: 6000000, complete: true) ==
        9,
    'Medium-slow response not reduced',
  );
  check(
    managedBatchWindow(current: 10, requestMicros: 9000000, complete: true) ==
        5,
    'Slow response not halved',
  );
  check(
    managedBatchWindow(current: 10, requestMicros: 500000, complete: false) ==
        5,
    'Error/partial receipts grew batch',
  );
  for (var i = 0; i < 20; i++)
    size = managedBatchWindow(
      current: size,
      requestMicros: 9000000,
      complete: false,
    );
  check(size == 2, 'Pressure crossed minimum');
  check(
    managedBatchWindow(current: 4, requestMicros: 0, complete: true) == 4,
    'Unknown timing grew batch',
  );
  final info = adaptiveSyncDiagnostic({
    'nextLimit': 5,
    'requestMicros': 9000000,
    'adjustmentReason': 'reduce_slow',
  });
  check(
    info.contains('5 records') && info.contains('Slow response'),
    'Adaptive evidence missing',
  );
  check(
    adaptiveSyncDiagnostic({'nextLimit': 'bad'}).contains('unavailable'),
    'Malformed evidence shown as measured',
  );
  check(adaptiveSyncCard(null).contains('Batch range: 2–10') &&
      adaptiveSyncCard(null).contains('Waiting'), 'Idle card invented a measurement');
  check(adaptiveSyncCard({'nextLimit': 5, 'adjustmentReason': 'reduce_slow'}).contains('Reduced · slow response'), 'Card adjustment missing');
  check(adaptiveSyncCard({'nextLimit': 11}).contains('unavailable'), 'Invalid card window displayed');
  check(adaptiveSyncCard({'nextLimit': 6, 'adjustmentReason': 'grow_fast'}).contains('Next batch: 6'), 'Measured next window missing');
  print(
    'PASS: pending reasons/retry deadlines and adaptive speed growth/backoff/bounds',
  );
}
