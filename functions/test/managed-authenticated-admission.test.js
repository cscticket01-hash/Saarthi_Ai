'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {storage,A,B}=require('./helpers/managed-storage');
const {fixture,time}=require('./helpers/managed-school-broker');
test('valid HMAC lock timeout is school-bound retry evidence, never an ACK',()=>{
 for(const bundle of [false,true]){
  const s=storage({bundle});let locks=0;
  s.context.LockService.getScriptLock=()=>({waitLock(){locks++;throw Error('Lock busy timed out');},releaseLock(){throw Error('Unacquired lock cannot be released');}});
  const before=s.all.size;
  const out=s.call({action:'managed_records',operation:'write',collection:'school_notices',id:'unchanged',data:{schoolId:A,title:'must not write'}});
  assert.equal(out.success,false);assert.equal(out.schoolId,A);assert.equal(out.code,'SCRIPT_TIMEOUT');
  assert.equal(locks,1);assert.equal(s.all.size,before);
  assert.equal([...s.props.keys()].filter(k=>k.startsWith('VS_NONCE_')).length,0);
 }
});
test('foreign, invalid, stale or replayed signatures never authorize writes or success',()=>{
 const s=storage();let locks=0;
 s.context.LockService.getScriptLock=()=>({waitLock(){locks++;throw Error('Lock busy');},releaseLock(){}});
 for(const schoolId of [A,B]){
  const out=s.context.VS_managedHandle({postData:{contents:JSON.stringify({schoolId,timestamp:Date.now(),nonce:'a'.repeat(48),payload:'{}',signature:'0'.repeat(64)})}});
  assert.equal(out.success,false);assert.equal(out.schoolId,undefined);assert.equal(out.code,'SCRIPT_OPERATION_FAILED');
 }
 assert.equal(locks,0,'Unauthenticated requests never reach admission');
});
test('broker maps authenticated admission timeout to existing retryable HTTP504 without weakening unsigned response rejection',async()=>{
 const s=storage({bundle:true});class Clock extends Date{static now(){return time;}}s.context.Date=Clock;
 s.context.LockService.getScriptLock=()=>({waitLock(){throw Error('Lock timed out');},releaseLock(){}});
 const b=fixture(async(_,opt)=>({ok:true,status:200,text:async()=>JSON.stringify(s.context.doPost({postData:{contents:opt.body}}))}));
 await assert.rejects(b.call({action:'managed/records',operation:'read',collection:'school_notices',syncProtocol:2}),e=>e.status===504&&e.code==='SCRIPT_TIMEOUT');
 const unsigned=fixture(async()=>({ok:true,status:200,text:async()=>JSON.stringify({success:false,code:'SCRIPT_TIMEOUT'})}));
 await assert.rejects(unsigned.call({action:'managed/records',operation:'read',collection:'school_notices',syncProtocol:2}),e=>e.status===502&&e.code==='SCRIPT_SIGNED_RESPONSE_UNVERIFIED');
});
