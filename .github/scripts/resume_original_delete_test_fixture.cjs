'use strict';
// Resumes ONLY the exact synthetic delete created in Run 42222529247.
// Reuses its original operationId and expected revision; no new student,
// media, fee, school, licence or generation may be created.
const crypto=require('node:crypto'),fs=require('node:fs');
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d';
const STUDENT='TEST_DELETE_42222529247_8ce61a39';
const DOCUMENT='TEST_DELETE_CARD_42222529247_8ce61a39';
const FEE='TEST_DELETE_FEE_42222529247_8ce61a39';
const PDF='1ZMaJR3NMtT1G5Uy0HJPtfKvHPac6wgnj';
const OP='980a80a2ed52f3a498c4410209225e95';
const ORIGINAL='da3ac36d-a064-469b-877f-774f2442d1ae';
const API='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const LOGIN='https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const sha=s=>crypto.createHash('sha256').update(s).digest('hex');
const GENERATION='p-'+sha('test-delete/'+STUDENT);
const RECEIPT=sha(JSON.stringify([SCHOOL,'managed_records',['students_directory',STUDENT,OP]]));
const report={scope:'TEST-only original pending delete, no new fixture',status:'PENDING',originalImmutableOperation:true,attempts:0,stage:'init'};
async function send(url,body,token){
 const r=await fetch(url,{method:'POST',headers:{'content-type':'application/json',...(token?{authorization:'Bearer '+token}:{})},
 body:JSON.stringify(body),signal:AbortSignal.timeout(110000)});
 let data={};try{data=await r.json()}catch{}
 return {status:r.status,data};
}
async function main(){
 if(process.env.GITHUB_ACTIONS!=='true'||process.env.GITHUB_REF!=='refs/heads/feature/smart-sync-3'||
  process.env.VS_RESUME_ORIGINAL_TEST_DELETE!==STUDENT)throw Error('Original TEST-only opt-in required');
 const health=await fetch(API+'/healthz',{signal:AbortSignal.timeout(20000)}).then(r=>r.json());
 if(health.ready!==true||health.runtimeCommit!=='eec9d8f9348b917f6d7845c8d3c31fa040ccff03')
  throw Error('TEST runtime did not match immutable source');
 const login=await send(LOGIN,{email:process.env.VS_TEST_LOGIN_EMAIL,password:process.env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});
 if(login.status!==200||!login.data.idToken)throw Error('TEST owner auth failed');
 const token=login.data.idToken;
 const call=body=>send(API,{...body,schoolId:SCHOOL},token);
 async function read(collection,id){
  const r=await call({action:'managed/records',operation:'read',collection,id,syncProtocol:2});
  if(r.status!==200||r.data.success!==true||r.data.schoolId!==SCHOOL||r.data.pointRead!==true)
    throw Error('TEST point read failed for '+collection);
  return r.data.records?.[id];
 }
 const parent=await read('students_directory',STUDENT);
 const plan=parent?._syncErasePlan;
 if(parent?.schoolId!==SCHOOL||parent._syncDeleted!==true||parent._syncOperationId!==OP||
    plan?.version!==1||!Array.isArray(plan.targets)||plan.targets.length!==5||
    !Array.isArray(plan.files)||plan.files.length!==1||plan.files[0]!==PDF)
  throw Error('Unexpected original pending TEST plan, no mutation allowed');
 const allow=new Set(['students_directory','documents','fee_payments','mobile_users','mobile_sessions','mobile_complaints']);
 if(plan.targets.some(t=>!allow.has(t.collection)||(t.generation&&t.generation!==GENERATION))||
    plan.targets[0].collection!=='students_directory'||plan.targets[0].id!==STUDENT)
  throw Error('Original TEST plan contains unexpected target');
 report.before={targetsProcessed:plan.cursor,targetsTotal:plan.targets.length,
  filesProcessed:plan.fileCursor,filesTotal:plan.files.length,
  archivesRedacted:plan.archiveCursor||0,archivesTotal:plan.archiveIds?.length??null};
 console.log('ORIGINAL_DELETE_BEFORE '+JSON.stringify(report.before));
 for(let retry=1;retry<=4;retry++){
  report.attempts=retry;
  const r=await call({action:'managed/records',operation:'delete',collection:'students_directory',
    id:STUDENT,syncProtocol:2,operationId:OP,expectedRecordRevision:ORIGINAL,
    deletedStudentGeneration:GENERATION,deleteEverywhereVersion:1});
  if(r.status===200&&r.data.success===true){
   if(r.data.driveDeletionComplete!==true||r.data.firebaseDeletionComplete!==true||
      !r.data.deletedFileIds?.includes(PDF))throw Error('Delete returned unverified final ACK');
   report.driveVerified=true;report.firebaseVerified=true;break;
  }
  if(r.data.code!=='SCRIPT_DELETE_EVERYWHERE_PENDING')
   throw Error('Original delete blocked by '+(r.data.code||'unexpected provider error'));
  console.log('ORIGINAL_DELETE_RETRY '+JSON.stringify({attempt:retry,code:r.data.code}));
 }
 if(report.driveVerified!==true||report.firebaseVerified!==true)
  throw Error('Original delete still retained after bounded exact retries');
 const after=await read('students_directory',STUDENT);
 const doc=await read('documents',DOCUMENT),fee=await read('fee_payments',FEE);
 if(after?._syncDeleted!==true||after?._syncErasePlan?.complete!==true||
    doc?._syncDeleted!==true||fee?._syncDeleted!==true)
  throw Error('Original and dependent Google tombstones not verified');
 report.googleTombstonesVerified=true;
 const file=await call({action:'managed/file/read',fileId:PDF});
 if(file.status===200&&file.data.success===true&&file.data.base64)throw Error('Original PDF still readable');
 report.permanentPDFUnavailable=true;
 const edge=await call({action:'managed/cloudflare/operation',lane:'records',id:RECEIPT,waitMillis:18000});
 report.originalEdgeReceiptVerified=edge.status===200&&edge.data.driveState==='verified'&&
   edge.data.firebaseDeletionComplete===true;
 report.edgeState=report.originalEdgeReceiptVerified?'verified':edge.data.deliveryStatus?.state||edge.data.code||'pending';
 report.status=report.originalEdgeReceiptVerified?'PASS':'DRIVE_AND_FIREBASE_VERIFIED_EDGE_PENDING';
}
main().catch(err=>{report.status='FAIL';report.blocker=String(err.message).slice(0,140);process.exitCode=1})
.finally(()=>{fs.mkdirSync('build/cloud-prerequisites',{recursive:true});fs.writeFileSync('build/cloud-prerequisites/original-test-delete-resume.json',JSON.stringify(report,null,2));
 console.log('ORIGINAL_DELETE_RECONCILIATION '+JSON.stringify(report));});
