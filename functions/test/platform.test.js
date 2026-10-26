'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const domain = require('../domain');
const crypto = require('node:crypto');

function platform({ records = {}, claims = {}, schoolClaims = {admin:true}, backend = {}, tokens = [], messages = [] } = {}) {
 const store = new Map(Object.entries(records));
 function ref(key) {
  return { id:key.split('/').pop(), get:async()=>snapshot(key), create:async d=>{if(store.has(key))throw Error('Exists');store.set(key,d);}, update:async d=>store.set(key,{...store.get(key),...d}), set:async(d,o)=>store.set(key,o?.merge?{...store.get(key),...d}:d), delete:async()=>store.delete(key) };
 }
 function snapshot(key) { return { id:key.split('/').pop(),exists:store.has(key),data:()=>store.get(key),ref:ref(key) }; }
 function collection(name,filters=[]) {
  return {doc:id=>ref(name+'/'+id),add:async d=>ref(name+'/'+crypto.randomUUID()).create(d),where:(f,op,v)=>collection(name,[...filters,[f,v]]),get:async()=>({docs:[...store.keys()].filter(k=>k.startsWith(name+'/')&&filters.every(([f,v])=>store.get(k)[f]===v)).map(snapshot)})};
 }
 const database={collection,runTransaction:async action=>{const writes=[];const tx={get:r=>r.get(),set:(r,d,o)=>writes.push(()=>r.set(d,o)),create:(r,d)=>writes.push(()=>r.create(d)),update:(r,d)=>writes.push(()=>r.update(d))};const result=await action(tx);for(const write of writes)await write();return result;}};
 const admin={firestore:()=>database,auth:()=>({verifyIdToken:async()=>claims}),apps:[],initializeApp:(_,name)=>({name,auth:()=>({verifyIdToken:async()=>schoolClaims})}),messaging:()=>({sendEachForMulticast:async message=>{tokens.push(...message.tokens);messages.push(message);return {failureCount:0};}})};
 const context=vm.createContext({exports:{},Date,Buffer,AbortSignal,fetch:async()=>({json:async()=>backend}),require:name=>name==='firebase-admin'?admin:name==='firebase-functions/v2/https'?{onRequest:(_,h)=>h}:name==='node:crypto'?crypto:name==='./domain'?domain:null});
 vm.runInContext(fs.readFileSync(path.join(__dirname,'../platform.js'),'utf8'),context);
 async function request(body,authorization) {
  let code=200,value;const response={set(){},status(c){code=c;return this;},json(v){value=v;}};
  await context.exports.platformApi({method:'POST',headers:{authorization},body},response);
  return {code,value};
 }
 return {request,store,tokens,messages};
}
const now=Date.now();
const installed={['platform_installations/'+domain.hash('installation-long-school-a')]:{secretHash:domain.hash('secret-a'),schoolId:'school-one',trialStartedAt:now}};
const auth={installationId:'installation-long-school-a',installationSecret:'secret-a'};
test('schools cannot issue developer licence keys',async()=>{const p=platform({claims:{role:'student'}});const r=await p.request({action:'license/issue',schoolId:'school-one',days:365},'Bearer valid');assert.equal(r.code,403);assert.equal(p.store.size,0);});
test('a school cannot activate another school licence',async()=>{const p=platform({records:{...installed,['platform_licenses/'+domain.hash('VS-FOREIGN')]:{schoolId:'school-two',status:'active',expiresAt:now+domain.DAY}}});const r=await p.request({action:'license/activate',...auth,key:'VS-FOREIGN'});assert.equal(r.code,403);assert.equal(p.store.get('platform_installations/'+domain.hash(auth.installationId)).schoolId,'school-one');});
test('linking school Firebase requires its own admin proof',async()=>{const p=platform({records:installed,schoolClaims:{role:'student'}});const r=await p.request({action:'school/bind',...auth,projectId:'school-one',googleScriptUrl:'https://script.google.com/macros/s/ABC/exec',schoolIdToken:'school-user-token'});assert.equal(r.code,403);});
test('pairing rejects a Google Script configured for a foreign project',async()=>{const p=platform({records:installed,backend:{success:true,projectId:'school-two'}});const r=await p.request({action:'school/bind',...auth,projectId:'school-one',googleScriptUrl:'https://script.google.com/macros/s/ABC/exec',schoolIdToken:'school-admin-token'});assert.equal(r.code,403);assert.equal(p.store.has('platform_schools/school-one'),false);});
test('mobile registration rejects a foreign school session response',async()=>{const p=platform({records:{'platform_schools/school-one':{schoolId:'school-one',trialStartedAt:now,googleScriptUrl:'https://script.google.com/macros/s/ABC/exec'}},backend:{success:true,projectId:'school-two',role:'student',personId:'p-1'}});const r=await p.request({action:'mobile/register',projectId:'school-one',schoolSessionToken:'school-session',deviceId:'d'.repeat(40)});assert.equal(r.code,403);});
test('notice delivery contains only the issuing school tokens',async()=>{const p=platform({records:{...installed,'platform_schools/school-one':{trialStartedAt:now},'platform_mobile_sessions/a':{schoolId:'school-one',fcmToken:'own-token',expiresAt:now+domain.DAY},'platform_mobile_sessions/b':{schoolId:'school-two',fcmToken:'foreign-token',expiresAt:now+domain.DAY}}});const r=await p.request({action:'school/notice',...auth,noticeId:'notice-1',title:'Test',message:'School A only'});assert.equal(r.code,200);assert.deepEqual(p.tokens,['own-token']);});
test('changing school replaces previous notification sessions on the phone',async()=>{const p=platform({records:{'platform_schools/school-two':{schoolId:'school-two',trialStartedAt:now,googleScriptUrl:'https://script.google.com/macros/s/ABC/exec'},'platform_mobile_sessions/old':{schoolId:'school-one',deviceId:domain.hash('d'.repeat(40)),fcmToken:'old-token',expiresAt:now+domain.DAY}},backend:{success:true,projectId:'school-two',role:'student',personId:'p-2',expiresAt:now+domain.DAY}});const r=await p.request({action:'mobile/register',projectId:'school-two',schoolSessionToken:'school-session',deviceId:'d'.repeat(40),fcmToken:'new-token'});assert.equal(r.code,200);assert.equal(p.store.has('platform_mobile_sessions/old'),false);});

