import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../lib/windows_connect/managed_school_session.dart';
import '../../lib/windows_firebase_sync.dart';
import '../../lib/windows_pending_school_sync.dart';
import '../../lib/windows_local_firestore.dart';
import '../../lib/mobile/school_session.dart';
import '../../lib/mobile/attendance_store.dart';
import '../../lib/sync_latency_statistics.dart';

// Bounded real TEST observations, not a 400-school load or physical-device test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('100 TEST records use existing Windows outbox and verified receiver snapshots', () async {
    const school = 'vs-db8afb01a3be46a983c8284714d06e5d';
    const endpoint = 'https://saarthi-sync-v2-test.onrender.com/school-cloud';
    if (Platform.environment['GITHUB_ACTIONS'] != 'true' ||
        Platform.environment['VS_TEST_LATENCY_CONFIRM'] != school ||
        Platform.environment['VS_TEST_LATENCY_RECORDS'] != '100') {
      throw StateError('Explicit bounded canonical TEST latency authorization required.');
    }
    HttpOverrides.global = null;
    FlutterSecureStorage.setMockInitialValues({});
    final report = <String, dynamic>{
      'status': 'RUNNING', 'schoolId': school,
      'sourceSha': Platform.environment['GITHUB_SHA'],
      'scope': 'Hosted Windows SQLite production outbox/batch helpers, real TEST broker/Drive, actual SchoolSession applied cache and website review protocol applied snapshot',
      'recordTarget': 100, 'cohortSize': 5, 'cohortTarget': 20,
      'correlation': 'Five record observations share each serial cohort; not 100 independent network trials or devices.',
      'clock': 'One producer-host monotonic Stopwatch; no cross-host UTC subtraction.',
      'conditions': 'Authenticated/warmed TEST; explicit receiver refresh after ACK; discovery wait, browser paint, physical Android and production capacity excluded.',
      'physicalDevicesVerified': false, 'browserPaintMeasured': false,
      'cohorts': <Map<String, dynamic>>[], 'samples': <Map<String, dynamic>>[],
      'failureCount': 0, 'censoredRecords': 0, 'permanentDeletion': false,
    };
    final tmp = await Directory.systemTemp.createTemp('vs-latency-');
    final client = http.Client();
    SchoolSession? mobile;
    AttendanceStore? store;
    final all = Stopwatch()..start();
    final samples = report['samples'] as List<Map<String, dynamic>>;
    final cohorts = report['cohorts'] as List<Map<String, dynamic>>;
    final db = FirebaseFirestore.instance;
    var stage = 'exact runtime';
    try {
      final expected = Platform.environment['VS_EXPECTED_TEST_RUNTIME'] ?? '';
      if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(expected)) throw StateError('Reviewed runtime required.');
      final healthResponse = await client.get(Uri.parse('$endpoint/healthz')).timeout(const Duration(seconds: 120));
      final runtime = jsonDecode(healthResponse.body) as Map;
      expect(healthResponse.statusCode, 200); expect(runtime['ready'], true);
      expect(runtime['projectId'], 'saarthi-ai-df12b'); expect(runtime['runtimeCommit'], expected);
      report['runtimeCommit'] = expected;
      stage = 'authenticated TEST identity';
      final login = await ManagedSchoolSession.login(Platform.environment['VS_TEST_LOGIN_EMAIL']!,
        Platform.environment['VS_TEST_LOGIN_PASSWORD']!, endpoint: endpoint);
      expect(login['schoolId'], school); expect(login['allowed'], true);
      final health = await ManagedSchoolSession.callForSchool(school, 'managed/storage/check', {});
      expect(health['recordWriteBatchVersion'], 1); expect(health['brokerRecordWriteBatchVersion'], 1);
      expect(health['scriptBundleVersion'], '2026-10-26.2');
      report['scriptBundleVersion'] = health['scriptBundleVersion'];
      WindowsFirebaseRemote.recordWriteBatchSupported = true;
      WindowsFirebaseRemote.recordFieldPatchSupported = health['recordFieldPatchVersion'] == 1;
      WindowsFirebaseRemote.recordPointReadSupported = health['recordPointReadVersion'] == 1;
      final run = Platform.environment['GITHUB_RUN_ID']!, attempt = Platform.environment['GITHUB_RUN_ATTEMPT'] ?? '1';
      expect(RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(run), true);
      expect(RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(attempt), true);
      final prefix = 'latency-v1-$run-$attempt';
      final profile = 'TEST-$prefix', person = '$prefix-person';
      final linkToken = sha256.convert(utf8.encode('$prefix/private-test-link')).toString();
      await db.changeLocalStorageLocation('${tmp.path}/windows');
      await db.switchProfile(profile, identity: {'schoolId': school, 'schoolSyncId': school});
      expect((await db.collection('_windows_firebase_outbox').get()).docs, isEmpty);
      stage = 'fresh synthetic TEST person';
      await ManagedSchoolSession.callForSchool(school, 'managed/records', {
        'collection': 'students_directory', 'operation': 'write', 'id': person, 'syncProtocol': 2,
        'operationId': '$prefix-person-create', 'expectedRecordRevision': '', 'data': {
          'schoolId': school, 'syntheticTest': true, 'name': 'Synthetic latency TEST',
          'class': '1', 'section': prefix, 'rollNo': '999999', 'dob': '2015-01-01',
          'mobileStableId': person, 'mobileLinkToken': linkToken,
        },
      });
      sqfliteFfiInit();
      Future<Database> openAttendance() => databaseFactoryFfi.openDatabase('${tmp.path}/attendance.db',
        options: OpenDatabaseOptions(version: 1, onCreate: (value, _) => AttendanceStore.createSchema(value)));
      store = AttendanceStore(openDatabaseOverride: openAttendance);
      mobile = SchoolSession(client: client, persistSession: (_) async {}, attendanceStore: store,
        cacheDirectory: () async => tmp);
      final qr = SchoolLink.encodeCompact({'managed': true, 'schoolId': school, 'centralEndpoint': endpoint,
        'type': 'student', 'personId': person, 'linkToken': linkToken});
      await mobile.login(SchoolLink.parse(qr), studentClass: '1', roll: '999999', dob: '2015-01-01');
      await mobile.refreshDashboard(afterSignal: true);
      final receiver = mobile;
      final websiteKnown = <String, String>{};
      final websiteCache = <String, dynamic>{};
      final timer = Stopwatch()..start();
      for (var cohort = 0; cohort < 20; cohort++) {
        if (all.elapsed > const Duration(minutes: 45)) throw StateError('Bounded measurement deadline.');
        expect((await db.collection('_windows_firebase_outbox').get()).docs, isEmpty);
        final rows = <Map<String, dynamic>>[];
        stage = 'cohort $cohort local durable save';
        for (var index = 0; index < 5; index++) {
          final id = '$prefix-notice-${cohort * 5 + index}';
          final start = timer.elapsedMicroseconds;
          await db.collection('school_notices').doc(id).set({'schoolId': school, 'syntheticTest': true,
            'title': 'Synthetic latency $id', 'timestamp': DateTime.now().millisecondsSinceEpoch});
          final row = <String, dynamic>{'id': id, 'cohort': cohort, 'queuedMicros': start,
            'localDurableSaveMicros': timer.elapsedMicroseconds - start};
          rows.add(row); samples.add(row);
        }
        final pendingBefore = (await db.collection('_windows_firebase_outbox').get()).docs;
        expect(pendingBefore, hasLength(5));
        final originalOps = {for (final row in pendingBefore) row.data()!['documentId']: row.data()!['operationId']};
        for (final row in rows) row['operationId'] = originalOps[row['id']];
        stage = 'cohort $cohort cloud verified ACK';
        var requests = 0;
        Future<Map<String, Object>> prepare() => WindowsFirebaseRemote.prepareManagedBatch(school,
          canAdmit: () => db.activeProfileId == profile,
          send: (boundSchool, operations) async {
            requests++; expect(boundSchool, school);
            return ManagedSchoolSession.callForSchool(school, 'managed/records/batch', {'operations': operations});
          });
        final receipts = await prepare();
        final canonical = <String, Map<String, dynamic>>{}, revisions = <String, String>{};
        await WindowsPendingSchoolSync.flush(profileId: profile,
          send: (a, b, c, d) async => throw StateError('Versioned owner required.'),
          prepareVersioned: (ref, item) => WindowsFirebaseRemote.prepareQueuedRecord(ref, item, school),
          canonicalForAck: (item) => canonical[item['operationId']],
          sendVersioned: (item) async {
            expect(item['operationId'], originalOps[item['documentId']]);
            if (receipts.isEmpty) receipts.addAll(await prepare());
            final receipt = receipts.remove(item['operationId']);
            if (receipt is Exception) throw receipt;
            if (receipt == null) requests++;
            final reply = await WindowsFirebaseRemote.syncManagedRecord(item, school,
              batchReply: receipt is Map<String, dynamic> ? receipt : null);
            if (reply['record'] is Map) canonical[item['operationId'] as String] = Map<String, dynamic>.from(reply['record']);
            final revision = reply['recordRevision'] as String;
            revisions[item['documentId'] as String] = revision;
            return revision;
          },
          onActivity: (event) {
            if (event['stage'] == 'verified') {
              final row = rows.singleWhere((row) => row['id'] == event['documentId']);
              row['queueToVerifiedAckMicros'] = timer.elapsedMicroseconds - (row['queuedMicros'] as int);
            }
          });
        expect((await db.collection('_windows_firebase_outbox').get()).docs, isEmpty);
        for (final row in rows) expect(row['queueToVerifiedAckMicros'], isA<int>());
        stage = 'cohort $cohort verified receiver apply';
        final observation = <String, dynamic>{'cohort': cohort, 'records': 5, 'writeRequests': requests};
        cohorts.add(observation);
        await Future.wait([
          (() async {
            await receiver.refreshDashboard(afterSignal: true);
            final notices = (receiver.dashboard['notices'] as List).whereType<Map>();
            for (final row in rows) {
              final remote = notices.singleWhere((notice) => notice['id'] == row['id']);
              expect(remote['title'], 'Synthetic latency ${row['id']}');
              row['windowsToMobileAppliedMicros'] = timer.elapsedMicroseconds - (row['queuedMicros'] as int);
            }
            expect(receiver.lastDashboardVerifiedAt, isNotNull);
          })(),
          (() async {
            final result = await ManagedSchoolSession.callForSchool(school, 'managed/changes', {
              'collections': ['school_notices'], 'knownRevisions': websiteKnown,
            });
            expect(result['schoolId'], school);
            final group = (result['changes'] as Map)['school_notices'] as Map;
            expect(group['unchanged'], isNot(true));
            final received = Map<String, dynamic>.from(group['records'] as Map);
            for (final row in rows) {
              final remote = received[row['id']] as Map;
              expect(remote['syntheticTest'], true); expect(remote['_syncRevision'], revisions[row['id']]);
            }
            // Apply only after every record and its authoritative revision verifies.
            websiteCache.clear(); websiteCache.addAll(received);
            websiteKnown['school_notices'] = group['collectionRevision'] as String;
            for (final row in rows) {
              expect((websiteCache[row['id']] as Map)['title'], 'Synthetic latency ${row['id']}');
              row['windowsToWebsiteProtocolAppliedMicros'] = timer.elapsedMicroseconds - (row['queuedMicros'] as int);
            }
          })(),
        ]);
        observation['complete'] = true;
      }
      expect(samples, hasLength(100)); expect(cohorts, hasLength(20));
      expect((await db.collection('_windows_firebase_outbox').get()).docs, isEmpty);
      for (final metric in ['localDurableSaveMicros', 'queueToVerifiedAckMicros',
          'windowsToMobileAppliedMicros', 'windowsToWebsiteProtocolAppliedMicros']) {
        report[metric] = syncLatencyQuantiles(samples.map((row) => row[metric] as int));
      }
      report['status'] = 'PASS'; report['independentCohorts'] = 20; report['pending'] = 0;
      report['attemptedRecords'] = 100; report['unattemptedRecords'] = 0; report['percentilesWithheld'] = false;
      report['statisticalLimit'] = 'Record-level empirical quantiles from20correlatedcohorts; p99 is an observed tail/max, not a production tail guarantee or a 400-school concurrency result.';
    } catch (_) {
      report['status'] = 'FAIL'; report['failedStage'] = stage; report['failureCount'] = 1;
      report['attemptedRecords'] = samples.length;
      report['unattemptedRecords'] = 100 - samples.length;
      report['censoredRecords'] = samples.where((row) => !row.containsKey('windowsToMobileAppliedMicros') || !row.containsKey('windowsToWebsiteProtocolAppliedMicros')).length;
      report['percentilesWithheld'] = true; // Never exclude failures to manufacture PASS percentiles.
      rethrow;
    } finally {
      report['elapsedMs'] = all.elapsedMilliseconds;
      try { report['pending'] = (await db.collection('_windows_firebase_outbox').get()).docs.length; } catch (_) {}
      await mobile?.closeBackgroundInvocation(); client.close();
      final output = File('build/cloud-prerequisites/sync3-latency.json'); await output.parent.create(recursive: true);
      await output.writeAsString(jsonEncode(report)); print(jsonEncode(report));
    }
  }, timeout: const Timeout(Duration(minutes: 60)));
}
