'use strict';
// Exact-PR-source Firestore provider acceptance. TEST-only synthetic paths.
// Does NOT claim live Google Drive or Cloudflare end-to-end verification.
const assert=require('node:assert/strict');
const path=require('node:path');
const {createRequire}=require('node:module');
const {randomBytes}=require('node:crypto');
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d';
const PROJECT='saarthi-ai-df12b';
const BRANCH='refs/heads/fix/delete-everywhere-ack-firebase-20261106';
const COLLECTIONS=['students_directory','documents','fee_payments'];
const report={test:'PR236-exact-source-provider',status:'PENDING',scope:'Isolated TEST synthetic Firestore documents',driveAck:'SIMULATED_BOUNDARY_ONLY',deleted:0,replayDeleted:null,readbackAbsent:0,foreignGenerationRetained:false};
async function main(){
 if(process.env.GITHUB_ACTIONS!=='true'||process.env.GITHUB_REF!==BRANCH||
    process.env.VS_LIVE_FIRESTORE_ACCEPTANCE!=='isolated-test-synthetic-only')
   throw Error('Explicit isolated TEST GitHub branch authorization required');
 const raw=process.env.SCHOOL_SERVICE_ACCOUNT_JSON||'';
 if(raw.length<200||raw.length>12000)throw Error('TEST Firebase credential unavailable');
 let key;try{key=JSON.parse(raw)}catch{throw Error('Invalid TEST Firebase credential JSON')}
 if(key.type!=='service_account'||key.project_id!==PROJECT||
    typeof key.client_email!=='string'||!key.client_email.endsWith('@'+PROJECT+'.iam.gserviceaccount.com')||
    typeof key.private_key!=='string'||!key.private_key.includes('BEGIN PRIVATE KEY'))
   throw Error('Unexpected Firebase project or service-account credential');
 const requireFunctions=createRequire(path.resolve(__dirname,'../../functions/package.json'));
 const {initializeApp,cert,deleteApp}=requireFunctions('firebase-admin/app');
 const {getFirestore}=requireFunctions('firebase-admin/firestore');
 const {createDeleteEverywhere}=requireFunctions('./delete-everywhere');
 const app=initializeApp({credential:cert(key),projectId:PROJECT},
   'pr236-exact-source-firebase-'+process.env.GITHUB_RUN_ID);
 const db=getFirestore(app);
 const unique=String(process.env.GITHUB_RUN_ID||'')+'_'+String(process.env.GITHUB_RUN_ATTEMPT||'1')+'_'+randomBytes(5).toString('hex');
 if(!/^\d+_\d+_[a-f0-9]{10}$/.test(unique))throw Error('Bad isolated CI operation identity');
 const id='TEST_PR236_FIRESTORE_'+unique,gen='p-TEST-PR236-'+unique;
 const sourceRevision='pr236-old-'+unique,finalRevision='pr236-drive-'+unique,operationId='pr236-op-'+unique;
 const targets=COLLECTIONS.map((collection,i)=>({
  collection,id:id+'_'+i,sourceRevision,revision:i===0?finalRevision:'pr236-deleted-'+i+'-'+unique,generation:gen
 }));
 const refs=targets.map(t=>db.doc('schools/'+SCHOOL+'/'+t.collection+'/'+t.id));
 const wrong=db.doc('schools/'+SCHOOL+'/documents/'+id+'_generation_guard');
 const request={action:'managed_records',deleteEverywhereVersion:1,operation:'delete',
   collection:targets[0].collection,id:targets[0].id,operationId,syncProtocol:2};
 const proof={success:true,schoolId:SCHOOL,syncProtocol:2,deleteEverywhereVersion:1,
   driveDeletionComplete:true,recordRevision:finalRevision,deletionTargets:targets,
   record:{schoolId:SCHOOL,_syncDeleted:true,_syncRevision:finalRevision,
     _syncOperationId:operationId,_syncErasePlan:{complete:true,targets}}};
 // This fixture models the signed Google plan only to isolate actual Firestore permissions,
 // atomic transactions, readback and no-delete-on-generation-conflict in PR #236.
 const cleanup=createDeleteEverywhere({db});
 try{
  for(const ref of refs){
   await ref.create({schoolId:SCHOOL,personId:gen,_syncRevision:sourceRevision,
      syntheticTest:true,syntheticDeleteAcceptance:true,source:'PR236_SOURCE_PROVIDER_TEST'});
   assert.equal((await ref.get()).exists,true,'TEST Firebase create/readback');
  }
  const completed=await cleanup.finish(SCHOOL,request,proof);
  assert.equal(completed.firebaseDeletionComplete,true);
  assert.equal(completed.firebaseDeletedRecords,targets.length);
  report.deleted=completed.firebaseDeletedRecords;
  for(const ref of refs){assert.equal((await ref.get()).exists,false);report.readbackAbsent++;}
  const again=await cleanup.finish(SCHOOL,request,proof);
  assert.equal(again.firebaseDeletedRecords,0);
  report.replayDeleted=again.firebaseDeletedRecords;
  await wrong.create({schoolId:SCHOOL,personId:gen+'-replacement',_syncRevision:sourceRevision,
      syntheticTest:true,syntheticDeleteAcceptance:true,source:'PR236_SOURCE_PROVIDER_TEST'});
  const deniedTargets=[{collection:'documents',id:id+'_generation_guard',
    sourceRevision,revision:'wrong-generation-tombstone-'+unique,generation:gen}];
  const deniedRequest={...request,collection:'documents',id:id+'_generation_guard'};
  const deniedProof={...proof,recordRevision:deniedTargets[0].revision,
     deletionTargets:deniedTargets,
     record:{...proof.record,_syncRevision:deniedTargets[0].revision,
       _syncErasePlan:{complete:true,targets:deniedTargets}}};
  await assert.rejects(cleanup.finish(SCHOOL,deniedRequest,deniedProof),e=>
      e?.code==='DELETE_EVERYWHERE_GENERATION_CONFLICT');
  report.foreignGenerationRetained=(await wrong.get()).exists;
  assert.equal(report.foreignGenerationRetained,true);
  report.status='PASS_REAL_FIRESTORE_EXACT_PR_SOURCE';
 }finally{
  // Only created synthetic IDs and only the identical test owner may be cleaned up.
  for(const ref of [...refs,wrong]){
   const snapshot=await ref.get();
   if(!snapshot.exists)continue;
   const row=snapshot.data();
   if(row?.schoolId!==SCHOOL||row?.syntheticDeleteAcceptance!==true||
      row?.source!=='PR236_SOURCE_PROVIDER_TEST'||
      ![gen,gen+'-replacement'].includes(row.personId))
     throw Error('Unexpected TEST document; refused fallback cleanup');
   await ref.delete();
   assert.equal((await ref.get()).exists,false,'Synthetic cleanup readback');
  }
  await deleteApp(app);
 }
}
main().catch(e=>{report.status='FAIL';report.blocker=String(e?.code||e?.message||'TEST_FAILURE').slice(0,160);process.exitCode=1})
 .finally(()=>{console.log('PR236_REAL_FIRESTORE_RESULT '+JSON.stringify(report));});
