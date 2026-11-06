'use strict';
// Deletes only the three exact synthetic Firebase mirror documents left by the
// failed TEST Render credential comparison. This is an Admin SDK cleanup
// fallback, NOT proof that the Render Delete Everywhere path succeeded.
const crypto=require('node:crypto'),fs=require('node:fs');
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d';
const STUDENT='TEST_DELETE_42222529247_8ce61a39';
const DOCUMENT='TEST_DELETE_CARD_42222529247_8ce61a39';
const FEE='TEST_DELETE_FEE_42222529247_8ce61a39';
const OP='980a80a2ed52f3a498c4410209225e95';
const ORIGINAL='da3ac36d-a064-469b-877f-774f2442d1ae';
const API='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const RUNTIME='f275669d9a8769b0dcfb8a2f60b5fef2c5a07982';
const PROJECT='saarthi-ai-df12b';
const LOGIN='https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const sha=s=>crypto.createHash('sha256').update(s).digest('hex');
const GENERATION='p-'+sha('test-delete/'+STUDENT);
const report={scope:'TEST-only direct Firebase Admin SDK cleanup; exactly three synthetic mirrors',status:'PENDING',renderDeleteFlowVerified:false,readbackVerified:false,deleted:0,alreadyAbsent:0};
function account(){
 let v;try{v=JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT_JSON||'{}')}catch{throw Error('TEST administrative credential JSON invalid')}
 if(v.project_id!==PROJECT||v.type!=='service_account'||!v.client_email?.endsWith('@'+PROJECT+'.iam.gserviceaccount.com')||!v.private_key)
  throw Error('TEST Firebase Admin credential is not scoped to the expected project');
 return v;
}
async function post(url,body,token){
 const response=await fetch(url,{method:'POST',headers:{'content-type':'application/json',...(token?{authorization:'Bearer '+token}:{})},
  body:JSON.stringify(body),signal:AbortSignal.timeout(110000)});
 let data={};try{data=await response.json()}catch{}
 return {status:response.status,data};
}
async function main(){
 if(process.env.GITHUB_ACTIONS!=='true'||process.env.GITHUB_REF!=='refs/heads/feature/smart-sync-3'||
   process.env.VS_CLEANUP_SYNTHETIC_TEST_FIRESTORE!==STUDENT)
  throw Error('Explicit isolated TEST cleanup opt-in required');
 const health=await fetch(API+'/healthz',{signal:AbortSignal.timeout(20000)}).then(r=>r.json());
 if(health.ready!==true||health.runtimeCommit!==RUNTIME)throw Error('TEST runtime identity mismatch; refuse cleanup');
 const credentialHash=sha(account().client_email);
 report.renderCredentialMismatch=health.adminCredentialFingerprint!==credentialHash;
 if(!report.renderCredentialMismatch)throw Error('Render credential now matches CI; use the product Delete Everywhere path instead');
 const login=await post(LOGIN,{email:process.env.VS_TEST_LOGIN_EMAIL,password:process.env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});
 if(login.status!==200||!login.data.idToken)throw Error('TEST owner authentication failed');
 const token=login.data.idToken;
 const read=async(collection,id)=>{
  const result=await post(API,{action:'managed/records',operation:'read',collection,id,syncProtocol:2,schoolId:SCHOOL},token);
  if(result.status!==200||result.data.success!==true||result.data.schoolId!==SCHOOL||result.data.pointRead!==true)
   throw Error('TEST point read failed for '+collection);
  return result.data.records?.[id];
 };
 const parent=await read('students_directory',STUDENT);
 const plan=parent?._syncErasePlan;
 if(parent?.schoolId!==SCHOOL||parent._syncDeleted!==true||parent._syncOperationId!==OP||
   parent._syncRevision!==ORIGINAL||plan?.version!==1||plan.complete!==true||plan.archivesComplete!==true||
   !Array.isArray(plan.targets)||plan.targets.length!==5||plan.cursor!==plan.targets.length||
   !Array.isArray(plan.files)||plan.files.length!==1||plan.files[0]!== '1ZMaJR3NMtT1G5Uy0HJPtfKvHPac6wgnj'||
   plan.fileCursor!==plan.files.length)
  throw Error('Original sealed Google Delete plan is not complete; refuse direct cleanup');
 const targets=[
  {collection:'students_directory',id:STUDENT},
  {collection:'documents',id:DOCUMENT},
  {collection:'fee_payments',id:FEE}
 ];
 const refs=[];
 for(const item of targets){
  const target=plan.targets.find(t=>t.collection===item.collection&&t.id===item.id);
  if(!target||target.generation!==GENERATION||typeof target.sourceRevision!=='string'||!target.sourceRevision)
   throw Error('Original synthetic target revision/generation does not match; refuse cleanup');
  refs.push({...item,target,ref:null});
 }
 const fromFunctions=require('node:module').createRequire(require('node:path').resolve(__dirname,'../../functions/package.json'));
 const {initializeApp,cert,deleteApp}=fromFunctions('firebase-admin/app');
 const {getFirestore}=fromFunctions('firebase-admin/firestore');
 const app=initializeApp({credential:cert(account()),projectId:PROJECT},'cleanup-original-test-mirrors-'+process.env.GITHUB_RUN_ID);
 const db=getFirestore(app);
 try{
  for(const item of refs){
   const ref=db.doc('schools/'+SCHOOL+'/'+item.collection+'/'+item.id);
   item.ref=ref;
   const before=await ref.get();
   if(!before.exists){report.alreadyAbsent++;continue;}
   const row=before.data();
   if(row.schoolId!==SCHOOL||row.syntheticTest!==true||row.syntheticDeleteAcceptance!==true||
      (row.mobileStableId||row.personId||row._syncDeletedOwner)!==GENERATION||
      row._syncRevision!==item.target.sourceRevision)
    throw Error('Refusing to delete a non-synthetic or changed Firestore document');
  }
  for(const item of refs){
   const removed=await db.runTransaction(async tx=>{
    const snap=await tx.get(item.ref);
    if(!snap.exists)return false;
    const row=snap.data();
    if(row.schoolId!==SCHOOL||row.syntheticTest!==true||row.syntheticDeleteAcceptance!==true||
       (row.mobileStableId||row.personId||row._syncDeletedOwner)!==GENERATION||
       row._syncRevision!==item.target.sourceRevision)
     throw Error('Firestore synthetic document changed during guarded delete');
    tx.delete(item.ref);return true;
   });
   if(removed)report.deleted++;
   const after=await item.ref.get();
   if(after.exists)throw Error('Firestore negative readback failed for '+item.collection);
  }
  report.readbackVerified=true;
  report.checked=refs.length;
  report.absent=refs.length;
  report.status='PASS_DIRECT_ADMIN_CLEANUP_ONLY';
 }finally{await deleteApp(app);}
}
main().catch(error=>{report.status='FAIL';report.blocker=String(error.message).slice(0,180);process.exitCode=1})
.finally(()=>{fs.mkdirSync('build/cloud-prerequisites',{recursive:true});fs.writeFileSync('build/cloud-prerequisites/firebase-direct-cleanup.json',JSON.stringify(report,null,2));console.log('FIREBASE_DIRECT_CLEANUP_REPORT '+JSON.stringify(report));});
