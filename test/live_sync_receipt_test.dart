import 'package:flutter_test/flutter_test.dart';
import '../lib/live_sync_protocol.dart';

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
}
