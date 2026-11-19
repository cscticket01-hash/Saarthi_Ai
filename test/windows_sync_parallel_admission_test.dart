import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/windows_sync_parallel_admission.dart';

void main() {
 const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
 Map<String,dynamic> notice(String id,String op,int when,{
   String state='pending',String schoolId=school})=> {
     'queueId':id,'collection':'school_notices','schoolId':schoolId,
     'operationId':op,'operation':'set','syncState':state,
     'queuedAtMillis':when,
   };
 test('Student upload does not block an independently pending notification',(){
   final rows=[
     {'queueId':'person-1','collection':'students_directory',
      'schoolId':school,'syncState':'pending','queuedAtMillis':1},
     notice('notice-a','original-notice-operation-00001',2)
   ];
   expect(oldestIndependentNotice(rows,schoolId:school,nowMillis:100),
     {'queueId':'notice-a','operationId':'original-notice-operation-00001'});
 });
 test('same-notice FIFO and school isolation are never bypassed',(){
   final rows=[
     notice('notice-new','original-notice-operation-00002',20),
     notice('notice-old','original-notice-operation-00001',10,state:'needsAttention')
   ];
   expect(oldestIndependentNotice(rows,schoolId:school,nowMillis:100),isNull);
   expect(oldestIndependentNotice([
     notice('foreign','original-notice-operation-00003',1,schoolId:'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
     notice('local','original-notice-operation-00004',2)
   ],schoolId:school,nowMillis:100)?['queueId'],'local');
 });
 test('quota retry and pending dependencies are not accelerated',(){
   final waiting=notice('wait','original-notice-operation-00005',2)
     ..['retryAtMillis']=1000;
   expect(oldestIndependentNotice([waiting],schoolId:school,nowMillis:100),isNull);
   final dependent=notice('dependent','original-notice-operation-00006',2)
     ..['priorDeletion']={'operation':'delete'};
   expect(oldestIndependentNotice([dependent],schoolId:school,nowMillis:100),isNull);
 });
 test('bounded fast-lane admits an independent expense during slow Drive work', () {
   final rows = [
     {'queueId':'person','collection':'students_directory',
      'documentId':'person-1','schoolId':school,'syncState':'pending',
      'operationId':'person-operation-0000000001','operation':'set',
      'queuedAtMillis':1},
     {'queueId':'expense','collection':'school_expenses',
      'documentId':'expense-a','schoolId':school,'syncState':'pending',
      'operationId':'expense-operation-0000001','operation':'set',
      'queuedAtMillis':2},
   ];
   expect(oldestIndependentRecord(rows, schoolId: school, nowMillis: 100),
     {'queueId':'expense','operationId':'expense-operation-0000001'});
 });
 test('independent lane never overtakes same-record retry, quota or delete', () {
   Map<String,dynamic> expense(String queue, String op, int time,
       {String state='pending',String operation='set'}) => {
     'queueId':queue,'collection':'school_expenses',
     'documentId':'expense-a','schoolId':school,
     'operationId':op,'operation':operation,
     'syncState':state,'queuedAtMillis':time,
   };
   final blocked = [
     expense('original','expense-operation-0000001',1,state:'needsAttention'),
     expense('newer','expense-operation-0000002',2),
   ];
   expect(oldestIndependentRecord(blocked,schoolId:school,nowMillis:100),isNull);
   final waiting = expense('quota','expense-operation-0000003',1)
     ..['retryAtMillis']=1000;
   expect(oldestIndependentRecord([waiting],schoolId:school,nowMillis:100),isNull);
   expect(oldestIndependentRecord([
     expense('deleted','expense-operation-0000004',1,operation:'delete')
   ],schoolId:school,nowMillis:100),isNull);
   expect(oldestIndependentRecord([
     {...expense('other','expense-operation-0000005',1), 'schoolId':
       'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}
   ],schoolId:school,nowMillis:100),isNull);
 });

 test('person and notice calls start together and remain joined until both settle',() async {
   final person=Completer<void>(),notice=Completer<void>();
   final calls=<String>[];
   final run=runIndependentCloudAdmissions(
     () {calls.add('person');return person.future;},
     () {calls.add('notice');return notice.future;});
   expect(calls,['person','notice']);
   var finished=false;
   run.then((_)=>finished=true);
   notice.complete();
   await Future<void>.delayed(Duration.zero);
   expect(finished,isFalse,reason:'slow person must not be abandoned in background');
   person.complete();
   await run;
   expect(finished,isTrue);
 });
 test('Cloudflare-accepted notice does not keep device upload queue busy',(){
   expect(oldestIndependentNotice([
     notice('already','original-notice-operation-00007',1,state:'cloudAccepted'),
     notice('next','original-notice-operation-00008',2)
   ],schoolId:school,nowMillis:100)?['queueId'],'next');
 });
}
