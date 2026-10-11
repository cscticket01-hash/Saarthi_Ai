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
    await db.switchProfile('synthetic-restore',identity:{'schoolId':school,'schoolSyncId':school});
    final ref=db.collection('school_notices').doc('notice');
    await ref.set({'schoolId':school,'title':'Retained','capturedAt':1791500000123});
    await ref.delete();
    final deletion=(await db.collection('_windows_local_deletions').get()).docs.single.id;
    await db.requestLocalRestore(deletion,approved:true);
  });
  tearDown(()async {await db.resetVolatileSession();});
  Future<void> deleteAck() => WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
    send:(a,b,c,d)async{},sendVersioned:(row)async=>'actual-delete-revision');
  Map<String,dynamic> inventory()=>{'schoolId':school,'recycleVersion':1,'partial':false,
    'entries':[{'id':'notice','collection':'school_notices','deletedRevision':'actual-delete-revision',
      'fileId':'synthetic-private-snapshot','status':'recoverable'}]};
  test('unacknowledged deletion is never cancelled or sent as a restore',()async {
    var calls=0;
    final original=(await db.collection('_windows_firebase_outbox').get()).docs.single.data();
    await syncLocalRestoreRequests(db,school,(body)async {calls++;return {};});
    expect(calls,0);
    expect((await db.collection('_windows_firebase_outbox').get()).docs.single.data(),original);
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
      return {'schoolId':school,'restored':true,'syncProtocol':2,'recordRevision':'actual-restore-revision'};
    });
    expect((await db.collection('_windows_recycle_requests').get()).docs.single.data()['state'],'verified');
    expect((await db.collection('school_notices').doc('notice').get()).data()?['capturedAt'],1791500000123);
    expect((await db.collection('_windows_local_deletions').get()).docs.single.data()['deletedRevision'],'actual-delete-revision');
  });
  test('foreign or malformed restore responses never become verified local receipts',()async {
    await deleteAck();
    await expectLater(syncLocalRestoreRequests(db,school,(body)async =>body['operation']=='list'?inventory():
      {'schoolId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','restored':true,'syncProtocol':2,'recordRevision':'foreign'}),throwsStateError);
    expect((await db.collection('_windows_recycle_requests').get()).docs.single.data()['state'],'retry');
    expect((await db.collection('school_notices').doc('notice').get()).data()?['_syncRevision'],isNot('foreign'));
  });
}
