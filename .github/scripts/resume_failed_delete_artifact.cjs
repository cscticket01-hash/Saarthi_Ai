'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict'),{createHash}=require('node:crypto');
const {retryExactDelete,verifiedNativeReceipt}=require('./native_person_receipt.cjs');
const {observeDeletePlan}=require('./delete_plan_progress.cjs');
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d',SHA='731bca40858285e9dc06450f9a6b9a41b6e461cc',RUN='42999713169';
const API='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const hash=x=>createHash('sha256').update(x).digest('hex');
function fixture(r){
 assert.equal(r.schoolId,SCHOOL);assert.equal(r.sourceCommit,SHA);assert.equal(r.verifiedRuntime,SHA);
 assert.equal(r.status,'FAIL');assert.equal(r.realProviderCalls,true);assert.equal(r.syntheticDeleted,false);
 assert.ok(Array.isArray(r.checks)&&r.checks.every(x=>x.status==='PASS'));
 for(const name of ['actual Google Drive original PDF byte SHA-256','Website API delta sees student and document before delete','actual Android mobile protocol can authenticate synthetic student','Android mobile protocol gets original TEST PDF before delete'])
  assert.ok(r.checks.some(x=>x.name===name));
 const f=r.reviewRequired,ids=r.fixtureIds;assert.ok(f&&ids);
 const match=/^TEST_DELETE_42999713169_([a-f0-9]{8})$/.exec(f.student||'');assert.ok(match);
 assert.equal(f.documentId,'TEST_DELETE_CARD_'+RUN+'_'+match[1]);
 assert.equal(f.feeId,'TEST_DELETE_FEE_'+RUN+'_'+match[1]);
 for(const key of ['student','documentId','feeId','fileId'])assert.equal(f[key],ids[key]);
 assert.match(f.fileId||'',/^[A-Za-z0-9_-]{1,200}$/);assert.match(f.deleteOperationId||'',/^[a-f0-9]{32}$/);
 assert.match(f.originalParentRevision||'',/^[A-Za-z0-9_-]{16,100}$/);
 return Object.freeze({schoolId:SCHOOL,student:f.student,documentId:f.documentId,feeId:f.feeId,fileId:f.fileId,
  operationId:f.deleteOperationId,originalRevision:f.originalParentRevision,generation:'p-'+hash('test-delete/'+f.student)});
}
function validatePerson(row,f){
 assert.equal(row?.schoolId,SCHOOL);
 if(row._syncDeleted!==true){assert.equal(row.syntheticTest,true);assert.equal(row.mobileStableId,f.generation);assert.equal(row._syncRevision,f.originalRevision);return;}
 assert.equal(row._syncOperationId,f.operationId);assert.equal(row._syncDeletedOwner,f.generation);
 const p=row._syncErasePlan;assert.equal(p?.version,1);assert.ok(Array.isArray(p.targets)&&Array.isArray(p.files));
 const root=p.targets.find(t=>t.collection==='students_directory'&&t.id===f.student);
 assert.equal(root?.generation,f.generation);assert.equal(root.sourceRevision,f.originalRevision);assert.equal(root.revision,row._syncRevision);
 assert.ok(p.targets.some(t=>t.collection==='documents'&&t.id===f.documentId));
 assert.ok(p.targets.some(t=>t.collection==='fee_payments'&&t.id===f.feeId));
 assert.ok(p.targets.filter(t=>t.collection==='students_directory').every(t=>t.id===f.student));
 assert.ok(p.targets.filter(t=>t.collection==='documents').every(t=>t.id===f.documentId));
 assert.ok(p.targets.filter(t=>t.collection==='fee_payments').every(t=>t.id===f.feeId));
 assert.deepEqual(p.files,[f.fileId]);
}
const result={status:'FAIL',originalOperationRetained:true,deletionReceiptVerified:false,
 originalRecordsVerified:false,pdfInaccessible:false,websiteReadback:false,deletedPersonLoginRejected:false};
