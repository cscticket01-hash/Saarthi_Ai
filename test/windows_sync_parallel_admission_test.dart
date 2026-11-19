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
     notice('foreign','original-notice-operation-00003',1,schoolId:'vs-'+'b'*32),
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
 test('Cloudflare-accepted notice does not keep device upload queue busy',(){
   expect(oldestIndependentNotice([
     notice('already','original-notice-operation-00007',1,state:'cloudAccepted'),
     notice('next','original-notice-operation-00008',2)
   ],schoolId:school,nowMillis:100)?['queueId'],'next');
 });
}
