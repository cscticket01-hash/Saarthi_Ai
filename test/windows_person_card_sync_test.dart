import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_school_identity.dart';
import '../lib/windows_sync_dependencies.dart';
import '../lib/windows_person_card_sync.dart';
import '../lib/windows_sync_comparison.dart';
import '../lib/windows_sync_recovery.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final db = FirebaseFirestore.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(true);
    final dir = await Directory.systemTemp.createTemp('person-card-');
    await db.changeLocalStorageLocation(dir.path);
    await db.switchProfile(dir.path, identity: {'schoolSyncId': school, 'schoolId': school});
  });
  tearDown(() async => db.resetVolatileSession());
  test('record-local priority failure defers without losing its original error or dependency', () async {
    await WindowsSyncDependencies.retain(school, 'teachers_directory', 'held', 'revision');
    const original = MissingSyncAcknowledgement();
    final deferred = await WindowsPersonCardSync.priorityPass(() async { throw original; });
    expect(deferred?.error, same(original));
    expect(await WindowsSyncDependencies.read(school), hasLength(1));
    expect(() => deferred!.rethrowFailure(), throwsA(same(original)));
  });
  test('shared transport failures still stop priority admission immediately', () async {
    final original = SocketException('offline');
    await expectLater(WindowsPersonCardSync.priorityPass(() async { throw original; }), throwsA(same(original)));
    expect(await WindowsPersonCardSync.priorityPass(() async {}), isNull);
  });
  for (final collection in ['students_directory', 'teachers_directory']) {
    test('$collection fresh create includes QR identity in the first wire snapshot', () async {
      final ref = db.collection(collection).doc('fresh');
      await ref.set({'schoolId': school, 'name': 'Synthetic', 'teacherId': 'fresh'});
      await SchoolPersonIdentity.preparePendingCreates(school);
      final person = (await ref.get()).data()!;
      expect(person['mobileLinkToken'], isNotEmpty);
      expect(person['mobileStableId'], startsWith('p-'));
      final queued = (await db.collection('_windows_firebase_outbox').get()).docs.single;
      expect((queued.data()['data'] as Map)['mobileStableId'], person['mobileStableId']);
      final operation = queued.data()['operationId'];
      await SchoolPersonIdentity.ensure(collection, 'fresh');
      expect((await queued.reference.get()).data()?['operationId'], operation);
    });
  }
  test('bound and failed create operations are never regenerated', () async {
    for (final id in ['bound', 'failed']) await db.collection('teachers_directory').doc(id).set({'schoolId': school, 'name': id});
    final rows = (await db.collection('_windows_firebase_outbox').get()).docs;
    final bound = rows.firstWhere((r) => r.data()['documentId'] == 'bound');
    await db.bindOutboxWireData(bound.reference, bound.data(), Map<String, dynamic>.from(bound.data()['data'] as Map), 'snapshot2');
    final failed = rows.firstWhere((r) => r.data()['documentId'] == 'failed');
    await failed.reference.update({'syncState': 'retry', 'failureCategory': 'timeout'});
    final before = {for (final r in rows) r.id: (await r.reference.get()).data()!['operationId']};
    await SchoolPersonIdentity.preparePendingCreates(school);
    for (final r in rows) expect((await r.reference.get()).data()?['operationId'], before[r.id]);
    expect((await db.collection('teachers_directory').doc('bound').get()).data()?['mobileStableId'], isNull);
  });
  Future<void> parent() async {
    await db.applySyncedDocument(db.collection('teachers_directory').doc('one'),
      {'schoolId': school, 'name': 'One', '_syncRevision': 'verified-parent'});
    await WindowsSyncDependencies.retain(school, 'teachers_directory', 'one', 'verified-parent');
  }
  test('priority job orders preparation, remaining parent ACK and cards; retains dependency until reconciliation', () async {
    await parent(); final calls = <String>[];
    await WindowsPersonCardSync.run(school,
      prepare: (targets) async { expect(targets, {'teacherId': {'one'}}); calls.add('prepare'); },
      pushParents: () async { calls.add('parent'); },
      cardId: (_, id, person) => 'card-$id',
      sendCards: (ids) async { expect(ids, {'card-one'}); calls.add('card'); });
    expect(calls, ['prepare', 'parent', 'card']);
    expect(await WindowsSyncDependencies.read(school), hasLength(1));
  });
  test('pause and unverified parent failure cannot admit a card upload', () async {
    await parent(); var admit = true, uploads = 0;
    await WindowsPersonCardSync.run(school, canAdmit: () => admit,
      prepare: (_) async { admit = false; }, pushParents: () async => fail('Paused parent'),
      cardId: (_, id, person) => id, sendCards: (_) async { uploads++; });
    expect(uploads, 0);
    await expectLater(WindowsPersonCardSync.run(school,
      prepare: (_) async {}, pushParents: () async => throw StateError('ACK missing'),
      cardId: (_, id, person) => id, sendCards: (_) async { uploads++; }), throwsStateError);
    expect(uploads, 0); expect(await WindowsSyncDependencies.read(school), hasLength(1));
  });
  test('stale parent revision does not publish a card', () async {
    await parent(); await db.applySyncedDocument(db.collection('teachers_directory').doc('one'),
      {'schoolId': school, '_syncRevision': 'newer'});
    expect(await WindowsPersonCardSync.run(school,
      prepare: (_) async => fail('Stale dependency'), pushParents: () async {},
      cardId: (_, id, person) => id, sendCards: (_) async => fail('No card')), 0);
  });
  test('same-operation metadata ACK skips readback only with complete identity and bytes proof', () {
    final payload = {'schoolId': school, 'documentId': 'card', 'documentRevision': 'op',
      'contentHash': 'a' * 64, 'fileId': 'real-drive-file'};
    final row = {...payload, '_syncRevision': 'drive-revision', '_syncOperationId': 'op'};
    final ack = {'success': true, 'schoolId': school, 'syncProtocol': 2,
      'recordRevision': 'drive-revision', 'record': row};
    expect(documentAcknowledgementFromWrite(payload, ack), isNotNull);
    for (final change in [
      {'_syncOperationId': 'other'}, {'_syncRevision': 'other'}, {'fileId': 'other'},
      {'contentHash': 'b' * 64}, {'schoolId': 'foreign'}, {'documentId': 'other'},
    ]) expect(documentAcknowledgementFromWrite(payload, {...ack, 'record': {...row, ...change}}), isNull);
    expect(documentAcknowledgementFromWrite(payload, {...ack, 'driveState': 'pending'}), isNull);
    expect(documentAcknowledgementFromWrite(payload, {...ack, 'recordRevision': 'cf-only'}), isNull);
  });

 test('atomic pilot reserves both existing outboxes in one local CAS without claiming Drive ACK',()async{
   const stable='p-88888888888888888888888888888888';
   final parent={
     'schoolId':school,'collection':'students_directory',
     'documentId':'person-1','operation':'set',
     'operationId':'original-person-operation-0001','baseCloudRevision':'',
     'syncState':'pending',
     'data':{'schoolId':school,'name':'Student One','mobileStableId':stable},
   };
   final card={
     'schoolId':school,'documentId':'card-1',
     'documentRevision':'original-idcard-revision-0001',
     'documentKind':'idCard','deleted':false,'baseCloudRevision':'',
     'ownerRole':'student','studentId':'person-1','personId':stable,
     'optimizedMimeType':'application/pdf','syncState':'Pending',
   };
   final parentRef=db.collection('_windows_firebase_outbox').doc('queue-person-1');
   final cardRef=db.collection('_windows_document_outbox').doc('card-1');
   await parentRef.set(parent);
   await cardRef.set(card);
   const bundleId='atomic-outbox-original-pair-0001';
   await db.markAtomicPersonCardOutbox(
     school:school,parentQueueId:parentRef.id,parentBefore:parent,
     documentId:cardRef.id,documentBefore:card,
     bundleId:bundleId,state:'reserved');
   final parentReserved=(await parentRef.get()).data()!;
   final cardReserved=(await cardRef.get()).data()!;
   expect(parentReserved['atomicBundleId'],bundleId);
   expect(cardReserved['atomicBundleId'],bundleId);
   expect(parentReserved['atomicState'],'reserved');
   expect(cardReserved['atomicState'],'reserved');
   expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty,
     reason:'Cloudflare reservation is not a Drive receipt');
   final changed={...cardReserved,'documentRevision':'new-local-save-0001'};
   await cardRef.set(changed);
   await expectLater(db.markAtomicPersonCardOutbox(
     school:school,parentQueueId:parentRef.id,parentBefore:parentReserved,
     documentId:cardRef.id,documentBefore:cardReserved,
     bundleId:bundleId,state:'committed',
     parentCloudRevision:'live-parent-one',documentCloudRevision:'live-card-one'),
     throwsStateError);
   expect((await parentRef.get()).data()?['atomicState'],'reserved');
   expect((await cardRef.get()).data()?['documentRevision'],'new-local-save-0001');
   await cardRef.set(cardReserved);
   await db.markAtomicPersonCardOutbox(
     school:school,parentQueueId:parentRef.id,parentBefore:parentReserved,
     documentId:cardRef.id,documentBefore:cardReserved,
     bundleId:bundleId,state:'committed',
     parentCloudRevision:'live-parent-one',documentCloudRevision:'live-card-one');
   expect((await parentRef.get()).data()?['atomicCloudRevision'],'live-parent-one');
   expect((await cardRef.get()).data()?['atomicCloudRevision'],'live-card-one');
   expect((await parentRef.get()).data()?['atomicState'],'committed');
   expect((await cardRef.get()).data()?['atomicState'],'committed');
 });


 test('dual verified Drive ACK retires original Person/Card queues together without duplicating upload',()async{
   const stable='p-88888888888888888888888888888888';
   const bundleId='atomic-pilot-verified-pair-0001';
   const contentHash='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
   const parentOp='original-parent-create-operation-0001';
   const cardOp='original-card-create-operation-0001';
   final parentRef=db.collection('students_directory').doc('student-verified');
   final documentRef=db.collection('_local_student_documents').doc('id-verified');
   final parentQueueRef=db.collection('_windows_firebase_outbox').doc('parent-verified-queue');
   final documentQueueRef=db.collection('_windows_document_outbox').doc('id-verified');
   final originalParent={'schoolId':school,'name':'One','mobileStableId':stable};
   final originalLocal={'schoolId':school,'documentId':'id-verified',
     'documentRevision':cardOp,'localPath':'/safe/original.pdf',
     'syncState':'Pending'};
   await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(()async{
     await parentRef.set(originalParent);
     await documentRef.set(originalLocal);
   });
   final queuedParent={'schoolId':school,'collection':'students_directory',
     'documentId':'student-verified','operation':'set',
     'operationId':parentOp,'baseCloudRevision':'',
     'atomicBundleId':bundleId,'atomicState':'committed',
     'atomicCloudRevision':'live-parent-verified',
     'data':originalParent};
   final queuedDocument={'schoolId':school,'documentId':'id-verified',
     'documentRevision':cardOp,'documentKind':'idCard','deleted':false,
     'studentId':'student-verified','personId':stable,
     'ownerRole':'student','localPath':'/safe/original.pdf',
     'baseCloudRevision':'','atomicBundleId':bundleId,
     'atomicState':'committed','atomicCloudRevision':'live-card-verified'};
   await parentQueueRef.set(queuedParent);
   await documentQueueRef.set(queuedDocument);
   final cloudParent={...originalParent,'_syncRevision':'live-parent-verified',
     '_syncOperationId':parentOp};
   final cloudDoc={'schoolId':school,'bundleId':bundleId,
     'documentKind':'idCard','documentId':'id-verified',
     'documentRevision':cardOp,'mimeType':'application/pdf',
     'studentId':'student-verified','personId':stable,'ownerRole':'student',
     'contentHash':contentHash,'fileId':'googleDriveVerifiedFile001',
     'bundleMedia':[{'kind':'idCard','sha256':contentHash,
       'fileId':'googleDriveVerifiedFile001'}],
     '_syncRevision':'live-card-verified','_syncOperationId':cardOp};
   final backup=[
     {'operationId':parentOp,'collection':'students_directory',
       'id':'student-verified','backupState':'verified','driveVerified':true,
       'recordRevision':'live-parent-verified','driveRevision':'drive-parent-confirmed'},
     {'operationId':cardOp,'collection':'documents',
       'id':'id-verified','backupState':'verified','driveVerified':true,
       'recordRevision':'live-card-verified','driveRevision':'drive-card-confirmed'},
   ];
   Future<void> finish({String hash=contentHash,Map<String,dynamic>? before})=>
      db.finishVerifiedAtomicPersonCardOutbox(
       school:school,parentQueueId:parentQueueRef.id,parentBefore:queuedParent,
       parentLocalBefore:originalParent,documentId:documentQueueRef.id,
       documentBefore:queuedDocument,documentLocalBefore:before??originalLocal,
       bundleId:bundleId,parentCloud:cloudParent,documentCloud:cloudDoc,
       verifiedBackups:backup,cardSha256:hash);
   await expectLater(Future<void>.sync(()=>finish(hash:'f'*64)),throwsStateError);
   expect((await parentQueueRef.get()).data(),isNotNull);
   expect((await documentQueueRef.get()).data(),isNotNull);
   await expectLater(Future<void>.sync(() =>
       db.finishVerifiedAtomicPersonCardOutbox(
     school:school,parentQueueId:parentQueueRef.id,parentBefore:queuedParent,
     parentLocalBefore:originalParent,documentId:documentQueueRef.id,
     documentBefore:queuedDocument,documentLocalBefore:originalLocal,
     bundleId:bundleId,parentCloud:cloudParent,
     documentCloud:{...cloudDoc,'fileId':'different-unverified-drive-file'},
     verifiedBackups:backup,cardSha256:contentHash)),throwsStateError,
     reason:'Cloud document and attested media must share one Drive file ID');
   expect((await documentQueueRef.get()).data(),isNotNull);
   await documentRef.set({...originalLocal,'documentRevision':'newer-local-card-edit'});
   await expectLater(Future<void>.sync(()=>finish()),throwsStateError);
   expect((await parentQueueRef.get()).data(),isNotNull);
   expect((await documentQueueRef.get()).data(),isNotNull);
   await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(()=>
      documentRef.set(originalLocal));
   await finish();
   expect((await parentQueueRef.get()).data(),isNull);
   expect((await documentQueueRef.get()).data(),isNull);
   expect((await parentRef.get()).data()?['_syncRevision'],'live-parent-verified');
   expect((await db.collection('documents').doc('id-verified').get()).data()?['bundleId'],bundleId);
   expect((await documentRef.get()).data()?['syncState'],'Synced');
   expect((await documentRef.get()).data()?['cloudRevision'],'drive-card-confirmed');
   expect((await db.collection('_windows_sync_receipts')
       .doc('document-id-verified-$cardOp').get()).data()?['bundleId'],bundleId);
 });

}
