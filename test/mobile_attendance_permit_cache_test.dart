import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../lib/attendance_schedule.dart';
import '../lib/mobile/attendance_store.dart';
import '../lib/mobile/school_session.dart';
import '../lib/mobile/session_cache_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final fixture = Map<String, dynamic>.from((jsonDecode(
      File('test/fixtures/windows_person_qr.json').readAsStringSync()) as List).first);
  final school = fixture['schoolId'] as String;
  final role = fixture['type'] as String;
  final person = fixture['personId'] as String;
  final link = SchoolLink.parse(SchoolLink.encodeCompact(fixture));
  const secure = FlutterSecureStorage();
  const gps = {'latitude': 24, 'longitude': 92, 'accuracy': 3};
  late Directory directory;
  late AttendanceStore store;
  final caches = <MobileSessionCacheStore>[];
  Future<Database> openAttendance() => databaseFactoryFfi.openDatabase(
      '${directory.path}/attendance.db', options: OpenDatabaseOptions(version: 1,
      onConfigure: (db) async { await db.execute('PRAGMA synchronous=FULL'); },
      onCreate: (db, _) => AttendanceStore.createSchema(db)));
  Future<Database> openCache() => databaseFactoryFfi.openDatabase(
      '${directory.path}/session.db', options: OpenDatabaseOptions(version: 1,
      singleInstance: false,
      onConfigure: (db) async { await db.execute('PRAGMA synchronous=FULL'); },
      onCreate: (db, _) => MobileSessionCacheStore.createSchema(db)));
  MobileSessionCacheStore cache() {
    final value = MobileSessionCacheStore(openDatabaseOverride: openCache);
    caches.add(value);
    return value;
  }
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('vs-permit-cache');
    store = AttendanceStore(openDatabaseOverride: openAttendance);
  });
  tearDown(() async {
    await store.close();
    for (final value in caches) { await value.close(); }
    caches.clear();
    await directory.delete(recursive: true);
  });
  Map<String, dynamic> approval(int now) => {
    'purpose': 'attendance', 'schoolId': school, 'role': role,
    'documentId': person, 'personId': 'stable-pupil',
    'day': attendanceDay(DateTime.fromMillisecondsSinceEpoch(now)),
    'expiresAt': now + 300000,
    'sessionHash': sha256.convert(utf8.encode('verified')).toString(),
    'qrHash': sha256.convert(utf8.encode('$role/$person/${fixture['linkToken']}')).toString(),
  };
  String encode(Map<String, dynamic> value) =>
      '${base64UrlEncode(utf8.encode(jsonEncode(value)))}.${'a' * 64}';
  Map<String, dynamic> response(Map<String, dynamic> value) => {
    'success': true, 'schoolId': school, 'projectId': school, ...value,
  };
  Map<String, dynamic> login(String token, int now) => response({
    'sessionToken': 'verified', 'expiresAt': now + 3600000,
    'person': {'personId': person}, 'attendancePermit': token,
    'attendanceStatus': {'version': 1, 'day': attendanceDay(DateTime.now()),
      'recorded': false, 'schedule': null},
  });
  String operation(String day) => sha256.convert(utf8.encode(
      jsonEncode([school, role, 'stable-pupil', day, 'entry']))).toString();

  for (final encrypted in [false, true]) {
    test('valid permit survives offline restart in ${encrypted ? 'encrypted shared' : 'secure'} cache without a Drive refresh', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final day = attendanceDay(DateTime.now()), token = encode(approval(now));
      var offline = false, refreshes = 0, marks = 0, statuses = 0;
      final client = MockClient((r) async {
        if (offline) throw const SocketException('Synthetic offline');
        final request = jsonDecode(r.body)['request'] as Map;
        switch (request['action']) {
          case 'mobile_login': return http.Response(jsonEncode(login(token, now)), 200);
          case 'mobile_refresh':
            refreshes++;
            return http.Response(jsonEncode(response({'attendancePermit': token})), 200);
          case 'mobile_mark_attendance':
            marks++;
            expect(request['attendancePermit'], token);
            return http.Response(jsonEncode(response({'syncProtocol': 2,
              'accepted': true, 'operationId': operation(day)})), 200);
          case 'mobile_attendance_status':
            statuses++;
            expect(request['attendancePermit'], token);
            return http.Response(jsonEncode(response({'syncProtocol': 2, 'operations': [
              {'operationId': operation(day), 'state': 'completed',
                'createdAt': now, 'completedAt': now + 1}]})), 200);
        }
        return http.Response(jsonEncode(response({})), 200);
      });
      final frontCache = encrypted ? cache() : null;
      final session = SchoolSession(client: client, attendanceStore: store,
          sharedSessionStore: frontCache);
      await session.login(link);
      final snapshot = jsonDecode(encrypted ? (await frontCache!.read())!
          : (await secure.read(key: 'vs_mobile_session'))!) as Map;
      expect(snapshot['attendancePermit'], token);
      expect(jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(
          (snapshot['attendancePermit'] as String).split('.').first))))['expiresAt'],
          approval(now)['expiresAt'], reason: 'No approval expiry extension');
      if (encrypted) {
        final rows = await (await frontCache!.database).query('session_snapshot');
        expect(jsonEncode(rows), isNot(contains(token)));
      }
      offline = true;
      await session.saveAttendance(gps, now, 'entry');
      await session.flushAttendance();
      final owner = AttendanceStore.owner(link.endpoint, school, role, person);
      expect((await store.pending(owner)).single['capturedAt'], now);
      await store.close();
      store = AttendanceStore(openDatabaseOverride: openAttendance);
      final restored = SchoolSession(client: client, attendanceStore: store,
          sharedSessionStore: encrypted ? cache() : null);
      await restored.restore();
      expect(restored.loggedIn, true);
      offline = false;
      await (await store.database).update('attendance', {'nextAt': 0});
      await restored.flushAttendance();
      expect(refreshes, 0);
      expect(marks, 1);
      expect(restored.attendancePending, 1);
      expect(restored.lastAttendanceAck, isNull);
      await (await store.database).update('attendance', {'nextAt': 0});
      await restored.flushAttendance();
      expect(statuses, 1);
      expect(restored.attendancePending, 0);
      expect(restored.lastAttendanceAck, isNotNull);
      expect((await (await store.database).query('attendance')).single['capturedAt'], now);
    });
  }

  for (final invalid in ['missing', 'malformed', 'wrong-type', 'expired', 'school', 'role',
    'person', 'session', 'qr', 'day', 'beyond-session', 'policy-expired']) {
    test('$invalid persisted permit falls back to a fresh verified approval', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final day = attendanceDay(DateTime.now()), token = encode(approval(now));
      var refreshes = 0, marks = 0;
      final client = MockClient((r) async {
        final request = jsonDecode(r.body)['request'] as Map;
        if (request['action'] == 'mobile_login') return http.Response(jsonEncode(login(token, now)), 200);
        if (request['action'] == 'mobile_refresh') {
          refreshes++;
          return http.Response(jsonEncode(response({'attendancePermit': token,
            'policyExpiresAt': now + 3600000})), 200);
        }
        if (request['action'] == 'mobile_mark_attendance') {
          marks++;
          expect(request['attendancePermit'], token);
          return http.Response(jsonEncode(response({'syncProtocol': 2,
            'accepted': true, 'operationId': operation(day)})), 200);
        }
        return http.Response(jsonEncode(response({})), 200);
      });
      await SchoolSession(client: client, attendanceStore: store).login(link);
      final owner = AttendanceStore.owner(link.endpoint, school, role, person);
      await store.save(owner, day, 'entry', now, gps);
      final snapshot = jsonDecode((await secure.read(key: 'vs_mobile_session'))!) as Map;
      final changed = approval(now);
      switch (invalid) {
        case 'expired': changed['expiresAt'] = now - 1; break;
        case 'school': changed['schoolId'] = 'vs-${'b' * 32}'; break;
        case 'role': changed['role'] = role == 'student' ? 'teacher' : 'student'; break;
        case 'person': changed['documentId'] = 'another-pupil'; break;
        case 'session': changed['sessionHash'] = 'b' * 64; break;
        case 'qr': changed['qrHash'] = 'b' * 64; break;
        case 'day': changed['day'] = '2000-01-01'; break;
        case 'beyond-session': changed['expiresAt'] = now + 7200000; break;
      }
      if (invalid == 'missing') { snapshot.remove('attendancePermit'); }
      else if (invalid == 'wrong-type') { snapshot['attendancePermit'] = 42; }
      else { snapshot['attendancePermit'] = invalid == 'malformed' ? 'bad' : encode(changed); }
      if (invalid == 'policy-expired') snapshot['policyExpiresAt'] = now - 1;
      await secure.write(key: 'vs_mobile_session', value: jsonEncode(snapshot));
      final restored = SchoolSession(client: client, attendanceStore: store);
      await restored.restore();
      await restored.flushAttendance();
      expect(restored.loggedIn, true);
      expect(refreshes, 1);
      expect(marks, 1);
      expect((await store.pending(owner)).single['capturedAt'], now);
      expect(restored.lastAttendanceAck, isNull);
    });
  }

  for (final outage in ['offline', 'timeout', '503']) {
    test('$outage retry retains the same live approval and original capture', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final day = attendanceDay(DateTime.now()), token = encode(approval(now));
      var failing = true, refreshes = 0, marks = 0;
      final captured = <int>[];
      final client = MockClient((r) async {
        final request = jsonDecode(r.body)['request'] as Map;
        if (request['action'] == 'mobile_login') return http.Response(jsonEncode(login(token, now)), 200);
        if (request['action'] == 'mobile_refresh') {
          refreshes++;
          return http.Response(jsonEncode(response({'attendancePermit': token})), 200);
        }
        if (request['action'] == 'mobile_mark_attendance') {
          marks++;
          captured.add(request['clientCapturedAt'] as int);
          expect(request['attendancePermit'], token);
          if (failing) {
            if (outage == 'offline') throw const SocketException('Synthetic offline');
            if (outage == 'timeout') throw TimeoutException('Synthetic transport timeout');
            return http.Response(jsonEncode({'success': false, 'code': 'SCRIPT_TIMEOUT'}), 503);
          }
          return http.Response(jsonEncode(response({'syncProtocol': 2,
            'accepted': true, 'operationId': operation(day)})), 200);
        }
        return http.Response(jsonEncode(response({})), 200);
      });
      final session = SchoolSession(client: client, attendanceStore: store);
      await session.login(link);
      final owner = AttendanceStore.owner(link.endpoint, school, role, person);
      await store.save(owner, day, 'entry', now, gps);
      await session.flushAttendance();
      final retained = (await store.pending(owner)).single;
      expect(retained['state'], 'pending');
      expect(retained['attempts'], 1);
      expect(retained['nextAt'] as int, greaterThan(now));
      failing = false;
      await (await store.database).update('attendance', {'nextAt': 0});
      await session.flushAttendance();
      expect(refreshes, 0);
      expect(marks, 2);
      expect(captured, [now, now]);
      expect((await store.pending(owner)).single['id'], retained['id']);
      expect((await store.pending(owner)).single['state'], 'accepted');
      expect(session.lastAttendanceAck, isNull);
    });
  }

  test('a cached valid approval cannot bypass a fresh server access denial', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final token = encode(approval(now)), day = attendanceDay(DateTime.now());
    final client = MockClient((r) async {
      final request = jsonDecode(r.body)['request'] as Map;
      if (request['action'] == 'mobile_login') return http.Response(jsonEncode(login(token, now)), 200);
      return http.Response(jsonEncode({'success': false, 'message': 'School access inactive'}), 403);
    });
    await SchoolSession(client: client, attendanceStore: store).login(link);
    final owner = AttendanceStore.owner(link.endpoint, school, role, person);
    await store.save(owner, day, 'entry', now, gps);
    final restored = SchoolSession(client: client, attendanceStore: store);
    await restored.restore();
    await restored.flushAttendance();
    expect(restored.loggedIn, false);
    expect(restored.lastAttendanceAck, isNull);
    expect(await secure.read(key: 'vs_mobile_session'), isNull);
    final row = (await store.pending(owner)).single;
    expect(row['state'], 'needsAttention');
    expect(row['capturedAt'], now);
  });
}
