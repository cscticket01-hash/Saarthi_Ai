'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createSchoolAppLockRecovery}=require('../school-app-lock-recovery');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32);
const id={schoolId:A,uid:'admin-a'},pc={deviceId:'pc-a',devices:['pc-a','pc-b']};
function fixture(){
 const docs=new Map();let at=1700000000000;
 const db={doc:path=>({path}),async runTransaction(fn){return fn({
  async get(ref){return {exists:docs.has(ref.path),data:()=>structuredClone(docs.get(ref.path))};},
  set(ref,data,options){docs.set(ref.path,{...(options?.merge?docs.get(ref.path):{}),...structuredClone(data)});}
 });}};
 const handle=createSchoolAppLockRecovery({db,now:()=>at});
 return {docs,advance:ms=>at+=ms,run:(action,b={},device=pc,identity=id)=>
  handle('managed/app-lock/recovery/'+action,{recoverySchoolId:A,...b},identity,device)};
}
test('School ID must match authenticated school and active Windows PC',async()=>{
 const f=fixture();
 await assert.rejects(f.run('verify',{recoverySchoolId:B}),e=>e.status===403);
 await assert.rejects(f.run('verify',{},pc,{schoolId:B,uid:id.uid}),e=>e.status===403);
 await assert.rejects(f.run('verify',{},pc,{}),e=>e.status===403);
 await assert.rejects(f.run('verify',{}, {deviceId:'revoked',devices:['pc-a']}),e=>e.status===403);
 assert.equal(f.docs.size,0);
 const result=await f.run('verify');
 assert.equal(result.authorized,true);
 assert.equal(result.schoolId,A);
 assert.match(result.approvalToken,/^[a-f0-9]{64}$/);
 const row=[...f.docs.values()][0];
 assert.equal(row.purpose,'school-id-app-lock-recovery');
 assert.notEqual(row.tokenHash,result.approvalToken);
});
test('Recovery is bound to the verified school, user and PC and consumed once',async()=>{
 const f=fixture(),{approvalToken}=await f.run('verify');
 await assert.rejects(f.run('consume',{approvalToken,recoverySchoolId:B}),e=>e.status===403);
 await assert.rejects(f.run('consume',{approvalToken},{deviceId:'pc-b',devices:pc.devices}),e=>e.status===403);
 await assert.rejects(f.run('consume',{approvalToken},pc,{...id,uid:'another-user'}),e=>e.status===403);
 await assert.rejects(f.run('consume',{approvalToken:'z'.repeat(64)}),e=>e.status===403);
 assert.deepEqual(await f.run('consume',{approvalToken}),{success:true,schoolId:A,authorized:true});
 await assert.rejects(f.run('consume',{approvalToken}),e=>e.status===403);
});
test('Expired grants and grants replaced by a new verification cannot reset App Lock',async()=>{
 const f=fixture(),first=await f.run('verify'),next=await f.run('verify');
 await assert.rejects(f.run('consume',{approvalToken:first.approvalToken}),e=>e.status===403);
 f.advance(120000);
 await assert.rejects(f.run('consume',{approvalToken:next.approvalToken}),e=>e.status===403);
});
test('Retired OTP routes stay disabled and recovery grants remain server-only',()=>{
 const fs=require('node:fs'),path=require('node:path');
 const source=fs.readFileSync(path.join(__dirname,'../managed-schools.js'),'utf8');
 assert.match(source,/if\(action\.startsWith\('managed\/app-lock\/otp\/'\)\)\{\s*fail\(/);
 assert.doesNotMatch(source,/createSchoolAppLockOtp/);
 const rules=fs.readFileSync(path.join(__dirname,'../../firestore.platform.rules'),'utf8');
 for(const root of ['school_app_lock_otp','school_admin_action_approvals'])
  assert.match(rules,new RegExp("!\\(root in \\[([^\\]]*)'"+root+"'[^\\]]*\\]\\)"));
});
