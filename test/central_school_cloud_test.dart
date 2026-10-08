import 'dart:io';
import 'package:saarthi_ai/windows_connect/school_drive_images.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saarthi_ai/platform/platform_config.dart';
import 'package:saarthi_ai/windows_connect/central_school_cloud.dart';
import 'package:saarthi_ai/windows_connect/google_authorization.dart';
import 'package:saarthi_ai/windows_connect/school_provisioner.dart';
const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
class _CountingClient extends MockClient {
  _CountingClient():super((request)async=>http.Response(jsonEncode({'success':true,'schoolId':school}),200));
  int closes=0;
  @override void close(){closes++;super.close();}
}
void main() {
  test('only central managed-record revision conflict reaches conflict recovery', () async {
    for (final specific in [true, false]) {
      final cloud=CentralSchoolCloud(endpoint:'https://school.example/api',client:MockClient((r) async =>
        http.Response(jsonEncode({'success':false,'message':specific?'Record revision conflict':'private value NEVER_EXPOSE',
          'requestId':'03ee66b9-8b36-4054-a521-a42b5293aba2'}),409)));
      await expectLater(cloud.send('POST',Uri.parse(cloud.endpoint),body:{'action':'managed/records'}),
        throwsA(isA<StateError>().having((e)=>e.toString(),'specific conflict',specific?contains('Record revision conflict'):isNot(contains('conflict')))
          .having((e)=>e.toString(),'privacy',isNot(contains('NEVER_EXPOSE')))));
      cloud.close();
    }
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(()=>FlutterSecureStorage.setMockInitialValues({}));
  test('request wrappers can share an explicitly caller-owned connection without closing it', () async {
    final savedFixture={'managed':true,'schoolId':school,'uid':'owner','projectId':platformProjectId,'folderId':'managed','firebaseRefreshToken':'fixture-refresh','endpoint':'https://saarthi-oauth-staging.onrender.com/school-cloud'};
    expect(CentralSchoolCloud.decodeSaved(jsonEncode(savedFixture))['schoolId'],school);
    FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key:jsonEncode(savedFixture)});
    final transport=_CountingClient();
    for(var i=0;i<2;i++){
      final cloud=CentralSchoolCloud(client:transport,closeClient:false,endpoint:'https://saarthi-oauth-staging.onrender.com/school-cloud',expectedSchoolId:school);
      expect((await cloud.api({'action':'status'},token:'test-token'))['schoolId'],school);
      cloud.close();expect(transport.closes,0);
    }
    transport.close();expect(transport.closes,1);
  });
  test('default connection ownership still closes and cancels its request wrapper', () {
    final transport=_CountingClient();final cloud=CentralSchoolCloud(client:transport);
    cloud.close();expect(cloud.cancelled,true);expect(transport.closes,1);
  });
  test('Private Drive loader accepts only canonical Drive file identities',(){
    expect(schoolDriveFileId('https://drive.google.com/file/d/own-file/view'),'own-file');
    expect(schoolDriveFileId('https://attacker.example/file/d/token/view'),isNull);
    expect(schoolDriveFileId('https://attacker@drive.google.com/file/d/token/view'),isNull);
    expect(schoolDriveFileId('https://drive.google.com/file/d/../view'),isNull);
  });
  test('School OAuth uses offline Drive permission and verifies loopback callback',() async {
    final auth=GoogleAuthorization(oauthClientId:'desktop.apps.googleusercontent.com',
      client:MockClient((r) async {
        if(r.url.host=='oauth2.googleapis.com') {
          expect(Uri.splitQueryString(r.body).containsKey('client_secret'),false);
          return http.Response(jsonEncode({'access_token':'access','refresh_token':'refresh',
            'scope':'openid email https://www.googleapis.com/auth/drive.file','expires_in':3600}),200);
        }
        expect(r.headers['Authorization'],'Bearer access');
        return http.Response('{"sub":"123","email":"school@gmail.com","email_verified":true}',200);
      }),openBrowser:(uri) async {
        final scopes=uri.queryParameters['scope']!;
        expect(scopes,contains('/auth/drive.file'));expect(scopes,isNot(contains('cloud-platform')));
        expect(scopes,isNot(contains('script.')));expect(uri.queryParameters['access_type'],'offline');
        final callback=Uri.parse(uri.queryParameters['redirect_uri']!).replace(queryParameters:{
          'state':uri.queryParameters['state']!,'code':'approved-code'});
        final browser=HttpClient();
        try{await (await (await browser.getUrl(callback)).close()).drain<void>();}finally{browser.close();}
      });
    final account=await HttpOverrides.runWithHttpOverrides(()=>auth.authorize(script:false,schoolCloud:true),_LoopbackOverrides());
    expect(account.email,'school@gmail.com');expect(account.refreshToken,'refresh');expect(account.expiresIn,3600);
    auth.close();
  });
  test('All paths include a validated school ID and reject traversal',(){
    expect(tenantCollectionPath(school,'students_directory'),'schools/$school/students_directory');
    for(final id in ['', '../other','vs-school-legacy']) {
      expect(()=>tenantCollectionPath(id,'students_directory'),throwsStateError);
    }
    for(final collection in ['../school_memberships','students/other','schools/other/students']) {
      expect(()=>tenantCollectionPath(school,collection),throwsStateError);
    }
  });
  test('Central documents replace caller schoolId and remove local credentials/bytes',(){
    final data = centralSchoolData({'schoolId':'other','name':'Student','password':'secret',
      'refreshToken':'private','photoBase64':'bytes','localPath':'device','photoUrl':'own-drive-link'},school);
    expect(data,{'schoolId':school,'name':'Student','photoUrl':'own-drive-link'});
  });
  test('New central flow calls no project creation, Firebase Management or Apps Script APIs',() async {
    final hosts = <String>[];
    final cloud = CentralSchoolCloud(endpoint:'https://school.example/api',client:MockClient((r) async {
      hosts.add(r.url.host);expect(r.followRedirects,false);
      if (r.url.host == 'school.example') {
        final body = jsonDecode(r.body);
        if (body['action']=='onboard') return http.Response(jsonEncode({'schoolId':school,'projectId':platformProjectId,'email':'school@gmail.com','customToken':'server-token','uid':'verified-uid'}),200);
        return http.Response(jsonEncode({'success':true,'schoolId':school,'projectId':platformProjectId,'uid':'verified-uid'}),200);
      }
      if(r.url.host=='identitytoolkit.googleapis.com') return http.Response(jsonEncode({'idToken':'firebase-token','refreshToken':'firebase-refresh','expiresIn':'3600'}),200);
      if(r.url.host=='firestore.googleapis.com') return http.Response('{}',200);
      if(r.method=='GET') return http.Response('{"files":[]}',200);
      return http.Response('{"id":"school-folder"}',200);
    }));
    await cloud.connect(const GoogleSetupAccount('123','school@gmail.com','google-token',refreshToken:'google-refresh'),'My school');
    final saved=await CentralSchoolCloud.saved();expect(saved['schoolId'],school);expect(saved['folderId'],'school-folder');expect(saved['uid'],'verified-uid');
    expect(hosts, isNot(contains('cloudresourcemanager.googleapis.com')));
    expect(hosts, isNot(contains('firebase.googleapis.com')));expect(hosts,isNot(contains('script.googleapis.com')));
    cloud.close();
  });
  test('Server-verified Firebase identity mismatch stops before Drive or session persistence',() async {
    for (final changed in [<String,dynamic>{'uid':'foreign-uid'},<String,dynamic>{'uid':null},
      <String,dynamic>{'schoolId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'},<String,dynamic>{'projectId':'foreign-project'}]) {
      final cloud=CentralSchoolCloud(endpoint:'https://school.example/api',client:MockClient((r) async {
        if (r.url.host=='school.example') {
          final body=jsonDecode(r.body);
          if(body['action']=='onboard') return http.Response(jsonEncode({'schoolId':school,'projectId':platformProjectId,
            'email':'school@gmail.com','customToken':'server-token','uid':'verified-uid'}),200);
          return http.Response(jsonEncode({'success':true,'schoolId':school,'projectId':platformProjectId,'uid':'verified-uid',...changed}),200);
        }
        expect(r.url.host,'identitytoolkit.googleapis.com');
        return http.Response('{"idToken":"firebase-token","refreshToken":"firebase-refresh","expiresIn":"3600"}',200);
      }));
      await expectLater(cloud.connect(const GoogleSetupAccount('123','school@gmail.com','google-token'),'School'),throwsStateError);
      expect(await CentralSchoolCloud.saved(),isEmpty);cloud.close();
    }
  });
  test('Partial Firebase/Drive setup never saves a connected session',() async {
    final cloud=CentralSchoolCloud(endpoint:'https://school.example/api',client:MockClient((r) async => http.Response('{}',403)));
    await expectLater(cloud.connect(const GoogleSetupAccount('123','school@gmail.com','token'),'School'),throwsStateError);
    expect(await CentralSchoolCloud.saved(),isEmpty);cloud.close();
  });
  test('Drive API denial identifies the failed endpoint and reports only safe diagnostic metadata',() async {
    final stages=<String>[]; final reports=<Map>[];
    final cloud=CentralSchoolCloud(endpoint:'https://school.example/api',client:MockClient((r) async {
      if(r.url.host=='school.example') {
        final b=jsonDecode(r.body);
        if(b['action']=='onboard') return http.Response(jsonEncode({'schoolId':school,'projectId':platformProjectId,
          'email':'school@gmail.com','customToken':'server-token','uid':'verified-uid'}),200);
        if(b['action']=='setup/diagnostic') {expect(r.followRedirects,false);reports.add(b); return http.Response('{"success":true}',200);}
        return http.Response(jsonEncode({'schoolId':school,'projectId':platformProjectId,'uid':'verified-uid'}),200);
      }
      if(r.url.host=='identitytoolkit.googleapis.com') return http.Response('{"idToken":"firebase-token","refreshToken":"firebase-refresh"}',200);
      if(r.url.host=='firestore.googleapis.com') return http.Response('{}',200);
      return http.Response(jsonEncode({'error':{'message':'private-google-token and key', 'status':'PERMISSION_DENIED',
        'details':[{'reason':'SERVICE_DISABLED','metadata':{'credential':'private-google-token'}}]}}),403);
    }));
    await expectLater(cloud.connect(const GoogleSetupAccount('123','school@gmail.com','google-token'),'School',progress:stages.add),
      throwsA(isA<StateError>().having((e)=>e.message,'endpoint',contains('Google Drive folder search'))
        .having((e)=>e.message,'reason',contains('SERVICE_DISABLED'))
        .having((e)=>e.message,'privacy',isNot(contains('private-google-token')))));
    expect(stages,['firebase']);expect(await CentralSchoolCloud.saved(),isEmpty);
    expect(reports,[{'action':'setup/diagnostic','schoolId':school,'stage':'drive_list','httpStatus':403,'reason':'SERVICE_DISABLED'}]);cloud.close();
  });
  test('Central migration denial remains explicit and never bypasses authorization or exposes arbitrary error bodies',() async {
    final cloud=CentralSchoolCloud(endpoint:'https://school.example/api',client:MockClient((r) async =>
      http.Response('{"message":"Legacy school administrator proof is required"}',403)));
    await expectLater(cloud.api({'action':'migration/import'}),throwsA(isA<StateError>()
      .having((e)=>e.message,'operation',contains('legacy migration'))
      .having((e)=>e.message,'reason',contains('Legacy school administrator proof is required'))));
    expect(await CentralSchoolCloud.saved(),isEmpty);cloud.close();
    final other=CentralSchoolCloud(endpoint:'https://school.example/api',client:MockClient((r) async =>
      http.Response('{"message":"private-token-value"}',403)));
    await expectLater(other.api({'action':'onboard'}),throwsA(isA<StateError>()
      .having((e)=>e.message,'privacy',isNot(contains('private-token-value')))));other.close();
  });
  test('Legacy project provisioning is disabled in the normal client build',() async {
    final setup=SchoolProvisioner(api:GoogleSetupApi('secret'),account:const GoogleSetupAccount('123','school@gmail.com','token'),
      checkpoint:_Checkpoint(),progress:(_){},bundle:{});
    await expectLater(setup.ensureProject(),throwsStateError);
    await expectLater(setup.activateFirebase(),throwsStateError);
    await expectLater(setup.firebase(),throwsStateError);
  });
}
class _Checkpoint implements SetupCheckpoint {
  @override Future<Map<String,dynamic>> read() async=>{};
  @override Future<void> write(Map<String,dynamic> value) async{}
}

class _LoopbackOverrides extends HttpOverrides {}
