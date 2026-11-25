'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createSchoolAppLockOtp}=require('../school-app-lock-otp');
function fixture({configured=true,verified=true,mailOk=true}={}){
 const docs=new Map(),emails=[];let at=1700000000000,audit=0;
 const identity={schoolId:'school-a',uid:'uid-a'},device={deviceId:'pc-a',devices:['pc-a','pc-b']};
 const auth={async getUser(uid){assert.equal(uid,identity.uid);return {email:'school@example.test',emailVerified:verified};}};
 const db={doc:path=>({path}),collection:path=>({doc:()=>({path:path+'/'+(++audit)})}),
  async runTransaction(fn){return fn({async get(ref){return {exists:docs.has(ref.path),data:()=>structuredClone(docs.get(ref.path))};},
   set(ref,data,options){docs.set(ref.path,{...(options?.merge?docs.get(ref.path):{}),...structuredClone(data)});}});}};
 const env=configured?{SAARTHI_SCHOOL_APP_LOCK_OTP_PEPPER:'x'.repeat(48),SAARTHI_DEVELOPER_OTP_RESEND_API_KEY:'test-only',SAARTHI_DEVELOPER_OTP_FROM:'sender@example.test'}:{};
 const handle=createSchoolAppLockOtp({auth,db,env,now:()=>at,fetchImpl:async(_url,options)=>{emails.push(JSON.parse(options.body));return {ok:mailOk};}});
 return {docs,emails,run:(action,b={},d=device,i=identity)=>handle('managed/app-lock/otp/'+action,b,i,d),advance:ms=>{at+=ms;},code:()=>emails.at(-1).text.match(/\b\d{6}\b/)[0]};
}
test('OTP is private, expires, rate limits resend and is consumed exactly once',async()=>{
 const f=fixture(),sent=await f.run('send');
 assert.equal(sent.success,true);assert.equal('otp' in sent,false);
 assert.deepEqual(f.emails[0].to,['school@example.test']);
 await assert.rejects(f.run('send'),e=>e.status===429);
 await assert.rejects(f.run('verify',{otp:f.code()},{deviceId:'pc-b',devices:['pc-a','pc-b']}),e=>e.status===403);
 const wrong=f.code()==='111111'?'222222':'111111';
 assert.equal((await f.run('verify',{otp:wrong})).verified,false);
 assert.equal((await f.run('verify',{otp:f.code()})).verified,true);
 await assert.rejects(f.run('verify',{otp:f.code()}),e=>e.status===403);
 assert.equal([...f.docs.keys()].filter(k=>k.startsWith('platform_audit/')).length,1);
});
test('missing configuration, unverified email, inactive PC and mail failure fail closed',async()=>{
 for(const [options,status] of [[{configured:false},503],[{verified:false},403],[{mailOk:false},503]]){
  const f=fixture(options);await assert.rejects(f.run('send'),e=>e.status===status);
  if(f.emails.length)await assert.rejects(f.run('verify',{otp:f.code()}),e=>e.status===403);
 }
 const f=fixture();await assert.rejects(f.run('send',{}, {deviceId:'revoked',devices:['pc-a']}),e=>e.status===403);
});
test('attempt limit and five-minute expiry are enforced',async()=>{
 const f=fixture();await f.run('send');const wrong=f.code()==='111111'?'222222':'111111';
 for(let i=0;i<5;i++)assert.equal((await f.run('verify',{otp:wrong})).verified,false);
 await assert.rejects(f.run('verify',{otp:f.code()}),e=>e.status===403);
 f.advance(60001);await f.run('send');f.advance(300000);
 await assert.rejects(f.run('verify',{otp:f.code()}),e=>e.status===403);
});
test('Firestore wildcard denies direct access to App Lock OTP challenges',()=>{
 const path=require('node:path').join(__dirname,'../../firestore.platform.rules');
 const source=require('node:fs').readFileSync(path,'utf8');
 assert.match(source,/!\(root in \[[^\]]*'school_app_lock_otp'[^\]]*\]\)/);
});
