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
  test('exact published ID replaces a known older version; cache survives offline restart; tombstone removes it', () async {
    final root = await Directory.systemTemp.createTemp('vs-published-id');
    addTearDown(() => root.delete(recursive: true));
    var version = 1, downloads = 0;
    var deleted = false, offline = false;
    Uint8List bytes() => Uint8List.fromList(utf8.encode('%PDF-1.7\nexact school ID version $version\n%%EOF'));
    final transport = MockClient((request) async {
      final b = jsonDecode(request.body)['request'] as Map;
      if (b['action'] == 'mobile_login') return http.Response(jsonEncode(login()), 200);
      if (offline) throw const SocketException('offline');
      final pdf = bytes(), hash = sha256.convert(pdf).toString();
      if (b['action'] == 'mobile_document') {
        downloads++; expect(b['documentId'], 'own-card');
        return http.Response(jsonEncode(response({'documentRevision':'v$version',
          'mime':'application/pdf', 'contentHash':hash, 'base64':base64Encode(pdf)})), 200);
      }
      return http.Response(jsonEncode(response({'revision':'dashboard-$version-$deleted',
        'idCardPackage': deleted ? null : {'documentId':'own-card','documentRevision':'v$version','contentHash':hash},
        'documents':[], 'reportCards':[]})), 200);
    });
    final session = SchoolSession(client: transport, cacheDirectory: () async => root);
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await session.refreshDashboard();
    expect(await session.publishedIdCard(), bytes()); expect(downloads, 1);
    expect(await session.publishedIdCard(), bytes()); expect(downloads, 1);
    version = 2; await session.refreshDashboard();
    expect(await session.publishedIdCard(), bytes()); expect(downloads, 2);
    offline = true;
    final restored = SchoolSession(client: transport, cacheDirectory: () async => root);
    await restored.restore(); expect(await restored.publishedIdCard(), bytes()); expect(downloads, 2);
    await expectLater(restored.refreshDashboard(), throwsA(isA<SocketException>()));
    expect(await restored.publishedIdCard(), bytes());
    offline = false; deleted = true; await restored.refreshDashboard();
    expect(await restored.publishedIdCard(), isNull); expect(await restored.cachedPdf('idCard'), isNull);
    final afterDelete = SchoolSession(cacheDirectory: () async => root); await afterDelete.restore();
    expect(await afterDelete.cachedPdf('idCard'), isNull);
  });
  test('acknowledged notice IDs remove deleted cached notices without duplicate retries', () async {
    var stage = 0;
    final session = SchoolSession(client: MockClient((request) async {
      final b = jsonDecode(request.body)['request'] as Map;
      if (b['action'] == 'mobile_login') return http.Response(jsonEncode(login()), 200);
      return http.Response(jsonEncode(response({'revision':'v${stage++}', 'noticesDelta':true,
        'noticeIds':stage == 1 ? ['own'] : [],
        'notices':stage == 1 ? [{'id':'own','title':'Exact notice','_noticeRevision':'r1'}] : []})), 200);
    }));
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await session.refreshDashboard(); expect(session.dashboard['notices'], hasLength(1));
    await session.refreshDashboard(); expect(session.dashboard['notices'], isEmpty);
    await session.refreshDashboard(); expect(session.dashboard['notices'], isEmpty);
    final restored = SchoolSession(); await restored.restore(); expect(restored.dashboard['notices'], isEmpty);
  });

  test('a deleted manifest discards an older in-flight ID download without restoring its cache', () async {
    final root = await Directory.systemTemp.createTemp('vs-id-deletion-race');
    addTearDown(() => root.delete(recursive: true));
    final answer = Completer<http.Response>(), started = Completer<void>();
    final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7\nold ID\n%%EOF'));
    final hash = sha256.convert(pdf).toString(); var deleted = false;
    final session = SchoolSession(cacheDirectory: () async => root, client: MockClient((request) async {
      final b = jsonDecode(request.body)['request'] as Map;
      if (b['action'] == 'mobile_login') return http.Response(jsonEncode(login()), 200);
      if (b['action'] == 'mobile_document') { started.complete(); return answer.future; }
      return http.Response(jsonEncode(response({'revision':deleted?'deleted':'v1',
        'idCardPackage':deleted ? null : {'documentId':'id','documentRevision':'v1','contentHash':hash}})), 200);
    }));
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await session.refreshDashboard();
    final download = session.publishedIdCard();
    final rejected = expectLater(download, throwsStateError);
    await started.future; deleted = true; await session.refreshDashboard();
    answer.complete(http.Response(jsonEncode(response({'documentRevision':'v1','mime':'application/pdf',
      'contentHash':hash,'base64':base64Encode(pdf)})), 200));
    await rejected; expect(await session.cachedPdf('idCard'), isNull);
    expect(await session.publishedIdCard(), isNull);
  });

}
