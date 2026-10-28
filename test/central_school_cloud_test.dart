import 'dart:io';
import 'dart:async';
import 'package:fake_async/fake_async.dart';
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
class _StreamClient extends http.BaseClient {
  _StreamClient(this.response);
  final Future<http.StreamedResponse> Function() response;
  int sends = 0, closes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sends++;
    return response();
  }
  @override
  void close() { closes++; }
}
void main() {
  test('Cloudflare acceptance polls one immutable ticket until real Drive ACK', () async {
    final calls = <Map<String, dynamic>>[];
    final id = List.filled(64, 'a').join();
    final cloud = CentralSchoolCloud(endpoint: 'https://school.example/api',
      client: MockClient((request) async {
        calls.add(Map<String, dynamic>.from(jsonDecode(request.body)));
        return http.Response(jsonEncode(calls.length < 3 ? {
          'success': true, 'schoolId': school, 'edgeDeliveryVersion': 1,
          'driveState': 'pending', 'delivery': {'lane': 'records', 'id': id},
        } : {
          'success': true, 'schoolId': school, 'driveState': 'verified',
          'syncProtocol': 2, 'recordRevision': 'drive-verified',
        }), 200);
      }));
    final result = await cloud.api({'action': 'managed/records', 'schoolId': school,
      'syncProtocol': 2, 'operation': 'write', 'operationId': 'original-operation-id'});
    expect(result['recordRevision'], 'drive-verified');
    expect(calls.first['edgeDeliveryVersion'], 1);
    expect(calls.skip(1).map((c) => c['action']),
      everyElement('managed/cloudflare/operation'));
    expect(calls.skip(1).map((c) => c['id']), everyElement(id));
    expect(calls.where((c) => c.containsKey('operationId')), hasLength(1));
    cloud.close();
  });
  for (final invalid in ['foreign-school', 'changed-ticket', 'unverified-final']) {
    test('Cloudflare $invalid never clears original local work', () async {
      var calls = 0;
      final id = List.filled(64, 'a').join();
      final cloud = CentralSchoolCloud(endpoint: 'https://school.example/api',
        client: MockClient((_) async {
          calls++;
          return http.Response(jsonEncode(calls == 1 || invalid == 'changed-ticket' ? {
            'success': true,
            'schoolId': invalid == 'foreign-school' ? 'another-school' : school,
            'edgeDeliveryVersion': 1, 'driveState': 'pending',
            'delivery': {'lane': 'records', 'id': calls == 1 ? id : List.filled(64, 'b').join()},
          } : {'success': true, 'schoolId': school, 'driveState': 'pending'}), 200);
        }));
      await expectLater(cloud.api({'action': 'managed/records', 'schoolId': school,
        'syncProtocol': 2, 'operation': 'write'}), throwsStateError);
      expect(calls, invalid == 'foreign-school' ? 1 : 2);
      cloud.close();
    });
  }
  test('upload identity is scoped to school, owner, slot and immutable bytes', () {
    final key = CentralSchoolCloud.uploadIdentity(school, 'teacher-1', 'photo', 'YWJj');
    expect(key, CentralSchoolCloud.uploadIdentity(school, 'teacher-1', 'photo', 'data:image/png;base64,YWJj'));
    expect(key, isNot(CentralSchoolCloud.uploadIdentity(school, 'teacher-2', 'photo', 'YWJj')));
    expect(key, isNot(CentralSchoolCloud.uploadIdentity('other', 'teacher-1', 'photo', 'YWJj')));
    expect(key, isNot(CentralSchoolCloud.uploadIdentity(school, 'teacher-1', 'photo', 'YWJk')));
    expect(() => CentralSchoolCloud.uploadIdentity(school, '', 'photo', 'YWJj'), throwsStateError);
  });
  test('managed 120-second budget bounds headers and body without replay', () {
    for (final delayedHeaders in [true, false]) {
      fakeAsync((clock) {
        final body = StreamController<List<int>>();
        final transport = _StreamClient(() async {
          if (delayedHeaders) await Future<void>.delayed(const Duration(seconds: 119));
          return http.StreamedResponse(body.stream, 200);
        });
        final cloud = CentralSchoolCloud(endpoint: 'https://school.example/api',
            client: transport, closeClient: false);
        Object? failure;
        var completed = false;
        cloud.send('POST', Uri.parse(cloud.endpoint), body: {'action':'managed/records'})
          .then<void>((_) { completed = true; }, onError: (Object error) { failure = error; });
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 119)); clock.flushMicrotasks();
        expect(failure, isNull);
        clock.elapse(const Duration(seconds: 1)); clock.flushMicrotasks();
        expect(failure, isA<CentralRequestTimeout>());
        expect((failure as CentralRequestTimeout).stage, CentralTimeoutStage.responseBody);
        expect(completed, false);
        expect(transport.sends, 1); expect(transport.closes, 0);
        // A late successful response cannot retroactively certify the caller.
        body.add(utf8.encode('{"success":true}')); body.close(); clock.flushMicrotasks();
        expect(completed, false); expect(transport.sends, 1);
        cloud.close(); expect(transport.closes, 0);
      });
    }
  });
  test('managed response after 45 seconds succeeds exactly once', () {
    fakeAsync((clock) {
      final transport = _StreamClient(() async {
        await Future<void>.delayed(const Duration(seconds: 60));
        return http.StreamedResponse(Stream.value(utf8.encode('{"success":true}')), 200);
      });
      final cloud = CentralSchoolCloud(endpoint:'https://school.example/api', client:transport, closeClient:false);
      var completed = false;
      cloud.send('POST', Uri.parse(cloud.endpoint), body:{'action':'managed/changes'})
          .then((_) { completed = true; });
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds:45)); clock.flushMicrotasks();
      expect(completed, false);
      clock.elapse(const Duration(seconds:15)); clock.flushMicrotasks();
      expect(completed, true); expect(transport.sends, 1);
      cloud.close();
    });
  });
  test('no response headers are classified without retrying or resetting the shared client', () {
    fakeAsync((clock) {
      final response = Completer<http.StreamedResponse>();
      final transport = _StreamClient(() => response.future);
      final cloud = CentralSchoolCloud(endpoint:'https://school.example/api', client:transport,closeClient:false);
      Object? failure;
      cloud.send('GET', Uri.parse(cloud.endpoint)).then<void>((_) {}, onError:(Object error) { failure=error; });
      clock.flushMicrotasks(); clock.elapse(const Duration(seconds:45)); clock.flushMicrotasks();
      expect((failure as CentralRequestTimeout).stage, CentralTimeoutStage.responseHeaders);
      expect(failure.toString(), isNot(contains('school.example')));
      expect(transport.sends,1); expect(transport.closes,0);
      response.complete(http.StreamedResponse(Stream.value(utf8.encode('{}')),200)); clock.flushMicrotasks();
      cloud.close();
    });
  });
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
  test('safe coded storage failures remain distinct from revision conflicts', () async {
    final cloud = CentralSchoolCloud(endpoint: 'https://central.example/school-cloud',
      client: MockClient((_) async => http.Response(jsonEncode({
        'success': false, 'code': 'SCHOOL_STORAGE_NOT_CONNECTED',
        'message': 'NEVER_EXPOSE_PRIVATE_BODY',
      }), 409)));
    await expectLater(cloud.send('POST', Uri.parse(cloud.endpoint),
      body: {'action': 'managed/records'}),
      throwsA(isA<CentralCloudException>()
        .having((e) => e.diagnosticCode, 'code', 'SCHOOL_STORAGE_NOT_CONNECTED')
        .having((e) => e.toString(), 'specific explanation', contains('existing school storage binding'))
        .having((e) => e.toString(), 'not a revision conflict', isNot(contains('conflict')))
        .having((e) => e.toString(), 'private body', isNot(contains('NEVER_EXPOSE')))));
    cloud.close();
  });
  test('operation ID conflict retains the precise category without exposing raw bodies', () async {
    final cloud=CentralSchoolCloud(endpoint:'https://central.example/school-cloud',client:MockClient((_) async=>
      http.Response(jsonEncode({'success':false,'code':'OPERATION_ID_CONFLICT','message':'PRIVATE_BODY'}),409)));
    await expectLater(cloud.send('POST',Uri.parse(cloud.endpoint),body:{'action':'managed/records'}),
      throwsA(isA<CentralCloudException>().having((e)=>e.diagnosticCode,'code','OPERATION_ID_CONFLICT')
        .having((e)=>e.toString(),'retained conflict',contains('Both versions are retained'))
        .having((e)=>e.toString(),'privacy',isNot(contains('PRIVATE_BODY')))));
    cloud.close();
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
  test('profile-only OAuth accepts canonical Google scope without school permissions', () async {
    final auth = GoogleAuthorization(oauthClientId:'desktop.apps.googleusercontent.com',
      client:MockClient((r) async {
        if (r.url.host == 'oauth2.googleapis.com') {
          return http.Response(jsonEncode({'access_token':'access',
            'scope':'openid email https://www.googleapis.com/auth/userinfo.profile'}),200);
        }
        return http.Response(jsonEncode({'sub':'123','email':'school@gmail.com',
          'email_verified':true,'picture':'https://lh3.googleusercontent.com/photo.gif'}),200);
      }),openBrowser:(uri) async {
        expect(uri.queryParameters['scope']!.split(' '), ['openid','email','profile']);
        final callback=Uri.parse(uri.queryParameters['redirect_uri']!).replace(queryParameters:{
          'state':uri.queryParameters['state']!,'code':'approved-code'});
        final browser=HttpClient();
        try { await (await (await browser.getUrl(callback)).close()).drain<void>(); }
        finally { browser.close(); }
      });
    try {
      final account=await HttpOverrides.runWithHttpOverrides(
        ()=>auth.authorize(script:false,profileOnly:true), _LoopbackOverrides());
      expect(account.photoUrl,'https://lh3.googleusercontent.com/photo.gif');
    } finally { auth.close(); }
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
