'use strict';
const {createHash,randomUUID}=require('node:crypto');
const {validatePackage,verifySourceGeometry}=require('./global-id-card-package');
const {analyzePdf,renderReviewSource,probeRuntime,renderCleanCompanion}=require('./global-id-card-analysis');
const MAX_PDF_BYTES=8*1024*1024;
const KINDS=new Set(['studentId','teacherId','otherStaffId']);
const ID=/^gid-[a-f0-9]{32}$/;
const SCHOOL=/^vs-[a-f0-9]{32}$/;
const HASH=/^[a-f0-9]{64}$/;
const sha256=bytes=>createHash('sha256').update(bytes).digest('hex');
function invalid(status,message){throw Object.assign(new Error(message),{status,publicMessage:true});}
function parseSource(body){
  const name=typeof body.name==='string'?body.name.trim():'';
  if(!KINDS.has(body.kind)||!name||name.length>100||/[\x00-\x1f\x7f]/.test(name))
    invalid(400,'Template name and valid person category required');
  if(body.syntheticSampleConfirmed!==true)
    invalid(400,'Confirm the PDF contains only fictional sample data and authorized artwork');
  const raw=body.pdfBase64;
  if(typeof raw!=='string'||raw.length>Math.ceil(MAX_PDF_BYTES/3)*4||
    !/^[A-Za-z0-9+/]+={0,2}$/.test(raw))invalid(400,'Invalid or oversized PDF');
  const bytes=Buffer.from(raw,'base64');
  if(bytes.length<16||bytes.length>MAX_PDF_BYTES||bytes.toString('base64')!==raw||
    !/^%PDF-\d\.\d/.test(bytes.subarray(0,12).toString('ascii'))||
    !/%%EOF\s*$/.test(bytes.subarray(-1024).toString('latin1')))
    invalid(400,'A complete PDF up to 8 MiB is required');
  // Header/footer screening is NOT a parser or proof of sanitization.
  return {name,kind:body.kind,bytes,sourceSha256:sha256(bytes)};
}
function publicEntry(row){
  return {id:row.id,name:row.name,kind:row.kind,version:row.version,
    familyId:row.familyId||row.id,previousId:row.previousId||null,isCurrent:row.isCurrent!==false,
    state:row.state,mappingState:row.mappingState,accessType:row.accessType,
    pricePaise:row.pricePaise,currency:'INR',updatedAt:row.updatedAt};
}
// GCS checks are necessary, not sufficient: Firebase client rules and
// inherited IAM must also be independently verified before opt-in.
async function verifyPrivateBucket(bucket){
 try{
  const [meta]=await bucket.getMetadata();
  const config=meta.iamConfiguration;
  if(config?.uniformBucketLevelAccess?.enabled!==true||config?.publicAccessPrevention!=='enforced')
   return {ready:false,reason:'private_bucket_controls_required'};
  const [policy]=await bucket.iam.getPolicy({requestedPolicyVersion:3});
  if(!Array.isArray(policy?.bindings)||policy.bindings.some(b=>
     !Array.isArray(b.members)||b.members.some(m=>m==='allUsers'||m==='allAuthenticatedUsers')))
   return {ready:false,reason:'public_bucket_binding_or_unverified'};
  return {ready:true,reason:'private_controls_checked'};
 }catch(_){return {ready:false,reason:'bucket_permission_or_metadata_unavailable'};}
}
// Foundation policy: payment is disabled; premium cannot accidentally unlock.
function accessDecision(row,grant,school){
  if(row?.state!=='published'||row.mappingState!=='verified'||
     row.packageVerified!==true||!HASH.test(row.packageSha256||''))return false;
  if(row.accessType==='free'&&row.pricePaise===0)return true;
  return row.accessType==='premium'&&grant?.active===true&&
    grant.schoolId===school&&grant.templateId===row.id&&grant.version===row.version&&
    grant.source==='developer_grant';
}
function createGlobalIdCardLibrary({db,bucket,now=Date.now,policyReviewed=process.env.SAARTHI_GLOBAL_ID_STORAGE_POLICY_VERIFIED==='true',analyzer=process.env.SAARTHI_GLOBAL_ID_PDFTOTEXT,imageAnalyzer=process.env.SAARTHI_GLOBAL_ID_PDFTOHTML,rasterizer=process.env.SAARTHI_GLOBAL_ID_PDFTOPPM,analyzeSource=analyzePdf}){
  const collection='global_id_card_library';
  const refs=id=>{if(!ID.test(id||''))invalid(400,'Invalid template identity');return db.doc(collection+'/'+id);};
  const familyRef=id=>{if(!ID.test(id||''))invalid(400,'Invalid template family');return db.doc('global_id_card_families/'+id);};
  let storageProbe=null;
  async function storageStatus(){
    if(!bucket)return {ready:false,reason:'not_configured'};
    if(!policyReviewed)return {ready:false,reason:'private_storage_review_required'};
    const t=now();
    if(storageProbe&&t>=storageProbe.at&&t-storageProbe.at<60000)return storageProbe.result;
    const result=await (bucket.verifyPrivateStorage?.()??verifyPrivateBucket(bucket));
    storageProbe={at:now(),result};return result;
  }
  async function storage(){
    const status=await storageStatus();
    if(!status.ready)invalid(503,'Private template storage policy is not verified');
    return bucket;
  }
  async function list(){
    const snapshot=await db.collection(collection).orderBy('updatedAt','desc').limit(200).get();
    const rows=snapshot.docs.map(doc=>doc.data());
    const families=[...new Set(rows.map(r=>r.familyId||r.id))];
    const current=new Map(await Promise.all(families.map(async id=>{
      const s=await familyRef(id).get();return [id,s.exists?(s.data()?.currentId||null):undefined];
    })));
    return rows.map(row=>({...row,isCurrent:current.get(row.familyId||row.id)===row.id||
      (current.get(row.familyId||row.id)===undefined&&!row.previousId&&row.state==='published')}));

  }
  async function developerAction(action,b,actor){
    if(action==='list'){
      const status=await storageStatus();
      return {success:true,templates:(await list()).filter(row=>row.state!=='deleted').map(row=>({...publicEntry(row),detectedKind:row.analysis?.category?.kind||null,categoryEvidence:row.analysis?.category?.evidence||'unknown'})),paymentEnabled:false,
        storageConfigured:!!bucket,storageReady:status.ready,storageReason:status.reason,
        analysisConfigured:!!analyzer,imageAnalysisConfigured:!!imageAnalyzer,reviewRasterizerConfigured:!!rasterizer};
    }
    if(action==='runtime-check'){
      const status=await storageStatus();
      const checks=await probeRuntime(analyzer,imageAnalyzer,rasterizer);
      return {success:true,storageReady:status.ready,storageReason:status.reason,checks,
        ready:status.ready&&checks.text&&checks.imageGeometry&&checks.raster};
    }
    if(action==='preflight'){
      const {bytes}=parseSource(b);
      const analysis=await analyzeSource(bytes,analyzer,imageAnalyzer);
      return {success:true,category:analysis.category,fields:[...new Set(analysis.pages.flatMap(p=>[
        ...p.candidates.map(r=>r.key),...(p.imageCandidates||[]).map(r=>r.suggestedRole).filter(Boolean),
        ...(p.labelSlots||[]).map(r=>r.role)
      ]))]};
    }
    if(action==='upload'){
      const {name,kind,bytes,sourceSha256}=parseSource(b);
      // Analyze before creating any durable object. Explicit heading mismatch
      // never creates a draft or consumes storage. Unknown heading requires
      // a human category confirmation on the new upload client.
      let analysis=null;
      if(analyzer){
        analysis=await analyzeSource(bytes,analyzer,imageAnalyzer);
        if(analysis.category?.evidence==='conflicting_headings')invalid(400,'PDF contains conflicting card categories. Correct the original PDF.');
        if(analysis.category?.kind&&analysis.category.kind!==kind)
          invalid(400,'PDF category is '+analysis.category.kind+'. Select the matching category before uploading.');
        if(!analysis.category?.kind&&b.categoryConfirmed!==true)
          invalid(400,'PDF category could not be detected. Confirm the correct card category before uploading.');
      }
      const id='gid-'+randomUUID().replaceAll('-','');
      const ref=refs(id),sourcePath='global-id-card-library/private/'+id+'/source.pdf';
      let parent=null;
      if(b.previousId!=null){
        const snap=await refs(b.previousId).get();parent=snap.data();
        if(!snap.exists||parent.state!=='published'||parent.kind!==kind||parent.accessType!=='free')
          invalid(409,'New revision requires an existing published free template of the same category');
      }
      const familyId=parent?.familyId||parent?.id||id;
      const family=familyRef(familyId);
      // Never create a download token, public ACL or signed school URL for sample PDFs.
      const object=(await storage()).file(sourcePath);
      await object.save(bytes,{resumable:false,validation:'crc32c',
        preconditionOpts:{ifGenerationMatch:0},metadata:{contentType:'application/pdf',
          cacheControl:'private,no-store',metadata:{sha256:sourceSha256}}});
      const [readback]=await object.download();
      if(sha256(readback)!==sourceSha256)invalid(503,'Source storage readback failed; not registered');
      const row={id,name,kind,familyId,previousId:parent?.id||null,version:1,state:'draft',mappingState:'awaiting_analysis',
        packageVerified:false,sourcePath,sourceSha256,sourceBytes:bytes.length,
        ...(analysis?{mappingState:'review_required',analysis}:{}),
        accessType:'free',pricePaise:0,currency:'INR',createdBy:actor.uid,
        createdAt:now(),updatedAt:now()};
      await db.runTransaction(async tx=>{
        const fs=await tx.get(family);
        const old=fs.data();
        if(parent){
          const latest=await tx.get(refs(parent.id));
          if(latest.data()?.state!=='published'||latest.data()?.kind!==kind||
             latest.data()?.packageSha256!==parent.packageSha256)invalid(409,'Previous version changed');
          row.version=Math.max(Number(old?.lastVersion)||0,parent.version)+1;
          if(row.version>10000)invalid(409,'Template version limit reached');
        }else if(fs.exists)invalid(409,'Template family already exists');
        tx.create(ref,row);
        tx.set(family,{familyId,lastVersion:row.version,currentId:fs.exists?(old.currentId??null):(parent?.id||null),updatedAt:now()},{merge:true});
      });
      return {success:true,template:publicEntry(row)};
    }
    if(action==='analyze'){
      const ref=refs(b.id),snap=await ref.get(),row=snap.data();
      if(!snap.exists||row.state!=='draft')invalid(409,'Open a draft first');
      const [source]=await (await storage()).file(row.sourcePath).download();
      if(source.length>MAX_PDF_BYTES||sha256(source)!==row.sourceSha256)invalid(503,'Source checksum failed');
      const analysis=await analyzeSource(source,analyzer,imageAnalyzer);
      await db.runTransaction(async tx=>{
        const latest=await tx.get(ref);
        if(latest.data()?.state!=='draft'||latest.data()?.sourceSha256!==row.sourceSha256)invalid(409,'Draft changed');
        tx.set(ref,{mappingState:'review_required',analysis,updatedAt:now()},{merge:true});
      });
      return {success:true,analysis,sourceSha256:row.sourceSha256};
    }
    if(action==='review-source'){
      const snap=await refs(b.id).get(),row=snap.data();
      if(!snap.exists||row.state!=='draft'||row.mappingState!=='review_required'||
        row.sourceSha256!==b.sourceSha256||!row.analysis?.pages)invalid(409,'Analyze the current draft first');
      const [source]=await (await storage()).file(row.sourcePath).download();
      if(source.length>MAX_PDF_BYTES||sha256(source)!==row.sourceSha256)invalid(503,'Source checksum failed');
      const rasters=await renderReviewSource(source,row.analysis.pages,rasterizer);
      return {success:true,sourceSha256:row.sourceSha256,rasters};
    }
    if(action==='review-clean-pdf'){
      // Companion files are developer-only, processed transiently, and never
      // distributed as PDFs. The immutable filled source is unchanged.
      const snap=await refs(b.id).get(),row=snap.data();
      if(!snap.exists||row.state!=='draft'||row.mappingState!=='review_required'||
         row.sourceSha256!==b.sourceSha256||!row.analysis?.pages)invalid(409,'Analyze the current draft first');
      await storage();
      const {bytes}=parseSource({name:row.name,kind:row.kind,pdfBase64:b.pdfBase64,syntheticSampleConfirmed:b.syntheticSampleConfirmed});
      const rasters=await renderCleanCompanion(bytes,row.analysis.pages,analyzer,rasterizer);
      const latest=await refs(b.id).get();
      if(latest.data()?.state!=='draft'||latest.data()?.sourceSha256!==row.sourceSha256)invalid(409,'Draft changed');
      return {success:true,sourceSha256:row.sourceSha256,rasters};
    }
    if(action==='publish'){
      if(b.reviewConfirmed!==true)invalid(400,'Confirm sample removal, geometry, fonts and real QR replacement');
      const ref=refs(b.id),snap=await ref.get(),row=snap.data();
      if(!snap.exists||row.state!=='draft'||row.mappingState!=='review_required'||b.sourceSha256!==row.sourceSha256)invalid(409,'Analyze the current draft and review its clean package first');
      if(row.analysis?.category?.kind&&row.analysis.category.kind!==row.kind)
        invalid(400,'PDF category mismatch. Correct the draft category before publishing.');
      if(row.analysis?.category?.evidence==='conflicting_headings')invalid(400,'Conflicting card categories');
      const {bytes,sha256:packageSha256,clean}=validatePackage(b.package,row.id);
      verifySourceGeometry(clean,row.analysis?.pages);
      if(row.packageSha256&&row.packageSha256!==packageSha256)invalid(409,'Published package is immutable; upload a new version as a new design');
      const packagePath='global-id-card-library/verified/'+row.id+'/v'+row.version+'/'+packageSha256+'.json';
      const object=(await storage()).file(packagePath);
      try{await object.save(bytes,{resumable:false,validation:'crc32c',preconditionOpts:{ifGenerationMatch:0},
        metadata:{contentType:'application/json',cacheControl:'private,no-store'}});}
      catch(e){if(Number(e.code)!==412)throw e;}
      const [readback]=await object.download();
      if(sha256(readback)!==packageSha256)invalid(503,'Clean package checksum failed');
      const published=await db.runTransaction(async tx=>{
        const latest=await tx.get(ref),current=latest.data();
        const family=familyRef(row.familyId||row.id),fs=await tx.get(family),familyState=fs.data();
        if(current?.state!=='draft'||current.sourceSha256!==row.sourceSha256||
           current.kind!==row.kind||current.mappingState!=='review_required'||JSON.stringify(current.analysis?.category)!==JSON.stringify(row.analysis?.category)||JSON.stringify(current.analysis?.pages)!==JSON.stringify(row.analysis?.pages)||
           (current.packageSha256&&current.packageSha256!==packageSha256))invalid(409,'Draft changed');
        const next={state:'published',mappingState:'verified',packageVerified:true,packageSha256,packagePath,
          reviewedBy:actor.uid,reviewedAt:now(),updatedAt:now()};
        tx.set(ref,next,{merge:true});
        // An older draft published after a later revision must not silently
        // replace it. Rollback is an explicit developer action.
        if(!familyState?.currentId||row.version>=Number(familyState.currentVersion||0))
          tx.set(family,{familyId:row.familyId||row.id,lastVersion:Math.max(row.version,Number(familyState?.lastVersion||0)),
            currentId:row.id,currentVersion:row.version,updatedAt:now()},{merge:true});
        return {...current,...next};
      });
      return {success:true,template:publicEntry(published)};
    }
    if(action==='make-current'){
      const ref=refs(b.id),snap=await ref.get(),row=snap.data();
      if(!snap.exists||!['published','archived'].includes(row.state)||row.mappingState!=='verified'||
         row.packageVerified!==true||row.accessType!=='free'||!HASH.test(row.packageSha256||''))
        invalid(409,'Only a verified free revision can be restored or made current');
      const [bytes]=await (await storage()).file(row.packagePath).download();
      if(bytes.length>MAX_PDF_BYTES||sha256(bytes)!==row.packageSha256)invalid(503,'Revision checksum failed');
      const family=familyRef(row.familyId||row.id);
      await db.runTransaction(async tx=>{
        const latest=await tx.get(ref),fs=await tx.get(family),current=latest.data();
        if(!['published','archived'].includes(current?.state)||current.packageSha256!==row.packageSha256||
          current.packageVerified!==true||current.accessType!=='free')invalid(409,'Revision changed');
        tx.set(ref,{state:'published',updatedAt:now(),updatedBy:actor.uid},{merge:true});
        tx.set(family,{familyId:row.familyId||row.id,lastVersion:Math.max(row.version,Number(fs.data()?.lastVersion||0)),
          currentId:row.id,currentVersion:row.version,updatedAt:now(),updatedBy:actor.uid},{merge:true});
      });
      return {success:true};
    }
    if(action==='change-category'){
      if(!KINDS.has(b.kind))invalid(400,'Invalid category');
      const ref=refs(b.id),snap=await ref.get(),row=snap.data();
      if(!snap.exists||row.state!=='draft'||row.packageVerified===true||row.previousId||row.version!==1)
        invalid(409,'Only an unpublished original draft can change category');
      const [bytes]=await (await storage()).file(row.sourcePath).download();
      if(bytes.length>MAX_PDF_BYTES||sha256(bytes)!==row.sourceSha256)invalid(503,'Source checksum failed');
      const analysis=await analyzeSource(bytes,analyzer,imageAnalyzer);
      if(analysis.category?.kind!==b.kind)invalid(400,'PDF does not explicitly match the requested category');
      await db.runTransaction(async tx=>{
        const latest=await tx.get(ref),current=latest.data();
        if(current?.state!=='draft'||current.packageVerified===true||current.previousId||current.version!==1||
           current.sourceSha256!==row.sourceSha256||current.kind!==row.kind)invalid(409,'Draft changed');
        tx.set(ref,{kind:b.kind,analysis,mappingState:'review_required',updatedAt:now(),updatedBy:actor.uid},{merge:true});
      });
      return {success:true};
    }
    if(action==='delete'){
      if(b.confirmed!==true)invalid(400,'Confirm deletion of the unpublished draft');
      const ref=refs(b.id);
      await db.runTransaction(async tx=>{
        const snap=await tx.get(ref),row=snap.data();
        if(!snap.exists||!['draft','archived'].includes(row.state)||row.packageVerified===true||row.packagePath)
          invalid(409,'Only never-published drafts can be deleted. Archive published revisions instead.');
        const family=await tx.get(familyRef(row.familyId||row.id));
        if(family.data()?.currentId===row.id)invalid(409,'Current revision cannot be deleted');
        tx.set(ref,{state:'deleted',deletedAt:now(),deletedBy:actor.uid,updatedAt:now()},{merge:true});
      });
      return {success:true};
    }
    if(action==='archive'||action==='restore'){
      const ref=refs(b.id);
      const row=await db.runTransaction(async tx=>{
        const snap=await tx.get(ref),old=snap.data();
        if(!snap.exists||old.state==='deleted')invalid(404,'Template not found');
        const family=familyRef(old.familyId||old.id),fs=await tx.get(family);
        // Restore to draft, never accidentally publish an unreviewed source.
        const next={state:action==='archive'?'archived':'draft',updatedAt:now(),updatedBy:actor.uid};
        tx.set(ref,next,{merge:true});
        if(action==='archive'&&fs.data()?.currentId===old.id)tx.set(family,{currentId:null,currentVersion:0,updatedAt:now()},{merge:true});
        return {...old,...next};
      });
      return {success:true,template:publicEntry(row)};
    }
    if(action==='grant'){
      // The future manual entitlement store is ready; all current designs remain free.
      if(!SCHOOL.test(b.schoolId||''))invalid(400,'Invalid school identity');
      const ref=refs(b.id);
      const schoolRef=db.doc('platform_schools/'+b.schoolId);
      const grantRef=db.doc('global_id_card_entitlements/'+b.schoolId+'/templates/'+b.id);
      await db.runTransaction(async tx=>{
        const [t,s]=await Promise.all([tx.get(ref),tx.get(schoolRef)]);
        const row=t.data();
        if(!t.exists||!s.exists||s.data().managed!==true||s.data().deletedAt||
           row.state!=='published'||row.packageVerified!==true)invalid(409,'Verified published template and active school required');
        tx.set(grantRef,{schoolId:b.schoolId,templateId:b.id,version:row.version,
          active:true,source:'developer_grant',actor:actor.uid,updatedAt:now()});
      });
      return {success:true};
    }
    invalid(400,'Unknown global ID card operation');
  }
  async function schoolAction(action,b,member){
    if(action==='package'||action==='access'){
      await storage();
      const snap=await refs(b.id).get(),row=snap.data();
      if(!snap.exists||row.version!==b.version)invalid(404,'Template version unavailable');
      const grant=row.accessType==='premium'?(await db.doc('global_id_card_entitlements/'+member.schoolId+'/templates/'+row.id).get()).data():null;
      if(!accessDecision(row,grant,member.schoolId))invalid(403,'Template access not verified');
      if(action==='access')return {success:true,schoolId:member.schoolId,uid:member.uid,packageSha256:row.packageSha256};
      const [bytes]=await (await storage()).file(row.packagePath).download();
      if(bytes.length>MAX_PDF_BYTES||sha256(bytes)!==row.packageSha256)invalid(503,'Template checksum failed');
      return {success:true,schoolId:member.schoolId,template:publicEntry(row),packageSha256:row.packageSha256,packageBase64:bytes.toString('base64')};
    }
    if(action!=='list')invalid(400,'Unknown global ID card operation');
    if(!(await storageStatus()).ready)invalid(503,'Private template storage policy is not verified');
    // Never expose raw sample PDFs, draft paths, metadata with sample values,
    // or unverified template artwork to school clients.
    const rows=(await list()).filter(r=>r.state==='published'&&r.mappingState==='verified'&&
      r.packageVerified===true&&HASH.test(r.packageSha256||''));
    const templates=await Promise.all(rows.map(async row=>{
      const grant=row.accessType==='premium'?(await db.doc('global_id_card_entitlements/'+member.schoolId+'/templates/'+row.id).get()).data():null;
      return {...publicEntry(row),packageSha256:row.packageSha256,unlocked:accessDecision(row,grant,member.schoolId)};
    }));
    const serverTime=now(),expiresAt=Math.min(serverTime+24*3600000,Number(member.entitlement?.expiresAt||0));
    return {success:true,schoolId:member.schoolId,uid:member.uid,templates,paymentEnabled:false,serverTime,expiresAt};
  }
  return {developerAction,schoolAction};
}
module.exports={createGlobalIdCardLibrary,parseSource,accessDecision,publicEntry,verifyPrivateBucket,MAX_PDF_BYTES};
