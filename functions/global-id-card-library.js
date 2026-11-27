'use strict';
const {createHash,randomUUID}=require('node:crypto');
const {validatePackage}=require('./global-id-card-package');
const {analyzePdf}=require('./global-id-card-analysis');
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
// Foundation policy: payment is disabled; premium cannot accidentally unlock.
function accessDecision(row,grant,school){
  if(row?.state!=='published'||row.mappingState!=='verified'||
     row.packageVerified!==true||!HASH.test(row.packageSha256||''))return false;
  if(row.accessType==='free'&&row.pricePaise===0)return true;
  return row.accessType==='premium'&&grant?.active===true&&
    grant.schoolId===school&&grant.templateId===row.id&&grant.version===row.version&&
    grant.source==='developer_grant';
}
function createGlobalIdCardLibrary({db,bucket,now=Date.now,analyzer=process.env.SAARTHI_GLOBAL_ID_PDFTOTEXT,imageAnalyzer=process.env.SAARTHI_GLOBAL_ID_PDFTOHTML}){
  const collection='global_id_card_library';
  const refs=id=>{if(!ID.test(id||''))invalid(400,'Invalid template identity');return db.doc(collection+'/'+id);};
  const familyRef=id=>{if(!ID.test(id||''))invalid(400,'Invalid template family');return db.doc('global_id_card_families/'+id);};
  function storage(){
    if(!bucket)invalid(503,'Private Firebase template storage is not configured');
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
    if(action==='list')return {success:true,templates:(await list()).map(publicEntry),paymentEnabled:false,storageConfigured:!!bucket,analysisConfigured:!!analyzer,imageAnalysisConfigured:!!imageAnalyzer};
    if(action==='upload'){
      const {name,kind,bytes,sourceSha256}=parseSource(b);
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
      const object=storage().file(sourcePath);
      await object.save(bytes,{resumable:false,validation:'crc32c',
        preconditionOpts:{ifGenerationMatch:0},metadata:{contentType:'application/pdf',
          cacheControl:'private,no-store',metadata:{sha256:sourceSha256}}});
      const [readback]=await object.download();
      if(sha256(readback)!==sourceSha256)invalid(503,'Firebase source readback failed; not registered');
      const row={id,name,kind,familyId,previousId:parent?.id||null,version:1,state:'draft',mappingState:'awaiting_analysis',
        packageVerified:false,sourcePath,sourceSha256,sourceBytes:bytes.length,
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
        tx.set(family,{familyId,lastVersion:row.version,currentId:old?.currentId||parent?.id||null,updatedAt:now()},{merge:true});
      });
      // Upload is durable before analysis begins. Failure keeps the source
      // retryable and private rather than reporting a false publication.
      if(analyzer){
        try{
          const analysis=await analyzePdf(readback,analyzer,imageAnalyzer);
          const next={mappingState:'review_required',analysis,updatedAt:now()};
          await db.runTransaction(async tx=>{
            const latest=await tx.get(ref);
            if(latest.data()?.state!=='draft'||latest.data()?.sourceSha256!==sourceSha256)invalid(409,'Draft changed');
            tx.set(ref,next,{merge:true});
          });
          return {success:true,template:publicEntry({...row,...next})};
        }catch(_){/* Source remains stored; Analyze may retry explicitly. */}
      }
      return {success:true,template:publicEntry(row)};
    }
    if(action==='analyze'){
      const ref=refs(b.id),snap=await ref.get(),row=snap.data();
      if(!snap.exists||row.state!=='draft')invalid(409,'Open a draft first');
      const [source]=await storage().file(row.sourcePath).download();
      if(source.length>MAX_PDF_BYTES||sha256(source)!==row.sourceSha256)invalid(503,'Source checksum failed');
      const analysis=await analyzePdf(source,analyzer,imageAnalyzer);
      await db.runTransaction(async tx=>{
        const latest=await tx.get(ref);
        if(latest.data()?.state!=='draft'||latest.data()?.sourceSha256!==row.sourceSha256)invalid(409,'Draft changed');
        tx.set(ref,{mappingState:'review_required',analysis,updatedAt:now()},{merge:true});
      });
      return {success:true,analysis,sourceSha256:row.sourceSha256};
    }
    if(action==='publish'){
      if(b.reviewConfirmed!==true)invalid(400,'Confirm sample removal, geometry, fonts and real QR replacement');
      const ref=refs(b.id),snap=await ref.get(),row=snap.data();
      if(!snap.exists||row.state!=='draft'||row.mappingState!=='review_required'||b.sourceSha256!==row.sourceSha256)invalid(409,'Analyze the current draft and review its clean package first');
      const {bytes,sha256:packageSha256}=validatePackage(b.package,row.id);
      if(row.packageSha256&&row.packageSha256!==packageSha256)invalid(409,'Published package is immutable; upload a new version as a new design');
      const packagePath='global-id-card-library/verified/'+row.id+'/v'+row.version+'/'+packageSha256+'.json';
      const object=storage().file(packagePath);
      try{await object.save(bytes,{resumable:false,validation:'crc32c',preconditionOpts:{ifGenerationMatch:0},
        metadata:{contentType:'application/json',cacheControl:'private,no-store'}});}
      catch(e){if(Number(e.code)!==412)throw e;}
      const [readback]=await object.download();
      if(sha256(readback)!==packageSha256)invalid(503,'Clean package checksum failed');
      const published=await db.runTransaction(async tx=>{
        const latest=await tx.get(ref),current=latest.data();
        const family=familyRef(row.familyId||row.id),fs=await tx.get(family),familyState=fs.data();
        if(current?.state!=='draft'||current.sourceSha256!==row.sourceSha256||
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
      const [bytes]=await storage().file(row.packagePath).download();
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
    if(action==='archive'||action==='restore'){
      const ref=refs(b.id);
      const row=await db.runTransaction(async tx=>{
        const snap=await tx.get(ref),old=snap.data();
        if(!snap.exists)invalid(404,'Template not found');
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
      const snap=await refs(b.id).get(),row=snap.data();
      if(!snap.exists||row.version!==b.version)invalid(404,'Template version unavailable');
      const grant=row.accessType==='premium'?(await db.doc('global_id_card_entitlements/'+member.schoolId+'/templates/'+row.id).get()).data():null;
      if(!accessDecision(row,grant,member.schoolId))invalid(403,'Template access not verified');
      if(action==='access')return {success:true,schoolId:member.schoolId,uid:member.uid,packageSha256:row.packageSha256};
      const [bytes]=await storage().file(row.packagePath).download();
      if(bytes.length>MAX_PDF_BYTES||sha256(bytes)!==row.packageSha256)invalid(503,'Template checksum failed');
      return {success:true,schoolId:member.schoolId,template:publicEntry(row),packageSha256:row.packageSha256,packageBase64:bytes.toString('base64')};
    }
    if(action!=='list')invalid(400,'Unknown global ID card operation');
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
module.exports={createGlobalIdCardLibrary,parseSource,accessDecision,publicEntry,MAX_PDF_BYTES};
