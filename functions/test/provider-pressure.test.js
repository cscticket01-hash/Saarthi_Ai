'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {createProviderPressure,retryAfterMillis,quotaError}=require('../provider-pressure');
const {fixture,A,B}=require('./helpers/managed-school-broker');
const {createCloudflareSync}=require('../cloudflare-sync');
test('quota gate isolates schools, waits, then clears only after success',async()=>{
 let at=1000,calls=0;const p=createProviderPressure({now:()=>at});
 const fail=()=>{calls++;throw quotaError('SCRIPT_QUOTA_EXCEEDED',120000);};
 await assert.rejects(p.run(A,'SCRIPT_QUOTA_EXCEEDED',fail),e=>e.status===429&&e.retryAfterMs===120000);
 await assert.rejects(p.run(A,'SCRIPT_QUOTA_EXCEEDED',fail));assert.equal(calls,1);
 assert.equal(await p.run(B,'SCRIPT_QUOTA_EXCEEDED',()=>42),42);
 at+=120000;assert.equal(await p.run(A,'SCRIPT_QUOTA_EXCEEDED',()=>42),42);
 assert.equal(await p.run(A,'SCRIPT_QUOTA_EXCEEDED',()=>43),43);
});
test('older success cannot clear a newer quota failure and writes are not replayed',async()=>{
 let finish,calls=0;const p=createProviderPressure({now:()=>1000});
 const slow=p.run(A,'CLOUDFLARE_QUOTA_EXCEEDED',()=>new Promise(r=>{finish=r;}));
 await assert.rejects(p.run(A,'CLOUDFLARE_QUOTA_EXCEEDED',()=>{calls++;throw quotaError('CLOUDFLARE_QUOTA_EXCEEDED');}));
 finish(1);await slow;
 await assert.rejects(p.run(A,'CLOUDFLARE_QUOTA_EXCEEDED',()=>{calls++;}));assert.equal(calls,1);
});
test('permission and conflict preserve their original error and do not close quota gate',async()=>{
 const p=createProviderPressure();for(const status of [403,409,503]){
 const original=Object.assign(Error('private upstream text'),{status});
 await assert.rejects(p.run(A,'SCRIPT_QUOTA_EXCEEDED',()=>{throw original;}),e=>e===original);
 assert.equal(await p.run(A,'SCRIPT_QUOTA_EXCEEDED',()=>1),1);
 }
});
test('Retry-After parses seconds/dates with a one-day safety bound',()=>{
 assert.equal(retryAfterMillis('120',1000),120000);
 assert.equal(retryAfterMillis('Thu, 01 Jan 1970 00:01:00 GMT',1000),59000);
 for(const v of [null,'','private error','-1'])assert.equal(retryAfterMillis(v,1000),0);
 assert.equal(retryAfterMillis('999999999',1000),86400000);
});
test('broker Google quota prevents additional Script requests in the same school',async()=>{
 const f=fixture(async(url,opt)=>({ok:true,status:200,text:async()=>JSON.stringify({success:false,schoolId:JSON.parse(opt.body).schoolId,code:'SCRIPT_QUOTA_EXCEEDED'})}));
 await assert.rejects(f.call({action:'managed/storage/quota',schoolId:A}),e=>e.code==='SCRIPT_QUOTA_EXCEEDED');
 await assert.rejects(f.call({action:'managed/storage/quota',schoolId:A}),e=>e.status===429);
 assert.equal(f.sent.length,1);
});
test('Firestore SDK exhaustion becomes safe quota evidence',async()=>{
 const f=fixture();f.db.doc=()=>{throw Object.assign(Error('private quota detail'),{code:8});};
 let calls=0;f.db.doc=()=>{calls++;throw Object.assign(Error('private quota detail'),{code:8});};
 await assert.rejects(f.call({action:'managed/storage/quota',schoolId:A}),e=>e.status===429&&e.code==='FIREBASE_QUOTA_EXCEEDED'&&!e.message.includes('private'));
 await assert.rejects(f.call({action:'managed/storage/quota',schoolId:B},'B'),e=>e.status===429);assert.equal(calls,1);
});
test('Cloudflare non-JSON 429 cancels body and prevents repeated fetch',async()=>{
 let calls=0,cancelled=false;const cf=createCloudflareSync({url:'https://example.com',key:'a'.repeat(32),schools:[A],now:()=>1000,fetchImpl:async()=>{
 calls++;return {status:429,headers:new Headers({'Retry-After':'120'}),body:{cancel:async()=>{cancelled=true;}}};
 }});
 await assert.rejects(cf.rpc(A,'notices',{command:'snapshot'}),e=>e.status===429&&e.code==='CLOUDFLARE_QUOTA_EXCEEDED'&&e.retryAfterMs===120000);
 await assert.rejects(cf.rpc(A,'notices',{command:'snapshot'}));assert.equal(calls,1);assert.equal(cancelled,true);
});

