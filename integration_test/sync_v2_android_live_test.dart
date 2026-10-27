import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../lib/main_android.dart' show SaarthiMobileApp;
import '../lib/mobile/attendance_store.dart';
import '../lib/mobile/school_session.dart';
import '../lib/windows_connect/managed_school_session.dart';

class _NetworkBoundary extends http.BaseClient {
  final inner = http.Client();
  bool offline = false;
  final _timings = <Map<String, Object?>>[];
  List<Map<String, Object?>> get requestTimings => List.unmodifiable(_timings);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) async {
    if (offline) throw const SocketException('TEST offline boundary');
    String? action;
    if (r is http.Request) {
      try {
        final envelope = jsonDecode(r.body);
        if (envelope is Map) {
          final mobile = envelope['request'];
          final value = mobile is Map ? mobile['action'] : envelope['action'];
          if (value is String &&
              const {'mobile_refresh', 'mobile_mark_attendance',
                     'mobile_attendance_status'}.contains(value)) action = value;
        }
      } catch (_) { /* Never log a raw request or credential. */ }
    }
    final clock = Stopwatch()..start();
    try {
      final response = await inner.send(r);
      if (action != null && _timings.length < 100) {
        _timings.add({'action': action, 'headerLatencyMs': clock.elapsedMilliseconds,
                      'http': response.statusCode});
      }
      return response;
    } catch (_) {
      if (action != null && _timings.length < 100) {
        _timings.add({'action': action, 'headerLatencyMs': clock.elapsedMilliseconds,
                      'transportError': true});
      }
      rethrow;
    }
  }

  @override
  void close() => inner.close();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'Android OS native SQLite and secure restore -> real TEST ACK -> production dashboard',
      (tester) async {
    const school = 'vs-db8afb01a3be46a983c8284714d06e5d';
    const endpoint = 'https://saarthi-sync-v2-test.onrender.com/school-cloud';
    const run = String.fromEnvironment('VS_TEST_RUN_ID');
    if (!Platform.isAndroid ||
        const String.fromEnvironment('VS_TEST_CONNECT_CONFIRM') != school ||
        run.isEmpty) throw StateError('Isolated Android TEST runner required');
    HttpOverrides.global = null;
    final metrics = <String, dynamic>{
      'scope':
          'Android API 35 emulator, native SQLite/secure-storage plugins, actual production dashboard; injected offline network boundary',
      'schoolId': school,
      'status': 'RUNNING'
    };
    try {
      // Render before native plugins and real network requests so the hosted
      // Flutter driver can attach while cloud work waits.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      print('VS_ANDROID_TEST_STAGE first_frame');
      await tester.runAsync(() async {
        final transport = _NetworkBoundary();
        var store = AttendanceStore();
        final credentialsFile = File(
            '${(await getApplicationSupportDirectory()).path}/vs_test_credentials.json');
        final credentials =
            jsonDecode(await credentialsFile.readAsString()) as Map;
        await credentialsFile
            .delete(); // Supplied privately with adb run-as, never compiled into APK.
        if (credentials['VS_TEST_CONNECT_CONFIRM'] != school)
          throw StateError('TEST credential scope required');
        try {
          final admin = await ManagedSchoolSession.login(
              credentials['VS_TEST_LOGIN_EMAIL'] as String,
              credentials['VS_TEST_LOGIN_PASSWORD'] as String,
              endpoint: endpoint);
          expect(admin['schoolId'], school);
          print('VS_ANDROID_TEST_STAGE authenticated');
          // Registration label and the operational school profile are separate.
          // Prepare missing synthetic TEST branding with the existing CAS protocol.
          final config = await ManagedSchoolSession.callForSchool(
              school, 'managed/records', {
            'operation': 'read',
            'collection': 'school_config',
            'syncProtocol': 2
          });
          expect(config['schoolId'], school);
          final existingProfile =
              (config['records'] as Map)['school_profile_cache'];
          final profile = existingProfile is Map
              ? Map<String, dynamic>.from(existingProfile)
              : <String, dynamic>{};
          final configuredName = profile['schoolName']?.toString().trim() ?? '';
          if (configuredName.isEmpty) {
            final data = {
              ...profile,
              'schoolId': school,
              'schoolName': 'TEST Sync V2',
              'syntheticTest': true
            };
            data.removeWhere((key, value) => key.startsWith('_sync'));
            final ack = await ManagedSchoolSession.callForSchool(
                school, 'managed/records', {
              'operation': 'write',
              'collection': 'school_config',
              'id': 'school_profile_cache',
              'syncProtocol': 2,
              'operationId': 'android-test-branding-$run',
              'expectedRecordRevision': profile['_syncRevision'] ?? '',
              'data': data
            });
            expect(ack['schoolId'], school);
            expect(ack['recordRevision'], isA<String>());
            metrics['syntheticSchoolProfileSeeded'] = true;
          } else {
            expect(configuredName, 'TEST Sync V2',
                reason: 'Existing TEST profile must not be silently replaced');
            metrics['syntheticSchoolProfileSeeded'] = false;
          }
          final person = 'synthetic-android-$run',
              token =
                  sha256.convert(utf8.encode('android-test/$run')).toString();
          await ManagedSchoolSession.callForSchool(school, 'managed/records', {
            'operation': 'write',
            'collection': 'students_directory',
            'id': person,
            'syncProtocol': 2,
            'operationId': 'android-seed-$run',
            'expectedRecordRevision': '',
            'data': {
              'schoolId': school,
              'syntheticTest': true,
              'name': 'Synthetic Android TEST Student',
              'class': '1',
              'section': 'TEST-android-$run',
              'rollNo': '900002',
              'dob': '2015-01-01',
              'mobileStableId': person,
              'mobileLinkToken': token
            }
          });
          final raw = SchoolLink.encodeCompact({
            'managed': true,
            'schoolId': school,
            'centralEndpoint': endpoint,
            'type': 'student',
            'personId': person,
            'linkToken': token
          });
          final session =
              SchoolSession(client: transport, attendanceStore: store);
          await session.login(SchoolLink.parse(raw),
              studentClass: '1', roll: '900002', dob: '2015-01-01');
          await session.refreshDashboard();
          print('VS_ANDROID_TEST_STAGE dashboard');
          expect(session.schoolName, 'TEST Sync V2');
          final windowsNotice =
              'synthetic-hosted-notice-${run.split('-').first}';
          expect(
              (session.dashboard['notices'] as List)
                  .any((row) => row['id'] == windowsNotice),
              true,
              reason:
                  'Native Android must read the notice ACKed by the hosted Windows outbox in this same run');
          metrics['windowsNoticeReadOnNativeAndroid'] = true;
          final webNotice = 'synthetic-web-notice-${run.split('-').first}';
          expect(
              (session.dashboard['notices'] as List).any((row) =>
                  row['id'] == webNotice &&
                  row['title'] ==
                      'Synthetic website exchange ${run.split('-').first}'),
              true);
          metrics['websiteNoticeReadOnNativeAndroid'] = true;
          final captured = DateTime.now().millisecondsSinceEpoch;
          metrics['syntheticPersonId'] = person;
          metrics['originalCapturedAt'] = captured;
          transport.offline = true;
          final save = Stopwatch()..start();
          await session.saveAttendance(
              {'latitude': 24.8, 'longitude': 92.7, 'accuracy': 5},
              captured,
              'entry');
          await session.flushAttendance();
          metrics['offlineNativeSaveMs'] = save.elapsedMilliseconds;
          final owner =
              AttendanceStore.owner(endpoint, school, 'student', person);
          expect((await store.pending(owner)).single['capturedAt'], captured);
          await store.close();
          store = AttendanceStore();
          final restored =
              SchoolSession(client: transport, attendanceStore: store);
          await restored.restore();
          expect(restored.loggedIn, true);
          expect(restored.link!.schoolId, school);
          expect((await store.pending(owner)).single['capturedAt'], captured);
          expect(await store.pending('foreign-owner'), isEmpty);
          transport.offline = false;
          final ack = Stopwatch()..start();
          for (var n = 0; n < 36; n++) {
            await restored.flushAttendance();
            await restored.refreshAttendanceStatus();
            if (restored.attendancePending == 0 &&
                restored.lastAttendanceAck != null) break;
            await Future<void>.delayed(const Duration(seconds: 5));
          }
          expect(restored.attendancePending, 0);
          expect(restored.lastAttendanceAck, isNotNull);
          metrics['androidQueueToDurableAckMs'] = ack.elapsedMilliseconds;
          final verificationRead = Stopwatch()..start();
          final cloud = await ManagedSchoolSession.callForSchool(
              school, 'managed/records', {
            'operation': 'read',
            'collection': 'attendance_records',
            'syncProtocol': 2
          });
          expect(
              (cloud['records'] as Map).values.any((r) =>
                  r['personId'] == person && r['entryCapturedAt'] == captured),
              true);
          metrics['androidQueueToVerifiedCloudReadMs'] =
              ack.elapsedMilliseconds;
          metrics['androidFinalCloudVerificationReadMs'] =
              verificationRead.elapsedMilliseconds;
          // TEST-only request header timings: not Script duration or full body.
          metrics['androidQueueRequestTimings'] = transport.requestTimings;
          print('VS_ANDROID_TEST_STAGE attendance_verified');
          // A verified check-in must lock out same-day duplicate captures,
          // even if the retry uses the original timestamp and coordinates.
          // Do not bypass the real attendance safety policy in acceptance.
          await expectLater(
              restored.saveAttendance(
                  {'latitude': 24.8, 'longitude': 92.7, 'accuracy': 5},
                  captured,
                  'entry'),
              throwsA(isA<StateError>().having(
                  (error) => error.message,
                  'same-day attendance lock',
                  contains('Locked until tomorrow'))));
          await restored.flushAttendance();
          expect(restored.attendancePending,
              0); // Native SQLite must have no second queued operation.
          metrics['sameDayDuplicateCaptureRejected'] = true;
          await SchoolSession.instance.restore();
          expect(SchoolSession.instance.loggedIn, true);
          metrics['nativeCloudChecks'] = 'PASS';
        } finally {
          transport.close();
          await store.close();
        }
      });
      expect(metrics['nativeCloudChecks'], 'PASS',
          reason:
              'An async test failure must never produce a PASS evidence file');
      await tester.pumpWidget(const SaarthiMobileApp());
      await tester.pump();
      expect(find.text('TEST Sync V2'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      metrics['status'] = 'PASS';
    } catch (_) {
      metrics['status'] = 'FAIL';
      rethrow;
    } finally {
      await tester.runAsync(() async {
        await File(
                '${(await getApplicationSupportDirectory()).path}/vs_android_evidence.json')
            .writeAsString(jsonEncode(metrics), flush: true);
      });
      print('VS_ANDROID_OS_EVIDENCE ${jsonEncode(metrics)}');
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
