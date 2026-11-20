'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {createDeveloperPasswordOtp}=require('../developer-password-otp');

function fixture({configured=true,verified=true,authTime=1000000}={}){
 const docs=new Map(),emails=[],passwords=[],revoked=[];
 let at=1000000000;
 const uid='developer-uid',email='developer@example.test';
 const auth={
  async getUser(id){assert.equal(id,uid);return {email,emailVerified:verified};},
  async verifyIdToken(token,checkRevoked){assert.equal(token,'test-token');assert.equal(checkRevoked,true);return {uid,auth_time:authTime};},
  async updateUser(id,changes){passwords.push({id,changes});},
  async revokeRefreshTokens(id){revoked.push(id);}
 };
 const db={
  doc(path){return {path};},
  collection(path){return {add:async row=>{docs.set(path+'/audit',row);}};},
  async runTransaction(fn){
   const tx={
    async get(ref){return {exists:docs.has(ref.path),data:()=>structuredClone(docs.get(ref.path))};},
    set(ref,values,opt){const previous=opt?.merge?docs.get(ref.path)||{}:{};docs.set(ref.path,{...previous,...structuredClone(values)});}
   };
   return fn(tx);
  }
 };
 const env=configured?{
  SAARTHI_DEVELOPER_OTP_PEPPER:'a'.repeat(48),
  SAARTHI_DEVELOPER_OTP_RESEND_API_KEY:'test-api-key',
  SAARTHI_DEVELOPER_OTP_FROM:'noreply@example.test'
 }:{};
 const handler=createDeveloperPasswordOtp({
  auth,db,now:()=>at,env,
  fetchImpl:async(url,options)=>{
   assert.equal(url,'https://api.resend.com/emails');
   const body=JSON.parse(options.body);
   emails.push(body);
   return {ok:true};
  }
 });
 const req={headers:{authorization:'Bearer test-token'}};
 const run=(action,body={})=>handler('developer/managed/security/otp/'+action,body,{uid},req);
 const advance=ms=>{at+=ms;};
 const lastCode=()=>emails.at(-1).text.match(/\b\d{6}\b/)?.[0];
 return {run,docs,emails,passwords,revoked,advance,lastCode,uid};
}

test('developer password cannot change without configured email security',async()=>{
 const f=fixture({configured:false});
 await assert.rejects(f.run('send'),e=>e.status===503);
 await assert.rejects(f.run('change',{password:'StrongPassword123!'}),e=>e.status===503);
 assert.equal(f.passwords.length,0);
 assert.equal(f.emails.length,0);
});

test('OTP is emailed only, expires after five minutes and unlocks one password change',async()=>{
 const f=fixture();
 await assert.rejects(f.run('change',{password:'StrongPassword123!'}),e=>e.status===403);
 const sent=await f.run('send');
 assert.equal(sent.success,true);assert.equal(sent.expiresAt,1000000000+300000);
 assert.equal('otp' in sent,false);
 assert.equal('code' in sent,false);
 const row=f.docs.get('developer_password_otp/'+f.uid);
 assert.equal(row.hash.length,64);
 assert.equal(row.hash.includes(f.lastCode()),false);
 const wrong=await f.run('verify',{otp:f.lastCode()==='000001'?'000002':'000001'});
 assert.equal(wrong.verified,false);
 const verification=await f.run('verify',{otp:f.lastCode()});
 assert.equal(verification.verified,true);
 const password='StrongPassword123!';
 await assert.rejects(f.run('change',{password}),e=>e.status===403);
 await assert.rejects(f.run('change',{password,proof:'0'.repeat(64)}),e=>e.status===403);
 assert.equal((await f.run('change',{password,proof:verification.proof})).passwordChanged,true);
 assert.deepEqual(f.passwords,[{id:f.uid,changes:{password:'StrongPassword123!'}}]);
 assert.deepEqual(f.revoked,[f.uid]);
 await assert.rejects(f.run('change',{password:'OtherPassword456!',proof:verification.proof}),e=>e.status===403);
});

test('resend invalidates previous OTP and enforces rate limit',async()=>{
 const f=fixture();
 await f.run('send');
 const first=f.lastCode();
 await assert.rejects(f.run('send'),e=>e.status===429);
 f.advance(60001);
 await f.run('send');
 const second=f.lastCode();
 // A previous unverified challenge must no longer authenticate.
 if(first!==second){
  const before=await f.run('verify',{otp:first});
  assert.equal(before.verified,false);
 }
 assert.equal((await f.run('verify',{otp:second})).verified,true);
});

test('expired OTP and unverified developer email cannot authorize a password update',async()=>{
 const f=fixture();
 await f.run('send');
 const code=f.lastCode();
 f.advance(300000);
 await assert.rejects(f.run('verify',{otp:code}),e=>e.status===403);
 await assert.rejects(f.run('change',{password:'StrongPassword123!'}),e=>e.status===403);
 const unverified=fixture({verified:false});
 await assert.rejects(unverified.run('send'),e=>e.status===403);
});
