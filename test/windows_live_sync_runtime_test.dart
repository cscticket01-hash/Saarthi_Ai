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

 test('durable inbox applies only whole bundles across the 100-record batching boundary',()async{
  FlutterSecureStorage.setMockInitialValues({});
  await WindowsRuntimeFlags.setLocalStorageEnabled(false);
  final db=FirebaseFirestore.instance;
  await db.switchProfile('runtime-atomic-'+DateTime.now().microsecondsSinceEpoch.toString(),
    identity:{'schoolId':school,'schoolSyncId':school});
  final store=WindowsLiveRuntimeLocalStore(db,school,db.activeProfileId);
  final ordinary=<Map<String,dynamic>>[
    for(var i=1;i<=99;i++)
      {'sequence':i,'collection':'school_expenses','id':'expense-$i',
       'record':{'schoolId':school,'_syncRevision':'live-$i'}}
  ];
  await store.retainPage(LiveSyncPage.parse({
    'success':true,'liveProtocol':1,'schoolId':school,
    'cursor':99,'head':101,'more':true,'events':ordinary,
  },school,0));
  final bundle=<Map<String,dynamic>>[
    {'sequence':100,'collection':'students_directory','id':'person-one',
     'bundleId':'atomic-person-card-0000001','bundleSize':2,'bundleIndex':0,
     'record':{'schoolId':school,'_syncRevision':'live-100'}},
    {'sequence':101,'collection':'documents','id':'id-card-one',
     'bundleId':'atomic-person-card-0000001','bundleSize':2,'bundleIndex':1,
     'record':{'schoolId':school,'_syncRevision':'live-101'}},
  ];
  await store.retainPage(LiveSyncPage.parse({
    'success':true,'liveProtocol':1,'schoolId':school,
    'cursor':101,'head':101,'more':false,'events':bundle,
  },school,99));
  final first=await store.pending();
  expect(first.length,99,reason:'a 2-record bundle cannot be split by the 100 cap');
  expect(first.every((entry)=>entry.bundleId==null),isTrue);
  await store.applied(first);
  final second=await store.pending();
  expect(second.map((e)=>e.collection).toList(),['students_directory','documents']);
  expect(second.map((e)=>e.bundleIndex).toList(),[0,1]);
  await db.collection('_windows_live_incoming').doc('$school-101').delete();
  await expectLater(store.pending(),throwsStateError,
    reason:'a lost card event must retain the parent for recovery');
 });


 test('Windows applies verified Person + ID Card together without producing uploads',()async{
  FlutterSecureStorage.setMockInitialValues({});
  await WindowsRuntimeFlags.setLocalStorageEnabled(false);
  final db=FirebaseFirestore.instance;
  await db.switchProfile('atomic-success-'+DateTime.now().microsecondsSinceEpoch.toString(),
    identity:{'schoolId':school,'schoolSyncId':school});
  final store=WindowsLiveRuntimeLocalStore(db,school,db.activeProfileId);
  const bundle='atomic-receiver-bundle-0001';
  final parent=<String,dynamic>{'schoolId':school,'name':'Verified Student',
    'mobileStableId':'p-verified-student-one','_syncRevision':'live-parent-one'};
  final card=<String,dynamic>{'schoolId':school,'studentId':'person-1',
    'personId':'p-verified-student-one','ownerRole':'student',
    'bundleManifestHash':'a'*64,'_syncRevision':'live-card-one'};
  final events=<Map<String,dynamic>>[
   {'sequence':1,'collection':'students_directory','id':'person-1','record':parent,
    'bundleId':bundle,'bundleSize':2,'bundleIndex':0},
   {'sequence':2,'collection':'documents','id':'card-1','record':card,
    'bundleId':bundle,'bundleSize':2,'bundleIndex':1},
  ];
  await store.retainPage(LiveSyncPage.parse({
    'success':true,'liveProtocol':1,'schoolId':school,
    'cursor':2,'head':2,'more':false,'events':events,
  },school,0));
  final entries=await store.pending();expect(entries.length,2);
  var reads=0;
  final bothStarted=Completer<void>();
  final done=await store.reconcileBundle(entries,(action,body)async{
    expect(action,'managed/live/read');
    reads++;
    if(reads==2)bothStarted.complete();
    // A sequential implementation cannot pass this barrier. No wall-clock
    // benchmark or fake live-latency claim is inferred from this test.
    await bothStarted.future.timeout(const Duration(seconds: 2));
    expect((await db.collection('students_directory').doc('person-1').get()).data(),isNull);
    expect((await db.collection('documents').doc('card-1').get()).data(),isNull);
    final record=body['collection']=='students_directory'?parent:card;
    return {'success':true,'liveProtocol':1,'schoolId':school,
      'recordRevision':record['_syncRevision'],'record':record};
  });
  expect(done,isTrue);expect(reads,2);
  expect((await db.collection('students_directory').doc('person-1').get()).data()?['name'],'Verified Student');
  expect((await db.collection('documents').doc('card-1').get()).data()?['studentId'],'person-1');
  expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
  await store.applied(entries);
  expect((await store.pending()).isEmpty,isTrue);
 });
 test('concurrent bundle reads retain all work if one response fails or belongs to another school',()async{
  for(final failTransport in [true,false]) {
   FlutterSecureStorage.setMockInitialValues({});
   await WindowsRuntimeFlags.setLocalStorageEnabled(false);
   final db=FirebaseFirestore.instance;
   await db.switchProfile('parallel-failure-$failTransport-${DateTime.now().microsecondsSinceEpoch}',
     identity:{'schoolId':school,'schoolSyncId':school});
   final store=WindowsLiveRuntimeLocalStore(db,school,db.activeProfileId);
   const bundle='atomic-concurrent-failure-0001';
   final events=<Map<String,dynamic>>[
    for(var i=0;i<2;i++) {'sequence':i+1,'collection':i==0?'students_directory':'documents',
     'id':i==0?'person':'card','record':{'schoolId':school,'_syncRevision':'live-${i+1}'},
     'bundleId':bundle,'bundleSize':2,'bundleIndex':i},
   ];
   await store.retainPage(LiveSyncPage.parse({'success':true,'liveProtocol':1,'schoolId':school,
     'cursor':2,'head':2,'more':false,'events':events},school,0));
   var calls=0;final started=Completer<void>();
   final result=store.reconcileBundle(await store.pending(),(action,body)async{
    if(++calls==2)started.complete();
    await started.future.timeout(const Duration(seconds:2));
    final index=body['id']=='person'?0:1;
    if(index==1&&failTransport)throw StateError('Transport interrupted');
    return {'success':true,'liveProtocol':1,'schoolId':index==1?'vs-${'b'*32}':school,
      'recordRevision':'live-${index+1}','record':events[index]['record']};
   });
   if(failTransport){await expectLater(result,throwsStateError);}else{expect(await result,false);}
   expect(calls,2);
   expect((await db.collection('students_directory').doc('person').get()).data(),isNull);
   expect((await db.collection('documents').doc('card').get()).data(),isNull);
   expect((await store.pending()).length,2);
  }
 });
 test('pending local card edit blocks the entire incoming Person/Card transaction',()async{
  FlutterSecureStorage.setMockInitialValues({});
  await WindowsRuntimeFlags.setLocalStorageEnabled(false);
  final db=FirebaseFirestore.instance;
  await db.switchProfile('atomic-blocked-'+DateTime.now().microsecondsSinceEpoch.toString(),
    identity:{'schoolId':school,'schoolSyncId':school});
  await db.collection('documents').doc('card-blocked').set({
    'schoolId':school,'name':'Unsynced card local edit'});
  final old=(await db.collection('_windows_firebase_outbox').get()).docs.single.data();
  final store=WindowsLiveRuntimeLocalStore(db,school,db.activeProfileId);
  const bundle='atomic-blocked-bundle-0001';
  final person={'schoolId':school,'name':'Server student',
    '_syncRevision':'live-server-parent'};
  final card={'schoolId':school,'name':'Server card',
    '_syncRevision':'live-server-card'};
  await store.retainPage(LiveSyncPage.parse({
    'success':true,'liveProtocol':1,'schoolId':school,'cursor':2,'head':2,
    'more':false,'events':[
      {'sequence':1,'collection':'students_directory','id':'person-blocked',
       'bundleId':bundle,'bundleSize':2,'bundleIndex':0,'record':person},
      {'sequence':2,'collection':'documents','id':'card-blocked',
       'bundleId':bundle,'bundleSize':2,'bundleIndex':1,'record':card},
    ],
  },school,0));
  final entries=await store.pending();
  final applied=await store.reconcileBundle(entries,(action,body)async {
    final value=body['collection']=='students_directory'?person:card;
    return {'success':true,'liveProtocol':1,'schoolId':school,
      'recordRevision':value['_syncRevision'],'record':value};
  });
  expect(applied,isFalse);
  expect((await db.collection('students_directory').doc('person-blocked').get()).data(),isNull);
  expect((await db.collection('documents').doc('card-blocked').get()).data()?['name'],
    'Unsynced card local edit');
  expect((await db.collection('_windows_firebase_outbox').get()).docs.single.data()['operationId'],
    old['operationId']);
  expect((await store.pending()).length,2);
 });

 test('Windows refuses incomplete original Person+Photo+ID proof before local CAS',()async{
  FlutterSecureStorage.setMockInitialValues({});
  await WindowsRuntimeFlags.setLocalStorageEnabled(false);
  final db=FirebaseFirestore.instance;
  await db.switchProfile('atomic-photo-'+DateTime.now().microsecondsSinceEpoch.toString(),
    identity:{'schoolId':school,'schoolSyncId':school});
  const bundle='atomic-original-photo-bundle-0001';
  const generation='p-99999999999999999999999999999999';
  final photoId='a'*64,photoHash='b'*64;
  final person={'schoolId':school,'mobileStableId':generation,
   'name':'Atomic Student','_syncRevision':'live-photo-parent',
   'atomicPortrait':{'bundleId':bundle,'documentId':'original-card',
     'role':'student','id':photoId,'sha256':photoHash,
     'mime':'image/jpeg','sizeBytes':1024}};
  final doc={'schoolId':school,'studentId':'original-person',
    'personId':generation,'ownerRole':'student','documentKind':'idCard',
    'bundleId':bundle,'bundleManifestHash':'c'*64,
    '_syncRevision':'live-photo-card',
    'bundleMedia':[
      {'kind':'idCard','sha256':'d'*64},
      {'kind':'photo','id':photoId,'sha256':photoHash,
       'mime':'image/jpeg','sizeBytes':1024},
    ]};
  final good=<Map<String,dynamic>>[
    {'bundleId':bundle,'bundleSize':2,'bundleIndex':0,
     'collection':'students_directory','id':'original-person','record':person},
    {'bundleId':bundle,'bundleSize':2,'bundleIndex':1,
     'collection':'documents','id':'original-card','record':doc},
  ];
  await db.applyVerifiedLiveBundle(school,good);
  expect((await db.collection('students_directory')
    .doc('original-person').get()).data()?['atomicPortrait'],
    person['atomicPortrait']);
  final wrong=[
    {...good[0],'id':'different-person'},
    {...good[1],'record':{
      ...doc,'bundleMedia':[
        {'kind':'idCard','sha256':'d'*64},
        {'kind':'photo','id':photoId,'sha256':'f'*64,
         'mime':'image/jpeg','sizeBytes':1024},
      ],
    }},
  ];
  // The guarded local transaction may reject an invalid bundle synchronously
  // before it returns a Future. Capture both sync and async rejections.
  await expectLater(Future<void>.sync(() => db.applyVerifiedLiveBundle(school,wrong)),
    throwsStateError);
  expect((await db.collection('students_directory')
    .doc('different-person').get()).data(),isNull,
    reason:'Bad photo cannot partially create a Person');
 });

}
