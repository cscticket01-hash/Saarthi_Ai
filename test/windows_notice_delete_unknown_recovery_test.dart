import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/windows_sync_recovery.dart';
import '../lib/sync_recovery_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final db = FirebaseFirestore.instance;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile(
      'notice-delete-recovery-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolSyncId': school, 'schoolId': school},
    );
  });

  Future<QueryDocumentSnapshot<Map<String, dynamic>>> stuckDelete(String id) async {
    await db.applySyncedDocument(db.collection('school_notices').doc(id), {
      'schoolId': school, 'title': 'Previous notice', 'description': 'Published',
      '_syncRevision': 'before-r1', '_syncOperationId': 'prior-write-operation-0001',
    });
    await db.collection('school_notices').doc(id).delete();
    final rows = (await db.collection('_windows_firebase_outbox').get()).docs;
    final row = rows.singleWhere((r) => r.data()['documentId'] == id);
    expect(row.data()['operation'], 'delete');
    expect(row.data()['baseCloudRevision'], 'before-r1');
    await row.reference.update({
      'syncState': 'needsAttention', 'failureCategory': 'unknown',
      'retryCount': 5,
    });
    return (await db.collection('_windows_firebase_outbox').get()).docs
        .singleWhere((r) => r.data()['documentId'] == id);
  }

  Map<String, dynamic> readback(String id, [Map<String, dynamic>? remote]) => {
    'schoolId': school, 'syncProtocol': 2, 'pointRead': true,
    'records': <String, dynamic>{if (remote != null) id: remote},
  };

  final oldCloud = <String, dynamic>{
    'schoolId': school, 'title': 'Previous notice',
    '_syncRevision': 'before-r1', '_syncOperationId': 'prior-write-operation-0001',
  };

  test('old unknown notice DELETE is read-only checked before a single safe retry', () async {
    final row = await stuckDelete('notice-1');
    final original = row.data();
    expect(verifiedUnknownNoticeDeleteReadback(original, oldCloud, school), true);
    var probes = 0;
    final repaired = await WindowsPendingSchoolSync.repair(
      profileId: db.activeProfileId, school: school, explicitRetry: true,
      read: (collection, id) async {
        probes++;
        expect(collection, 'school_notices');
        expect(id, 'notice-1');
        return readback(id, oldCloud);
      },
    );
    expect(repaired, 1);
    expect(probes, 1);
    final retry = (await row.reference.get()).data()!;
    expect(retry['operationId'], original['operationId']);
    expect(retry['baseCloudRevision'], original['baseCloudRevision']);
    expect(retry['operation'], 'delete');
    expect(retry['syncState'], 'retry');
    expect(retry['failureCategory'], 'server');
    expect((await db.collection('_windows_sync_receipts').get()).docs, isEmpty,
        reason: 'Verified point-read never manufactures a write ACK.');
    // A later verified authority, not the probe, owns outbox retirement.
    var sends = 0;
    await WindowsPendingSchoolSync.flush(
      profileId: db.activeProfileId,
      send: (_, __, ___, ____) async {},
      sendVersioned: (sent) async {
        sends++;
        expect(sent['operationId'], original['operationId']);
        return 'delete-verified-r2';
      },
    );
    expect(sends, 1);
    expect((await row.reference.get()).exists, false);
    expect((await db.collection('_windows_sync_receipts').get()).docs, isNotEmpty);
  });

  test('already deleted by same immutable operation is safe for receipt replay, never an invented ACK', () async {
    final row = await stuckDelete('notice-2');
    final original = row.data();
    final tombstone = <String, dynamic>{
      'schoolId': school, '_syncRevision': 'deletion-r2',
      '_syncDeleted': true, '_syncOperationId': original['operationId'],
    };
    expect(verifiedUnknownNoticeDeleteReadback(original, tombstone, school), true);
    final repaired = await WindowsPendingSchoolSync.repair(
      profileId: db.activeProfileId, school: school,
      read: (collection, id) async => readback(id, tombstone),
    );
    expect(repaired, 1);
    final retained = (await row.reference.get()).data()!;
    expect(retained['syncState'], 'retry');
    expect(retained['operationId'], original['operationId']);
    expect((await db.collection('_windows_sync_receipts').get()).docs, isEmpty);
  });

  test('unrelated cloud revision or missing readback never replays or clears deletion', () async {
    final row = await stuckDelete('notice-3');
    final original = row.data();
    final unexpected = <String, dynamic>{
      ...oldCloud, '_syncRevision': 'other-device-r9',
      '_syncOperationId': 'some-other-operation-0001',
    };
    expect(verifiedUnknownNoticeDeleteReadback(original, unexpected, school), false);
    expect(verifiedUnknownNoticeDeleteReadback(original, null, school), false);
    expect(verifiedUnknownNoticeDeleteReadback(original,
      {...oldCloud, 'schoolId': 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}, school), false);
    expect(verifiedUnknownNoticeDeleteReadback(original,
      {...oldCloud, '_syncDeleted': true}, school), false);
    final count = await WindowsPendingSchoolSync.repair(
      profileId: db.activeProfileId, school: school,
      read: (collection, id) async => readback(id, unexpected),
    );
    expect(count, 0);
    final retained = (await row.reference.get()).data()!;
    expect(retained['syncState'], 'needsAttention');
    expect(retained['failureCategory'], 'unknown');
    expect(retained['operationId'], original['operationId']);
    expect(retained['baseCloudRevision'], 'before-r1');
    expect((await db.collection('_windows_sync_receipts').get()).docs, isEmpty);
  });

  test('unknown notice retry journal is once per original operation after another unclassified failure', () async {
    final row = await stuckDelete('notice-4');
    final original = row.data();
    var reads = 0;
    Future<Map<String, dynamic>> read(String collection, String id) async {
      reads++;
      return readback(id, oldCloud);
    }
    expect(await WindowsPendingSchoolSync.repair(
      profileId: db.activeProfileId, school: school, explicitRetry: true, read: read), 1);
    final retried = (await row.reference.get()).data()!;
    await row.reference.update({
      'syncState': 'needsAttention', 'failureCategory': 'unknown',
      'retryCount': 5,
    });
    expect(await WindowsPendingSchoolSync.repair(
      profileId: db.activeProfileId, school: school, explicitRetry: true, read: read), 0);
    expect(reads, 1);
    final retained = (await row.reference.get()).data()!;
    expect(retained['operationId'], original['operationId']);
    expect(retained['baseCloudRevision'], retried['baseCloudRevision']);
    expect(retained['syncState'], 'needsAttention');
  });

  test('missing delete proof is diagnosed as retryable without fabricating success', () {
    const error = 'Cloud deletion is not verified. Pending operation retained.';
    final decision = windowsSyncRecovery(StateError(error));
    expect(decision.kind, SyncFailureKind.server);
    expect(decision.retry, true);
    expect(decision.independentRecords, true);
    expect(documentFailureDiagnostic(StateError(error), 'recordRequestAndAck')['failureCode'],
        'DELETE_ACK_UNVERIFIED');
    const drive = 'Google Drive acknowledgement unverified; local work retained.';
    expect(windowsSyncRecovery(StateError(drive)).kind, SyncFailureKind.server);
    expect(documentFailureDiagnostic(StateError(drive), 'recordRequestAndAck')['failureCode'],
        'DRIVE_ACK_UNVERIFIED');
  });
}
