'use strict';
// Resumes ONLY the exact synthetic delete created in Run 42222529247.
// Reuses its original operationId and expected revision; NO new Google Script
// student/media/fee, school, licence or generation. A Firebase-only synthetic
// mirror is recreated ONLY at three exact previously deleted TEST paths, then
// erased by the existing Render Delete Everywhere owner and directly read back.
const crypto=require('node:crypto'),fs=require('node:fs');
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d';
const STUDENT='TEST_DELETE_42222529247_8ce61a39';
const DOCUMENT='TEST_DELETE_CARD_42222529247_8ce61a39';
const FEE='TEST_DELETE_FEE_42222529247_8ce61a39';
const PDF='1ZMaJR3NMtT1G5Uy0HJPtfKvHPac6wgnj';
const OP='980a80a2ed52f3a498c4410209225e95';
const ORIGINAL='da3ac36d-a064-469b-877f-774f2442d1ae';
const API='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const RUNTIME='e522a421990462f91beff41cf75d93672ad7d238';
const PROJECT='saarthi-ai-df12b';
const LOGIN='https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const sha=s=>crypto.createHash('sha256').update(s).digest('hex');
const GENERATION='p-'+sha('test-delete/'+STUDENT);
const RECEIPT=sha(JSON.stringify([SCHOOL,'managed_records',['students_directory',STUDENT,OP]]));
const report={scope:'TEST-only existing deletion and direct Firestore absence proof; synthetic mirrors only',status:'PENDING',originalImmutableOperation:true,attempts:0,stage:'init',firestoreReadbackVerified:false};
function account(){
 let v;try{v=JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT_JSON||'{}')}catch{throw Error('TEST administrative credential JSON invalid')}
 if(v.project_id!==PROJECT||v.type!=='service_account'||!v.client_email?.endsWith('@'+PROJECT+'.iam.gserviceaccount.com')||!v.private_key)throw Error('TEST Firestore admin credentials not scoped to expected Firebase project');
 return v;
}
async function firestore() {
 const fromFunctions=require('node:module').createRequire(require('node:path').resolve(__dirname,'../../functions/package.json'));
 const {initializeApp,cert,deleteApp}=fromFunctions('firebase-admin/app');
 const {getFirestore}=fromFunctions('firebase-admin/firestore');
 const app=initializeApp({credential:cert(account()),projectId:PROJECT},'verify-original-delete-'+process.env.GITHUB_RUN_ID);
 return {db:getFirestore(app),close:()=>deleteApp(app)};
}
async function plantExactSyntheticMirror(db,plan){
 // No creation of new GS/Drive records and NO writes to real student keys.
 // Every target must exist in the immutable, same-school sealed original plan.
 if(plan.complete!==true||plan.archivesComplete!==true||plan.cursor!==plan.targets.length||plan.fileCursor!==plan.files.length)
  throw Error('Provider deletion plan is not fully verified: do not seed Firebase');
 const probe=[
  {collection:'students_directory',id:STUDENT},
  {collection:'documents',id:DOCUMENT},
  {collection:'fee_payments',id:FEE},
 ];
 let seeded=0,alreadyThere=0;
 for(const {collection,id} of probe){
  const target=plan.targets.find(t=>t.collection===collection&&t.id===id);
  if(!target||!target.sourceRevision||target.generation!==GENERATION)
   throw Error('Original synthetic Firebase target generation/revision not proven');
  const ref=db.doc('schools/'+SCHOOL+'/'+collection+'/'+id);
  const before=await ref.get();
  if(before.exists){
   const row=before.data();
   if(row.schoolId!==SCHOOL||row.syntheticDeleteAcceptance!==true||
      (row.mobileStableId||row.personId||row._syncDeletedOwner)!==GENERATION||
      row._syncRevision!==target.sourceRevision)
    throw Error('Unexpected existing Firebase record: refuse to delete or overwrite');
   alreadyThere++;
  }else{
   const payload={schoolId:SCHOOL,_syncRevision:target.sourceRevision,
    syntheticTest:true,syntheticDeleteAcceptance:true,
    ...(collection==='students_directory'?{mobileStableId:GENERATION,name:'ORIGINAL SYNTHETIC TEST DELETE'}:{personId:GENERATION})};
   await ref.create(payload);
   seeded++;
  }
  const now=await ref.get();
  if(!now.exists||now.data().syntheticDeleteAcceptance!==true||now.data().schoolId!==SCHOOL)
   throw Error('Synthetic Firebase pre-delete readback missing');
 }
 report.firebaseBefore={checked:probe.length,seeded,existingSafeMirrors:alreadyThere,allPresent:true};
 return probe;
}
async function readbackAbsent(db,probe){
 let missing=0;
 for(const {collection,id} of probe){
  const snapshot=await db.doc('schools/'+SCHOOL+'/'+collection+'/'+id).get();
  if(snapshot.exists)throw Error('TEST Firestore record still exists after final signed Delete Everywhere ACK');
  missing++;
 }
 report.firebaseAfter={checked:probe.length,absent:missing};
 report.firestoreReadbackVerified=missing===probe.length;
}
async function send(url,body,token){
 const r=await fetch(url,{method:'POST',headers:{'content-type':'application/json',...(token?{authorization:'Bearer '+token}:{})},
 body:JSON.stringify(body),signal:AbortSignal.timeout(110000)});
 let data={};try{data=await r.json()}catch{}
 return {status:r.status,data};
}
async function main(){
 if(process.env.GITHUB_ACTIONS!=='true'||process.env.GITHUB_REF!=='refs/heads/feature/smart-sync-3'||
  process.env.VS_RESUME_ORIGINAL_TEST_DELETE!==STUDENT)throw Error('Original TEST-only opt-in required');
 await require('./test_runtime_identity.cjs').waitForRuntime(RUNTIME,{attempts:12});
 const health=await fetch(API+'/healthz',{signal:AbortSignal.timeout(20000)}).then(r=>r.json());
 if(health.ready!==true||health.runtimeCommit!==RUNTIME)
  throw Error('TEST runtime did not match immutable source');
 if(health.adminCredentialFingerprint!==sha(account().client_email))
  throw Error('Render and GitHub TEST Firebase Admin service-account identities differ; refuse deletion');
 report.firebaseCredentialIdentityMatch=true;
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
 const firebase=await firestore();
 try{
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
 // Firestore proof must include positive *before* and negative *after* reads.
 // These same three TEST paths are reused on a retry, never duplicated.
 const probe=await plantExactSyntheticMirror(firebase.db,plan);
 report.stage='predelete-readback-verified';
 console.log('ORIGINAL_DELETE_BEFORE '+JSON.stringify(report.before));
 // Reopen the already-existing needsAttention receipt exactly once. This
 // never calls enqueue with a new ID and the Worker rechecks the stored payload.
 const current=await call({action:'managed/cloudflare/operation',lane:'records',id:RECEIPT,waitMillis:18000});
 let final=current.status===200&&current.data.success===true&&current.data.driveState==='verified'?current.data:null;
 if(!final&&current.status===200&&current.data.success===true&&current.data.driveState==='pending'){
  report.originalReceiptAlreadyQueued=true;
 }else if(!final&&current.status===409&&current.data.code==='DELETE_EVERYWHERE_ACK_UNVERIFIED'){
  const reopened=await call({action:'managed/cloudflare/retry-delete',lane:'records',
   id:RECEIPT,operationId:OP,recordId:STUDENT,
   expectedRecordRevision:ORIGINAL,deletedStudentGeneration:GENERATION});
  if(reopened.status!==200||reopened.data.success!==true||reopened.data.retried!==true)
   throw Error('Original Cloudflare review retry blocked HTTP '+reopened.status+' '+(reopened.data.code||'UNVERIFIED'));
  report.originalReceiptReopened=true;
 }else if(!final)throw Error('Original Cloudflare receipt blocked HTTP '+current.status+' '+(current.data.code||'UNVERIFIED'));
 for(let retry=1;retry<=12;retry++){
  report.attempts=retry;
  const edge=await call({action:'managed/cloudflare/operation',lane:'records',id:RECEIPT,waitMillis:18000});
  if(edge.status===200&&edge.data.success===true&&edge.data.driveState==='verified'){
   final=edge.data;break;
  }
  if(edge.status===200&&edge.data.success===true&&edge.data.driveState==='pending'){
   console.log('ORIGINAL_DELETE_EDGE_PENDING '+JSON.stringify({attempt:retry,state:edge.data.deliveryStatus?.state||'pending',failureCode:edge.data.deliveryStatus?.failureCode||null}));
   continue;
  }
  throw Error('Original Cloudflare receipt blocked HTTP '+edge.status+' '+(edge.data.code||'UNVERIFIED'));
 }
 if(!final)throw Error('Original Delete Everywhere receipt did not reach a verified Drive+Firebase ACK');
 if(final.driveDeletionComplete!==true||final.firebaseDeletionComplete!==true||
    !final.deletedFileIds?.includes(PDF))throw Error('Delete returned unverified final ACK');
 report.driveVerified=true;report.firebaseVerified=true;
 report.firebaseDeletedByRender=final.firebaseDeletedRecords;
 if(!Number.isInteger(report.firebaseDeletedByRender)||report.firebaseDeletedByRender<probe.length)
  throw Error('Render did not report all three real Firebase mirror deletes');
 await readbackAbsent(firebase.db,probe);

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
 report.status=report.originalEdgeReceiptVerified?'PASS':'PASS_FIREBASE_READBACK_EDGE_PENDING';
 }finally{await firebase.close();}
}
main().catch(err=>{report.status='FAIL';report.blocker=String(err.message).slice(0,140);process.exitCode=1})
.finally(()=>{fs.mkdirSync('build/cloud-prerequisites',{recursive:true});fs.writeFileSync('build/cloud-prerequisites/original-test-delete-resume.json',JSON.stringify(report,null,2));
 console.log('ORIGINAL_DELETE_RECONCILIATION '+JSON.stringify(report));});
