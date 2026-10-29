import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_id_card_reviews.dart';
import '../lib/windows_sync_recovery.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_repair_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  Map<String,dynamic> event(String stage, {String id='T1', String op='operation-0000000001', String category='timeout'}) => {
    'schoolId':school,'collection':'teachers_directory','documentId':id,
    'operationId':op,'queueCollection':'_windows_firebase_outbox',
    'stage':stage,'failureCategory':category,
  };
  test('only an exact verified operation resolves remembered repair; persistence retains success', () {
    final memory=WindowsRepairMemory();
    expect(memory.observe(event('automaticRepair'),school,1),isTrue);
    memory.observe(event('requestCompleted'),school,2);
    memory.observe(event('verified',id:'T2'),school,3);
    memory.observe(event('verified',op:'other-operation-0001'),school,4);
    memory.observe({...event('verified'),'schoolId':'foreign'},school,5);
    expect(memory.entries.single['status'],'retrying');
    memory.observe(event('verified'),school,6);
    memory.observe(event('verified'),school,7);
    expect(memory.entries.single['verifiedRepairs'],1);
    final restored=WindowsRepairMemory()..restore(jsonDecode(jsonEncode(memory.snapshot(school))),school);
    expect(restored.entries.single['status'],'resolved');
    restored.observe(event('retry'),school,8);
    expect(restored.entries.single['status'],'recurred');
    expect(restored.entries.single['recurrences'],1);
    restored.observe(event('retry'),school,9);
    expect(restored.entries.single['recurrences'],1,'log repeats are not new repair episodes');
    expect((WindowsRepairMemory()..restore(memory.snapshot(school),'foreign')).entries,isEmpty);
  });
  test('bounded memory groups observations but separates school, module, record and operation', () {
    final memory=WindowsRepairMemory();
    for(var i=0;i<150;i++) memory.observe(event('conflict',id:'T$i'),school,i);
    expect(memory.entries.length,WindowsRepairMemory.limit);
    memory.observe(event('conflict',id:'T149'),school,151);
    expect(memory.entries.last['observations'],2);
    memory.observe({...event('conflict',id:'T149'),'collection':'students_directory'},school,152);
    expect(memory.entries.last['observations'],1);
    final snapshot=memory.snapshot(school);
    expect(jsonEncode(snapshot),isNot(contains('password')));
    final corrupt={'version':1,'schoolId':school,'entries':[{'key':'bad','scope':'bad','schoolId':school}]};
    expect((WindowsRepairMemory()..restore(corrupt,school)).entries,isEmpty);
  });
  test('verified readback differs from merely admitting a retry', () {
    final memory=WindowsRepairMemory();
    memory.observe({...event('repairDiagnosed'),'outcome':'retry_admitted'},school,1);
    expect(memory.entries.single['verifiedRepairs'],0);
    memory.observe({...event('repairDiagnosed'),'outcome':'verified_cloud_reconciled'},school,2);
    expect(memory.entries.single['status'],'resolved');
    expect(memory.entries.single['verifiedRepairs'],1);
  });
  test('unchanged diagnosed conflict cools down only with known unchanged cloud evidence', () {
    final prior={'outcome':'review_required','inputSignature':'sig','cloudManifestRevision':'head','verifiedReadbackAt':10};
    bool skip({String sig='sig',String? cloud='head',int at=20,bool manual=false})=>
      repeatedRepairProbe(prior,signature:sig,cloudRevision:cloud,now:at,explicitRetry:manual);
    expect(skip(),isTrue);expect(skip(sig:'edited'),isFalse);
    expect(skip(cloud:'new-head'),isFalse);expect(skip(cloud:null),isFalse);
    expect(skip(manual:true),isFalse);expect(skip(at:9),isFalse);
    expect(skip(at:3600010),isFalse);
  });
  test('card evidence preserves cooldown across repeat observations and manual retry retains checks', () async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    final db=FirebaseFirestore.instance;
    await db.switchProfile('memory-${DateTime.now().microsecondsSinceEpoch}',identity:{'schoolSyncId':school});
    PublishedIdInputConflict problem(String input)=>PublishedIdInputConflict(
      schoolId:school,documentId:'card1',ownerRole:'teacher',personId:'person1',
      personDocId:'T1',inputRevision:input,cloudRevision:'cloud1');
    await WindowsIdCardReviews.retain(problem('input1'),'Teacher');
    var calls=0;var clock=100000;
    Future<Map<String,dynamic>> unavailable() async {calls++;throw StateError('Synthetic unavailable evidence');}
    Future<void> repair({bool manual=false})=>WindowsIdCardReviews.repairPending(school,
      read:unavailable,explicitRetry:manual,now:()=>DateTime.fromMillisecondsSinceEpoch(clock));
    await repair();expect(calls,1);
    final ref=db.collection(WindowsIdCardReviews.collection).doc('card1');
    final before=(await ref.get()).data()!;
    await WindowsIdCardReviews.retain(problem('input1'),'Teacher');
    expect((await ref.get()).data()?['nextRepairAt'],before['nextRepairAt']);
    await repair();expect(calls,1,'same failed evidence cannot issue a new network read');
    await repair(manual:true);expect(calls,2);
    expect((await ref.get()).data()?['status'],'needsReview','manual retry is not proof');
    await WindowsIdCardReviews.retain(problem('input2'),'Teacher');
    await repair();expect(calls,3,'new input gets a fresh bounded diagnosis');
    for(var n=0;n<6;n++){clock+=3600000;await repair();}
    expect(calls,7,'five probes for the new evidence; no endless repair loop');
    expect((await ref.get()).data()?['status'],'needsReview');
    expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty);
  });

}
