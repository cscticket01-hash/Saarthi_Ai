'use strict';
const {randomBytes,randomUUID,createHash,timingSafeEqual}=require('node:crypto');
const DAY=86400000,MAX_ACTIVE=5,MAX_RECENT=100;
const digest=value=>createHash('sha256').update(value).digest('hex');
function deny(status,code){const error=new Error(code);error.status=status;error.code=code;throw error;}
function generateDeviceCredential(){return randomBytes(32).toString('base64url');}
// Fixed-size append-only revocation filters. False positives reject a candidate
// credential safely (generate a new credential); removed hashes never become
// valid again. No 1,000-revocation admission cliff or unbounded aggregate growth.
const FILTER_BYTES=16384;
function filterPositions(value){const bytes=createHash('sha256').update(value).digest();return Array.from({length:7},(_,n)=>bytes.readUInt32BE(n*4)%(FILTER_BYTES*8));}
function filterHas(encoded,value){if(!encoded)return false;const bytes=Buffer.from(encoded,'base64');if(bytes.length!==FILTER_BYTES)deny(503,'DEVICE_REVOCATION_FILTER_INVALID');return filterPositions(value).every(n=>(bytes[n>>3]&(1<<(n&7)))!==0);}
function filterAdd(encoded,value){const bytes=encoded?Buffer.from(encoded,'base64'):Buffer.alloc(FILTER_BYTES);if(bytes.length!==FILTER_BYTES)deny(503,'DEVICE_REVOCATION_FILTER_INVALID');for(const n of filterPositions(value))bytes[n>>3]|=1<<(n&7);return bytes.toString('base64');}
/** Foundation only: callers MUST supply server-authenticated school-admin identity.
 * Not connected to routes. No authority is inferred from request-body school IDs.
 * A credential is generated and durably saved by the device before registration,
 * so a lost response can be retried without issuing a second active credential.
 */
