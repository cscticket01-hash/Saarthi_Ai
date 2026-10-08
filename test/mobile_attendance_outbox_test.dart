import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../lib/mobile/attendance_store.dart';
import '../lib/mobile/school_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final fixture = Map<String, dynamic>.from((jsonDecode(File('test/fixtures/windows_person_qr.json').readAsStringSync()) as List).first);
  final school = fixture['schoolId'] as String;
  late Directory directory;
  late AttendanceStore store;
  Future<Database> open() => databaseFactoryFfi.openDatabase('${directory.path}/attendance.db', options: OpenDatabaseOptions(version: 1,
    onConfigure: (db) async { await db.execute('PRAGMA synchronous=FULL'); }, onCreate: (db, _) => AttendanceStore.createSchema(db)));
  setUp(() async { FlutterSecureStorage.setMockInitialValues({}); directory = await Directory.systemTemp.createTemp('vs-attendance-fixture'); store = AttendanceStore(openDatabaseOverride: open); });
  tearDown(() async { await store.close(); await directory.delete(recursive: true); });
  const gps = {'latitude': 24, 'longitude': 92, 'accuracy': 3};
  test('SQLite commit survives restart; duplicate capture and foreign owner cannot overwrite or claim it', () async {
    final id = await store.save('owner', '2026-10-08', 'entry', 1000, gps);
    await store.save('owner', '2026-10-08', 'entry', 2000, gps);
    await store.close(); store = AttendanceStore(openDatabaseOverride: open);
    expect((await store.pending('owner')).single['capturedAt'], 1000);
    expect(await store.pending('foreign'), isEmpty);
    final claimed = await store.claim('owner', 3000, 'lease'); expect(claimed!['id'], id);
    expect(await store.claim('owner', 3001, 'other'), isNull);
    await store.finish('owner', id, 'wrong-lease', {'state': 'completed'});
    expect((await store.pending('owner')).single['state'], 'pending');
    expect((await store.claim('owner', 93001, 'restart'))!['capturedAt'], 1000);
  });
  test('SQLite pending count is exact beyond a bounded inventory page', () async {
    final db = await store.database;
    await db.transaction((tx) async { for (var i=0;i<1001;i++) { await tx.insert('attendance', {'id':'row$i','owner':'owner','day':'2026-10-08','mode':'entry','capturedAt':i,'payload':'{}','state':'pending'}); }});
    expect((await store.summary('owner'))['pending'], 1001);
  });
  test('offline save survives logout/restart; accepted is pending until exact final cloud ACK', () async {
    var offline = false, wrongAck = false, completed = false;
    final day = DateTime.now().toUtc().add(const Duration(hours:5,minutes:30)).toIso8601String().substring(0,10);
    final permit = {'schoolId':school,'role':fixture['role'],'documentId':fixture['personId'],'personId':'stable-pupil','day':day};
    final token = '${base64UrlEncode(utf8.encode(jsonEncode(permit)))}.fixture';
    final operation = sha256.convert(utf8.encode(jsonEncode([school,fixture['role'],'stable-pupil',day,'entry']))).toString();
    Map<String,dynamic> reply(Map<String,dynamic> fields) => {'success':true,'schoolId':school,'projectId':school,...fields};
    final transport = MockClient((r) async {
      final request = Map<String,dynamic>.from(jsonDecode(r.body)['request']);
      final action = request['action'];
      if (offline) throw const SocketException('offline');
      Map<String,dynamic> out;
      if (action=='mobile_login') out=reply({'sessionToken':'verified','expiresAt':DateTime.now().add(const Duration(hours:1)).millisecondsSinceEpoch});
      else if (action=='mobile_refresh') out=reply({'attendancePermit':token,'expiresAt':DateTime.now().add(const Duration(hours:1)).millisecondsSinceEpoch});
      else if (action=='mobile_mark_attendance') { expect(request['clientCapturedAt'], isA<int>()); out=reply({'syncProtocol':2,'accepted':true,'operationId':operation}); }
      else if (action=='mobile_attendance_status') out=reply({'syncProtocol':2,'operations':[{'operationId':wrongAck?'wrong':operation,'state':completed?'completed':'retry','createdAt':1000,'completedAt':2000}]});
      else out=reply({});
      return http.Response(jsonEncode(out),200);
    });
    var session=SchoolSession(client:transport,attendanceStore:store);
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    offline=true;
    final captured=DateTime.now().millisecondsSinceEpoch;
    await session.saveAttendance(gps,captured,'entry');await session.flushAttendance();expect(session.attendancePending,1);
    await session.logout();
    session=SchoolSession(client:transport,attendanceStore:store);await session.restore();expect(session.loggedIn,false);
    offline=false;await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));await session.flushAttendance();
    expect(session.attendancePending,1);expect(session.attendanceAccepted,1);
    final db=await store.database;await db.update('attendance',{'nextAt':0});
    wrongAck=true;completed=true;await session.flushAttendance();expect(session.attendancePending,1);
    await db.update('attendance',{'nextAt':0});wrongAck=false;await session.flushAttendance();
    expect(session.attendancePending,0);expect(session.lastAttendanceAck,isNotNull);
    expect((await db.query('attendance')).single['capturedAt'],captured); // Retained audit row, no deletion.
  });
}
