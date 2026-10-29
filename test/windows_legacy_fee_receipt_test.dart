import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_sync_comparison.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_pending_school_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final db = FirebaseFirestore.instance;
  final at = DateTime(2026,10,29,15,16);
  Map<String,dynamic> local() => {
    'schoolId':school, 'paymentId':'legacy', 'receiptNo':'VS-202610-${at.millisecondsSinceEpoch}',
    'studentId':'S1','studentName':'Student','feeIdentity':'stable-S1','class':'Class 1',
    'month':'2026-10', 'feeItems':{'Tuition':100}, 'installmentAmount':100,
    'expectedAmount':100,'totalPaid':100,'balance':0,'status':'PAID','paymentMode':'Cash',
    'dateText':'29/10/2026','timeText':'15:16',
    'driveUrl':'https://drive.google.com/file/d/original-receipt/view', 'sheetUrl':'',
    'paidAt':Timestamp.fromDate(at.add(const Duration(seconds:45))),
  };
  Map<String,dynamic> cloud() => {...local(), 'id':'legacy',
    'fileId':'original-receipt','fileUrl':'https://drive.google.com/file/d/original-receipt/view',
    'success':true,'syncTiming':{'brokerPreparationMillis':4,'scriptRoundTripMillis':1200},
    '_syncRevision':'verified-cloud-revision','_syncOperationId':'original-cloud-operation'}
    ..remove('driveUrl')..remove('sheetUrl')..remove('paidAt');
  Map<String,dynamic> queued() => {'collection':'fee_payments','documentId':'legacy',
    'schoolId':school,'operation':'set','operationId':'second-local-operation','data':local()};
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile('legacy-fee-${DateTime.now().microsecondsSinceEpoch}',identity:{'schoolSyncId':school});
  });
  test('only the complete known legacy finalization signature can reconcile', () {
    expect(identicalLegacyFeePublication(queued(),cloud()),true);
    expect(automaticDuplicateReadback(queued(),cloud()),true);
    for(final changed in <Map<String,dynamic>>[
      {'totalPaid':99},{'installmentAmount':99},{'balance':1},{'expectedAmount':200},
      {'studentId':'another'},{'receiptNo':'VS-202610-1790000000000'},
      {'fileId':'another-file'},{'fileUrl':'https://drive.google.com/file/d/another/view'},
      {'dateText':'28/10/2026'},{'timeText':'15:17'},{'feeItems':{'Different':100}},
      {'paymentMode':'UPI'},{'paidAt':Timestamp.fromDate(at)},
      {'schoolId':'foreign'},{'unknownFinancialDetail':'changed'},
      {'receiptDocumentId':'new-flow-receipt'},{'_syncDeleted':true},
    ]) expect(automaticDuplicateReadback(queued(),{...cloud(),...changed}),false,reason:changed.keys.join(','));
    expect(automaticDuplicateReadback({...queued(),'operation':'delete'},cloud()),false);
    expect(automaticDuplicateReadback({...queued(),'data':{...local(),'paidAt':Timestamp.fromDate(at.subtract(const Duration(seconds:1)))}},cloud()),false);
  });
  test('only complete committed upload envelopes can be reconciled', () {
    final hash='a'*64;
    final key=sha256.convert(utf8.encode(jsonEncode([school,'legacy','fee_receipt',hash]))).toString();
    final envelope={...cloud(),'cloudflareAccepted':true,'driveState':'verified',
      'uploadResumableVersion':1,'uploadKey':key,'sha256':hash,'sizeBytes':1000,'offset':1000,'committed':true,
      'deliveryTiming':{'version':1,'deliveryMillis':1200,'observedAt':at.millisecondsSinceEpoch}};
    expect(automaticDuplicateReadback(queued(),envelope),true);
    for(final bad in <Map<String,dynamic>>[
      {'driveState':'pending'},{'committed':false},{'offset':500},{'uploadKey':'b'*64},
      {'syncTiming':{'unknownFinancialField':100}}, {'success':false},
    ]) expect(automaticDuplicateReadback(queued(),{...envelope,...bad}),false);
  });
  test('verified legacy duplicate retires one exact queue row and archives both financial originals', () async {
    await db.collection('fee_payments').doc('legacy').set(local());
    final row=(await db.collection('_windows_firebase_outbox').get()).docs.single;
    await row.reference.update({'syncState':'conflict','failureCategory':'conflict'});
    final pending=(await row.reference.get()).data()!;
    await db.collection('_windows_sync_status').doc('repair-${pending['operationId']}').set({
      'schoolId':school,'operationId':pending['operationId'],'attempts':5,
      'nextProbeAt':DateTime.now().add(const Duration(days:1)).millisecondsSinceEpoch,
    });
    var reads=0;
    await WindowsPendingSchoolSync.repair(profileId:db.activeProfileId,school:school,
      read:(collection,id)async { reads++; return {'schoolId':school,'syncProtocol':2,'pointRead':true,'records':{id:cloud()}}; });
    expect(reads,1);
    expect((await row.reference.get()).exists,false);
    final history=(await db.collection('_windows_sync_conflict_history').doc(pending['operationId']).get()).data()!;
    expect(history['data']['paidAt'],isA<Timestamp>());
    expect(history['verifiedCloud']['fileId'],'original-receipt');
    expect((await db.collection('fee_payments').doc('legacy').get()).data()?['totalPaid'],100);
    expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty,
      reason:'Authenticated duplicate reconciliation must not manufacture an operation ACK');
  });
  test('a money mismatch stays retained and new legacy repair probe is bounded', () async {
    await db.collection('fee_payments').doc('legacy').set(local());
    final row=(await db.collection('_windows_firebase_outbox').get()).docs.single;
    await row.reference.update({'syncState':'conflict','failureCategory':'conflict'});
    var reads=0;
    Future<void> repair() async { await WindowsPendingSchoolSync.repair(profileId:db.activeProfileId,school:school,
      read:(collection,id)async {reads++;return {'schoolId':school,'syncProtocol':2,'pointRead':true,'records':{id:{...cloud(),'totalPaid':99}}};}); }
    await repair(); await repair();
    expect(reads,1); expect((await row.reference.get()).exists,true);
    expect((await db.collection('fee_payments').doc('legacy').get()).data()?['totalPaid'],100);
  });
}
