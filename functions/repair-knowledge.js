'use strict';
const {createPrivateKey,createHash,createHmac,sign}=require('node:crypto');
const PROTOCOL=1,DAY=86400000;
const MODULES=new Set(['all','students_directory','teachers_directory','documents','fee_ledger','fee_payments','school_expenses','school_notices','attendance_records','exams','exam_results','school_config']);
const CATEGORIES=new Set(['networkPath','timeout','server','quota','conflict','configuration','validation','fileMissing','unknown','idCardInputs']);
// A versioned server catalog can remember a sanitized error fingerprint,
 // never arbitrary client text, payment data or code to execute.
const CODES=new Set(['RECORD_REVISION_CONFLICT','OPERATION_ID_CONFLICT',
 'SCRIPT_RECORD_REVISION_CONFLICT','SCRIPT_OPERATION_ID_CONFLICT',
 'SCRIPT_DOCUMENT_REVISION_CONFLICT','SCRIPT_TIMEOUT',
 'SCRIPT_QUOTA_EXCEEDED','SCRIPT_PERMISSION_DENIED',
 'SCRIPT_RECORD_VERIFY_FAILED','SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED',
 'FIELD_DELTA_UNAVAILABLE','ACK_UNVERIFIED','SCRIPT_TRANSPORT_ERROR',
 'SCRIPT_RESPONSE_READ_FAILED','SCRIPT_HTTP_ERROR',
 'SCRIPT_MIGRATION_PENDING','SCRIPT_MIGRATION_CONFLICT',
 'SCRIPT_STORAGE_NOT_PREPARED','SCRIPT_JSON_READBACK_FAILED',
 'SCRIPT_EXTERNAL_EDIT_REVIEW_REQUIRED']);
