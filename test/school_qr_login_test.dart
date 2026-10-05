import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../lib/school_qr_link.dart';
import '../lib/mobile/school_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixtures = (jsonDecode(File('test/fixtures/windows_person_qr.json').readAsStringSync()) as List).map((v)=>Map<String,dynamic>.from(v as Map)).toList();
  setUp(()=>FlutterSecureStorage.setMockInitialValues({}));
  Map<String,dynamic> reply(String school) => {'success':true,'schoolId':school,'projectId':school,'sessionToken':'verified-session',
    'expiresAt':DateTime.now().add(const Duration(hours:1)).millisecondsSinceEpoch,'person':{'name':'Own person'},'schoolName':'Own school'};
  for(final fixture in fixtures) {
    test('Windows ${fixture['type']} QR encodes the exact envelope Android uses to login and restore',() async {
      final raw=SchoolLink.encode(fixture);
      expect(jsonDecode(raw),fixture);
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
}
