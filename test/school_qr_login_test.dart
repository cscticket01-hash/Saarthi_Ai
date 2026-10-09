import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../lib/school_qr_link.dart';
import '../lib/qr_authentication_engine.dart';
import '../lib/mobile/school_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixtures = (jsonDecode(File('test/fixtures/windows_person_qr.json').readAsStringSync()) as List).map((v)=>Map<String,dynamic>.from(v as Map)).toList();
  setUp(()=>FlutterSecureStorage.setMockInitialValues({}));
  test('QR engine preserves expired identity but rejects invalid identity and new expired login',(){
    final link=QrAuthenticationEngine.decode(SchoolLink.encode(fixtures.first));
    expect(()=>QrAuthenticationEngine.decode(link.rawQr,expectedSchool:'foreign'),throwsStateError);
    final trusted={'expiresAt':2000,'schoolToken':'verified','person':{'personId':link.personId}};
    QrAuthenticationEngine.validateSession(link,trusted,now:1000,restored:true);
    QrAuthenticationEngine.validateSession(link,trusted,now:2000,restored:true);
    expect(()=>QrAuthenticationEngine.validateSession(link,{...trusted,'sessionToken':'verified'},now:2000),throwsStateError);
    expect(()=>QrAuthenticationEngine.validateSession(link,{...trusted,'person':{'personId':'foreign'}},now:1000,restored:true),throwsStateError);
  });
  Map<String,dynamic> reply(String school) => {'success':true,'schoolId':school,'projectId':school,'sessionToken':'verified-session',
    'expiresAt':DateTime.now().add(const Duration(hours:1)).millisecondsSinceEpoch,'person':{'name':'Own person'},'schoolName':'Own school'};
  for(final fixture in fixtures) {
    test('Windows ${fixture['type']} VS3 QR uses actual Android session login and secure restore',() async {
      final raw=SchoolLink.encodeCompact(fixture);
      expect(raw,startsWith('VS3|'));
      expect(SchoolLink.detectVersion(raw),3);
      final link=SchoolLink.parse(raw);
      final session=SchoolSession(client:MockClient((request) async {
        expect(request.url.toString(),fixture['centralEndpoint']);
        final body=jsonDecode(request.body) as Map;
        expect(body['action'],'managed/mobile');expect(body['schoolId'],fixture['schoolId']);
        final login=body['request'] as Map;
        expect(login['action'],'mobile_login');expect(login['role'],fixture['type']);expect(login['personId'],fixture['personId']);expect(login['linkToken'],fixture['linkToken']);
        expect(login['dob'],'2015-01-01');
        return http.Response(jsonEncode(reply(fixture['schoolId'] as String)),200);
      }));
      await session.login(link,studentClass:'Class 1',roll:'1',dob:'2015-01-01');
      expect(session.loggedIn,true);
      final restored=SchoolSession();await restored.restore();
      expect(restored.link!.schoolId,fixture['schoolId']);expect(restored.link!.role,fixture['type']);expect(restored.loggedIn,true);
    });
  }
  for(final fixture in fixtures) {
    test('compact managed QR retains verified identity without private metadata',() async {
      final raw=SchoolLink.encodeCompact({...fixture,'googleScriptUrl':'https://script.google.com/private','name':'Sensitive name'});
      expect(raw.length,lessThan(150));expect(raw,startsWith('VS3|'));expect(raw, isNot(contains('Sensitive name')));
      final link=SchoolLink.parse(raw);
      expect(link.personId,fixture['personId']);expect(link.linkToken,fixture['linkToken']);
      final session=await QrAuthenticationEngine.authenticate(link,(body)async {
        expect(body['linkToken'],fixture['linkToken']);
        return {...reply(fixture['schoolId'] as String),'person':{'personId':fixture['personId']}};
      });expect(session['schoolId'],fixture['schoolId']);
      expect(()=>SchoolLink.parse(raw.replaceFirst('|s|','|x|').replaceFirst('|t|','|x|')),throwsFormatException);
    });
  }
  test('scanner accepts one shared QR, pauses duplicates and requires retry after invalid QR', () {
    final capture=SchoolQrCapture();
    expect(() => capture.capture('not-a-school-qr'), throwsFormatException);
    expect(capture.paused,isTrue);
    expect(capture.capture(SchoolLink.encode(fixtures.first)),isNull);
    capture.retry();
    expect(capture.capture(SchoolLink.encode(fixtures.first))!.schoolId,fixtures.first['schoolId']);
    expect(capture.capture(SchoolLink.encode(fixtures.last)),isNull);
  });
  test('foreign-school response and wrong credentials never persist a mobile login',() async {
    for(final response in [http.Response(jsonEncode(reply('vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')),200),http.Response(jsonEncode({'success':false,'message':'Wrong credentials'}),403)]) {
      final session=SchoolSession(client:MockClient((_) async=>response));
      await expectLater(session.login(SchoolLink.parse(SchoolLink.encode(fixtures.first))),throwsStateError);
      expect(session.loggedIn,false);expect(session.link,isNull);
      expect(await const FlutterSecureStorage().read(key:'vs_mobile_session'),isNull);
    }
  });
  test('logout during an in-flight login rejects the old response',() async {
    final response=Completer<http.Response>();final started=Completer<void>();
    final session=SchoolSession(client:MockClient((_) {started.complete();return response.future;}));
    final pending=session.login(SchoolLink.parse(SchoolLink.encode(fixtures.first)));
    final failure=expectLater(pending,throwsStateError);
    await started.future;await session.clear();response.complete(http.Response(jsonEncode(reply(fixtures.first['schoolId'] as String)),200));
    await failure;expect(session.loggedIn,false);
    expect(await const FlutterSecureStorage().read(key:'vs_mobile_session'),isNull);
  });
  test('one schema rejects unsupported version, generic school login, unsafe person ID and endpoint',(){
    for(final edit in [{'v':3},{'type':'school'},{'personId':'../foreign'},{'centralEndpoint':'https://evil.example'}]) {
      expect(()=>SchoolLink.parse(jsonEncode({...fixtures.first,...edit})),throwsFormatException);
    }
  });
  test('version detection and parsing never expose JSON parser internals', () {
    for (final raw in ['', 'random text', 'VS4|x', 'VS3|', 'VS3|a|s|%%%|token', '{', '{"v":2,"app":"VIDYA_SAARTHI","firebaseLink":"{bad"}']) {
      try { SchoolLink.parse(raw); fail('Invalid QR accepted: $raw'); }
      on FormatException catch (e) {
        expect(e.message, isNot(contains('Unexpected character')));
        expect(e.message, isNot(contains('RangeError')));
      }
    }
  });
  test('VS3 login rejects malformed school response and retains no session', () async {
    for (final body in ['VS3|unexpected', '<html>Unavailable</html>', '{truncated', '[]']) {
      final session = SchoolSession(client:MockClient((_) async => http.Response(body,200)));
      await expectLater(session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixtures.first))), throwsStateError);
      expect(session.loggedIn,false);
      expect(await const FlutterSecureStorage().read(key:'vs_mobile_session'),isNull);
    }
  });

  test('already printed JSON v2 still uses authenticated mobile login', () async {
    final link=SchoolLink.parse(SchoolLink.encode(fixtures.first));
    expect(SchoolLink.detectVersion(link.rawQr),2);
    final session=SchoolSession(client:MockClient((request) async {
      final body=jsonDecode(request.body) as Map;
      expect((body['request'] as Map)['linkToken'],link.linkToken);
      return http.Response(jsonEncode(reply(link.schoolId)),200);
    }));
    await session.login(link);
    expect(session.loggedIn,true);
  });
  test('tampered VS3 is rejected by server verification, never grants a session', () async {
    final raw=SchoolLink.encodeCompact(fixtures.first);
    final tampered=raw.substring(0,raw.length-1)+'y';
    final session=SchoolSession(client:MockClient((request) async {
      expect(((jsonDecode(request.body) as Map)['request'] as Map)['linkToken'],isNot(fixtures.first['linkToken']));
      return http.Response(jsonEncode({'success':false,'message':'Invalid or revoked ID credential'}),403);
    }));
    await expectLater(session.login(SchoolLink.parse(tampered)),throwsStateError);
    expect(session.loggedIn,false);
    expect(await const FlutterSecureStorage().read(key:'vs_mobile_session'),isNull);
  });

  test(
      'valid issued QR from another environment is distinguished without trusting its endpoint',
      () {
    final raw = jsonEncode({
      ...fixtures.first,
      'centralEndpoint':
          'https://saarthi-sync-v2-test.onrender.com/school-cloud'
    });
    expect(
        () => SchoolLink.parse(raw),
        throwsA(isA<SchoolQrException>()
            .having((e) => e.code, 'code', 'SERVER_ENVIRONMENT_MISMATCH')));
  });
  test('school setup QR is distinct from an issued person card', () {
    expect(
        () =>
            SchoolLink.parse(jsonEncode({...fixtures.first, 'type': 'school'})),
        throwsA(isA<SchoolQrException>()
            .having((e) => e.code, 'code', 'WRONG_QR_KIND')));
  });
  for(final token in ['abcdefghijklmnopqrst','abcdefghijklmnopqrstuvwxyz12345','abcdefghijklmnopqrstuvwx+legacy/token=']) {
    test('valid issued v2 token remains usable when VS3 cannot represent it: ${token.length}',(){
      final raw=SchoolLink.encodeCompact({...fixtures.first,'linkToken':token,'name':'Private fixture'});
      expect(SchoolLink.detectVersion(raw),2);
      expect(SchoolLink.parse(raw).linkToken,token);
      expect(SchoolLink.parse(raw).personId,fixtures.first['personId']);
      expect(raw,isNot(contains('Private fixture')));
    });
  }
  test('v2 fallback cannot accept an invalid issued token',(){
    expect(()=>SchoolLink.encodeCompact({...fixtures.first,'linkToken':'short'}),throwsFormatException);
  });

}
