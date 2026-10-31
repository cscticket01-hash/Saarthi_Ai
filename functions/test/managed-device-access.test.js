'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {generateKeyPairSync,createHash}=require('node:crypto');
const {createManagedDeviceAccess,verifyOfflineDeviceLease,MAX_OFFLINE_MS,DAILY_OFFLINE_MS}=require('../managed-device-access');
const {generateDeviceCredential,createManagedDeviceRegistry}=require('../managed-device-registry');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32),keys=generateKeyPairSync('ed25519');
const hash=value=>createHash('sha256').update(value).digest('hex');
function fixture(enforced=true,managementEnabled=false,enrollmentEnabled=false,offlineWindowMs=MAX_OFFLINE_MS){let time=1000000,tail=Promise.resolve();const rows=new Map(),audit=[];
 const store={transaction(school,work){const result=tail.then(async()=>{const change=await work(rows.has(school)?structuredClone(rows.get(school)):null);rows.set(school,structuredClone(change.state));if(change.audit)audit.push(change.audit);return change.result;});tail=result.catch(()=>{});return result;}};
 const access=createManagedDeviceAccess({store,enforced,managementEnabled,enrollmentEnabled,offlinePrivateKey:keys.privateKey,now:()=>time,offlineWindowMs});
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
test('opt-in daily offline device lease remains signed, identity-bound and capped at 24 hours',async()=>{
 const f=fixture(true,false,false,DAILY_OFFLINE_MS),headers=f.proof(1);
 const result=(await f.call('managed/device/register',headers)).result;
 const context={publicKey:keys.publicKey,schoolId:A,uid:f.identity.uid,
  deviceIdentity:result.device.deviceIdentity,generationHash:result.device.generationHash,now:f.time};
 assert.equal(result.offlineExpiresAt,f.time()+DAILY_OFFLINE_MS);
 assert.equal(verifyOfflineDeviceLease(result.offlineLease,{...context,maxOfflineMs:DAILY_OFFLINE_MS}).expiresAt,result.offlineExpiresAt);
 assert.throws(()=>verifyOfflineDeviceLease(result.offlineLease,context),{code:'INVALID_OFFLINE_DEVICE_LEASE'});
 assert.throws(()=>verifyOfflineDeviceLease(result.offlineLease,{...context,maxOfflineMs:DAILY_OFFLINE_MS,schoolId:B}),{code:'INVALID_OFFLINE_DEVICE_LEASE'});
 f.setTime(result.offlineExpiresAt);
 assert.throws(()=>verifyOfflineDeviceLease(result.offlineLease,{...context,maxOfflineMs:DAILY_OFFLINE_MS}),{code:'INVALID_OFFLINE_DEVICE_LEASE'});
 assert.throws(()=>createManagedDeviceAccess({store:f.store,enforced:true,offlinePrivateKey:keys.privateKey,offlineWindowMs:2*DAILY_OFFLINE_MS}),/Unsupported/);
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

test('enrollment mode keeps existing sync/session authorization exactly legacy and negotiates new clients',async()=>{
 const f=fixture(false,false,true),headers=f.proof(1);
 for(const action of ['managed/session','managed/records','managed/disconnect','managed/storage/connect']) {
  assert.deepEqual(await f.call(action,{}),{handled:false,mode:'legacy_unenforced',deviceEnforced:false});
 }
 await assert.rejects(f.call('managed/device/register',headers),{code:'DEVICE_ROLLOUT_DISABLED'});
 assert.equal(f.rows.size,0);
 const first=(await f.call('managed/device/register',headers,{deviceManagementProtocol:2})).result;
 assert.equal(first.deviceManaged,true);assert.equal(first.deviceEnforced,false);
 assert.equal(first.deviceEnrollmentOnly,true);assert.equal(first.offlineLease,undefined);
 const list=(await f.call('managed/device/list',headers)).result;
 assert.equal(list.canRevoke,false);assert.equal(list.devices.length,1);
 const before=structuredClone(f.rows.get(A));
 await assert.rejects(f.call('managed/device/revoke',headers,{targetDeviceIdentity:hash('other')}),{code:'DEVICE_ENFORCEMENT_REQUIRED'});
 assert.deepEqual(f.rows.get(A),before);
 f.setTime(f.time()+61000);
 await f.access.observePresence({headers},{schoolId:A,uid:f.identity.uid});
 const seen=(await createManagedDeviceRegistry({store:f.store,schoolId:A,now:f.time}).list({...f.identity,role:'school_admin'}))[0].lastSeenAt;
 assert.equal(seen,f.time());
 await f.access.observePresence({headers:{}},{schoolId:A,uid:f.identity.uid});
 await f.access.observePresence({headers},{schoolId:B,uid:f.identity.uid});
 assert.equal((await f.call('managed/device/list',headers)).result.devices.length,1);
});
test('enrollment still enforces school isolation, fresh registration and five-PC admission',async()=>{
 const f=fixture(false,false,true),body={deviceManagementProtocol:2};
 await assert.rejects(f.call('managed/device/register',f.proof(1),body,{...f.identity,authenticatedAt:f.time()-300001}),{code:'DEVICE_FRESH_LOGIN_REQUIRED'});
 for(let i=1;i<=5;i++) await f.call('managed/device/register',f.proof(i),body);
 await assert.rejects(f.call('managed/device/register',f.proof(6),body),{code:'DEVICE_LIMIT_REACHED'});
 await assert.rejects(f.call('managed/device/list',f.proof(7),{schoolId:B}),{code:'DEVICE_SCHOOL_MISMATCH'});
 assert.deepEqual(await f.call('managed/records',{}),{handled:false,mode:'legacy_unenforced',deviceEnforced:false});
});

test('restored school sessions enroll two real proofs without fresh password login',async()=>{
 const f=fixture(false,false,true),one=f.proof(1),two=f.proof(2);
 f.setTime(f.time()+3600000); // Refreshed Firebase tokens retain their old auth_time.
 const a=(await f.call('managed/device/list',one,{deviceName:'Office PC',deviceOs:'Windows'})).result;
 assert.equal(a.devices.length,1);assert.equal(a.devices[0].current,true);
 assert.equal(a.devices[0].name,'Office PC');assert.equal(a.canRevoke,false);
 await f.access.observeSession({headers:two},{action:'managed/session',schoolId:A,deviceName:'Accounts PC'},f.identity,f.entitlement);
 const b=(await f.call('managed/device/list',one)).result;
 assert.equal(b.devices.length,2);assert.equal(b.devices.filter(d=>d.current).length,1);
 assert.equal(b.devices.find(d=>d.current).deviceIdentity,a.devices[0].deviceIdentity);
 const other=(await f.call('managed/device/list',two)).result;
 assert.equal(other.devices.find(d=>d.current).name,'Accounts PC');
 assert.equal(f.audit.length,2);
 f.setTime(f.time()+61000);
 const again=(await f.call('managed/device/list',one,{deviceName:'Renamed office'})).result;
 const current=again.devices.find(d=>d.current);
 assert.equal(current.lastSeenAt,f.time());assert.equal(current.name,'Renamed office');
 assert.equal(current.generationHash,a.devices[0].generationHash);assert.equal(f.audit.length,2);
});
test('session migration never repairs revoked, pruned or conflicting device credentials',async()=>{
 const f=fixture(false,false,true),one=f.proof(1),two=f.proof(2);
 await f.call('managed/device/list',one);const second=(await f.call('managed/device/list',two)).result.devices.find(d=>d.current);
 const registry=createManagedDeviceRegistry({store:f.store,schoolId:A,now:f.time});
 const actor={...f.identity,role:'school_admin'};
 await registry.revoke(actor,{currentDeviceId:one['x-vidya-device-id'],currentCredential:one['x-vidya-device-credential'],targetDeviceIdentity:second.deviceIdentity});
 const before=structuredClone(f.rows.get(A));
 await assert.rejects(f.call('managed/device/list',two),{code:'DEVICE_AUTHORIZATION_REJECTED'});
 await assert.rejects(f.call('managed/device/list',{...two,'x-vidya-device-credential':generateDeviceCredential()}),{code:'DEVICE_AUTHORIZATION_REJECTED'});
 await assert.rejects(f.call('managed/device/list',{...one,'x-vidya-device-credential':generateDeviceCredential()}),{code:'DEVICE_CREDENTIAL_CONFLICT'});
 assert.deepEqual(f.rows.get(A),before);
 f.setTime(f.time()+86400001);f.entitlement.expiresAt=f.time()+86400000;
 await registry.list(actor); // Prune revoked display row, retaining revocation filter.
 assert.equal(f.rows.get(A).devices[second.deviceIdentity],undefined);
 await assert.rejects(f.call('managed/device/list',two),{code:'DEVICE_AUTHORIZATION_REJECTED'});
 await assert.rejects(f.call('managed/device/list',{...two,'x-vidya-device-credential':generateDeviceCredential()}),{code:'DEVICE_AUTHORIZATION_REJECTED'});
});
test('restored-session admission retains transactional five-PC limit and identity guards',async()=>{
 const f=fixture(false,false,true);f.setTime(f.time()+3600000);
 const attempts=await Promise.allSettled(Array.from({length:6},(_,n)=>f.call('managed/device/list',f.proof(n+1))));
 assert.equal(attempts.filter(r=>r.status==='fulfilled').length,5);
 assert.equal(attempts.find(r=>r.status==='rejected').reason.code,'DEVICE_LIMIT_REACHED');
 assert.equal(Object.keys(f.rows.get(A).devices).length,5);
 await assert.rejects(f.call('managed/device/list',{}),{code:'DEVICE_PROOF_REQUIRED'});
 await assert.rejects(f.call('managed/device/list',f.proof(7),{},f.identity,{allowed:false,expiresAt:f.time()+10000}),{code:'DEVICE_ENTITLEMENT_EXPIRED'});
 await assert.rejects(f.call('managed/device/list',f.proof(7),{schoolId:B}),{code:'DEVICE_SCHOOL_MISMATCH'});
 await assert.rejects(f.call('managed/device/list',f.proof(7),{},{...f.identity,authenticatedAt:undefined}),{code:'DEVICE_FRESH_LOGIN_REQUIRED'});
 for(const mode of [fixture(),fixture(false,true)]){
  await assert.rejects(mode.call('managed/device/list',mode.proof(1)),{code:'DEVICE_AUTHORIZATION_REJECTED'});
  assert.equal(mode.rows.size,0);
 }
});

test('two authenticated Windows PCs share last verified adapter hints across their lists',async()=>{
 const f=fixture(false,false,true),pcA=f.proof(1),pcB=f.proof(2);
 const a=(await f.call('managed/device/list',pcA,
  {deviceName:'Mohit_Das',deviceOs:'Windows',connectionType:'WiFi'})).result;
 assert.equal(a.canRevoke,false);
 const b=(await f.call('managed/device/list',pcB,
  {deviceName:'DESKTOP-TG22ER2',deviceOs:'Windows',connectionType:'LAN'})).result;
 assert.equal(b.devices.length,2);
 for(const proof of [pcA,pcB]) {
  const list=(await f.call('managed/device/list',proof)).result;
  assert.equal(list.devices.find(d=>d.name==='Mohit_Das').connectionType,'WiFi');
  assert.equal(list.devices.find(d=>d.name==='DESKTOP-TG22ER2').connectionType,'LAN');
  assert.equal(list.devices.filter(d=>d.current).length,1);
 }
 // Unverified adapters cannot erase an earlier legitimate report.
 await f.call('managed/device/list',pcA,{connectionType:'Unknown'});
 const after=(await f.call('managed/device/list',pcB)).result.devices;
 assert.equal(after.find(d=>d.name==='Mohit_Das').connectionType,'WiFi');
 // The caller must possess the original registered credential to change its hint.
 await assert.rejects(f.call('managed/device/list',
   {...pcA,'x-vidya-device-credential':generateDeviceCredential()},
   {connectionType:'LAN'}),{code:'DEVICE_CREDENTIAL_CONFLICT'});
 assert.equal(f.audit.length,2,'Connectivity hints cannot grant access or create devices');
});
