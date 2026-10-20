import 'package:fake_async/fake_async.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../lib/mobile/school_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = Map<String, dynamic>.from((jsonDecode(
      File('test/fixtures/windows_person_qr.json').readAsStringSync()) as List).first as Map);
  final school = fixture['schoolId'];
  Map<String, dynamic> response(Map<String, dynamic> data) => {
    'success': true, 'schoolId': school, 'projectId': school, ...data,
  };
  Map<String, dynamic> login() => response({
    'sessionToken': 'synthetic-session', 'expiresAt': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    'person': {'name': 'Synthetic student'}, 'schoolName': 'Synthetic school',
  });
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('a verified school read arriving after 25 seconds is accepted instead of timing out early', () async {
    late Completer<http.Response> reply;
    var slow = false;
    final session = SchoolSession(persistSession: (_) async {}, client: MockClient((request) async {
      final action = (jsonDecode(request.body)['request'] as Map)['action'];
      if (action == 'mobile_login') return http.Response(jsonEncode(login()), 200);
      if (slow) return reply.future;
      return http.Response(jsonEncode(response({'revision': 'old', 'notices': []})), 200);
    }));
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await session.refreshDashboard();
    slow = true;
    fakeAsync((clock) {
      reply = Completer<http.Response>();
      Map<String, dynamic>? verified;
      Object? failure;
      session.schoolCall('mobile_dashboard', {}).then((result) => verified = result, onError: (Object e) { failure = e; });
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 35));
      expect(failure, isNull);
      expect(verified, isNull);
      expect(session.dashboard['revision'], 'old');
      reply.complete(http.Response(jsonEncode(response({'revision': 'new', 'notices': []})), 200));
      clock.flushMicrotasks();
      expect(failure, isNull);
      expect(verified?['revision'], 'new');
      expect(session.dashboard['revision'], 'old');
      expect(session.connectionState, SchoolConnectionState.connected);
    });
    await session.clear();
  });

  test('an actual read deadline retains verified cache and rejects a late response', () async {
    late Completer<http.Response> reply;
    var slow = false;
    final session = SchoolSession(persistSession: (_) async {}, client: MockClient((request) async {
      final action = (jsonDecode(request.body)['request'] as Map)['action'];
      if (action == 'mobile_login') return http.Response(jsonEncode(login()), 200);
      if (slow) return reply.future;
      return http.Response(jsonEncode(response({'revision': 'verified', 'notices': []})), 200);
    }));
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await session.refreshDashboard();
    final verifiedAt = session.lastDashboardVerifiedAt;
    slow = true;
    fakeAsync((clock) {
      reply = Completer<http.Response>();
      Object? failure;
      session.refreshDashboard().then((_) {}, onError: (Object e) { failure = e; });
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 106));
      clock.flushMicrotasks();
      expect(failure, isA<TimeoutException>());
      expect(session.dashboard['revision'], 'verified');
      expect(session.lastDashboardVerifiedAt, verifiedAt);
      expect(session.connectionState, SchoolConnectionState.connectionError);
      reply.complete(http.Response(jsonEncode(response({'revision': 'late', 'notices': []})), 200));
      clock.flushMicrotasks();
      expect(session.dashboard['revision'], 'verified');
    });
    await session.clear();
  });

  test('legacy empty metadata lists never become Script group checkpoints and refresh recovers without clearing cache', () async {
    var reads = 0;
    final session = SchoolSession(persistSession: (_) async {}, client: MockClient((request) async {
      final body = Map<String, dynamic>.from(jsonDecode(request.body)['request'] as Map);
      if (body['action'] == 'mobile_login') return http.Response(jsonEncode(login()), 200);
      if (++reads == 1) return http.Response(jsonEncode(response({
        'revision': 'legacy', 'notices': [], 'noticeIds': [], 'obsoleteMetadata': [],
        'revisions': {'notices': 'old', 'noticeIds': 'metadata', 'obsoleteMetadata': 'metadata'},
      })), 200);
      final groups = body['knownGroupRecordRevisions'] as Map;
      expect(groups.keys, contains('notices'));
      expect(groups.containsKey('noticeIds'), false);
      expect(groups.containsKey('obsoleteMetadata'), false);
      expect((body['knownRevisions'] as Map).keys, ['notices']);
      return http.Response(jsonEncode(response({'revision': 'recovered', 'notices': [],
        'idCardPackage': {'documentId': 'own-card', 'documentRevision': 'published-revision', 'contentHash': 'a' * 64},
      })), 200);
    }));
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await session.refreshDashboard();
    expect(session.dashboard['revision'], 'legacy');
    await session.refreshDashboard();
    expect(session.dashboard['revision'], 'recovered');
    expect((session.dashboard['idCardPackage'] as Map)['documentId'], 'own-card');
    expect(session.loggedIn, true);
    expect(session.connectionState, SchoolConnectionState.connected);
    await session.clear();
  });

  for (final unchanged in [false, true]) {
    test('cache-write timeout after ${unchanged ? 'unchanged' : 'changed'} server response is a local cache failure, not upstream timeout', () async {
      var revision = 'original', failWrite = false, writes = 0;
      final committed = <Map<String, dynamic>>[];
      final session = SchoolSession(
        persistSession: (value) async {
          writes++;
          if (failWrite) throw TimeoutException('Synthetic local storage timeout');
          committed.add(Map<String, dynamic>.from(jsonDecode(value) as Map));
        },
        client: MockClient((request) async {
          final action = (jsonDecode(request.body)['request'] as Map)['action'];
          if (action == 'mobile_login') return http.Response(jsonEncode(login()), 200);
          return http.Response(jsonEncode(response({
            'revision': revision,
            if (unchanged && failWrite) 'unchanged': true,
            if (!(unchanged && failWrite)) 'notices': [{'id': 'notice', 'title': revision}],
          })), 200);
        }),
      );
      await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
      await session.refreshDashboard();
      final verified = session.lastDashboardVerifiedAt;
      final previousWrites = writes;
      expect(committed.last['dashboard']['revision'], 'original');
      expect(committed.last['lastDashboardVerifiedAt'], verified!.millisecondsSinceEpoch);
      revision = 'new'; failWrite = true;
      await expectLater(session.refreshDashboard(), throwsA(isA<SchoolCacheFailure>()));
      expect(writes, previousWrites + 1, reason: 'Content and verification time use one commit');
      expect(session.dashboard['revision'], 'original');
      expect(session.lastDashboardVerifiedAt, verified);
      expect(session.connectionState, SchoolConnectionState.connectionError);
      expect(session.connectionMessage, contains('local cache verification failed'));
      expect(session.connectionMessage, isNot(contains('School server took too long')));
      expect(session.loggedIn, true);
      failWrite = false;
      await session.refreshDashboard();
      expect(session.connectionState, SchoolConnectionState.connected);
      expect(session.dashboard['revision'], 'new');
      await session.clear();
    });
  }

  test('latest dashboard timeout retains earlier notices and announces syncing before the response settles', () async {
    var fail = false;
    final reply = Completer<http.Response>();
    final requestStarted=Completer<void>();
    final states = <SchoolConnectionState>[];
    final session = SchoolSession(client: MockClient((request) async {
      final action = (jsonDecode(request.body)['request'] as Map)['action'];
      if (action == 'mobile_login') return http.Response(jsonEncode(login()), 200);
      if (fail) { requestStarted.complete(); return reply.future; }
      return http.Response(jsonEncode(response({'revision': 'verified',
        'notices': [{'id': 'existing', 'title': 'Already verified notice'}]})), 200);
    }));
    await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await session.refreshDashboard();
    final verified = session.lastDashboardVerifiedAt;
    session.connectionChanges.addListener(() => states.add(session.connectionState));
    fail = true;
    final pending = session.refreshDashboard();
    expect(states.last, SchoolConnectionState.syncing);
    expect(session.dashboard['revision'], 'verified');
    final failure=expectLater(pending, throwsA(isA<TimeoutException>()));
    await requestStarted.future;
    reply.completeError(TimeoutException('Synthetic transport timeout'));
    await failure;
    expect(session.connectionMessage, contains('Latest school dashboard refresh'));
    expect(session.connectionMessage, contains('response is unverified'));
    expect(session.lastDashboardVerifiedAt, verified);
    expect((session.dashboard['notices'] as List).single['title'], 'Already verified notice');
    expect(states.last, SchoolConnectionState.connectionError);
    await session.clear();
  });
}
