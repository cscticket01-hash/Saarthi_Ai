'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict');
const {fixture:f,validateRetainedPerson}=require('./retained_delete_fixture.cjs');
const {retryExactDelete,verifiedNativeReceipt}=require('./native_person_receipt.cjs');
const API='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const report={scope:'Exact retained synthetic TEST deletion; no replacement fixtures or physical devices',status:'PENDING',originalOperationRetained:true,checks:[]};
async function post(url,body,token){
 const r=await fetch(url,{method:'POST',headers:{'content-type':'application/json',...(token?{authorization:'Bearer '+token}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(120000)});
 return {status:r.status,data:await r.json()};
}
async function main(){
 assert.equal(process.env.GITHUB_ACTIONS,'true');assert.equal(process.env.GITHUB_REPOSITORY,'cscticket01-hash/Saarthi_Ai');
 assert.equal(process.env.GITHUB_REF,'refs/heads/feature/smart-sync-3');
 await require('./test_runtime_identity.cjs').waitForRuntime(process.env.VS_EXPECTED_TEST_RUNTIME);
 const key=fs.readFileSync('lib/platform/platform_config.dart','utf8').match(/const platformApiKey = '([A-Za-z0-9_-]+)'/)[1];
 const login=await post('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key='+key,{email:process.env.VS_TEST_LOGIN_EMAIL,password:process.env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});
 assert.equal(login.status,200);assert.ok(login.data.idToken);
 const call=async body=>{
  const r=await post(API,{...body,schoolId:f.schoolId},login.data.idToken);
  if(r.status!==200||r.data.success!==true||r.data.schoolId!==f.schoolId)
   throw Object.assign(Error('Retained TEST request failed'),{code:r.data.code,http:r.status});return r.data;
 };
 const read=(collection,id)=>call({action:'managed/records',collection,id,operation:'read',syncProtocol:2});
 const before=await read('students_directory',f.student);assert.equal(before.pointRead,true);
 validateRetainedPerson(before.records?.[f.student]);report.checks.push('original retained generation and immutable delete scope verified');
 const body={action:'managed/records',edgeDeliveryVersion:1,operation:'delete',collection:'students_directory',id:f.student,
  syncProtocol:2,operationId:f.operationId,expectedRecordRevision:f.originalRevision,
  deletedStudentGeneration:f.generation,deleteEverywhereVersion:1};
 const observe=require('./delete_plan_progress.cjs').observeDeletePlan(async(collection,id)=>{
  const reply=await read(collection,id);validateRetainedPerson(reply.records?.[id]);return reply;
 },f.schoolId,progress=>{report.progress=progress;console.log('RETAINED_TEST_DELETE_PROGRESS '+JSON.stringify(progress));});
 const ack=await retryExactDelete(body,request=>call(request),{attempts:48,observeProgress:observe});
 assert.equal(verifiedNativeReceipt(ack,body,f.schoolId),true);
 assert.ok(ack.deletedFileIds?.includes(f.fileId));validateRetainedPerson(ack.record);
 report.checks.push('actual signed final Drive and Firebase completion receipt verified');
 for(const [collection,id] of [['students_directory',f.student],['documents',f.documentId],['fee_payments',f.feeId]]){
  const current=await read(collection,id);assert.equal(current.pointRead,true);
  assert.equal(current.records?.[id]?._syncDeleted,true);assert.equal(current.records[id]._syncDeletedOwner,f.generation);
 }
 report.checks.push('original student, document and fee tombstones independently read back');
 const file=await post(API,{action:'managed/file/read',schoolId:f.schoolId,fileId:f.fileId},login.data.idToken);
 assert.ok(file.status!==200||file.data.success!==true||!file.data.base64);
 report.checks.push('original PDF inaccessible after signed permanent deletion');
 report.status='PASS';report.deletedFileId=f.fileId;report.firebaseDeletedRecords=ack.firebaseDeletedRecords;
}
main().catch(error=>{report.status='FAIL';report.failure={category:error.name==='TimeoutError'?'REQUEST_TIMEOUT':error.code==='ERR_ASSERTION'?'PROOF_MISMATCH':'PROVIDER_REJECTED',code:/^[A-Z_]{2,90}$/.test(error.code||'')?error.code:null,http:error.http||null};process.exitCode=1;})
.finally(()=>{fs.mkdirSync('build/cloud-prerequisites',{recursive:true});fs.writeFileSync('build/cloud-prerequisites/retained-delete-resume.json',JSON.stringify(report,null,2));console.log('RETAINED_TEST_DELETE '+JSON.stringify(report));});
