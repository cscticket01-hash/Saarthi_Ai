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
  print('12 queue projection checks passed');
}
