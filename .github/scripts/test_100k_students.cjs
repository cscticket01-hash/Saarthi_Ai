'use strict';
// Explicit isolated TEST-school load. No production credentials, no data deletes.
// Deterministic TEST2-DEMO IDs match the reviewed 100,000-row CSV.
const crypto=require('node:crypto'),fs=require('node:fs'),path=require('node:path');
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d';
const ENDPOINT='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const LOGIN='https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const TARGET=100000,OUTPUT='build/test-100k/progress.json';
const digest=value=>crypto.createHash('sha256').update(value).digest('hex');
const number=(s,d)=>s===undefined?d:Number(s);
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const pad=n=>String(n).padStart(6,'0');
const student=n=>{
 const label=pad(n),id='TEST2-DEMO-'+label,cls='Class '+(1+(n-1)%12);
 const section=String.fromCharCode(65+(n-1)%10);
 // Class+section repeats every 60 students. Roll numbers must remain distinct
 // within that pair; the old /120 slot numbering collided at student #61.
 // Preserve the first 60 completed IDs, and use a new durable operation ID
 // for the corrected payload of all uncommitted entries.
 const rollNo=n<=60?'1':String(n);
 return {id,operationId:(n<=60?'VS100K_':'VS100K2_')+label+'_'+digest(SCHOOL+'/'+id).slice(0,16),
  data:{schoolId:SCHOOL,name:'Demo Student '+label,class:cls,studentClass:cls,
   section,rollNo,mobileStableId:'p-'+digest('TEST2-DEMO-STUDENT/'+id).slice(0,32),
   syntheticTest:true,syntheticBatch:'TEST2-DEMO-100K'}};
};
async function transport(url,body,token){
 const res=await fetch(url,{method:body?'POST':'GET',redirect:'error',
  headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},
  ...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(120000)});
 const result=await res.json();return {status:res.status,data:result};
}
async function run({env=process.env,send=transport}={}){
 const start=number(env.VS_TEST_100K_START,1),end=number(env.VS_TEST_100K_END,10),
  budgetMinutes=number(env.VS_TEST_100K_BUDGET_MINUTES,35);
 const report={schoolId:SCHOOL,fixture:'TEST2-DEMO',target:TARGET,start,end,
  checked:0,verified:0,pending:0,previouslyPresent:0,failed:0,
  status:'RUNNING',lastVerifiedIndex:start-1,stage:'input validation',source:'live school Drive via signed broker'};
 const started=Date.now();
 const checkpoint=()=>{
  fs.mkdirSync(path.dirname(OUTPUT),{recursive:true});
  fs.writeFileSync(OUTPUT,JSON.stringify({...report,elapsedSeconds:Math.round((Date.now()-started)/1000)},null,2));
 };
 const require=(v,label)=>{if(!v)throw Error(label);};
 try{
  require(env.GITHUB_ACTIONS==='true','GitHub Actions only');
  require(env.VS_TEST_100K_CONFIRM===SCHOOL,'TEST school explicit opt-in missing');
  require(Number.isInteger(start)&&Number.isInteger(end)&&start>=1&&end<=TARGET&&start<=end,'Invalid bounded range');
  require(Number.isFinite(budgetMinutes)&&budgetMinutes>=2&&budgetMinutes<=340,'Invalid time budget');
  require(/^[a-f0-9]{40}$/.test(env.VS_EXPECTED_TEST_RUNTIME||''),'Missing exact deployed commit pin');
  require(typeof env.VS_TEST_LOGIN_EMAIL==='string'&&!!env.VS_TEST_LOGIN_EMAIL,'Missing TEST login');
  require(typeof env.VS_TEST_LOGIN_PASSWORD==='string'&&!!env.VS_TEST_LOGIN_PASSWORD,'Missing TEST secret');
  report.stage='TEST deployment readiness';
  let r=await send(ENDPOINT+'/healthz');
  require(r.status===200&&r.data.ready===true&&r.data.projectId==='saarthi-ai-df12b'&&r.data.runtimeCommit===env.VS_EXPECTED_TEST_RUNTIME,'TEST runtime mismatch');
  report.runtimeCommit=r.data.runtimeCommit;
  report.stage='TEST Firebase login';
  r=await send(LOGIN,{email:env.VS_TEST_LOGIN_EMAIL,password:env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});
  require(r.status===200&&typeof r.data.idToken==='string','TEST login denied');
  const token=r.data.idToken,uid=r.data.localId;
  async function call(body){
   const reply=await send(ENDPOINT,{...body,schoolId:SCHOOL},token);
   if(reply.status!==200||reply.data?.success!==true||reply.data.schoolId!==SCHOOL){
    const code=/^[A-Z_]{1,80}$/.test(reply.data?.code||'')?reply.data.code:'UNVERIFIED_PROVIDER_FAILURE';
    throw Object.assign(Error('TEST broker '+code),{status:reply.status,code,retryAtMillis:reply.data?.deliveryStatus?.retryAtMillis});
   }return reply.data;
  }
  report.stage='TEST membership and signed Google storage';
  const session=await call({action:'managed/session'});
  require(session.allowed===true&&session.uid===uid&&session.storageReady===true,'Invalid school membership/entitlement');
  const health=await call({action:'managed/storage/check'});
  require(health.storageReady===true&&health.recordSyncVersion===2&&health.schoolId===SCHOOL,'TEST Drive not prepared');
  checkpoint();
  for(let n=start;n<=end;n++){
   if(Date.now()-started>budgetMinutes*60000-120000){report.status='TIME_BUDGET_REACHED';break;}
   const s=student(n);report.stage='student '+n+' Cloudflare accept';
   const body={action:'managed/records',collection:'students_directory',operation:'write',
    syncProtocol:2,edgeDeliveryVersion:1,id:s.id,operationId:s.operationId,
    expectedRecordRevision:'',data:s.data};
   let ack;let lastCode='';
   // Same ID and operationId on every retry. Do not invent a replacement write.
   for(let retry=0;retry<6;retry++){
    try{ack=await call(body);break;}catch(e){
     lastCode=e.code||'REQUEST_FAILURE';
     if(![429,502,503,504].includes(e.status))throw e;
     if(Date.now()-started>budgetMinutes*60000-120000)throw e;
     await pause(Math.min(30000,2000*2**retry));
    }
   }
   require(ack!=null,'No accepted receipt '+lastCode);
   if(ack.delivery){
    require(ack.cloudflareAccepted===true&&ack.driveState==='pending'&&
      ack.delivery.lane==='records'&&/^[a-f0-9]{64}$/.test(ack.delivery.id),'Invalid Cloudflare ticket');
    report.stage='student '+n+' signed Google ACK';
    let completed=false;
    for(let poll=0;poll<75;poll++){
     if(Date.now()-started>budgetMinutes*60000-120000)break;
     const result=await call({action:'managed/cloudflare/operation',...ack.delivery,waitMillis:20000});
     if(!result.delivery){require(result.driveState==='verified','Google ACK missing');ack=result;completed=true;break;}
     require(result.delivery.id===ack.delivery.id&&result.delivery.lane==='records','Staged ticket changed');
     const wait=result.deliveryStatus?.retryAtMillis;
     if(Number.isSafeInteger(wait)&&wait>Date.now())await pause(Math.min(30000,Math.max(1000,wait-Date.now())));
    }
    if(!completed){report.pending++;report.status='PENDING_DRIVE_ACK';report.lastPendingIndex=n;break;}
   }
   require(ack.driveState==='verified'&&typeof ack.recordRevision==='string'&&!!ack.recordRevision,'Missing Google record proof');
   report.stage='student '+n+' canonical Drive readback';
   const actual=await call({action:'managed/records',collection:'students_directory',operation:'read',syncProtocol:2,id:s.id});
   const item=actual.records?.[s.id];
   require(item&&item.schoolId===SCHOOL&&item._syncRevision===ack.recordRevision&&
    item._syncOperationId===s.operationId&&item.name===s.data.name&&
    item.class===s.data.class&&item.section===s.data.section&&
    String(item.rollNo)===s.data.rollNo&&item.mobileStableId===s.data.mobileStableId&&
    item.syntheticTest===true&&item._syncDeleted!==true,'Canonical student readback mismatch');
   report.checked++;report.verified++;report.lastVerifiedIndex=n;
   checkpoint();
   console.log(JSON.stringify({event:'TEST_100K_VERIFIED',index:n,verified:report.verified,target:TARGET}));
  }
  if(report.status==='RUNNING')report.status=report.lastVerifiedIndex===end?'RANGE_VERIFIED':'INCOMPLETE';
 }catch(e){
  report.failed++;report.status='FAIL';report.failure={stage:report.stage,code:e?.code||'VALIDATION_OR_TRANSPORT_FAILURE',status:Number.isInteger(e?.status)?e.status:null};
 }finally{checkpoint();}
 console.log(JSON.stringify({event:'TEST_100K_FINAL',...report,loginCredentials:'never logged'}));
 return report;
}
if(require.main===module)run().then(report=>{if(report.status!=='RANGE_VERIFIED'&&report.status!=='TIME_BUDGET_REACHED')process.exitCode=1;});
module.exports={run,student,SCHOOL,TARGET};
