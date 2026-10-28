'use strict';
const {createHash,randomUUID}=require('node:crypto');
const unavailable=()=>Object.assign(Error('Provider recovery coordination unavailable; pending work retained.'),{status:503,code:'PROVIDER_PRESSURE_UNAVAILABLE',publicMessage:true});
// A single metadata subscription per broker; healthy calls do not perform a
// Firestore transaction. Recovery claims and quota changes are transactional.
// This is optional until its small but nonzero provider cost is accepted.
function createProviderPressureJournal({db,projectId,now=Date.now,maxEntries=2000,probeMillis=120000}){
 if(typeof projectId!=='string'||!projectId||maxEntries<1||maxEntries>2000||probeMillis<1000||probeMillis>180000)throw Error('Invalid pressure journal configuration');
 const id=createHash('sha256').update(projectId).digest('hex');
 const ref=db.doc('sync_provider_pressure/'+id);
 let latest=null,failed=false,unsubscribe=null,waiters=[],restartAt=0,closed=false;
 const key=(provider,scope)=>createHash('sha256').update(JSON.stringify([provider,scope])).digest('hex');
 function decode(snapshot){
  if(!snapshot.exists)return {};
  const value=snapshot.data();
  if(value.version!==1||value.projectId!==projectId||!value.gates||typeof value.gates!=='object'||Array.isArray(value.gates)||Object.keys(value.gates).length>maxEntries)throw unavailable();
  for(const [name,row]of Object.entries(value.gates)){
   if(!/^[a-f0-9]{64}$/.test(name)||!row||!Number.isSafeInteger(row.until)||!Number.isSafeInteger(row.attempts)||row.attempts<1||row.attempts>10||
      !Number.isSafeInteger(row.observedAt)||row.until<row.observedAt||row.until-row.observedAt>86400000||
      (row.claim!==undefined&&(typeof row.claim!=='string'||!Number.isSafeInteger(row.claimUntil))))throw unavailable();
  }
  return value.gates;
 }
 function settle(){for(const notify of waiters.splice(0))notify();}
 function failure(){failed=true;restartAt=now()+30000;settle();}
 function start(){
  if(unsubscribe!==null)return;
  // Set before subscribe because fakes or adapters may emit synchronously.
  unsubscribe=()=>{};
  try{unsubscribe=ref.onSnapshot(snapshot=>{try{latest=decode(snapshot);failed=false;}catch(_){failure();}settle();},failure);}
  catch(_){failure();}
 }
 async function ready(){
  if(closed)throw unavailable();
  if(failed&&now()>=restartAt){unsubscribe?.();unsubscribe=null;latest=null;failed=false;}
  start();
  if(latest===null&&!failed)await new Promise(resolve=>{
   let timer;const done=()=>{clearTimeout(timer);resolve();};waiters.push(done);
   timer=setTimeout(()=>{waiters=waiters.filter(x=>x!==done);resolve();},5000);timer.unref?.();
  });
  if(failed||latest===null)throw unavailable();
 }
 async function mutate(change){
  try{return await db.runTransaction(async tx=>{
   const gates={...decode(await tx.get(ref))};const result=change(gates);
   tx.set(ref,{version:1,projectId,gates});return result;
  });}catch(error){if(error?.code==='PROVIDER_PRESSURE_UNAVAILABLE')throw error;throw unavailable();}
 }
 async function admit(provider,scope){
  await ready();const name=key(provider,scope),row=latest[name];
  if(!row)return null;
  if(row.until>now())return {wait:row.until-now()};
  if(row.claim&&row.claimUntil>now())return {wait:row.claimUntil-now()};
  return mutate(gates=>{
   const current=gates[name];if(!current)return null;
   if(current.until>now())return {wait:current.until-now()};
   if(current.claim&&current.claimUntil>now())return {wait:current.claimUntil-now()};
   const claim=randomUUID();gates[name]={...current,claim,claimUntil:now()+probeMillis};
   return {name,claim};
  });
 }
 async function failedQuota(provider,scope,retryAfterMs){
  await ready();const name=key(provider,scope);
  return mutate(gates=>{
   const current=gates[name],attempts=Math.min(10,(current?.attempts||0)+1);
   const delay=Math.max(Math.min(900000,60000*2**(attempts-1)),Math.min(86400000,Math.max(0,Number(retryAfterMs)||0)));
   // Only old, unclaimed cooldown metadata may expire to make room.
   for(const [id,row]of Object.entries(gates))if(now()-row.until>86400000&&!(row.claim&&row.claimUntil>now()))delete gates[id];
   if(!gates[name]&&Object.keys(gates).length>=maxEntries)throw unavailable();
   const until=Math.max(current?.until||0,now()+delay);
   gates[name]={observedAt:now(),attempts,until};
   return until;
  });
 }
 async function succeeded(ticket){
  if(!ticket?.claim)return;
  await mutate(gates=>{if(gates[ticket.name]?.claim===ticket.claim)delete gates[ticket.name];});
 }
 function close(){closed=true;unsubscribe?.();unsubscribe=null;failed=true;settle();}
 return {admit,failedQuota,succeeded,close};
}
module.exports={createProviderPressureJournal};
