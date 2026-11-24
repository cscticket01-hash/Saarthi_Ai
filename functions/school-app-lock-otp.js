'use strict';
const {randomInt,randomBytes,createHmac,createHash,timingSafeEqual}=require('node:crypto');

// Recovery changes only the PC's local App Lock, never the Firebase account.
// A caller must already have an authenticated school-admin session and active PC proof.
function createSchoolAppLockOtp({auth,db,now=Date.now,fetchImpl=fetch,env=process.env}){
 const fail=(status,message)=>{const e=new Error(message);e.status=status;e.publicMessage=true;throw e;};
 return async function handle(action,b,identity,device){
  const pepper=env.SAARTHI_SCHOOL_APP_LOCK_OTP_PEPPER||'';
  const key=env.SAARTHI_DEVELOPER_OTP_RESEND_API_KEY||'';
  const from=env.SAARTHI_DEVELOPER_OTP_FROM||'';
  if(pepper.length<32||!key||!/^\S+@\S+\.\S+$/.test(from))fail(503,'School App Lock recovery is not configured.');
  const {schoolId,uid}=identity;
  if(!device||!device.devices.includes(device.deviceId))fail(403,'Active Windows PC required.');
  const account=await auth.getUser(uid);
  if(!account?.email||account.emailVerified!==true||account.disabled)fail(403,'Verified school email required for recovery.');
  const t=now(), scope=JSON.stringify([schoolId,uid,device.deviceId,account.email]);
  const ref=db.doc('school_app_lock_otp/'+createHash('sha256').update(schoolId).digest('hex'));
  const digest=(nonce,code)=>createHmac('sha256',pepper).update(JSON.stringify(['app-lock-v1',scope,nonce,code])).digest('hex');
  if(action==='managed/app-lock/otp/send'){
   const nonce=randomBytes(24).toString('hex'),code=String(randomInt(1000000)).padStart(6,'0');
   await db.runTransaction(async tx=>{
    const row=await tx.get(ref),old=row.exists?row.data():{};
    const inWindow=Number(old.windowStart)>0&&t-Number(old.windowStart)<86400000;
    if(t-Number(old.lastSent||0)<60000||(inWindow&&Number(old.sent||0)>=6))fail(429,'Wait before requesting another code.');
    tx.set(ref,{scope,nonce,hash:digest(nonce,code),expiresAt:t+300000,lastSent:t,attempts:0,
      windowStart:inWindow?old.windowStart:t,sent:inWindow?Number(old.sent||0)+1:1});
   });
   try{
    const r=await fetchImpl('https://api.resend.com/emails',{method:'POST',
     headers:{Authorization:'Bearer '+key,'Content-Type':'application/json'},
     body:JSON.stringify({from,to:[account.email],subject:'Vidya Saarthi App Lock recovery',
      text:'Your App Lock recovery code is '+code+'. It expires in 5 minutes. Ignore this email if you did not request recovery.'}),
     signal:AbortSignal.timeout(12000)});
    if(!r.ok)throw Error('mail failed');
   }catch(_){
    await db.runTransaction(async tx=>{const row=await tx.get(ref);if(row.exists&&row.data().nonce===nonce)tx.set(ref,{hash:'',expiresAt:0},{merge:true});});
    fail(503,'Recovery email could not be sent.');
   }
   return {success:true,schoolId,expiresAt:t+300000,resendAfter:t+60000};
  }
  if(action==='managed/app-lock/otp/verify'){
   const code=String(b.otp||'');
   if(!/^\d{6}$/.test(code))fail(400,'Enter the six-digit recovery code.');
   return db.runTransaction(async tx=>{
    const row=await tx.get(ref),v=row.exists?row.data():null;
    if(!v||v.scope!==scope||!v.hash||v.expiresAt<=t||Number(v.attempts||0)>=5)fail(403,'Recovery code unavailable or expired.');
    const expected=Buffer.from(v.hash,'hex'),actual=Buffer.from(digest(v.nonce,code),'hex');
    if(expected.length!==32||!timingSafeEqual(expected,actual)){
      tx.set(ref,{attempts:Number(v.attempts||0)+1},{merge:true});
      return {success:false,verified:false,schoolId};
    }
    tx.set(ref,{hash:'',expiresAt:0,consumedAt:t},{merge:true});
    tx.set(db.collection('platform_audit').doc(),{action:'school/app-lock/recovery-verified',actor:uid,schoolId,deviceId:device.deviceId,at:t});
    return {success:true,verified:true,schoolId};
   });
  }
  fail(400,'Unknown recovery action.');
 };
}
module.exports={createSchoolAppLockOtp};
