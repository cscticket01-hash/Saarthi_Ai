import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../lib/testing/isolated_admin_fixture.dart';
import '../../lib/windows_connect/central_school_cloud.dart';
import '../../lib/windows_connect/managed_school_session.dart';
import '../../lib/windows_connect/managed_record_media.dart';
import '../../lib/windows_local_firestore.dart';

void main() {
 TestWidgetsFlutterBinding.ensureInitialized();
 test('read back the original retained TEST portrait without submitting an upload',() async {
  const school='vs-db8afb01a3be46a983c8284714d06e5d';
  const endpoint='https://saarthi-sync-v2-test.onrender.com/school-cloud';
  const original='42999712701-1';
  expect(Platform.environment['GITHUB_ACTIONS'],'true');
  expect(Platform.environment['GITHUB_REPOSITORY'],'cscticket01-hash/Saarthi_Ai');
  expect(Platform.environment['GITHUB_REF'],'refs/heads/test/read-retained-portrait-20261111');
  expect(Platform.environment['VS_TEST_CONNECT_CONFIRM'],school);
  HttpOverrides.global=null;
  FlutterSecureStorage.setMockInitialValues({});
  final report=<String,dynamic>{'scope':'Read-only original retained synthetic portrait',
   'originalFixture':original,'businessWriteSubmitted':false,'status':'FAIL'};
  final tmp=await Directory.systemTemp.createTemp('vs-retained-portrait-');
  try {
   final health=jsonDecode((await http.get(Uri.parse('$endpoint/healthz'))).body) as Map;
   expect(health['ready'],true);expect(health['projectId'],'saarthi-ai-df12b');
   expect(health['runtimeCommit'],'731bca40858285e9dc06450f9a6b9a41b6e461cc');
   await authenticateIsolatedAdminFixture(Platform.environment['VS_TEST_LOGIN_EMAIL']!,
    Platform.environment['VS_TEST_LOGIN_PASSWORD']!,endpoint:endpoint);
   sqfliteFfiInit();
   final db=FirebaseFirestore.instance;
   await db.changeLocalStorageLocation('${tmp.path}/windows');
   await db.switchProfile('TEST-retained-portrait',identity:{'schoolId':school,'schoolSyncId':school});
   final portrait=img.Image(width:640,height:960)..textData={'Synthetic run':original};
   img.fill(portrait,color:img.ColorRgb8(190,210,220));
   final raw=img.encodePng(portrait);
   String? expectedHash,expectedMime;
   Future<Map<String,dynamic>> receiptOnly(String action,Map<String,dynamic> body) async {
    expect(action,'managed/file/upload');
    final key=body['uploadKey'] as String;
    final id=sha256.convert(utf8.encode(jsonEncode([school,key]))).toString();
    expectedHash=sha256.convert(base64Decode(body['base64'] as String)).toString();
    expectedMime=body['mime'] as String;
    report['receiptIdentityHash']=id;
    // This callback intentionally does NOT submit its upload body. A missing
    // original receipt fails closed instead of creating a replacement fixture.
    for(var attempt=0;attempt<3;attempt++) {
     try { return await ManagedSchoolSession.callForSchool(school,
      'managed/cloudflare/operation',{'lane':'file-$id','id':id,'waitMillis':18000}); }
     on CentralCloudException catch(error) {
      if(attempt==2||error.status!=503||
       !['SCRIPT_TIMEOUT','EDGE_DELIVERY_PENDING'].contains(error.diagnosticCode)||
       error.retryAfterMs>60000) rethrow;
      await Future<void>.delayed(Duration(milliseconds:error.retryAfterMs.clamp(15000,30000).toInt()));
     }
    }
    throw StateError('Original retained receipt unverified');
   }
   final prepared=await prepareManagedRecord({'schoolId':school,
    'photoUrl':'data:image/png;base64,${base64Encode(raw)}'},school,receiptOnly);
   final cloud=await ManagedSchoolSession.callForSchool(school,'managed/file/read',
    {'fileId':prepared['photoFileId']});
   expect(cloud['mime'],expectedMime);
   expect(sha256.convert(base64Decode(cloud['base64'] as String)).toString(),expectedHash);
   report['fileHashVerified']=true;report['originalDriveReceiptVerified']=true;
   report['runtimeCommit']=health['runtimeCommit'];report['status']='PASS';
  } finally {
   await Directory('build/cloud-prerequisites').create(recursive:true);
   await File('build/cloud-prerequisites/retained-portrait.json').writeAsString(jsonEncode(report));
   print(jsonEncode(report));
  }
 },timeout:const Timeout(Duration(minutes:10)));
}
