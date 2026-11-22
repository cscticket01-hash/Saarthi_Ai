import 'dart:async';
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
    expect(projectWindowsSyncState([],nowMillis:0,incomingPending:1),'idle');
    expect(projectWindowsSyncState([],nowMillis:0,incomingPending:0),'idle');
    // Background reconciliation/Drive polling cannot keep device sync busy
    // once all locally durable, verified ACKs have removed the queue entries.
    expect(projectWindowsSyncState([],nowMillis:0,syncing:true),'idle');
    expect(projectWindowsSyncState([],nowMillis:0,syncing:true,incomingPending:1),'idle');
    expect(projectWindowsSyncState([{'syncState':'pending'}],nowMillis:0,syncing:true),'syncing');
    expect(projectWindowsSyncState([],nowMillis:0,syncing:true,reviewRequired:true),'needsAttention');
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
    expect(projectWindowsSyncState([],nowMillis:0,incomingPending:onlyCheck['total']!),'idle');
    expect(projectWindowsDevicePhase(
      durableState:'idle',uploadPending:0,syncing:true,
      transferActive:false,paused:false,stalled:false),'idle');
    expect(projectWindowsDevicePhase(
      durableState:'pending',uploadPending:1,syncing:true,
      transferActive:false,paused:false,stalled:false),'preparing');
    expect(projectWindowsDevicePhase(
      durableState:'pending',uploadPending:1,syncing:true,
      transferActive:true,paused:false,stalled:false),'syncing');
    expect(projectWindowsDevicePhase(
      durableState:'needsAttention',uploadPending:1,syncing:true,
      transferActive:false,paused:false,stalled:false),'needsAttention');
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
  test('parallel admission is restricted to eligible independent school records', () {
    final item = <String,dynamic>{
      'schoolId':school,'collection':'school_notices','documentId':'notice-a',
      'operation':'set','operationId':'notice-operation-0001',
      'baseCloudRevision':'','syncState':'pending','data':{'text':'a'},
    };
    bool eligible(Map row) => canParallelStageRecord(row,school,edgeDeliverySupported:true);
    expect(eligible(item),true);
    expect(eligible({...item,'collection':'school_calendar'}),true);
    for(final collection in ['school_expenses','attendance_records',
      'attendance_logs','teacher_attendance']) {
      expect(eligible({...item,'collection':collection}),true);
    }
    expect(eligible({...item,'collection':'fee_payments'}),false);
    expect(eligible({...item,'collection':'students_directory'}),false);
    expect(eligible({...item,'schoolId':'foreign'}),false);
    expect(eligible({...item,'operation':'delete'}),false);
    expect(eligible({...item,'priorDeletion':{}}),false);
    expect(eligible({...item,'atomicBundleId':'bundle'}),false);
    expect(eligible({...item,'syncState':'cloudAccepted'}),false);
    expect(eligible({...item,'syncState':'retry',
      'retryAtMillis':DateTime.now().add(const Duration(hours:1)).millisecondsSinceEpoch}),false);
    expect(canParallelStageRecord(item,school,edgeDeliverySupported:false),false);
  });
  test('existing person concurrency is restricted to identity-bound contact patches', () {
    for(final collection in ['students_directory','teachers_directory']) {
      final key=collection=='students_directory'?'mobileStableId':'teacherId';
      final patch={'version':1,'identity':{key:'established-owner'},
        'set':{'phone':'synthetic-contact'},'remove':[]};
      final row={'schoolId':school,'collection':collection,'documentId':'person-a',
        'operation':'set','operationId':'contact-operation-001',
        'baseCloudRevision':'provider-revision','syncState':'pending','updateIntent':true,
        'data':{key:'established-owner','phone':'synthetic-contact'},'fieldPatch':patch};
      bool eligible(Map item)=>canParallelStageRecord(item,school,edgeDeliverySupported:true);
      expect(eligible(row),true);
      expect(eligible({...row,'createIntent':true}),false);
      expect(eligible({...row,'baseCloudRevision':'cf-temporary'}),false);
      expect(eligible({...row,'fieldPatch':{...patch,'set':{'active':false}}}),false);
      expect(eligible({...row,'data':{key:'different-owner'}}),false);
      expect(eligible({...row,'data':{...row['data'] as Map,'photoUrl':'data:image/jpeg;base64,AA=='}}),false);
      expect(eligible({...row,'wireMode':'snapshot2','wireData':row['data']}),false);
      expect(eligible({...row,'fieldPatch':{...patch,'remove':['address']}}),false);
    }
  });
  test('unrelated person and financial backlog cannot starve standalone expenses', () {
    final expense={'schoolId':school,'collection':'school_expenses',
      'documentId':'expense-a','operationId':'expense-operation-0001',
      'operation':'set','syncState':'pending','baseCloudRevision':'',
      'data':{'title':'Supplies'}};
    final rows=<Map<String,dynamic>>[
      expense,
      {'schoolId':school,'collection':'students_directory',
       'documentId':'student-a','operationId':'student-create-0001',
       'operation':'set','syncState':'cloudAccepted'},
      {'schoolId':school,'collection':'fee_payments',
       'documentId':'fee-a','operationId':'fee-operation-00001',
       'operation':'set','syncState':'pending'},
      {'schoolId':school,'collection':'documents',
       'documentId':'file-a','operationId':'document-operation-1',
       'operation':'set','syncState':'pending'},
    ];
    expect(canStageExpensePastUnrelatedOwners(expense,rows,school),true);
    expect(canStageExpensePastUnrelatedOwners(expense,[
      ...rows,{'schoolId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
       'collection':'school_notices','operation':'set'},
    ],school),false);
    expect(canStageExpensePastUnrelatedOwners(expense,[
      ...rows,{'schoolId':school,'collection':'fee_payments',
       'atomicBundleId':'reserved-transaction','operation':'set'},
    ],school),false);
    expect(canStageExpensePastUnrelatedOwners(expense,[
      ...rows,{'schoolId':school,'collection':'students_directory',
       'operation':'delete'},
    ],school),false);
    expect(canStageExpensePastUnrelatedOwners(expense,[
      ...rows,{'schoolId':school,'collection':'school_expenses',
       'documentId':'expense-a','operationId':'other-expense-op','operation':'set'},
    ],school),false);
    expect(canStageExpensePastUnrelatedOwners(
      {...expense,'schoolId':'foreign'},rows,school),false);
  });

  test('attendance admission keeps school policy and person dependencies ordered', () {
    final attendance={'schoolId':school,'collection':'attendance_records',
      'documentId':'attendance-a','operationId':'attendance-operation-001',
      'operation':'set','baseCloudRevision':'','syncState':'pending',
      'data':{'personId':'synthetic-person','present':true}};
    final safe=<Map<String,dynamic>>[
      attendance,
      {'schoolId':school,'collection':'fee_payments','documentId':'fee-a',
       'operationId':'fee-op-000000001','operation':'set','syncState':'pending'},
      {'schoolId':school,'collection':'documents','documentId':'document-a',
       'operationId':'file-op-000000001','operation':'set','syncState':'pending'},
    ];
    expect(canStageAttendancePastUnrelatedOwners(attendance,safe,school),true);
    for(final parent in ['students_directory','teachers_directory','school_config','school_settings']) {
      expect(canStageAttendancePastUnrelatedOwners(attendance,[
        ...safe,{'schoolId':school,'collection':parent,'operation':'set',
          'syncState':'cloudAccepted'},
      ],school),false);
    }
    expect(canStageAttendancePastUnrelatedOwners(attendance,[
      ...safe,{'schoolId':school,'collection':'attendance_records',
      'documentId':'attendance-a','operationId':'different-op','operation':'set'},
    ],school),false);
    expect(canStageAttendancePastUnrelatedOwners(attendance,[
      ...safe,{'schoolId':school,'collection':'school_calendar',
      'operation':'delete','syncState':'pending'},
    ],school),false);
    expect(canStageAttendancePastUnrelatedOwners(attendance,[
      ...safe,{'schoolId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'collection':'school_notices','operation':'set'},
    ],school),false);
  });

  test('bounded admission drains in-flight records before admitting another window',() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    final db=FirebaseFirestore.instance;
    await db.switchProfile('parallel-${DateTime.now().microsecondsSinceEpoch}',
      identity:{'schoolSyncId':school,'schoolId':school});
    for(var i=0;i<4;i++) {
      await db.collection('school_notices').doc('parallel-$i').set({'text':'notice $i'});
    }
    final ready=Completer<void>(), release=Completer<void>();
    var started=0, active=0, peak=0;
    var allow=true;
    final flush=WindowsPendingSchoolSync.flush(
      profileId:db.activeProfileId,
      canAdmit:()=>allow,
      parallelAdmission:(item)=>canParallelStageRecord(item,school,edgeDeliverySupported:true),
      send:(_,__,___,____) async {},
      sendVersioned:(item)async{
        started++;active++;
        if(active>peak)peak=active;
        if(started==3&&!ready.isCompleted)ready.complete();
        await release.future;
        active--;
        return 'revision-${item['operationId']}';
      },
    );
    try {
      await ready.future.timeout(const Duration(seconds:5));
      expect(started,3);
      expect(peak,3);
      allow=false;
    } finally {
      if(!release.isCompleted)release.complete();
      await flush;
    }
    expect(started,3);
    expect((await db.collection('_windows_firebase_outbox').get()).docs.length,1);
  });
  test('unresolved parent keeps attendance and expense admission serial',() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    final db=FirebaseFirestore.instance;
    await db.switchProfile('parallel-barrier-${DateTime.now().microsecondsSinceEpoch}',
        identity:{'schoolSyncId':school,'schoolId':school});
    final queue=db.collection('_windows_firebase_outbox');
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() async {
      await queue.doc('parent').set({
        'schoolId':school,'collection':'students_directory','documentId':'parent-a',
        'operation':'set','operationId':'parent-operation-0001','baseCloudRevision':'',
        'syncState':'needsAttention','data':{'name':'Retained parent'},
      });
      for(var i=0;i<3;i++) {
        await queue.doc('att-$i').set({
          'schoolId':school,'collection':'attendance_records','documentId':'att-$i',
          'operation':'set','operationId':'attendance-operation-000$i','baseCloudRevision':'',
          'syncState':'pending','data':{'status':'present'},
        });
      }
    });
    var active=0,peak=0,sends=0;
    await WindowsPendingSchoolSync.flush(
      profileId:db.activeProfileId,
      parallelAdmission:(item)=>canParallelStageRecord(item,school,edgeDeliverySupported:true),
      send:(_,__,___,____) async {},
      sendVersioned:(item)async{
        sends++;active++;if(active>peak)peak=active;
        await Future<void>.delayed(Duration.zero);active--;
        return 'revision-${item['operationId']}';
      });
    expect(sends,3);
    expect(peak,1);
    expect((await queue.doc('parent').get()).data()?['syncState'],'needsAttention');
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
      expect(find.text('Local Storage'),findsOneWidget);expect(find.text('Last sync: 2.40 sec'),findsOneWidget);
      expect(find.text('Open Folder'),findsNothing);
      ui.WindowsUiLanguage.change('bn');await tester.pumpAndSettle();
      expect(find.text('স্থানীয় স্টোরেজ'),findsOneWidget);expect(find.text('শেষ সিঙ্ক: 2.40 সেকেন্ড'),findsOneWidget);
      expect(tester.takeException(),isNull);await tester.pumpWidget(const SizedBox());
    });
  }
}
