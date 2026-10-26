'use strict';
// Explicitly opted-in, isolated TEST-only provider acceptance. Retains its one fixture.
const crypto=require('node:crypto'),fs=require('node:fs');
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d';
const ENDPOINT='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const LOGIN='https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
function requireCheck(ok,name){if(!ok)throw new Error(name);}
async function transport(url,body,token){
 const response=await fetch(url,{method:body?'POST':'GET',redirect:'error',headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(120000)});
 return {status:response.status,data:await response.json()};
}
async function acceptance({env=process.env,request=transport,report={checks:[]}}={}){
 report.scope='isolated TEST native upload, one retained synthetic file';report.schoolId=SCHOOL;
 report.networkInterruptionTested=false;report.resumeScope='confirmed first chunk, fresh begin/status, remaining bytes';
 report.productionCapacityCertified=false;report.retained=true;
 let stage='explicit opt-in';
 try{
  requireCheck(env.VS_TEST_NATIVE_UPLOAD_ACCEPTANCE==='1',stage);
  stage='reviewed runtime requirement';requireCheck(/^[a-f0-9]{40}$/.test(env.VS_EXPECTED_TEST_RUNTIME||''),stage);
  const expectedVersion=require('./reviewed_script_version.cjs').currentReviewedScriptVersion();
  stage='TEST login secrets';requireCheck(env.VS_TEST_LOGIN_EMAIL&&env.VS_TEST_LOGIN_PASSWORD,stage);
  const runId=env.VS_TEST_NATIVE_UPLOAD_RUN_ID||crypto.randomBytes(12).toString('hex');
  requireCheck(/^[A-Za-z0-9_-]{1,64}$/.test(runId),'TEST run ID');
  report.uploadKey='sync3_native_acceptance_'+runId;
  let token;
  async function call(body){
   const start=performance.now();const r=await request(ENDPOINT,{...body,schoolId:SCHOOL},token);
   requireCheck(r.status===200&&r.data&&r.data.success===true&&r.data.schoolId===SCHOOL,stage);
   report.checks.push({name:stage,status:'PASS',elapsedMs:Math.round(performance.now()-start)});return r.data;
  }
  stage='matching TEST runtime';let r=await request(ENDPOINT+'/healthz');
  requireCheck(r.status===200&&r.data.ready===true&&r.data.projectId==='saarthi-ai-df12b'&&r.data.runtimeCommit===env.VS_EXPECTED_TEST_RUNTIME,stage);
  report.runtimeCommit=r.data.runtimeCommit;report.checks.push({name:stage,status:'PASS'});
  stage='Firebase TEST login';r=await request(LOGIN,{email:env.VS_TEST_LOGIN_EMAIL,password:env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});
  requireCheck(r.status===200&&typeof r.data.idToken==='string'&&typeof r.data.localId==='string',stage);token=r.data.idToken;
  stage='authenticated active TEST identity';const session=await call({action:'managed/session'});
  requireCheck(session.allowed===true&&session.uid===r.data.localId,stage);
  stage='matching TEST Script and native capability';const health=await call({action:'managed/storage/check'});
  requireCheck(health.storageReady===true&&health.scriptBundleVersion===expectedVersion&&health.brokerUploadResumableVersion===1&&health.uploadResumableVersion===1,stage);
  report.scriptBundleVersion=health.scriptBundleVersion;
  // Deterministic, non-school data makes a retained run ID safe to resume.
  const bytes=Buffer.alloc(768*1024);for(let i=0;i<bytes.length;i++)bytes[i]=(i*31+17)%251;
  const meta={action:'managed/file/upload/resumable',uploadKey:report.uploadKey,name:report.uploadKey+'.bin',mime:'application/octet-stream',sha256:hash(bytes),sizeBytes:bytes.length};
  function verified(out){
   requireCheck(out.uploadResumableVersion===1&&out.uploadKey===meta.uploadKey&&out.sha256===meta.sha256&&out.sizeBytes===bytes.length&&typeof out.committed==='boolean'&&Number.isSafeInteger(out.offset)&&out.offset>=0&&out.offset<=bytes.length&&
    (out.committed?out.offset===bytes.length&&/^[A-Za-z0-9_-]{1,200}$/.test(out.fileId||''):out.offset<bytes.length),stage);return out;
  }
  stage='begin retained upload';let progress=verified(await call({...meta,operation:'begin'}));
  const initial=progress.offset;
  if(!progress.committed&&initial===0){
   stage='confirmed initial 256 KiB chunk';const chunk=bytes.subarray(0,256*1024);
   progress=verified(await call({...meta,operation:'part',offset:0,base64:chunk.toString('base64'),chunkSha256:hash(chunk)}));
   requireCheck(!progress.committed&&progress.offset===chunk.length,stage);
  }
  stage='provider-confirmed status before reopening';progress=verified(await call({...meta,operation:'status'}));const confirmed=progress.offset;
  stage='fresh begin with original durable key';progress=verified(await call({...meta,operation:'begin'}));requireCheck(progress.offset===confirmed,stage);
  stage='provider-confirmed status after reopening';progress=verified(await call({...meta,operation:'status'}));requireCheck(progress.offset===confirmed,stage);
  report.resumedFrom=confirmed;
  for(let step=0;!progress.committed&&step<8;step++){
   stage='remaining chunk '+(step+1);const offset=progress.offset,chunk=bytes.subarray(offset,Math.min(offset+512*1024,bytes.length));
   progress=verified(await call({...meta,operation:'part',offset,base64:chunk.toString('base64'),chunkSha256:hash(chunk)}));requireCheck(progress.offset>offset,stage);
  }
  stage='verified committed file';requireCheck(progress.committed,stage);const fileId=progress.fileId;
  stage='stable completion status';const final=verified(await call({...meta,operation:'status'}));requireCheck(final.committed&&final.fileId===fileId,stage);
  stage='exact retained file byte readback';const read=await call({action:'managed/file/read',fileId});
  requireCheck(typeof read.base64==='string'&&read.base64.length<=1100000&&read.mime===meta.mime,stage);
  const returned=Buffer.from(read.base64,'base64');requireCheck(returned.equals(bytes)&&hash(returned)===meta.sha256,stage);
  report.fileId=fileId;report.sizeBytes=bytes.length;report.sha256=meta.sha256;report.startedFromExistingUpload=initial>0;report.status='PASS';
  report.remaining='No physical-device, forced network-loss, provider quota saturation or production load acceptance performed.';
 }catch(_){report.status='FAIL';report.failedStage=stage;report.next='Inspect sanitized stage; retain the same run ID after uncertain writes. Never clear or replay another school queue.';}
 return report;
}
if(require.main===module)acceptance().then(report=>{
 fs.mkdirSync('build/cloud-prerequisites',{recursive:true});fs.writeFileSync('build/cloud-prerequisites/native-upload-acceptance.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));if(report.status!=='PASS')process.exitCode=1;
});
module.exports={acceptance,SCHOOL,ENDPOINT};
