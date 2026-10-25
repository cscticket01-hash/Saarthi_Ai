import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/platform/platform_config.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_sync_comparison.dart';
import '../lib/windows_sync_recovery.dart';
import '../lib/sync_recovery_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final db = FirebaseFirestore.instance;
  Future<DocumentSnapshot<Map<String,dynamic>>> pending() async =>
      (await db.collection('_windows_firebase_outbox').get()).docs.single;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key:jsonEncode({
      'managed':true, 'projectId':platformProjectId, 'folderId':'managed',
      'schoolId':school, 'uid':'synthetic-save-test', 'firebaseRefreshToken':'synthetic',
      'endpoint':'https://unreachable.example/school-cloud',
    })});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile('save-${DateTime.now().microsecondsSinceEpoch}',
        identity:{'schoolId':school,'schoolSyncId':school});
  });

  for (final collection in ['teachers_directory','students_directory','school_notices','fee_payments']) {
    test('$collection concurrent identical saves retain one exact operation', () async {
      final ref = db.collection(collection).doc('same');
      final value = {'schoolId':school,'name':'Synthetic','amount':100};
      await ref.set(value);
      final original = (await pending()).data()!;
      await Future.wait(List.generate(8, (_) => ref.set({...value})));
      final current = (await pending()).data()!;
      expect(migrationJsonValue(current), migrationJsonValue(original));
      expect((await db.collection(collection).get()).docs.length, 1);
      await db.acknowledgeOutbox((await pending()).reference,original,revision:'verified-r1');
      await ref.set(value);
      expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
      await ref.update({'name':'Changed'});
      final changed = (await pending()).data()!;
      expect(changed['data']['name'],'Changed');
      expect(changed['baseCloudRevision'],'verified-r1');
      expect((await db.collection(collection).get()).docs.length,1);
    });
  }

  test('timestamp-only directory Save retains retry identity and diagnostics', () async {
    final ref = db.collection('teachers_directory').doc('T1');
    await ref.set({'schoolId':school,'teacherId':'person-1','name':'Same',
      'createdAt':Timestamp.fromDate(DateTime.fromMillisecondsSinceEpoch(1)),'updatedAt':Timestamp.fromDate(DateTime.fromMillisecondsSinceEpoch(1))});
    final q=await pending();
    await db.recordOutboxFailure(q.reference,q.data()!,state:'needsAttention',
      error:'Synthetic permission failure',failureCategory:'authorization',retryCount:5);
    final original=(await pending()).data()!;
    await ref.update({'updatedAt':FieldValue.serverTimestamp()});
    expect(migrationJsonValue((await pending()).data()),migrationJsonValue(original));
    expect((await ref.get()).data()?['updatedAt'],isA<Timestamp>());
    expect(((await ref.get()).data()!['updatedAt'] as Timestamp).millisecondsSinceEpoch,1);
    await db.resetVolatileSession();
    expect(migrationJsonValue((await pending()).data()),migrationJsonValue(original),reason:'Durable queue survives restart');
  });

  test('same directory value in cloud adopts verified revision despite save timestamps', () async {
    final ref=db.collection('teachers_directory').doc('T1');
    await ref.set({'schoolId':school,'teacherId':'person-1','name':'Same','updatedAt':1});
    final q=await pending();
    final remote={'schoolId':school,'id':'T1','teacherId':'person-1','name':'Same',
      'updatedAt':2,'_syncUpdatedAt':3,'_syncRevision':'cloud-r2','_syncOperationId':'other-pc'};
    expect(await db.recordOutboxConflict(q.reference,q.data()!,remote),false);
    expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
    expect((await ref.get()).data()?['_syncRevision'],'cloud-r2');
    expect((await db.collection('_windows_sync_conflict_history').get()).docs.length,1);
    expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty,
      reason:'Verified readback is not a fabricated operation ACK');
  });

  for (final collection in ['teachers_directory','students_directory']) {
    test('$collection changed Save replaces same person using authenticated CAS', () async {
      final identity=collection=='teachers_directory'?'teacherId':'mobileStableId';
      final ref=db.collection(collection).doc('P1');
      await ref.set({'schoolId':school,identity:'person-1','name':'Local'});
      final q=await pending(), original=qData(await pending());
      final remote={'schoolId':school,'id':'P1',identity:'person-1','name':'Cloud',
        '_syncRevision':'cloud-r2','_syncOperationId':'other-pc'};
      expect(await db.recordOutboxConflict(q.reference,original,remote),true);
      final conflicted=(await pending()).data()!;
      await ref.update({'name':'Local'});
      expect(migrationJsonValue((await pending()).data()),migrationJsonValue(conflicted),reason:'Unchanged Save cannot choose a winner');
      await ref.update({'name':'Explicit changed Save'});
      final saved=(await pending()).data()!;
      expect(saved['syncState'],'pending');
      expect(saved['baseCloudRevision'],'cloud-r2');
      expect(saved['savedOverConflictOperationId'],original['operationId']);
      expect((await db.collection('_windows_sync_conflicts').get()).docs.single.data()['remote']['name'],'Cloud');
      expect((await db.collection('_windows_sync_conflict_history').get()).docs.single.data()['data']['name'],'Local');
      await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,send:(a,b,c,d)async{},
        sendVersioned:(item)async {
          expect(item['baseCloudRevision'],'cloud-r2');
          expect(item['documentId'],'P1');
          return 'verified-r3';
        });
      expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
      expect((await db.collection(collection).get()).docs.length,1);
    });
  }

  test('another person, deletion, financial conflict and permission failure stay protected', () async {
    for(final entry in [
      ['teachers_directory','teacherId','other-person',false],
      ['students_directory','mobileStableId','other-person',false],
      ['teachers_directory','teacherId','person-1',true],
      ['fee_payments','paymentId','person-1',false],
    ]) {
      final collection=entry[0] as String, field=entry[1] as String;
      final ref=db.collection(collection).doc('protected');
      await ref.set({'schoolId':school,field:'person-1','amount':100});
      final rows=(await db.collection('_windows_firebase_outbox').get()).docs;
      final q=rows.singleWhere((q)=>q.data()['collection']==collection);
      await db.recordOutboxConflict(q.reference,q.data(),{
        'schoolId':school,'id':'protected',field:entry[2],'amount':200,
        '_syncDeleted':entry[3], '_syncRevision':'cloud-r2','_syncOperationId':'other-pc',
      });
      // A verified deletion may retire an obsolete operation; it must never be
      // turned into an implicit resurrection by this new Save policy.
      final retained=(await q.reference.get()).data();
      if(retained==null) continue;
      await ref.update({'amount':150});
      expect((await q.reference.get()).data()?['syncState'],'conflict');
    }
  });

  test('corrected validation retries; authorization retains original diagnosis', () async {
    final ref=db.collection('students_directory').doc('S1');
    await ref.set({'schoolId':school,'name':'Same','contact':'123'});
    var q=await pending();
    await db.recordOutboxFailure(q.reference,q.data()!,state:'needsAttention',
      error:'Invalid contact',failureCategory:'validation');
    await ref.update({'contact':'9876543210'});
    expect((await pending()).data()?['syncState'],'pending');
    q=await pending();
    await db.recordOutboxFailure(q.reference,q.data()!,state:'needsAttention',
      error:'Permission denied',failureCategory:'authorization');
    await ref.update({'name':'Changed'});
    expect((await pending()).data()?['syncState'],'needsAttention');
    expect((await pending()).data()?['failureCategory'],'authorization');
    expect((await pending()).data()?['lastError'],'Permission denied');
  });

  test('directory comparison retains photos, identity and real changes; finance dates count', () {
    const a={'schoolId':school,'teacherId':'T1','name':'Same','photoUrl':'a','updatedAt':1};
    expect(sameSavedRecord('teachers_directory',a,{...a,'updatedAt':2}),true);
    for(final change in [{'teacherId':'T2'},{'name':'Changed'},{'photoUrl':'b'},{'schoolId':'foreign'}]) {
      expect(sameSavedRecord('teachers_directory',a,{...a,...change}),false);
    }
    expect(sameSavedRecord('fee_payments',a,{...a,'updatedAt':2}),false);
    const error=PendingSyncAttention(3,2);
    expect(error.toString(),contains('2 version conflicts, 1 other issues'));
    expect(windowsSyncRecovery(const PendingSyncAttention(1,0)).kind,SyncFailureKind.unknown);
  });
}

Map<String,dynamic> qData(DocumentSnapshot<Map<String,dynamic>> row)=>row.data()!;
