import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/windows_sync_schedule.dart';
import '../lib/sync_recovery_policy.dart';
import '../lib/windows_connect/central_school_cloud.dart';

class _ObservedTimer implements Timer {
  bool active = true;
  @override void cancel() => active = false;
  @override bool get isActive => active;
  @override int get tick => 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final db = FirebaseFirestore.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile('activity-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolSyncId':school,'schoolId':school});
  });
  test('hourly deadline uses durable checkpoint across restart and future-clock anomaly', () {
    var now = DateTime.utc(2026,10,11,10,45);
    final checkpoint = DateTime.utc(2026,10,11,10);
    final delays = <Duration>[], signals = <Duration>[];
    final timers = <_ObservedTimer>[];
    final callbacks = <void Function()>[];
    final schedule = WindowsSyncSchedule(signals.add, now: () => now,
      periodic: (delay,callback) => _ObservedTimer(),
      once: (delay,callback) {
        delays.add(delay);callbacks.add(callback);
        final timer = _ObservedTimer();timers.add(timer);return timer;
      });
    schedule.start(const Duration(minutes:4));
    schedule.armCheckpoint(checkpoint);
    expect(delays.single,const Duration(minutes:15));
    // A normal remote poll does not replace the verified checkpoint.
    now = now.add(const Duration(minutes:4));
    schedule.armCheckpoint(checkpoint);
    expect(delays.last,const Duration(minutes:11));
    expect(timers.first.isActive,false);
    now = DateTime.utc(2026,10,11,11);
    callbacks.last();
    expect(signals,[const Duration(milliseconds:250)]);
    expect(syncCheckpointDue(checkpoint,now),true);
    schedule.armCheckpoint(checkpoint);
    expect(delays.last,Duration.zero);
    schedule.armCheckpoint(now.add(const Duration(hours:2)));
    expect(delays.last,Duration.zero);
    schedule.stop();expect(timers.every((t)=>!t.isActive),true);
  });
  test('measured operation activity waits for ACK and observer failures cannot change queue', () async {
    await db.collection('teachers_directory').doc('teacher').set({'name':'TEST'});
    final queued = (await db.collection('_windows_firebase_outbox').get()).docs.single;
    final started = Completer<void>(), response = Completer<String>();
    final events = <Map<String,dynamic>>[];
    final flushing = WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
      send:(a,b,c,d)async{}, sendVersioned:(row) {started.complete();return response.future;},
      onActivity:(event) {events.add(event);if(event['stage']=='cloudRequest')throw StateError('Observer TEST');});
    await started.future;
    expect(events.map((e)=>e['stage']),['cloudRequest','waitingForAck']);
    expect((await db.collection('_windows_firebase_outbox').get()).docs,hasLength(1));
    response.complete('real-test-provider-revision');await flushing;
    expect(events.last['stage'],'verified');
    expect(events.last['operationId'],queued.data()['operationId']);
    expect(events.last['elapsedMicros'],isNonNegative);
    expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
    expect(events.every((e)=>!e.containsKey('data') && !e.containsKey('lastError')),true);
  });
  test('timeout emits recoverable retry and preserves operation capture identity', () async {
    await db.collection('school_notices').doc('notice').set({'text':'TEST','capturedAt':123});
    final before=(await db.collection('_windows_firebase_outbox').get()).docs.single;
    final events=<Map<String,dynamic>>[];
    await expectLater(WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
      send:(a,b,c,d)async{},sendVersioned:(row)async=>throw TimeoutException('TEST'),
      onActivity:events.add),throwsA(isA<TimeoutException>()));
    final after=(await before.reference.get()).data()!;
    expect(after['operationId'],before.data()['operationId']);
    expect(after['data']['capturedAt'],123);
    expect(after['syncState'],'retry');expect(after['retryAtMillis'],isA<int>());
    expect(events.last['stage'],'retry');expect(events.last['isRetryable'],true);
    expect(events.any((e)=>e['stage']=='verified'),false);
  });
  test('conflicts and authorization errors never offer safe transport retry', () async {
    for (final status in [409,403]) {
      final id = 'case-$status';
      await db.collection('teachers_directory').doc(id).set({'name':'TEST'});
      final selected = (await db.collection('_windows_firebase_outbox').get()).docs
          .singleWhere((row)=>row.data()['documentId']==id);
      final events=<Map<String,dynamic>>[];
      await expectLater(WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
        onlyQueueId:selected.id,send:(a,b,c,d)async{},sendVersioned:(row)async=>
          throw CentralCloudException(status,'school_cloud','TEST',
            diagnosticCode:status==409?'RECORD_REVISION_CONFLICT':''),
        onActivity:events.add),throwsA(isA<CentralCloudException>()));
      expect(events.last['stage'],status==409?'conflict':'unauthorized');
      expect(events.last['isRetryable'],false);
      expect((await selected.reference.get()).data()?['operationId'],selected.data()['operationId']);
      expect(events.any((e)=>e['stage']=='verified'),false);
    }
  });
  test('durable backoff waits only its own row and never extends on polling', () async {
    await db.collection('teachers_directory').doc('waiting').set({'name':'Waiting'});
    final waiting=(await db.collection('_windows_firebase_outbox').get()).docs.single;
    final deadline=DateTime.now().add(const Duration(hours:1)).millisecondsSinceEpoch;
    await waiting.reference.update({'syncState':'retry','retryAtMillis':deadline,
      'failureCategory':'timeout'});
    await db.collection('school_notices').doc('ready').set({'text':'Ready'});
    final sent=<String>[];
    await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
      respectBackoff:true,send:(a,b,c,d)async{},sendVersioned:(row)async {sent.add(row['documentId'] as String);return 'ACK-ready';});
    expect(sent,['ready']);
    final retained=(await waiting.reference.get()).data()!;
    expect(retained['retryAtMillis'],deadline);
    expect(pendingRecordBackoffDue(retained,DateTime.fromMillisecondsSinceEpoch(deadline-1)),false);
    expect(pendingRecordBackoffDue(retained,DateTime.fromMillisecondsSinceEpoch(deadline)),true);
    await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
      onlyQueueId:waiting.id,onlyOperationId:retained['operationId'] as String,
      send:(a,b,c,d)async{},sendVersioned:(row)async {sent.add(row['documentId'] as String);return 'ACK-user-retry';});
    expect(sent,['ready','waiting']);
  });
  test('filtered retry never sends another row or newer replacement operation', () async {
    await db.collection('teachers_directory').doc('a').set({'name':'A'});
    await db.collection('teachers_directory').doc('b').set({'name':'B'});
    final rows=(await db.collection('_windows_firebase_outbox').get()).docs;
    final selected=rows.first;
    var calls=0;
    await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
      onlyQueueId:selected.id,onlyOperationId:'stale-original-id',
      send:(a,b,c,d)async{},sendVersioned:(row)async {calls++;return 'ACK';});
    expect(calls,0);expect((await db.collection('_windows_firebase_outbox').get()).docs,hasLength(2));
    await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
      onlyQueueId:selected.id,onlyOperationId:selected.data()['operationId'] as String,
      send:(a,b,c,d)async{},sendVersioned:(row)async {calls++;return 'ACK';});
    expect(calls,1);expect((await db.collection('_windows_firebase_outbox').get()).docs,hasLength(1));
  });
}
