'use strict';

// Do not authenticate with School ID alone. Identity and entitlement are
// checked by the managed broker before entering this recovery route.
function createSchoolAppLockRecovery({adminSecurity}){
 const fail=(status,message)=>{const e=new Error(message);e.status=status;e.publicMessage=true;throw e;};
 return async function handle(action,body,identity,device){
  if(!identity?.uid||!/^vs-[a-f0-9]{32}$/.test(identity.schoolId)||
     body.recoverySchoolId!==identity.schoolId)
   fail(403,'School verification failed.');
  if(!device||typeof device.deviceId!=='string'||
     !Array.isArray(device.devices)||!device.devices.includes(device.deviceId))
   fail(403,'An active registered Windows PC is required.');
  // Existing independent Admin Password checks, lockout, password-version
  // binding, expiration, audit and one-use approval consumption remain in force.
  const scope='protected-settings',target='app-lock-recovery:'+device.deviceId;
  if(action==='managed/app-lock/recovery/verify'){
   const r=await adminSecurity.handle({operation:'authorize',scope,target,password:body.adminPassword},identity);
   if(r?.success!==true||r.authorized!==true||r.schoolId!==identity.schoolId||
      !/^[a-f0-9]{64}$/.test(r.approvalToken||''))
    fail(403,'School administrator verification failed.');
   return {success:true,schoolId:identity.schoolId,authorized:true,
    approvalToken:r.approvalToken,expiresAt:r.expiresAt};
  }
  if(action==='managed/app-lock/recovery/consume'){
   const r=await adminSecurity.handle({operation:'consume',scope,target,approvalToken:body.approvalToken},identity);
   if(r?.success!==true||r.authorized!==true||r.schoolId!==identity.schoolId)
    fail(403,'Recovery approval is invalid or expired.');
   return {success:true,schoolId:identity.schoolId,authorized:true};
  }
  fail(400,'Unknown App Lock recovery action.');
 };
}
module.exports={createSchoolAppLockRecovery};
