'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {generateKeyPairSync,createHash}=require('node:crypto');
const {createManagedDeviceAccess,verifyOfflineDeviceLease,MAX_OFFLINE_MS}=require('../managed-device-access');
const {generateDeviceCredential,createManagedDeviceRegistry}=require('../managed-device-registry');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32),keys=generateKeyPairSync('ed25519');
const hash=value=>createHash('sha256').update(value).digest('hex');
function fixture(enforced=true,managementEnabled=false){let time=1000000,tail=Promise.resolve();const rows=new Map(),audit=[];
 const store={transaction(school,work){const result=tail.then(async()=>{const change=await work(rows.has(school)?structuredClone(rows.get(school)):null);rows.set(school,structuredClone(change.state));if(change.audit)audit.push(change.audit);return change.result;});tail=result.catch(()=>{});return result;}};
 const access=createManagedDeviceAccess({store,enforced,managementEnabled,offlinePrivateKey:keys.privateKey,now:()=>time});
 const identity={schoolId:A,uid:'school-admin',authenticatedAt:time};
 const entitlement={allowed:true,expiresAt:time+86400000};
 const proof=n=>({'x-vidya-device-id':String(n).padStart(32,'0'),'x-vidya-device-credential':generateDeviceCredential()});
 const call=(action,headers,body={},auth=identity,policy=entitlement)=>access.authorize({req:{headers},body:{action,schoolId:A,...body},identity:auth,entitlement:policy});
 return {rows,audit,store,identity,entitlement,access,proof,call,setTime:t=>time=t,time:()=>time};}
test('default rollout preserves explicit legacy mode and never pretends registry is enforced',async()=>{
 const f=fixture(false);assert.deepEqual(await f.call('managed/session',{}),{handled:false,mode:'legacy_unenforced',deviceEnforced:false});
 await assert.rejects(f.call('managed/device/register',f.proof(1)),{code:'DEVICE_ROLLOUT_DISABLED'});
 assert.equal(f.rows.size,0);assert.throws(()=>createManagedDeviceAccess({store:f.store,enforced:true}),/signing key/);
});
test('all PC managed actions require fresh device proof while mobile/developer stay independent',async()=>{
 const f=fixture(),headers=f.proof(1);await f.call('managed/device/register',headers);
 for(const action of ['managed/session','managed/records','managed/storage/connect','managed/disconnect','managed/import/commit','managed/future-action']){
  await assert.rejects(f.call(action,{}),{code:'DEVICE_PROOF_REQUIRED'});
  assert.equal((await f.call(action,headers)).mode,'enforced');
 }
 for(const action of ['managed/mobile','developer/managed/create'])assert.equal((await f.access.authorize({req:{},body:{action}})).mode,'non_pc');
});
test('foreign school/body and unknown credentials rejected; no request identity substitution',async()=>{
 const f=fixture(),headers=f.proof(1);await f.call('managed/device/register',headers);
 await assert.rejects(f.call('managed/session',headers,{schoolId:B}),{code:'DEVICE_SCHOOL_MISMATCH'});
 await assert.rejects(f.call('managed/session',headers,{},{}),{code:'DEVICE_VERIFIED_IDENTITY_REQUIRED'});
 await assert.rejects(f.call('managed/session',f.proof(1)),{code:'DEVICE_AUTHORIZATION_REJECTED'});
});
test('revocation is checked each request; cached offline lease cannot authorize online access',async()=>{
 const f=fixture(),one=f.proof(1),two=f.proof(2);
 await f.call('managed/device/register',one);const second=(await f.call('managed/device/register',two)).result;
 const listing=(await f.call('managed/device/list',one)).result.devices;assert.equal(listing.filter(d=>d.current).length,1);
 await assert.rejects(f.call('managed/device/revoke',one,{targetDeviceIdentity:listing.find(d=>d.current).deviceIdentity}),{code:'CURRENT_DEVICE_PROTECTED'});
 await f.call('managed/device/revoke',one,{targetDeviceIdentity:second.device.deviceIdentity});
 await assert.rejects(f.call('managed/records',two,{offlineLease:second.offlineLease}),{code:'DEVICE_AUTHORIZATION_REJECTED'});
 await assert.rejects(f.call('managed/device/register',{...two,'x-vidya-device-credential':generateDeviceCredential()}),{code:'DEVICE_FRESH_LOGIN_REQUIRED'});
 f.setTime(f.time()+1000);f.identity.authenticatedAt=f.time();
 const replacement={...two,'x-vidya-device-credential':generateDeviceCredential()};
 const reauthorized=(await f.call('managed/device/register',replacement)).result;
 assert.notEqual(reauthorized.device.generationHash,second.device.generationHash);
 await assert.rejects(f.call('managed/session',two),{code:'DEVICE_AUTHORIZATION_REJECTED'});
});
test('offline lease is signature/context/generation bound and expires within15min or licence expiry',async()=>{
 const f=fixture(),headers=f.proof(1),result=(await f.call('managed/device/register',headers)).result;
 const context={publicKey:keys.publicKey,schoolId:A,uid:f.identity.uid,deviceIdentity:result.device.deviceIdentity,generationHash:result.device.generationHash,now:f.time};
 assert.equal(verifyOfflineDeviceLease(result.offlineLease,context).expiresAt,f.time()+MAX_OFFLINE_MS);
 for(const wrong of [{schoolId:B},{uid:'foreign'},{deviceIdentity:'a'.repeat(64)},{generationHash:'b'.repeat(64)}])assert.throws(()=>verifyOfflineDeviceLease(result.offlineLease,{...context,...wrong}),{code:'INVALID_OFFLINE_DEVICE_LEASE'});
 assert.throws(()=>verifyOfflineDeviceLease(result.offlineLease.slice(0,-3)+'AAA',context),{code:'INVALID_OFFLINE_DEVICE_LEASE'});
 f.setTime(result.offlineExpiresAt);assert.throws(()=>verifyOfflineDeviceLease(result.offlineLease,context),{code:'INVALID_OFFLINE_DEVICE_LEASE'});
 f.setTime(1000000);const shorter=(await f.call('managed/device/check',headers,{},f.identity,{allowed:true,expiresAt:f.time()+5000})).result;
 assert.equal(shorter.offlineExpiresAt,f.time()+5000);
});
test('stale password authentication cannot admit new PC; same active retry remains idempotent',async()=>{
 const f=fixture(),headers=f.proof(1);await f.call('managed/device/register',headers);
 f.setTime(f.time()+300001);assert.equal((await f.call('managed/device/register',headers)).result.device.duplicate,true);
 await assert.rejects(f.call('managed/device/register',f.proof(2)),{code:'DEVICE_FRESH_LOGIN_REQUIRED'});
 await assert.rejects(f.call('managed/device/check',headers,{},f.identity,{allowed:false,expiresAt:f.time()+10000}),{code:'DEVICE_ENTITLEMENT_EXPIRED'});
});
test('old1000-hash history migrates into bounded filters without old credential reuse or capacity cliff',async()=>{
 const f=fixture(),retired=generateDeviceCredential(),entries={};
 for(let n=0;n<1001;n++)entries[hash(A+'\n'+(n===0?retired:'retired'+n))]=hash('device'+n);
 f.rows.set(A,{schemaVersion:1,schoolId:A,devices:{},revokedCredentials:entries});
 const registry=createManagedDeviceRegistry({store:f.store,schoolId:A,now:f.time});
 await registry.register({...f.identity,role:'school_admin'},{deviceId:'d'.repeat(32),credential:generateDeviceCredential()});
 const state=f.rows.get(A);assert.equal(state.revokedCredentials,undefined);assert.equal(Buffer.from(state.revokedCredentialFilter,'base64').length,16384);
 await assert.rejects(registry.register({...f.identity,role:'school_admin'},{deviceId:'e'.repeat(32),credential:retired}),{code:'REAUTHORIZATION_REQUIRES_NEW_CREDENTIAL'});
});

