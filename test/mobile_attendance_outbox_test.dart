import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../lib/mobile/attendance_store.dart';
import '../lib/mobile/attendance_confirmation_schedule.dart';
import '../lib/attendance_schedule.dart';
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
  test('fresh processing confirmations stay short only within a bounded server-created window', () {
    const created = 100000;
    for (final state in ['pending', 'processing']) {
      expect(attendanceUsesFastConfirmation(state: state, createdAt: created,
        now: created + 29999), true);
      for (final attempts in [2, 3, 4, 20]) {
        expect(attendanceConfirmationDelay(state: state, createdAt: created,
          attempts: attempts, now: created + 29999), const Duration(seconds: 5));
      }
      expect(attendanceConfirmationDelay(state: state, createdAt: created,
        attempts: 4, now: created + 30000), const Duration(seconds: 20));
      expect(attendanceUsesFastConfirmation(state: state, createdAt: created,
        now: created + 30000), false);
      expect(attendanceConfirmationDelay(state: state, createdAt: created,
        attempts: 20, now: created + 60000), const Duration(seconds: 30));
    }
  });
  test('retry, unknown and untrusted timestamps retain existing confirmation backoff', () {
    for (final state in ['retry', 'unknown', null]) {
      expect(attendanceUsesFastConfirmation(state: state, createdAt: 100000,
        now: 100001), false);
      for (var attempts = 2; attempts <= 6; attempts++) {
        expect(attendanceConfirmationDelay(state: state, createdAt: 100000,
          attempts: attempts, now: 100001).inSeconds,
          [5, 10, 20, 30, 30][attempts - 2]);
      }
    }
    for (final created in <Object?>[null, '100000', 100000.0, 0, -1, 100002]) {
      expect(attendanceUsesFastConfirmation(state: 'processing', createdAt: created,
        now: 100001), false);
      expect(attendanceConfirmationDelay(state: 'processing', createdAt: created,
        attempts: 5, now: 100001), const Duration(seconds: 30));
    }
  });
  test('daily lock survives pending, needs-review, ACK and restart; schools, roles and days stay separate', () async {
    final a = AttendanceStore.owner('https://example.test', 'school-A', 'student', 'same-id');
    final b = AttendanceStore.owner('https://example.test', 'school-B', 'student', 'same-id');
    final teacher = AttendanceStore.owner('https://example.test', 'school-A', 'teacher', 'same-id');
    const day = '2026-10-19';
    final id = await store.save(a, day, 'entry', 1000, gps, oncePerDay: true);
    await expectLater(store.save(a, day, 'entry', 2000, gps, oncePerDay: true), throwsStateError);
    expect(await store.capturedOn(a, day), true);
    expect(await store.capturedOn(b, day), false);
    expect(await store.capturedOn(teacher, day), false);
    expect(await store.capturedOn(a, '2026-10-20'), false);
    await store.save(b, day, 'entry', 2000, gps, oncePerDay: true);
    await store.save(teacher, day, 'entry', 3000, gps, oncePerDay: true);
    final row = await store.claim(a, 4000, 'review');
    expect(row!['id'], id);
    await store.finish(a, id, 'review', {'state': 'needsAttention'});
    expect(await store.capturedOn(a, day), true);
    await store.retryReview(a);
    await store.claim(a, 5000, 'ack');
    await store.finish(a, id, 'ack', {'state': 'completed', 'completedAt': 6000});
    await store.close(); store = AttendanceStore(openDatabaseOverride: open);
    expect(await store.pending(a), isEmpty);
    expect(await store.capturedOn(a, day), true);
    await expectLater(store.save(a, day, 'exit', 7000, gps, oncePerDay: true), throwsStateError);
  });
  test(
    'entry and exit lock independently across review, restart and concurrent taps',
    () async {
      const owner = 'school-A/student-1', day = '2026-10-19';
      await store.save(owner, day, 'entry', 1000, gps, oncePerMode: true);
      expect(await store.capturedOn(owner, day, mode: 'entry'), true);
      expect(await store.capturedOn(owner, day, mode: 'exit'), false);
      final results = await Future.wait(
        [2000, 3000].map((at) async {
          try {
            await store.save(owner, day, 'exit', at, gps, oncePerMode: true);
            return true;
          } on StateError {
            return false;
          }
        }),
      );
      expect(results.where((v) => v).length, 1);
      await store.close();
      store = AttendanceStore(openDatabaseOverride: open);
      expect(await store.capturedOn(owner, day, mode: 'exit'), true);
      await expectLater(
        store.save(owner, day, 'exit', 4000, gps, oncePerMode: true),
        throwsStateError,
      );
      expect((await store.pending(owner)).length, 2);
      expect(
        await store.capturedOn('school-B/student-1', day, mode: 'exit'),
        false,
      );
    },
  );
  test('saved school session checks in and out without another login; pending actions stay locked', () async {
    final day = attendanceDay(DateTime.now()), at = DateTime.now().millisecondsSinceEpoch;
    final session = SchoolSession(attendanceStore: store, client: MockClient((_) async =>
      http.Response(jsonEncode({'success': true, 'schoolId': school, 'projectId': school,
        'sessionToken': 'verified', 'expiresAt': at + 3600000,
        'person': {'personId': fixture['personId']},
        'attendanceStatus': {'version': 1, 'day': day, 'recorded': false, 'schedule': null}}), 200)));
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await session.setSyncPaused(true); // Deterministic offline queue capture.
    await session.refreshAttendanceStatus();
    expect(session.attendanceLockFor('exit'), contains('Check in before'));
    await expectLater(session.saveAttendance(gps, at, 'exit'), throwsStateError);
    await session.saveAttendance(gps, at, 'entry');
    expect(session.attendanceLockFor('entry'), contains('Locked'));
    expect(session.attendanceLockFor('exit'), isEmpty);
    await session.saveAttendance(gps, at + 1, 'exit');
    expect(session.attendanceLockFor('exit'), contains('Locked'));
    expect(session.attendancePending, 2);
    final restored = SchoolSession(attendanceStore: store);
    await restored.restore(); await restored.refreshAttendanceStatus();
    expect(restored.attendanceLockFor('entry'), contains('Locked'));
    expect(restored.attendanceLockFor('exit'), contains('Locked'));
  });
  test('concurrent daily captures commit once without replacing original payload', () async {
    final results = await Future.wait([1000, 2000].map((at) async {
      try { await store.save('owner', '2026-10-19', 'entry', at, gps, oncePerDay: true); return true; }
      on StateError { return false; }
    }));
    expect(results.where((v) => v).length, 1);
    expect((await store.pending('owner')).length, 1);
  });
  test('schedule uses IST boundaries, malformed schedules fail closed and next day is independent', () {
    const window = {'enabled': true, 'startMinute': 480, 'endMinute': 600};
    expect(attendanceWindowAllows(window, DateTime.parse('2026-10-19T02:29:59Z')), false);
    expect(attendanceWindowAllows(window, DateTime.parse('2026-10-19T02:30:00Z')), true);
    expect(attendanceWindowAllows(window, DateTime.parse('2026-10-19T04:29:59Z')), true);
    expect(attendanceWindowAllows(window, DateTime.parse('2026-10-19T04:30:00Z')), false);
    expect(attendanceWindowAllows({'enabled': true, 'startMinute': 700, 'endMinute': 600}, DateTime.now()), false);
    expect(attendanceWindowAllows(null, DateTime.now()), true);
    expect(attendanceDay(DateTime.parse('2026-10-19T18:30:00Z')), '2026-10-20');
  });
  test('student requires schedule-capable school response and remote recorded state only locks its own day', () async {
    final day = attendanceDay(DateTime.now());
    final session = SchoolSession(attendanceStore: store, client: MockClient((_) async =>
      http.Response(jsonEncode({'success': true, 'schoolId': school, 'projectId': school,
        'sessionToken': 'verified', 'expiresAt': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
        'person': {'personId': fixture['personId']}}), 200)));
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await session.refreshAttendanceStatus();
    expect(session.attendanceLockReason, contains('Refresh school'));
    session.dashboard = {'attendanceStatus': {'version': 0, 'day': day}};
    expect(session.attendanceLockReason, contains('update required'));
    session.dashboard = {'attendanceStatus': {'version': 1, 'day': day, 'recorded': true, 'schedule': null}};
    expect(session.attendanceLockReason, contains('Locked'));
    session.dashboard = {'attendanceStatus': {'version': 1, 'day': '2000-01-01', 'recorded': true, 'schedule': null}};
    expect(session.attendanceLockReason, isEmpty);
    session.dashboard = {'attendanceStatus': {'version': 1, 'day': day, 'recorded': false,
      'schedule': {'enabled': true, 'startMinute': 600, 'endMinute': 480}}};
    expect(session.attendanceLockReason, contains('outside'));
  });
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
  test('original issued-card identity survives restart without storing credentials', () async {
    await store.save('issued-owner','2026-10-08','entry',1000,{...gps,'cardIssueId':'a'*64,'sessionToken':'must-not-store','originalAttendancePermit':'synthetic-signed-permit','originalPermitHash':sha256.convert(utf8.encode('synthetic-signed-permit')).toString(),'originalCardOfflineLease':'synthetic-signed-approval'});
    await store.close();store=AttendanceStore(openDatabaseOverride:open);
    final payload=jsonDecode((await store.pending('issued-owner')).single['payload'] as String) as Map;
    expect(payload['cardIssueId'],'a'*64);expect(payload.containsKey('sessionToken'),false);expect(payload['originalAttendancePermit'],'synthetic-signed-permit');expect(payload['originalCardOfflineLease'],'synthetic-signed-approval');
    await expectLater(store.save('issued-owner','2026-10-08','exit',1001,{...gps,'originalAttendancePermit':'synthetic-signed-permit','originalPermitHash':'tampered'}),throwsStateError);
    await expectLater(store.save('issued-owner','2026-10-08','exit',1001,{...gps,'cardIssueId':'invalid'}),throwsStateError);
  });
  test('SQLite pending count is exact beyond a bounded inventory page', () async {
    final db = await store.database;
    await db.transaction((tx) async { for (var i=0;i<1001;i++) { await tx.insert('attendance', {'id':'row$i','owner':'owner','day':'2026-10-08','mode':'entry','capturedAt':i,'payload':'{}','state':'pending'}); }});
    expect((await store.summary('owner'))['pending'], 1001);
  });
  test('shared 502 stops the batch and preserves both original captures without ACK', () async {
    var writes = 0;
    final day = DateTime.now().toUtc().add(const Duration(hours:5,minutes:30)).toIso8601String().substring(0,10);
    final permit = {'schoolId':school,'role':fixture['type'],'documentId':fixture['personId'],'personId':'stable','day':day};
    final token = '${base64UrlEncode(utf8.encode(jsonEncode(permit)))}.fixture';
    final session = SchoolSession(attendanceStore:store,client:MockClient((r) async {
      final action = (jsonDecode(r.body)['request'] as Map)['action'];
      if (action == 'mobile_mark_attendance') {
        writes++;
        return http.Response(jsonEncode({'success':false,'code':'SCRIPT_TIMEOUT'}),502);
      }
      return http.Response(jsonEncode({'success':true,'schoolId':school,'projectId':school,
        'sessionToken':'verified','person':{'personId':fixture['personId']},
        'expiresAt':DateTime.now().add(const Duration(hours:1)).millisecondsSinceEpoch,
        'attendancePermit':token}),200);
    }));
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    final owner = AttendanceStore.owner(session.link!.endpoint,school,fixture['type'],fixture['personId']);
    await store.save(owner,day,'entry',1000,gps); await store.save(owner,day,'exit',2000,gps);
    await session.flushAttendance();
    expect(writes,1); expect(session.loggedIn,true);expect(session.attendancePending,2);
    expect(session.attendanceAccepted,0);expect(session.lastAttendanceAck,isNull);
    expect((await store.pending(owner)).map((r)=>r['capturedAt']).toSet(),{1000,2000});
    await session.clear();
  });
  for (final rejection in [
    (
      400,
      'ATTENDANCE_OUTSIDE_SCHOOL',
      'Attendance can be marked only within the school location',
      'outside the school',
    ),
    (400, '', 'Accurate school location required', 'accuracy'),
    (
      400,
      'ATTENDANCE_SCHOOL_CLOSED',
      'School is closed today. Attendance is disabled for everyone',
      'School is closed',
    ),
    (
      409,
      'ATTENDANCE_CAPTURE_REVIEW',
      'Attendance capture date needs school review.',
      'capture date',
    ),
    (400, '', 'PRIVATE_TOKEN_NEVER_DISPLAY', 'request was rejected'),
  ]) {
    test(
      'policy rejection ${rejection.$3} retains capture and stops automatic retry',
      () async {
        var writes = 0;
        final day = DateTime.now()
            .toUtc()
            .add(const Duration(hours: 5, minutes: 30))
            .toIso8601String()
            .substring(0, 10);
        final permit = {
          'schoolId': school,
          'role': fixture['type'],
          'documentId': fixture['personId'],
          'personId': 'stable',
          'day': day,
        };
        final token =
            '${base64UrlEncode(utf8.encode(jsonEncode(permit)))}.fixture';
        final session = SchoolSession(
          attendanceStore: store,
          client: MockClient((r) async {
            final action = (jsonDecode(r.body)['request'] as Map)['action'];
            if (action == 'mobile_mark_attendance') {
              writes++;
              return http.Response(
                jsonEncode({
                  'success': false,
                  'code': rejection.$2,
                  'message': rejection.$3,
                  'requestId': '11111111-1111-1111-1111-111111111111',
                }),
                rejection.$1,
              );
            }
            return http.Response(
              jsonEncode({
                'success': true,
                'schoolId': school,
                'projectId': school,
                'sessionToken': 'verified',
                'person': {'personId': fixture['personId']},
                'expiresAt': DateTime.now()
                    .add(const Duration(hours: 1))
                    .millisecondsSinceEpoch,
                'attendancePermit': token,
              }),
              200,
            );
          }),
        );
        await session.login(
          SchoolLink.parse(SchoolLink.encodeCompact(fixture)),
        );
        final owner = AttendanceStore.owner(
          session.link!.endpoint,
          school,
          fixture['type'],
          fixture['personId'],
        );
        await store.save(owner, day, 'entry', 1000, gps);
        await session.flushAttendance();
        await session.flushAttendance();
        expect(writes, 1);
        expect(session.loggedIn, true);
        expect(session.attendanceAccepted, 0);
        expect(session.attendanceFailure, contains(rejection.$4));
        expect(session.attendanceFailure, isNot(contains('PRIVATE_TOKEN')));
        expect(
          session.attendanceFailure,
          contains('11111111-1111-1111-1111-111111111111'),
        );
        final row = (await store.pending(owner)).single;
        expect(row['state'], 'needsAttention');
        expect(row['capturedAt'], 1000);
        expect(jsonDecode(row['payload'] as String)['latitude'], 24);
        await store.close();
        store = AttendanceStore(openDatabaseOverride: open);
        expect((await store.pending(owner)).single['id'], row['id']);
        await session.clear();
      },
    );
  }
  test('offline save survives logout/restart; accepted is pending until exact final cloud ACK', () async {
    var offline = false, wrongAck = false, completed = false;
    final day = DateTime.now().toUtc().add(const Duration(hours:5,minutes:30)).toIso8601String().substring(0,10);
    final permit = {'schoolId':school,'role':fixture['type'],'documentId':fixture['personId'],'personId':'stable-pupil','day':day};
    final token = '${base64UrlEncode(utf8.encode(jsonEncode(permit)))}.fixture';
    final operation = sha256.convert(utf8.encode(jsonEncode([school,fixture['type'],'stable-pupil',day,'entry']))).toString();
    Map<String,dynamic> reply(Map<String,dynamic> fields) => {'success':true,'schoolId':school,'projectId':school,'attendanceStatus':{'version':1,'day':day,'recorded':false,'schedule':null},...fields};
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
    expect(session.attendanceLockReason, contains('Locked'));
    await expectLater(session.saveAttendance(gps,captured+1,'entry'), throwsStateError);
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
    var completed = false, statusResponseAt = 0, acceptedResponseAt = 0;
    final client = MockClient((request) async {
      final b = jsonDecode(request.body)['request'] as Map;
      Map<String, dynamic> data = {
        'success': true,
        'schoolId': school,
        'projectId': school,
        'attendanceStatus': {'version': 1, 'day': day, 'recorded': false, 'schedule': null}
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
        acceptedResponseAt = DateTime.now().millisecondsSinceEpoch;
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
        // A response received later must get a fresh future deadline, rather
        // than reusing the timestamp from before the network request.
        await Future<void>.delayed(const Duration(milliseconds: 30));
        statusResponseAt = DateTime.now().millisecondsSinceEpoch;
        data.addAll({
          'syncProtocol': 2,
          'operations': [
            {
              'operationId': operation,
              'state': completed ? 'completed' : 'processing',
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
    final accepted = (await (await store.database).query('attendance')).single;
    expect(accepted['state'], 'accepted');
    expect(accepted['nextAt'] as int,
        greaterThanOrEqualTo(acceptedResponseAt + 5000));
    expect(accepted['nextAt'] as int,
        lessThanOrEqualTo(DateTime.now().millisecondsSinceEpoch + 5000));
    await (await store.database).update('attendance', {'nextAt': 0});
    await session.flushAttendance();
    expect(refreshes, 0);
    expect(marks, 1);
    expect(statuses, 1);
    expect(session.attendancePending, 1);
    expect(session.lastAttendanceAck, isNull);
    final processing = (await (await store.database).query('attendance')).single;
    expect(processing['state'], 'accepted');
    expect(processing['operationId'], operation);
    expect(processing['attempts'], accepted['attempts']);
    expect(processing['nextAt'] as int, greaterThanOrEqualTo(statusResponseAt + 5000));
    await session.flushAttendance();
    expect(statuses, 1, reason: 'No eager loop before the confirmation deadline');
    for (var check = 0; check < 3; check++) {
      await (await store.database).update('attendance', {'nextAt': 0});
      await session.flushAttendance();
      expect((await (await store.database).query('attendance')).single['attempts'],
          accepted['attempts'], reason: 'Healthy checks do not inflate failure backoff');
    }
    expect(statuses, 4);
    await (await store.database).update('attendance', {'nextAt': 0, 'attempts': 7});
    await session.flushAttendance();
    expect((await (await store.database).query('attendance')).single['attempts'], 7,
        reason: 'Fast confirmation never resets retained retry history');
    completed = true;
    await (await store.database).update('attendance', {'nextAt': 0});
    await session.flushAttendance();
    expect(statuses, 6);
    expect(marks, 1, reason: 'Status confirmation never resubmits the capture');
    expect(session.attendancePending, 0);
    expect(
        (await (await store.database).query('attendance')).single['capturedAt'],
        now);
    final restored = SchoolSession(client: client, attendanceStore: store);
    await restored.restore();
    await expectLater(restored.saveAttendance(gps, now, 'entry'), throwsStateError);
    expect(restored.attendanceLockReason, contains('Locked'));
    await restored.flushAttendance();
    expect(marks, 1); // No second capture or second server write after restart.
    expect(refreshes, 0);
  });
}
