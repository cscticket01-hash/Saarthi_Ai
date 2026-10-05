import 'dart:async';
import '../lib/windows_connect/firebase_token_cache.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'dart:convert';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_firebase_sync.dart';
import '../lib/platform/platform_config.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_managed_school_gate.dart';
import '../lib/main_dashboard_screen_windows.dart' show WindowsSectionLocks,WindowsAdminAccessGate;
import '../lib/windows_local_settings.dart';
import '../lib/windows_local_auth.dart' as local;
import '../lib/windows_connect/managed_school_session.dart';
void main(){
  test('legacy branding cache without schoolId is recovered only from its immutable tenant profile', () async {
    final db = FirebaseFirestore.instance;
    final profile = 'registration-cache-${DateTime.now().microsecondsSinceEpoch}';
    const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    await db.switchProfile(profile, identity: {'schoolSyncId': school});
    await db.collection('school_config').doc('school_profile_cache').set({'schoolName': 'Saved School', 'principalName': 'Saved Principal'});
    expect((await db.readSchoolRegistrationCache(school))?['schoolId'], school);
    await expectLater(db.readSchoolRegistrationCache('vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'), throwsStateError);
    await db.collection('school_config').doc('school_profile_cache').set({'schoolId': 'other-school'});
    await expectLater(db.readSchoolRegistrationCache(school), throwsStateError);
  });
  test('Firebase token exchanges coalesce, expire early and isolate accounts', () async {
    final cache = FirebaseTokenCache(); var calls = 0;
    Future<({String token, int expiresAt})> refresh() async {
      calls++; return (token: 'token-$calls', expiresAt: 3600000);
    }
    expect(await Future.wait([cache.get('A', refresh, now: 0), cache.get('A', refresh, now: 0)]), ['token-1', 'token-1']);
    expect(await cache.get('A', refresh, now: 1000), 'token-1'); expect(calls, 1);
    expect(await cache.get('A', refresh, now: 3540000), 'token-2');
    expect(await cache.get('B', refresh, now: 0), 'token-3');
    cache.clear(); expect(await cache.get('B', refresh, now: 0), 'token-4');
    final pending = Completer<({String token, int expiresAt})>(); cache.clear();
    final old = cache.get('A', () => pending.future, now: 0);
    final rejected = expectLater(old, throwsStateError);
    await cache.get('B', refresh, now: 0);
    pending.complete((token: 'old-A', expiresAt: 3600000)); await rejected;
    expect(await cache.get('B', refresh, now: 0), 'token-5');
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  test('managed protected settings reauthenticate against Firebase without storing a password',()async{
    const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final saved={'managed':true,'projectId':platformProjectId,'schoolId':school,'uid':'school-uid','email':'a@school.example','folderId':'managed','firebaseRefreshToken':'old-refresh','endpoint':'https://school.example/school-cloud'};
    final encoded=jsonEncode(saved);FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key:encoded});
    final hosts=<String>[];
    final client=MockClient((request)async{
      hosts.add(request.url.host);final body=jsonDecode(request.body);
      if(request.url.host=='identitytoolkit.googleapis.com'){expect(body['password'],'transient-password');return http.Response(jsonEncode({'localId':'school-uid','idToken':'reauth-token'}),200);}
      expect(body.containsKey('password'),false);expect(body['schoolId'],school);expect(request.headers['Authorization'],'Bearer reauth-token');
      return http.Response(jsonEncode({'success':true,'schoolId':school,'uid':'school-uid'}),200);
    });
    await ManagedSchoolSession.reauthenticate('a@school.example','transient-password',client:client);
    expect(hosts,['identitytoolkit.googleapis.com','school.example']);
    expect(await const FlutterSecureStorage().read(key:CentralSchoolCloud.key),encoded);
    await expectLater(ManagedSchoolSession.reauthenticate('other@school.example','transient-password'),throwsStateError);
  });
  test('managed session configuration is authoritative, tenant-bound and refreshes stale script URLs', () {
    const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final response = {'success': true, 'schoolId': school, 'uid': 'A',
      'projectId': platformProjectId, 'storageReady': true,
      'scriptUrl': 'https://script.google.com/macros/s/SchoolADeployment/exec'};
    expect(managedSessionConfiguration(response, school, 'A')['scriptUrl'], response['scriptUrl']);
    expect(managedSessionConfiguration({...response, 'storageReady': false}, school, 'A')['scriptUrl'], '');
    for (final change in [ {'schoolId': 'other'}, {'uid': 'B'},
      {'projectId': 'foreign'}, {'scriptUrl': 'https://foreign.example/exec'} ]) {
      expect(() => managedSessionConfiguration({...response, ...change}, school, 'A'), throwsStateError);
    }
  });
  test('fresh managed login saves exact server school/configuration, never plaintext password', () async {
    const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    FlutterSecureStorage.setMockInitialValues({});
    final client = MockClient((request) async {
      final body = jsonDecode(request.body);
      if (request.url.host == 'identitytoolkit.googleapis.com') {
        expect(body['email'], 'a@school.example');
        return http.Response(jsonEncode({'localId': 'A', 'idToken': 'A-token', 'refreshToken': 'A-refresh'}), 200);
      }
      expect(body.containsKey('schoolId'), false); expect(body.containsKey('password'), false);
      return http.Response(jsonEncode({'success': true, 'schoolId': school, 'uid': 'A',
        'projectId': platformProjectId, 'storageReady': true, 'scriptUrl': 'https://script.google.com/macros/s/SchoolADeployment/exec',
        'allowed': true, 'activated': true, 'status': 'licensed'}), 200);
    });
    final session = await ManagedSchoolSession.login(' a@school.example ', 'transient-password',
      client: client, endpoint: 'https://school.example/school-cloud');
    final saved = await CentralSchoolCloud.saved();
    expect(saved['schoolId'], school); expect(saved['uid'], 'A');
    expect(saved['scriptUrl'], session['scriptUrl']); expect(saved.containsKey('password'), false);
    expect(await const FlutterSecureStorage().read(key: CentralSchoolCloud.key), isNot(contains('transient-password')));
  });
  test('wrong credentials or foreign server identity never save a new session', () async {
    for (final mode in ['wrong-password', 'foreign-uid']) {
      FlutterSecureStorage.setMockInitialValues({});
      final client = MockClient((request) async {
        if (request.url.host == 'identitytoolkit.googleapis.com') {
          if (mode == 'wrong-password') return http.Response(jsonEncode({'error': {'message': 'INVALID_LOGIN_CREDENTIALS'}}), 400);
          return http.Response(jsonEncode({'localId': 'A', 'idToken': 'A-token', 'refreshToken': 'A-refresh'}), 200);
        }
        return http.Response(jsonEncode({'success': true, 'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'uid': 'B'}), 200);
      });
      await expectLater(ManagedSchoolSession.login('a@school.example', 'wrong',
        client: client, endpoint: 'https://school.example/school-cloud'), throwsStateError);
      expect(await const FlutterSecureStorage().read(key: CentralSchoolCloud.key), isNull);
    }
  });
  test('ordinary logout retains managed enrollment and school-scoped App Lock', () async {
    final saved = jsonEncode({'managed': true, 'projectId': platformProjectId, 'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'uid': 'school-uid', 'email': 'a@school.example', 'folderId': 'managed', 'firebaseRefreshToken': 'refresh', 'endpoint': 'https://school.example/school-cloud'});
    FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key: saved});
    await WindowsLocalSecurity.initialize();
    await WindowsLocalSecurity.create(adminId: 'School app', password: 'app-only-pass');
    await local.FirebaseAuth.instance.signOut();
    expect(await const FlutterSecureStorage().read(key: CentralSchoolCloud.key), saved);
    expect(WindowsLocalSecurity.verifyPassword('app-only-pass'), true);
    expect(local.FirebaseAuth.instance.currentUser?.email, 'a@school.example');
  });
  test('managed App Lock and Admin Section Lock use independent school-scoped credentials',()async{
    const a='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',b='vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    Map<String,dynamic> saved(String school)=>{'managed':true,'projectId':platformProjectId,'schoolId':school,'uid':school,'email':'a@school.example','folderId':'managed','firebaseRefreshToken':'refresh','endpoint':'https://school.example/school-cloud'};
    FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key:jsonEncode(saved(a))});
    await WindowsLocalSecurity.initialize();expect(WindowsLocalSecurity.configured,false);
    await WindowsLocalSecurity.create(adminId:'School app',password:'app-only-pass');
    expect(await WindowsSectionLocks.enabled('admin_section'),false);
    await WindowsSectionLocks.addPassword(sectionKey:'admin_section',password:'admin-only-pass');
    expect(WindowsLocalSecurity.verifyPassword('admin-only-pass'),false);
    expect(await WindowsSectionLocks.verify(sectionKey:'admin_section',password:'app-only-pass'),false);
    expect(await WindowsSectionLocks.verify(sectionKey:'admin_section',password:'admin-only-pass'),true);
    await const FlutterSecureStorage().write(key:CentralSchoolCloud.key,value:jsonEncode(saved(b)));
    await WindowsLocalSecurity.initialize();expect(WindowsLocalSecurity.configured,false);expect(await WindowsSectionLocks.enabled('admin_section'),false);
    await const FlutterSecureStorage().write(key:CentralSchoolCloud.key,value:jsonEncode(saved(a)));
    await WindowsLocalSecurity.initialize();expect(WindowsLocalSecurity.verifyPassword('app-only-pass'),true);expect(await WindowsSectionLocks.enabled('admin_section'),true);
    await WindowsLocalSecurity.clearAppLock();expect(await WindowsSectionLocks.enabled('admin_section'),true);
  });
  testWidgets('Admin entry no longer asks a second password even with a legacy lock saved',(tester)async{
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(home:WindowsAdminAccessGate(child:Text('Direct admin panel'))));
    await tester.pump();await tester.pump();expect(find.text('Direct admin panel'),findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await WindowsSectionLocks.addPassword(sectionKey:'admin_section',password:'admin-only-pass');
    await tester.pumpWidget(const MaterialApp(home:WindowsAdminAccessGate(child:Text('Direct admin panel'))));
    await tester.pump();await tester.pump();expect(find.text('Direct admin panel'),findsOneWidget);expect(find.text('Admin Section Password'),findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  test('queued local writes and stale batches cannot cross a school switch',()async{
    final db=FirebaseFirestore.instance;
    final suffix=DateTime.now().microsecondsSinceEpoch;
    final a='managed-a-$suffix',b='managed-b-$suffix';
    await db.switchProfile(a);
    final ref=db.collection('students_directory').doc('same');
    final batch=db.batch()..set(ref,{'name':'Old batch'});
    final write=ref.set({'name':'School A'});
    final switched=db.switchProfile(b);
    await write;await switched;
    expect((await db.collection('students_directory').doc('same').get()).exists,false);
    await expectLater(ref.set({'name':'Wrong school'}),throwsStateError);
    await expectLater(batch.commit(),throwsStateError);
    await db.switchProfile(a);
    expect((await db.collection('students_directory').doc('same').get()).data()?['name'],'School A');
  });
  test('managed sync refuses A outbox after B credentials replace the session',()async{
    const a='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',b='vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key:jsonEncode({'managed':true,'projectId':platformProjectId,'schoolId':b,'uid':'B','email':'b@school.example','folderId':'managed','firebaseRefreshToken':'B-refresh','endpoint':'https://school.example/school-cloud'})});
    await FirebaseFirestore.instance.switchProfile('central_$a',identity:{'schoolId':a,'schoolSyncId':a,'firebaseProjectId':platformProjectId});
    await expectLater(WindowsFirebaseRemote.writeDocument(projectId:platformProjectId,idToken:'A-token',collection:'students_directory',documentId:'same',data:{'name':'School A'}),throwsStateError);
    await expectLater(WindowsFirebaseRemote.readCollection(projectId:platformProjectId,idToken:'A-token',collection:'students_directory'),throwsStateError);
  });
  testWidgets('managed logout cannot expose legacy dashboard or licence skip',(tester)async{
    FlutterSecureStorage.setMockInitialValues({'vidya_saarthi_managed_required':'true'});
    await tester.pumpWidget(const MaterialApp(home:WindowsManagedSchoolGate(child:Text('School data'),legacy:Text('Legacy skip'))));
    await tester.pump();await tester.pump();
    expect(find.text('School Login'),findsOneWidget);expect(find.text('School data'),findsNothing);expect(find.text('Legacy skip'),findsNothing);
    await ManagedSchoolSession.logout();await tester.pump();await tester.pump();
    expect(find.text('School Login'),findsOneWidget);expect(find.text('Legacy skip'),findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('school password input preserves characters and visibility toggle without duplication',(tester)async{
    await tester.pumpWidget(const MaterialApp(home:WindowsManagedSchoolLogin()));
    final password=find.widgetWithText(TextField,'Password');
    await tester.enterText(password,'a');await tester.pump();
    expect(tester.widget<TextField>(password).controller!.text,'a');expect(tester.widget<TextField>(password).obscureText,true);
    await tester.tap(find.byKey(const ValueKey('show-password')));await tester.pump();
    expect(tester.widget<TextField>(password).obscureText,false);expect(tester.widget<TextField>(password).controller!.text,'a');
    await tester.enterText(password,'aaaa');await tester.pump();
    await tester.tap(find.byKey(const ValueKey('hide-password')));await tester.pump();expect(tester.widget<TextField>(password).controller!.text,'aaaa');
    await tester.enterText(password,'ab');await tester.pump();
    await tester.enterText(password,'a');await tester.pump();
    await tester.enterText(password,'ac');await tester.pump();
    expect(tester.widget<TextField>(password).controller!.text,'ac');
    final email=find.widgetWithText(TextField,'School login email');
    expect(tester.widget<TextField>(email).autocorrect,false);
    expect(tester.widget<TextField>(email).enableSuggestions,false);
    await tester.pumpWidget(const SizedBox());
  });
}
