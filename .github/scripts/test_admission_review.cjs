'use strict';
// Read exactly one isolated TEST migration document, its bound person-operation
// journals, and signed point readbacks. No writes, reconciliation or replay.
const fs=require('node:fs'),crypto=require('node:crypto'),path=require('node:path');
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d',PROJECT='saarthi-ai-df12b';
const API='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
async function post(url,body,token){
 const r=await fetch(url,{method:'POST',headers:{'content-type':'application/json',...(token?{authorization:'Bearer '+token}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(110000)});
 return {status:r.status,data:await r.json()};
}
async function main(){
 if(process.env.GITHUB_ACTIONS!=='true'||process.env.GITHUB_REPOSITORY!=='cscticket01-hash/Saarthi_Ai'||
    process.env.GITHUB_REF!=='refs/heads/test/admission-review-20261110')throw Error('Fixed TEST diagnostic branch required');
 const key=JSON.parse(process.env.SCHOOL_SERVICE_ACCOUNT_JSON||'{}');
 if(key.project_id!==PROJECT||key.type!=='service_account'||!key.client_email?.endsWith('@'+PROJECT+'.iam.gserviceaccount.com')||!key.private_key)throw Error('Project-scoped TEST credential required');
 const health=await fetch(API+'/healthz').then(r=>r.json());
 if(health.ready!==true||health.projectId!==PROJECT||health.adminCredentialFingerprint!==hash(key.client_email))throw Error('TEST runtime credential identity unverified');
 const publicKey=fs.readFileSync('lib/platform/platform_config.dart','utf8').match(/const platformApiKey = '([A-Za-z0-9_-]+)'/)[1];
 const login=await post('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key='+publicKey,{email:process.env.VS_TEST_LOGIN_EMAIL,password:process.env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});
 if(login.status!==200||!login.data.idToken)throw Error('TEST administrator login unavailable');
 const call=body=>post(API,{...body,schoolId:SCHOOL},login.data.idToken);
 const session=await call({action:'managed/session'});
 if(session.status!==200||session.data.schoolId!==SCHOOL||session.data.allowed!==true)throw Error('TEST school membership unverified');
 const fromFunctions=require('node:module').createRequire(path.resolve('functions/package.json'));
 const {initializeApp,cert,deleteApp}=fromFunctions('firebase-admin/app');
 const {getFirestore}=fromFunctions('firebase-admin/firestore');
 const app=initializeApp({credential:cert(key),projectId:PROJECT},'test-readonly-admission');
 const report={status:'READ_ONLY',runtime:health.runtimeCommit,schoolId:SCHOOL,markers:[],mutations:0};
 try{
  const db=getFirestore(app),state=(await db.doc('school_live_migrations/'+SCHOOL).get()).data()||{};
  for(const map of ['inflight','liveInflight'])for(const [token,marker] of Object.entries(state[map]||{}).slice(0,100)){
   const b=marker.operationBinding;
   const entry={marker:hash(token),lane:map,collection:marker.collection,startedAt:marker.startedAt,activeAttempts:marker.activeAttempts??null,completedAttempt:marker.completedAttempt===true,bound:!!b};
   report.markers.push(entry);
   if(!b||b.schoolId!==SCHOOL||typeof b.id!=='string'||b.id.length>200||b.id.includes('/')||!['write','delete','patch'].includes(b.operation))continue;
   entry.record=/^(TEST_|atomic-test-|TEST2-DEMO-)/.test(b.id)?b.id:hash(b.id);
   entry.operationIdHash=hash(b.operationId);entry.operation=b.operation;
   const current=await call({action:'managed/records',operation:'read',collection:b.collection,id:b.id,syncProtocol:2});
   entry.readHttp=current.status;
   if(current.status===200&&current.data.success===true&&current.data.schoolId===SCHOOL&&current.data.pointRead===true){
    const row=current.data.records?.[b.id];
    entry.recordPresent=!!row;entry.sameOperation=row?._syncOperationId===b.operationId;
    entry.sameRequestHash=row?._syncRequestHash===b.requestHash;entry.deleted=row?._syncDeleted===true;
    entry.erasePlanComplete=row?._syncErasePlan?.complete===true;
   }
   if(['students_directory','teachers_directory'].includes(b.collection)){
    const op=(await db.doc('school_person_lifecycle_operations/'+hash(JSON.stringify([SCHOOL,b.operationId]))).get()).data();
    entry.lifecyclePresent=!!op;entry.lifecycleIdentityMatches=op?.schoolId===SCHOOL&&op.collection===b.collection&&op.id===b.id&&op.operationId===b.operationId;
    entry.lifecycleState=op?.state||null;
   }
  }
 }finally{await deleteApp(app);}
 console.log('TEST_ADMISSION_REVIEW '+JSON.stringify(report));
}
main().catch(()=>{console.error('TEST_ADMISSION_REVIEW_FAILED: read-only diagnostic unavailable; no writes attempted');process.exitCode=1;});
