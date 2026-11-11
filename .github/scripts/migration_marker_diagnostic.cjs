'use strict';
const assert=require('node:assert/strict'),{createHash}=require('node:crypto');
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d';
const PROJECT='saarthi-ai-df12b';
const digest=value=>createHash('sha256').update(String(value)).digest('hex');
function summarize(state){
 const markers=[];
 for(const map of ['inflight','liveInflight'])for(const [key,marker] of Object.entries(state[map]||{})){
  const binding=marker.operationBinding;
  markers.push({lane:map,markerHash:digest(key),
   collection:/^[a-z_]{1,100}$/.test(marker.collection||'')?marker.collection:'unbound',
   startedAt:Number.isSafeInteger(marker.startedAt)?marker.startedAt:null,
   activeAttempts:Number.isSafeInteger(marker.activeAttempts)?marker.activeAttempts:null,
   completedAttempt:marker.completedAttempt===true,
   schemaKeys:Object.keys(marker).filter(k=>/^[A-Za-z_]{1,60}$/.test(k)).sort(),
   bound:!!binding,
   ...(binding?{bindingSchoolMatches:binding.schoolId===SCHOOL,
    operation:['write','delete','patch'].includes(binding.operation)?binding.operation:'unverified',
    operationHash:digest(binding.operationId),recordHash:digest(binding.id),
    requestHash:/^[a-f0-9]{64}$/.test(binding.requestHash||'')?binding.requestHash:null}:{}),
  });
 }
 return {scope:'Single isolated TEST migration document; read-only, no record payloads or tokens',
  schoolId:SCHOOL,unsettledWrites:markers.length,markers};
}
async function main(){
 assert.equal(process.env.GITHUB_ACTIONS,'true');
 assert.equal(process.env.GITHUB_REPOSITORY,'cscticket01-hash/Saarthi_Ai');
 assert.equal(process.env.GITHUB_REF,'refs/heads/test/read-migration-markers-20261111');
 const account=JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT_JSON||'{}');
 assert.equal(account.type,'service_account');assert.equal(account.project_id,PROJECT);
 assert.ok(account.client_email?.endsWith('@'+PROJECT+'.iam.gserviceaccount.com'));
 const fromFunctions=require('node:module').createRequire(require('node:path').resolve(__dirname,'../../functions/package.json'));
 const {initializeApp,cert,deleteApp}=fromFunctions('firebase-admin/app');
 const {getFirestore}=fromFunctions('firebase-admin/firestore');
 const app=initializeApp({credential:cert(account),projectId:PROJECT},'test-migration-read-only');
 try{
  // One exact document GET. Never set, update, delete, query all schools,
  // download private records or persist the administrative credential.
  const snapshot=await getFirestore(app).doc('school_live_migrations/'+SCHOOL).get();
  assert.equal(snapshot.exists,true);
  console.log('TEST_MIGRATION_DIAGNOSTIC '+JSON.stringify(summarize(snapshot.data())));
 }finally{await deleteApp(app);}
}
if(require.main===module)main().catch(error=>{
 console.error('TEST_MIGRATION_DIAGNOSTIC_FAILED '+JSON.stringify({code:Number.isInteger(error.code)?error.code:'READ_UNAVAILABLE'}));process.exitCode=1;
});
module.exports={summarize,SCHOOL};
