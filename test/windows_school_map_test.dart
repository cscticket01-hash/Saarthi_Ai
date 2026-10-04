import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../lib/windows_school_map.dart';
import '../lib/windows_school_map_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('map launcher hands a correctly encoded Google Maps URL to the browser', () async {
    final uri = schoolMapsSearchUri('School 12 & Girls, Assam');
    expect(uri.queryParameters['query'], 'School 12 & Girls, Assam');
    expect(uri.queryParameters['api'], '1');
    await WindowsSchoolMaps.open(uri, opener: (u) async { expect(u, uri); return true; });
    await expectLater(WindowsSchoolMaps.open(uri, opener: (_) async => false), throwsStateError);
    await expectLater(WindowsSchoolMaps.open(Uri.parse('file:///school')), throwsArgumentError);
  });
  test('coordinates must be a full valid finite pair, never arbitrary address numbers', () {
    for (final text in ['24.8012345, 92.8012345', '(24.8012345, 92.8012345)', '-24.8 92.8']) {
      expect(parseSchoolMapPin(text), isNotNull);
    }
    for (final text in ['', 'Street 12 Assam 788001', 'NaN, 92', '91, 92', '24, 181', '24,92,200']) {
      expect(parseSchoolMapPin(text), isNull, reason: text);
    }
  });
  test('a place pin takes priority over a different Google Maps camera centre', () {
    final pin = parseSchoolMapPin('https://www.google.com/maps/place/School+12/@24.7,92.7,17z/data=!4m2!3m1!3d24.8123456!4d92.8123456');
    expect(pin!.latitude, 24.8123456); expect(pin.longitude, 92.8123456);
    expect(pin.name, 'School 12');
    expect(pin.mapsUri.queryParameters['query'], '24.8123456, 92.8123456');
    expect(parseSchoolMapPin('https://www.google.com/maps/@24.7,92.7,17z'), isNull);
    expect(parseSchoolMapPin('https://www.google.com/maps/search/?api=1&query=School+12'), isNull);
    expect(parseSchoolMapPin('https://evil.example/maps/?q=24,92'), isNull);
    expect(parseSchoolMapPin('https://www.google.com/maps/search/?api=1&query=24.8%2C92.8')!.latitude, 24.8);
  });
  test('short Maps share links resolve only through trusted HTTPS Google redirects', () async {
    final client = MockClient((r) async => http.Response('', 302, headers: {
      'location':'https://www.google.com/maps/place/School/data=!3d24.8!4d92.8'}));
    final pin = await WindowsSchoolMaps.resolve('https://maps.app.goo.gl/example', client: client);
    expect(pin!.latitude, 24.8); client.close();
    for (final target in ['http://www.google.com/maps/?q=24,92', 'https://evil.example/maps/?q=24,92']) {
      final c = MockClient((_) async => http.Response('', 302, headers:{'location':target}));
      expect(await WindowsSchoolMaps.resolve('https://maps.app.goo.gl/example', client:c), isNull);
      c.close();
    }
  });
  test('200 metre geofence denies outside, invalid and uncertain boundary positions', () {
    const school = SchoolMapPin(0,0);
    SchoolMapPin at(double metres) => SchoolMapPin(metres / 6371000 * 180 / pi, 0);
    expect(schoolDistanceMeters(school, at(200)), closeTo(200, 0.001));
    expect(schoolAttendancePositionAllowed(school, at(180), accuracyMeters:10), isTrue);
    expect(schoolAttendancePositionAllowed(school, at(201), accuracyMeters:0), isFalse);
    expect(schoolAttendancePositionAllowed(school, at(195), accuracyMeters:10), isFalse);
    expect(schoolAttendancePositionAllowed(school, school, accuracyMeters:1000), isFalse);
    expect(schoolAttendancePositionAllowed(school, school, accuracyMeters:double.nan), isFalse);
    expect(schoolAttendancePositionAllowed(school, const SchoolMapPin(91,0), accuracyMeters:1), isFalse);
  });
  testWidgets('pin picker returns the confirmed point and cannot confirm a camera-only link', (tester) async {
    SchoolMapPin? result;
    await tester.binding.setSurfaceSize(const Size(1000,1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home:Builder(builder:(context)=>Scaffold(body:TextButton(
      onPressed:() async { result=await selectWindowsSchoolMapPin(context, schoolName:'Test School'); }, child:const Text('Select'))))));
    await tester.tap(find.text('Select')); await tester.pumpAndSettle();
    final confirm=find.text('Use this school pin • 200 m');
    expect(tester.widget<FilledButton>(find.ancestor(of:confirm, matching:find.byType(FilledButton))).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'https://www.google.com/maps/@24.8,92.8,17z');
    await tester.tap(find.text('Read pin')); await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.ancestor(of:confirm, matching:find.byType(FilledButton))).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '24.8123456, 92.8123456');
    await tester.tap(find.text('Read pin')); await tester.pumpAndSettle();
    expect(find.text('Attendance boundary: 200 metres from this pin'), findsOneWidget);
    await tester.tap(confirm); await tester.pumpAndSettle();
    expect(result!.latitude, 24.8123456); expect(result!.longitude, 92.8123456);
  });
}
