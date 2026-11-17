import '../../lib/school_timestamp.dart';
import '../../lib/windows_sync_projection.dart';

void main() {
  void check(bool value) { if (!value) throw StateError('Projection regression'); }
  const now = 100;
  String state(List<Map<String,dynamic>> rows, {bool offline=false}) =>
      projectWindowsSyncState(rows, nowMillis:now,offline:offline);
  check(state([])=='idle');
  check(projectWindowsSyncState([],nowMillis:now,syncing:true,paused:true)=='paused');
  check(projectWindowsSyncState([],nowMillis:now,reviewRequired:true)=='needsAttention');
  check(state([{'syncState':'needsAttention'}])=='needsAttention');
  check(state([{'syncState':'conflict'}])=='needsAttention');
  check(state([{'syncState':'pending'}])=='pending');
  check(state([{'syncState':'retry','retryAtMillis':200}])=='waiting');
  check(state([{'syncState':'retry','retryAtMillis':99}])=='pending');
  check(state([{'syncState':'pending'}],offline:true)=='offline');
  // A receipt/event cannot erase a retained row before durable completion.
  check(state([{'syncState':'acknowledged'}])=='pending');
  check(state([{'_queueCollection':'_windows_google_outbox'}])=='waiting');
  check(nextWindowsQueueRetry([
    {'syncState':'retry','retryAtMillis':300},
    {'syncState':'retry','retryAtMillis':200},
    {'syncState':'needsAttention','retryAtMillis':150},
    {'syncState':'retry','retryAtMillis':99},
  ],now)==200);
  check(nextWindowsQueueRetry([],now)==null);

  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final nowMs = DateTime.utc(2026, 11, 2).millisecondsSinceEpoch;
  final old = Timestamp.fromDate(
    DateTime.fromMillisecondsSinceEpoch(nowMs - 180000, isUtc: true));
  final recent = Timestamp.fromDate(
    DateTime.fromMillisecondsSinceEpoch(nowMs - 30000, isUtc: true));
  Map<String,dynamic> pending(Object timestamp) => {
    'schoolId': school,
    '_queueCollection': '_windows_firebase_outbox',
    'syncState': 'pending', 'retryCount': 0, 'queuedAt': timestamp,
  };
  bool stalled(List<Map<String,dynamic>> rows, {
    bool syncing = false, bool paused = false,
    bool automaticEnabled = true, int? nextRetryMillis,
  }) => windowsSyncAdmissionStalled(rows,
    schoolId: school, nowMillis: nowMs, syncing: syncing,
    paused: paused, automaticEnabled: automaticEnabled,
    nextRetryMillis: nextRetryMillis,
  );
  check(stalled([pending(old)]));
  check(!stalled([pending(recent)]));
  check(!stalled([pending(old)], syncing: true));
  check(!stalled([pending(old)], paused: true));
  check(!stalled([pending(old)], automaticEnabled: false));
  check(!stalled([pending(old)], nextRetryMillis: nowMs + 10000));
  check(!stalled([{...pending(old), 'retryAtMillis': nowMs + 10000}]));
  check(!stalled([{...pending(old), 'retryCount': 2}]));
  check(!stalled([{...pending(old), 'schoolId': 'foreign'}]));
  check(!stalled([{...pending(old), 'queuedAt': null}]));
  check(!stalled([{...pending(old), 'syncState': 'accepted'}]));
  check(!stalled([{...pending(old), '_queueCollection': '_windows_google_outbox'}]));
  print('Queue projection and stalled-dispatch safeguards passed');
}