async function post(url,body,token){
 const r=await fetch(url,{method:'POST',redirect:'error',headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(120000)});
 return {http:r.status,data:await r.json()};
}
async function main(){
 assert.equal(process.env.GITHUB_ACTIONS,'true');assert.equal(process.env.GITHUB_REPOSITORY,'cscticket01-hash/Saarthi_Ai');
 assert.equal(process.env.GITHUB_REF,'refs/heads/test/resume-failed-delete-20261111');
 assert.equal(process.env.VS_TEST_CONNECT_CONFIRM,SCHOOL);
 const base='https://api.github.com/repos/cscticket01-hash/Saarthi_Ai';
 async function get(path){const r=await fetch(base+path,{headers:{Accept:'application/vnd.github+json',Authorization:'Bearer '+process.env.GITHUB_TOKEN},signal:AbortSignal.timeout(30000)});assert.equal(r.status,200);return r.json();}
 const run=await get('/actions/runs/'+RUN);
 assert.equal(run.head_sha,SHA);assert.equal(run.head_branch,'feature/smart-sync-3');assert.equal(run.event,'push');assert.equal(run.conclusion,'failure');assert.equal(run.head_repository.full_name,process.env.GITHUB_REPOSITORY);
 const artifact=await get('/actions/artifacts/13849243695');assert.equal(artifact.workflow_run.id,Number(RUN));assert.equal(artifact.name,'real-test-delete-everywhere-evidence');assert.equal(artifact.expired,false);
 const f=fixture(JSON.parse(fs.readFileSync('evidence/delete-everywhere-live.json','utf8')));
 await require('./test_runtime_identity.cjs').waitForRuntime(SHA);
 const key=fs.readFileSync('lib/platform/platform_config.dart','utf8').match(/const platformApiKey = '([A-Za-z0-9_-]+)'/)[1];
 const login=await post('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key='+key,{email:process.env.VS_TEST_LOGIN_EMAIL,password:process.env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});
 assert.equal(login.http,200);assert.ok(login.data.idToken);
 const token=login.data.idToken,privateReadTrace={};
 const call=(body,retryOptions)=>require('./safe_test_read_retry.cjs').schoolCall({post,url:API,schoolId:SCHOOL,token,report:privateReadTrace,retryOptions},body);
 const read=(collection,id)=>call({action:'managed/records',collection,id,operation:'read',syncProtocol:2},{attempts:6});
 const session=await call({action:'managed/session'});assert.equal(session.allowed,true);assert.equal(session.activated,true);
 const before=await read('students_directory',f.student);assert.equal(before.pointRead,true);validatePerson(before.records?.[f.student],f);
 const body={action:'managed/records',edgeDeliveryVersion:1,operation:'delete',collection:'students_directory',id:f.student,syncProtocol:2,
  operationId:f.operationId,expectedRecordRevision:f.originalRevision,deletedStudentGeneration:f.generation,deleteEverywhereVersion:1};
 const observe=observeDeletePlan(async(collection,id)=>{const r=await read(collection,id);validatePerson(r.records?.[id],f);return r;},SCHOOL);
 const ack=await retryExactDelete(body,request=>call(request),{attempts:48,maxElapsedMs:40*60*1000,observeProgress:observe});
 assert.equal(verifiedNativeReceipt(ack,body,SCHOOL),true);assert.ok(ack.deletedFileIds?.includes(f.fileId));validatePerson(ack.record,f);
 result.deletionReceiptVerified=true;
 for(const [collection,id] of [['students_directory',f.student],['documents',f.documentId],['fee_payments',f.feeId]]){
  const r=await read(collection,id);assert.equal(r.pointRead,true);assert.equal(r.records?.[id]?._syncDeleted,true);assert.equal(r.records[id]._syncDeletedOwner,f.generation);
 }
 result.originalRecordsVerified=true;
 const web=await call({action:'managed/changes',collections:['students_directory','documents','fee_payments'],knownRevisions:{}});
 assert.equal(web.changes?.students_directory?.records?.[f.student]?._syncDeleted,true);
 assert.equal(web.changes?.documents?.records?.[f.documentId]?._syncDeleted,true);result.websiteReadback=true;
 const mobile=await post(API,{action:'managed/mobile',schoolId:SCHOOL,request:{action:'mobile_login',projectId:SCHOOL,role:'student',personId:f.generation,
  linkToken:hash('test-mobile-link/'+f.student),studentClass:'1',rollNo:String((Number(RUN.slice(-6))%900000)+100000),dob:'2015-01-01'}},token);
 assert.equal(mobile.http,403);assert.notEqual(mobile.data.success,true);assert.notEqual(typeof mobile.data.sessionToken,'string');result.deletedPersonLoginRejected=true;
 const file=await post(API,{action:'managed/file/read',schoolId:SCHOOL,fileId:f.fileId},token);
 assert.equal(file.http,502);assert.ok(['SCRIPT_OPERATION_FAILED','SCRIPT_PERMISSION_DENIED'].includes(file.data.code));
 assert.notEqual(file.data.success,true);assert.ok(!file.data.base64);result.pdfInaccessible=true;
 result.status='PASS';
}
if(require.main===module)main().catch(error=>{
 const safe=new Set(['SCRIPT_SIGNED_RESPONSE_UNVERIFIED','SCRIPT_TIMEOUT','SCRIPT_DELETE_BUDGET_EXHAUSTED','SCRIPT_DELETE_NO_PROGRESS','SCRIPT_DELETE_EVERYWHERE_PENDING','SCRIPT_QUOTA_EXCEEDED']);
 result.failureCode=safe.has(error.code)?error.code:'PROOF_OR_REQUEST_UNVERIFIED';process.exitCode=1;
}).finally(()=>{
 fs.mkdirSync('build/cloud-prerequisites',{recursive:true});
 fs.writeFileSync('build/cloud-prerequisites/original-delete-completion.json',JSON.stringify(result,null,2));
 // Only verification flags: no artifact-derived identities, hashes, raw errors,
 // request references, credentials or record contents are published.
 console.log('ORIGINAL_TEST_DELETE_COMPLETION '+JSON.stringify(result));
});
module.exports={fixture,validatePerson,SCHOOL,SHA};
