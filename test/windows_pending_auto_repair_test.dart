import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/windows_sync_recovery.dart';
import '../lib/windows_connect/central_school_cloud.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = FirebaseFirestore.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile(
      'repair-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolSyncId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'},
    );
  });
  Future<void> flush(
    Future<String> Function(Map<String, dynamic>) sender, {
    void Function(Map<String, dynamic>)? observer,
  }) => WindowsPendingSchoolSync.flush(
    profileId: db.activeProfileId,
    send: (a, b, c, d) async {},
    sendVersioned: sender,
    onActivity: observer,
  );

  test('missing ACK remains durable retry and duplicate flush cannot acknowledge it', () async {
    await db.collection('school_notices').doc('n').set({'text': 'retain me'});
    final row =
        (await db.collection('_windows_firebase_outbox').get()).docs.single;
    await expectLater(
      flush((_) async => '  '),
      throwsA(isA<MissingSyncAcknowledgement>()),
    );
    final retained = (await row.reference.get()).data()!;
    expect(retained['syncState'], 'retry');
    expect(retained['failureCategory'], 'server');
    expect(retained['operationId'], row.data()['operationId']);
    await flush((_) async => 'authoritative-replayed-revision');
    var calls = 0;
    await flush((_) async {
      calls++;
      return 'duplicate';
    });
    expect(calls, 0);
    expect((await row.reference.get()).exists, false);
  });
  test(
    'HTTP 500 becomes recoverable retry instead of permanent attention',
    () async {
      await db.collection('school_notices').doc('n').set({'text': 'safe'});
      await expectLater(
        flush(
          (_) async => throw CentralCloudException(500, 'school_cloud', 'TEST'),
        ),
        throwsA(isA<CentralCloudException>()),
      );
      final row = (await db.collection('_windows_firebase_outbox').get())
          .docs
          .single
          .data();
      expect(row['syncState'], 'retry');
      expect(row['failureCategory'], 'server');
    },
  );
  test('persisted known transport attention reopens with same operation and reports repair', () async {
    await db.collection('school_notices').doc('n').set({'text': 'safe'});
    final row =
        (await db.collection('_windows_firebase_outbox').get()).docs.single;
    await row.reference.update({
      'syncState': 'needsAttention',
      'failureCategory': 'timeout',
      'retryCount': 1,
    });
    final events = <Map<String, dynamic>>[];
    await flush((sent) async {
      expect(sent['operationId'], row.data()['operationId']);
      expect(sent['data']['text'], 'safe');
      return 'real-provider-ack';
    }, observer: events.add);
    expect(events.first['stage'], 'automaticRepair');
    expect(events.last['stage'], 'verified');
  });
  test(
    'blocked, conflicting and exhausted operations never enter automatic send',
    () async {
      for (final category in [
        'authorization',
        'configuration',
        'unknown',
        'server',
      ]) {
        await db.collection('school_notices').doc(category).set({
          'text': 'retained',
        });
        final row = (await db.collection('_windows_firebase_outbox').get()).docs
            .singleWhere((r) => r.data()['documentId'] == category);
        await row.reference.update({
          'syncState': 'needsAttention',
          'failureCategory': category,
          'retryCount': category == 'server' ? automaticRecordRetryLimit : 0,
        });
      }
      await db.collection('school_notices').doc('conflict').set({
        'text': 'both versions',
      });
      final conflict = (await db.collection('_windows_firebase_outbox').get())
          .docs
          .singleWhere((r) => r.data()['documentId'] == 'conflict');
      await conflict.reference.update({
        'syncState': 'conflict',
        'failureCategory': 'server',
      });
      var calls = 0;
      await flush((_) async {
        calls++;
        return 'never';
      });
      expect(calls, 0);
      expect(
        (await db.collection('_windows_firebase_outbox').get()).docs,
        hasLength(5),
      );
    },
  );
  test('automatic retry budget stops recurring transport failures without deleting data', () async {
    await db.collection('school_notices').doc('n').set({'text': 'safe'});
    var calls = 0;
    for (var i = 0; i < automaticRecordRetryLimit; i++) {
      await expectLater(
        flush((_) async {
          calls++;
          throw const MissingSyncAcknowledgement();
        }),
        throwsA(isA<MissingSyncAcknowledgement>()),
      );
    }
    await flush((_) async {
      calls++;
      return 'must not run';
    });
    expect(calls, automaticRecordRetryLimit);
    final row = (await db.collection('_windows_firebase_outbox').get())
        .docs
        .single
        .data();
    expect(row['syncState'], 'needsAttention');
    expect(row['data']['text'], 'safe');
  });
}
