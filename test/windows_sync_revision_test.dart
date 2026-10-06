import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import '../lib/windows_settings_panel.dart';
import '../lib/school_cloud_engine.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_local_storage.dart';
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
  FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key:jsonEncode({'managed':true,'schoolId':school,'uid':'A','folderId':'managed',
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
  final simultaneous=await Future.wait([WindowsBackendBridge.documentBytes(record,fetch:fetch),WindowsBackendBridge.documentBytes(record,fetch:fetch)]);expect(simultaneous.every((b)=>base64Encode(b)==base64Encode(bytes)),true);expect(reads,1);
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
 test('crash generations recover without silently overwriting irrecoverable school data',()async{
  await db.collection('students_directory').doc('retained').set({'name':'Retained'});
  final file=await WindowsLocalStorage.databaseFile(),pending=File('${(await WindowsLocalStorage.databaseFile()).path}.pending'),backup=File('${(await WindowsLocalStorage.databaseFile()).path}.bak');
  final original=await file.readAsString(),oldBackup=await backup.exists()?await backup.readAsString():null;
  try{
   await pending.writeAsString(original,flush:true);await file.delete();
   expect((await db.collection('students_directory').doc('retained').get()).data()?['name'],'Retained');
   await pending.delete();await backup.writeAsString(original,flush:true);
   expect((await db.collection('students_directory').doc('retained').get()).data()?['name'],'Retained');
   await file.writeAsString('{truncated',flush:true);await backup.writeAsString('{truncated',flush:true);
   await expectLater(db.collection('students_directory').doc('unsafe').set({'name':'Must not write'}),throwsStateError);
   expect(await file.readAsString(),'{truncated');
  }finally{
   await file.writeAsString(original,flush:true);if(await pending.exists())await pending.delete();
   if(oldBackup!=null){await backup.writeAsString(oldBackup,flush:true);}else if(await backup.exists()){await backup.delete();}
  }
 });

 testWidgets('Settings Sync reflects durable pending, conflict, running and acknowledged states',(tester)async{
  final engine=WindowsSyncEngine.instance;
  await db.collection('teachers_directory').doc('status-teacher').set({'name':'Pending teacher'});
  await engine.refreshDetails();engine.state.value=SchoolCloudState.localReady;
  await tester.pumpWidget(const MaterialApp(home:Scaffold(body:SingleChildScrollView(child:WindowsSyncStatusCard()))));
  await tester.pump();expect(find.text('Pending: 1'),findsOneWidget);expect(find.textContaining('1 items pending'),findsOneWidget);
  final item=(await db.collection('_windows_firebase_outbox').get()).docs.single;
  await item.reference.set({'syncState':'conflict','lastError':'Record revision conflict'},const SetOptions(merge:true));
  await engine.refreshDetails();await tester.pump();expect(find.textContaining('1 items need attention'),findsOneWidget);
  await tester.tap(find.text('Details'));await tester.pumpAndSettle();expect(find.textContaining('status-teacher: conflict'),findsOneWidget);
  await tester.tap(find.text('Close'));await tester.pumpAndSettle();
  engine.state.value=SchoolCloudState.syncing;await tester.pump();
  expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton,'Sync Now')).onPressed,isNull);
  await item.reference.set({'syncState':'pending'},const SetOptions(merge:true));
  await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,send:(a,b,c,d)async{},sendVersioned:(item)async=>'acknowledged-revision');
  await engine.refreshDetails();engine.lastSuccessfulSync=DateTime(2026,10,6,10);engine.state.value=SchoolCloudState.synced;
  await tester.pump();expect(find.text('Pending: 0'),findsOneWidget);expect(find.textContaining('Sync Status • Synced'),findsOneWidget);
  expect(find.textContaining('2026-10-06'),findsOneWidget);
  await tester.pumpWidget(const SizedBox());engine.lastSuccessfulSync=null;engine.state.value=SchoolCloudState.localReady;
 });

}
