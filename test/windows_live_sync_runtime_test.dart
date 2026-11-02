import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/live_sync_protocol.dart';
import '../lib/windows_live_sync_runtime.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_connect/central_school_cloud.dart';

const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
Map<String,dynamic> page(int after)=>{
 'success':true,'liveProtocol':1,'schoolId':school,'cursor':1,'head':1,'more':false,
 'events':after==0?[{'sequence':1,'collection':'school_expenses','id':'one',
  'record':{'schoolId':school,'_syncRevision':'live-one','amount':1}}]:[],
};
class MemoryInbox implements WindowsLiveRuntimeStore {
 int value=0,cleared=0;bool fail=false;
 final entries=<WindowsLiveIncoming>[];
 @override Future<int> cursor(String school)async=>value;
 @override Future<void> retainPage(LiveSyncPage page)async{
  if(fail)throw StateError('disk failed');
  if(page.after!=value)throw StateError('cursor differs');
  for(final e in page.events)entries.add(WindowsLiveIncoming('$school-${e['sequence']}',
    e['sequence'],e['collection'],e['id']));
  value=page.cursor;
 }
 @override Future<List<WindowsLiveIncoming>> pending()async=>List.of(entries);
 @override Future<void> replaceCheckpoint(int expectedCursor,int nextCursor,
   [Set<String>? verifiedCollections])async{
  if(value!=expectedCursor)throw StateError('cursor changed');
  entries.removeWhere((e)=>e.sequence<=nextCursor &&
    (verifiedCollections==null||verifiedCollections.contains(e.collection)));value=nextCursor;
 }
 @override Future<void> applied(List<WindowsLiveIncoming> rows)async{
  entries.removeWhere((e)=>rows.contains(e));cleared+=rows.length;
 }
}
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 test('hints only schedule; durable replay is reconciled by the ordinary sync owner',()async{
  final store=MemoryInbox();var scheduled=0,receipts=0,reconciled=0;
  final runtime=WindowsLiveSyncRuntime(school:school,profile:'one',deviceId:'persistent-device-one',
   store:store,currentSchool:()=>school,currentProfile:()=>'one',canRun:()=>true,
   onWork:()=>scheduled++,reconcile:(targets)async{
    reconciled++;expect(store.value,1);expect(receipts,1);
    expect(targets,{'school_expenses':{'one'}});return true;
   },call:(action,body)async{
    if(action.endsWith('/received')){receipts++;return {'success':true};}
    return page(body['after']);
   });
  runtime.hint();runtime.reconnect();expect(scheduled,2);expect(reconciled,0);
  await runtime.run();expect(reconciled,1);expect(store.cleared,1);
  expect(store.entries,isEmpty);
 });
 test('concurrent run requests share one replay and one business reconciliation',()async{
  final store=MemoryInbox(),response=Completer<Map<String,dynamic>>();
  var reads=0,applies=0;
  final runtime=WindowsLiveSyncRuntime(school:school,profile:'one',deviceId:'persistent-device-one',
   store:store,currentSchool:()=>school,currentProfile:()=>'one',canRun:()=>true,
   onWork:(){},reconcile:(targets)async{applies++;return true;},
   call:(action,body)async{
    if(action.endsWith('/received'))return {'success':true};
    reads++;return response.future;
   });
  final first=runtime.run(),second=runtime.run();expect(identical(first,second),isTrue);
  await Future<void>.delayed(Duration.zero);expect(reads,1);
  response.complete(page(0));await Future.wait([first,second]);
  expect(applies,1);expect(store.cleared,1);
 });
 test('blocked local apply retains incoming work and retries despite an advanced delivery cursor',()async{
  final store=MemoryInbox();var verified=false,reconciled=0;
  final runtime=WindowsLiveSyncRuntime(school:school,profile:'one',deviceId:'persistent-device-one',
   store:store,currentSchool:()=>school,currentProfile:()=>'one',canRun:()=>true,
   onWork:(){},reconcile:(targets)async{reconciled++;return verified;},
   call:(action,body)async=>action.endsWith('/received')?{'success':true}:page(body['after']));
  await runtime.run();expect(store.value,1);expect(store.entries.length,1);expect(store.cleared,0);
  verified=true;await runtime.run();expect(store.entries,isEmpty);expect(reconciled,2);
 });
 test('disk failure cannot call the business reconciler or acknowledge delivery',()async{
  final store=MemoryInbox()..fail=true;var actions=0;
  final runtime=WindowsLiveSyncRuntime(school:school,profile:'one',deviceId:'persistent-device-one',
   store:store,currentSchool:()=>school,currentProfile:()=>'one',canRun:()=>true,
   onWork:(){},reconcile:(targets)async{actions++;return true;},
   call:(action,body)async{if(action.endsWith('/received'))actions++;return page(0);});
  await expectLater(runtime.run(),throwsStateError);expect(actions,0);expect(store.value,0);
 });
 test('pause/profile switch during the network await prevents retention and business apply',()async{
  for(final pause in [true,false]){
   final store=MemoryInbox(),reply=Completer<Map<String,dynamic>>();
   var enabled=true,profile='one';
   final runtime=WindowsLiveSyncRuntime(school:school,profile:'one',deviceId:'persistent-device-one',
    store:store,currentSchool:()=>school,currentProfile:()=>profile,canRun:()=>enabled,
    onWork:(){},reconcile:(targets)async=>throw StateError('must not reconcile'),
    call:(action,body)=>reply.future);
   final running=runtime.run();await Future<void>.delayed(Duration.zero);
   if(pause){enabled=false;}else{profile='two';}
   reply.complete(page(0));await expectLater(running,throwsStateError);
   expect(store.value,0);expect(store.entries,isEmpty);
  }
 });
 test('profile switch after verified reconciliation cannot clear original retained events',()async{
  final store=MemoryInbox();var profile='one';
  final runtime=WindowsLiveSyncRuntime(school:school,profile:'one',deviceId:'persistent-device-one',
   store:store,currentSchool:()=>school,currentProfile:()=>profile,canRun:()=>true,
   onWork:(){},reconcile:(targets)async{profile='two';return true;},
   call:(action,body)async=>action.endsWith('/received')?{'success':true}:page(body['after']));
  await expectLater(runtime.run(),throwsStateError);expect(store.entries.length,1);expect(store.cleared,0);
 });
 test('compacted history requires a verified pinned snapshot before checkpoint replacement',()async{
  for(final variant in ['verified','blocked','head-changed']){
   final store=MemoryInbox()..value=1;
   var heads=0,receipts=0,recoveries=0;
   final runtime=WindowsLiveSyncRuntime(school:school,profile:'one',deviceId:'persistent-device-one',
    store:store,currentSchool:()=>school,currentProfile:()=>'one',canRun:()=>true,
    onWork:(){},reconcile:(targets)async=>throw StateError('no retained events'),
    recoverSnapshot:(collections)async{recoveries++;expect(collections,{'school_expenses'});return variant!='blocked';},
    call:(action,body)async{
     if(action.endsWith('/changes'))throw CentralCloudException(409,'school_cloud','Snapshot required',diagnosticCode:'LIVE_SNAPSHOT_REQUIRED');
     if(action.endsWith('/received')){receipts++;expect(store.value,5);return {'success':true};}
     heads++;return {'success':true,'liveProtocol':1,'schoolId':school,
      'cursor':variant=='head-changed'&&heads>1?6:5,
      'collections':[{'collection':'school_expenses','state':'active'}]};
    });
   if(variant=='head-changed'){await expectLater(runtime.run(),throwsStateError);}else{await runtime.run();}
   expect(recoveries,1);expect(store.value,variant=='verified'?5:1);
   expect(receipts,variant=='verified'?1:0);
  }
 });
 test('compacted replay verifies retired Drive collections and rejects authority changes',()async{
  for(final variant in ['verified','blocked','state-changed']){
   final store=MemoryInbox()..value=1;
   store.entries.add(const WindowsLiveIncoming('$school-1',1,'school_notices','one'));
   var heads=0,reconciled=0;
   final runtime=WindowsLiveSyncRuntime(school:school,profile:'one',deviceId:'persistent-device-one',
    store:store,currentSchool:()=>school,currentProfile:()=>'one',canRun:()=>true,
    onWork:(){},reconcile:(targets)async{reconciled++;return true;},
    recoverSnapshot:(collections)async{
     expect(collections,{'school_expenses','school_notices'});return variant!='blocked';
    },call:(action,body)async{
     if(action.endsWith('/changes'))throw CentralCloudException(409,'school_cloud','Snapshot required',diagnosticCode:'LIVE_SNAPSHOT_REQUIRED');
     if(action.endsWith('/received'))return {'success':true};
     heads++;return {'success':true,'liveProtocol':1,'schoolId':school,'cursor':5,
      'collections':[{'collection':'school_expenses','state':'active'},
       {'collection':'school_notices','state':variant=='state-changed'&&heads>1?'active':'legacy'}]};
    });
   if(variant=='state-changed'){await expectLater(runtime.run(),throwsStateError);}else{await runtime.run();}
   expect(store.value,variant=='verified'?5:1);
   expect(store.entries.length,variant=='verified'?0:1);expect(reconciled,0);
  }
 });
 test('snapshot checkpoint CAS cannot delete a newer replay page',()async{
  FlutterSecureStorage.setMockInitialValues({});
  await WindowsRuntimeFlags.setLocalStorageEnabled(false);
  final db=FirebaseFirestore.instance;
  await db.switchProfile('runtime-cas-${DateTime.now().microsecondsSinceEpoch}',
    identity:{'schoolId':school,'schoolSyncId':school});
  final store=WindowsLiveRuntimeLocalStore(db,school,db.activeProfileId);
  await store.retainPage(LiveSyncPage.parse(page(0),school,0));
  // Snapshot verification started at cursor1, but another replay has now
  // durably retained cursor2. The old snapshot cannot discard either row.
  await store.retainPage(LiveSyncPage(school,1,2,2,[{
   'sequence':2,'collection':'school_expenses','id':'two',
   'record':{'schoolId':school,'_syncRevision':'live-two','amount':2}}]));
  await expectLater(store.replaceCheckpoint(1,5),throwsStateError);
  expect(await store.cursor(school),2);
  expect((await store.pending()).map((row)=>row.sequence).toList(),[1,2]);
 });
 test('active snapshot preserves retired Drive-owned incoming hints for their own reconciler',()async{
  FlutterSecureStorage.setMockInitialValues({});
  await WindowsRuntimeFlags.setLocalStorageEnabled(false);
  final db=FirebaseFirestore.instance;
  await db.switchProfile('runtime-retired-${DateTime.now().microsecondsSinceEpoch}',
    identity:{'schoolId':school,'schoolSyncId':school});
  final store=WindowsLiveRuntimeLocalStore(db,school,db.activeProfileId);
  await store.retainPage(LiveSyncPage(school,0,1,1,[{
    'sequence':1,'collection':'school_notices','id':'one','retired':true,
    'source':'drive','recordAuthority':'school-drive','record':null}]));
  await store.replaceCheckpoint(1,5,{'school_expenses'});
  expect(await store.cursor(school),5);
  expect((await store.pending()).single.collection,'school_notices');
 });
 test('local runtime compacts only verified incoming payloads and preserves a pending business edit',()async{
  FlutterSecureStorage.setMockInitialValues({});
  await WindowsRuntimeFlags.setLocalStorageEnabled(false);
  final db=FirebaseFirestore.instance;
  await db.switchProfile('runtime-${DateTime.now().microsecondsSinceEpoch}',
    identity:{'schoolId':school,'schoolSyncId':school});
  final store=WindowsLiveRuntimeLocalStore(db,school,db.activeProfileId);
  await db.collection('school_expenses').doc('one').set({'schoolId':school,'amount':99});
  final pending=(await db.collection('_windows_firebase_outbox').get()).docs.single.data();
  await store.retainPage(LiveSyncPage.parse(page(0),school,0));
  final entries=await store.pending();expect(entries.single.id,'one');
  await store.applied(entries);
  expect(await store.cursor(school),1);
  expect((await db.collection('_windows_live_incoming').get()).docs,isEmpty);
  expect((await db.collection('school_expenses').doc('one').get()).data()?['amount'],99);
  expect((await db.collection('_windows_firebase_outbox').get()).docs.single.data()['operationId'],pending['operationId']);
  await expectLater(store.replaceCheckpoint(0,5),throwsStateError);
  expect(await store.cursor(school),1);
  await store.replaceCheckpoint(1,5);expect(await store.cursor(school),5);
  expect((await db.collection('_windows_firebase_outbox').get()).docs.single.data()['operationId'],pending['operationId']);
 });
}
