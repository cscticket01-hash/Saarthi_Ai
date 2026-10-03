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
        if (body['action']=='onboard') return http.Response(jsonEncode({'schoolId':school,'projectId':platformProjectId,'email':'school@gmail.com','customToken':'server-token'}),200);
        return http.Response(jsonEncode({'success':true,'schoolId':school}),200);
      }
      if(r.url.host=='identitytoolkit.googleapis.com') return http.Response(jsonEncode({'idToken':'firebase-token','refreshToken':'firebase-refresh','localId':'verified-uid'}),200);
      if(r.url.host=='firestore.googleapis.com') return http.Response('{}',200);
      if(r.method=='GET') return http.Response('{"files":[]}',200);
      return http.Response('{"id":"school-folder"}',200);
    }));
    await cloud.connect(const GoogleSetupAccount('123','school@gmail.com','google-token',refreshToken:'google-refresh'),'My school');
    final saved=await CentralSchoolCloud.saved();expect(saved['schoolId'],school);expect(saved['folderId'],'school-folder');
    expect(hosts, isNot(contains('cloudresourcemanager.googleapis.com')));
    expect(hosts, isNot(contains('firebase.googleapis.com')));expect(hosts,isNot(contains('script.googleapis.com')));
    cloud.close();
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
