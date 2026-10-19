'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {fixture,A}=require('./helpers/managed-school-broker');
test('management presence uses identity and registry, so a previously issued presence token cannot bypass revoke',async()=>{
 const states=new Map();let tail=Promise.resolve();
 const deviceStore={transaction(school,work){const result=tail.then(async()=>{
  const change=await work(states.has(school)?structuredClone(states.get(school)):null);
  states.set(school,structuredClone(change.state));return change.result;
 });tail=result.catch(()=>{});return result;}};
 const f=fixture(undefined,{deviceManagementEnabled:true,deviceStore});
 const headers=n=>({authorization:'Bearer A','x-vidya-device-id':String(n).padStart(32,'0'),'x-vidya-device-credential':String(n).repeat(43)});
 const call=(n,action,body={})=>f.handle({method:'POST',headers:headers(n),body:{action,schoolId:A,...body}});
 const first=await call(1,'managed/device/register',{deviceName:'Office',deviceOs:'Windows'});
 const second=await call(2,'managed/device/register',{deviceName:'Accounts',deviceOs:'Windows'});
 assert.equal(first.deviceManaged,true);assert.equal(first.offlineLease,undefined);
 const session=await call(2,'managed/session');
 assert.equal(session.deviceManaged,true);assert.equal(session.deviceEnforced,false);
 assert.equal(session.offlineLease,undefined);assert.ok(session.presenceToken);
 assert.equal((await call(2,'managed/presence',{presenceToken:session.presenceToken})).success,true);
 await call(1,'managed/device/revoke',{targetDeviceIdentity:second.device.deviceIdentity});
 await assert.rejects(call(2,'managed/presence',{presenceToken:session.presenceToken}),{code:'DEVICE_AUTHORIZATION_REJECTED'});
 await assert.rejects(f.call({action:'managed/presence',schoolId:A,presenceToken:session.presenceToken}),{code:'DEVICE_PROOF_REQUIRED'});
 const list=await call(1,'managed/device/list');assert.equal(list.devices.filter(d=>d.current).length,1);
 assert.equal(f.docs.get('school_memberships/A').active,true);
});

test('enrollment preserves legacy session/presence even when directory storage fails',async()=>{
 const {time}=require('./helpers/managed-school-broker');
 const {createManagedDeviceRegistry}=require('../managed-device-registry');
 const states=new Map(),scheduled=[];let clock=time,broken=false;
 const deviceStore={async transaction(school,work){
  if(broken)throw Error('Synthetic metadata outage');
  const change=await work(states.has(school)?structuredClone(states.get(school)):null);
  states.set(school,structuredClone(change.state));return change.result;
 }};
 const f=fixture(undefined,{deviceEnrollmentEnabled:true,deviceStore,now:()=>clock,scheduleHint:fn=>scheduled.push(fn)});
 const session=await f.call({action:'managed/session'});
 assert.equal(session.allowed,true);assert.equal(session.deviceEnforced,false);
 await scheduled.shift()(); // No device proof: optional migration does nothing.
 const headers={authorization:'Bearer A','x-vidya-device-id':'E'.repeat(32),'x-vidya-device-credential':'F'.repeat(43)};
 const call=(action,body={})=>f.handle({method:'POST',headers,body:{action,schoolId:A,...body}});
 await assert.rejects(call('managed/device/register'),{code:'DEVICE_ROLLOUT_DISABLED'});
 await call('managed/device/register',{deviceManagementProtocol:2,deviceName:'Enrollment PC',deviceOs:'Windows'});
 const registry=createManagedDeviceRegistry({store:deviceStore,schoolId:A,now:()=>clock});
 const actor={schoolId:A,uid:'A',role:'school_admin'};
 clock+=61000;
 const p=await call('managed/presence',{presenceToken:session.presenceToken});assert.equal(p.success,true);
 assert.equal((await registry.list(actor))[0].lastSeenAt,time);
 await scheduled.shift()();
 assert.equal((await registry.list(actor))[0].lastSeenAt,clock);
 broken=true;
 assert.equal((await f.call({action:'managed/session'})).allowed,true);
 assert.equal((await call('managed/presence',{presenceToken:session.presenceToken})).success,true);
 await scheduled.shift()(); // Optional failure is contained, never changes the ACK.
 assert.equal((await f.call({action:'managed/session'})).allowed,true);
 assert.equal(f.docs.get('school_memberships/A').active,true);
});

test('two restored school sessions enroll in the background without touching school records or sync ACKs',async()=>{
 const {time}=require('./helpers/managed-school-broker');
 const states=new Map(),scheduled=[];let tail=Promise.resolve(),broken=false;
 const store={transaction(school,work){const p=tail.then(async()=>{
  if(broken)throw Error('Metadata unavailable');
  const change=await work(states.has(school)?structuredClone(states.get(school)):null);
  states.set(school,structuredClone(change.state));return change.result;
 });tail=p.catch(()=>{});return p;}};
 const f=fixture(undefined,{deviceEnrollmentEnabled:true,deviceStore:store,now:()=>time+3600000,scheduleHint:fn=>scheduled.push(fn)});
 const headers=n=>({authorization:'Bearer A','x-vidya-device-id':String(n).repeat(32),'x-vidya-device-credential':String(n).repeat(43)});
 const call=(n,action)=>f.handle({method:'POST',headers:headers(n),body:{schoolId:A,action,deviceName:n===1?'Office':'Accounts'}});
 for(const n of [1,2]) assert.equal((await call(n,'managed/session')).allowed,true);
 assert.equal(states.size,0);
 while(scheduled.length)await scheduled.shift()();
 const directory=await call(1,'managed/device/list');
 assert.equal(directory.devices.length,2);assert.equal(directory.devices.filter(r=>r.current).length,1);
 assert.equal(directory.devices.find(r=>r.current).name,'Office');assert.equal(directory.canRevoke,false);
 assert.equal((await call(2,'managed/device/list')).devices.find(r=>r.current).name,'Accounts');
 assert.equal(f.sent.length,0); // No Drive/Script write, fake ACK or queue operation.
 assert.equal(f.docs.get('school_memberships/A').active,true);
 broken=true;assert.equal((await call(1,'managed/session')).allowed,true);
 while(scheduled.length)await scheduled.shift()();
 assert.equal((await call(2,'managed/session')).allowed,true);
 while(scheduled.length)await scheduled.shift()();
});
