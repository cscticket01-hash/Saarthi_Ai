'use strict';
const {createHash}=require('node:crypto');
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d';
// Exact, immutable TEST-only acceptance fixtures. Never infer a school,
// record generation or operation ID from a caller-provided arbitrary string.
const originalFixtures=Object.freeze({
 'TEST_DELETE_42222529247_8ce61a39':Object.freeze({
  operationId:'980a80a2ed52f3a498c4410209225e95',
  originalRevision:'da3ac36d-a064-469b-877f-774f2442d1ae'}),
 'TEST_DELETE_42362168489_3677a100':Object.freeze({
  operationId:'376738e10b5ec7edbae9670383a3b790',
  originalRevision:'1ac77f0b-030c-44c7-abe5-4343cb8b4d13'})
});
const STUDENT=process.env.VS_DIAGNOSE_ORIGINAL_TEST_DELETE||'';
const selected=Object.hasOwn(originalFixtures,STUDENT)?originalFixtures[STUDENT]:null;
const OP=selected?.operationId||'',ORIGINAL=selected?.originalRevision||'';
const API='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const PROJECT='saarthi-ai-df12b';
const sha=x=>createHash('sha256').update(x).digest('hex');
const RECEIPT=sha(JSON.stringify([SCHOOL,'managed_records',['students_directory',STUDENT,OP]]));
const GENERATION='p-'+sha('test-delete/'+STUDENT);
const LOGIN='https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
async function send(url,body,token){
 const r=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(45000)});
 return {status:r.status,data:await r.json()};
}
async function main(){
 if(process.env.GITHUB_ACTIONS!=='true'||process.env.GITHUB_REF!=='refs/heads/feature/smart-sync-3'||!selected)
  throw Error('Exact isolated TEST-only deletion receipt required');
 const h=await fetch(API+'/healthz',{signal:AbortSignal.timeout(20000)}).then(r=>r.json());
 if(h.ready!==true||h.projectId!==PROJECT||!/^[a-f0-9]{40}$/.test(h.runtimeCommit||'')||
  !/^[a-f0-9]{64}$/.test(h.adminCredentialFingerprint||''))
  throw Error('Verified TEST runtime Firebase credential fingerprint required');
 const login=await send(LOGIN,{email:process.env.VS_TEST_LOGIN_EMAIL,password:process.env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});
 if(login.status!==200||!login.data.idToken)throw Error('TEST school owner login failed');
 const response=await send(API,{action:'managed/cloudflare/retry-delete',schoolId:SCHOOL,
  lane:'records',id:RECEIPT,operationId:OP,recordId:STUDENT,
  expectedRecordRevision:ORIGINAL,deletedStudentGeneration:GENERATION,
  credentialFingerprint:h.adminCredentialFingerprint,diagnoseOnly:true},login.data.idToken);
 if(response.status!==200||response.data.success!==true||
   response.data.diagnosticReadOnly!==true||response.data.schoolId!==SCHOOL)
  throw Error('Authenticated read-only receipt diagnosis failed HTTP '+response.status+' '+(response.data.code||'UNVERIFIED'));
 const review=response.data.reviewDiagnosis;
 if(!review||typeof review.state!=='string'||!Number.isInteger(review.retryCount)||
    typeof review.immutable!=='boolean')throw Error('Review diagnosis not verified');
 console.log('ORIGINAL_DELETE_RECEIPT_DIAGNOSIS '+JSON.stringify({
  status:'READ_ONLY_VERIFIED',review,backendRuntimeMatchesProject:true
 }));
 // Inspect ONLY the original school-owned tombstone and bounded cursors.
 // Archive IDs, record contents, credentials and remote request data are never logged.
 const own=await send(API,{action:'managed/records',operation:'read',collection:'students_directory',
  id:STUDENT,schoolId:SCHOOL,syncProtocol:2},login.data.idToken);
 if(own.status!==200||own.data.success!==true||own.data.schoolId!==SCHOOL||
    own.data.pointRead!==true)throw Error('Original TEST tombstone cannot be read securely');
 const row=own.data.records?.[STUDENT],plan=row?._syncErasePlan;
 if(!row||row.schoolId!==SCHOOL||row._syncDeleted!==true||
    row._syncOperationId!==OP||plan?.version!==1||
    !Array.isArray(plan.targets)||!Array.isArray(plan.files))
  throw Error('Original scoped Delete Everywhere plan not proven');
 const bounded=(n,len)=>Number.isInteger(n)&&n>=0&&n<=len?n:null;
 const archiveCount=Array.isArray(plan.archiveIds)?plan.archiveIds.length:null;
 console.log('ORIGINAL_DELETE_PLAN_DIAGNOSIS '+JSON.stringify({
  status:'READ_ONLY_VERIFIED',
  targetCursor:bounded(plan.cursor,plan.targets.length),
  targetTotal:plan.targets.length,
  fileCursor:bounded(plan.fileCursor,plan.files.length),
  fileTotal:plan.files.length,
  archivesComplete:plan.archivesComplete===true,
  archiveCursor:archiveCount===null?null:bounded(plan.archiveCursor,archiveCount),
  archiveTotal:archiveCount,
  scanRemainingFrames:Array.isArray(plan.archiveScan?.stack)?plan.archiveScan.stack.length:null,
  complete:plan.complete===true
 }));
}
main().catch(e=>{console.error('ORIGINAL_DELETE_DIAGNOSIS_FAILED '+String(e.message).slice(0,175));process.exitCode=1});
