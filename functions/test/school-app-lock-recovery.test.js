'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createSchoolAppLockRecovery}=require('../school-app-lock-recovery');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32);
const id={schoolId:A,uid:'admin-a'},pc={deviceId:'pc-a',devices:['pc-a','pc-b']};
const token='a'.repeat(64);
function fixture(){
 const calls=[];let grant=null,version=1;
 const handle=createSchoolAppLockRecovery({adminSecurity:{async handle(b,i){
  calls.push({b,i});
  if(b.operation==='authorize'){
   if(b.password!=='Admin123')throw Object.assign(Error('Wrong password'),{status:403});
   grant={target:b.target,scope:b.scope,uid:i.uid,school:i.schoolId,version};
   return {success:true,authorized:true,schoolId:i.schoolId,approvalToken:token,expiresAt:120000};
  }
  if(!grant||b.approvalToken!==token||b.target!==grant.target||b.scope!==grant.scope||
      i.schoolId!==grant.school||i.uid!==grant.uid||grant.version!==version)
   throw Object.assign(Error('Invalid approval'),{status:403});
  grant=null;
  return {success:true,authorized:true,schoolId:i.schoolId};
 }}});
 return {calls,rotate:()=>version++,run:(action,b={},device=pc,identity=id)=>
  handle('managed/app-lock/recovery/'+action,{recoverySchoolId:A,...b},identity,device)};
}
test('School ID alone, wrong school, wrong Admin Password and inactive PC cannot authorize',async()=>{
 const f=fixture();
 await assert.rejects(f.run('verify',{recoverySchoolId:B,adminPassword:'Admin123'}),e=>e.status===403);
 await assert.rejects(f.run('verify',{adminPassword:'Admin123'},pc,{schoolId:B,uid:id.uid}),e=>e.status===403);
 await assert.rejects(f.run('verify',{adminPassword:'Admin123'},{deviceId:'revoked',devices:['pc-a']}),e=>e.status===403);
 assert.equal(f.calls.length,0);
 await assert.rejects(f.run('verify'),e=>e.status===403);
 await assert.rejects(f.run('verify',{adminPassword:'wrong'}),e=>e.status===403);
});
test('Verify and consume use a device-specific protected action and reject replay',async()=>{
 const f=fixture();
 const result=await f.run('verify',{adminPassword:'Admin123'});
 assert.equal(result.approvalToken,token);
 assert.equal(f.calls[0].b.scope,'protected-settings');
 assert.equal(f.calls[0].b.target,'app-lock-recovery:pc-a');
 await assert.rejects(f.run('consume',{approvalToken:token},{deviceId:'pc-b',devices:pc.devices}),e=>e.status===403);
 await assert.rejects(f.run('consume',{approvalToken:token},pc,{...id,uid:'another-user'}),e=>e.status===403);
 assert.deepEqual(await f.run('consume',{approvalToken:token}),{success:true,schoolId:A,authorized:true});
 await assert.rejects(f.run('consume',{approvalToken:token}),e=>e.status===403);
});
test('Admin Password rotation invalidates outstanding recovery approval',async()=>{
 const f=fixture();await f.run('verify',{adminPassword:'Admin123'});f.rotate();
 await assert.rejects(f.run('consume',{approvalToken:token}),e=>e.status===403);
});
test('Retired OTP routes cannot generate codes; historical OTP data stays private',()=>{
 const fs=require('node:fs'),path=require('node:path');
 const source=fs.readFileSync(path.join(__dirname,'../managed-schools.js'),'utf8');
 assert.match(source,/if\(action\.startsWith\('managed\/app-lock\/otp\/'\)\)\{\s*fail\(/);
 assert.doesNotMatch(source,/createSchoolAppLockOtp/);
 const rules=fs.readFileSync(path.join(__dirname,'../../firestore.platform.rules'),'utf8');
 assert.match(rules,/!\(root in \[[^\]]*'school_app_lock_otp'[^\]]*\]\)/);
});
