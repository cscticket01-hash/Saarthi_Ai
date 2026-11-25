'use strict';
const {randomBytes,createHash}=require('node:crypto');
const digest=value=>createHash('sha256').update(value).digest('hex');

// The broker authenticates the existing school session, licence and PC before
// calling this route. School ID is a match against that identity, not a login.
function createSchoolAppLockRecovery({db,now=Date.now}){
 const fail=(status,message)=>{const e=new Error(message);e.status=status;e.publicMessage=true;throw e;};
 return async function handle(action,body,identity,device){
  if(!identity?.uid||!/^vs-[a-f0-9]{32}$/.test(identity.schoolId)||
     body.recoverySchoolId!==identity.schoolId)
   fail(403,'School verification failed.');
  if(!device||typeof device.deviceId!=='string'||
     !Array.isArray(device.devices)||!device.devices.includes(device.deviceId))
   fail(403,'An active registered Windows PC is required.');
  const binding={schoolId:identity.schoolId,uid:identity.uid,deviceId:device.deviceId};
  // Separate document namespace in the existing server-only approval collection.
  // These grants cannot be used as Admin Password approvals.
  const ref=db.doc('school_admin_action_approvals/app-lock-recovery-'+digest(JSON.stringify(binding)));
  if(action==='managed/app-lock/recovery/verify'){
   const token=randomBytes(32).toString('hex'),expiresAt=now()+120000;
   await db.runTransaction(async tx=>{
    tx.set(ref,{...binding,purpose:'school-id-app-lock-recovery',
     tokenHash:digest(token),expiresAt,ttlAt:new Date(expiresAt),used:false});
   });
   return {success:true,schoolId:identity.schoolId,authorized:true,approvalToken:token,expiresAt};
  }
  if(action==='managed/app-lock/recovery/consume'){
   const token=body.approvalToken;
   if(typeof token!=='string'||!/^[a-f0-9]{64}$/.test(token))
    fail(403,'Recovery approval is invalid or expired.');
   await db.runTransaction(async tx=>{
    const snap=await tx.get(ref),row=snap.exists?snap.data():null;
    if(!row||row.purpose!=='school-id-app-lock-recovery'||row.used!==false||
       row.schoolId!==binding.schoolId||row.uid!==binding.uid||row.deviceId!==binding.deviceId||
       !Number.isSafeInteger(row.expiresAt)||row.expiresAt<=now()||row.tokenHash!==digest(token))
     fail(403,'Recovery approval is invalid or expired.');
    tx.set(ref,{used:true,tokenHash:null},{merge:true});
   });
   return {success:true,schoolId:identity.schoolId,authorized:true};
  }
  fail(400,'Unknown App Lock recovery action.');
 };
}
module.exports={createSchoolAppLockRecovery};
