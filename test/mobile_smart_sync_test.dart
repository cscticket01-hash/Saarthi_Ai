import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../lib/mobile/school_session.dart';
import '../lib/school_backend_transport.dart';
import '../lib/mobile/school_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = Map<String, dynamic>.from(
    (jsonDecode(
          File('test/fixtures/windows_person_qr.json').readAsStringSync(),
        ) as List).first
        as Map,
  );
  final school = fixture['schoolId'] as String;
  Map<String, dynamic> response(Map<String, dynamic> values) => {
    'success': true,
    'schoolId': school,
    'projectId': school,
    ...values,
  };
  Map<String, dynamic> login() => response({
    'sessionToken': 'verified-session',
    'expiresAt': DateTime.now()
        .add(const Duration(hours: 1))
        .millisecondsSinceEpoch,
    'person': {'name': 'Mohit Das', 'class': 'Class 1', 'rollNo': '1'},
    'schoolName': 'Own school',
  });
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test('confirmed attendance survives restart and malformed/failed reads without crossing role cache', () async {
    var offline = false, malformed = false, reads = 0;
    final client = MockClient((request) async {
      final action = (jsonDecode(request.body)['request'] as Map)['action'];
      if (action == 'mobile_login') return http.Response(jsonEncode(login()), 200);
      if (offline) throw const SocketException('offline');
      reads++;
      return http.Response(jsonEncode(response({'attendance': malformed ? 'bad' : [{'date': '2026-10-19', 'checkIn': 123}]})), 200);
    });
    final session = SchoolSession(client: client);
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await Future.wait([session.attendanceHistory('2026-10'), session.attendanceHistory('2026-10')]);
    expect(reads, 1);
    final restored = SchoolSession(client: client); await restored.restore();
    expect(restored.cachedAttendanceHistory('2026-10')!.single['checkIn'], 123);
    offline = true; await expectLater(restored.attendanceHistory('2026-10'), throwsA(isA<SocketException>()));
    expect(restored.cachedAttendanceHistory('2026-10')!.length, 1);
    offline = false; malformed = true;
    await expectLater(restored.attendanceHistory('2026-10'), throwsStateError);
    expect(restored.cachedAttendanceHistory('2026-10')!.length, 1);
    final stored = jsonDecode((await const FlutterSecureStorage().read(key: 'vs_mobile_session'))!) as Map<String,dynamic>;
    stored['cacheRole'] = 'teacher';
    FlutterSecureStorage.setMockInitialValues({'vs_mobile_session': jsonEncode(stored)});
    final foreignRole = SchoolSession(); await foreignRole.restore();
    expect(foreignRole.cachedAttendanceHistory('2026-10'), isNull);
    await restored.clear(); expect(restored.cachedAttendanceHistory('2026-10'), isNull);
  });
  test('ACK hint during an older in-flight dashboard schedules one fresh delta read', () async {
    final oldReply = Completer<http.Response>();
    var dashboardReads = 0;
    final session = SchoolSession(
      client: MockClient((request) async {
        final action = (jsonDecode(request.body)['request'] as Map)['action'];
        if (action == 'mobile_login')
          return http.Response(jsonEncode(login()), 200);
        dashboardReads++;
        if (dashboardReads == 1) return oldReply.future;
        expect(
          (jsonDecode(request.body)['request'] as Map)['afterSignal'],
          true,
        );
        return http.Response(
          jsonEncode(
            response({
              'revision': 'new',
              'notices': [
                {'id': 'new', 'title': 'After ACK'},
              ],
            }),
          ),
          200,
        );
      }),
    );
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    final first = session.refreshDashboard();
    final signal = session.refreshDashboard(afterSignal: true);
    final duplicate = session.refreshDashboard(afterSignal: true);
    oldReply.complete(
      http.Response(
        jsonEncode(response({'revision': 'old', 'notices': []})),
        200,
      ),
    );
    await Future.wait([first, signal, duplicate]);
    expect(dashboardReads, 2);
    expect(session.dashboard['revision'], 'new');
    expect(session.connectionState, SchoolConnectionState.connected);
  });
  test('content-free refresh hints are accepted only for the currently verified school', () {
    expect(
      SchoolNotifications.belongsToSession({
        'schoolId': school,
        'type': 'school_sync',
      }, school),
      true,
    );
    expect(
      SchoolNotifications.belongsToSession({
        'schoolId': 'foreign-school',
        'type': 'school_sync',
      }, school),
      false,
    );
    expect(
      SchoolNotifications.belongsToSession({
        'schoolId': school,
        'type': 'school_sync',
      }, null),
      false,
    );
    expect(
      SchoolNotifications.belongsToSession({
        'schoolId': school,
        'type': 'unknown',
      }, school),
      false,
    );
  });
  test('live dashboard, optional Drive failure, server error and network recovery have distinct states', () async {
    var mode = 'online';
    final session = SchoolSession(
      client: MockClient((request) async {
        final action = (jsonDecode(request.body)['request'] as Map)['action'];
        if (action == 'mobile_login')
          return http.Response(jsonEncode(login()), 200);
        if (mode == 'offline') throw const SocketException('disconnected');
        if (mode == 'server')
          return http.Response(
            jsonEncode({
              'success': false,
              'message': 'School script unavailable',
            }),
            502,
          );
        if (action == 'mobile_document')
          return http.Response(
            jsonEncode({
              'success': false,
              'message': 'Optional file unavailable',
            }),
            502,
          );
        return http.Response(
          jsonEncode(
            response({
              'revision': mode,
              'notices': [
                {'id': 'new-notice', 'title': mode},
              ],
            }),
          ),
          200,
        );
      }),
    );
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await session.refreshDashboard();
    expect(session.connectionState, SchoolConnectionState.connected);
    expect(session.lastDashboardVerifiedAt, isNotNull);
    await expectLater(
      session.schoolCall('mobile_document', {}),
      throwsA(isA<SchoolApiFailure>()),
    );
    expect(session.connectionState, SchoolConnectionState.connected);
    mode = 'server';
    await expectLater(
      session.refreshDashboard(),
      throwsA(isA<SchoolApiFailure>()),
    );
    expect(session.connectionState, SchoolConnectionState.connectionError);
    expect((session.dashboard['notices'] as List).single['title'], 'online');
    mode = 'offline';
    await expectLater(
      session.refreshDashboard(),
      throwsA(isA<SocketException>()),
    );
    expect(session.connectionState, SchoolConnectionState.connectionError);
    mode = 'recovered';
    await session.refreshDashboard();
    expect(session.connectionState, SchoolConnectionState.connected);
    expect((session.dashboard['notices'] as List).single['title'], 'recovered');
  });
  test('HTML 503 and timeout preserve session and verified generation, then recover', () async {
    var mode = 'online';
    final session = SchoolSession(
      client: MockClient((request) async {
        final action = (jsonDecode(request.body)['request'] as Map)['action'];
        if (action == 'mobile_login')
          return http.Response(jsonEncode(login()), 200);
        if (mode == 'server')
          return http.Response('<html>Bad gateway</html>', 503);
        if (mode == 'timeout') throw TimeoutException('synthetic timeout');
        return http.Response(
          jsonEncode(
            response({
              'revision': mode,
              'notices': [
                {'id': 'safe', 'title': mode},
              ],
            }),
          ),
          200,
        );
      }),
    );
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await session.refreshDashboard();
    final verified = session.lastDashboardVerifiedAt;
    mode = 'server';
    await expectLater(
      session.refreshDashboard(),
      throwsA(isA<SchoolApiFailure>()),
    );
    expect(session.loggedIn, true);
    expect(session.lastDashboardVerifiedAt, verified);
    expect(session.connectionMessage, contains('HTTP 503'));
    mode = 'timeout';
    await expectLater(
      session.refreshDashboard(),
      throwsA(isA<TimeoutException>()),
    );
    expect(session.connectionMessage, contains('too long'));
    expect(session.dashboard['revision'], 'online');
    mode = 'recovered';
    await session.refreshDashboard();
    expect(session.connectionState, SchoolConnectionState.connected);
    expect(session.dashboard['revision'], 'recovered');
    final restored = SchoolSession(
      client: MockClient((_) async => throw TimeoutException('outage')),
    );
    await restored.restore();
    expect(
      restored.lastDashboardVerifiedAt?.millisecondsSinceEpoch,
      session.lastDashboardVerifiedAt?.millisecondsSinceEpoch,
    );
    await session.clear();
    await restored.clear();
  });
  test(
    'retry jitter is capped and structural storage failures require review',
    () {
      expect(schoolRetryDelay(1, jitter: 0).inSeconds, 5);
      expect(schoolRetryDelay(20, jitter: 1).inSeconds, 300);
      expect(
        SchoolApiFailure(502, code: 'SCRIPT_PERMISSION_DENIED').retryable,
        false,
      );
      expect(SchoolApiFailure(502, code: 'SCRIPT_TIMEOUT').retryable, true);
    },
  );
  test('expired saved login survives restart and outage; renews without QR; logout persists', () async {
    var offline = false;
    var renewals = 0;
    final client = MockClient((request) async {
      final action = (jsonDecode(request.body)['request'] as Map)['action'];
      if (action == 'mobile_login')
        return http.Response(jsonEncode(login()), 200);
      if (offline) throw const SocketException('offline');
      if (action == 'mobile_refresh') {
        renewals++;
        return http.Response(
          jsonEncode(
            response({
              'expiresAt': DateTime.now()
                  .add(const Duration(days: 30))
                  .millisecondsSinceEpoch,
            }),
          ),
          200,
        );
      }
      return http.Response(jsonEncode(response({'revision': 'renewed'})), 200);
    });
    final initial = SchoolSession(client: client);
    await initial.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    const storage = FlutterSecureStorage();
    final saved = jsonDecode(
      (await storage.read(key: 'vs_mobile_session'))!,
    ) as Map<String, dynamic>;
    saved['expiresAt'] = DateTime.now()
        .subtract(const Duration(days: 365))
        .millisecondsSinceEpoch;
    await storage.write(key: 'vs_mobile_session', value: jsonEncode(saved));
    final restarted = SchoolSession(client: client);
    await restarted.restore();
    expect(restarted.loggedIn, true);
    expect(restarted.cachedAccessAllowed, false);
    offline = true;
    await expectLater(
      restarted.refreshDashboard(),
      throwsA(isA<SocketException>()),
    );
    expect(restarted.loggedIn, true);
    offline = false;
    await Future.wait([
      restarted.refreshDashboard(),
      restarted.refreshDashboard(),
    ]);
    expect(renewals, 1);
    expect(restarted.cachedAccessAllowed, true);
    final again = SchoolSession(client: client);
    await again.restore();
    expect(again.loggedIn, true);
    await again.logout();
    final loggedOut = SchoolSession();
    await loggedOut.restore();
    expect(loggedOut.loggedIn, false);
  });
  test('verified Home and notice survive network/server/Drive outages and secure restart', () async {
    var offline = false;
    var calls = 0;
    final session = SchoolSession(
      client: MockClient((request) async {
        calls++;
        final action = (jsonDecode(request.body)['request'] as Map)['action'];
        if (action == 'mobile_login')
          return http.Response(jsonEncode(login()), 200);
        if (offline) throw const SocketException('temporary offline');
        return http.Response(
          jsonEncode(
            response({
              'revision': 'v1',
              'revisions': {'notices': 'n1'},
              'person': {
                'name': 'Mohit Das',
                'class': 'Class 1',
                'rollNo': '1',
              },
              'notices': [
                {'id': 'n1', 'title': 'School notice'},
              ],
            }),
          ),
          200,
        );
      }),
    );
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await session.refreshDashboard();
    offline = true;
    await expectLater(
      session.refreshDashboard(),
      throwsA(isA<SocketException>()),
    );
    expect(session.dashboard['notices'], isNotEmpty);
    expect(session.cachedAccessAllowed, true);
    final restored = SchoolSession();
    await restored.restore();
    expect(restored.person['name'], 'Mohit Das');
    expect(restored.dashboard['notices'], isNotEmpty);
    expect(calls, 3);
  });
  test(
    'unchanged delta retains notice; changed notice replaces only its group',
    () async {
      var stage = 0;
      final s = SchoolSession(
        client: MockClient((request) async {
          final b = jsonDecode(request.body)['request'] as Map;
          if (b['action'] == 'mobile_login')
            return http.Response(jsonEncode(login()), 200);
          if (stage++ == 0)
            return http.Response(
              jsonEncode(
                response({
                  'revision': 'v1',
                  'revisions': {'notices': 'n1'},
                  'notices': [
                    {'id': '1', '_noticeRevision': 'own-n1'},
                  ],
                  'reportCards': [
                    {'id': 'r1'},
                  ],
                }),
              ),
              200,
            );
          expect(b['knownRevision'], 'v1');
          expect(b['knownNoticeRevisions']['1'], 'own-n1');
          return http.Response(
            jsonEncode(
              response(
                stage == 2
                    ? {'unchanged': true, 'revision': 'v1'}
                    : {
                        'revision': 'v2',
                        'revisions': {'notices': 'n2'},
                        'noticesDelta': true,
                        'noticeIds': ['2', '1'],
                        'notices': [
                          {'id': '2'},
                        ],
                      },
              ),
            ),
            200,
          );
        }),
      );
      await s.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
      await s.refreshDashboard();
      await s.refreshDashboard();
      expect((s.dashboard['notices'] as List).first['id'], '1');
      await s.refreshDashboard();
      expect((s.dashboard['notices'] as List).first['id'], '2');
      expect((s.dashboard['notices'] as List).length, 2);
      expect((s.dashboard['notices'] as List).last['id'], '1');
      expect(s.dashboard['reportCards'], isNotEmpty);
    },
  );
  for (final status in [401, 403])
    test(
      'authoritative $status invalidates verified cache and session',
      () async {
        var denied = false;
        final s = SchoolSession(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode(
                denied
                    ? {'success': false, 'message': 'Licence revoked'}
                    : login(),
              ),
              denied ? status : 200,
            ),
          ),
        );
        await s.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
        denied = true;
        await expectLater(
          s.refreshDashboard(),
          throwsA(isA<SchoolAccessDenied>()),
        );
        expect(s.loggedIn, false);
        expect(s.dashboard, isEmpty);
        final restored = SchoolSession();
        await restored.restore();
        expect(restored.loggedIn, false);
      },
    );
  test('cached PDF opens without network, survives restart, and bad replacement retains old version', () async {
    final root = await Directory.systemTemp.createTemp('vs-mobile-pdf');
    addTearDown(() => root.delete(recursive: true));
    var calls = 0;
    final s = SchoolSession(
      cacheDirectory: () async => root,
      client: MockClient((_) async {
        calls++;
        return http.Response(jsonEncode(login()), 200);
      }),
    );
    await s.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    final pdf = Uint8List.fromList(
      utf8.encode('%PDF-1.7\nverified fixture\n%%EOF'),
    );
    final digest = sha256.convert(pdf).toString();
    await s.cachePdf('idCard', 'v10', pdf, expectedHash: digest);
    await s.cachePdf('report:term1', 'r1', pdf, expectedHash: digest);
    final watch = Stopwatch()..start();
    expect(await s.cachedPdf('idCard'), pdf);
    watch.stop();
    print('MOBILE_CACHED_ID_OPEN_MICROS=${watch.elapsedMicroseconds}');
    expect(calls, 1);
    await expectLater(
      s.cachePdf(
        'idCard',
        'v11',
        Uint8List.fromList([1, 2, 3]),
        expectedHash: digest,
      ),
      throwsStateError,
    );
    expect(s.cachedPdfVersion('idCard'), 'v10');
    expect(await s.cachedPdf('idCard'), pdf);
    final restored = SchoolSession(cacheDirectory: () async => root);
    await restored.restore();
    expect(await restored.cachedPdf('idCard'), pdf);
    expect(await restored.cachedPdf('report:term1'), pdf);
    await restored.clear();
    expect(await restored.cachedPdf('idCard'), isNull);
  });
  test(
    'coalesced refresh and logout discard stale in-flight response',
    () async {
      final answer = Completer<http.Response>();
      var requests = 0;
      final s = SchoolSession(
        client: MockClient((r) async {
          if ((jsonDecode(r.body)['request'] as Map)['action'] ==
              'mobile_login')
            return http.Response(jsonEncode(login()), 200);
          requests++;
          return answer.future;
        }),
      );
      await s.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
      final first = s.refreshDashboard();
      expect(identical(first, s.refreshDashboard()), true);
      final failure = expectLater(first, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      await s.clear();
      answer.complete(
        http.Response(
          jsonEncode(
            response({
              'notices': [
                {'id': 'stale'},
              ],
            }),
          ),
          200,
        ),
      );
      await failure;
      expect(requests, 1);
      expect(s.dashboard, isEmpty);
    },
  );
  test('two mobile devices read the same school-published ID without creating a document', () async {
    final root = await Directory.systemTemp.createTemp('vs-two-mobile-id');
    addTearDown(() => root.delete(recursive: true));
    final pdf = Uint8List.fromList(
      utf8.encode('%PDF-1.7\nexact shared school publication\n%%EOF'),
    );
    final hash = sha256.convert(pdf).toString();
    var downloads = 0;
    final transport = MockClient((request) async {
      final body = jsonDecode(request.body)['request'] as Map;
      if (body['action'] == 'mobile_login')
        return http.Response(jsonEncode(login()), 200);
      if (body['action'] == 'mobile_document') {
        downloads++;
        expect(body['documentId'], 'school-published-card');
        return http.Response(
          jsonEncode(
            response({
              'documentRevision': 'same-revision',
              'contentHash': hash,
              'mime': 'application/pdf',
              'base64': base64Encode(pdf),
            }),
          ),
          200,
        );
      }
      expect(body['action'], 'mobile_dashboard');
      return http.Response(
        jsonEncode(
          response({
            'revision': 'same-dashboard',
            'idCardPackage': {
              'documentId': 'school-published-card',
              'documentRevision': 'same-revision',
              'contentHash': hash,
            },
            'documents': [],
            'reportCards': [],
          }),
        ),
        200,
      );
    });
    for (final device in ['one', 'two']) {
      final folder = Directory('${root.path}/$device');
      await folder.create();
      final session = SchoolSession(
        client: transport,
        cacheDirectory: () async => folder,
      );
      await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
      await session.refreshDashboard();
      expect(await session.publishedIdCard(), pdf);
      expect(await session.publishedIdCard(), pdf);
    }
    expect(
      downloads,
      2,
    ); // One verified cache download per device, zero writes.
  });
  test('exact published ID replaces a known older version; cache survives offline restart; tombstone removes it', () async {
    final root = await Directory.systemTemp.createTemp('vs-published-id');
    addTearDown(() => root.delete(recursive: true));
    var version = 1, downloads = 0;
    var deleted = false, offline = false;
    Uint8List bytes() => Uint8List.fromList(
      utf8.encode('%PDF-1.7\nexact school ID version $version\n%%EOF'),
    );
    final transport = MockClient((request) async {
      final b = jsonDecode(request.body)['request'] as Map;
      if (b['action'] == 'mobile_login')
        return http.Response(jsonEncode(login()), 200);
      if (offline) throw const SocketException('offline');
      final pdf = bytes(), hash = sha256.convert(pdf).toString();
      if (b['action'] == 'mobile_document') {
        downloads++;
        expect(b['documentId'], 'own-card');
        return http.Response(
          jsonEncode(
            response({
              'documentRevision': 'v$version',
              'mime': 'application/pdf',
              'contentHash': hash,
              'base64': base64Encode(pdf),
            }),
          ),
          200,
        );
      }
      return http.Response(
        jsonEncode(
          response({
            'revision': 'dashboard-$version-$deleted',
            'idCardPackage': deleted
                ? null
                : {
                    'documentId': 'own-card',
                    'documentRevision': 'v$version',
                    'contentHash': hash,
                  },
            'documents': [],
            'reportCards': [],
          }),
        ),
        200,
      );
    });
    final session = SchoolSession(
      client: transport,
      cacheDirectory: () async => root,
    );
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await session.refreshDashboard();
    expect(await session.publishedIdCard(), bytes());
    expect(downloads, 1);
    expect(await session.publishedIdCard(), bytes());
    expect(downloads, 1);
    version = 2;
    await session.refreshDashboard();
    expect(await session.publishedIdCard(), bytes());
    expect(downloads, 2);
    offline = true;
    final restored = SchoolSession(
      client: transport,
      cacheDirectory: () async => root,
    );
    await restored.restore();
    expect(await restored.publishedIdCard(), bytes());
    expect(downloads, 2);
    await expectLater(
      restored.refreshDashboard(),
      throwsA(isA<SocketException>()),
    );
    expect(await restored.publishedIdCard(), bytes());
    offline = false;
    deleted = true;
    await restored.refreshDashboard();
    expect(await restored.publishedIdCard(), isNull);
    expect(await restored.cachedPdf('idCard'), isNull);
    final afterDelete = SchoolSession(cacheDirectory: () async => root);
    await afterDelete.restore();
    expect(await afterDelete.cachedPdf('idCard'), isNull);
  });
  test('acknowledged notice IDs remove deleted cached notices without duplicate retries', () async {
    var stage = 0;
    final session = SchoolSession(
      client: MockClient((request) async {
        final b = jsonDecode(request.body)['request'] as Map;
        if (b['action'] == 'mobile_login')
          return http.Response(jsonEncode(login()), 200);
        return http.Response(
          jsonEncode(
            response({
              'revision': 'v${stage++}',
              'noticesDelta': true,
              'noticeIds': stage == 1 ? ['own'] : [],
              'notices': stage == 1
                  ? [
                      {
                        'id': 'own',
                        'title': 'Exact notice',
                        '_noticeRevision': 'r1',
                      },
                    ]
                  : [],
            }),
          ),
          200,
        );
      }),
    );
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await session.refreshDashboard();
    expect(session.dashboard['notices'], hasLength(1));
    await session.refreshDashboard();
    expect(session.dashboard['notices'], isEmpty);
    await session.refreshDashboard();
    expect(session.dashboard['notices'], isEmpty);
    final restored = SchoolSession();
    await restored.restore();
    expect(restored.dashboard['notices'], isEmpty);
  });

  test('a deleted manifest discards an older in-flight ID download without restoring its cache', () async {
    final root = await Directory.systemTemp.createTemp('vs-id-deletion-race');
    addTearDown(() => root.delete(recursive: true));
    final answer = Completer<http.Response>(), started = Completer<void>();
    final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7\nold ID\n%%EOF'));
    final hash = sha256.convert(pdf).toString();
    var deleted = false;
    final session = SchoolSession(
      cacheDirectory: () async => root,
      client: MockClient((request) async {
        final b = jsonDecode(request.body)['request'] as Map;
        if (b['action'] == 'mobile_login')
          return http.Response(jsonEncode(login()), 200);
        if (b['action'] == 'mobile_document') {
          started.complete();
          return answer.future;
        }
        return http.Response(
          jsonEncode(
            response({
              'revision': deleted ? 'deleted' : 'v1',
              'idCardPackage': deleted
                  ? null
                  : {
                      'documentId': 'id',
                      'documentRevision': 'v1',
                      'contentHash': hash,
                    },
            }),
          ),
          200,
        );
      }),
    );
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await session.refreshDashboard();
    final download = session.publishedIdCard();
    final rejected = expectLater(download, throwsStateError);
    await started.future;
    deleted = true;
    await session.refreshDashboard();
    answer.complete(
      http.Response(
        jsonEncode(
          response({
            'documentRevision': 'v1',
            'mime': 'application/pdf',
            'contentHash': hash,
            'base64': base64Encode(pdf),
          }),
        ),
        200,
      ),
    );
    await rejected;
    expect(await session.cachedPdf('idCard'), isNull);
    expect(await session.publishedIdCard(), isNull);
  });

  test('mobile group delta merges changed records, removes acknowledged IDs and rejects incomplete baseline', () async {
    var stage = 0;
    final session = SchoolSession(
      client: MockClient((request) async {
        final b = jsonDecode(request.body)['request'] as Map;
        if (b['action'] == 'mobile_login')
          return http.Response(jsonEncode(login()), 200);
        if (stage > 0) {
          expect(b['knownGroupRecordRevisions']['calendar']['a'], 'a1');
          expect(b['knownGroupRecordRevisions'].containsKey('noticeIds'), isFalse);
          expect(b['knownGroupRecordRevisions'].containsKey('legacyMetadata'), isFalse);
        }
        final payload = stage++ == 0
            ? {
                'revision': 'v1',
                'noticeIds': ['legacy-id'],
                'legacyMetadata': [],
                'revisions': {'calendar': 'c1'},
                'mobileRecordDeltaVersion': 1,
                'groupRecordDeltas': {
                  'calendar': {
                    'ids': ['a', 'b'],
                  },
                },
                'calendar': [
                  {
                    'id': 'a',
                    'title': 'Keep',
                    '_mobileRecordId': 'a',
                    '_mobileRecordRevision': 'a1',
                  },
                  {
                    'id': 'b',
                    'title': 'Before',
                    '_mobileRecordId': 'b',
                    '_mobileRecordRevision': 'b1',
                  },
                ],
              }
            : {
                'revision': 'v2',
                'revisions': {'calendar': 'c2'},
                'mobileRecordDeltaVersion': 1,
                'groupRecordDeltas': {
                  'calendar': {
                    'ids': stage == 2
                        ? ['a', 'b']
                        : stage == 3
                        ? ['a']
                        : ['missing'],
                  },
                },
                'calendar': stage == 2
                    ? [
                        {
                          'id': 'b',
                          'title': 'After',
                          '_mobileRecordId': 'b',
                          '_mobileRecordRevision': 'b2',
                        },
                      ]
                    : [],
              };
        return http.Response(jsonEncode(response(payload)), 200);
      }),
    );
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await session.refreshDashboard();
    await session.refreshDashboard();
    expect((session.dashboard['calendar'] as List)[0]['title'], 'Keep');
    expect((session.dashboard['calendar'] as List)[1]['title'], 'After');
    await session.refreshDashboard();
    expect(session.dashboard['calendar'], hasLength(1));
    await expectLater(session.refreshDashboard(), throwsStateError);
    expect(session.dashboard['calendar'], hasLength(1));
  });
  test(
    'pause immediately gates dashboard calls and hourly idle checks coalesce',
    () async {
      var calls = 0;
      final session = SchoolSession(
        client: MockClient((request) async {
          final b = jsonDecode(request.body)['request'] as Map;
          if (b['action'] == 'mobile_login')
            return http.Response(jsonEncode(login()), 200);
          calls++;
          return http.Response(jsonEncode(response({'revision': 'v1'})), 200);
        }),
      );
      await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
      await session.refreshDashboard();
      expect(calls, 1);
      await session.refreshIfIdleDue();
      expect(calls, 1);
      await session.setSyncPaused(true);
      expect(session.syncPaused, true);
      await session.refreshDashboard(afterSignal: true);
      expect(calls, 1);
      final restored = SchoolSession();
      await restored.restore();
      expect(restored.syncPaused, false); // Upgrades resume hidden background sync.
      await session.setSyncPaused(false);
      expect(calls, 2);
      final due = session.lastDashboardVerifiedAt!.add(
        const Duration(hours: 1),
      );
      await Future.wait([
        session.refreshIfIdleDue(now: due),
        session.refreshIfIdleDue(now: due),
      ]);
      expect(calls, 3);
    },
  );
  test('dashboard quota survives restart and notification bursts without extra reads or false verification', () async {
    var quota = false, reads = 0;
    final client = MockClient((request) async {
      final action = (jsonDecode(request.body)['request'] as Map)['action'];
      if (action == 'mobile_login') return http.Response(jsonEncode(login()), 200);
      if (action != 'mobile_dashboard') return http.Response(jsonEncode(response({})), 200);
      reads++;
      if (quota) return http.Response(jsonEncode({'success': false, 'code': 'SCRIPT_QUOTA_EXCEEDED'}), 429);
      return http.Response(jsonEncode(response({'revision': 'verified-before-quota', 'notices': []})), 200);
    });
    final session = SchoolSession(client: client);
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await session.refreshDashboard();
    final verified = session.lastDashboardVerifiedAt!.millisecondsSinceEpoch;
    quota = true;
    await expectLater(session.refreshDashboard(afterSignal: true), throwsA(isA<SchoolApiFailure>()));
    expect(session.dashboardQuotaRetryAt!.millisecondsSinceEpoch,
        greaterThan(DateTime.now().add(const Duration(seconds: 58)).millisecondsSinceEpoch));
    for (var i = 0; i < 5; i++) {
      await expectLater(session.refreshDashboard(afterSignal: true), throwsA(isA<SchoolApiFailure>()));
    }
    expect(reads, 2);
    expect(session.lastDashboardVerifiedAt!.millisecondsSinceEpoch, verified);
    final restored = SchoolSession(client: client);await restored.restore();
    expect(restored.dashboard['revision'], 'verified-before-quota');
    expect(restored.dashboardQuotaRetryAt, session.dashboardQuotaRetryAt);
    await expectLater(restored.refreshDashboard(afterSignal: true), throwsA(isA<SchoolApiFailure>()));
    expect(reads, 2);
    await session.clear();await restored.clear();
  });

}