test('successful managed session includes signed offline authorization only in enforced mode',async()=>{
 const f=fixture(),headers=f.proof(1);await f.call('managed/device/register',headers);
 const session=await f.call('managed/session',headers);
 assert.equal(session.handled,false);assert.equal(session.deviceEnforced,true);
 assert.equal(verifyOfflineDeviceLease(session.offlineLease,{publicKey:keys.publicKey,schoolId:A,uid:f.identity.uid,
  deviceIdentity:session.device.deviceIdentity,generationHash:session.device.generationHash,now:f.time}).expiresAt,session.offlineExpiresAt);
 const legacy=await fixture(false).call('managed/session',{});
 assert.equal(legacy.deviceEnforced,false);assert.equal(legacy.offlineLease,undefined);
});

test('management mode preserves offline policy but checks registration and revocation online',async()=>{
 const f=fixture(false,true),one=f.proof(1),two=f.proof(2);
 const first=(await f.call('managed/device/register',one)).result;
 assert.equal(first.deviceManaged,true);assert.equal(first.deviceEnforced,false);
 assert.equal(first.offlineLease,undefined);
 const second=(await f.call('managed/device/register',two)).result;
 const session=await f.call('managed/session',one);
 assert.equal(session.deviceManaged,true);assert.equal(session.deviceEnforced,false);
 const list=(await f.call('managed/device/list',one)).result;
 assert.equal(list.devices.length,2);assert.equal(list.devices.filter(d=>d.current).length,1);
 assert.equal(list.deviceLimit,5);assert.equal(list.serverTime,f.time());
 await assert.rejects(f.call('managed/presence',{}),{code:'DEVICE_PROOF_REQUIRED'});
 await f.call('managed/device/revoke',one,{targetDeviceIdentity:second.device.deviceIdentity});
 for(const action of ['managed/session','managed/presence','managed/records']) {
  await assert.rejects(f.call(action,two),{code:'DEVICE_AUTHORIZATION_REJECTED'});
 }
 assert.equal((await f.call('managed/device/list',one)).result.devices.filter(d=>d.status==='active').length,1);
});