const ACTIONS={retry_floor:[5,900],record_probe_cooldown:[300,3600],card_probe_cooldown:[120,3600],batch_cap:[2,10]};
const hash=v=>createHash('sha256').update(v).digest('hex');
function fail(status,code){throw Object.assign(Error(code),{status,code,publicMessage:true});}
function exact(v,keys){if(!v||Object.getPrototypeOf(v)!==Object.prototype||Object.keys(v).some(k=>!keys.includes(k)))fail(400,'REPAIR_KNOWLEDGE_SCHEMA');}
function policy(input){
 exact(input,['enabled','rules']);
 if(typeof input.enabled!=='boolean'||!Array.isArray(input.rules)||input.rules.length>20||(!input.enabled&&input.rules.length))fail(400,'REPAIR_KNOWLEDGE_SCHEMA');
 const seen=new Set();const rules=input.rules.map(r=>{
  exact(r,['id','module','category','action','value','rolloutPercent']);
  if(!/^[a-z][a-z0-9_-]{0,63}$/.test(r.id||'')||seen.has(r.id)||!MODULES.has(r.module)||!CATEGORIES.has(r.category)||!Object.hasOwn(ACTIONS,r.action)||!Number.isSafeInteger(r.value)||r.value<ACTIONS[r.action][0]||r.value>ACTIONS[r.action][1]||!Number.isInteger(r.rolloutPercent)||r.rolloutPercent<1||r.rolloutPercent>100)fail(400,'REPAIR_KNOWLEDGE_RULE');
  if(r.action==='retry_floor'&&(!['networkPath','timeout','server','quota'].includes(r.category)||r.module!=='all')||r.action==='card_probe_cooldown'&&(r.module!=='documents'||r.category!=='idCardInputs')||r.action==='record_probe_cooldown'&&r.category!=='conflict')fail(400,'REPAIR_KNOWLEDGE_RULE');
  seen.add(r.id);return {id:r.id,module:r.module,category:r.category,action:r.action,value:r.value,rolloutPercent:r.rolloutPercent};
 });
 return {enabled:input.enabled,rules};
}
const policyHash=p=>hash(JSON.stringify(policy(p)));
function reports(input){
 if(!Array.isArray(input)||input.length>20)fail(400,'REPAIR_KNOWLEDGE_REPORT');
 return input.map(r=>{exact(r,['module','category','outcome','code']);
  if(!MODULES.has(r.module)||r.module==='all'||!CATEGORIES.has(r.category)||!['detected','retry','resolved','recurred'].includes(r.outcome)||
   (r.code!==undefined&&!CODES.has(r.code)))fail(400,'REPAIR_KNOWLEDGE_REPORT');
  return {module:r.module,category:r.category,outcome:r.outcome,...(r.code?{code:r.code}:{})};
 });
}
function createRepairKnowledge({db,now=Date.now,enabled=false,privateKey,keyId='repair-v1',reportSalt}={}){
 let key,configured=enabled;
 if(enabled){try{key=createPrivateKey(privateKey);if(key.asymmetricKeyType!=='ed25519'||!/^[a-zA-Z0-9_-]{1,64}$/.test(keyId)||typeof reportSalt!=='string'||reportSalt.length<32)throw Error();}catch{configured=false;key=undefined;}}
 const head=()=>db.doc('repair_knowledge/published');
 // Source of truth survives Windows uninstall, app reset and device replacement.
 // Protected server-only version docs are append-only, never client-written.
 const versionRef=sequence=>db.doc('repair_knowledge/version-'+sequence);
 function envelope(sequence,p,proofExpiresAt){
  const issuedAt=now();const expiresAt=Math.min(issuedAt+DAY,proofExpiresAt||issuedAt+DAY);
  const payload=Buffer.from(JSON.stringify({protocol:PROTOCOL,purpose:'vidya-sync-repair',sequence,issuedAt,expiresAt,...p})).toString('base64url');
  return {keyId,payload,signature:sign(null,Buffer.from(payload),key).toString('base64url')};
 }
 function proof(value,p){return value?.passed===true&&value.protocol===PROTOCOL&&value.suite==='shared-repair-policy-v1'&&value.policyHash===policyHash(p)&&/^[a-f0-9]{40}$/.test(value.sourceCommit||'')&&Number.isSafeInteger(value.expiresAt)&&value.expiresAt>now()&&Number.isSafeInteger(value.verifiedAt)&&value.verifiedAt<=now()&&value.expiresAt-value.verifiedAt<=7*DAY&&value.expiresAt>value.verifiedAt;}
 function ready(){if(!configured||!key)fail(503,'REPAIR_KNOWLEDGE_DISABLED');}
 async function published(){
  ready();return db.runTransaction(async tx=>{
   const r=head(),saved=await tx.get(r);if(!saved.exists)return null;
   const old=saved.data();if(!Number.isSafeInteger(old.sequence)||old.sequence<1)fail(503,'REPAIR_KNOWLEDGE_STATE');
   const p=policy(old.policy),proofRow=p.enabled?await tx.get(db.doc('repair_knowledge_evidence/'+old.evidenceId)):null;
   // Expired/revoked evidence disables the policy. A new signed sequence also
   // distributes the kill switch; it never reuses an older sequence.
   const usable=!p.enabled||proof(proofRow?.data(),p);
   if(usable&&old.expiresAt>now()+3600000)return old.envelope;
   const next=usable?p:{enabled:false,rules:[]},sequence=old.sequence+1,e=envelope(sequence,next,usable&&next.enabled?proofRow.data().expiresAt:undefined);
   const archive=versionRef(sequence);
   if((await tx.get(archive)).exists)fail(409,'REPAIR_KNOWLEDGE_ARCHIVE_CONFLICT');
   const expiresAt=JSON.parse(Buffer.from(e.payload,'base64url')).expiresAt;
   const publication={...old,sequence,policy:next,envelope:e,expiresAt};
   tx.set(archive,{protocol:PROTOCOL,sequence,policy:next,envelope:e,
     policyHash:policyHash(next),publishedAt:now(),evidenceId:next.enabled?old.evidenceId:null,
     previousSequence:old.sequence,disabledByExpiredEvidence:!usable});
   tx.set(r,publication);return e;
  });
 }
 async function ingest(identity,body){
  exact(body,['batchId','reports']);const rows=reports(body.reports);
  if(!/^[a-f0-9]{64}$/.test(body.batchId||''))fail(400,'REPAIR_KNOWLEDGE_REPORT');
  if(!rows.length)return;
  // Authenticated source is private, salted and never returned to schools.
  const source=createHmac('sha256',reportSalt).update(identity.schoolId).digest('hex');
  await db.runTransaction(async tx=>{
   const sourceRef=db.doc('repair_knowledge_sources/'+source),catalogRef=db.doc('repair_knowledge/catalog');
   const [prior,catalog]=await Promise.all([tx.get(sourceRef),tx.get(catalogRef)]),p=prior.data()||{},hour=Math.floor(now()/3600000);
   const ids=p.hour===hour&&Array.isArray(p.batchIds)?p.batchIds:[];if(ids.includes(body.batchId))return;
   const count=p.hour===hour?p.count:0;if(count>=6)fail(429,'REPAIR_KNOWLEDGE_REPORT_LIMIT');
   const patterns={...(catalog.data()?.patterns||{})};
   for(const row of rows){const id=hash(JSON.stringify(row));
    if(!patterns[id]&&Object.keys(patterns).length>=1000)continue;
    patterns[id]={...row,observations:Math.min(1000000000,(patterns[id]?.observations||0)+1),lastHour:hour,untrusted:true};
   }
   tx.set(sourceRef,{hour,count:count+1,batchIds:[...ids,body.batchId]});tx.set(catalogRef,{protocol:PROTOCOL,patterns});
  });
 }
 return {
  async pull(identity,b){ready();
   if(!/^vs-[a-f0-9]{32}$/.test(identity?.schoolId||''))fail(403,'REPAIR_KNOWLEDGE_IDENTITY');
   exact(b,['batchId','reports']);
   if(b.reports!==undefined){try{await ingest(identity,b);}catch(e){if(e.status!==429)throw e;}}
   else if(b.batchId!==undefined)fail(400,'REPAIR_KNOWLEDGE_REPORT');
   return {repairKnowledgeProtocol:PROTOCOL,envelope:await published()};
  },
  async status(){const saved=await head().get(),catalog=await db.doc('repair_knowledge/catalog').get();
   return {configured,sequence:saved.data()?.sequence||0,policy:saved.data()?.policy||{enabled:false,rules:[]},patterns:Object.values(catalog.data()?.patterns||{})};
  },
  async publish(input,uid){ready();exact(input,['expectedSequence','policy','evidenceId']);const p=policy(input.policy);
   if(!Number.isSafeInteger(input.expectedSequence)||input.expectedSequence<0||typeof uid!=='string'||!uid)fail(400,'REPAIR_KNOWLEDGE_PUBLISH');
   if(p.enabled&&!/^[a-f0-9]{64}$/.test(input.evidenceId||''))fail(400,'REPAIR_KNOWLEDGE_EVIDENCE');
   return db.runTransaction(async tx=>{
    const r=head(),old=await tx.get(r),sequence=old.data()?.sequence||0;
    const evidence=p.enabled?await tx.get(db.doc('repair_knowledge_evidence/'+input.evidenceId)):null;
    if(sequence!==input.expectedSequence)fail(409,'REPAIR_KNOWLEDGE_VERSION_CONFLICT');
    if(p.enabled&&!proof(evidence?.data(),p))fail(409,'REPAIR_KNOWLEDGE_EVIDENCE');
    const e=envelope(sequence+1,p,p.enabled?evidence.data().expiresAt:undefined);
    const archive=versionRef(sequence+1);
    if((await tx.get(archive)).exists)fail(409,'REPAIR_KNOWLEDGE_ARCHIVE_CONFLICT');
    const expiresAt=JSON.parse(Buffer.from(e.payload,'base64url')).expiresAt;
    const record={protocol:PROTOCOL,sequence:sequence+1,policy:p,
      policyHash:policyHash(p),evidenceId:p.enabled?input.evidenceId:null,
      envelope:e,expiresAt,publishedBy:uid,publishedAt:now(),previousSequence:sequence};
    tx.set(archive,record);
    tx.set(r,record);return {sequence:sequence+1,envelope:e};
   });
  }
 };
}
module.exports={createRepairKnowledge,policy,policyHash,reports,MODULES,CATEGORIES,CODES,ACTIONS};