test('expired quota gate admits one recovery probe rather than a retry burst',async()=>{
 let at=1000,finish,calls=0;const p=createProviderPressure({now:()=>at});
 await assert.rejects(p.run(A,'SCRIPT_QUOTA_EXCEEDED',()=>{throw quotaError('SCRIPT_QUOTA_EXCEEDED');}));
 at+=60000;const probe=p.run(A,'SCRIPT_QUOTA_EXCEEDED',()=>new Promise(r=>{calls++;finish=r;}));
 await assert.rejects(p.run(A,'SCRIPT_QUOTA_EXCEEDED',()=>{calls++;}),e=>e.status===429);
 assert.equal(calls,1);finish(1);await probe;
 assert.equal(await p.run(A,'SCRIPT_QUOTA_EXCEEDED',()=>2),2);
});

test('configured shared Google owner gates both schools without trusting request scope fields',async()=>{
 const scopes={[A]:'e'.repeat(64),[B]:'e'.repeat(64)};
 const f=fixture(async(url,opt)=>({ok:true,status:200,text:async()=>JSON.stringify({success:false,schoolId:JSON.parse(opt.body).schoolId,code:'SCRIPT_QUOTA_EXCEEDED'})}),{googleQuotaScopes:scopes});
 await assert.rejects(f.call({action:'managed/storage/quota',schoolId:A}));
 await assert.rejects(f.call({action:'managed/storage/quota',schoolId:B,googleQuotaScope:'other'},'B'),e=>e.code==='SCRIPT_QUOTA_EXCEEDED');
 assert.equal(f.sent.length,1);
 assert.throws(()=>fixture(null,{googleQuotaScopes:{foreign:'owner'}}),/Invalid trusted Google quota scopes/);
});
test('Cloudflare worker quota scope protects other enabled schools sharing the same endpoint',async()=>{
 let calls=0;const cf=createCloudflareSync({url:'https://example.com',key:'a'.repeat(32),schools:[A,B],now:()=>1000,fetchImpl:async()=>{
  calls++;return {status:429,headers:new Headers(),body:{cancel:async()=>{}}};
 }});
 await assert.rejects(cf.rpc(A,'notices',{command:'stats'}));
 await assert.rejects(cf.rpc(B,'notices',{command:'stats'}),e=>e.code==='CLOUDFLARE_QUOTA_EXCEEDED');assert.equal(calls,1);
});

test('unavailable shared admission fails closed but slow metadata cleanup cannot lose a verified ACK',async()=>{
 let writes=0;
 const blocked=createProviderPressure({journalBudgetMs:5,journal:{admit:()=>new Promise(()=>{})}});
 await assert.rejects(blocked.run('owner','SCRIPT_QUOTA_EXCEEDED',()=>{writes++;}),e=>e.code==='PROVIDER_PRESSURE_UNAVAILABLE');assert.equal(writes,0);
 const cleanup=createProviderPressure({journalBudgetMs:5,journal:{admit:async()=>({claim:'probe'}),succeeded:()=>new Promise(()=>{})}});
 assert.equal(await cleanup.run('owner','SCRIPT_QUOTA_EXCEEDED',()=> 'verified-ack'),'verified-ack');
});
