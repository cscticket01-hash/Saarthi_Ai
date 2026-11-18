'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto'),vm=require('node:vm'),fs=require('node:fs');
for(const source of ['SaarthiManagedAdapter.gs','SaarthiManagedAll.gs'])test(source+' authenticates busy nonce rejection without dispatch or false success',()=>{
 const school='vs-'+'a'.repeat(32),secret='b'.repeat(64),props=new Map([['VS_MANAGED_SCHOOL_ID',school],['VS_MANAGED_SECRET',secret]]);
 let dispatches=0,locks=0;
 const c=vm.createContext({Date,JSON,Number,String,Object,Error,console:{info(){}},jsonResponse:x=>x,
 PropertiesService:{getScriptProperties:()=>({getProperty:k=>props.get(k),setProperty:(k,v)=>props.set(k,v),getProperties:()=>Object.fromEntries(props)})},
 Utilities:{Charset:{UTF_8:'UTF-8'},computeHmacSha256Signature:(s,k)=>[...crypto.createHmac('sha256',k).update(s).digest()]},
 LockService:{getScriptLock:()=>({waitLock(){locks++;throw Error('Lock timed out');},releaseLock(){}})}});
 vm.runInContext(fs.readFileSync('../school-backend/managed/'+source,'utf8'),c);
 c.jsonResponse=x=>x;c.VS_managedRecord=()=>{dispatches++;return {};};
 const b={schoolId:school,timestamp:Date.now(),nonce:'c'.repeat(48),payload:JSON.stringify({action:'managed_records',operation:'write'})};
 b.signature=crypto.createHmac('sha256',secret).update(school+'\n'+b.timestamp+'\n'+b.nonce+'\n'+b.payload).digest('hex');
 const send=value=>c.VS_managedHandle({postData:{contents:JSON.stringify(value)}});
 const busy=send(b);assert.equal(busy.success,false);assert.equal(busy.schoolId,school);assert.equal(busy.code,'SCRIPT_TIMEOUT');assert.equal(dispatches,0);assert.equal(locks,1);
 for(const changed of [{...b,signature:'0'.repeat(64)},{...b,schoolId:'vs-'+'d'.repeat(32)},{...b,timestamp:1},{...b,payload:'{}'}]){
  const denied=send(changed);assert.equal(denied.success,false);assert.equal(Object.hasOwn(denied,'schoolId'),false);
 }
 assert.equal(locks,1);assert.equal(dispatches,0);
});
