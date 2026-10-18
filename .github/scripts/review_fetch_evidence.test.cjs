'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm');
const {installBrowserEvidence}=require('./review_fetch_evidence.cjs');
const config={endpoint:'https://synthetic.example/school-cloud',school:'synthetic-school',noticeId:'synthetic-notice',title:'Synthetic title'};
function rig(reply){let requests=0;const window={fetch:async()=>{requests++;return new Response(JSON.stringify(reply),{status:200});}};vm.runInNewContext('('+installBrowserEvidence.toString()+')(config)',{window,config,TextDecoder});return {window,get requests(){return requests;}};}
const write={schoolId:config.school,action:'managed/records',operation:'write',collection:'school_notices',id:config.noticeId,operationId:'safe-operation',privateToken:'PRIVATE_CANARY'};
async function flush(){await new Promise(resolve=>setTimeout(resolve,10));}
test('browser observer retains verified original response evidence after app consumption without replay or secrets',async()=>{
 const r=rig({success:true,schoolId:config.school,syncProtocol:2,recordRevision:'verified',secret:'PRIVATE_CANARY'});
 const response=await r.window.fetch(config.endpoint,{method:'POST',body:JSON.stringify(write)});assert.equal((await response.json()).success,true);await flush();
 assert.equal(r.requests,1);const e=r.window.__vsReviewEvidence[0];assert.equal(e.complete,true);assert.equal(e.recordRevision,'verified');assert.equal(e.operationId,'safe-operation');assert(!JSON.stringify(e).includes('PRIVATE_CANARY'));
});
test('only exact school notice reads match, and wrong notice contents cannot verify readback',async()=>{
 const r=rig({schoolId:config.school,syncProtocol:2,changes:{school_notices:{records:{[config.noticeId]:{schoolId:config.school,title:'Different'}}}}});
 const read={schoolId:config.school,action:'managed/changes',collections:['school_notices']};
 for(const body of [{...read,schoolId:'foreign'},{...read,headOnly:true}])await r.window.fetch(config.endpoint,{method:'POST',body:JSON.stringify(body)});
 assert.equal(r.window.__vsReviewEvidence.length,0);
 await r.window.fetch(config.endpoint,{method:'POST',body:JSON.stringify(read)});await flush();const e=r.window.__vsReviewEvidence[0];assert.equal(e.complete,true);assert.equal(e.noticeMatches,false);assert.equal(e.unchanged,false);
});
test('resetting the observation window excludes an earlier in-flight response',async()=>{
 let release;const window={fetch:()=>new Promise(resolve=>{release=resolve;})};vm.runInNewContext('('+installBrowserEvidence.toString()+')(config)',{window,config});
 const pending=window.fetch(config.endpoint,{method:'POST',body:JSON.stringify(write)});window.__vsReviewEvidence=[];
 release(new Response(JSON.stringify({schoolId:config.school,syncProtocol:2,success:true,recordRevision:'old'})));
 await pending;await flush();assert.equal(window.__vsReviewEvidence.length,0);
});
test('Flutter typed-byte fetch payload verifies the exact notice body without consuming the application response',async()=>{
 const r=rig({schoolId:config.school,syncProtocol:2,changes:{school_notices:{records:{[config.noticeId]:{schoolId:config.school,title:config.title,privateField:'PRIVATE_CANARY'}}}}});
 const read={schoolId:config.school,action:'managed/changes',collections:['school_notices']};
 const response=await r.window.fetch(config.endpoint,{method:'POST',body:new TextEncoder().encode(JSON.stringify(read))});
 assert.equal((await response.json()).changes.school_notices.records[config.noticeId].title,config.title);await flush();
 const e=r.window.__vsReviewEvidence[0];assert.equal(e.complete,true);assert.equal(e.noticeMatches,true);assert.equal(r.requests,1);assert(!JSON.stringify(e).includes('PRIVATE_CANARY'));
});
