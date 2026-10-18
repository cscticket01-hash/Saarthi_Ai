import 'dart:async';
import 'package:fake_async/fake_async.dart';
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
  void fire(void Function() callback) {
    if (!active) return;
    // A real one-shot Timer is inactive before its callback runs.
    active = false;
    callback();
  }
  @override bool get isActive => active;
  @override int get tick => 0;
}

void main() {
  test('notice-only publication excludes unrelated identity work', () {
    expect(windowsIdPublicationTargets({'notices': {'N1'}}), isEmpty);
    expect(windowsIdPublicationTargets({
      'notices': {'N1'}, 'students_directory': {'S2'},
      'attendance': {'A1'}, 'fees': {'F1'},
    }), {'studentId': {'S2'}});
    expect(windowsIdPublicationTargets({'teachers_directory': {'T1'}}),
        {'teacherId': {'T1'}});
    expect(windowsIdPublicationTargets({'school_config': {'gps'}}), isEmpty);
    expect(windowsIdPublicationTargets({'school_config': {'school_profile_cache'}}), isNull);
    expect(windowsIdPublicationTargets({'school_settings': {'document_templates'}}), isNull);
    expect(windowsIdPublicationTargets({}, audit: true), isNull);
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  test('unverified checkpoints do not turn targeted remote changes into repeated full audits', () {
    final attempt=DateTime.utc(2026,10,17);
    expect(windowsIntegrityAuditDue(now:attempt,lastAttempt:null),true);
    for(var minute=1;minute<60;minute++) {
      final now=attempt.add(Duration(minutes:minute));
      expect(automaticWindowsSyncDue(now:now,lastAttempt:attempt,
        localMutation:false,pendingWork:true),true);
      expect(windowsIntegrityAuditDue(now:now,lastAttempt:attempt),false);
      expect(syncCheckpointDue(null,now),true,reason:'Unknown remains unknown, not a fabricated verified checkpoint');
    }
    expect(windowsIntegrityAuditDue(now:attempt.add(const Duration(hours:1)),lastAttempt:attempt),true);
    expect(windowsIntegrityAuditDue(now:attempt,lastAttempt:attempt,manual:true),true);
    expect(windowsIntegrityAuditDue(now:attempt,lastAttempt:attempt.add(const Duration(hours:1))),true);
  });
  test('remote discovery selects only changed collections and backs off independently', () {
    final now=DateTime.utc(2026,10,17);
    final watch=WindowsCloudChangeWatch();
    expect(watch.due(now),true);
    watch.succeeded(now);
    expect(watch.due(now.add(const Duration(seconds:29))),false);
    expect(watch.due(now.add(const Duration(seconds:30))),true);
    final known={'fee_payments':'fee-1','students_directory':'students-1'};
    expect(changedWindowsCollections(known,known),isEmpty);
    expect(changedWindowsCollections(known,{...known,'fee_payments':'fee-2'}),{'fee_payments'});
    expect(()=>changedWindowsCollections(known,{'fee_payments':'fee-2'}),throwsStateError);
    for(var i=0;i<12;i++)watch.failed(now);
    expect(watch.nextCheck!.difference(now),const Duration(minutes:15));
    watch.succeeded(now);expect(watch.failures,0);
    watch.reset();expect(watch.due(now),true);
  });
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
    timers.last.fire(callbacks.last);
    expect(timers.last.isActive,false);
    expect(signals,[const Duration(milliseconds:250)]);
    expect(syncCheckpointDue(checkpoint,now),true);
    schedule.armCheckpoint(checkpoint);
    expect(delays.last,Duration.zero);
    schedule.armCheckpoint(now.add(const Duration(hours:2)));
    expect(delays.last,Duration.zero);
    schedule.stop();expect(timers.every((t)=>!t.isActive),true);
  });
  test('idle admission allows startup, immediate edits and one elapsed-hour check only', () {
    fakeAsync((clock) {
      final start = DateTime.utc(2026, 10, 16);
      DateTime? lastAttempt;
      var attempts = 0, dirty = false, pending = false;
      DateTime now() => start.add(clock.elapsed);
      void dispatch() {
        if (!automaticWindowsSyncDue(now: now(), lastAttempt: lastAttempt,
            localMutation: dirty, pendingWork: pending)) return;
        attempts++;
        lastAttempt = now(); // An attempt is not a successful cloud ACK.
        dirty = false;
      }
      final lane = WindowsSyncDispatch(dispatch, now: now);
      final schedule = WindowsSyncSchedule((delay) => lane.request(delay), now: now);
      schedule.start(const Duration(hours: 1));
      dispatch(); // Every new process starts once, irrespective of saved ACK time.
      expect(attempts, 1);
      for (var minute = 0; minute < 59; minute++) {
        schedule.wake(); schedule.reconnected();
        clock.elapse(const Duration(minutes: 1));
      }
      expect(attempts, 1);
      clock.elapse(const Duration(minutes: 1, seconds: 1));
      expect(attempts, 2);
      // An empty failed hourly check does not open a rapid retry loop.
      for (var i = 0; i < 5; i++) {
        lane.request(const Duration(seconds: 5));
        clock.elapse(const Duration(seconds: 5));
      }
      expect(attempts, 2);
      dirty = true;
      lane.request(const Duration(milliseconds: 250), localMutation: true);
      clock.elapse(const Duration(milliseconds: 250));
      expect(attempts, 3);
      pending = true; // Actual durable work retains bounded retry admission.
      lane.request(const Duration(seconds: 5));
      clock.elapse(const Duration(seconds: 5));
      expect(attempts, 4);
      pending = false;
      lane.request(const Duration(seconds: 5));
      clock.elapse(const Duration(seconds: 5));
      expect(attempts, 4);
      lastAttempt = null; // Full process restart, not window focus.
      dispatch();
      expect(attempts, 5);
      schedule.stop(); lane.cancel();
    });
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
