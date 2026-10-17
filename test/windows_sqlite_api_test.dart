import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_local_storage.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/windows_sheet_recovery.dart';
import '../lib/storage/windows_sqlite_store.dart';
import '../lib/platform/platform_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = FirebaseFirestore.instance;
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  setUp(() async {
    expect(WindowsLocalStorage.sqliteEnabled, true,
        reason:
            'Must execute the real SQLite backend, not the legacy JSON fallback');
    FlutterSecureStorage.setMockInitialValues({
      CentralSchoolCloud.key: jsonEncode({
        'managed': true,
        'projectId': platformProjectId,
        'folderId': 'managed',
        'schoolId': school,
        'uid': 'synthetic-sqlite',
        'firebaseRefreshToken': 'synthetic',
        'endpoint': 'https://unreachable.example/school-cloud'
      })
    });
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    final copy = await Directory.systemTemp.createTemp('vs-sql-api-');
    await db.changeLocalStorageLocation(copy.path);
    final sql = await WindowsLocalStorage.sqliteFile();
    final legacy = await WindowsLocalStorage.databaseFile();
    if (!await sql.exists() && await legacy.exists())
      await db.migrateLocalDatabaseToSqlite(approved: true);
    await db.switchProfile('sql-api-${DateTime.now().microsecondsSinceEpoch}',
        identity: {'schoolId': school, 'schoolSyncId': school});
    expect(await sql.exists(), true);
  });
  tearDown(() async {
    await db.resetVolatileSession();
  });
  test('scoped ACK/cache/apply preserves neighboring queues, receipts and noncanonical legacy pending rows', () async {
    await db.collection('fee_payments').doc('a').set({'schoolId':school,'amount':100});
    await db.collection('fee_payments').doc('b').set({'schoolId':school,'amount':200});
    final queue=(await db.collection('_windows_firebase_outbox').get()).docs;
    final a=queue.singleWhere((q)=>q.data()['documentId']=='a');
    final b=queue.singleWhere((q)=>q.data()['documentId']=='b');
    await db.acknowledgeOutbox(a.reference,a.data(),revision:'synthetic-ACK-a');
    // Compare persisted timestamp values, not freshly decoded object identities.
    expect(migrationJsonValue((await b.reference.get()).data()),migrationJsonValue(b.data()));
    final receipt=(await db.collection('_windows_sync_receipts').get()).docs.single;
    await cacheVerifiedSheetRecord(school,'fee_payments','a',{'schoolId':school,'amount':100,'_syncRevision':'cloud-a'});
    await cacheVerifiedSheetRecord(school,'fee_payments','b',{'schoolId':school,'amount':200,'_syncRevision':'cloud-b'});
    await cacheVerifiedSheetRecord(school,'fee_payments','a',{'schoolId':school,'amount':110,'_syncRevision':'cloud-a2'});
    expect((await db.collection('_windows_verified_cloud_records').get()).docs,hasLength(2));
    expect((await db.collection('_windows_verified_cloud_records').doc(sheetRecoveryCacheKey('fee_payments','b')).get()).data()?['record']['amount'],200);
    await db.applySyncedDocument(db.collection('school_notices').doc('one'),{'schoolId':school,'title':'One','_syncRevision':'one'});
    await db.applySyncedDocument(db.collection('school_notices').doc('two'),{'schoolId':school,'title':'Two','_syncRevision':'two'});
    expect((await db.collection('school_notices').get()).docs,hasLength(2));
    expect((await receipt.reference.get()).data(),receipt.data());
    // Compare persisted timestamp values, not freshly decoded object identities.
    expect(migrationJsonValue((await b.reference.get()).data()),migrationJsonValue(b.data()));
    // A legacy queue ID need not equal today's derived record key. Download
    // admission must still see its pending edit and retain the local payload.
    final protected=db.collection('school_notices').doc('protected');
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(()=>protected.set({'schoolId':school,'title':'Local pending'}));
    await db.collection('_windows_firebase_outbox').doc('legacy-noncanonical').set({
      ...b.data(),'collection':'school_notices','documentId':'protected','data':{'schoolId':school,'title':'Local pending'}});
    await db.applySyncedDocument(protected,{'schoolId':school,'title':'Remote','_syncRevision':'remote-protected'});
    expect((await protected.get()).data()?['title'],'Local pending');
    expect((await db.collection('_windows_firebase_outbox').doc('legacy-noncanonical').get()).exists,true);
    await db.resetVolatileSession();
    expect((await receipt.reference.get()).data(),receipt.data());
    // Compare persisted timestamp values, not freshly decoded object identities.
    expect(migrationJsonValue((await b.reference.get()).data()),migrationJsonValue(b.data()));
  });
  test('offline delete atomically retains original financial snapshot and delete identity after reopen', () async {
    final profile = db.activeProfileId;
    final ref = db.collection('fee_payments').doc('retained-fee');
    await ref.set({'schoolId':school,'amount':500,'capturedAt':1791500000123});
    await ref.delete();
    expect((await ref.get()).exists,false);
    final pending = (await db.collection('_windows_firebase_outbox').get()).docs.single.data();
    expect(pending['operation'],'delete');
    await db.resetVolatileSession();
    await db.switchProfile('away');
    expect((await db.collection('_windows_local_deletions').get()).docs,isEmpty);
    await db.switchProfile(profile,identity:{'schoolId':school,'schoolSyncId':school});
    final retained = (await db.collection('_windows_local_deletions').get()).docs.single.data();
    expect(retained['operationId'],pending['operationId']);
    expect(retained['cloudDeletionVerified'],false);
    expect(retained['snapshot'],{'schoolId':school,'amount':500,'capturedAt':1791500000123});
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(()=>db.collection('school_notices').doc('cloud-tombstone').delete());
    expect((await db.collection('_windows_local_deletions').get()).docs,hasLength(1));
    expect((await db.collection('_windows_firebase_outbox').get()).docs.single.data()['operationId'],pending['operationId']);
    await WindowsPendingSchoolSync.flush(profileId:profile,send:(a,b,c,d)async{},sendVersioned:(row)async=>'verified-delete-revision');
    final acknowledged = (await db.collection('_windows_local_deletions').get()).docs.single.data();
    expect(acknowledged['cloudDeletionVerified'],true);
    expect(acknowledged['deletedRevision'],'verified-delete-revision');
    expect(acknowledged['snapshot'],retained['snapshot']);
  });
  test(
      'production API offline save retains stable operation, pending count and original time after close/reopen',
      () async {
    final profile = db.activeProfileId;
    final doc =
        db.collection('attendance_records').doc('synthetic-sql-attendance');
    await doc.set({
      'schoolId': school,
      'entryCapturedAt': 1791500000123,
      'name': 'Retained'
    });
    final pending = (await db.collection('_windows_firebase_outbox').get())
        .docs
        .single
        .data();
    await expectLater(
        WindowsPendingSchoolSync.flush(
            profileId: profile,
            send: (a, b, c, d) async => throw const SocketException('Offline')),
        throwsA(isA<SocketException>()));
    await db.resetVolatileSession();
    await db.switchProfile('away');
    await db.switchProfile(profile,
        identity: {'schoolId': school, 'schoolSyncId': school});
    final restored = (await db.collection('_windows_firebase_outbox').get())
        .docs
        .single
        .data();
    expect(restored['operationId'], pending['operationId']);
    expect(restored['syncState'], 'retry');
    expect(
        (await db
                .collection('attendance_records')
                .doc('synthetic-sql-attendance')
                .get())
            .data()?['entryCapturedAt'],
        1791500000123);
    await WindowsPendingSchoolSync.flush(
        profileId: profile,
        send: (a, b, c, d) async {},
        sendVersioned: (row) async {
          expect(row['operationId'], pending['operationId']);
          return 'verified-real-protocol-revision';
        });
    expect(
        (await db.collection('_windows_firebase_outbox').get()).docs, isEmpty);
    expect((await db.collection('_windows_sync_receipts').get()).docs,
        hasLength(1));
  });
  test(
      'invalid second batch mutation rolls back local record and outbox together',
      () async {
    final batch = db.batch();
    batch.set(db.collection('students_directory').doc('first'),
        {'schoolId': school, 'name': 'Not committed'});
    batch.update(db.collection('students_directory').doc('missing'),
        {'name': 'Invalid'});
    await expectLater(batch.commit(), throwsStateError);
    expect(
        (await db.collection('students_directory').doc('first').get()).exists,
        false);
    expect(
        (await db.collection('_windows_firebase_outbox').get()).docs, isEmpty);
  });
  test('newer edits survive stale cloud pull and old operation ACK in SQLite',
      () async {
    final doc = db.collection('fee_payments').doc('synthetic-fee');
    await doc.set({'schoolId': school, 'amount': 100});
    final queue =
        (await db.collection('_windows_firebase_outbox').get()).docs.single;
    final old = queue.data();
    await doc.update({'amount': 150});
    await db.applySyncedDocument(
        doc, {'schoolId': school, 'amount': 50, '_syncRevision': 'stale'});
    await db.acknowledgeOutbox(queue.reference, old, revision: 'ack-old');
    expect((await doc.get()).data()?['amount'], 150);
    expect((await db.collection('_windows_firebase_outbox').get()).docs,
        hasLength(1));
    expect(
        (await db.collection('_windows_firebase_outbox').get())
            .docs
            .single
            .data()['operationId'],
        isNot(old['operationId']));
  });
  test('school switches never reveal another profile records, outbox or files',
      () async {
    final original = db.activeProfileId;
    await db
        .collection('documents')
        .doc('same-id')
        .set({'schoolId': school, 'originalPath': 'School-A-only.pdf'});
    await db.switchProfile('B-sql-${DateTime.now().microsecondsSinceEpoch}',
        identity: {'schoolSyncId': 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'});
    expect(
        (await db.collection('documents').doc('same-id').get()).exists, false);
    expect(
        (await db.collection('_windows_firebase_outbox').get()).docs, isEmpty);
    await db.switchProfile(original,
        identity: {'schoolId': school, 'schoolSyncId': school});
    expect(
        (await db.collection('documents').doc('same-id').get())
            .data()?['originalPath'],
        'School-A-only.pdf');
    expect((await db.collection('_windows_firebase_outbox').get()).docs,
        hasLength(1));
  });
}
