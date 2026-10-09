import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../lib/windows_connect/managed_school_session.dart';
import '../../lib/windows_pending_school_sync.dart';
import '../../lib/windows_local_firestore.dart';
import '../../lib/mobile/school_session.dart';
import '../../lib/mobile/attendance_store.dart';

// Opt-in hosted production-class tests against real isolated cloud, not a device UI.
void main() {
 TestWidgetsFlutterBinding.ensureInitialized();
 test('real existing Windows outbox -> Drive ACK -> actual mobile session -> cached restart',() async {
  const school='vs-db8afb01a3be46a983c8284714d06e5d';
  const endpoint='https://saarthi-sync-v2-test.onrender.com/school-cloud';
  if(Platform.environment['VS_TEST_CONNECT_CONFIRM']!=school||Platform.environment['GITHUB_ACTIONS']!='true')throw StateError('Explicit isolated TEST runner required');
  FlutterSecureStorage.setMockInitialValues({});
  final tmp=await Directory.systemTemp.createTemp('vs-isolated-engines-');
  final report=<String,dynamic>{'scope':'Hosted Windows production Dart classes, real TEST cloud; no Android OS or physical-device UI','schoolId':school};
  sqfliteFfiInit();
  final store=AttendanceStore(openDatabaseOverride:()=>databaseFactoryFfi.openDatabase('${tmp.path}/attendance.db',options:OpenDatabaseOptions(version:1,onCreate:(db,_)=>AttendanceStore.createSchema(db))));
  final transport=http.Client();
  try{
   final login=await ManagedSchoolSession.login(Platform.environment['VS_TEST_LOGIN_EMAIL']!,Platform.environment['VS_TEST_LOGIN_PASSWORD']!,endpoint:endpoint);
   expect(login['schoolId'],school);
   final db=FirebaseFirestore.instance;await db.changeLocalStorageLocation('${tmp.path}/windows');
   final profile='TEST-hosted-${Platform.environment['GITHUB_RUN_ID']}';
   await db.switchProfile(profile,identity:{'schoolId':school,'schoolSyncId':school});
   final id='synthetic-hosted-notice-${Platform.environment['GITHUB_RUN_ID']}';
   final clock=Stopwatch()..start();
   await db.collection('school_notices').doc(id).set({'schoolId':school,'syntheticTest':true,'title':'Actual Windows local-first TEST notice','timestamp':DateTime.now().millisecondsSinceEpoch});
   report['localSaveMs']=clock.elapsedMilliseconds;
   expect((await db.collection('_windows_firebase_outbox').get()).docs,hasLength(1));
   await expectLater(WindowsPendingSchoolSync.flush(profileId:profile,send:(a,b,c,d)async=>throw const SocketException('Synthetic offline boundary')),throwsA(isA<SocketException>()));
   await db.switchProfile('TEST-unbound');await db.switchProfile(profile,identity:{'schoolId':school,'schoolSyncId':school});
   expect((await db.collection('school_notices').doc(id).get()).exists,true);
   expect((await db.collection('_windows_firebase_outbox').get()).docs,hasLength(1));
   await WindowsPendingSchoolSync.flush(profileId:profile,send:(a,b,c,d)async=>throw StateError('Versioned path required'),sendVersioned:(item)async{
    final ack=await ManagedSchoolSession.callForSchool(school,'managed/records',{'collection':item['collection'],'id':item['documentId'],'operation':'write','data':item['data'],'syncProtocol':2,'operationId':item['operationId'],'expectedRecordRevision':item['baseCloudRevision']??''});
    expect(ack['schoolId'],school);expect(ack['syncProtocol'],2);expect(ack['recordRevision'],isA<String>());return ack['recordRevision'] as String;
   });
   report['windowsQueueToAckMs']=clock.elapsedMilliseconds;
   expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);report['windowsPending']=0;
   const person='isolated-v2-20261009-student';
   final linkToken=sha256.convert(utf8.encode('isolated-v2-20261009/synthetic-qr')).toString();
   final qr=SchoolLink.encodeCompact({'managed':true,'schoolId':school,'centralEndpoint':endpoint,'type':'student','personId':person,'linkToken':linkToken});
   final mobile=SchoolSession(client:transport,cacheDirectory:tmp,attendanceStore:store);
   await mobile.login(SchoolLink.parse(qr),studentClass:'1',roll:'900001',dob:'2015-01-01');
   await mobile.refreshDashboard();
   expect((mobile.dashboard['notices'] as List).any((n)=>n['id']==id),true);
   expect(mobile.connectionState,SchoolConnectionState.connected);
   report['windowsToActualMobileReadMs']=clock.elapsedMilliseconds;
   final bytes=await mobile.publishedIdCard();expect(bytes,isNotNull);expect(bytes!.length,greaterThan(0));
   final restored=SchoolSession(client:transport,cacheDirectory:tmp,attendanceStore:store);await restored.restore();
   expect(restored.loggedIn,true);expect((restored.dashboard['notices'] as List).any((n)=>n['id']==id),true);
   expect(await restored.cachedPdf('idCard'),isNotNull);
   report['status']='PASS';
  }catch(_){report['status']='FAIL';rethrow;}
  finally{transport.close();await store.close();await Directory('build/cloud-prerequisites').create(recursive:true);await File('build/cloud-prerequisites/actual-engines.json').writeAsString(jsonEncode(report));print(jsonEncode(report));}
 },timeout:const Timeout(Duration(minutes:8)));
}