function createManagedDeviceRegistry({store,schoolId,now=Date.now,requireFreshAuthentication=false}){
 if(!/^vs-[a-f0-9]{32}$/.test(schoolId)||!store?.transaction)throw new Error('Invalid registry configuration');
 function actor(auth){if(auth?.schoolId!==schoolId||auth.role!=='school_admin'||typeof auth.uid!=='string'||!auth.uid)deny(403,'DEVICE_ADMIN_REQUIRED');}
 function device(value){if(typeof value!=='string'||! /^[A-Za-z0-9_-]{32,128}$/.test(value))deny(400,'INVALID_DEVICE_ID');return digest(value);}
 function secret(value){if(typeof value!=='string'||! /^[A-Za-z0-9_-]{43}$/.test(value))deny(400,'INVALID_DEVICE_CREDENTIAL');return digest(schoolId+'\n'+value);}
 function prune(state,t){if(state.schoolId!==schoolId||state.schemaVersion!==1||!state.devices||Array.isArray(state.devices))deny(403,'FOREIGN_DEVICE_REGISTRY');
  const devices={};for(const [id,row] of Object.entries(state.devices)){
   if(row.schoolId!==schoolId||row.deviceIdentity!==id||!['active','revoked'].includes(row.status))deny(403,'FOREIGN_DEVICE_REGISTRY');
   if(row.status==='active'||row.revokedAt>t-DAY)devices[id]={...row};
  }const next={...state,devices};
  // Lossless adoption of the earlier foundation's explicit retired hashes.
  for(const [credential,id] of Object.entries(state.revokedCredentials||{})){
   next.revokedCredentialFilter=filterAdd(next.revokedCredentialFilter,credential);
   next.revokedDeviceFilter=filterAdd(next.revokedDeviceFilter,id);
  }
  delete next.revokedCredentials;return next;}
 function equal(a,b){return typeof a==='string'&&/^[a-f0-9]{64}$/.test(a)&&timingSafeEqual(Buffer.from(a,'hex'),Buffer.from(b,'hex'));}
 function valid(state,id,credential){const row=state.devices[id];if(!row||row.status!=='active'||!equal(row.credentialHash,credential))deny(401,'DEVICE_AUTHORIZATION_REJECTED');return row;}
 // Optional display hint; not an access-control input.
 function connectionMetadata(value,t){return value==='WiFi'||value==='LAN' ? {connectionType:value,connectionSeenAt:t}:{};}
 function safe(row,t){return {deviceIdentity:row.deviceIdentity,name:row.name,os:row.os,type:row.type,status:row.status,
  generationHash:digest(row.credentialHash+'\n'+row.authorizedAt),authorizedAt:row.authorizedAt,lastSeenAt:row.lastSeenAt,connectionType:row.connectionType||'Unknown',connectionSeenAt:row.connectionSeenAt||null,...(row.status==='revoked'?{revokedAt:row.revokedAt}:{}),
  // Absence of a recent heartbeat is not proof that the PC is offline.
  activity:row.status==='active'?(t>=row.lastSeenAt&&t-row.lastSeenAt<=120000?'recently_seen':'unknown'):'revoked'};}
 async function transact(work){const t=now();if(!Number.isSafeInteger(t)||t<0)throw new Error('Invalid server clock');
  return store.transaction(schoolId,async existing=>work(prune(existing||{schemaVersion:1,schoolId,devices:{}},t),t));}
 function audit(auth,id,event,t){return {eventId:randomUUID(),schoolId,deviceIdentity:id,actorHash:digest(auth.uid),event,at:t};}
 return {
  async register(auth,input,{existingSessionEnrollment=false}={}){actor(auth);const id=device(input.deviceId),credential=secret(input.credential);
   const name=String(input.name||'Windows PC').trim(),os=String(input.os||'Windows').trim();
   if(!name||name.length>100||os.length>80||/[\x00-\x1f]/.test(name+os))deny(400,'INVALID_DEVICE_METADATA');
   return transact((state,t)=>{const old=state.devices[id];
    if(old?.status==='active'){if(!equal(old.credentialHash,credential))deny(409,'DEVICE_CREDENTIAL_CONFLICT');
     if(existingSessionEnrollment){if(t-old.lastSeenAt>=60000)old.lastSeenAt=t;
      if(input.name!==undefined)old.name=name;if(input.os!==undefined)old.os=os;}
     Object.assign(old,connectionMetadata(input.connectionType,t));
     return {state,result:{...safe(old,t),duplicate:true}};}
    // Enrollment-only migration accepts an already verified school session for
    // a never-registered PC. It cannot resurrect a revoked/pruned identity.
    if(existingSessionEnrollment&&(old||filterHas(state.revokedDeviceFilter,id)))deny(401,'DEVICE_AUTHORIZATION_REJECTED');
    if(requireFreshAuthentication&&!existingSessionEnrollment&&(!Number.isSafeInteger(auth.authenticatedAt)||auth.authenticatedAt>t||t-auth.authenticatedAt>300000||old?.status==='revoked'&&auth.authenticatedAt<=old.revokedAt))deny(401,'DEVICE_FRESH_LOGIN_REQUIRED');
    if(filterHas(state.revokedCredentialFilter,credential)||old&&equal(old.credentialHash,credential))deny(401,'REAUTHORIZATION_REQUIRES_NEW_CREDENTIAL');
    if(Object.values(state.devices).filter(r=>r.status==='active').length>=MAX_ACTIVE)deny(409,'DEVICE_LIMIT_REACHED');
    if(Object.values(state.devices).some(r=>equal(r.credentialHash,credential)))deny(409,'DEVICE_CREDENTIAL_REUSED');
    if(!old&&Object.keys(state.devices).length>=MAX_RECENT)deny(429,'DEVICE_RECENT_HISTORY_LIMIT');
    const row={schoolId,deviceIdentity:id,credentialHash:credential,name,os,type:'pc',status:'active',authorizedAt:t,lastSeenAt:t,...connectionMetadata(input.connectionType,t)};
    state.devices[id]=row;return {state,audit:audit(auth,id,old||filterHas(state.revokedDeviceFilter,id)?'reauthorized':'registered',t),result:{...safe(row,t),duplicate:false}};
   });},
  async verify({deviceId,credential,connectionType}){const id=device(deviceId),proof=secret(credential);return transact((state,t)=>{
   const row=valid(state,id,proof);if(t-row.lastSeenAt>=60000)row.lastSeenAt=t;
   if(connectionType!==undefined && connectionType!==row.connectionType)
    Object.assign(row,connectionMetadata(connectionType,t));
   return {state,result:safe(row,t)};
  });},
  async revoke(auth,{currentDeviceId,currentCredential,targetDeviceId,targetDeviceIdentity}){actor(auth);
   if((targetDeviceId!==undefined)===(targetDeviceIdentity!==undefined))deny(400,'INVALID_DEVICE_TARGET');
   if(targetDeviceIdentity!==undefined&&!/^[a-f0-9]{64}$/.test(targetDeviceIdentity))deny(400,'INVALID_DEVICE_TARGET');
   const current=device(currentDeviceId),target=targetDeviceIdentity||device(targetDeviceId),proof=secret(currentCredential);
   if(current===target)deny(409,'CURRENT_DEVICE_PROTECTED');
   return transact((state,t)=>{valid(state,current,proof);const row=state.devices[target];
    if(!row)deny(404,'DEVICE_NOT_FOUND');if(row.status==='revoked')return {state,result:{...safe(row,t),duplicate:true}};
    state.revokedCredentialFilter=filterAdd(state.revokedCredentialFilter,row.credentialHash);state.revokedDeviceFilter=filterAdd(state.revokedDeviceFilter,target);row.status='revoked';row.revokedAt=t;return {state,audit:audit(auth,target,'revoked',t),result:{...safe(row,t),duplicate:false}};
   });},
  async list(auth){actor(auth);return transact((state,t)=>({state,result:Object.values(state.devices).map(row=>safe(row,t))}));}
 };
}
/** A single school aggregate is the transaction contention point: concurrent
 * admissions cannot each observe a free sixth slot. Audit entries are separate.
 * Never call this adapter with request-controlled collection names.
 */
function firestoreManagedDeviceStore(db){return {transaction(schoolId,work){if(!/^vs-[a-f0-9]{32}$/.test(schoolId))throw new Error('Invalid school');
 const ref=db.doc('managed_pc_registries/'+schoolId);
 return db.runTransaction(async tx=>{const snapshot=await tx.get(ref),change=await work(snapshot.exists?snapshot.data():null);
  tx.set(ref,change.state);if(change.audit)tx.create(ref.collection('audit').doc(change.audit.eventId),change.audit);return change.result;});
 }};}
module.exports={createManagedDeviceRegistry,firestoreManagedDeviceStore,generateDeviceCredential};
