import 'package:flutter_test/flutter_test.dart';
import '../lib/live_sync_protocol.dart';
import '../lib/windows_firebase_sync.dart';

void main() {
 const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
 const collection='school_expenses', id='expense-one', op='original-operation-0001';
 Map<String,dynamic> receipt()=>{
  'success':true,'schoolId':school,'syncProtocol':2,'liveProtocol':1,
  'cloudState':'committed','backupState':'pending','operationId':op,
  'recordRevision':'live-original','record':{'schoolId':school,
   '_syncRevision':'live-original','_syncOperationId':op,'amount':10},
 };
 bool verify(Map<String,dynamic> r)=>verifyLiveRecordReceipt(r,
   school:school,collection:collection,id:id,operationId:op);
 test('live commitment is distinct from legacy Drive acknowledgement',(){
  expect(verify(receipt()),isTrue);
  expect(verify({'schoolId':school,'syncProtocol':2,'recordRevision':'gs-original'}),isFalse);
  expect(isDriveRecoveryRevision('live-original'),isFalse);
  expect(isDriveRecoveryRevision('cf-original'),isFalse);
  expect(isDriveRecoveryRevision('gs-original'),isTrue);
 });
 test('incomplete, foreign and mismatched live receipts retain the outbox',(){
  for(final key in ['success','liveProtocol','cloudState','backupState','operationId','record']) {
   final value=receipt()..remove(key);expect(()=>verify(value),throwsStateError,reason:key);
  }
  for(final mutate in <void Function(Map<String,dynamic>)>[
   (r)=>r['schoolId']='other-school',
   (r)=>r['record']['schoolId']='other-school',
   (r)=>r['record']['id']='another-id',
   (r)=>r['record']['_syncRevision']='live-newer',
   (r)=>r['record']['_syncOperationId']='different-operation',
   (r)=>r['record']['_syncDeleted']=true,
   (r)=>r['recordRevision']='gs-unverified',
  ]) {final value=receipt();mutate(value);expect(()=>verify(value),throwsStateError);}
 });
 test('seeded no-op and duplicate keep original metadata only with explicit proof',(){
  final value=receipt()..addAll({'unchanged':true,'backupState':'verified',
   'source':'drive','driveRevision':'gs-seeded','recordRevision':'gs-seeded'});
  value['record']['_syncRevision']='gs-seeded';
  value['record']['_syncOperationId']='first-operation';
  expect(verify(value),isTrue);
  value.remove('source');expect(()=>verify(value),throwsStateError);
  final duplicate=receipt()..addAll({'duplicate':true,'resolution':'cloudRetained'});
  duplicate['record']['_syncOperationId']='first-operation';expect(verify(duplicate),isTrue);
  duplicate.remove('resolution');expect(()=>verify(duplicate),throwsStateError);
 });
 test('deletion requires the exact canonical tombstone',(){
  final value=receipt();
  expect(()=>verifyLiveRecordReceipt(value,school:school,collection:collection,
    id:id,operationId:op,deleting:true),throwsStateError);
  value['record']['_syncDeleted']=true;
  expect(verifyLiveRecordReceipt(value,school:school,collection:collection,
    id:id,operationId:op,deleting:true),isTrue);
 });
 test('live negotiation preserves stable IDs and does not affect file delivery',(){
  final body={'action':'managed/records','operationId':op,'expectedRecordRevision':'gs-base'};
  expect(negotiateLiveSync(body),{...body,'liveProtocol':1});
  expect(body.containsKey('liveProtocol'),isFalse);
  final file={'action':'managed/file/upload','uploadKey':'original-file-key'};
  expect(negotiateLiveSync(file),file);
 });

 test('legacy Cloudflare notice tombstone is a verified device ACK, not Drive success',() {
   const notice='NOTICE-1793730809802932-87474139';
   final receipt=<String,dynamic>{
     'success':true,'schoolId':school,'syncProtocol':2,
     'cloudflareAccepted':true,'driveState':'pending',
     'recordRevision':'cf-committed-1','collectionRevision':'cf-head-2',
     'record':{'id':notice,'schoolId':school,'_syncDeleted':true,
       '_syncRevision':'cf-committed-1','_syncOperationId':op}
   };
   expect(verifyLegacyCloudflareNoticeReceipt(receipt,school:school,
     collection:'school_notices',id:notice,operationId:op,deleting:true),isTrue);
   expect(receipt['driveState'],'pending');
   expect(receipt.containsKey('driveDeletionComplete'),isFalse);
   expect(verifyLegacyCloudflareNoticeReceipt(receipt,school:school,
     collection:'students_directory',id:notice,operationId:op,deleting:true),isFalse);
   expect(verifyLiveRecordReceipt(receipt,school:school,
     collection:'school_notices',id:notice,operationId:op,deleting:true),isFalse);
 });
 test('legacy Cloudflare notice write needs its exact immutable canonical record',() {
   final receipt=<String,dynamic>{
     'success':true,'schoolId':school,'syncProtocol':2,
     'cloudflareAccepted':true,'driveState':'pending',
     'recordRevision':'cf-commit','collectionRevision':'cf-head',
     'record':{'id':'notice-id','schoolId':school,'_syncRevision':'cf-commit',
       '_syncOperationId':op,'message':'Hello'}};
   bool check(Map<String,dynamic> value)=>verifyLegacyCloudflareNoticeReceipt(
     value,school:school,collection:'school_notices',id:'notice-id',operationId:op);
   expect(check(receipt),isTrue);
   for(final key in ['schoolId','cloudflareAccepted','driveState','record',
      'recordRevision','collectionRevision']) {
     final broken=Map<String,dynamic>.from(receipt)..remove(key);
     if(key=='cloudflareAccepted'||key=='recordRevision')
       expect(check(broken),isFalse,reason:key);
     else expect(()=>check(broken),throwsStateError,reason:key);
   }
   for(final mutation in <void Function(Map<String,dynamic>)>[
     (r)=>r['record']=Map<String,dynamic>.from(r['record'])..['_syncOperationId']='foreign-op',
     (r)=>r['record']=Map<String,dynamic>.from(r['record'])..['schoolId']='foreign-school',
     (r)=>r['record']=Map<String,dynamic>.from(r['record'])..['_syncRevision']='newer-revision',
     (r)=>r['record']=Map<String,dynamic>.from(r['record'])..['_syncDeleted']=true,
     (r)=>r['driveState']='verified',
     (r)=>r['recordRevision']='live-wrong',
   ]) {
     final invalid=Map<String,dynamic>.from(receipt);mutation(invalid);
     if(invalid['recordRevision']=='live-wrong')
       expect(check(invalid),isFalse);
     else expect(()=>check(invalid),throwsStateError);
   }
 });
 test('Windows returns committed notice-delete CF revision without pretending Drive finished',() async {
   const id='notice-retry', operation='delete';
   const item={'schoolId':school,'collection':'school_notices','documentId':id,
     'operation':operation,'operationId':op,'baseCloudRevision':'old-gs-revision'};
   final ack=<String,dynamic>{'success':true,'schoolId':school,'syncProtocol':2,
     'cloudflareAccepted':true,'driveState':'pending',
     'recordRevision':'cf-tombstone','collectionRevision':'cf-new-head',
     'record':{'schoolId':school,'id':id,'_syncRevision':'cf-tombstone',
       '_syncOperationId':op,'_syncDeleted':true}};
   final reply=await WindowsFirebaseRemote.syncManagedRecord(item,school,batchReply:ack);
   expect(reply['recordRevision'],'cf-tombstone');
   expect(reply['driveState'],'pending');
   expect(reply.containsKey('firebaseDeletionComplete'),isFalse);
   expect(item['baseCloudRevision'],'old-gs-revision');
   final missingTombstone=Map<String,dynamic>.from(ack)
     ..['record']={'schoolId':school,'id':id,'_syncRevision':'cf-tombstone','_syncOperationId':op};
   await expectLater(WindowsFirebaseRemote.syncManagedRecord(item,school,
      batchReply:missingTombstone),throwsStateError);
   final nonNotice={...item,'collection':'students_directory'};
   await expectLater(WindowsFirebaseRemote.syncManagedRecord(nonNotice,school,
      batchReply:ack),throwsStateError);
 });
}
