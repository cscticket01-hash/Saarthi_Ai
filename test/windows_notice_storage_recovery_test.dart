import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/windows_sync_recovery.dart';
import '../lib/sync_recovery_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final db=FirebaseFirestore.instance;
  const notice={'title':'Tomorrow','description':'School notice','category':'General',
    'timestamp':1793326507791,'lastEdited':1793326507791,'deliveryStatus':'sync_pending','schoolId':school};
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(true);
    final dir=await Directory.systemTemp.createTemp('notice-storage-recovery-');
    await db.changeLocalStorageLocation(dir.path);
    await db.switchProfile('notice-io-${DateTime.now().microsecondsSinceEpoch}',
      identity:{'schoolSyncId':school,'schoolId':school});
  });
  tearDown(()async {await db.resetVolatileSession();});
  Future<void> flush(Future<String> Function(Map<String,dynamic>) send) =>
    WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,send:(_,__,___,____)async{},sendVersioned:send);
  test('record filesystem I/O retains original request and retries only to its budget',()async {
    await db.collection('school_notices').doc('notice').set(notice);
    final ref=(await db.collection('_windows_firebase_outbox').get()).docs.single.reference;
    final original=(await ref.get()).data()!;
    var calls=0;
    for(var i=0;i<automaticRecordRetryLimit;i++) {
      await expectLater(flush((sent)async {
        calls++;expect(sent['operationId'],original['operationId']);expect(sent['data'],original['data']);
        throw const FileSystemException('sharing violation','private-database-path',OSError('busy',32));
      }),throwsA(isA<RecordLocalStorageFailure>()));
      final retained=(await ref.get()).data()!;
      expect(retained['failureCategory'],'localStorage');
      expect(retained['failureCode'],'RECORD_LOCAL_STORAGE_IO');
      expect(retained['failureOsErrorCode'],32);
      expect(retained['lastError'].toString(),isNot(contains('private-database-path')));
      expect(retained['baseCloudRevision'],original['baseCloudRevision']);
      expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty);
    }
    expect((await ref.get()).data()?['syncState'],'needsAttention');
    await flush((_)async{calls++;return 'must-not-send';});
    expect(calls,automaticRecordRetryLimit);
  });
  test('v2.1.203 fileMissing text notice reopens with identical wire request and requires real ACK',()async {
    await db.collection('school_notices').doc('notice').set(notice);
    final ref=(await db.collection('_windows_firebase_outbox').get()).docs.single.reference;
    final queued=(await ref.get()).data()!;
    final bound=await db.bindOutboxWireData(ref,queued,Map<String,dynamic>.from(notice),'snapshot2');
    expect(bound,isNotNull);
    await ref.update({'syncState':'needsAttention','failureCategory':'fileMissing','failureCode':'fileMissing','retryCount':1});
    final original=(await ref.get()).data()!;
    var calls=0;
    await expectLater(flush((sent)async {
      calls++;expect(sent['operationId'],original['operationId']);
      expect(sent['wireData'],original['wireData']);expect(sent['data'],original['data']);
      expect(sent['baseCloudRevision'],original['baseCloudRevision']);
      expect(sent['syncState'],'retry');expect(sent['failureCategory'],'localStorage');
      throw const MissingSyncAcknowledgement();
    }),throwsA(isA<MissingSyncAcknowledgement>()));
    expect((await ref.get()).exists,true);
    expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty);
    await flush((sent)async {calls++;expect(sent['operationId'],original['operationId']);return 'verified-original-ack';});
    expect(calls,2);expect((await ref.get()).exists,false);
    expect((await db.collection('_windows_sync_receipts').get()).docs,isNotEmpty);
  });
  test('missing document originals and notices with media are never reopened by text repair',()async {
    for(final data in [notice,{...notice,'photoUrl':'file:///missing.jpg'}]) {
      final id=data.containsKey('photoUrl')?'media':'conflict';
      await db.collection('school_notices').doc(id).set(data);
      final row=(await db.collection('_windows_firebase_outbox').get()).docs.singleWhere((r)=>r.data()['documentId']==id);
      await row.reference.update({'syncState':id=='conflict'?'conflict':'needsAttention','failureCategory':'fileMissing','retryCount':1});
    }
    await flush((_)async=>fail('Blocked media/conflict must not send'));
    expect((await db.collection('_windows_firebase_outbox').get()).docs,hasLength(2));
    expect(windowsSyncRecovery(const PendingDocumentFileFailure()).kind,SyncFailureKind.fileMissing);
    expect(windowsSyncRecovery(const FileSystemException('missing attachment')).kind,SyncFailureKind.fileMissing);
    expect(textOnlyNoticeRequest({'collection':'documents','operation':'set','data':notice}),false);
  });
}
