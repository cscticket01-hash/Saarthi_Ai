'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {fixture,A}=require('./helpers/managed-school-broker');
const operationId='transport-operation-12345';
const body={action:'managed/records',collection:'documents',operation:'write',id:'synthetic',syncProtocol:2,operationId,expectedRecordRevision:'',data:{schoolId:A,syntheticTest:true}};
function verify(error,code,stage,kind,status=503){
 assert.equal(error.status,status);assert.equal(error.code,code);assert.equal(error.publicMessage,true);
 assert.deepEqual(error.syncDiagnostic,{schoolId:A,syncProtocol:2,operationId,scriptStage:stage,transportKind:kind});
 assert.equal(JSON.stringify(error).includes('NEVER_EXPOSE'),false);assert.equal(error.message.includes('NEVER_EXPOSE'),false);return true;
}
test('Script POST socket failure keeps operation identity without backend replay or false ACK',async()=>{
 const f=fixture(async()=>{throw Object.assign(new TypeError('NEVER_EXPOSE URL and token'),{cause:{code:'ECONNRESET'}});});
 await assert.rejects(f.call(body),e=>verify(e,'SCRIPT_TRANSPORT_ERROR','request','socket'));
 assert.equal(f.sent.length,1);assert.equal(JSON.parse(JSON.parse(f.sent[0].opt.body).payload).operationId,operationId);
});
test('Script redirect transport failure is diagnosed without replaying the signed POST',async()=>{
 let calls=0;const f=fixture(async(_,options)=>{if(++calls===1)return {status:302,headers:new Headers({location:'https://script.googleusercontent.com/test'})};assert.equal(options.method,'GET');throw Object.assign(new TypeError('NEVER_EXPOSE'),{cause:{code:'EAI_AGAIN'}});});
 await assert.rejects(f.call(body),e=>verify(e,'SCRIPT_TRANSPORT_ERROR','redirect','dns'));assert.equal(calls,2);
});
test('Script timeout is a safe 504 and retains the exact versioned operation',async()=>{
 const f=fixture(async()=>{throw new DOMException('NEVER_EXPOSE','TimeoutError');});
 await assert.rejects(f.call(body),e=>verify(e,'SCRIPT_TIMEOUT','request','timeout',504));assert.equal(f.sent.length,1);
});
test('truncated Script response stream cannot become a successful cloud ACK',async()=>{
 const f=fixture(async()=>({status:200,ok:true,text:async()=>{throw Object.assign(new TypeError('NEVER_EXPOSE'),{cause:{code:'UND_ERR_SOCKET'}});}}));
 await assert.rejects(f.call(body),e=>verify(e,'SCRIPT_RESPONSE_READ_FAILED','response','socket'));assert.equal(f.sent.length,1);
});
test('database exceptions are not mislabeled as Script failures and foreign school never forwards',async()=>{
 const f=fixture();const doc=f.db.doc;f.db.doc=path=>path.startsWith('school_storage_private/')?{get:async()=>{throw new TypeError('application failure');}}:doc(path);
 await assert.rejects(f.call(body),e=>e instanceof TypeError&&e.code===undefined);assert.equal(f.sent.length,0);
 await assert.rejects(f.call({...body,schoolId:'vs-'+ 'b'.repeat(32)}),e=>e.status===403);assert.equal(f.sent.length,0);
});

test('verified school-root failure retains safe provider provenance instead of generic operation failure',async()=>{
 const f=fixture(async()=>({status:200,ok:true,text:async()=>JSON.stringify({success:false,schoolId:A,code:'SCRIPT_ROOT_IDENTITY_MISMATCH',message:'NEVER_EXPOSE'})}));
 await assert.rejects(f.call(body),e=>e.status===502&&e.code==='SCRIPT_ROOT_IDENTITY_MISMATCH'&&!e.message.includes('NEVER_EXPOSE'));
 assert.equal(f.sent.length,1);
});

for(const status of [301,302,303,307,308])test(`verified response chain ${status} never replays signed write`,async()=>{
 let calls=0;const f=fixture(async(url,options)=>{
  calls++;
  if(calls===1)return {status:302,headers:new Headers({location:'https://script.googleusercontent.com/first'})};
  assert.equal(options.method,'GET');assert.equal(options.body,undefined);assert.equal(options.headers,undefined);assert.equal(options.redirect,'manual');
  if(calls===2)return {status,headers:new Headers({location:'/final'})};
  return {status:200,ok:true,text:async()=>JSON.stringify({success:true,schoolId:A,records:{}})};
 });
 await f.call(body);assert.equal(calls,3);assert.equal(f.sent.filter(x=>x.opt.method==='POST').length,1);
 assert.equal(f.sent[2].url,'https://script.googleusercontent.com/final');
});
for(const location of ['https://evil.example/x','https://script.googleusercontent.com.evil.example/x','http://script.googleusercontent.com/x','https://user:secret@script.googleusercontent.com/x','https://script.googleusercontent.com:444/x',null])test(`unsafe response redirect rejected: ${location}`,async()=>{
 const f=fixture(async()=>({status:302,headers:new Headers(location?{location}:{})}));
 await assert.rejects(f.call(body),e=>e.code==='SCRIPT_REDIRECT_REJECTED');assert.equal(f.sent.length,1);
});
test('response redirect loop stops without a second write or false ACK',async()=>{
 const f=fixture(async()=>({status:302,headers:new Headers({location:'https://script.googleusercontent.com/loop'})}));
 await assert.rejects(f.call(body),e=>e.code==='SCRIPT_REDIRECT_LIMIT');assert.equal(f.sent.length,2);
});
test('response redirect chain is bounded even when URLs keep changing',async()=>{
 let calls=0;const f=fixture(async()=>({status:302,headers:new Headers({location:'https://script.googleusercontent.com/'+(++calls)})}));
 await assert.rejects(f.call(body),e=>e.code==='SCRIPT_REDIRECT_LIMIT');assert.equal(f.sent.length,6);
});
test('redirect completion still rejects foreign school response',async()=>{
 let calls=0;const f=fixture(async()=>++calls===1?{status:302,headers:new Headers({location:'https://script.googleusercontent.com/result'})}:{status:200,ok:true,text:async()=>JSON.stringify({success:true,schoolId:'foreign'})});
 await assert.rejects(f.call(body),e=>e.code==='SCRIPT_IDENTITY_MISMATCH');assert.equal(f.sent.length,2);
});

test('Apps Script lock timeout is retryable 504 without replay, raw errors or false ACK',async()=>{
 const f=fixture(async()=>({status:200,ok:true,text:async()=>JSON.stringify({success:false,schoolId:A,code:'SCRIPT_TIMEOUT',message:'NEVER_EXPOSE'})}));
 await assert.rejects(f.call(body),e=>e.status===504&&e.code==='SCRIPT_TIMEOUT'&&e.message.includes('pending changes are retained')&&!e.message.includes('NEVER_EXPOSE'));
 assert.equal(f.sent.length,1);
 assert.equal(JSON.parse(JSON.parse(f.sent[0].opt.body).payload).operationId,operationId);
});
