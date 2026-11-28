'use strict';
// One-shot authenticated acceptance test, exclusively for the isolated ID
// library staging project. No human account, production data or credential
// logging. Temporary Firebase principals are removed in finally.
const {randomUUID,createHash}=require('node:crypto');
const {syntheticProbePdf}=require('../functions/global-id-card-analysis');
const hash=b=>createHash('sha256').update(b).digest('hex');
const project='saarthi-ai-staging',bucketName='saarthi-id-library-staging';
const safeName='Synthetic staging ID card acceptance';
function requireCheck(ok,name){if(!ok)throw Object.assign(Error('probe check failed'),{probeStep:name});}
async function getWebKey(app){
  const {access_token}=await app.options.credential.getAccessToken();
  const get=async url=>{
    const response=await fetch(url,{headers:{Authorization:'Bearer '+access_token},signal:AbortSignal.timeout(12000)});
    if(!response.ok)throw Object.assign(Error('staging web configuration unavailable'),{probeStep:'firebase-web-config-http-'+response.status});
    return response.json();
  };
  const base='https://firebase.googleapis.com/v1beta1/projects/'+project;
  const list=await get(base+'/webApps');
  for(const entry of list.apps||[]){
    if(!/^projects\/[a-zA-Z0-9-]+\/webApps\/[a-zA-Z0-9:_-]+$/.test(entry.name||''))continue;
    const config=await get('https://firebase.googleapis.com/v1beta1/'+entry.name+'/config');
    if(config.projectId===project&&typeof config.apiKey==='string'&&config.apiKey.length>20)return config.apiKey;
  }
  throw Object.assign(Error('staging Firebase web app unavailable'),{probeStep:'staging-web-app-not-found'});
}
async function tokenFor(auth,key,uid,claims={}){
  const custom=await auth.createCustomToken(uid,claims);
  const response=await fetch('https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key='+encodeURIComponent(key),{
    method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:custom,returnSecureToken:true}),
    signal:AbortSignal.timeout(15000)
  });
  if(!response.ok)throw Object.assign(Error('Firebase test sign-in unavailable'),{probeStep:'firebase-auth-http-'+response.status});
  const {idToken}=await response.json();
  requireCheck(typeof idToken==='string','id-token');
  const decoded=await auth.verifyIdToken(idToken,true);
  requireCheck(decoded.uid===uid&&(!claims.developer||decoded.developer===true),'verified-firebase-identity');
  return idToken;
}
function cleanPdf(source){
  const text=source.toString('ascii'),i=text.indexOf('\nstream\n')+8,j=text.indexOf('endstream',i);
  requireCheck(i>=8&&j-i>5,'synthetic-clean-fixture');
  const stream='q Q'+' '.repeat(j-i-4)+'\n';
  return Buffer.from(text.slice(0,i)+stream+text.slice(j),'ascii');
}
async function run({app,auth,db,bucket,env}){
  if(app.options.projectId!==project||env.SAARTHI_ID_LIBRARY_STAGING!=='true'||
     env.SAARTHI_GLOBAL_ID_R2_BUCKET!==bucketName||
     env.RENDER_SERVICE_ID!=='srv-dc4skhlg1s2s73flu6q0'||
     env.SAARTHI_ID_LIBRARY_E2E_PROBE!=='20261128-b')return;
  const checks={},mark=db.doc('_id_library_staging_probe/20261128-b');
  let devUid,schoolUid,schoolId,devToken,id,claimed=false,step='probe-lock';
  const port=Number(env.PORT||8080),base='http://127.0.0.1:'+port+'/school-cloud';
  const call=async(action,body,token,expected=200)=>{
    const response=await fetch(base,{method:'POST',headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},
      body:JSON.stringify({action,...body}),signal:AbortSignal.timeout(45000)});
    requireCheck(response.status===expected,action+'-http-'+response.status);
    const data=await response.json();
    if(expected===200)requireCheck(data.success===true,action+'-response');
    return data;
  };
  const dev=(action,body={},expected=200)=>call('developer/managed/id-library/'+action,body,devToken,expected);
  try{
    claimed=await db.runTransaction(async tx=>{
      if((await tx.get(mark)).exists)return false;
      tx.create(mark,{state:'started',at:Date.now()});return true;
    });
    if(!claimed)return;
    step='firebase-web-config';const key=await getWebKey(app);
    step='health';const health=await fetch(base+'/healthz',{signal:AbortSignal.timeout(15000)});
    requireCheck(health.ok&&(await health.json()).projectId===project,'isolated-staging-health');checks.health=true;
    step='anonymous-denial';await call('developer/managed/id-library/runtime-check',{},null,401);checks.anonymousDenied=true;
    step='temporary-firebase-identities';
    const nonce=randomUUID().replaceAll('-','');
    devUid='id-probe-dev-'+nonce;schoolUid='id-probe-school-'+nonce;schoolId='vs-'+randomUUID().replaceAll('-','');
    // Explicit synthetic principals. Developer privilege exists only in the
    // short-lived signed test token; no persistent admin claim/password.
    await auth.createUser({uid:devUid});
    await auth.createUser({uid:schoolUid});
    const now=Date.now(),batch=db.batch();
    batch.create(db.doc('school_memberships/'+schoolUid),{schoolId,managed:true,role:'school_admin',active:true});
    batch.create(db.doc('school_entitlements/'+schoolId),{active:true,blocked:false,status:'trial',startsAt:now-1000,expiresAt:now+3600000});
    await batch.commit();
    devToken=await tokenFor(auth,key,devUid,{developer:true});
    const schoolToken=await tokenFor(auth,key,schoolUid);
    const school=(action,body={},expected=200)=>call('managed/id-library/'+action,{schoolId,...body},schoolToken,expected);
    checks.realFirebaseAuth=true;
    step='runtime-check';
    const runtime=await dev('runtime-check');
    console.info('ID_LIBRARY_E2E_RUNTIME '+JSON.stringify({ready:runtime.ready===true,storageReady:runtime.storageReady===true,storageReason:runtime.storageReason,checks:runtime.checks}));
    requireCheck(runtime.ready&&runtime.storageReady&&runtime.checks.text&&runtime.checks.imageGeometry&&runtime.checks.raster,'authenticated-runtime');
    checks.runtime=true;checks.r2Ready=true;
    step='upload';
    const source=syntheticProbePdf(),sourceSha256=hash(source);
    const uploaded=await dev('upload',{name:safeName,kind:'studentId',syntheticSampleConfirmed:true,pdfBase64:source.toString('base64')});
    id=uploaded.template?.id;
    requireCheck(/^gid-[a-f0-9]{32}$/.test(id||'')&&uploaded.template.state==='draft','private-draft');
    checks.upload=true;
    const ref=db.doc('global_id_card_library/'+id),row=(await ref.get()).data();
    requireCheck(row.sourceSha256===sourceSha256&&row.sourcePath==='global-id-card-library/private/'+id+'/source.pdf','source-registration');
    const [readback]=await bucket.file(row.sourcePath).download();
    requireCheck(hash(readback)===sourceSha256,'r2-source-readback');checks.sourceChecksum=true;
    step='draft-access-denial';
    requireCheck(!(await school('list')).templates.some(t=>t.id===id),'draft-hidden');
    await school('package',{id,version:1},403);checks.draftHidden=true;
    step='analyze';
    const analyzed=await dev('analyze',{id});
    const pages=analyzed.analysis?.pages||[],p=pages[0];
    requireCheck(analyzed.sourceSha256===sourceSha256&&pages.length===1&&p.candidates.some(c=>c.key==='name')&&p.imageCandidates.length>0,'real-analysis');
    checks.analysis=true;
    step='review-source';
    const review=await dev('review-source',{id,sourceSha256});
    requireCheck(typeof review.rasters?.front==='string'&&review.sourceSha256===sourceSha256,'review-raster');
    checks.review=true;
    step='clean-artwork';
    const clean=await dev('review-clean-pdf',{id,sourceSha256,syntheticSampleConfirmed:true,pdfBase64:cleanPdf(source).toString('base64')});
    requireCheck(typeof clean.rasters?.front==='string'&&clean.rasters.front!==review.rasters.front,'clean-artwork');
    checks.cleanArtwork=true;
    const packageData={manifest:{id,version:1,canvasWidth:p.canvasWidth,canvasHeight:p.canvasHeight,
      printWidthMm:p.printWidthMm,printHeightMm:p.printHeightMm,
      regions:[{key:'name',side:'front',kind:'text',x:20,y:55,width:115,height:20},
        {key:'qr',side:'front',kind:'qr',x:175,y:95,width:42,height:42}]},backgrounds:{front:clean.rasters.front}};
    step='review-approval-gate';
    await dev('publish',{id,sourceSha256,package:packageData,reviewConfirmed:false},400);checks.reviewRequired=true;
    // Only this known generated, blank synthetic fixture is approved by the
    // test. Production publication still requires developer artwork review.
    step='publish';
    const published=await dev('publish',{id,sourceSha256,package:packageData,reviewConfirmed:true});
    requireCheck(published.template.state==='published'&&published.template.mappingState==='verified','published-state');
    checks.publish=true;
    step='r2-package-readback';
    const stored=(await ref.get()).data(),[packageBytes]=await bucket.file(stored.packagePath).download();
    requireCheck(stored.packageVerified===true&&hash(packageBytes)===stored.packageSha256,'verified-r2-package');
    checks.packageChecksum=true;
    step='school-catalog';
    const listing=await school('list'),entry=listing.templates.find(t=>t.id===id);
    requireCheck(entry?.unlocked===true&&entry.kind==='studentId'&&entry.packageSha256===stored.packageSha256&&
      !('sourcePath' in entry)&&!('sourceSha256' in entry),'authenticated-school-catalog');
    checks.schoolCatalog=true;
    step='school-package';
    const retrieved=await school('package',{id,version:1});
    const bytes=Buffer.from(retrieved.packageBase64,'base64');
    requireCheck(retrieved.schoolId===schoolId&&hash(bytes)===stored.packageSha256&&JSON.parse(bytes).manifest.id===id&&
      !bytes.includes(source),'authenticated-school-package');
    checks.schoolPackage=true;
    step='archive';
    await dev('archive',{id});requireCheck(!(await school('list')).templates.some(t=>t.id===id),'archive-hidden');
    await school('package',{id,version:1},403);checks.archive=true;
  }catch(error){
    const code=typeof error?.code==='string'&&/^[a-zA-Z0-9_/-]{1,80}$/.test(error.code)?error.code:null;
    console.info('ID_LIBRARY_E2E_BLOCKER '+JSON.stringify({step:error?.probeStep||step,code}));
  }finally{
    if(claimed){
      // Keep only the archived synthetic test template and its immutable
      // checksum evidence. No production draft or existing account touched.
      const cleanup=[];
      if(id&&devToken&&!checks.archive){
        try{await dev('archive',{id});}catch(_){checks.archiveCleanupFailed=true;}
      }
      if(devUid)cleanup.push(auth.deleteUser(devUid).catch(e=>{if(e.code!=='auth/user-not-found')throw e;}));
      if(schoolUid)cleanup.push(auth.deleteUser(schoolUid).catch(e=>{if(e.code!=='auth/user-not-found')throw e;}),db.doc('school_memberships/'+schoolUid).delete());
      if(schoolId)cleanup.push(db.doc('school_entitlements/'+schoolId).delete());
      const cleaned=(await Promise.allSettled(cleanup)).every(r=>r.status==='fulfilled');
      checks.cleanup=checks.archiveCleanupFailed!==true&&cleaned;
      const passed=checks.archive===true&&checks.cleanup===true;
      await mark.set({state:passed?'passed':'failed',checks,at:Date.now()},{merge:true}).catch(()=>{});
      console.info('ID_LIBRARY_E2E_RESULT '+JSON.stringify({passed,checks}));
    }
  }
}
module.exports={run};
