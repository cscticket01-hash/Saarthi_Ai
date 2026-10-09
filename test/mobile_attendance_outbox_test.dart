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
    await store.finish('owner', id, 'restart', {'state':'needsAttention'});
    expect(await store.hasDue('owner',100000),false);
    await store.retryReview('foreign');expect((await store.pending('owner')).single['state'],'needsAttention');
    await store.retryReview('owner');expect(await store.hasDue('owner',100000),true);expect((await store.pending('owner')).single['state'],'pending');
  });
  test('SQLite pending count is exact beyond a bounded inventory page', () async {
    final db = await store.database;
    await db.transaction((tx) async { for (var i=0;i<1001;i++) { await tx.insert('attendance', {'id':'row$i','owner':'owner','day':'2026-10-08','mode':'entry','capturedAt':i,'payload':'{}','state':'pending'}); }});
    expect((await store.summary('owner'))['pending'], 1001);
  });
  test('offline save survives logout/restart; accepted is pending until exact final cloud ACK', () async {
    var offline = false, wrongAck = false, completed = false;
    final day = DateTime.now().toUtc().add(const Duration(hours:5,minutes:30)).toIso8601String().substring(0,10);
    final permit = {'schoolId':school,'role':fixture['type'],'documentId':fixture['personId'],'personId':'stable-pupil','day':day};
    final token = '${base64UrlEncode(utf8.encode(jsonEncode(permit)))}.fixture';
    final operation = sha256.convert(utf8.encode(jsonEncode([school,fixture['type'],'stable-pupil',day,'entry']))).toString();
    Map<String,dynamic> reply(Map<String,dynamic> fields) => {'success':true,'schoolId':school,'projectId':school,...fields};
    final transport = MockClient((r) async {
      final request = Map<String,dynamic>.from(jsonDecode(r.body)['request']);
      final action = request['action'];
      if (offline) throw const SocketException('offline');
      Map<String,dynamic> out;
      if (action=='mobile_login') out=reply({'sessionToken':'verified','person':{'personId':fixture['personId']},'expiresAt':DateTime.now().add(const Duration(hours:1)).millisecondsSinceEpoch});
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
  test(
      'server-issued permit is reused only for its live session; ACK polling avoids another Drive refresh',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final day = DateTime.now()
        .toUtc()
        .add(const Duration(hours: 5, minutes: 30))
        .toIso8601String()
        .substring(0, 10);
    final person = fixture['personId'], role = fixture['type'];
    final body = {
      'purpose': 'attendance',
      'schoolId': school,
      'role': role,
      'documentId': person,
      'personId': 'stable',
      'day': day,
      'expiresAt': now + 300000,
      'sessionHash': sha256.convert(utf8.encode('verified')).toString(),
      'qrHash': sha256
          .convert(utf8.encode('$role/$person/${fixture['linkToken']}'))
          .toString()
    };
    final token =
        '${base64UrlEncode(utf8.encode(jsonEncode(body)))}.${List.filled(64, 'a').join()}';
    final operation = sha256
        .convert(
            utf8.encode(jsonEncode([school, role, 'stable', day, 'entry'])))
        .toString();
    var refreshes = 0, marks = 0, statuses = 0;
    final client = MockClient((request) async {
      final b = jsonDecode(request.body)['request'] as Map;
      Map<String, dynamic> data = {
        'success': true,
        'schoolId': school,
        'projectId': school
      };
      if (b['action'] == 'mobile_login')
        data.addAll({
          'sessionToken': 'verified',
          'expiresAt': now + 3600000,
          'person': {'personId': person},
          'attendancePermit': token
        });
      if (b['action'] == 'mobile_refresh') {
        refreshes++;
        data.addAll({'expiresAt': now + 3600000, 'attendancePermit': token});
      }
      if (b['action'] == 'mobile_mark_attendance') {
        marks++;
        expect(b['clientCapturedAt'], now);
        data.addAll({
          'syncProtocol': 2,
          'accepted': true,
          'operationId': sha256
              .convert(utf8
                  .encode(jsonEncode([school, role, 'stable', day, b['mode']])))
              .toString()
        });
      }
      if (b['action'] == 'mobile_attendance_status') {
        statuses++;
        data.addAll({
          'syncProtocol': 2,
          'operations': [
            {
              'operationId': operation,
              'state': 'completed',
              'createdAt': now,
              'completedAt': now + 1
            }
          ]
        });
      }
      return http.Response(jsonEncode(data), 200);
    });
    final session = SchoolSession(client: client, attendanceStore: store);
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await session.saveAttendance(gps, now, 'entry');
    await session.flushAttendance();
    await (await store.database).update('attendance', {'nextAt': 0});
    await session.flushAttendance();
    expect(refreshes, 0);
    expect(marks, 1);
    expect(statuses, 1);
    expect(session.attendancePending, 0);
    expect(
        (await (await store.database).query('attendance')).single['capturedAt'],
        now);
    final restored = SchoolSession(client: client, attendanceStore: store);
    await restored.restore();
    await restored.saveAttendance(gps, now, 'exit');
    await restored.flushAttendance();
    expect(refreshes, 1); // Permit was not persisted or reused across restore.
  });
}
