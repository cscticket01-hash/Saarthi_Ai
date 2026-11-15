import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../lib/windows_drive_delivery_queue.dart';
import '../lib/windows_firebase_sync.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_connect/central_school_cloud.dart';

const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const other = 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const op = 'drive-journal-operation-0001';
Map<String, dynamic> receipt(String operationId, {String backup = 'pending'}) =>
    {
      'success': true,
      'schoolId': school,
      'syncProtocol': 2,
      'liveProtocol': 1,
      'cloudState': 'committed',
      'backupState': backup,
      'operationId': operationId,
      'recordRevision': 'live-one',
      if (backup == 'verified') 'driveRevision': 'drive-one',
      'record': {
        'id': 'one',
        'schoolId': school,
        '_syncRevision': 'live-one',
        '_syncOperationId': operationId,
        'amount': 10,
      },
    };
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = FirebaseFirestore.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile(
      'drive-history-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolSyncId': school},
    );
  });
  Map<String, dynamic> edgeNotice({bool completed = false}) => {
    'source': List.filled(64, 'a').join(), 'schoolId': school,
    'profileId': db.activeProfileId, 'action': 'managed/records',
    'collection': 'school_expenses', 'id': 'edge-one',
    'proof': {
      'success': true, 'schoolId': school, 'edgeDeliveryVersion': 1,
      'cloudflareAccepted': true, 'driveState': completed ? 'verified' : 'pending',
      if (!completed) 'delivery': {'lane': 'records', 'id': List.filled(64, 'b').join()},
    },
  };
  test('staging receipt survives restart/replay without clearing the business outbox', () async {
    await db.collection('school_expenses').doc('edge-one').set({'schoolId': school, 'amount': 42});
    await WindowsDriveDeliveryQueue.retainEdge(edgeNotice());
    expect((await WindowsDriveDeliveryQueue.history(school)).single['state'], 'pending');
    expect((await WindowsDriveDeliveryQueue.history(school)).single['cloudflareAccepted'], true);
    var polls = 0;
    await WindowsDriveDeliveryQueue.poll(school, call: (action, body) async {
      polls++; throw StateError('Staging receipt is serviced by its original outbox');
    });
    expect(polls, 1, reason: 'Only the original read-only Cloudflare ticket is queried');
    await WindowsDriveDeliveryQueue.retainEdge(edgeNotice(completed: true));
    await WindowsDriveDeliveryQueue.retainEdge(edgeNotice());
    expect((await WindowsDriveDeliveryQueue.history(school)).single['state'], 'completed');
    expect((await db.collection('_windows_firebase_outbox').get()).docs, hasLength(1));
  });
  test('measured Google bytes progress and original verified completion persist separately', () async {
    final notice = edgeNotice();
    (notice['proof'] as Map)['delivery'] = {
      'lane': 'file-${List.filled(64,'b').join()}',
      'id': List.filled(64,'b').join(),
    };
    await WindowsDriveDeliveryQueue.retainEdge(notice);
    var calls = 0;
    await WindowsDriveDeliveryQueue.poll(school,call:(action,body) async {
      calls++;
      expect(action,'managed/cloudflare/operation');
      return {
        'success':true,'schoolId':school,'cloudflareAccepted':true,
        'driveState':'pending','delivery':body,
        'driveProgress':{'version':1,'acknowledgedBytes':512,'totalBytes':1024},
      };
    });
    final history=await WindowsDriveDeliveryQueue.history(school);
    expect(calls,1);
    expect((history.single['driveProgress'] as Map)['acknowledgedBytes'],512);
    await WindowsDriveDeliveryQueue.poll(school,
      clock:()=>DateTime.now().add(const Duration(seconds:7)),
      call:(action,body) async => {
        'success':true,'schoolId':school,'cloudflareAccepted':true,
        'driveState':'verified','committed':true,'fileId':'verified-id',
        'driveDurationMillis':12500,
      });
    final done=(await WindowsDriveDeliveryQueue.history(school)).single;
    expect(done['state'],'completed');
    expect(done['driveDurationMillis'],12500);
    expect(done['driveProgress'],isNull);
  });
  test('foreign school status cannot mark Cloudflare backup completed', () async {
    await WindowsDriveDeliveryQueue.retainEdge(edgeNotice());
    await WindowsDriveDeliveryQueue.poll(school,call:(action,body) async => {
      'success':true,'schoolId':other,'cloudflareAccepted':true,'driveState':'verified',
    });
    expect((await WindowsDriveDeliveryQueue.history(school)).single['state'],'pending');
  });
  test('concurrent completed and pending receipts cannot regress the durable state', () async {
    await Future.wait([
      WindowsDriveDeliveryQueue.retainEdge(edgeNotice(completed: true)),
      WindowsDriveDeliveryQueue.retainEdge(edgeNotice()),
    ]);
    expect((await WindowsDriveDeliveryQueue.history(school)).single['state'], 'completed');
  });
  test('staging receipt refuses foreign school/profile and changed delivery identity', () async {
    final original = edgeNotice();
    await WindowsDriveDeliveryQueue.retainEdge(original);
    for (final bad in [
      {...edgeNotice(), 'profileId': 'another-profile'},
      {...edgeNotice(), 'schoolId': other},
      {...edgeNotice(), 'proof': {...(edgeNotice()['proof'] as Map), 'cloudflareAccepted': false}},
      {...edgeNotice(), 'proof': {...(edgeNotice()['proof'] as Map),
        'delivery': {'lane': 'records', 'id': List.filled(64, 'c').join()}}},
    ]) {
      await expectLater(WindowsDriveDeliveryQueue.retainEdge(bad), throwsStateError);
    }
    expect((await WindowsDriveDeliveryQueue.history(school)).single['state'], 'pending');
  });
  test('a prepared upload session and a partly rejected batch cannot claim Drive save complete', () async {
    final session = edgeNotice(completed: true)..['action'] = 'managed/file/upload';
    await expectLater(WindowsDriveDeliveryQueue.retainEdge(session), throwsStateError);
    final batch = edgeNotice(completed: true)..['action'] = 'managed/records/batch';
    (batch['proof'] as Map)['batchComplete'] = false;
    await WindowsDriveDeliveryQueue.retainEdge(batch);
    expect((await WindowsDriveDeliveryQueue.history(school)).single['state'], 'needsAttention');
    expect((await WindowsDriveDeliveryQueue.history(school)).single['completedAt'], 0);
  });
  test('cloud commitment clears its outbox while Drive completion stays separately pending', () async {
    await db.collection('school_expenses').doc('one').set({
      'schoolId': school,
      'amount': 10,
    });
    expect(
      (await db.collection('_windows_firebase_outbox').get()).docs,
      hasLength(1),
    );
    await WindowsPendingSchoolSync.flush(
      profileId: db.activeProfileId,
      send: (collection, id, operation, data) async {},
      sendVersioned: (item) async {
        final ack = await WindowsFirebaseRemote.syncManagedRecord(
          item,
          school,
          batchReply: receipt(item['operationId'] as String),
        );
        return ack['recordRevision'] as String;
      },
    );
    expect(
      (await db.collection('_windows_firebase_outbox').get()).docs,
      isEmpty,
    );
    final history = await WindowsDriveDeliveryQueue.history(school);
    expect(history, hasLength(1));
    expect(history.single['state'], 'pending');
    expect(history.single['completedAt'], 0);
  });
  test('restart reconciliation uses original operation receipt without re-sending a mutation', () async {
    await WindowsDriveDeliveryQueue.retain(
      school,
      'school_expenses',
      'one',
      op,
      receipt(op),
    );
    final calls = <String>[];
    await WindowsDriveDeliveryQueue.poll(
      school,
      call: (action, body) async {
        calls.add(action);
        expect(body['operationId'], op);
        return {
          'success': true,
          'liveProtocol': 1,
          'schoolId': school,
          'operationId': op,
          'found': true,
          'receipt': receipt(op, backup: 'verified'),
        };
      },
    );
    expect(calls, ['managed/live/operationReceipt']);
    final history = await WindowsDriveDeliveryQueue.history(school);
    expect(history.single['state'], 'completed');
    expect(history.single['completedAt'], greaterThan(0));
    await WindowsDriveDeliveryQueue.retain(
      school,
      'school_expenses',
      'one',
      op,
      receipt(op),
    );
    expect(
      (await WindowsDriveDeliveryQueue.history(school)).single['state'],
      'completed',
    );
  });
  test('staging, foreign operation and live revisions cannot become Drive completion', () {
    final journal = {
      'schoolId': school,
      'operationId': op,
      'recordRevision': 'live-one',
    };
    final done = receipt(op, backup: 'verified');
    expect(
      WindowsDriveDeliveryQueue.verifiedBackupReceipt(journal, receipt(op)),
      isFalse,
    );
    for (final invalid in [
      {...done, 'schoolId': other},
      {...done, 'operationId': 'other-operation-0001'},
      {...done, 'recordRevision': 'live-newer'},
      {...done, 'driveRevision': 'live-one'},
      {...done, 'driveRevision': 'cf-one'},
    ])
      expect(
        WindowsDriveDeliveryQueue.verifiedBackupReceipt(journal, invalid),
        isFalse,
      );
    expect(
      WindowsDriveDeliveryQueue.verifiedBackupReceipt(journal, done),
      isTrue,
    );
  });
  test('provider backoff is durable and pause admits no status read', () async {
    await WindowsDriveDeliveryQueue.retain(
      school,
      'school_expenses',
      'one',
      op,
      receipt(op),
    );
    final now = DateTime.now();
    var calls = 0;
    await WindowsDriveDeliveryQueue.poll(
      school,
      clock: () => now,
      call: (action, body) async {
        calls++;
        throw CentralCloudException(
          429,
          'school_cloud',
          'Quota',
          retryAfterMs: 3600000,
        );
      },
    );
    await WindowsDriveDeliveryQueue.poll(
      school,
      clock: () => now.add(const Duration(minutes: 1)),
      call: (a, b) async {
        calls++;
        return {};
      },
    );
    await WindowsDriveDeliveryQueue.poll(
      school,
      canAdmit: () => false,
      clock: () => now.add(const Duration(hours: 2)),
      call: (a, b) async {
        calls++;
        return {};
      },
    );
    expect(calls, 1);
    final row =
        (await db
                .collection(WindowsDriveDeliveryQueue.collection)
                .doc(op)
                .get())
            .data()!;
    expect(row['state'], 'pending');
    expect(row['nextPollAt'], now.millisecondsSinceEpoch + 3600000);
  });
  test('profile switch during a status read cannot write a receipt into another school', () async {
    await WindowsDriveDeliveryQueue.retain(
      school,
      'school_expenses',
      'one',
      op,
      receipt(op),
    );
    await expectLater(
      WindowsDriveDeliveryQueue.poll(
        school,
        call: (a, b) async {
          await db.switchProfile(
            'drive-history-other-${DateTime.now().microsecondsSinceEpoch}',
            identity: {'schoolSyncId': other},
          );
          return {
            'success': true,
            'liveProtocol': 1,
            'schoolId': school,
            'operationId': op,
            'found': true,
            'receipt': receipt(op, backup: 'verified'),
          };
        },
      ),
      throwsStateError,
    );
    expect(
      (await db.collection(WindowsDriveDeliveryQueue.collection).get()).docs,
      isEmpty,
    );
  });
}
