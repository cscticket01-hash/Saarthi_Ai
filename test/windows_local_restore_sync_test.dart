import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_local_restore_sync.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/platform/platform_config.dart';

// Decoded persistence timestamps are fresh objects on each read. Compare their
// actual millisecond values while retaining every field and scalar type.
String _canonicalEvidence(Object? value) {
  Object? normalize(Object? item) {
    if (item is Timestamp) return {'timestampMilliseconds':item.toDate().toUtc().millisecondsSinceEpoch};
    if (item is Map) {
      final map=Map<String,dynamic>.from(item), keys=Map<String,dynamic>.from(item).keys.toList()..sort();
      return {for(final key in keys)key:normalize(map[key])};
    }
    if (item is List) return item.map(normalize).toList();
    return item;
  }
  return jsonEncode(normalize(value));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db=FirebaseFirestore.instance;
  const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  late Directory temp;
  setUp(()async {
    FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key:jsonEncode({
      'managed':true,'schoolId':school,'uid':'synthetic-admin','projectId':platformProjectId,
      'firebaseRefreshToken':'synthetic','endpoint':'https://unreachable.example/school-cloud','folderId':'managed',
      'verifiedAccess':{'success':true,'allowed':true,'schoolId':school,'uid':'synthetic-admin',
        'expiresAt':DateTime.now().add(const Duration(days:1)).millisecondsSinceEpoch}})});
    await WindowsRuntimeFlags.setLocalStorageEnabled(true);
    temp=await Directory.systemTemp.createTemp('vs-restore-coordination-');
    await db.changeLocalStorageLocation(temp.path);
    await db.switchProfile('synthetic-restore-${DateTime.now().microsecondsSinceEpoch}',identity:{'schoolId':school,'schoolSyncId':school});
    final ref=db.collection('school_notices').doc('notice');
    await ref.set({'schoolId':school,'title':'Retained','capturedAt':1791500000123});
    await ref.delete();
    final deletion=(await db.collection('_windows_local_deletions').get()).docs.single.id;
    await db.requestLocalRestore(deletion,approved:true);
  });
  tearDown(()async {await db.resetVolatileSession();});
  Future<void> deleteAck() => WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
    send:(a,b,c,d)async{},sendVersioned:(row)async=>'actual-delete-revision');
  Map<String,dynamic> inventory()=>{'success':true,'schoolId':school,'recycleVersion':1,'partial':false,
    'entries':[{'id':'notice','collection':'school_notices','deletedRevision':'actual-delete-revision',
      'fileId':'synthetic-private-snapshot','status':'recoverable'}]};
  test('unacknowledged deletion is never cancelled or sent as a restore',()async {
    var calls=0;
    final original=(await db.collection('_windows_firebase_outbox').get()).docs.single.data();
    await syncLocalRestoreRequests(db,school,(body)async {calls++;return {};});
    expect(calls,0);
    expect(_canonicalEvidence((await db.collection('_windows_firebase_outbox').get()).docs.single.data()),_canonicalEvidence(original));
    expect((await db.collection('_windows_recycle_requests').get()).docs.single.data()['state'],'awaitingDeleteAck');
  });
  test('lost restore ACK retains exact persisted body and resumes without requiring tombstone listing',()async {
    await deleteAck();
    Map<String,dynamic>? firstBody;
    await expectLater(syncLocalRestoreRequests(db,school,(body)async {
      if(body['operation']=='list')return inventory();
      firstBody=Map<String,dynamic>.from(body);throw const SocketException('Synthetic lost ACK');
    }),throwsA(isA<SocketException>()));
    final profile=db.activeProfileId;
    await db.resetVolatileSession();await db.switchProfile(profile,identity:{'schoolId':school,'schoolSyncId':school});
    await syncLocalRestoreRequests(db,school,(body)async {
      expect(body,firstBody); // The cloud row is already restored; no second list.
      return {'success':true,'schoolId':school,'restored':true,'syncProtocol':2,'recordRevision':'actual-restore-revision'};
    });
    expect((await db.collection('_windows_recycle_requests').get()).docs.single.data()['state'],'verified');
    expect((await db.collection('school_notices').doc('notice').get()).data()?['capturedAt'],1791500000123);
    expect((await db.collection('_windows_local_deletions').get()).docs.single.data()['deletedRevision'],'actual-delete-revision');
  });
  test('foreign or malformed restore responses never become verified local receipts',()async {
    await deleteAck();
    await syncLocalRestoreRequests(db,school,(body)async =>body['operation']=='list'?inventory():
      {'success':true,'schoolId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','restored':true,'syncProtocol':2,'recordRevision':'foreign'});
    expect((await db.collection('_windows_recycle_requests').get()).docs.single.data()['state'],'needsReview');
    expect((await db.collection('school_notices').doc('notice').get()).data()?['_syncRevision'],isNot('foreign'));
  });
  for(final status in [409,403]) {
    test('permanent HTTP $status retains restore evidence and permits unrelated restore',()async {
      final other=db.collection('school_notices').doc('independent');
      await other.set({'schoolId':school,'title':'Independent','capturedAt':1791500000456});
      await other.delete();
      final deletions=(await db.collection('_windows_local_deletions').get()).docs;
      final otherDeletion=deletions.singleWhere((r)=>r.data()['documentId']=='independent').id;
      await db.requestLocalRestore(otherDeletion,approved:true);
      await deleteAck();
      final evidenceBefore={for(final r in (await db.collection('_windows_local_deletions').get()).docs)r.id:r.data()};
      final originalRequest=(await db.collection('_windows_recycle_requests').get()).docs.singleWhere((r)=>r.data()['documentId']=='notice').data();
      final unrelated=db.collection('attendance_records').doc('pending-independent');
      await unrelated.set({'schoolId':school,'capturedAt':1791500000789,'personId':'synthetic'});
      final originalQueue=(await db.collection('_windows_firebase_outbox').get()).docs.single.data();
      final attempts=<String>[];
      await syncLocalRestoreRequests(db,school,(body)async {
        if(body['operation']=='list')return {
          ...inventory(),
          'entries':[
            ...(inventory()['entries'] as List),
            {'id':'independent','collection':'school_notices','deletedRevision':'actual-delete-revision',
              'fileId':'independent-private-snapshot','status':'recoverable'}]};
        attempts.add(body['fileId'] as String);
        if(body['fileId']=='synthetic-private-snapshot')throw CentralCloudException(status,'school_cloud',
          status==409?'Record revision conflict':'School access denied',
          diagnosticCode:status==409?'RECORD_REVISION_CONFLICT':'ACCESS_DENIED');
        return {'success':true,'schoolId':school,'restored':true,'syncProtocol':2,'recordRevision':'independent-restore-revision'};
      });
      expect(attempts,containsAll(['synthetic-private-snapshot','independent-private-snapshot']));
      final requests=(await db.collection('_windows_recycle_requests').get()).docs;
      final failed=requests.singleWhere((r)=>r.data()['documentId']=='notice').data();
      expect(failed['state'],status==409?'conflict':'rejected');
      expect(failed['operationId'],originalRequest['operationId']);
      expect(failed['deletionOperationId'],originalRequest['deletionOperationId']);
      expect((failed['body'] as Map)['expectedRecordRevision'],'actual-delete-revision');
      expect(requests.singleWhere((r)=>r.data()['documentId']=='independent').data()['state'],'verified');
      expect((await db.collection('school_notices').doc('independent').get()).data()?['capturedAt'],1791500000456);
      expect(_canonicalEvidence({for(final r in (await db.collection('_windows_local_deletions').get()).docs)r.id:r.data()}),_canonicalEvidence(evidenceBefore));
      expect(_canonicalEvidence((await db.collection('_windows_firebase_outbox').get()).docs.single.data()),_canonicalEvidence(originalQueue));
      expect((await unrelated.get()).data()?['capturedAt'],1791500000789);
      // Terminal failures cannot be blindly replayed on subsequent sync ticks.
      await syncLocalRestoreRequests(db,school,(body)async {fail('Permanent restore must wait for administrator review');});
    });
  }
  test('missing bounded authoritative snapshot requires review without invented ACK',()async {
    await deleteAck();
    final original=(await db.collection('_windows_recycle_requests').get()).docs.single.data();
    final deletion=(await db.collection('_windows_local_deletions').get()).docs.single.data();
    var calls=0;
    await syncLocalRestoreRequests(db,school,(body)async {
      calls++;
      expect(body['operation'],'list');
      return {'success':true,'schoolId':school,'recycleVersion':1,'entries':[],
        'partial':true,'nextAfter':'synthetic-page-$calls'};
    });
    expect(calls,4);
    final retained=(await db.collection('_windows_recycle_requests').get()).docs.single.data();
    expect(retained['state'],'needsReview');
    expect(retained['reason'],'snapshot_not_in_bounded_inventory');
    expect(retained['operationId'],original['operationId']);
    expect(retained['deletionOperationId'],original['deletionOperationId']);
    expect(retained.containsKey('recordRevision'),false);
    expect(_canonicalEvidence((await db.collection('_windows_local_deletions').get()).docs.single.data()),_canonicalEvidence(deletion));
    expect((await db.collection('school_notices').doc('notice').get()).data()?['_syncRevision'],isNull);
    await syncLocalRestoreRequests(db,school,(body)async {fail('Missing snapshot must wait for administrator review');});
  });

}