test('notices require the app to verify the school before displaying',async()=>{const p=platform({records:{...installed,'platform_schools/school-one':{trialStartedAt:now},'platform_mobile_sessions/a':{schoolId:'school-one',fcmToken:'own-token',expiresAt:now+domain.DAY}}});await p.request({action:'school/notice',...auth,noticeId:'notice-2',title:'Test',message:'Own school notice'});assert.equal(p.messages.length,1);assert.equal(p.messages[0].notification,undefined);assert.equal(p.messages[0].data.schoolId,'school-one');assert.equal(p.messages[0].data.body,'Own school notice');});
test('a paid key records purchase immediately even before activation',async()=>{const p=platform({records:{'platform_schools/school-one':{trialStartedAt:now}},claims:{admin:true,uid:'developer'}});const r=await p.request({action:'license/issue',schoolId:'school-one',days:365,paid:true},'Bearer valid');assert.equal(r.code,200);assert.equal(p.store.get('platform_schools/school-one').purchased,true);});
test('a complimentary activation does not erase a previous purchase',async()=>{const p=platform({records:{...installed,'platform_schools/school-one':{trialStartedAt:now,purchased:true},['platform_licenses/'+domain.hash('VS-FREE')]:{schoolId:'school-one',status:'active',expiresAt:now+domain.DAY,paid:false}}});const r=await p.request({action:'license/activate',...auth,key:'VS-FREE'});assert.equal(r.code,200);assert.equal(p.store.get('platform_schools/school-one').purchased,true);});
test('registration retries reuse the secure credential and original trial',async()=>{const p=platform();const b={action:'installation/register',installationId:'secure-installation-identity',installationSecret:'s'.repeat(43),deviceFingerprint:'a'.repeat(64)};const first=await p.request(b),again=await p.request(b);assert.equal(first.code,200);assert.equal(again.code,200);assert.equal(first.value.installationSecret,again.value.installationSecret);assert.equal(first.value.trialStartedAt,again.value.trialStartedAt);const foreign=await p.request({...b,installationSecret:'x'.repeat(43)});assert.equal(foreign.code,409);});
