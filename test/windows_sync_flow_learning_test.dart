import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_sync_evidence.dart';
import '../lib/windows_sync_flow.dart';
import '../lib/windows_learned_sync_rules.dart';
import '../lib/windows_repair_memory.dart';
import '../lib/windows_sync_projection.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_ui_localization.dart' as ui;

void main(){
  TestWidgetsFlutterBinding.ensureInitialized();
  const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  Map<String,dynamic> event(String stage,{String op='operation-0000000001',String category='timeout'})=>{
    'schoolId':school,'collection':'school_notices','documentId':'n',
    'queueCollection':'_windows_firebase_outbox','operationId':op,
    'failureCategory':category,'stage':stage,
  };
  setUp((){ui.WindowsUiLanguage.change('en');WindowsSyncEvidence.active.value={};});
  tearDown(()=>ui.WindowsUiLanguage.change('en'));
  test('24 hour expiry removes display events but preserves persistent successful rules',(){
    final rules=WindowsLearnedSyncRules();
    rules.observe(event('retry'),school);rules.observe(event('verified'),school);
    rules.observe(event('verified'),school);
    expect(rules.rules.single['successes'],1);
    const now=200000000;
    expect(recentRepairHistory([{'at':now-86400000},{'at':now-1}],now),[{'at':now-1}]);
    final restored=WindowsLearnedSyncRules()..restore(rules.snapshot(school),school);
    expect(restored.recommend(school,'school_notices','timeout'),'replay_original');
    expect(restored.recommend('foreign','school_notices','timeout'),isNull);
    expect(restored.recommend(school,'school_notices','quota'),isNull);
    restored.observe(event('learnedActionApplied',op:'operation-0000000002'),school);
    restored.observe(event('retry',op:'operation-0000000002'),school);
    expect(restored.recommend(school,'school_notices','timeout'),isNull);
  });
  test('unverified outcomes cannot train; conflicts only choose fresh verification',(){
    final rules=WindowsLearnedSyncRules();
    rules.observe(event('requestCompleted'),school);
    rules.observe({...event('repairDiagnosed',category:'conflict'),'outcome':'retry_admitted'},school);
    expect(rules.rules,isEmpty);
    rules.observe({...event('repairDiagnosed',category:'conflict'),'outcome':'verified_cloud_reconciled'},school);
    expect(rules.recommend(school,'school_notices','conflict'),'verify_original');
    expect((WindowsLearnedSyncRules()..restore(rules.snapshot(school),'foreign')).rules,isEmpty);
  });
  test('expiry prunes resolved per-operation history while keeping unresolved evidence',(){
    final memory=WindowsRepairMemory();
    memory.observe(event('retry'),school,1);memory.observe(event('verified'),school,2);
    memory.observe(event('conflict',op:'unresolved-operation'),school,3);
    memory.pruneResolved(86400002);
    expect(memory.entries.length,1);expect(memory.entries.single['status'],'reviewRequired');
  });
  test('only data-bearing successful idle cycles replace the last measured timing',(){
    final clock=VerifiedSyncTiming();
    expect(clock.complete(startSequence:0,micros:100,now:1,idle:true),false);
    clock.verified();expect(clock.complete(startSequence:0,micros:2400000,now:2,idle:false),false);
    expect(clock.complete(startSequence:0,micros:2400000,now:3,idle:true),true);
    expect(clock.complete(startSequence:1,micros:1,now:4,idle:true),false);
    expect(clock.lastMicros,2400000);
    final restored=VerifiedSyncTiming()..restore(clock.snapshot(school),school);
    expect(restored.lastMicros,2400000);
    expect((VerifiedSyncTiming()..restore(clock.snapshot(school),'foreign')).lastMicros,isNull);
    expect(projectWindowsSyncState([],nowMillis:0,incomingPending:1),'pending');
    expect(projectWindowsSyncState([],nowMillis:0,incomingPending:0),'idle');
  });
  test('stalled self repair is own-school, delayed, bounded and never clears evidence',(){
    const foreign='vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const collection='students_directory';
    const now=1800000000000;
    final stale={
      'schoolId':school,'collection':collection,'state':'downloading',
      'remaining':1,'observedAt':now-180000,'repairAttempts':0,
    };
    List<String> select(Iterable<Map<String,dynamic>> rows)=>windowsStalledDownloadRepairTargets(
      schoolId:school,downloads:rows,
      allowedCollections:{collection,'school_expenses'},nowMillis:now);
    expect(select([stale]),[collection]);
    expect(select([{...stale,'state':'needsReview'}]),[collection]);
    expect(select([{...stale,'schoolId':foreign}]),isEmpty);
    expect(select([{...stale,'state':'verified'}]),isEmpty);
    expect(select([{...stale,'remaining':0}]),isEmpty);
    expect(select([{...stale,'observedAt':now-30000}]),isEmpty);
    expect(select([{...stale,'collection':'unknown_collection'}]),isEmpty);
    expect(select([{...stale,'repairAttempts':2}]),isEmpty);
    expect(select([{...stale,'repairAttempts':1,
      'repairLastAttemptAt':now-60000}]),isEmpty);
    expect(select([{...stale,'repairAttempts':1,
      'repairLastAttemptAt':now-1000000}]),[collection]);
    expect(select([stale,{...stale,'collection':'school_expenses',
      'observedAt':now-300000}]),['school_expenses']);
    expect(stale['remaining'],1,reason:'selection must never complete a download');
  });
  test('incoming cloud check is not an upload, and school-scoped counts retain work',(){
    final breakdown=windowsIncomingPendingBreakdown(
      schoolId:school,
      downloads:[
        {'schoolId':school,'state':'downloading','remaining':2},
        {'schoolId':school,'state':'verified','remaining':4},
        {'schoolId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
         'state':'needsReview','remaining':100},
      ],
      remoteChangeQueued:true,
      binaryStatus:{'schoolId':school,'inventory':'MEASURED',
                    'pending':1,'failed':1,'interrupted':0},
    );
    expect(breakdown,{'recordDownloads':2,'remoteChecks':1,'mediaFiles':2,'total':5});
    expect(windowsSyncFlowPendingText(0,breakdown),'Incoming work');
    expect(windowsSyncFlowPendingText(2,breakdown),'2 uploads');
    final onlyCheck=windowsIncomingPendingBreakdown(
      schoolId:school,downloads:[],remoteChangeQueued:true,
      binaryStatus:{'schoolId':'foreign','inventory':'MEASURED','pending':9});
    expect(onlyCheck['total'],1);
    expect(windowsSyncFlowPendingText(0,onlyCheck),'Cloud check queued');
    expect(projectWindowsSyncState([],nowMillis:0,incomingPending:onlyCheck['total']!),'pending');
    expect(windowsIncomingPendingBreakdown(schoolId:school,
      downloads:[],remoteChangeQueued:false)['total'],0);
    expect(windowsSyncFlowPendingText(0,{}),'0 pending');
  });
  test('activity is school scoped and subscriptions are not transfer animations',(){
    expect(WindowsSyncEvidence.dataAction('managed/events'),false);
    WindowsSyncEvidence.enter(school,'cloud');WindowsSyncEvidence.enter(school,'cloud');
    WindowsSyncEvidence.leave(school,'cloud');expect(WindowsSyncEvidence.lanes(school),{'cloud'});
    expect(WindowsSyncEvidence.lanes('foreign'),isEmpty);
    WindowsSyncEvidence.leave(school,'cloud');expect(WindowsSyncEvidence.lanes(school),isEmpty);
  });
  test('learned retry retains the exact operation and cannot manufacture an ACK',()async{
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    final db=FirebaseFirestore.instance;
    await db.switchProfile('learning-${DateTime.now().microsecondsSinceEpoch}',identity:{'schoolSyncId':school,'schoolId':school});
    await db.collection('school_notices').doc('n').set({'text':'Original'});
    final row=(await db.collection('_windows_firebase_outbox').get()).docs.single;
    await row.reference.update({'syncState':'needsAttention','failureCategory':'timeout'});
    final original=(await row.reference.get()).data()!;
    var reads=0;
    await WindowsPendingSchoolSync.repair(profileId:db.activeProfileId,school:school,
      learnedAction:(_,__)=>'replay_original',read:(_,id)async{reads++;return {'schoolId':school,'syncProtocol':2,'pointRead':true,'records':{}};});
    final retry=(await row.reference.get()).data()!;
    expect(reads,0);expect(retry['operationId'],original['operationId']);expect(retry['data'],original['data']);
    expect(retry['baseCloudRevision'],original['baseCloudRevision']);expect(retry['syncState'],'retry');
    expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty);
    await row.reference.update({'syncState':'conflict','failureCategory':'conflict'});
    await WindowsPendingSchoolSync.repair(profileId:db.activeProfileId,school:school,
      learnedAction:(_,__)=>'replay_original',read:(_,id)async{reads++;return {'schoolId':school,'syncProtocol':2,'pointRead':true,'records':{}};});
    expect(reads,1);expect((await row.reference.get()).exists,true);
  });
  for(final width in [320.0,1100.0]){
    testWidgets('three-node flow is responsive and language-aware at $width',(tester)async{
      await tester.binding.setSurfaceSize(Size(width,1000));addTearDown(()=>tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home:Scaffold(body:SingleChildScrollView(child:MediaQuery(
        data:MediaQueryData(textScaler:TextScaler.linear(1.5)),child:WindowsSyncFlow(
          phase:'idle',label:'Idle',local:'D:\\ 10 GB / 100 GB',cloud:'No verified ACK yet',drive:'Unknown',pending:0,lastMicros:2400000))))));
      await tester.pumpAndSettle();
      expect(find.text('Local Storage'),findsOneWidget);expect(find.text('2.40 sec'),findsOneWidget);
      expect(find.text('Open Folder'),findsNothing);
      ui.WindowsUiLanguage.change('bn');await tester.pumpAndSettle();
      expect(find.text('স্থানীয় স্টোরেজ'),findsOneWidget);expect(find.text('2.40 সেকেন্ড'),findsOneWidget);
      expect(tester.takeException(),isNull);await tester.pumpWidget(const SizedBox());
    });
  }
}
