'use strict';
const {createHmac,randomBytes,timingSafeEqual}=require('node:crypto');

const TTL=10*60*1000;
const WINDOW=24*60*60*1000;
const neutral={success:true};
const deny=(status,message)=>{throw Object.assign(new Error(message),{status,publicMessage:true});};

function createDeveloperRecovery({auth,db,uid,pepper,apiKey,from,resetUrl,fetchImpl=fetch,now=Date.now}){
 const hash=value=>createHmac('sha256',pepper).update(value).digest('hex');
 const ref=db.doc('developer_recovery/'+uid);
 const update=callback=>db.runTransaction(async tx=>{
  const snapshot=await tx.get(ref);
  const write=values=>tx.set(ref,values,{merge:true});
  return callback(snapshot.exists?snapshot.data():{},write);
 });
 const eligible=account=>!account.disabled&&account.emailVerified===true&&
  (account.customClaims?.developer===true||account.customClaims?.admin===true);
 return async function recover(body){
  if(body.action==='developer/recovery/request'){
   if(typeof body.email!=='string'||body.email.length>254)return neutral;
   const account=await auth.getUser(uid);
   if(!eligible(account)||account.email?.toLowerCase()!==body.email.trim().toLowerCase())return neutral;
   const token=randomBytes(32).toString('hex');
   const tokenHash=hash(token);
   const started=await update((row,write)=>{
    const time=now();
    const sent=(row.sent||[]).filter(at=>at>time-WINDOW);
    if(sent.length>=2||sent.some(at=>at>time-TTL)||row.pendingUntil>time||row.resetting)return false;
    write({pending:tokenHash,pendingUntil:time+WINDOW});
    return true;
   });
   if(!started)return neutral;
   const link=new URL(resetUrl);
   link.hash='reset='+token;
   let response;
   try{
    response=await fetchImpl('https://api.resend.com/emails',{
     method:'POST',
     headers:{Authorization:'Bearer '+apiKey,'Content-Type':'application/json','Idempotency-Key':tokenHash},
     body:JSON.stringify({from,to:[account.email],subject:'Saarthi AI developer password reset',
      text:'Open this one-time link within 10 minutes: '+link.href}),
     signal:AbortSignal.timeout(12000)
    });
   }catch{return neutral;}
   await update((row,write)=>{
    if(row.pending!==tokenHash)return;
    const time=now();
    if(response.ok){
     write({sent:[...(row.sent||[]).filter(at=>at>time-WINDOW),time],
      tokenHash,expiresAt:time+TTL,email:account.email,pending:null,pendingUntil:0});
    }else if(response.status>=400&&response.status<500&&response.status!==429){
     write({pending:null,pendingUntil:0});
    }
   });
   return neutral;
  }
  if(body.action==='developer/recovery/confirm'){
   const {token,password}=body;
   if(typeof password!=='string'||password.length<12||password.length>128)
    deny(400,'Use a password of 12–128 characters.');
   if(typeof token!=='string'||!/^[a-f0-9]{64}$/.test(token))
    deny(403,'Reset link is invalid or expired.');
   const account=await auth.getUser(uid);
   await update((row,write)=>{
    if(!eligible(account)||row.email!==account.email||!/^[a-f0-9]{64}$/.test(row.tokenHash||'')||
       !timingSafeEqual(Buffer.from(row.tokenHash,'hex'),Buffer.from(hash(token),'hex'))||
       row.expiresAt<=now()||row.resetting)
     deny(403,'Reset link is invalid or expired.');
    write({tokenHash:null,expiresAt:0,resetting:true});
   });
   try{
    await auth.updateUser(uid,{password});
    await auth.revokeRefreshTokens(uid);
   }finally{
    await update((row,write)=>write({resetting:false}));
   }
   return {success:true,passwordChanged:true};
  }
  deny(400,'Unknown developer recovery action.');
 };
}
module.exports={createDeveloperRecovery};
