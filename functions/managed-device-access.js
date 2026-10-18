'use strict';
const {createPrivateKey,createPublicKey,sign,verify}=require('node:crypto');
const {createManagedDeviceRegistry}=require('./managed-device-registry');
const MAX_OFFLINE_MS=15*60*1000;
function reject(status,code){const error=new Error(code);error.status=status;error.code=code;error.publicMessage=true;throw error;}
function header(req,key){const value=req?.headers?.[key];if(typeof value!=='string')reject(401,'DEVICE_PROOF_REQUIRED');return value;}
/** Insert ONLY after existing identity(req, body.schoolId) has checked Firebase
 * revocation, active school-admin membership and current entitlement. Never pass
 * a request's asserted identity here. Mobile/developer routes run before this.
 * Enabling enforcement must be an explicit TEST-approved server configuration.
 */
function createManagedDeviceAccess({store,enforced=false,managementEnabled=false,enrollmentEnabled=false,offlinePrivateKey,now=Date.now}){
 let key;
 if(enforced){if(!offlinePrivateKey)throw new Error('Offline device signing key required for enforced rollout');
  key=typeof offlinePrivateKey==='string'||Buffer.isBuffer(offlinePrivateKey)?createPrivateKey(offlinePrivateKey):offlinePrivateKey;
  if(key.type!=='private'||key.asymmetricKeyType!=='ed25519')throw new Error('Ed25519 offline device key required');}
 function context(identity,body){if(!/^vs-[a-f0-9]{32}$/.test(identity?.schoolId)||typeof identity.uid!=='string'||!identity.uid)reject(403,'DEVICE_VERIFIED_IDENTITY_REQUIRED');
  if(body.schoolId!==undefined&&body.schoolId!==identity.schoolId)reject(403,'DEVICE_SCHOOL_MISMATCH');
  return {...identity,role:'school_admin'};}
 function lease(auth,device,entitlement){const issuedAt=now(),expiresAt=Math.min(Number(entitlement.expiresAt),issuedAt+MAX_OFFLINE_MS);
  if(entitlement.allowed!==true||!Number.isSafeInteger(expiresAt)||expiresAt<=issuedAt)reject(403,'DEVICE_ENTITLEMENT_EXPIRED');
  const data={version:1,purpose:'vidya-pc-offline',schoolId:auth.schoolId,uid:auth.uid,deviceIdentity:device.deviceIdentity,generationHash:device.generationHash,issuedAt,expiresAt};
  const payload=Buffer.from(JSON.stringify(data)).toString('base64url');return {offlineLease:payload+'.'+sign(null,Buffer.from(payload),key).toString('base64url'),offlineExpiresAt:expiresAt,device};}
 return {async observePresence(req,presence){
  // Optional display metadata only. Never change the legacy presence result.
  if(!enrollmentEnabled||enforced||managementEnabled)return;
  try{
   if(!/^vs-[a-f0-9]{32}$/.test(presence?.schoolId)||typeof presence.uid!=='string')return;
   const registry=createManagedDeviceRegistry({store,schoolId:presence.schoolId,now});
   await registry.verify({deviceId:header(req,'x-vidya-device-id'),credential:header(req,'x-vidya-device-credential')});
  }catch{/* Missing/stale device metadata cannot interrupt existing access. */}
 },async authorize({req,body,identity,entitlement}){
  const action=body?.action;
  // Independent Android school-session and developer protocols are preserved.
  if(action==='managed/mobile'||typeof action!=='string'||!action.startsWith('managed/'))return {handled:false,mode:'non_pc'};
  const auth=context(identity,body),isDeviceAction=action.startsWith('managed/device/');
  if(!enforced&&!managementEnabled&&(!enrollmentEnabled||!isDeviceAction)){if(isDeviceAction)reject(503,'DEVICE_ROLLOUT_DISABLED');return {handled:false,mode:'legacy_unenforced',deviceEnforced:false};}
  if(entitlement?.allowed!==true||Number(entitlement.expiresAt)<=now())reject(403,'DEVICE_ENTITLEMENT_EXPIRED');
  const enrollmentOnly=!enforced&&!managementEnabled;
  if(enrollmentOnly&&action==='managed/device/register'&&body.deviceManagementProtocol!==2)reject(503,'DEVICE_ROLLOUT_DISABLED');
  if(enrollmentOnly&&action==='managed/device/revoke')reject(503,'DEVICE_ENFORCEMENT_REQUIRED');
  const mode=enforced?'enforced':enrollmentOnly?'enrollment':'managed';
  const access=device=>enforced?{deviceEnforced:true,...lease(auth,device,entitlement)}:{deviceManaged:true,deviceEnforced:false,...(enrollmentOnly?{deviceEnrollmentOnly:true}:{}),device};
  const proof={deviceId:header(req,'x-vidya-device-id'),credential:header(req,'x-vidya-device-credential')};
  const registry=createManagedDeviceRegistry({store,schoolId:auth.schoolId,now,requireFreshAuthentication:true});
  if(action==='managed/device/register'){
   // Device retries present the same locally persisted credential, not a newly
   // generated secret. A revoked device must reauthenticate and use a new one.
   const device=await registry.register(auth,{...proof,name:body.deviceName,os:body.deviceOs});
   return {handled:true,mode,result:{success:true,schoolId:auth.schoolId,...access(device)}};
  }
  // Every protected request reads the registry transactionally: no cached
  // presence/session/offline lease may authorize an online server request.
  const device=await registry.verify(proof);
  if(action==='managed/device/check')return {handled:true,mode,result:{success:true,schoolId:auth.schoolId,...access(device)}};
  if(action==='managed/device/list')return {handled:true,mode,result:{success:true,schoolId:auth.schoolId,serverTime:now(),deviceLimit:5,canRevoke:!enrollmentOnly,recentActivityWindowMs:120000,devices:(await registry.list(auth)).map(row=>({...row,current:row.deviceIdentity===device.deviceIdentity}))}};
  if(action==='managed/device/revoke'){
   const target=await registry.revoke(auth,{currentDeviceId:proof.deviceId,currentCredential:proof.credential,targetDeviceIdentity:body.targetDeviceIdentity});
   return {handled:true,mode,result:{success:true,schoolId:auth.schoolId,device:target}};
  }
  if(isDeviceAction)reject(400,'UNKNOWN_DEVICE_ACTION');
  if(action==='managed/session')return {handled:false,mode,...access(device)};
  return {handled:false,mode,deviceManaged:managementEnabled,deviceEnforced:enforced,device};
 }};
}
/** Pure signature/context check for independently cached OFFLINE access only.
 * This cannot prove immediate offline revocation: max15min limits that window.
 * Online routes MUST call authorize and check current registry, never this.
 * Windows must pin the configured Ed25519 public key and expected generation.
 */
