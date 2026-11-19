'use strict';
// Only synthetic records in the retained isolated TEST school. Never delete data.
const crypto=require('node:crypto'),fs=require('node:fs');
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d';
const ENDPOINT='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const LOGIN='https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const hash=value=>crypto.createHash('sha256').update(value).digest('hex');
async function transport(url,body,token){
 const response=await fetch(url,{method:body?'POST':'GET',redirect:'error',
  headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},
  ...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(120000)});
 return {status:response.status,data:await response.json()};
}
// Protected person writes use a signed lifecycle/Drive proof, whereas
// ordinary records use a durable Cloudflare ticket plus a signed Drive ACK.
// Never mistake a direct person receipt for a Cloudflare staging receipt.
function verifiedRecordRoute(result,route){
 const revision=result?.recordRevision;
 if(typeof revision!=='string'||!revision||/^(cf-|live-)/.test(revision)||result.delivery)return false;
 if(route==='person')return result.personLifecycleVersion===1&&result.syncProtocol===2&&result.cloudflareAccepted!==true;
 if(route==='edge')return result.cloudflareAccepted===true&&result.driveState==='verified';
 return false;
}
// Re-submit only the EXACT same immutable original request after an authenticated
// broker SCRIPT_TIMEOUT. Both the original operation ID (or exact status ticket)
// and its serialized request must remain unchanged. One bounded retry only.
async function retryOriginalTimeout(run,body,{sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms)),delayMs=12000}={}){
 const original=JSON.stringify(body);
 const record=body?.action==='managed/records'&&body.operation==='write'&&
   /^[a-f0-9]{64}$/.test(body.operationId||'')&&body.syncProtocol===2;
 const status=body?.action==='managed/cloudflare/operation'&&
   /^(records|file-[a-f0-9]{64})$/.test(body.lane||'')&&
   /^[a-f0-9]{64}$/.test(body.id||'');
 for(let attempt=0;attempt<2;attempt++){
  if(JSON.stringify(body)!==original)throw Error('Immutable original request changed');
  try{return await run(body);}
  catch(error){
   if(error?.status!==504||error?.code!=='SCRIPT_TIMEOUT'||attempt!==0||!(record||status))
    throw error;
   await sleep(delayMs);
  }
 }
 throw Error('Original request remains unverified');
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
    report.failure={http:r.status,...(/^[A-Z_]{1,80}$/.test(r.data?.code||'')?{code:r.data.code}:{})};
    const error=new Error(stage);
    error.status=r.status;
    error.code=report.failure.code;
    throw error;
   }
   return r.data;
  }
  stage='verified TEST school membership';const session=await call({action:'managed/session'});requireCheck(session.allowed===true&&session.uid===r.data.localId);
  stage='matching owner-deployed TEST Script contract';const health=await call({action:'managed/storage/check'});
  const expectedScript=require('./reviewed_script_version.cjs').currentReviewedScriptVersion();
  report.scriptBundleVersion=typeof health.scriptBundleVersion==='string'?health.scriptBundleVersion:'unknown';
  report.expectedScriptBundleVersion=expectedScript;
  requireCheck(health.storageReady===true&&health.scriptBundleVersion===expectedScript);
  report.checks.push({name:stage,status:'PASS'});
  stage='new delivery capability';
  requireCheck(health.brokerEdgeDeliveryVersion===1&&health.recordSyncVersion===2&&health.uploadResumableVersion===1);
  report.checks.push({name:stage,status:'PASS'});
  async function settle(result){
   const ticket=result.delivery;requireCheck(result.cloudflareAccepted===true&&result.driveState==='pending'&&ticket&&/^[a-f0-9]{64}$/.test(ticket.id)&&/^(records|file-[a-f0-9]{64})$/.test(ticket.lane));
   requireCheck(!result.fileId&&!result.recordRevision);
   for(let attempt=0;attempt<24;attempt++){
    result=await originalRequest({action:'managed/cloudflare/operation',...ticket,waitMillis:20000});
    if(result.deliveryStatus)report.lastDeliveryStatus=result.deliveryStatus;
    if(!result.delivery){requireCheck(result.driveState==='verified');return result;}
    requireCheck(result.delivery.id===ticket.id&&result.delivery.lane===ticket.lane);
   }
   throw Error(stage);
  }
  // Every status poll or record retry is tied to its original immutable
  // operation, never a new ID or guessed receipt. Timeouts remain failures
  // until the exact signed Drive proof and readback are obtained.
  async function originalRequest(body){
   const wrapped=async original=>{
    const answer=await call(original);
    if(report.failure?.code==='SCRIPT_TIMEOUT')delete report.failure;
    return answer;
   };
   return retryOriginalTimeout(wrapped,body,{
    sleep:async ms=>{report.originalTimeoutRetryCount=(report.originalTimeoutRetryCount||0)+1;
     await new Promise(resolve=>setTimeout(resolve,ms));},
   });
  }
  async function record(collection,id,data,extra={}){
   const body={action:'managed/records',operation:'write',syncProtocol:2,collection,id,
    operationId:hash(SCHOOL+':'+collection+':'+id),expectedRecordRevision:'',data:{...data,schoolId:SCHOOL},edgeDeliveryVersion:1,...extra};
   let result=await originalRequest(body);
   // Person lifecycle may be owner-signed; otherwise require the exact
   // Cloudflare receipt and independent Drive verification for each person.
   const route=['teachers_directory','students_directory'].includes(collection)&&
     result.personLifecycleVersion===1?'person':'edge';
   if(route==='edge'&&result.delivery)result=await settle(result);
   requireCheck(verifiedRecordRoute(result,route));
   const replay=await originalRequest(body);
   requireCheck(replay.recordRevision===result.recordRevision&&verifiedRecordRoute(replay,route));
   const read=await call({action:'managed/records',operation:'read',syncProtocol:2,collection,id});
   const saved=read.records?.[id];
   requireCheck(saved?.schoolId===SCHOOL&&saved?._syncRevision===result.recordRevision&&saved?._syncOperationId===body.operationId);
   report.verifiedRoutes??=[];
   report.verifiedRoutes.push({collection,route:route==='person'?'signed-person-lifecycle-Drive':'Cloudflare-ACK-then-Drive'});
   if(collection==='documents')
    requireCheck(saved.fileId===data.fileId&&saved.contentHash===data.contentHash
      &&saved.documentKind===data.documentKind);
   report.checks.push({name:stage,status:'PASS'});return result;
  }
  // Test a real Cloudflare-backed collection BEFORE direct person writes.
  // The test is incomplete unless both this and protected person paths PASS.
  stage='calendar record Cloudflare acceptance and signed Google Drive readback';
  const calendar='CF_TEST_CALENDAR_'+run;
  await record('school_calendar',calendar,{title:'SYNTHETIC CLOUD DELIVERY TEST',syntheticTest:true});
  stage='teacher signed lifecycle, verified Drive write and exact replay';
  const teacher='CF_TEST_TEACHER_'+run;
  await record('teachers_directory',teacher,{teacherId:teacher,name:'SYNTHETIC CLOUD DELIVERY TEST',role:'teacher'});
  // Valid bounded synthetic PDF container. Original provider bytes are retained,
  // not a real student's report card or a generated template.
  const bytes=Buffer.alloc(768*1024,32);
  Buffer.from('%PDF-1.4\n% SYNTHETIC TEST SCHOOL ONLY\n').copy(bytes);
  bytes.write('%%EOF\n',bytes.length-6,'ascii');
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
  stage='exact permanent Drive byte readback';
  const file=await call({action:'managed/file/read',fileId});
  const fetched=Buffer.from(file.base64||'','base64');
  requireCheck(file.mime===meta.mime&&fetched.length===meta.sizeBytes
    &&fetched.equals(bytes)&&hash(fetched)===meta.sha256);
  report.bytesReadbackVerified=true;report.bytesWritten=meta.sizeBytes;report.sha256=meta.sha256;
  report.checks.push({name:stage,status:'PASS'});
  stage='ID card document metadata waits for verified real Drive file ID';
  await record('documents','CF_TEST_IDCARD_'+run,{documentKind:'idCard',ownerRole:'teacher',teacherId:teacher,personId:teacher,documentRevision:hash(run),contentHash:meta.sha256,fileId,fileUrl:'https://drive.google.com/file/d/'+fileId+'/view',mimeType:meta.mime,uploadedAt:1793232000000},{expectedRevision:''});
  stage='second independent signed Drive read after metadata commit';
  const second=await call({action:'managed/file/read',fileId});
  const reloaded=Buffer.from(second.base64||'','base64');
  requireCheck(second.schoolId===SCHOOL&&second.mime===meta.mime
    &&reloaded.length===meta.sizeBytes&&hash(reloaded)===meta.sha256
    &&reloaded.equals(bytes));
  report.checks.push({name:stage,status:'PASS'});
  stage='another school cannot poll the accepted receipt';
  const foreign=await request(ENDPOINT,{action:'managed/cloudflare/operation',schoolId:'vs-'+'0'.repeat(32),lane:'records',id:hash('foreign')},token);requireCheck(foreign.status===403);
  report.checks.push({name:stage,status:'PASS'});
  stage='staff signed lifecycle, verified Drive write and exact replay';
  const staff='CF_TEST_STAFF_'+run;
  await record('teachers_directory',staff,{teacherId:staff,name:'SYNTHETIC CLOUD DELIVERY TEST',role:'staff'});

  // Additional isolated TEST coverage is deliberately opt-in. Never write
  // production-school data, process user photos, or delete retained fixtures.
  if(env.VS_CF_EXTENDED_LANES==='1'){
   report.extendedCoverage={scope:'synthetic isolated TEST only',verifiedCollections:[],
    originalPhotoBytesVerified:false,completeProductionBackupCertified:false};
   stage='valid immutable TEST PNG before Cloudflare upload';
   const photoBytes=Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAGAAAACACAIAAAB7vvvtAAABFElEQVR4nO3QQRHAIADAMMDNNKEMt1Ow65M9EgW9zmefwbd1O+DvDAoGBYOCQcGgYFAwKBgUDAoGBYOCQcGgYFAwKBgUDAoGBYOCQcGgYFAwKBgUDAoGBYOCQcGgYFAwKBgUDAoGBYOCQcGgYFAwKBgUDAoGBYOCQcGgYFAwKBgUDAoGBYOCQcGgYFAwKBgUDAoGBYOCQcGgYFAwKBgUDAoGBYOCQcGgYFAwKBgUDAoGBYOCQcGgYFAwKBgUDAoGBYOCQcGgYFAwKBgUDAoGBYOCQcGgYFAwKBgUDAoGBYOCQcGgYFAwKBgUDAoGBYOCQcGgYFAwKBgUDAoGBYOCQcGgYFAwKBgUDAoGBYOCQcGgYFB4Abn9Ah0R5M54AAAAAElFTkSuQmCC','base64');
   const photoHash=hash(photoBytes);
   requireCheck(photoBytes.length===333&&photoHash==='a9edee8c3322156b7610e74023d0ee8ea50c692a502c074064e3454673c5fdaa');
   stage='synthetic PNG Cloudflare-to-Google Drive upload';
   const photoKey='cf_test_photo_'+run;
   const photoMeta={action:'managed/file/upload/resumable',uploadKey:photoKey,
    name:photoKey+'.png',mime:'image/png',sha256:photoHash,sizeBytes:photoBytes.length,edgeDeliveryVersion:1};
   let photoProgress=await call({...photoMeta,operation:'begin'});
   if(photoProgress.delivery)photoProgress=await settle(photoProgress);
   if(!photoProgress.committed){
    const offset=photoProgress.offset;
    requireCheck(Number.isSafeInteger(offset)&&offset>=0&&offset<photoBytes.length);
    const part=photoBytes.subarray(offset);
    photoProgress=await call({...photoMeta,operation:'part',offset,
     base64:part.toString('base64'),chunkSha256:hash(part)});
    if(photoProgress.delivery)photoProgress=await settle(photoProgress);
   }
   requireCheck(photoProgress.committed===true&&photoProgress.sha256===photoHash&&
    photoProgress.offset===photoBytes.length&&photoProgress.sizeBytes===photoBytes.length&&
    /^[A-Za-z0-9_-]{1,200}$/.test(photoProgress.fileId||''));
   const photoFileId=photoProgress.fileId;
   stage='independent original PNG Drive bytes and hash readback';
   const photoRead=await call({action:'managed/file/read',fileId:photoFileId});
   const photoSaved=Buffer.from(photoRead.base64||'','base64');
   requireCheck(photoRead.mime==='image/png'&&photoSaved.length===photoBytes.length&&
     photoSaved.equals(photoBytes)&&hash(photoSaved)===photoHash);
   report.extendedCoverage.originalPhotoBytesVerified=true;
   report.extendedCoverage.photoBytes=photoBytes.length;
   report.checks.push({name:stage,status:'PASS'});
   // Use one run-scoped original and exact CAS receipts. All references are
   // to this synthetic TEST school, never to real students or finances.
   const student='CF_TEST_STUDENT_'+run;
   stage='student profile with verified photo owner Google Drive readback';
   await record('students_directory',student,{studentId:student,
    mobileStableId:'p-'+hash('synthetic-student:'+run).slice(0,32),
    name:'SYNTHETIC CLOUD DELIVERY TEST',parentName:'SYNTHETIC',
    class:'CF_TEST',studentClass:'CF_TEST',rollNo:String(parseInt(hash(run).slice(0,7),16)),
    photoFileId,photoUrl:'https://drive.google.com/file/d/'+photoFileId+'/view'});
   report.extendedCoverage.verifiedCollections.push('students_directory');
   const fee='CF_TEST_FEE_'+run;
   stage='fee payment record original Cloudflare ACK and signed Google Drive readback';
   await record('fee_payments',fee,{paymentId:fee,receiptNo:fee,studentId:student,
    studentName:'SYNTHETIC CLOUD DELIVERY TEST',amount:0,totalPaid:0,
    paymentMode:'synthetic_test',status:'test_only'});
   report.extendedCoverage.verifiedCollections.push('fee_payments');
   stage='fee ledger record Cloudflare ACK and signed Google Drive readback';
   await record('fee_ledger','CF_TEST_LEDGER_'+run,{
    studentId:student,amount:0,paid:0,balance:0,source:'synthetic_cloud_delivery_test'});
   report.extendedCoverage.verifiedCollections.push('fee_ledger');
   stage='student attendance record Cloudflare ACK and signed Google Drive readback';
   await record('attendance_records','CF_TEST_ATTENDANCE_'+run,{
    studentId:student,date:'2026-11-19',status:'present',source:'synthetic_cloud_delivery_test'});
   report.extendedCoverage.verifiedCollections.push('attendance_records');
   stage='teacher attendance record Cloudflare ACK and signed Google Drive readback';
   await record('teacher_attendance','CF_TEST_TEACHER_ATTENDANCE_'+run,{
    teacherId:teacher,date:'2026-11-19',status:'present',source:'synthetic_cloud_delivery_test'});
   report.extendedCoverage.verifiedCollections.push('teacher_attendance');
   stage='exam result record Cloudflare ACK and signed Google Drive readback';
   await record('exam_results','CF_TEST_EXAM_'+run,{
    studentId:student,subject:'SYNTHETIC',marks:0,maxMarks:1,
    source:'synthetic_cloud_delivery_test'});
   report.extendedCoverage.verifiedCollections.push('exam_results');
   // This evidence does not include encrypted attendance queue, every school
   // Script instance or every production file; never claim all data complete.
   report.extendedCoverage.legacyAndProductionLanesUnverified=true;
   report.retainedExtendedFixtures={student,photoFileId,photoSha256:photoHash,
    fee,collections:report.extendedCoverage.verifiedCollections};
  }
  report.status='PASS';report.retainedFixtures={teacher,staff,calendar,document:'CF_TEST_IDCARD_'+run,fileId,sha256:meta.sha256};
 }catch(_){report.status='FAIL';report.failedStage=stage;}
 return report;
}
if(require.main===module)acceptance().then(report=>{
 fs.mkdirSync('build/cloud-prerequisites',{recursive:true});
 fs.writeFileSync('build/cloud-prerequisites/cloudflare-delivery.json',JSON.stringify(report,null,2));
 console.log(JSON.stringify(report));if(report.status!=='PASS')process.exitCode=1;
});
module.exports={acceptance,verifiedRecordRoute,retryOriginalTimeout,SCHOOL,ENDPOINT,LOGIN};
