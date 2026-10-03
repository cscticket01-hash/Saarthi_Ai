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
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(()=>FlutterSecureStorage.setMockInitialValues({}));
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
