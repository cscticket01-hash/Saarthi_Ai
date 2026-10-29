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
}
