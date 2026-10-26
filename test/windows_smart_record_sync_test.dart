import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/platform/platform_config.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_record_change_policy.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_sync_schedule.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/windows_sync_recovery.dart';
import '../lib/windows_backend_bridge.dart';

void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';final db=FirebaseFirestore.instance;
 Future<QueryDocumentSnapshot<Map<String,dynamic>>> pending()async=>(await db.collection('_windows_firebase_outbox').get()).docs.single;
 Map<String,dynamic> canonical(String revision,{String name='Mahit Das'})=>{
   'id':'T1','schoolId':school,'teacherId':'teacher-1','name':name,'photoUrl':'https://drive.google.com/file/d/photo/view',
   'photoFileId':'photo','phone':'9999999999','_syncRevision':revision,
   '_syncOperationId':'server-operation-$revision','_syncFieldRevisions':{'name':revision,'photoUrl':revision,'phone':revision},
 };
 setUp(()async{
  FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key:jsonEncode({
   'managed':true,'schoolId':school,'uid':'synthetic-rules','folderId':'managed',
   'projectId':platformProjectId,'firebaseRefreshToken':'synthetic','endpoint':'https://unreachable.example/school-cloud',
  })});
  await WindowsRuntimeFlags.setLocalStorageEnabled(false);
  await db.switchProfile('smart-rules-${DateTime.now().microsecondsSinceEpoch}',identity:{'schoolId':school,'schoolSyncId':school});
 });
 test('name-only edit of verified old record retains the same ID and queues no unchanged photo',()async{
   final ref=db.collection('teachers_directory').doc('T1');
   await db.applySyncedDocument(ref,canonical('r1'));
   await ref.update({'name':'Mohit Das','updatedAt':FieldValue.serverTimestamp()});
   final q=(await pending()).data(),patch=q['fieldPatch'] as Map;
   expect(q['documentId'],'T1');expect(patch['set']['name'],'Mohit Das');
   expect((patch['set'] as Map).containsKey('photoUrl'),false);
   expect(patch['before']['name']['revision'],'r1');
   expect((await ref.get()).data()?['photoFileId'],'photo');
 });
 test('photo can be added at any later time, without replacing other fields',()async{
   final base={...canonical('r1'),'photoUrl':'','createdAt':'2000-01-01'}..remove('photoFileId');
   final patch=buildRecordFieldPatch('teachers_directory',base,{...base,'photoUrl':'data:image/png;base64,AQID'});
   expect((patch!['set'] as Map).keys,['photoUrl']);
   expect(patch['remove'],isEmpty);expect(patch['before']['photoUrl']['exists'],true);
 });
 test('all modules ignore repeated Save-generated timestamps when business values do not change',()async{
   for(final collection in ['school_config','fee_settings','school_expenses','school_notices']){
    final ref=db.collection(collection).doc('same');
    await ref.set({'title':'Same','updatedAt':FieldValue.serverTimestamp()});
    final rows=(await db.collection('_windows_firebase_outbox').get()).docs;
    final q=rows.singleWhere((r)=>r.data()['collection']==collection),before=q.data();
    await ref.update({'title':'Same','updatedAt':FieldValue.serverTimestamp()});
    expect(migrationJsonValue((await q.reference.get()).data()),migrationJsonValue(before));
   }
 });
 test('wire request is frozen durably; changed local Save invalidates a stale binding',()async{
   final ref=db.collection('teachers_directory').doc('T1');await db.applySyncedDocument(ref,canonical('r1'));
   await ref.update({'name':'Mohit Das'});final q=await pending(),first=q.data();
   final wire={'schoolId':school,fieldPatchEnvelope:first['fieldPatch']};
   final bound=await db.bindOutboxWireData(q.reference,first,wire,'fieldPatch1');
   await db.resetVolatileSession();
   expect(migrationJsonValue((await q.reference.get()).data()),migrationJsonValue(bound));
   await ref.update({'name':'Newer user edit'});
   expect(await db.bindOutboxWireData(q.reference,bound!,wire,'fieldPatch1'),isNull);
   expect((await q.reference.get()).data()?['data']['name'],'Newer user edit');
 });
 test('real canonical ACK replaces data URL with verified media and gives future edits a baseline',()async{
   final ref=db.collection('teachers_directory').doc('T1');await ref.set({'teacherId':'teacher-1','name':'Mahit Das','photoUrl':'data:image/png;base64,AQID'});
   final q=await pending();await db.acknowledgeOutbox(q.reference,q.data(),revision:'r1',canonicalRecord:canonical('r1'));
   expect((await ref.get()).data()?['photoUrl'],startsWith('https://'));
   await ref.update({'name':'Mohit Das'});final item=(await pending()).data();
   expect(item['baseCloudRevision'],'r1');expect((item['fieldPatch']['set'] as Map).keys,['name']);
 });
 test('ACK during a newer Save preserves that edit and recomputes only its remaining delta',()async{
   final ref=db.collection('teachers_directory').doc('T1');await db.applySyncedDocument(ref,canonical('r1'));
   await ref.update({'name':'Mohit Das'});final old=await pending();
   await ref.update({'phone':'8888888888'});
   await db.acknowledgeOutbox(old.reference,old.data(),revision:'r2',canonicalRecord:canonical('r2',name:'Mohit Das'));
   final current=(await pending()).data();expect(current['data']['phone'],'8888888888');
   expect(current['baseCloudRevision'],'r2');expect((current['fieldPatch']['set'] as Map).keys,['phone']);
 });
 for(final collection in ['teachers_directory','students_directory','school_notices']){
  test('$collection competing new Add keeps the first cloud record and archives losing draft',()async{
   final ref=db.collection(collection).doc('same');final identity=collection=='students_directory'?'mobileStableId':'teacherId';
   await ref.set({identity:'local-person','name':'Later local draft'});final q=await pending();
   expect(q.data()['createIntent'],true);
   await db.recordOutboxConflict(q.reference,q.data(),{'id':'same','schoolId':school,identity:'first-person','name':'First committed',
     '_syncRevision':'winner','_syncOperationId':'first-cloud-operation'});
   expect((await q.reference.get()).exists,false);expect((await ref.get()).data()?['name'],'First committed');
   final history=(await db.collection('_windows_sync_conflict_history').get()).docs.single.data();
   expect(history['data']['name'],'Later local draft');
   expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty);
  });
 }
 test('explicit teacher deletion is not stuck behind an old edit conflict and retains cleanup receipt linkage',()async{
  final ref=db.collection('teachers_directory').doc('T1');await db.applySyncedDocument(ref,canonical('r1'));
  await ref.update({'name':'Local corrected'});var q=await pending();await q.reference.update({'syncState':'conflict'});
  await ref.delete();q=await pending();final original=q.data();expect(original['syncState'],'pending');
  expect(original['deletedRecordIdentity']['teacherId'],'teacher-1');
  await db.recordOutboxConflict(q.reference,original,canonical('r2'));
  final current=(await q.reference.get()).data()!;expect(current['syncState'],'pending');
  expect(current['operationId'],original['operationId']);expect(current['baseCloudRevision'],'r2');
  await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,send:(a,b,c,d)async{},sendVersioned:(_)async=>'deleted-r3');
  final deletion=(await db.collection('_windows_local_deletions').doc(original['operationId']).get()).data()!;
  expect(deletion['cloudDeletionVerified'],true);expect((await ref.get()).exists,false);
 });
 test('verified reconnect reopens exhausted network documents while retaining quota, conflicts and foreign work',()async{
  final queue=db.collection('_windows_document_outbox');
  for(final category in ['networkPath','timeout','quota','authorization','conflict']) {
   await queue.doc(category).set({'schoolId':school,'documentRevision':'original-$category',
    'syncState':category=='conflict'?'conflict':'needsAttention','failureCategory':category,
    'retryCount':8,'retryAtMillis':9999999999999,'localPath':'retained-file'});
  }
  await queue.doc('foreign').set({'schoolId':'other','syncState':'retry','failureCategory':'networkPath'});
  expect(await WindowsBackendBridge.resumeNetworkDocuments(db.activeProfileId,school),2);
  for(final category in ['networkPath','timeout','quota','authorization','conflict']) {
   final item=(await queue.doc(category).get()).data()!;
   expect(item['documentRevision'],'original-$category');expect(item['localPath'],'retained-file');
   expect(item['retryCount'],{'networkPath','timeout'}.contains(category)?0:8);
  }
  expect((await queue.doc('foreign').get()).data()?['syncState'],'retry');
  expect(networkRecoveryCandidate({'syncState':'needsAttention','failureCategory':'networkPath','retryCount':8}),true);
  for(final category in ['quota','authorization','unknown','validation','conflict']) {
   expect(networkRecoveryCandidate({'syncState':'needsAttention','failureCategory':category}),false);
  }
 });
 test('idle discovery waits one hour; fresh local work and reconnect work still enter immediately',(){
  final time=DateTime.utc(2026,1,1),watch=WindowsCloudChangeWatch();watch.succeeded(time);
  expect(watch.due(time.add(const Duration(minutes:59))),false);
  expect(watch.due(time.add(const Duration(hours:1))),true);
  expect(automaticWindowsSyncDue(now:time.add(const Duration(minutes:5)),lastAttempt:time,localMutation:false,pendingWork:false),false);
  expect(automaticWindowsSyncDue(now:time.add(const Duration(minutes:5)),lastAttempt:time,localMutation:true,pendingWork:false),true);
 });
}
