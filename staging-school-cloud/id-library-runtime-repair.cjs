'use strict';
// Authorized, one-shot maintenance of the exact existing Global ID draft.
// No public endpoint, no new Firebase principals, no category or publish
// operation, and no credentials, sample text, or artwork in the logs.
const {createGlobalIdCardLibrary}=require('../functions/global-id-card-library');
const {probeSandbox}=require('../functions/global-id-card-analysis');
const project='saarthi-ai-df12b',bucketName='saarthi-id-library-prod';
const target='Green Blue and White Modern Student ID Card';
const marker='_id_library_runtime_repairs/20261128-pdf';
function check(value,step){if(!value)throw Object.assign(Error('ID runtime repair blocked'),{repairStep:step});}
async function run({app,db,bucket,env}){
 if(app.options.projectId!==project||env.SAARTHI_ID_LIBRARY_STAGING==='true'||
    env.SAARTHI_GLOBAL_ID_R2_BUCKET!==bucketName||env.RENDER_SERVICE_ID!=='srv-db06j2id0e5s73aafdi0'||
    env.SAARTHI_ID_LIBRARY_REPAIR_DRAFT!=='20261128-pdf')return;
 const checks={},ref=db.doc(marker);let claimed=false,category=null,step='repair-lock',details=null;
 try{
  claimed=await db.runTransaction(async tx=>{
   if((await tx.get(ref)).exists)return false;
   tx.create(ref,{state:'started',at:Date.now()});return true;
  });
  if(!claimed)return;
  step='production-health';
  const health=await fetch('http://127.0.0.1:'+Number(env.PORT||8080)+'/school-cloud/healthz',{
   signal:AbortSignal.timeout(15000)});
  check(health.ok&&(await health.json()).projectId===project,'production-health');checks.health=true;
  step='sandbox';
  const sandbox=await probeSandbox();
  check(Object.keys(sandbox).length===9&&Object.values(sandbox).every(v=>v===true),'production-sandbox');
  checks.sandbox=true;
  step='runtime';
  const library=createGlobalIdCardLibrary({db,bucket});
  const actor={uid:'system-id-pdf-runtime-repair'};
  const runtime=await library.developerAction('runtime-check',{},actor);
  console.info('ID_LIBRARY_PROD_RUNTIME '+JSON.stringify({ready:runtime.ready,storageReady:runtime.storageReady,
    storageReason:runtime.storageReason,checks:runtime.checks,sandbox}));
  check(runtime.ready===true&&runtime.storageReady===true&&Object.values(runtime.checks).every(v=>v===true),'production-runtime');
  checks.runtime=true;checks.r2Ready=true;
  step='locate-exact-draft';
  const rows=await db.collection('global_id_card_library').where('name','==',target).limit(10).get();
  const matches=rows.docs.map(s=>s.data()).filter(row=>row.name===target&&row.state==='draft');
  check(matches.length===1,'exact-draft-not-unique');
  const row=matches[0],id=row.id;
  check(/^gid-[a-f0-9]{32}$/.test(id||'')&&row.sourcePath==='global-id-card-library/private/'+id+'/source.pdf'&&
    /^[a-f0-9]{64}$/.test(row.sourceSha256||'')&&['studentId','teacherId','otherStaffId'].includes(row.kind)&&
    ['awaiting_analysis','review_required'].includes(row.mappingState),'draft-identity');
  category=row.kind;checks.existingDraftFound=true;
  step='private-source';
  const account=env.SAARTHI_GLOBAL_ID_R2_ACCOUNT_ID;
  check(/^[a-f0-9]{32}$/.test(account||''),'production-r2-account');
  const unsigned=await fetch('https://'+account+'.r2.cloudflarestorage.com/'+bucketName+'/'+row.sourcePath,{
   method:'GET',signal:AbortSignal.timeout(10000),redirect:'error'});
  let authError=false;
  if(unsigned.status===400){
   const reader=unsigned.body?.getReader();let raw='',size=0;
   if(reader){try{while(size<4096){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;raw+=Buffer.from(value).toString('utf8');}await reader.cancel();}finally{reader.releaseLock();}}
   const code=raw.match(/<Code>([A-Za-z]{1,80})<\/Code>/)?.[1];
   authError=['InvalidArgument','InvalidRequest','MissingAuthenticationToken','AuthorizationHeaderMalformed','AccessDenied'].includes(code)&&/authorization|authentication|signature|credential/i.test(raw);
  }else await unsigned.body?.cancel();
  check([401,403,404].includes(unsigned.status)||(unsigned.status===400&&authError),'unsigned-production-source-denial');
  checks.privateSourceDenied=true;
  step='analyze-existing-draft';
  // The existing analysis action itself verifies the immutable source SHA.
  // A previously analyzed draft is reused rather than overwriting its work.
  const analysis=row.mappingState==='awaiting_analysis'
   ?await library.developerAction('analyze',{id},actor)
   :{analysis:row.analysis,sourceSha256:row.sourceSha256};
  const pages=analysis.analysis?.pages||[];
  check(analysis.sourceSha256===row.sourceSha256&&pages.length>=1&&pages.length<=2,'draft-analysis');
  checks.analysis=true;
  step='review-source';
  const review=await library.developerAction('review-source',{id,sourceSha256:row.sourceSha256},actor);
  check(review.success===true&&review.sourceSha256===row.sourceSha256&&typeof review.rasters?.front==='string'&&
    Boolean(review.rasters.back)===(pages.length===2),'review-editor-backend-raster');
  checks.sourceChecksum=true;checks.reviewReady=true;
  const latest=(await db.doc('global_id_card_library/'+id).get()).data();
  check(latest.state==='draft'&&latest.mappingState==='review_required'&&latest.kind===category&&
    latest.sourceSha256===row.sourceSha256&&latest.packageVerified!==true,'preserved-private-draft');
  checks.draftPreserved=true;checks.categoryPreserved=true;
  details={pages:pages.length,textCandidates:pages.reduce((n,p)=>n+(p.candidates?.length||0),0),
   imageCandidates:pages.reduce((n,p)=>n+(p.imageCandidates?.length||0),0),mappingState:latest.mappingState};
 }catch(error){
  console.info('ID_LIBRARY_PROD_REPAIR_BLOCKER '+JSON.stringify({step:error?.repairStep||step}));
 }finally{
  if(claimed){
   const passed=checks.draftPreserved===true&&checks.reviewReady===true&&checks.runtime===true;
   await ref.set({state:passed?'passed':'failed',checks,category,details,at:Date.now()},{merge:true}).catch(()=>{});
   console.info('ID_LIBRARY_PROD_REPAIR_RESULT '+JSON.stringify({passed,checks,category,details}));
  }
 }
}
module.exports={run};
