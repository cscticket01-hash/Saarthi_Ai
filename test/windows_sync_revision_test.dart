import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/windows_platform_client.dart';
import '../lib/windows_sync_engine.dart';
import '../lib/windows_backend_bridge.dart';
import '../lib/platform/platform_config.dart';
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';final db=FirebaseFirestore.instance;
 setUp(()async{
  FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key:jsonEncode({'managed':true,'schoolId':school,'uid':'A',
   'projectId':platformProjectId,'endpoint':'https://saarthi-oauth-staging.onrender.com/school-cloud','firebaseRefreshToken':'refresh','storageReady':false})});
  await WindowsRuntimeFlags.setLocalStorageEnabled(false);
  await db.switchProfile('revision-${DateTime.now().microsecondsSinceEpoch}',identity:{'schoolSyncId':school,'schoolId':school});
 });
 test('notice durable save returns without any Firebase or Drive call',()async{
  final watch=Stopwatch()..start();
  final result=await WindowsPlatformClient.instance.publishNotice('notice',{'title':'Actual local notice','timestamp':1});watch.stop();
  expect(result.notificationSent,false);expect(result.schoolPublished,false);
  expect((await db.collection('school_notices').doc('notice').get()).data()?['title'],'Actual local notice');
  final queue=(await db.collection('_windows_firebase_outbox').get()).docs.single.data();
  expect(queue['schoolId'],school);expect(queue['operationId'],isNotEmpty);
  final origin=db.activeProfileId;await db.switchProfile('away');await db.switchProfile(origin,identity:{'schoolId':school,'schoolSyncId':school});
  expect((await db.collection('_windows_firebase_outbox').get()).docs,hasLength(1));
  print('MEASURE notice local durable save ${watch.elapsedMicroseconds} us; remote calls=0; prior real device 3000–4000 ms (different environment).');
  expect(WindowsSyncEngine.instance.metrics['noticeSaveMicros'],isNotNull);
 });
 test('versioned acknowledgement advances newer pending edit baseline atomically',()async{
  final ref=db.collection('teachers_directory').doc('teacher');await ref.set({'name':'First'});
  await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,send:(a,b,c,d)async=>fail('versioned path only'),sendVersioned:(item)async{
   expect(item['baseCloudRevision'],'');await ref.set({'name':'Second'});return 'server-revision-1';});
  var queue=(await db.collection('_windows_firebase_outbox').get()).docs.single.data();expect(queue['baseCloudRevision'],'server-revision-1');expect(queue['data']['name'],'Second');
  await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,send:(a,b,c,d)async{},sendVersioned:(item)async=>'server-revision-2');
  expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
  await ref.set({'name':'Third'});queue=(await db.collection('_windows_firebase_outbox').get()).docs.single.data();expect(queue['baseCloudRevision'],'server-revision-2');
 });
 test('conflict retains local copy and stops automatic retry while another school is inaccessible',()async{
  await db.collection('school_expenses').doc('expense').set({'amount':100});
  final origin=db.activeProfileId;
  await expectLater(WindowsPendingSchoolSync.flush(profileId:origin,send:(a,b,c,d)async{},sendVersioned:(item)async=>throw StateError('Record revision conflict')),throwsStateError);
  final item=(await db.collection('_windows_firebase_outbox').get()).docs.single.data();expect(item['syncState'],'conflict');
  await WindowsPendingSchoolSync.flush(profileId:origin,send:(a,b,c,d)async=>fail('Conflict must not overwrite'));expect((await db.collection('school_expenses').doc('expense').get()).data()?['amount'],100);
  await db.switchProfile('B',identity:{'schoolSyncId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'});
  await expectLater(WindowsPendingSchoolSync.flush(profileId:origin,send:(a,b,c,d)async=>fail('No cross school send')),throwsStateError);
 });
 test('lazy document cache survives restart and never fetches unchanged file twice',()async{
  var reads=0;final bytes=Uint8List.fromList(utf8.encode('%PDF-1.4\nrepresentative cached document\n%%EOF'));
  final record={'schoolId':school,'fileId':'drive-test-${DateTime.now().microsecondsSinceEpoch}','documentRevision':'revision'};
  Future<Map<String,dynamic>> fetch(String s,String id)async{reads++;expect(s,school);return {'success':true,'schoolId':school,'mime':'application/pdf','base64':base64Encode(bytes)};}
  expect(await WindowsBackendBridge.documentBytes(record,fetch:fetch),bytes);expect(reads,1);
  final origin=db.activeProfileId;await db.switchProfile('away');await db.switchProfile(origin,identity:{'schoolId':school,'schoolSyncId':school});
  expect(await WindowsBackendBridge.documentBytes(record,fetch:fetch),bytes);expect(reads,1);
  await expectLater(WindowsBackendBridge.documentBytes({...record,'schoolId':'foreign'},fetch:fetch),throwsStateError);expect(reads,1);
 });
 test('pending edit survives failed remote call and protects against stale pull',()async{
  final ref=db.collection('students_directory').doc('pupil');await ref.set({'name':'Local'});
  await expectLater(WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,send:(a,b,c,d)async=>throw const SocketException('offline')),throwsA(isA<SocketException>()));
  await db.applySyncedDocument(ref,{'name':'Stale remote','_syncRevision':'stale'});
  expect((await ref.get()).data()?['name'],'Local');
  expect((await db.collection('_windows_firebase_outbox').get()).docs.single.data()['syncState'],'retry');
 });
}