function verifyOfflineDeviceLease(token,{publicKey,schoolId,uid,deviceIdentity,generationHash,now=Date.now}){
 if(typeof token!=='string'||token.length>4096)reject(401,'INVALID_OFFLINE_DEVICE_LEASE');
 const parts=token.split('.');if(parts.length!==2||! /^[A-Za-z0-9_-]+$/.test(parts[0])||! /^[A-Za-z0-9_-]{86}$/.test(parts[1]))reject(401,'INVALID_OFFLINE_DEVICE_LEASE');
 try{const key=typeof publicKey==='string'||Buffer.isBuffer(publicKey)?createPublicKey(publicKey):publicKey;
  if(key?.asymmetricKeyType!=='ed25519'||!verify(null,Buffer.from(parts[0]),key,Buffer.from(parts[1],'base64url')))reject(401,'INVALID_OFFLINE_DEVICE_LEASE');
 }catch{reject(401,'INVALID_OFFLINE_DEVICE_LEASE');}
 let payload;try{payload=JSON.parse(Buffer.from(parts[0],'base64url').toString('utf8'));}catch{reject(401,'INVALID_OFFLINE_DEVICE_LEASE');}
 const t=now();if(!Number.isSafeInteger(t)||t<0)reject(401,'INVALID_OFFLINE_DEVICE_LEASE');
 if(payload.version!==1||payload.purpose!=='vidya-pc-offline'||payload.schoolId!==schoolId||payload.uid!==uid||payload.deviceIdentity!==deviceIdentity||payload.generationHash!==generationHash||
  !Number.isSafeInteger(payload.issuedAt)||!Number.isSafeInteger(payload.expiresAt)||payload.issuedAt>t||payload.expiresAt<=t||payload.expiresAt<=payload.issuedAt||payload.expiresAt-payload.issuedAt>MAX_OFFLINE_MS)reject(401,'INVALID_OFFLINE_DEVICE_LEASE');
 return payload;
}
module.exports={createManagedDeviceAccess,verifyOfflineDeviceLease,MAX_OFFLINE_MS};
