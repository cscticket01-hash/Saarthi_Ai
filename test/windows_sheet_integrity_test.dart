import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_sheet_integrity.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final db = FirebaseFirestore.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(true);
    await db.changeLocalStorageLocation((await Directory.systemTemp.createTemp('sheet-audit-')).path);
    await db.switchProfile('audit-${DateTime.now().microsecondsSinceEpoch}', identity: {'schoolSyncId': school});
  });
  tearDown(() async { await db.resetVolatileSession(); });
  Map<String, dynamic> reply(String collection, {int? next}) => {
    'success': true, 'schoolId': school, 'collection': collection,
    'integrityAuditVersion': 1, 'readOnly': true, 'observedAt': 1793000000000,
    'checked': 25, 'coverage': 'bounded_verified_heads', 'nextRow': next,
    'findings': [{'id': 'one', 'reason': 'unmanaged_payload_change'}],
  };
  test('owner audit cursor survives restart and does not mutate a pending record', () async {
    await db.collection('school_notices').doc('one').set({'title': 'Local edit'});
    final queue = (await db.collection('_windows_firebase_outbox').get()).docs.single.data();
    await WindowsSheetIntegrity.audit(profile: db.activeProfileId, school: school,
      collections: ['school_notices', 'school_settings'], read: (collection, row) async {
        expect(collection, 'school_notices');expect(row, 2);return reply(collection, next: 27);
      });
    await db.resetVolatileSession();
    await WindowsSheetIntegrity.audit(profile: db.activeProfileId, school: school,
      collections: ['school_notices', 'school_settings'], read: (collection, row) async {
        expect(row, 27);return reply(collection);
      });
    final current = (await db.collection('_windows_firebase_outbox').get()).docs.single.data();
    expect(current['operationId'], queue['operationId']);expect(current['data'], queue['data']);
    expect((await db.collection('_windows_sync_status').doc('sheet-integrity').get()).data()?['nextCollection'], 'school_settings');
  });
  test('foreign/malformed response never advances the audit cursor', () async {
    for (final response in [
      {...reply('school_notices'), 'schoolId': 'foreign'},
      reply('school_notices', next: 999),
      {...reply('school_notices'), 'readOnly': false},
    ]) {
      await expectLater(WindowsSheetIntegrity.audit(profile: db.activeProfileId, school: school,
        collections: ['school_notices'], read: (_, _) async => response), throwsStateError);
      expect((await db.collection('_windows_sync_status').doc('sheet-integrity').get()).exists, false);
    }
  });
}
