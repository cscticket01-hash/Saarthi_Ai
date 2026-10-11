'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {createManagedDeviceRegistry,firestoreManagedDeviceStore,generateDeviceCredential}=require('../managed-device-registry');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32),admin={schoolId:A,uid:'admin-one',role:'school_admin'},DAY=86400000;
function fixture(){let clock=1000000,tail=Promise.resolve();const rows=new Map(),audits=[];
 const store={transaction(school,fn){const result=tail.then(async()=>{const change=await fn(rows.has(school)?structuredClone(rows.get(school)):null);rows.set(school,structuredClone(change.state));if(change.audit)audits.push(structuredClone(change.audit));return change.result;});tail=result.catch(()=>{});return result;}};
 return {rows,audits,registry:createManagedDeviceRegistry({store,schoolId:A,now:()=>clock}),setClock:t=>clock=t};}
const input=n=>({deviceId:String(n).padStart(32,'0'),credential:generateDeviceCredential(),name:'PC '+n,os:'Windows 11'});
test('concurrent sixth admission rejected; duplicate retries consume no extra slot',async()=>{
 const f=fixture(),devices=Array.from({length:6},(_,n)=>input(n));
 const results=await Promise.allSettled(devices.map(d=>f.registry.register(admin,d)));
 assert.equal(results.filter(r=>r.status==='fulfilled').length,5);
 assert.equal(results.find(r=>r.status==='rejected').reason.code,'DEVICE_LIMIT_REACHED');
 const repeated=await Promise.all(Array.from({length:10},()=>f.registry.register(admin,devices[0])));
 assert(repeated.every(r=>r.duplicate));assert.equal((await f.registry.list(admin)).length,5);assert.equal(f.audits.length,5);
});
test('foreign principals, forged credentials and duplicate credential assignment fail',async()=>{
 const f=fixture(),one=input(1);await f.registry.register(admin,one);
 await assert.rejects(f.registry.register({...admin,schoolId:B},input(2)),{code:'DEVICE_ADMIN_REQUIRED'});
 await assert.rejects(f.registry.list({...admin,role:'student'}),{code:'DEVICE_ADMIN_REQUIRED'});
 await assert.rejects(f.registry.register(admin,{...one,credential:generateDeviceCredential()}),{code:'DEVICE_CREDENTIAL_CONFLICT'});
 await assert.rejects(f.registry.register(admin,{...input(2),credential:one.credential}),{code:'DEVICE_CREDENTIAL_REUSED'});
 await assert.rejects(f.registry.verify({...one,credential:generateDeviceCredential()}),{code:'DEVICE_AUTHORIZATION_REJECTED'});
 await assert.rejects(f.registry.verify({...one,deviceId:input(99).deviceId}),{code:'DEVICE_AUTHORIZATION_REJECTED'});
});
test('current PC protected; revoked PC loses authorization while other PC remains valid',async()=>{
 const f=fixture(),one=input(1),two=input(2);await f.registry.register(admin,one);await f.registry.register(admin,two);
 const current={currentDeviceId:one.deviceId,currentCredential:one.credential};
 await assert.rejects(f.registry.revoke(admin,{...current,targetDeviceId:one.deviceId}),{code:'CURRENT_DEVICE_PROTECTED'});
 await assert.rejects(f.registry.revoke(admin,{...current,currentCredential:generateDeviceCredential(),targetDeviceId:two.deviceId}),{code:'DEVICE_AUTHORIZATION_REJECTED'});
 await f.registry.revoke(admin,{...current,targetDeviceId:two.deviceId});
 await assert.rejects(f.registry.verify(two),{code:'DEVICE_AUTHORIZATION_REJECTED'});
 assert.equal((await f.registry.verify(one)).status,'active');
 assert.equal((await f.registry.revoke(admin,{...current,targetDeviceId:two.deviceId})).duplicate,true);
 assert.equal(f.audits.filter(a=>a.event==='revoked').length,1);
});
test('revoked PC disappears at 24 hours; audit persists and old credential cannot reactivate',async()=>{
 const f=fixture(),one=input(1),two=input(2);await f.registry.register(admin,one);await f.registry.register(admin,two);
 await f.registry.revoke(admin,{currentDeviceId:one.deviceId,currentCredential:one.credential,targetDeviceId:two.deviceId});
 f.setClock(1000000+DAY-1);assert.equal((await f.registry.list(admin)).length,2);
 f.setClock(1000000+DAY);assert.equal((await f.registry.list(admin)).length,1);
 await assert.rejects(f.registry.register(admin,two),{code:'REAUTHORIZATION_REQUIRES_NEW_CREDENTIAL'});
 const replacement={...two,credential:generateDeviceCredential()};assert.equal((await f.registry.register(admin,replacement)).status,'active');
 await assert.rejects(f.registry.verify(two),{code:'DEVICE_AUTHORIZATION_REJECTED'});
 assert.equal((await f.registry.verify(replacement)).status,'active');assert.equal(f.audits.filter(a=>a.event==='revoked').length,1);assert.equal(f.audits.filter(a=>a.event==='reauthorized').length,1);
});
test('public metadata/audits/store contain no plaintext credentials and status never invents offline',async()=>{
 const f=fixture(),one=input(1);await f.registry.register(admin,one);
 assert(!JSON.stringify([...f.rows.values()]).includes(one.credential));assert(!JSON.stringify(f.audits).includes(one.credential));
 f.setClock(1000000+300000);const list=await f.registry.list(admin);assert.equal(list[0].activity,'unknown');assert(!JSON.stringify(list).includes('credential'));
 await f.registry.verify(one);assert.equal((await f.registry.list(admin))[0].activity,'recently_seen');
});
test('foreign data in aggregate fails closed without writes',async()=>{
 const f=fixture();f.rows.set(A,{schemaVersion:1,schoolId:B,devices:{}});
 await assert.rejects(f.registry.list(admin),{code:'FOREIGN_DEVICE_REGISTRY'});assert.equal(f.rows.get(A).schoolId,B);assert.equal(f.audits.length,0);
});
test('Firestore adapter uses school aggregate transaction and separate audit documents',async()=>{
 const calls=[];const ref={collection:name=>({doc:id=>({path:'audit/'+id,name})})};
 const db={doc:path=>{calls.push(path);return ref;},runTransaction:fn=>fn({get:async()=>({exists:false}),set:(...args)=>calls.push(['set',...args]),create:(...args)=>calls.push(['create',...args])})};
 const store=firestoreManagedDeviceStore(db);assert.equal(await store.transaction(A,async()=>({state:{schoolId:A},audit:{eventId:'event'},result:'done'})),'done');
 assert.equal(calls[0],'managed_pc_registries/'+A);assert.equal(calls[2][0],'create');assert.throws(()=>store.transaction('invalid',()=>{}));
});
