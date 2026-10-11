import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_sync_pause.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_pending_school_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('timed pause survives restore and expires using elapsed wall time', () {
    var now = DateTime.utc(2026, 10, 11);
    final first = WindowsSyncPause(now: () => now);
    final saved = first.pause(const Duration(hours: 12));
    now = now.add(const Duration(hours: 4));
    final restarted = WindowsSyncPause(now: () => now)..restore(saved);
    expect(restarted.isPaused, true);
    expect(restarted.pausedUntil!.millisecondsSinceEpoch,
        DateTime.utc(2026, 10, 11, 12).millisecondsSinceEpoch);
    now = now.add(const Duration(hours: 8));
    expect(restarted.isPaused, false);
    expect(restarted.pausedUntil, isNull);
  });
  test('pause is bounded and device-local policy instances remain independent', () {
    final now = DateTime.utc(2026, 10, 11);
    final deviceA = WindowsSyncPause(now: () => now);
    final deviceB = WindowsSyncPause(now: () => now);
    expect(() => deviceA.pause(Duration.zero), throwsArgumentError);
    expect(() => deviceA.pause(const Duration(hours: 25)), throwsArgumentError);
    deviceA.pause(const Duration(hours: 24));
    expect(deviceA.isPaused, true);
    expect(deviceB.isPaused, false);
    deviceA.resume();
    expect(deviceA.isPaused, false);
    deviceA.restore({'startedAtMillis': now.millisecondsSinceEpoch,
      'pausedUntilMillis': now.add(const Duration(hours: 25)).millisecondsSinceEpoch});
    expect(deviceA.isPaused, false);
  });
  test('pause admits no next row while accepted ACK and newer edit survive', () async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    final db = FirebaseFirestore.instance;
    await db.switchProfile('pause-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolSyncId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'});
    final first = db.collection('teachers_directory').doc('a');
    await first.set({'name': 'Original'});
    await db.collection('teachers_directory').doc('b').set({'name': 'Other'});
    final before = (await db.collection('_windows_firebase_outbox').get()).docs;
    final originalIds = {for (final row in before) row.data()['documentId']: row.data()['operationId']};
    final accepted = Completer<void>(), finish = Completer<void>();
    var allowed = true;
    final sent = <String>[];
    final flushing = WindowsPendingSchoolSync.flush(profileId: db.activeProfileId,
      canAdmit: () => allowed, send: (a,b,c,d) async {},
      sendVersioned: (item) async {
        sent.add(item['documentId'] as String);
        accepted.complete();
        await finish.future;
        return 'verified-revision';
      });
    await accepted.future;
    allowed = false;
    final admittedId = sent.single;
    await db.collection('teachers_directory').doc(admittedId).set({'name': 'Newer local edit'});
    finish.complete();
    await flushing;
    expect(sent, hasLength(1));
    final retained = (await db.collection('_windows_firebase_outbox').get()).docs;
    expect(retained, hasLength(2));
    final admitted = retained.singleWhere((row) => row.data()['documentId'] == admittedId).data();
    expect(admitted['baseCloudRevision'], 'verified-revision');
    expect(admitted['data']['name'], 'Newer local edit');
    final other = retained.singleWhere((row) => row.data()['documentId'] != admittedId).data();
    expect(other['operationId'], originalIds[other['documentId']]);
    allowed = true;
    await WindowsPendingSchoolSync.flush(profileId: db.activeProfileId,
      canAdmit: () => allowed, send: (a,b,c,d) async {},
      sendVersioned: (item) async => 'verified-final-revision');
    expect((await db.collection('_windows_firebase_outbox').get()).docs, isEmpty);
  });
}
