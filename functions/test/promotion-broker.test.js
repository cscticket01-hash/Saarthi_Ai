'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {createLiveSync}=require('../live-sync');
const school='vs-'+'a'.repeat(32),id='student-one';
const personId='p-'+'1'.repeat(64);
const old={schoolId:school,mobileStableId:personId,class:'Class 10',studentClass:'Class 10',
 section:'A',rollNo:'4'};
const next={...old,class:'Class 11',studentClass:'Class 11',
 previousClass:'Class 10',promotionExamId:'final-10',
 promotionTransactionId:'promotion:final-10:student-one',
 classMovement:'PROMOTED',lastExamResult:'PASS',
 promotionPending:true,promotionSyncState:'Pending'};
const exam={schoolId:school,examId:'final-10',isFinal:true,
 studentClass:'Class 10',academicSession:'2026-2027',
 subjects:['English','Math'],fullMarks:100,passMarks:33};
const marks={schoolId:school,examId:'final-10',studentId:id,personId,
 studentClass:'Class 10',academicSession:'2026-2027',
 result:'PASS',marks:{English:81,Math:70}};
function harness(overrides={}){
 const records={
  ['students_directory/'+id]:{record:old,recordRevision:'live-student-rev'},
  ['exams/final-10']:{record:exam,recordRevision:'live-exam-rev'},
  ['exam_center_results/final-10_'+id]:{record:marks,recordRevision:'live-result-rev'},
 };
 Object.assign(records,overrides);
 const messages=[];
 const edge={enabled:()=>true,rpc:async(_school,_lane,request)=>{
  messages.push(request);
  if(request.command==='read'){
   const found=records[request.collection+'/'+request.id];
   return found?{...found,source:'cloudflare',schoolId:school,liveProtocol:1}:
    {source:'missing',schoolId:school,liveProtocol:1};
  }
  if(request.command==='commit')return {cloudState:'committed'};
  throw Error('Unexpected command '+request.command);
 }};
 return {live:createLiveSync({edge,schools:[school]}),messages};
}
const request={collection:'students_directory',id,operation:'write',
 operationId:'sample-promotion-operation-2026',expectedRevision:'live-student-rev',data:next};
test('broker produces authoritative matching revision proof; ignores client forged proof',async()=>{
 const {live,messages}=harness();
 const reply=await live.commit(school,{...request,promotionProof:{examRevision:'forged'}},
  async()=>{throw Error('Unexpected Drive lookup');});
 assert.equal(reply.cloudState,'committed');
 const written=messages.find(m=>m.command==='commit');
 assert.deepEqual(written.promotionProof,{
  examId:'final-10',examRevision:'live-exam-rev',
  resultId:'final-10_student-one',resultRevision:'live-result-rev',
 });
 assert.equal(written.promotionProof.examRevision==='forged',false);
 assert.equal(messages.filter(m=>m.command==='read').length,3);
});
test('missing or changed exam marks never reach cloud commit',async()=>{
 for(const caseData of [
  {['exams/final-10']:{record:{...exam,isFinal:false},recordRevision:'live-exam-rev'}},
  {['exam_center_results/final-10_'+id]:{record:{...marks,marks:{English:15,Math:70}},recordRevision:'live-result-rev'}},
  {['exam_center_results/final-10_'+id]:null},
 ]){
  const {live,messages}=harness(caseData);
  await assert.rejects(live.commit(school,request,async()=>{}));
  assert.equal(messages.filter(m=>m.command==='commit').length,0);
 }
});
