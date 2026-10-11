import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_local_storage.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/platform/platform_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db=FirebaseFirestore.instance;
  const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key:jsonEncode({
      'managed':true,'projectId':platformProjectId,'folderId':'managed','schoolId':school,
      'uid':'restore-admin','firebaseRefreshToken':'synthetic','endpoint':'https://unreachable.example/school-cloud',
      'verifiedAccess':{'expiresAt':DateTime.now().add(const Duration(days:1)).millisecondsSinceEpoch,'success':true,'allowed':true,'schoolId':school,'uid':'restore-admin'}})});
    await WindowsRuntimeFlags.setLocalStorageEnabled(true);
    final root=await Directory.systemTemp.createTemp('vs-offline-restore-');
    await db.changeLocalStorageLocation(root.path);
    if(WindowsLocalStorage.sqliteEnabled) {
      final sql=await WindowsLocalStorage.sqliteFile(), legacy=await WindowsLocalStorage.databaseFile();
      if(!await sql.exists() && await legacy.exists())await db.migrateLocalDatabaseToSqlite(approved:true);
    }
    await db.switchProfile('restore-${DateTime.now().microsecondsSinceEpoch}',identity:{'schoolId':school,'schoolSyncId':school});
  });
  tearDown(() async {await db.resetVolatileSession();});
  Future<String> deletion(String collection) async {
    final ref=db.collection(collection).doc('original');
    await ref.set({'schoolId':school,'name':'synthetic','capturedAt':1791500000123});
    await ref.delete();
    return (await db.collection('_windows_local_deletions').get()).docs.single.id;
  }
  test('offline restore preserves delete operation and timestamp; restart and real ACK order',() async {
    final id=await deletion('school_notices'), profile=db.activeProfileId;
    final before=(await db.collection('_windows_firebase_outbox').get()).docs.single.data();
    await db.requestLocalRestore(id,approved:true);
    expect((await db.collection('school_notices').doc('original').get()).data()?['capturedAt'],1791500000123);
    expect((await db.collection('_windows_firebase_outbox').get()).docs.single.data(),before);
    final intent=(await db.collection('_windows_recycle_requests').get()).docs.single.data();
    expect(intent['state'],'awaitingDeleteAck');
    await expectLater(db.requestLocalRestore(id,approved:true),throwsStateError);
    await expectLater(db.collection('school_notices').doc('original').update({'name':'newer'}),throwsStateError);
    await db.applySyncedDocument(db.collection('school_notices').doc('original'),null);
    expect((await db.collection('school_notices').doc('original').get()).exists,true);
    await db.resetVolatileSession();await db.switchProfile('away');
    await db.switchProfile(profile,identity:{'schoolId':school,'schoolSyncId':school});
    expect((await db.collection('_windows_recycle_requests').get()).docs.single.data()['operationId'],intent['operationId']);
    await expectLater(db.finishLocalRestore(id,expectedDeletedRevision:'deleted',restoredRevision:'restored'),throwsStateError);
    await WindowsPendingSchoolSync.flush(profileId:profile,send:(a,b,c,d)async{},sendVersioned:(row)async=>'deleted');
    expect((await db.collection('_windows_recycle_requests').get()).docs.single.data()['state'],'awaitingCloudRestore');
    await expectLater(db.finishLocalRestore(id,expectedDeletedRevision:'stale',restoredRevision:'restored'),throwsStateError);
    await db.finishLocalRestore(id,expectedDeletedRevision:'deleted',restoredRevision:'restored');
    expect((await db.collection('_windows_recycle_requests').get()).docs.single.data()['state'],'verified');
    expect((await db.collection('_windows_local_deletions').get()).docs.single.data()['operationId'],id);
    await db.applySyncedDocument(db.collection('school_notices').doc('original'),null);
    expect((await db.collection('school_notices').doc('original').get()).data()?['_syncRevision'],'restored');
    await db.applySyncedDocument(db.collection('school_notices').doc('original'),{'schoolId':school,'name':'synthetic','capturedAt':1791500000123,'_syncRevision':'restored','_syncUpdatedAt':200});
    await db.applySyncedDocument(db.collection('school_notices').doc('original'),null,tombstoneRevision:'deleted',tombstoneUpdatedAt:300);
    expect((await db.collection('school_notices').doc('original').get()).exists,true);
    await db.applySyncedDocument(db.collection('school_notices').doc('original'),null,tombstoneRevision:'new-delete',tombstoneUpdatedAt:301);
    expect((await db.collection('school_notices').doc('original').get()).exists,false);
  });
  test('financial snapshot stays hidden until protected authoritative restore ACK',() async {
    final id=await deletion('fee_payments');
    await db.requestLocalRestore(id,approved:true);
    expect((await db.collection('fee_payments').doc('original').get()).exists,false);
    expect((await db.collection('_windows_recycle_requests').get()).docs.single.data()['localVerified'],false);
    await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,send:(a,b,c,d)async{},sendVersioned:(row)async=>'fee-delete');
    await db.finishLocalRestore(id,expectedDeletedRevision:'fee-delete',restoredRevision:'fee-restore');
    expect((await db.collection('fee_payments').doc('original').get()).data()?['capturedAt'],1791500000123);
  });
  test('administrator approval, school binding and newer local records are mandatory',() async {
    final id=await deletion('school_notices');
    await expectLater(db.requestLocalRestore(id,approved:false),throwsStateError);
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(()=>db.collection('school_notices').doc('original').set({'schoolId':school,'name':'newer'}));
    await expectLater(db.requestLocalRestore(id,approved:true),throwsStateError);
    await db.switchProfile('foreign',identity:{'schoolId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','schoolSyncId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'});
    await expectLater(db.requestLocalRestore(id,approved:true),throwsStateError);
  });
}
