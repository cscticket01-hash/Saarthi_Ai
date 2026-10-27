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
  Map<String, dynamic> response(Map<String, dynamic> value) => {
    'success': true, 'schoolId': school, 'projectId': school, ...value,
  };
  Map<String, dynamic> login() => response({
    'sessionToken': 'synthetic', 'expiresAt': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    'person': {'name': 'Synthetic'}, 'schoolName': 'Own school',
  });
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test('1000-row delta preserves provider order and unchanged baseline, rejects duplicate/foreign IDs', () async {
    var stage = 0;
    final baseline = [for (var n = 0; n < 1000; n++) {
      'id': 'r$n', '_mobileRecordId': 'r$n', '_mobileRecordRevision': 'v1', 'title': 'Original $n',
    }];
    final order = [for (var n = 999; n >= 1; n--) 'r$n'];
    final session = SchoolSession(persistSession: (_) async {}, client: MockClient((request) async {
      final body = jsonDecode(request.body)['request'] as Map;
      if (body['action'] == 'mobile_login') return http.Response(jsonEncode(login()), 200);
      final first = stage++ == 0;
      final ids = first ? [for (var n = 0; n < 1000; n++) 'r$n'] : stage == 3 ? ['r999', 'r999'] : order;
      return http.Response(jsonEncode(response({
        'revision': first ? 'before' : 'after', 'mobileRecordDeltaVersion': 1,
        'revisions': {'calendar': first ? 'c1' : 'c2'},
        'groupRecordDeltas': {'calendar': {'ids': ids}},
        'calendar': first ? baseline : [{
          'id': stage == 4 ? 'foreign' : 'r999', '_mobileRecordId': stage == 4 ? 'foreign' : 'r999',
          '_mobileRecordRevision': 'v2', 'title': 'Changed',
        }],
      })), 200);
    }));
    try {
      await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
      await session.refreshDashboard();
      expect(session.dashboard['calendar'], hasLength(1000));
      await session.refreshDashboard();
      final rows = session.dashboard['calendar'] as List;
      expect(rows, hasLength(999));
      expect(rows.first['id'], 'r999'); expect(rows.first['title'], 'Changed');
      expect(rows.last['id'], 'r1'); expect(rows.last['title'], 'Original 1');
      expect(rows.any((row) => row['id'] == 'r0'), false);
      final retained = jsonEncode(session.dashboard);
      await expectLater(session.refreshDashboard(), throwsStateError);
      expect(jsonEncode(session.dashboard), retained);
      await expectLater(session.refreshDashboard(), throwsStateError);
      expect(jsonEncode(session.dashboard), retained);
    } finally { await session.clear(); }
  });
  test('large legacy notice delta keeps authoritative order and only acknowledged IDs', () async {
    var first = true;
    final session = SchoolSession(persistSession: (_) async {}, client: MockClient((request) async {
      final body = jsonDecode(request.body)['request'] as Map;
      if (body['action'] == 'mobile_login') return http.Response(jsonEncode(login()), 200);
      final initial = first; first = false;
      return http.Response(jsonEncode(response(initial ? {
        'revision': 'v1', 'notices': [for (var n = 0; n < 1000; n++) {'id': 'n$n', 'title': 'Old $n', '_noticeRevision': 'v1'}],
      } : {
        'revision': 'v2', 'noticesDelta': true, 'noticeIds': [for (var n = 999; n >= 500; n--) 'n$n'],
        'notices': [{'id': 'n999', 'title': 'Changed', '_noticeRevision': 'v2'}],
      })), 200);
    }));
    try {
      await session.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
      await session.refreshDashboard(); await session.refreshDashboard();
      final rows = session.dashboard['notices'] as List;
      expect(rows, hasLength(500)); expect(rows.first['title'], 'Changed');
      expect(rows.last['id'], 'n500'); expect(rows.last['title'], 'Old 500');
    } finally { await session.clear(); }
  });
}
