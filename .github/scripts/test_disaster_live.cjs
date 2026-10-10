'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const schoolId='vs-db8afb01a3be46a983c8284714d06e5d',endpoint='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const apiKey='AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const {fixture,verifyEvidence}=require('./disaster_resume.cjs');
const report={schoolId,checks:[],status:'RUNNING',originalSchoolTouched:false,activeStorageChanged:false};
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function post(url,body,token){const response=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(120000)});return {http:response.status,data:await response.json()};}
async function run(){
 assert.equal(process.env.GITHUB_ACTIONS,'true');assert.equal(process.env.VS_TEST_CONNECT_CONFIRM,schoolId);
 assert.ok(process.env.VS_TEST_LOGIN_EMAIL&&process.env.VS_TEST_LOGIN_PASSWORD);
 // Capture only after the same-commit end-to-end fixture writers have finished.
 // A concurrent accepted write safely invalidates this generation instead of
 // silently mixing two different school states into a "complete" backup.
 const identity=fixture(process.env);let writersFinished=false;
 for(let n=0;n<140;n++){
  const r=await fetch('https://api.github.com/repos/'+process.env.GITHUB_REPOSITORY+'/actions/runs?branch=feature%2Fsmart-sync-3&per_page=30',{
    headers:{Authorization:'Bearer '+process.env.GITHUB_TOKEN,Accept:'application/vnd.github+json'},signal:AbortSignal.timeout(30000)});assert.equal(r.status,200);
  const runs=(await r.json()).workflow_runs,cloud=runs.filter(run=>run.name==='Isolated TEST cloud prerequisites');
  const run=cloud.find(run=>run.head_sha===process.env.GITHUB_SHA)||cloud.find(run=>String(run.id)===process.env.VS_TEST_CLOUD_EVIDENCE_RUN_ID);
  if(!cloud.some(run=>run.status!=='completed')&&run?.status==='completed'){
   let comparison;if(run.head_sha!==process.env.GITHUB_SHA){
    const c=await fetch('https://api.github.com/repos/'+process.env.GITHUB_REPOSITORY+'/compare/'+run.head_sha+'...'+process.env.GITHUB_SHA,{headers:{Authorization:'Bearer '+process.env.GITHUB_TOKEN,Accept:'application/vnd.github+json'},signal:AbortSignal.timeout(30000)});assert.equal(c.status,200);comparison=await c.json();
   }
   report.cloudEvidence=verifyEvidence(run,process.env.GITHUB_SHA,comparison);report.originalRecoveryOperationResumed=identity.resumed;writersFinished=true;break;
  }if(n%10===0)console.log('Waiting for verified compatible end-to-end TEST writers');await delay(15000);
 }assert.ok(writersFinished);
 const login=await post('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key='+apiKey,{email:process.env.VS_TEST_LOGIN_EMAIL,password:process.env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});assert.equal(login.http,200);const token=login.data.idToken;assert.ok(token);
 const call=async body=>{const r=await post(endpoint,{...body,schoolId},token);assert.equal(r.http,200);assert.equal(r.data.success,true);assert.equal(r.data.schoolId,schoolId);return r.data;};
 const pass=name=>{report.checks.push({name,status:'PASS'});console.log(JSON.stringify({check:name,status:'PASS'}));};
 // Wait only for this authorized TEST release to become available. No production
 // access, no fallback to old backup schemas and no deployment from CI.
 let ready=false;for(let n=0;n<40;n++){try{const r=await call({action:'managed/storage/check'});if(r.disasterRehearsalVersion===5&&r.brokerDisasterRehearsalVersion===5){ready=true;break;}}catch(_){}await delay(15000);}assert.ok(ready);pass('Authenticated TEST broker and reviewed disaster capability');
 const id=identity.id,op=id+'-create';
 const pdf=Buffer.from('%PDF-1.4\nSynthetic TEST disaster binary\n%%EOF\n'),uploadKey=crypto.createHash('sha256').update(id).digest('hex');
 const upload=await call({action:'managed/file/upload',name:id+'.pdf',mime:'application/pdf',base64:pdf.toString('base64'),uploadKey});
 const original=await call({action:'managed/records',operation:'write',collection:'school_notices',id,syncProtocol:2,operationId:op,expectedRecordRevision:'',data:{schoolId,syntheticTest:true,title:'Disposable disaster recovery fixture',fileId:upload.fileId,capturedAt:12345}});assert.ok(original.recordRevision);pass('Original operation and file durable ACK');
 const execute=async request=>{let result,retries=0;for(let step=0;step<400;step++){
   try{result=await call({action:'managed/disaster',...request});retries=0;}catch(error){if(++retries>3)throw error;await delay(Math.min(30000,4000*2**retries)+Math.floor(Math.random()*1000));continue;}
   assert.equal(result.disasterVersion,5);assert.equal(result.operationId,request.operationId);assert.equal(result.activeStorageChanged,false);
   if(result.complete){assert.equal(result.verified,true);assert.ok(result.verifiedAt>0);const repeated=await call({action:'managed/disaster',...request});assert.equal(repeated.fileId,result.fileId);return result;}
   if(step%10===0)console.log(JSON.stringify({stage:request.operation,phase:result.phase,step,copied:result.copied,binaryCount:result.binaryCount}));await delay(2000);
 }throw Error('TEST disaster job exceeds bounded verification window');};
 const backup=await execute({operation:'backup',operationId:crypto.createHash('sha256').update(id+'/backup').digest('hex')});pass('Complete managed-record and uploaded-byte archive hash readback');report.backupBinaryCount=backup.binaryCount;
 const restored=await execute({operation:'rehearse',operationId:crypto.createHash('sha256').update(id+'/restore').digest('hex'),fileId:backup.fileId});pass('Separate private Sheets/Drive restore readback, stable retry identity');report.restoredRecordCount=restored.recordCount;report.restoredBinaryCount=restored.binaryCount;
 const records=(await call({action:'managed/records',collection:'school_notices',operation:'read',syncProtocol:2})).records,row=records[id];assert.equal(row._syncRevision,original.recordRevision);assert.equal(row._syncOperationId,op);assert.equal(row.capturedAt,12345);assert.equal(row.fileId,upload.fileId);pass('Active Sheets records, revision, operation, timestamp and original file link unchanged');
 const originalFile=await call({action:'managed/file/read',fileId:upload.fileId});assert.deepEqual(Buffer.from(originalFile.base64,'base64'),pdf);pass('Original Drive bytes retained without QR regeneration');
 const foreign=await post(endpoint,{action:'managed/disaster',operation:'backup',operationId:'f'.repeat(64),schoolId:'vs-ffffffffffffffffffffffffffffffff'},token);assert.notEqual(foreign.http,200);pass('Foreign school disaster access rejected');
 report.status='PASS';report.activeCutoverVerified=false;report.localPendingQueuesIncluded=false;report.firebaseCredentialsIncluded=false;
}
run().catch(()=>{report.status='FAIL';process.exitCode=1;}).finally(()=>{fs.mkdirSync('build/cloud-prerequisites',{recursive:true});fs.writeFileSync('build/cloud-prerequisites/disaster-live.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));});
