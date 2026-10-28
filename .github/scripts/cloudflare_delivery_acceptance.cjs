'use strict';
// Only synthetic records in the retained isolated TEST school. Never delete data.
const crypto=require('node:crypto'),fs=require('node:fs');
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d';
const ENDPOINT='https://saarthi-oauth-staging.onrender.com/school-cloud';
const LOGIN='https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const hash=value=>crypto.createHash('sha256').update(value).digest('hex');
async function transport(url,body,token){
 const response=await fetch(url,{method:body?'POST':'GET',redirect:'error',
  headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},
  ...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(120000)});
 return {status:response.status,data:await response.json()};
}
async function acceptance({env=process.env,request=transport}={}){
 const report={scope:'Synthetic TEST school only, retained fixtures',schoolId:SCHOOL,checks:[],productionLoadCertified:false};
 let stage='explicit acceptance opt-in',token;
 function requireCheck(ok){if(!ok)throw Error(stage);}
 try{
  requireCheck(env.VS_CF_DELIVERY_ACCEPTANCE==='1');
  stage='expected reviewed broker runtime';requireCheck(/^[a-f0-9]{40}$/.test(env.VS_EXPECTED_RUNTIME||''));
  const run=env.VS_CF_DELIVERY_RUN_ID;stage='stable synthetic run identity';requireCheck(/^[A-Za-z0-9_-]{1,48}$/.test(run||''));
  stage='TEST login secrets';requireCheck(env.VS_TEST_LOGIN_EMAIL&&env.VS_TEST_LOGIN_PASSWORD);
  stage='deployed broker readiness';let r=await request(ENDPOINT+'/healthz');
  requireCheck(r.status===200&&r.data.ready===true&&r.data.projectId==='saarthi-ai-df12b');
  // Production intentionally omits its commit from public health. A deployment
  // pin comes from the separately verified Render live-deploy API, not a guess.
  if(r.data.runtimeCommit!==undefined)requireCheck(r.data.runtimeCommit===env.VS_EXPECTED_RUNTIME);
  else requireCheck(env.VS_VERIFIED_RENDER_COMMIT===env.VS_EXPECTED_RUNTIME&&/^dep-[a-z0-9]+$/.test(env.VS_VERIFIED_RENDER_DEPLOYMENT||''));
  report.runtimeCommit=env.VS_EXPECTED_RUNTIME;
  report.runtimeVerification=r.data.runtimeCommit?'health endpoint':'verified Render live-deploy pin';
  if(!r.data.runtimeCommit)report.deployment=env.VS_VERIFIED_RENDER_DEPLOYMENT;
  stage='Firebase TEST login';r=await request(LOGIN,{email:env.VS_TEST_LOGIN_EMAIL,password:env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});
  requireCheck(r.status===200&&typeof r.data.idToken==='string'&&typeof r.data.localId==='string');token=r.data.idToken;
  async function call(body){
   const r=await request(ENDPOINT,{...body,schoolId:SCHOOL},token);
   if(r.status!==200||r.data?.success!==true||r.data.schoolId!==SCHOOL){
    report.failure={http:r.status,...(/^[A-Z_]{1,80}$/.test(r.data?.code||'')?{code:r.data.code}:{})};throw Error(stage);
   }
   return r.data;
  }
  stage='verified TEST school membership';const session=await call({action:'managed/session'});requireCheck(session.allowed===true&&session.uid===r.data.localId);
  stage='new delivery capability';const health=await call({action:'managed/storage/check'});
  requireCheck(health.storageReady===true&&health.brokerEdgeDeliveryVersion===1&&health.recordSyncVersion===2&&health.uploadResumableVersion===1);
  report.checks.push({name:stage,status:'PASS'});
  async function settle(result){
   const ticket=result.delivery;requireCheck(result.cloudflareAccepted===true&&result.driveState==='pending'&&ticket&&/^[a-f0-9]{64}$/.test(ticket.id)&&/^(records|file-[a-f0-9]{64})$/.test(ticket.lane));
   requireCheck(!result.fileId&&!result.recordRevision);
   for(let attempt=0;attempt<24;attempt++){
    result=await call({action:'managed/cloudflare/operation',...ticket,waitMillis:20000});
    if(!result.delivery){requireCheck(result.driveState==='verified');return result;}
    requireCheck(result.delivery.id===ticket.id&&result.delivery.lane===ticket.lane);
   }
   throw Error(stage);
  }
  async function record(collection,id,data,extra={}){
   const body={action:'managed/records',operation:'write',syncProtocol:2,collection,id,
    operationId:hash(SCHOOL+':'+collection+':'+id),expectedRecordRevision:'',data:{...data,schoolId:SCHOOL},edgeDeliveryVersion:1,...extra};
   let result=await call(body);
   if(result.delivery)result=await settle(result);
   requireCheck(result.cloudflareAccepted===true&&result.driveState==='verified'&&typeof result.recordRevision==='string'&&!result.recordRevision.startsWith('cf-'));
   const replay=await call(body);requireCheck(replay.recordRevision===result.recordRevision&&replay.driveState==='verified');
   const read=await call({action:'managed/records',operation:'read',syncProtocol:2,collection,id});
   requireCheck(read.records?.[id]?._syncRevision===result.recordRevision);
   report.checks.push({name:stage,status:'PASS'});return result;
  }
  stage='teacher record edge acceptance, verified Drive write and exact replay';
  const teacher='CF_TEST_TEACHER_'+run;
  await record('teachers_directory',teacher,{teacherId:teacher,name:'SYNTHETIC CLOUD DELIVERY TEST',role:'teacher'});
  stage='staff record edge acceptance and verified Drive write';
  const staff='CF_TEST_STAFF_'+run;
  await record('teachers_directory',staff,{teacherId:staff,name:'SYNTHETIC CLOUD DELIVERY TEST',role:'staff'});
  const bytes=Buffer.alloc(768*1024,32);Buffer.from('%PDF-1.4\n% SYNTHETIC CLOUD DELIVERY TEST ONLY\n%%EOF\n').copy(bytes);
  const uploadKey='cf_test_document_'+run,meta={action:'managed/file/upload/resumable',uploadKey,
   name:uploadKey+'.pdf',mime:'application/pdf',sizeBytes:bytes.length,sha256:hash(bytes),edgeDeliveryVersion:1};
  stage='hash-verified resumable document staging';let progress=await call({...meta,operation:'begin'});
  const wasCommitted=progress.committed===true;
  if(progress.delivery)progress=await settle(progress);
  if(!wasCommitted&&progress.driveState!=='verified'){
   let offset=progress.offset;
   requireCheck(Number.isSafeInteger(offset)&&offset>=0&&offset<bytes.length);
   if(offset===0){const chunk=bytes.subarray(0,256*1024);progress=await call({...meta,operation:'part',offset,base64:chunk.toString('base64'),chunkSha256:hash(chunk)});offset=progress.offset;requireCheck(offset===chunk.length&&!progress.committed);}
   const reopened=await call({...meta,operation:'begin'});requireCheck(reopened.offset===offset);
   const chunk=bytes.subarray(offset);progress=await call({...meta,operation:'part',offset,base64:chunk.toString('base64'),chunkSha256:hash(chunk)});
   if(progress.delivery)progress=await settle(progress);
  }
  requireCheck(progress.committed===true&&progress.sha256===meta.sha256&&progress.sizeBytes===bytes.length&&progress.offset===bytes.length&&/^[A-Za-z0-9_-]{1,200}$/.test(progress.fileId||''));
  const fileId=progress.fileId;
  stage='exact permanent Drive byte readback';const file=await call({action:'managed/file/read',fileId});requireCheck(file.mime===meta.mime&&hash(Buffer.from(file.base64||'','base64'))===meta.sha256);
  report.checks.push({name:stage,status:'PASS'});
  stage='ID card document metadata waits for verified real Drive file ID';
  await record('documents','CF_TEST_IDCARD_'+run,{documentKind:'idCard',ownerRole:'teacher',teacherId:teacher,personId:teacher,documentRevision:hash(run),fileId,fileUrl:'https://drive.google.com/file/d/'+fileId+'/view',mimeType:meta.mime,uploadedAt:1793232000000},{expectedRevision:''});
  stage='another school cannot poll the accepted receipt';
  const foreign=await request(ENDPOINT,{action:'managed/cloudflare/operation',schoolId:'vs-'+'0'.repeat(32),lane:'records',id:hash('foreign')},token);requireCheck(foreign.status===403);
  report.checks.push({name:stage,status:'PASS'});
  report.status='PASS';report.retainedFixtures={teacher,staff,document:'CF_TEST_IDCARD_'+run,fileId,sha256:meta.sha256};
 }catch(_){report.status='FAIL';report.failedStage=stage;}
 return report;
}
if(require.main===module)acceptance().then(report=>{
 fs.mkdirSync('build/cloud-prerequisites',{recursive:true});
 fs.writeFileSync('build/cloud-prerequisites/cloudflare-delivery.json',JSON.stringify(report,null,2));
 console.log(JSON.stringify(report));if(report.status!=='PASS')process.exitCode=1;
});
module.exports={acceptance,SCHOOL,ENDPOINT,LOGIN};
