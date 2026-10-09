import '../lib/windows_document_templates.dart';
import '../lib/windows_sync_conflict_review.dart';
import '../lib/windows_connect/managed_school_session.dart';
import '../lib/windows_exam_service.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
import '../lib/windows_sync_recovery.dart';
import '../lib/sync_recovery_policy.dart';
import '../lib/windows_sync_control_center.dart';
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
 test('typed outage evidence is retryable while permission failure is retained for review', () async {
   expect(windowsSyncRecovery(TimeoutException('fixture')).kind, SyncFailureKind.timeout);
   expect(windowsSyncRecovery(const SocketException('fixture')).kind, SyncFailureKind.networkPath);
   await db.collection('fee_payments').doc('retained-payment').set({'amount':100});
   final before=(await db.collection('_windows_firebase_outbox').get()).docs.single.data();
   await expectLater(WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
     send:(a,b,c,d)async{},sendVersioned:(item)async=>throw CentralCloudException(502,'school_cloud',
       'Storage permission check failed',diagnosticCode:'SCRIPT_PERMISSION_DENIED')),throwsStateError);
   final retained=(await db.collection('_windows_firebase_outbox').get()).docs.single.data();
   expect(retained['operationId'],before['operationId']);expect(retained['data']['amount'],100);
   expect(retained['syncState'],'needsAttention');expect(retained['failureCategory'],'authorization');
   await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,send:(a,b,c,d)async=>fail('No automatic permission bypass'));
   expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty);
 });
 test('structural failure does not starve independent records or manufacture ACK', () async {
   await db.collection('students_directory').doc('a-broken').set({'name':'Retained'});
   await db.collection('students_directory').doc('b-working').set({'name':'Independent'});
   await expectLater(WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
     send:(a,b,c,d)async{},sendVersioned:(item)async {
       if(item['documentId']=='a-broken')throw CentralCloudException(502,'school_cloud','Storage review required',diagnosticCode:'SCRIPT_RECORD_VERIFY_FAILED');
       return 'verified-working-revision';
     }),throwsStateError);
   final queue=(await db.collection('_windows_firebase_outbox').get()).docs;
   expect(queue,hasLength(1));expect(queue.single.data()['documentId'],'a-broken');
   expect(queue.single.data()['syncState'],'needsAttention');
   expect((await db.collection('_windows_sync_receipts').get()).docs,hasLength(1));
   await db.collection('school_notices').doc('later-notice').set({'message':'New independent edit'});
   await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
     send:(a,b,c,d)async{},sendVersioned:(item)async {
       expect(item['documentId'],'later-notice');return 'verified-later-revision';
     });
   expect((await db.collection('_windows_firebase_outbox').get()).docs.single.data()['documentId'],'a-broken');
   expect((await db.collection('_windows_sync_receipts').get()).docs,hasLength(2));
 });
 test('shared storage identity error stops the batch after one failed request', () async {
   for (var i=0;i<3;i++) await db.collection('students_directory').doc('identity-$i').set({'name':'Retained'});
   var calls=0;
   await expectLater(WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
     send:(a,b,c,d)async{},sendVersioned:(item)async {
       calls++;
       throw CentralCloudException(502,'school_cloud','School storage identity mismatch',diagnosticCode:'SCRIPT_WORKBOOK_IDENTITY_MISMATCH');
     }),throwsStateError);
   expect(calls,1);expect((await db.collection('_windows_firebase_outbox').get()).docs,hasLength(3));
   expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty);
 });
 testWidgets('control center reports unknown connectivity and retains original queue', (tester) async {
   tester.view.physicalSize = const Size(1200, 1800);
   tester.view.devicePixelRatio = 1;
   addTearDown(tester.view.resetPhysicalSize);
   addTearDown(tester.view.resetDevicePixelRatio);
   await tester.runAsync(() async {
     await db.collection('fee_payments').doc('pending-preview').set({'amount':100});
     await WindowsSyncEngine.instance.refreshDetails();
     final font=FontLoader('ControlCenterPreview');
     font.addFont(File('assets/id_card_regular.ttf').readAsBytes().then((bytes)=>ByteData.sublistView(bytes)));
     await font.load();
   });
   final previewKey=GlobalKey();
   await tester.pumpWidget(RepaintBoundary(key:previewKey,child:MaterialApp(theme:ThemeData.dark().copyWith(textTheme:ThemeData.dark().textTheme.apply(fontFamily:'ControlCenterPreview')),home:const WindowsSyncControlCenter())));
   await tester.runAsync(() => WindowsSyncEngine.instance.refreshDetails());
   await tester.pumpAndSettle();
   expect(find.text('Sync & Backup Control Center'),findsOneWidget);
   expect(find.text('Not independently verified'),findsOneWidget);
   expect(find.text('Not yet verified'),findsWidgets);
   final pending=await tester.runAsync(()=>db.collection('_windows_firebase_outbox').get());
   expect(pending!.docs,hasLength(1));
   await tester.runAsync(() async {
     final boundary=previewKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
     final image=await boundary.toImage(pixelRatio:1).timeout(const Duration(seconds:15));
     try {
       final bytes=await image.toByteData(format:ui.ImageByteFormat.png).timeout(const Duration(seconds:15));
       final target=File('build/sync-control-preview/synthetic-test-school.png');
       await target.parent.create(recursive:true);
       await target.writeAsBytes(bytes!.buffer.asUint8List(),flush:true);
     } finally {image.dispose();}
   });
   await tester.pumpWidget(const SizedBox());
 });
 test('legacy queue binding preserves its original operation ID across failed retries', () async {
   final row=db.collection('_windows_firebase_outbox').doc('legacy-operation');
   await row.set({'collection':'teachers_directory','documentId':'retained-teacher','operation':'set',
     'operationId':'existing-operation-123','data':{'name':'Retained fixture'},'syncState':'pending'});
   for(var n=0;n<2;n++) {
     await expectLater(WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
       send:(a,b,c,d)async{},sendVersioned:(item)async{
         expect(item['operationId'],'existing-operation-123');expect(item['schoolId'],school);
         throw StateError('Isolated network failure');
       }),throwsStateError);
     expect((await row.get()).data()?['operationId'],'existing-operation-123');
     expect((await row.get()).data()?['data'],{'name':'Retained fixture'});
   }
 });
 test('performance percentiles retain at most 256 real measurements', () {
   final engine=WindowsSyncEngine.instance;
   for(var n=0;n<300;n++)engine.recordLocalSave('boundedFixture',n);
   final summary=engine.performanceSummary['boundedFixtureSaveMicros'] as Map;
   expect(summary['samples'],256);expect(summary['p50'],172);expect(summary['p95'],287);
 });
 test('safe queue diagnostics preserve rows and exclude payloads, credentials, paths and record identifiers', () async {
   final records=db.collection('_windows_firebase_outbox');
   const ref='2c564c78-1738-429c-bf1b-4d09ba3a42b6';
   await records.doc('PRIVATE_QUEUE_ID').set({'collection':'school_expenses','documentId':'PRIVATE_RECORD_ID',
     'operationId':'original-operation-123','baseCloudRevision':'retained-revision','syncState':'conflict','queuedAt':1,
     'data':{'name':'PRIVATE_STUDENT','password':'PRIVATE_PASSWORD'},'localPath':'PRIVATE_PATH',
     'lastError':'HTTP 409 [OPERATION_ID_CONFLICT] Ref: $ref. PRIVATE_RESPONSE'});
   final documents=db.collection('_windows_document_outbox');
   await documents.doc('PRIVATE_DOCUMENT').set({'syncState':'unexpected_PRIVATE_STATE',
     'operationId':'INVALID_PRIVATE_TOKEN@x','data':{'token':'PRIVATE_TOKEN'},'lastError':'[SCRIPT_PRIVATE_SECRET] PRIVATE_RESPONSE'});
   final beforeRecords=jsonEncode((await records.get()).docs.single.data());
   final beforeDocuments=jsonEncode((await documents.get()).docs.single.data());
   final report=await WindowsSyncEngine.instance.safeQueueDiagnostics();
   expect(report['pendingCount'],2);expect(report['schoolId'],school);
   final items=report['items'] as List;
   expect(items.first['operationId'],'original-operation-123');
   expect(items.first['code'],'OPERATION_ID_CONFLICT');expect(items.first['referenceId'],ref);
   expect(items.first['httpStatus'],409);expect(items.last['state'],'unknown');
   expect(jsonEncode(report),isNot(contains('PRIVATE')));
   expect(jsonEncode((await records.get()).docs.single.data()),beforeRecords);
   expect(jsonEncode((await documents.get()).docs.single.data()),beforeDocuments);
 });
 test('automatic retry starts promptly and exponentially backs off without high-frequency polling', () {
   expect(WindowsSyncEngine.reconciliationInterval, const Duration(minutes:4));
   expect(WindowsSyncEngine.retryDelayForFailure(1), const Duration(seconds:5));
   expect(WindowsSyncEngine.retryDelayForFailure(2), const Duration(seconds:10));
   expect(WindowsSyncEngine.retryDelayForFailure(100), const Duration(minutes:5));
   expect(WindowsSyncEngine.retryDelayForFailure(1, quotaLimited:true), const Duration(minutes:1));
   expect(WindowsSyncEngine.retryDelayForFailure(100, quotaLimited:true), const Duration(minutes:15));
 });
 test('managed exam saves persist, enqueue automatically and retain legacy history without overwriting', () async {
   await db.collection('_local_exam_center_exams').doc('legacy').set({'examId':'legacy','examName':'Retained old exam'});
   final created=await WindowsExamService.request({'action':'save_exam','examId':'durable','examName':'Unit Test','subjects':['Maths'],'fullMarks':50,'passMarks':20,'isFinal':false});
   expect(created['success'],true);expect(created['cloudSyncPending'],true);expect(created['sessionOnly'],false);
   await WindowsExamService.request({'action':'save_exam_result','examId':'durable','studentId':'own','marks':{'Maths':35},'result':'PASS'});
   final queue=(await db.collection('_windows_firebase_outbox').get()).docs.map((d)=>d.data()['collection']).toSet();
   expect(queue,containsAll(['exams','exam_center_results']));
   expect((await db.collection('_windows_exam_pending').get()).docs,isEmpty);
   final origin=db.activeProfileId;
   await db.resetVolatileSession();await db.switchProfile('exam-away');
   await db.switchProfile(origin,identity:{'schoolId':school,'schoolSyncId':school});
   final reopened=await WindowsExamService.request({'action':'list_exam_center'});
   expect((reopened['exams'] as List).length,2);expect((reopened['results'] as List).single['marks'],{'Maths':35});
   expect((await db.collection('_local_exam_center_exams').doc('legacy').get()).exists,true);
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
 test('attendance and financial mutations drain before media with verified ACKs',()async{
  for(final collection in ['documents','school_notices','fee_payments','attendance_records']) {
   await db.collection(collection).doc('priority').set({'value':1});
  }
  final sent=<String>[];
  await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
    send:(c,id,op,data)async=>sent.add(c));
  expect(sent,['attendance_records','fee_payments','school_notices','documents']);
  expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
 });
 test('conflict retains local copy and stops automatic retry while another school is inaccessible',()async{
  await db.collection('school_expenses').doc('expense').set({'amount':100});
  final origin=db.activeProfileId;
  final cloud=CentralSchoolCloud(endpoint:'https://school.example/api',client:MockClient((_)async=>
    http.Response(jsonEncode({'success':false,'message':'Record revision conflict'}),409)));
  await expectLater(WindowsPendingSchoolSync.flush(profileId:origin,send:(a,b,c,d)async{},sendVersioned:(item)async{
    await cloud.send('POST',Uri.parse(cloud.endpoint),body:{'action':'managed/records'});
    throw StateError('A failed request must never ACK');
  }),throwsStateError);
  cloud.close();
  final item=(await db.collection('_windows_firebase_outbox').get()).docs.single.data();expect(item['syncState'],'conflict');
  await WindowsPendingSchoolSync.flush(profileId:origin,send:(a,b,c,d)async=>fail('Conflict must not overwrite'));expect((await db.collection('school_expenses').doc('expense').get()).data()?['amount'],100);
  await db.switchProfile('B',identity:{'schoolSyncId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'});
  await expectLater(WindowsPendingSchoolSync.flush(profileId:origin,send:(a,b,c,d)async=>fail('No cross school send')),throwsStateError);
 });
 test('retained school A references cannot read or derive queries after switching school',()async{
  final collection=db.collection('students_directory'),ref=collection.doc('own'),query=collection.where('name',isEqualTo:'A');
  await ref.set({'name':'A'});final origin=db.activeProfileId;
  final stream=StreamIterator(query.snapshots());expect(await stream.moveNext(),true);
  await db.switchProfile('reference-school-B',identity:{'schoolSyncId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'});
  expect(await stream.moveNext(),false);await stream.cancel();
  await expectLater(ref.get(),throwsStateError);await expectLater(query.get(),throwsStateError);
  expect(()=>collection.doc('new'),throwsStateError);expect(()=>collection.where('name',isEqualTo:'B'),throwsStateError);
  await db.switchProfile(origin,identity:{'schoolId':school,'schoolSyncId':school});
  expect((await ref.get()).data()?['name'],'A');
 });
 test('lazy document cache survives restart and never fetches unchanged file twice',()async{
  var reads=0;final bytes=Uint8List.fromList(utf8.encode('%PDF-1.4\nrepresentative cached document\n%%EOF'));
  final record={'schoolId':school,'fileId':'drive-test-${DateTime.now().microsecondsSinceEpoch}','documentRevision':'revision','originalPath':jsonEncode({'documents':[{'fileUrl':'https://drive.google.com/file/d/cloud/view'}]}),'localPath':'bad\u0000path'};
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
 test('17 pending operations survive 503 and lost ACK; retry keeps IDs and deduplicates remote commits',()async{
  for(var i=0;i<17;i++){
   await db.collection('students_directory').doc('pending-$i').set({'name':'Test pupil $i'});
  }
  final profile=db.activeProfileId;
  final before=(await db.collection('_windows_firebase_outbox').get()).docs;
  expect(before.length,17);
  final ids=before.map((d)=>d.data()['operationId']).toSet();
  await expectLater(WindowsPendingSchoolSync.flush(profileId:profile,
   send:(a,b,c,d)async=>fail('versioned path only'),
   sendVersioned:(item)async=>throw const HttpException('Central school API failed (HTTP 503)')),
   throwsA(isA<HttpException>()));
  await db.switchProfile('other-school',identity:{'schoolSyncId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'});
  expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
  await db.switchProfile(profile,identity:{'schoolSyncId':school,'schoolId':school});
  var retained=(await db.collection('_windows_firebase_outbox').get()).docs;
  expect(retained.length,17);
  expect(retained.map((d)=>d.data()['operationId']).toSet(),ids);
  final remote=<String,String>{};var lostAck=true;var commits=0;
  Future<String> publish(Map<String,dynamic> item)async{
   expect(item['schoolId'],school);
   final id=item['operationId'] as String;
   if(!remote.containsKey(id)){remote[id]='ack-$id';commits++;}
   if(lostAck){lostAck=false;throw const HttpException('ACK response lost');}
   return remote[id]!;
  }
  await expectLater(WindowsPendingSchoolSync.flush(profileId:profile,send:(a,b,c,d)async{},sendVersioned:publish),throwsA(isA<HttpException>()));
  expect((await db.collection('_windows_firebase_outbox').get()).docs.length,17);
  await WindowsPendingSchoolSync.flush(profileId:profile,send:(a,b,c,d)async{},sendVersioned:publish);
  expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
  expect(commits,17);expect(remote.keys.toSet(),ids);
  expect((await db.collection('students_directory').get()).docs.length,17);
 });
 test('crash generations recover without silently overwriting irrecoverable school data',()async{
  await db.collection('students_directory').doc('retained').set({'name':'Retained'});
    if (WindowsLocalStorage.sqliteEnabled &&
        await (await WindowsLocalStorage.sqliteFile()).exists()) {
      final sql = await WindowsLocalStorage.sqliteFile();
      await db.resetVolatileSession();
      final original = await sql.readAsBytes();
      final corrupt = utf8.encode('truncated SQLite recovery evidence');
      try {
        await sql.writeAsBytes(corrupt, flush: true);
        await expectLater(
            db
                .collection('students_directory')
                .doc('unsafe')
                .set({'name': 'Must not write'}),
            throwsStateError);
        expect(await sql.readAsBytes(), corrupt);
      } finally {
        await db.resetVolatileSession();
        await sql.writeAsBytes(original, flush: true);
      }
      expect(
          (await db.collection('students_directory').doc('retained').get())
              .data()?['name'],
          'Retained');
      expect(
          (await db.collection('students_directory').doc('unsafe').get())
              .exists,
          false);
      return;
    }
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
  await tester.runAsync(()async{await db.collection('teachers_directory').doc('status-teacher').set({'name':'Pending teacher'});await engine.refreshDetails();});engine.state.value=SchoolCloudState.localReady;
  await tester.pumpWidget(const MaterialApp(home:Scaffold(body:SingleChildScrollView(child:WindowsSyncStatusCard()))));
  await tester.pump();expect(find.text('Pending: 1'),findsOneWidget);expect(find.textContaining('1 items pending'),findsOneWidget);
  final item=(await tester.runAsync(()=>db.collection('_windows_firebase_outbox').get()))!.docs.single;
  await tester.runAsync(()async{await item.reference.set({'syncState':'conflict','lastError':'Record revision conflict'},const SetOptions(merge:true));await engine.refreshDetails();});await tester.pump();expect(find.textContaining('1 items need attention'),findsOneWidget);
  await tester.tap(find.text('Details'));await tester.pumpAndSettle();expect(find.textContaining('status-teacher: conflict'),findsOneWidget);
  await tester.tap(find.text('Close'));await tester.pumpAndSettle();
  engine.state.value=SchoolCloudState.syncing;await tester.pump();
  expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton,'Sync Now')).onPressed,isNull);
  await tester.runAsync(()async{await item.reference.set({'syncState':'pending'},const SetOptions(merge:true));
  await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,send:(a,b,c,d)async{},sendVersioned:(item)async=>'acknowledged-revision');
  await engine.refreshDetails();});engine.lastSuccessfulSync=DateTime(2026,10,6,10);engine.state.value=SchoolCloudState.synced;
  await tester.pump();expect(find.text('Pending: 0'),findsOneWidget);expect(find.textContaining('Sync Status • Synced'),findsOneWidget);
  expect(find.textContaining('2026-10-06'),findsOneWidget);
  await tester.pumpWidget(const SizedBox());engine.lastSuccessfulSync=null;engine.state.value=SchoolCloudState.localReady;
 });

  test(
      'a typed 409 retains its row but does not starve an independent pending record',
      () async {
    await db
        .collection('fee_payments')
        .doc('conflicted')
        .set({'schoolId': school, 'amount': 100});
    await db
        .collection('school_notices')
        .doc('independent')
        .set({'schoolId': school, 'title': 'retained'});
    final origin = db.activeProfileId;
    final sent = <String>[];
    await expectLater(
        WindowsPendingSchoolSync.flush(
            profileId: origin,
            send: (a, b, c, d) async {},
            sendVersioned: (item) async {
              sent.add(item['collection'] as String);
              if (item['collection'] == 'fee_payments')
                throw CentralCloudException(
                    409, 'school_cloud', 'UPPERCASE diagnostic',
                    diagnosticCode: 'RECORD_REVISION_CONFLICT');
              return 'verified-revision';
            }),
        throwsA(isA<CentralCloudException>()));
    expect(sent, containsAll(['fee_payments', 'school_notices']));
    final retained =
        (await db.collection('_windows_firebase_outbox').get()).docs.single;
    expect(retained.data()['syncState'], 'conflict');
    expect(retained.data()['data']['amount'], 100);
    expect(
        (await db.collection('_windows_sync_receipts').get())
            .docs
            .single
            .data()['recordRevision'],
        'verified-revision');
  });
  test(
      'conflict edits retain the original operation and stay blocked until explicit review',
      () async {
    await db
        .collection('fee_payments')
        .doc('reviewed')
        .set({'schoolId': school, 'amount': 100});
    final queued =
        (await db.collection('_windows_firebase_outbox').get()).docs.single;
    await queued.reference.update({'syncState': 'conflict'});
    final old = (await queued.reference.get()).data()!;
    await db.collection('fee_payments').doc('reviewed').update({'amount': 150});
    final current = (await queued.reference.get()).data()!;
    expect(current['syncState'], 'conflict');
    expect(current['operationId'], isNot(old['operationId']));
    expect(
        (await db
                .collection('_windows_sync_conflict_history')
                .doc(old['operationId'])
                .get())
            .data()?['data']['amount'],
        100);
    await WindowsPendingSchoolSync.flush(
        profileId: db.activeProfileId,
        send: (a, b, c, d) async => fail('Conflict auto-sent'));
  });
  test(
      'explicit financial review creates a new CAS operation and retains both versions without ACK',
      () async {
    await db
        .collection('fee_payments')
        .doc('reviewed')
        .set({'schoolId': school, 'amount': 100});
    final row =
        (await db.collection('_windows_firebase_outbox').get()).docs.single;
    await row.reference.update({'syncState': 'conflict'});
    final old = (await row.reference.get()).data()!;
    final remote = {
      'schoolId': school,
      'id': 'reviewed',
      'amount': 200,
      '_syncRevision': 'cloud-revision'
    };
    await db.enqueueReviewedConflict(
        queueId: row.id,
        expected: old,
        remote: remote,
        choice: 'local',
        reason: 'Verified receipt comparison');
    final current = (await row.reference.get()).data()!;
    expect(current['data']['amount'], 100);
    expect(current['baseCloudRevision'], 'cloud-revision');
    expect(current['operationId'], isNot(old['operationId']));
    expect(current['syncState'], 'pending');
    final audit =
        (await db.collection('_windows_sync_resolution_history').get())
            .docs
            .single
            .data();
    expect(audit['remote']['amount'], 200);
    expect(audit['local']['operationId'], old['operationId']);
    expect(audit['status'], 'awaitingCloudAck');
    expect((await db.collection('_windows_sync_receipts').get()).docs, isEmpty);
    await expectLater(
        db.enqueueReviewedConflict(
            queueId: row.id,
            expected: old,
            remote: remote,
            choice: 'local',
            reason: 'duplicate'),
        throwsStateError);
  });
  test(
      'review rejects foreign school, foreign record, unverified revision and missing explicit decision',
      () async {
    await db
        .collection('fee_payments')
        .doc('guarded')
        .set({'schoolId': school, 'amount': 100});
    final row =
        (await db.collection('_windows_firebase_outbox').get()).docs.single;
    await row.reference.update({'syncState': 'conflict'});
    final old = (await row.reference.get()).data()!;
    for (final edit in [
      {'schoolId': 'foreign'},
      {'id': 'other'},
      {'_syncRevision': ''},
      {'_syncDeleted': true}
    ]) {
      await expectLater(
          db.enqueueReviewedConflict(
              queueId: row.id,
              expected: old,
              remote: {
                'schoolId': school,
                'id': 'guarded',
                '_syncRevision': 'cloud',
                ...edit
              },
              choice: 'cloud',
              reason: 'review'),
          throwsStateError);
    }
    await expectLater(
        db.enqueueReviewedConflict(
            queueId: row.id,
            expected: old,
            remote: {
              'schoolId': school,
              'id': 'guarded',
              '_syncRevision': 'cloud'
            },
            choice: 'cloud',
            reason: ''),
        throwsStateError);
    expect(migrationJsonValue((await row.reference.get()).data()), migrationJsonValue(old));
  });
  test(
      'a newer local edit invalidates the operator review before it can replace data',
      () async {
    await db
        .collection('fee_payments')
        .doc('stale-review')
        .set({'schoolId': school, 'amount': 100});
    final row =
        (await db.collection('_windows_firebase_outbox').get()).docs.single;
    await row.reference.update({'syncState': 'conflict'});
    final old = (await row.reference.get()).data()!;
    await db
        .collection('fee_payments')
        .doc('stale-review')
        .update({'amount': 300});
    await expectLater(
        db.enqueueReviewedConflict(
            queueId: row.id,
            expected: old,
            remote: {
              'schoolId': school,
              'id': 'stale-review',
              '_syncRevision': 'cloud',
              'amount': 200
            },
            choice: 'cloud',
            reason: 'stale'),
        throwsStateError);
    expect(
        (await db.collection('fee_payments').doc('stale-review').get())
            .data()?['amount'],
        300);
  });
  test(
      'replacing conflicted document metadata retains the original and cannot auto-upload',
      () async {
    final ref = db.collection('_windows_document_outbox').doc('file');
    await ref.set({
      'schoolId': school,
      'documentRevision': 'original',
      'localPath': 'original-file',
      'syncState': 'conflict'
    });
    await ref.set({
      'schoolId': school,
      'documentRevision': 'newer',
      'localPath': 'new-file',
      'syncState': 'pending'
    });
    expect((await ref.get()).data()?['syncState'], 'conflict');
    expect(
        (await db.collection('_windows_sync_conflict_history').get())
            .docs
            .single
            .data()['localPath'],
        'original-file');
  });
  test(
      'conflict recognition does not treat storage readiness or arbitrary 409 as record conflicts',
      () {
    expect(
        isRecordSyncConflict(CentralCloudException(
            409, 'school_cloud', 'conflict',
            diagnosticCode: 'SCHOOL_STORAGE_NOT_CONNECTED')),
        false);
    expect(
        isRecordSyncConflict(CentralCloudException(
            409, 'school_cloud', 'localized',
            diagnosticCode: 'OPERATION_ID_CONFLICT')),
        true);
    expect(isRecordSyncConflict(StateError('school identity conflict')), false);
  });
 test('isolated TEST build refuses original server before authentication or queue writes',(){
   const endpoint='https://saarthi-sync-v2-test.onrender.com/school-cloud';
   expect(()=>ManagedSchoolSession.verifyBuildEndpoint('https://saarthi-oauth-staging.onrender.com/school-cloud',configured:endpoint),throwsA(isA<CentralCloudException>().having((e)=>e.diagnosticCode,'code','TEST_ENVIRONMENT_MISMATCH')));
   ManagedSchoolSession.verifyBuildEndpoint(endpoint,configured:endpoint);
 });

 test('automatic ID publication skips a retained file conflict before credential changes or QR generation',()async{
   await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(()=>db.collection('students_directory').doc('retained-id').set({'schoolId':school,'name':'Retained','mobileLinkToken':'original-token'}));
   final id=WindowsBackendBridge.publishedIdCardOwnerId('student','retained-id');
   final queue=db.collection('_windows_document_outbox').doc(id);
   await queue.set({'schoolId':school,'documentRevision':'original','localPath':'original-file','syncState':'conflict'});
   final before=(await queue.get()).data();
   await WindowsDocumentTemplates.publishChangedIdCards();
   expect((await queue.get()).data(),before);
   expect((await db.collection('students_directory').doc('retained-id').get()).data()?['mobileLinkToken'],'original-token');
 });
 testWidgets('production conflict review opens read-only with no automatic financial choice',(tester)async{
   await tester.pumpWidget(MaterialApp(home:Builder(builder:(context)=>Scaffold(body:TextButton(onPressed:()=>showWindowsConflictReview(context,{'id':'pending','collection':'fee_payments','schoolId':school,'syncState':'conflict','data':{'amount':100}}),child:const Text('Open review'))))));
   await tester.tap(find.text('Open review'));await tester.pumpAndSettle();
   expect(find.text('Cloud verification: not performed'),findsOneWidget);
   expect(find.text('Use local version'),findsNothing);
   expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton,'Review and queue')).onPressed,isNull);
   final pending=await tester.runAsync(()=>db.collection('_windows_firebase_outbox').get());
   expect(pending!.docs,isEmpty);
   await tester.pumpWidget(const SizedBox.shrink());
 });

 test('reviewed conflict retains both versions and operation after durable reopen',()async{
   await db.collection('fee_payments').doc('restart-review').set({'amount':100,'schoolId':school});
   final row=(await db.collection('_windows_firebase_outbox').get()).docs.single;
   await row.reference.update({'syncState':'conflict'});
   final expected=(await row.reference.get()).data()!;
   await db.enqueueReviewedConflict(queueId:row.id,expected:expected,remote:{'schoolId':school,'id':'restart-review','_syncRevision':'cloud-before-review','amount':200},choice:'local',reason:'Synthetic restart verification');
   final queued=(await row.reference.get()).data()!;
   final origin=db.activeProfileId;
   await db.resetVolatileSession();await db.switchProfile('review-away');
   await db.switchProfile(origin,identity:{'schoolId':school,'schoolSyncId':school});
   expect(migrationJsonValue((await row.reference.get()).data()),migrationJsonValue(queued));
   expect(migrationJsonValue((await db.collection('_windows_sync_conflict_history').get()).docs.single.data()),migrationJsonValue(expected));
   expect((await db.collection('_windows_sync_resolution_history').get()).docs.length,1);
   expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty);
 });

}
