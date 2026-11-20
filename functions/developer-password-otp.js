'use strict';
const {randomBytes,randomInt,createHmac,timingSafeEqual}=require('node:crypto');

// This module never returns a generated code. Password changes fail closed
// unless the protected mail provider and OTP pepper are configured on Render.
function createDeveloperPasswordOtp({auth,db,now=Date.now,fetchImpl=fetch,env=process.env}){
 const reject=(status,message)=>{const e=new Error(message);e.status=status;e.publicMessage=true;throw e;};
 const digest=(uid,nonce,code)=>createHmac('sha256',env.SAARTHI_DEVELOPER_OTP_PEPPER)
   .update(uid+'\n'+nonce+'\n'+code).digest('hex');
 return async function handle(action,body,admin,req){
  const pepper=env.SAARTHI_DEVELOPER_OTP_PEPPER||'';
  const apiKey=env.SAARTHI_DEVELOPER_OTP_RESEND_API_KEY||'';
  const from=env.SAARTHI_DEVELOPER_OTP_FROM||'';
  if(pepper.length<32||!apiKey||!/^\S+@\S+\.\S+$/.test(from))
   reject(503,'Developer email OTP is not configured; password remains unchanged');
  const uid=admin.uid, t=now(), ref=db.doc('developer_password_otp/'+uid);
  const account=await auth.getUser(uid);
  if(!account?.email||account.emailVerified!==true)
   reject(403,'Verify the registered developer email before changing password');
  if(action==='developer/managed/security/otp/send'){
   // The client reauthenticates with CURRENT password; a recent auth_time
   // is enforced by the broker, not inferred from an editable UI state.
   const bearer=String(req.headers?.authorization||'').replace(/^Bearer\s+/i,'');
   const verified=await auth.verifyIdToken(bearer,true);
   if(verified.uid!==uid||!Number.isFinite(verified.auth_time)||
      t-verified.auth_time*1000>180000||t-verified.auth_time*1000<0)
    reject(401,'Re-enter the current password before requesting OTP');
   const code=String(randomInt(1000000)).padStart(6,'0');
   const nonce=randomBytes(24).toString('hex');
   await db.runTransaction(async tx=>{
    const row=await tx.get(ref),old=row.exists?row.data():{};
    const inWindow=Number(old.windowStartAt)>0&&t-Number(old.windowStartAt)<86400000;
    if(t-Number(old.lastSentAt||0)<60000)reject(429,'Wait before resending OTP');
    if(inWindow&&Number(old.sentInWindow||0)>=6)reject(429,'Too many OTP requests today');
    tx.set(ref,{nonce,hash:digest(uid,nonce,code),sentAt:t,expiresAt:t+600000,
     lastSentAt:t,attempts:0,verifiedAt:0,consumedAt:0,
     windowStartAt:inWindow?old.windowStartAt:t,sentInWindow:(inWindow?Number(old.sentInWindow||0):0)+1});
   });
   try{
    const response=await fetchImpl('https://api.resend.com/emails',{
     method:'POST',
     headers:{Authorization:'Bearer '+apiKey,'Content-Type':'application/json'},
     body:JSON.stringify({from,to:[account.email],subject:'Saarthi AI developer security code',
      text:'Your Saarthi AI developer verification code is '+code+'. It expires in 10 minutes. If you did not request this, ignore the email.'}),
     signal:AbortSignal.timeout(12000),
    });
    if(!response?.ok)throw Error('Mail provider rejected delivery');
   }catch(_){
    // Disable only our own challenge; a concurrent newer resend must survive.
    await db.runTransaction(async tx=>{
     const row=await tx.get(ref);
     if(row.exists&&row.data().nonce===nonce)tx.set(ref,{hash:'',expiresAt:0},{merge:true});
    });
    reject(503,'OTP email could not be sent; password remains unchanged');
   }
   return {success:true,expiresAt:t+600000,resendAfter:t+60000};
  }
  if(action==='developer/managed/security/otp/verify'){
   const code=String(body.otp||'');
   if(!/^\d{6}$/.test(code))reject(400,'Enter a valid six-digit OTP');
   return db.runTransaction(async tx=>{
    const row=await tx.get(ref),value=row.exists?row.data():null;
    if(!value||!value.hash||value.expiresAt<=t||value.consumedAt||
      Number(value.attempts||0)>=5)reject(403,'OTP expired or unavailable');
    if(value.verifiedAt)reject(409,'OTP was already verified');
    const expected=Buffer.from(value.hash,'hex');
    const actual=Buffer.from(digest(uid,value.nonce,code),'hex');
    const correct=expected.length===32&&timingSafeEqual(expected,actual);
    if(!correct){
     tx.set(ref,{attempts:Number(value.attempts||0)+1},{merge:true});
     return {success:false,verified:false};
    }
    tx.set(ref,{verifiedAt:t,hash:''},{merge:true});
    return {success:true,verified:true,expiresAt:value.expiresAt};
   });
  }
  if(action==='developer/managed/security/otp/change'){
   const password=body.password;
   if(typeof password!=='string'||password.length<12||password.length>128)
    reject(400,'Password must contain 12–128 characters');
   await db.runTransaction(async tx=>{
    const row=await tx.get(ref),value=row.exists?row.data():null;
    if(!value||!value.verifiedAt||value.consumedAt||value.expiresAt<=t)
     reject(403,'Verify a fresh email OTP before changing password');
    tx.set(ref,{consumedAt:t,hash:''},{merge:true});
   });
   await auth.updateUser(uid,{password});
   await auth.revokeRefreshTokens(uid);
   await db.collection('platform_audit').add({action,actor:uid,at:t});
   return {success:true,passwordChanged:true};
  }
  reject(400,'Unknown developer security action');
 };
}
module.exports={createDeveloperPasswordOtp};
