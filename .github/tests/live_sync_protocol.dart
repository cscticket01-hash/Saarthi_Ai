import '../../lib/live_sync_protocol.dart';
void check(bool value) {if(!value)throw StateError('Live protocol regression');}
Map<String,dynamic> page(String school)=>{
 'success':true,'liveProtocol':1,'schoolId':school,'cursor':1,'head':1,'more':false,
 'events':[{'sequence':1,'collection':'school_expenses','id':'one',
   'record':{'schoolId':school,'amount':10,'_syncRevision':'live-original'}}],
};
class Store implements LiveSyncStore {
 int value=0;bool fail=false;
 @override Future<int> cursor(String school)async=>value;
 @override Future<void> retainPage(LiveSyncPage page)async{
  if(fail)throw StateError('disk unavailable');
  check(value==page.after);value=page.cursor;
 }
}
Future<void> main()async{
 const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
 check(negotiateLiveSync({'action':'managed/records','operationId':'same'})['liveProtocol']==1);
 check(!isDriveRecoveryRevision('live-pending')&&!isDriveRecoveryRevision('cf-pending'));
 check(isDriveRecoveryRevision('gs-verified'));
 final ack=<String,dynamic>{'success':true,'schoolId':school,'syncProtocol':2,'liveProtocol':1,
  'cloudState':'committed','backupState':'pending','operationId':'operation-original',
  'recordRevision':'live-original','record':{'schoolId':school,'_syncRevision':'live-original','_syncOperationId':'operation-original'}};
 check(verifyLiveRecordReceipt(ack,school:school,collection:'school_expenses',id:'one',operationId:'operation-original'));
 var badAck=false;try{verifyLiveRecordReceipt({...ack,'record':null},school:school,collection:'school_expenses',id:'one',operationId:'operation-original');}catch(_){badAck=true;}
 check(badAck);
 check(LiveSyncPage.parse(page(school),school,0).events.length==1);
 final retired=page(school);
 retired['events']=[{'sequence':1,'collection':'school_expenses','id':'one',
  'retired':true,'source':'drive','recordAuthority':'school-drive','record':null}];
 check(LiveSyncPage.parse(retired,school,0).events.single['retired']==true);
 for(final field in ['retired','source','recordAuthority','record']) {
  final invalid={...retired,'events':[{...retired['events'][0]}..remove(field)]};
  var rejected=false;try{LiveSyncPage.parse(invalid,school,0);}catch(_){rejected=true;}
  check(rejected);
 }
 final invented={...retired,'events':[{...retired['events'][0],
  'record':{'schoolId':school,'_syncRevision':'live-fabricated'}}]};
 var inventedRejected=false;try{LiveSyncPage.parse(invented,school,0);}catch(_){inventedRejected=true;}
 check(inventedRejected);

 for(final variant in ['foreign','gap','future','false-more','bad-revision']){
  final data=page(school);
  if(variant=='foreign')data['schoolId']='other';
  if(variant=='gap')data['events'][0]['sequence']=2;
  if(variant=='future')data['cursor']=2;
  if(variant=='false-more')data['more']=true;
  if(variant=='bad-revision')data['events'][0]['record']['_syncRevision']='drive-only';
  var rejected=false;try{LiveSyncPage.parse(data,school,0);}catch(_){rejected=true;}
  check(rejected);
 }
 final store=Store();var active=school,received=0;
 final replay=LiveSyncReplay(schoolId:school,deviceId:'persistent-test-device-0001',store:store,
  currentSchool:()=>active,call:(action,body)async{
   if(action.endsWith('/received')){check(store.value==1);received++;return {'success':true};}
   return page(school);
  });
 store.fail=true;try{await replay.pull();}catch(_){}
 check(store.value==0&&received==0);
 store.fail=false;await replay.pull();check(store.value==1&&received==1);
 active='another-school';var rejected=false;try{await replay.pull();}catch(_){rejected=true;}
 check(rejected&&store.value==1);
}
