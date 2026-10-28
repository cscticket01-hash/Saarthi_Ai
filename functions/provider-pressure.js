'use strict';
// Evidence-based admission only. This never retries a write or creates an ACK.
const QUOTA_CODES=new Set(['SCRIPT_QUOTA_EXCEEDED','CLOUDFLARE_QUOTA_EXCEEDED','FIREBASE_QUOTA_EXCEEDED']);
function firebaseQuota(error){return [8,'8','resource-exhausted','RESOURCE_EXHAUSTED','firestore/resource-exhausted'].includes(error?.code);}
function isQuota(error){return error?.status===429||QUOTA_CODES.has(error?.code)||firebaseQuota(error);}
function retryAfterMillis(value,now=Date.now()){
 if(typeof value!=='string'||!value.trim())return 0;
 const seconds=/^\d+(?:\.\d+)?$/.test(value.trim())?Number(value):NaN;
 const millis=Number.isFinite(seconds)?seconds*1000:(/^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} GMT$/.test(value.trim())?Date.parse(value)-now:NaN);
 return Number.isFinite(millis)&&millis>0?Math.min(86400000,Math.ceil(millis)):0;
}
function quotaError(code,retryAfterMs=60000){return Object.assign(Error('Provider request limit reached; pending work retained for automatic recovery.'),{status:429,code,publicMessage:true,retryAfterMs});}
async function journalBudget(work,millis){
 let timer;
 try{return await Promise.race([work,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Object.assign(Error('Provider recovery coordination unavailable; pending work retained.'),{status:503,code:'PROVIDER_PRESSURE_UNAVAILABLE',publicMessage:true})),millis);})]);}
 finally{clearTimeout(timer);}
}
function createProviderPressure({now=Date.now,maxEntries=2000,isQuotaError=isQuota,journal=null,journalBudgetMs=1000}={}){
 const states=new Map();
 async function run(key,code,work){
  const stateKey=code+'\n'+key;
  const previous=states.get(stateKey);
  if(previous?.until>now())throw quotaError(code,previous.until-now());
  if(previous?.probing)throw quotaError(code,1000);
  if(previous)previous.probing=true;
  let ticket;
  try{
   if(journal){ticket=await journalBudget(journal.admit(code,key),journalBudgetMs);if(ticket?.wait)throw quotaError(code,ticket.wait);}
   const result=await work();
   // Coordination cleanup is not part of the authoritative provider ACK.
   if(journal&&ticket?.claim)await journalBudget(journal.succeeded(ticket),Math.min(250,journalBudgetMs)).catch(()=>{});
   // An older in-flight success must not reopen a newer quota gate.
   if(states.get(stateKey)===previous)states.delete(stateKey);
   return result;
  }catch(error){
   if(ticket?.wait)throw error;
   if(!isQuotaError(error))throw error;
   const attempts=Math.min(10,(states.get(stateKey)?.attempts||0)+1);
   const delay=Math.max(Math.min(900000,60000*2**(attempts-1)),Math.min(86400000,Number(error.retryAfterMs)||0));
   let until=Math.max(states.get(stateKey)?.until||0,now()+delay);
   // Admission refusals must not extend a shared cooldown or inflate attempts.
   if(journal&&!ticket?.wait){
    try{until=Math.max(until,await journalBudget(journal.failedQuota(code,key,delay),journalBudgetMs));}catch(_){/* Local gate stays closed if Firebase cannot persist quota metadata. */}
   }
   if(!states.has(stateKey)&&states.size>=maxEntries)states.delete(states.keys().next().value);
   states.set(stateKey,{attempts,until});
   throw quotaError(code,until-now());
  }finally{if(states.get(stateKey)===previous&&previous)previous.probing=false;}
 }
 return {run,retryAt:(key,code)=>{const until=states.get(code+'\n'+key)?.until||0;return until>now()?until:0;}};
}
module.exports={createProviderPressure,retryAfterMillis,isQuota,firebaseQuota,quotaError};
