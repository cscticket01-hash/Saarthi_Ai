'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),crypto=require('node:crypto');
const {waitForRuntime}=require('../../.github/scripts/test_runtime_identity.cjs');
const {retryExactDelete,verifiedNativeReceipt}=require('../../.github/scripts/native_person_receipt.cjs');
const school='vs-db8afb01a3be46a983c8284714d06e5d',project='saarthi-ai-df12b';
const endpoint='https://saarthi-sync-v2-test.onrender.com/school-cloud',wanted='bbbf71090699ae979d001bab591bcd01f8b7f087d6719f856d0a117aed77e95c';
const collections=['documents','students_directory','teachers_directory'];
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
const report={scope:'EXACT_TEST_UNFINISHED_DELETE_RECOVERY',status:'BLOCKED',productionAuthorized:false,forcedMarkersCleared:0};
async function post(url,body,token){const r=await fetch(url,{method:'POST',headers:{'content-type':'application/json',...(token?{authorization:'Bearer '+token}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(120000)});const data=await r.json();if(r.status!==200||data.success===false)throw Object.assign(Error('TEST request failed'),{http:r.status,code:data.code});return data;}
async function main(){
 assert.equal(process.env.GITHUB_ACTIONS,'true');assert.equal(process.env.GITHUB_REPOSITORY,'cscticket01-hash/Saarthi_Ai');assert.equal(process.env.GITHUB_REF,'refs/heads/test/atomic-person-live-20261109');
 await waitForRuntime(process.env.VS_EXPECTED_TEST_RUNTIME);
 const key=fs.readFileSync('lib/platform/platform_config.dart','utf8').match(/const platformApiKey = '([A-Za-z0-9_-]+)'/)[1];
 const login=await post('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key='+key,{email:process.env.VS_TEST_LOGIN_EMAIL,password:process.env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});assert.ok(login.idToken);
 const call=(action,body={})=>post(endpoint,{...body,action,schoolId:school},login.idToken);
 assert.equal((await call('managed/profile',{operation:'read'})).profile?.schoolName,'TEST Sync V2');
 const snapshot=await call('managed/records',{operation:'read',collection:'students_directory',syncProtocol:2});assert.ok(snapshot.records&&!snapshot.partial&&!snapshot.partialRecords&&!snapshot.pointRead);
 const matches=Object.entries(snapshot.records).filter(([id])=>hash(id)===wanted);assert.equal(matches.length,1);
 const [id,row]=matches[0];assert.equal(row.schoolId,school);assert.equal(row._syncDeleted,true);assert.equal(row._syncErasePlan?.version,1);assert.ok(Array.isArray(row._syncErasePlan.targets));
 const root=row._syncErasePlan.targets.find(t=>t.collection==='students_directory'&&t.id===id);assert.ok(root?.sourceRevision);assert.equal(root.generation,row._syncDeletedOwner);assert.match(row._syncOperationId,/^[A-Za-z0-9_-]{16,100}$/);
 report.initialDeleteComplete=row._syncErasePlan.complete===true;
 const external=JSON.parse(fs.readFileSync('.github/acceptance/test-preparation-no-live-writes.json','utf8'));
 assert.equal(external.schoolId,school);assert.equal(external.namespace,'978917e1b620408392a3c27b3ab783e6');assert.deepEqual(external.rows,[[0,0]]);assert.ok(Date.now()>=external.at&&Date.now()-external.at<15*60*1000,'Fresh connected Cloudflare SQL observation required');
 // This is an operator's independently observed no-write preparation proof,
 // never a user-data ACK, Google receipt, or a marker-clear authorization.
 report.externalNoLiveWritesObservedAt=external.at;
 const credentials=JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT_JSON||'{}');assert.equal(credentials.project_id,project);
 const req=require('node:module').createRequire(require('node:path').resolve('functions/package.json'));
 const {initializeApp,cert,deleteApp}=req('firebase-admin/app'),{getFirestore}=req('firebase-admin/firestore');
 const app=initializeApp({credential:cert(credentials),projectId:project},'exact-test-seed-recovery');
 try{
  const db=getFirestore(app),ref=db.doc('school_live_migrations/'+school),audit=db.doc('school_test_migration_repairs/'+school+'/epochs/'+process.env.GITHUB_RUN_ID);
  report.preparation=await db.runTransaction(async tx=>{
   const current=await tx.get(ref),previous=await tx.get(audit),state=current.data();assert.ok(state);
   if(previous.exists)return 'ALREADY_AUDITED';
   const group=state.nativeCohort;
   if(!group)return 'NO_PENDING_COHORT';
   assert.equal(group.state,'preparing');assert.deepEqual([...group.collections].sort(),collections);assert.ok(Date.now()-group.startedAt>=120000);
   assert.equal(Object.keys(state.inflight||{}).length,0);assert.equal(Object.keys(state.liveInflight||{}).length,0);
   const states={...state.collections};for(const name of collections){assert.equal(states[name]?.state,'preparing');states[name]={state:'legacy'};}
   tx.set(audit,{schoolId:school,at:Date.now(),actor:login.localId,reason:'ABORT_UNPUBLISHED_PREPARATION_TO_RESUME_EXACT_ORIGINAL_DELETE',before:state,cloudflareNoBusinessWrites:external,backupVerified:false});
   const next={...state,collections:states};delete next.nativeCohort;tx.set(ref,next);return 'AUDITED_NO_LIVE_WRITES_PREPARATION_ABORT';
  });
 }finally{await deleteApp(app);}
 const original={action:'managed/records',schoolId:school,edgeDeliveryVersion:1,operation:'delete',collection:'students_directory',id,syncProtocol:2,operationId:row._syncOperationId,expectedRecordRevision:root.sourceRevision,deletedStudentGeneration:row._syncDeletedOwner,deleteEverywhereVersion:1};
 const send=async body=>{const r=await fetch(endpoint,{method:'POST',headers:{'content-type':'application/json',authorization:'Bearer '+login.idToken},body:JSON.stringify(body),signal:AbortSignal.timeout(120000)});const data=await r.json();if(r.status!==200||data.success===false)throw Object.assign(Error('Original delete remains pending'),{http:r.status,status:r.status,code:data.code,retryAfterMs:data.retryAfterMs});return data;};
 const observe=require('./delete_plan_progress.cjs').observeDeletePlan(
  (collection,id)=>call('managed/records',{operation:'read',collection,id,syncProtocol:2}),school,
  progress=>{report.progress=progress;console.log('EXACT_TEST_DELETE_PROGRESS '+JSON.stringify(progress));});

 const ack=await retryExactDelete(original,send,{attempts:48,maxElapsedMs:40*60*1000,observeProgress:observe});assert.equal(verifiedNativeReceipt(ack,original,school),true);
 const current=(await call('managed/records',{operation:'read',collection:'students_directory',id,syncProtocol:2})).records[id];assert.equal(current._syncErasePlan.complete,true);assert.equal(current._syncErasePlan.archiveScan,undefined);assert.equal(current._syncOperationId,row._syncOperationId);assert.equal(current._syncRevision,row._syncRevision);
 report.status='PASS';report.sameOriginalOperation=true;report.signedDriveAndFirebaseCompletion=true;report.exhaustedIteratorStateRemovedByOriginalOwner=true;
}
main().catch(e=>{report.code=/^[A-Z0-9_]{2,100}$/.test(e.code||'')?e.code:'RECOVERY_BLOCKED';report.http=e.http||null;process.exitCode=1;}).finally(()=>{fs.mkdirSync('build/cloud-prerequisites',{recursive:true});fs.writeFileSync('build/cloud-prerequisites/preparing-delete-recovery.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));});
