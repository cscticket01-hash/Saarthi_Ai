import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_sync_schedule.dart';

class _DispatchTimer implements Timer {
  _DispatchTimer(this.callback);
  final void Function() callback;
  bool active = true;
  @override bool get isActive => active;
  @override int get tick => 0;
  @override void cancel() => active = false;
  void fire() {
    if (!active) return;
    active = false;
    callback();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const foreign = 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  final db = FirebaseFirestore.instance;
  late Directory temporary;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(true);
    temporary = await Directory.systemTemp.createTemp('vs-durable-admission-');
    await db.changeLocalStorageLocation(temporary.path);
    await db.switchProfile('synthetic-admission-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolSyncId':school,'schoolId':school});
  });
  tearDown(() async { await db.resetVolatileSession(); });

  test('fresh mutation advances long retry timer without duplicating dispatch', () {
    var now = DateTime.utc(2026,10,11);
    var dispatches = 0;
    final timers = <_DispatchTimer>[];
    final delays = <Duration>[];
    final dispatch = WindowsSyncDispatch(() => dispatches++,now: () => now,
      once: (delay,callback) {
        delays.add(delay);
        final timer = _DispatchTimer(callback);timers.add(timer);return timer;
      });
    dispatch.request(const Duration(minutes:5));
    now = now.add(const Duration(seconds:1));
    // Ordinary polling retains the existing single admission timer.
    dispatch.request(const Duration(minutes:4));
    expect(timers,hasLength(1));
    dispatch.request(const Duration(milliseconds:250),localMutation:true);
    expect(timers,hasLength(2));
    expect(timers.first.isActive,false);
    expect(delays.last,const Duration(milliseconds:250));
    // More edits cannot move the admitted burst later or create another timer.
    now = now.add(const Duration(milliseconds:10));
    dispatch.request(const Duration(milliseconds:250),localMutation:true);
    expect(timers,hasLength(2));
    timers.first.fire();expect(dispatches,0);
    timers.last.fire();expect(dispatches,1);
    expect(dispatch.scheduledAt,isNull);
    dispatch.request(const Duration(seconds:1));dispatch.cancel();
    timers.last.fire();expect(dispatches,1);
  });

  test('legacy identity binding preserves capture fields and survives disk reopen', () async {
    await db.collection('teachers_directory').doc('teacher').set({'name':'Original','capturedAt':123});
    await db.collection('school_config').doc('retained').set({'schoolName':'Synthetic'});
    final queue = (await db.collection('_windows_firebase_outbox').get()).docs
      .singleWhere((row)=>row.data()['documentId']=='teacher');
    final legacy = Map<String,dynamic>.from(queue.data())
      ..remove('operationId')..remove('schoolId');
    await queue.reference.set(legacy);
    final expected = (await queue.reference.get()).data()!;
    final migrated = await db.migrateOutboxIdentity(queue.reference,expected,schoolId:school);
    expect(migrated, isNotNull);
    expect(migrated!['operationId'],isNotEmpty);
    expect(migrated['schoolId'],school);
    expect(migrated['data']['capturedAt'],123);
    expect(migrated['data']['name'],'Original');
    final origin = db.activeProfileId;
    await db.switchProfile('synthetic-away');
    await db.switchProfile(origin,identity:{'schoolSyncId':school,'schoolId':school});
    final reopened = (await db.collection('_windows_firebase_outbox').doc(queue.id).get()).data()!;
    expect(reopened['operationId'],migrated['operationId']);
    expect((await db.collection('school_config').doc('retained').get()).data()?['schoolName'],'Synthetic');
  });

  test('foreign legacy queue cannot be rebound or sent and remains unchanged', () async {
    await db.collection('teachers_directory').doc('foreign-fixture').set({'name':'Synthetic','capturedAt':123});
    final queue = (await db.collection('_windows_firebase_outbox').get()).docs.single;
    final legacy = Map<String,dynamic>.from(queue.data())
      ..remove('operationId')..['schoolId']=foreign;
    await queue.reference.set(legacy);
    var sends = 0;
    await expectLater(WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
      send:(a,b,c,d)async{},sendVersioned:(item)async {sends++;return 'must-not-ACK';}),throwsStateError);
    final retained = (await queue.reference.get()).data()!;
    expect(sends,0);
    expect(retained['schoolId'],foreign);
    expect(retained.containsKey('operationId'),false);
    expect(retained['data']['capturedAt'],123);
    expect(retained['syncState'],legacy['syncState']);
    await expectLater(db.migrateOutboxIdentity(queue.reference,retained,schoolId:school),throwsStateError);
    expect((await queue.reference.get()).data()?['schoolId'],foreign);
  });

  test('migration compare-and-set cannot overwrite a newer durable local edit', () async {
    final ref = db.collection('teachers_directory').doc('teacher');
    await ref.set({'name':'Old','capturedAt':123});
    final queue = (await db.collection('_windows_firebase_outbox').get()).docs.single;
    final legacy = Map<String,dynamic>.from(queue.data())
      ..remove('operationId')..remove('schoolId');
    await queue.reference.set(legacy);
    final stale = (await queue.reference.get()).data()!;
    // Enqueue the newer local transaction before the migration transaction.
    final newerWrite = ref.set({'name':'Newer','capturedAt':456});
    final migration = db.migrateOutboxIdentity(queue.reference,stale,schoolId:school);
    await newerWrite;
    expect(await migration,isNull);
    final latest = (await queue.reference.get()).data()!;
    expect(latest['data']['name'],'Newer');
    expect(latest['data']['capturedAt'],456);
    expect(latest['operationId'],isNotEmpty);
    expect((await ref.get()).data()?['name'],'Newer');
  });

  test('stale cloud pull cannot re-conflict an administrator-reviewed replacement', () async {
    await db.collection('teachers_directory').doc('teacher').set({'name':'Reviewed local','capturedAt':123});
    final queue = (await db.collection('_windows_firebase_outbox').get()).docs.single;
    final original = queue.data();
    final remote = {'schoolId':school,'id':'teacher','name':'Cloud version',
      '_syncRevision':'cloud-new','_syncDeleted':false};
    expect(await db.recordOutboxConflict(queue.reference,original,remote),true);
    final conflicted = (await queue.reference.get()).data()!;
    expect(conflicted['syncState'],'conflict');
    expect(conflicted['operationId'],original['operationId']);
    await db.enqueueReviewedConflict(queueId:queue.id,expected:conflicted,remote:remote,
      choice:'local',reason:'Synthetic explicit administrator review');
    final reviewed = (await queue.reference.get()).data()!;
    expect(reviewed['operationId'],isNot(original['operationId']));
    expect(reviewed['baseCloudRevision'],'cloud-new');
    expect(reviewed['syncState'],'pending');
    // A callback carrying the pre-review snapshot arrives late.
    expect(await db.recordOutboxConflict(queue.reference,conflicted,remote),false);
    final retained = (await queue.reference.get()).data()!;
    expect(retained['operationId'],reviewed['operationId']);
    expect(retained['syncState'],'pending');
    expect(retained['baseCloudRevision'],'cloud-new');
    expect((await db.collection('_windows_sync_conflicts').get()).docs,hasLength(1));
  });

  test('conflict capture cannot mutate a newer local operation or accept a foreign manifest', () async {
    final ref = db.collection('teachers_directory').doc('teacher');
    await ref.set({'name':'Original','capturedAt':123});
    final queue = (await db.collection('_windows_firebase_outbox').get()).docs.single;
    final stale = queue.data();
    final newer = ref.set({'name':'Newer','capturedAt':456});
    final conflict = db.recordOutboxConflict(queue.reference,stale,
      {'schoolId':school,'_syncRevision':'cloud-other'});
    await newer;
    expect(await conflict,false);
    final current = (await queue.reference.get()).data()!;
    expect(current['syncState'],'pending');
    expect(current['data']['name'],'Newer');
    expect((await db.collection('_windows_sync_conflicts').get()).docs,isEmpty);
    await expectLater(db.recordOutboxConflict(queue.reference,current,
      {'schoolId':foreign,'_syncRevision':'cloud-foreign'}),throwsStateError);
    expect((await queue.reference.get()).data()?['operationId'],current['operationId']);
    expect((await db.collection('_windows_sync_conflicts').get()).docs,isEmpty);
  });

  test('lost payment ACK inventory retains original retry instead of creating conflict', () async {
    await db.collection('fee_payments').doc('payment').set({'schoolId':school,'amount':100});
    final queue = (await db.collection('_windows_firebase_outbox').get()).docs.single;
    final original = queue.data();
    final remote = {'schoolId':school,'amount':100,'_syncRevision':'committed-payment',
      '_syncOperationId':original['operationId']};
    expect(await db.recordOutboxConflict(queue.reference,original,remote),false);
    expect((await queue.reference.get()).data()?['syncState'],'pending');
    expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty);
    // Recover a previously misclassified conflict, preserving audit and CAS base.
    await queue.reference.set({...original,'syncState':'conflict','lastError':'Record revision conflict'});
    final conflicted = (await queue.reference.get()).data()!;
    expect(await db.recordOutboxConflict(queue.reference,conflicted,remote),false);
    final retry = (await queue.reference.get()).data()!;
    expect(retry['syncState'],'pending');
    expect(retry['operationId'],original['operationId']);
    expect(retry['baseCloudRevision'],original['baseCloudRevision']);
    expect((await db.collection('_windows_sync_conflict_history').get()).docs,hasLength(1));
    final origin = db.activeProfileId;
    await db.switchProfile('synthetic-payment-away');
    await db.switchProfile(origin,identity:{'schoolSyncId':school,'schoolId':school});
    final reopened = (await db.collection('_windows_firebase_outbox').doc(queue.id).get()).data()!;
    expect(reopened['syncState'],'pending');
    expect(reopened['operationId'],original['operationId']);
    await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,send:(a,b,c,d)async{},
      sendVersioned:(item)async {
        expect(item['operationId'],original['operationId']);
        return 'committed-payment';
      });
    expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
    expect((await db.collection('_windows_sync_receipts').get()).docs,hasLength(1));
  });

  test('committed payment identity re-admits exhausted transport only, without a fabricated receipt', () async {
    await db.collection('fee_payments').doc('exhausted').set({'schoolId':school,'amount':500});
    final queue=(await db.collection('_windows_firebase_outbox').get()).docs.single;
    final original=queue.data();
    final remote={'schoolId':school,'amount':500,'_syncRevision':'verified-committed-head',
      '_syncOperationId':original['operationId']};
    for(final category in ['validation','authorization','unknown','quota']) {
      await queue.reference.set({...original,'syncState':'needsAttention','failureCategory':category,'retryCount':5});
      expect(await db.recordOutboxConflict(queue.reference,(await queue.reference.get()).data()!,remote),false);
      expect((await queue.reference.get()).data()?['syncState'],'needsAttention');
    }
    await queue.reference.set({...original,'syncState':'needsAttention','failureCategory':'timeout','retryCount':5});
    final exhausted=(await queue.reference.get()).data()!;
    expect(await db.recordOutboxConflict(queue.reference,exhausted,{...remote,'_syncOperationId':'other-operation'}),false);
    expect((await queue.reference.get()).data()?['syncState'],'needsAttention');
    expect(await db.recordOutboxConflict(queue.reference,exhausted,remote),false);
    final admitted=(await queue.reference.get()).data()!;
    expect(admitted['syncState'],'pending');expect(admitted['operationId'],original['operationId']);
    expect(admitted['baseCloudRevision'],original['baseCloudRevision']);expect(admitted['data'],original['data']);
    expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty);
    expect((await db.collection('_windows_sync_conflict_history').get()).docs.single.data()['retryCount'],5);
  });

  test('already deleted payment retries authoritative tombstone without rebasing or fake ACK', () async {
    final ref = db.collection('fee_payments').doc('deleted-payment');
    await ref.set({'schoolId':school,'amount':100});
    await ref.delete();
    final queue = (await db.collection('_windows_firebase_outbox').get()).docs.single;
    final original = queue.data();
    await queue.reference.set({...original,'syncState':'conflict'});
    final conflicted = (await queue.reference.get()).data()!;
    expect(await db.recordOutboxConflict(queue.reference,conflicted,
      {'schoolId':school,'_syncDeleted':true,'_syncRevision':'deleted-elsewhere',
       '_syncOperationId':'other_device_delete_0001'}),false);
    final retry = (await queue.reference.get()).data()!;
    expect(retry['syncState'],'pending');
    expect(retry['baseCloudRevision'],original['baseCloudRevision']);
    expect(retry['operationId'],original['operationId']);
    expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty);
    expect((await ref.get()).exists,false);
  });

  test('remote payment deletion retires offline edit; deliberate new save uses deletion revision', () async {
    final ref = db.collection('fee_payments').doc('same-slot');
    await ref.set({'schoolId':school,'amount':100});
    final queue = (await db.collection('_windows_firebase_outbox').get()).docs.single;
    final original = queue.data();
    final tomb = {'schoolId':school,'_syncDeleted':true,'_syncRevision':'verified-delete'};
    expect(await db.recordOutboxConflict(queue.reference,original,tomb),false);
    expect((await ref.get()).exists,false);
    expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
    expect((await db.collection('_windows_sync_conflict_history').get()).docs.single.data()['data']['amount'],100);
    await db.applySyncedDocument(ref,null,tombstoneRevision:'verified-delete');
    await ref.set({'schoolId':school,'amount':200});
    // Full replacement edit before upload must retain fresh-entry identity.
    await ref.set({'schoolId':school,'amount':250});
    final fresh = (await db.collection('_windows_firebase_outbox').get()).docs.single;
    expect(fresh.data()['baseCloudRevision'],'verified-delete');
    expect(fresh.data()['data']['_syncRecreatesDeletedRevision'],'verified-delete');
    expect(await db.recordOutboxConflict(fresh.reference,fresh.data(),tomb),false);
    expect((await ref.get()).data()?['amount'],250);
    expect((await db.collection('_windows_firebase_outbox').get()).docs,hasLength(1));
    await fresh.reference.update({'syncState':'conflict'});
    final beforeUpgrade = (await fresh.reference.get()).data()!;
    expect(await db.recordOutboxConflict(fresh.reference,beforeUpgrade,tomb),false);
    expect((await fresh.reference.get()).data()?['syncState'],'pending');
    expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty);
  });

  test('offline delete then re-add sends durable deletion before fresh record', () async {
    final ref = db.collection('fee_payments').doc('offline-slot');
    await db.applySyncedDocument(ref,{'schoolId':school,'amount':100,'_syncRevision':'old-cloud'});
    await ref.delete();
    final deletion = (await db.collection('_windows_firebase_outbox').get()).docs.single.data();
    await ref.set({'schoolId':school,'amount':200});
    await ref.set({'schoolId':school,'amount':250});
    final origin = db.activeProfileId;
    await db.switchProfile('synthetic-offline-away');
    await db.switchProfile(origin,identity:{'schoolSyncId':school,'schoolId':school});
    final sent = <String>[];
    await WindowsPendingSchoolSync.flush(profileId:origin,send:(a,b,c,d)async{},sendVersioned:(item)async {
      sent.add(item['operation'] as String);
      if(item['operation']=='delete') {
        expect(item['operationId'],deletion['operationId']);
        expect(item['baseCloudRevision'],'old-cloud');
        return 'confirmed-deletion';
      }
      expect(item['baseCloudRevision'],'confirmed-deletion');
      expect(item['data']['_syncRecreatesDeletedOperationId'],deletion['operationId']);
      expect(item['data']['amount'],250);
      return 'fresh-record';
    });
    expect(sent,['delete','set']);
    expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
    expect((await ref.get()).data()?['amount'],250);
  });

  test('pre-upgrade confirmed deletion supports fresh save without resetting local data', () async {
    final ref = db.collection('fee_payments').doc('legacy-deleted-slot');
    await ref.set({'schoolId':school,'amount':100});
    await ref.delete();
    final queued = (await db.collection('_windows_firebase_outbox').get()).docs.single;
    await db.acknowledgeOutbox(queued.reference,queued.data(),revision:'legacy-deletion-ack');
    // Older clients persisted revision and verified deletion snapshot, without
    // the new baseline deleted flag.
    await db.collection('_windows_sync_baselines').doc(queued.id).set({'revision':'legacy-deletion-ack'});
    await ref.set({'schoolId':school,'amount':300});
    final fresh = (await db.collection('_windows_firebase_outbox').get()).docs.single.data();
    expect(fresh['baseCloudRevision'],'legacy-deletion-ack');
    expect(fresh['data']['_syncRecreatesDeletedRevision'],'legacy-deletion-ack');
    expect((await db.collection('_windows_local_deletions').get()).docs,isNotEmpty);
  });

  test('generic deletion reconciliation never discards a new student generation', () async {
    final ref = db.collection('students_directory').doc('same-student-slot');
    await ref.set({'schoolId':school,'name':'New occupant','mobileStableId':'p-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'});
    final queued = (await db.collection('_windows_firebase_outbox').get()).docs.single;
    await db.recordOutboxConflict(queued.reference,queued.data(),
      {'schoolId':school,'_syncDeleted':true,'_syncRevision':'retired-occupant',
       '_syncDeletedOwner':'p-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'});
    expect((await ref.get()).data()?['name'],'New occupant');
    expect((await db.collection('_windows_firebase_outbox').get()).docs,hasLength(1));
  });

  test('offline device missing delete/re-add adopts fresh generation but preserves genuine same-generation edits', () async {
    final ref = db.collection('fee_payments').doc('offline-other-device');
    await ref.set({'schoolId':school,'amount':100});
    final old = (await db.collection('_windows_firebase_outbox').get()).docs.single;
    final fresh = {'schoolId':school,'amount':200,'_syncRevision':'new-generation',
      '_syncRecreatesDeletedRevision':'deletion-missed-offline'};
    await db.recordOutboxConflict(old.reference,old.data(),fresh);
    expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
    await db.applySyncedDocument(ref,fresh);
    expect((await ref.get()).data()?['amount'],200);
    await ref.set({'schoolId':school,'amount':250});
    final edit = (await db.collection('_windows_firebase_outbox').get()).docs.single;
    expect(edit.data()['data']['_syncRecreatesDeletedRevision'],'deletion-missed-offline');
    expect(await db.recordOutboxConflict(edit.reference,edit.data(),{...fresh,'_syncRevision':'parallel-edit','amount':300}),true);
    expect((await ref.get()).data()?['amount'],250);
    expect((await edit.reference.get()).data()?['syncState'],'conflict');
  });

  test('adding missing school identity never replaces an original retry operation ID', () async {
    await db.collection('school_notices').doc('notice').set({'title':'Synthetic','capturedAt':123});
    final queue = (await db.collection('_windows_firebase_outbox').get()).docs.single;
    final legacy = Map<String,dynamic>.from(queue.data())..remove('schoolId');
    await queue.reference.set(legacy);
    final expected = (await queue.reference.get()).data()!;
    final migrated = await db.migrateOutboxIdentity(queue.reference,expected,schoolId:school);
    expect(migrated?['operationId'],legacy['operationId']);
    expect(migrated?['baseCloudRevision'],legacy['baseCloudRevision']);
  });
  test('late failure cannot tag a newer operation or same-ID review replacement', () async {
    final ref = db.collection('school_notices').doc('failure-race');
    await ref.set({'title':'Original','capturedAt':123});
    final queue = (await db.collection('_windows_firebase_outbox').get()).docs.single;
    final stale = queue.data();
    final newerWrite = ref.set({'title':'Newer','capturedAt':456});
    final failure = db.recordOutboxFailure(queue.reference,stale,state:'retry',
      error:'Old timeout',failureCategory:'timeout',retryCount:2,retryAtMillis:999999);
    await newerWrite;
    expect(await failure,false);
    final newer = (await queue.reference.get()).data()!;
    expect(newer['data']['title'],'Newer');
    expect(newer['syncState'],'pending');
    expect(newer['lastError'],isNull);
    // Even an unchanged operation ID cannot authorize metadata on a changed row.
    final replacement = queue.reference.update({'syncState':'needsAttention','lastError':'Reviewed'});
    final late = db.recordOutboxFailure(queue.reference,newer,state:'conflict',error:'Old conflict');
    await replacement;
    expect(await late,false);
    expect((await queue.reference.get()).data()?['lastError'],'Reviewed');
  });

  test('invalid snapshot failure is atomic and original retry metadata stays durable', () async {
    final queue = db.collection('_windows_firebase_outbox').doc('invalid-race');
    await queue.set({'schoolId':school,'operationId':'original','data':{},'retryCount':3});
    final invalid = (await queue.get()).data()!;
    final replacement = queue.set({'schoolId':school,'operationId':'replacement',
      'collection':'school_notices','documentId':'notice','operation':'set','data':{'title':'Fixed'}});
    final late = db.recordOutboxFailure(queue,invalid,state:'needsAttention',error:'Invalid old row');
    await replacement;
    expect(await late,false);
    final current = (await queue.get()).data()!;
    expect(current['operationId'],'replacement');
    expect(current['lastError'],isNull);
    final deadline = DateTime.now().add(const Duration(minutes:2)).millisecondsSinceEpoch;
    expect(await db.recordOutboxFailure(queue,current,state:'retry',error:'Timeout',
      failureCategory:'timeout',retryCount:4,retryAtMillis:deadline),true);
    final failed = (await queue.get()).data()!;
    expect(failed['operationId'],current['operationId']);
    expect(failed['data'],current['data']);
    expect(failed['retryCount'],4);
    expect(failed['retryAtMillis'],deadline);
    final foreignRow = {...failed,'schoolId':foreign};
    await queue.set(foreignRow);
    await expectLater(db.recordOutboxFailure(queue,foreignRow,state:'retry',error:'Foreign'),throwsStateError);
    expect((await queue.get()).data(),foreignRow);
  });

  test('failed send cannot mark an edit captured during the request', () async {
    final ref = db.collection('school_notices').doc('in-flight-edit');
    await ref.set({'title':'Original'});
    await expectLater(WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
      send:(collection,id,operation,data) async {
        await ref.set({'title':'Edited during request'});
        throw StateError('Old request failed');
      }),throwsStateError);
    final retained = (await db.collection('_windows_firebase_outbox').get()).docs.single.data();
    expect(retained['data']['title'],'Edited during request');
    expect(retained['syncState'],'pending');
    expect(retained['lastError'],isNull);
    expect(retained['retryCount'],0);
  });

}
