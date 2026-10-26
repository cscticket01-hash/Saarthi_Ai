'use strict';
const {createHash,randomUUID}=require('node:crypto');
// Metadata-only write-ahead notification work. No school record bodies, tokens
// or fabricated storage receipts. Publication is a hint, never a record ACK.
function createSchoolSyncDelivery({db,feed,now=Date.now,maxPending=512}) {
 const schoolRef=school=>{if(!/^vs-[a-f0-9]{32}$/.test(school))throw Error('Invalid delivery school');return db.doc('school_sync_delivery/'+school);};
 async function mutate(school,change){return db.runTransaction(async tx=>{const ref=schoolRef(school),snap=await tx.get(ref),state=snap.exists?snap.data():{};
  if(state.schoolId&&state.schoolId!==school)throw Error('Foreign notification state');
  const entries={...(state.entries||{})},result=change(entries);
  tx.set(ref,{version:1,schoolId:school,entries});return result;
 });}
 async function prepare(school,body){
  if(!feed.enabled || body.action!=='managed_records' || body.syncProtocol!==2 || !['write','delete'].includes(body.operation))return null;
  const key=createHash('sha256').update(JSON.stringify([body.collection,body.id,body.operationId])).digest('hex');
  return mutate(school,entries=>{
   if(entries[key])return {school,key,...entries[key]};
   if(Object.keys(entries).length>=maxPending)throw Object.assign(Error('Notification recovery backlog; retry pending write'),{status:503,code:'SYNC_DELIVERY_BUSY',publicMessage:true});
   const value={token:randomUUID(),collection:body.collection,id:body.id,operationId:body.operationId,
    operation:body.operation,createdAt:now(),attempts:0,nextAttemptAt:0,state:'prepared'};
   entries[key]=value;return {school,key,...value};
  });
 }
 async function remove(ticket){return mutate(ticket.school,entries=>{if(entries[ticket.key]?.token===ticket.token)delete entries[ticket.key];});}
 async function rejected(ticket){return mutate(ticket.school,entries=>{if(entries[ticket.key]?.token===ticket.token && entries[ticket.key].state==='prepared')delete entries[ticket.key];});}
 async function publish(ticket){
  const cols=ticket.operation==='delete'&&ticket.collection==='students_directory'?null:[ticket.collection];
  if(cols)await feed.publishMany(ticket.school,cols,ticket.id);
  else await feed.publishMany(ticket.school,feed.collections);
  await remove(ticket);
 }
 async function committed(ticket,revision){
  if(!ticket)return;
  await mutate(ticket.school,entries=>{if(entries[ticket.key]?.token===ticket.token)entries[ticket.key]={...entries[ticket.key],state:'committed',revision};});
  await publish(ticket);
 }
 async function recover(school,verify){
  if(!feed.enabled)return {repaired:0,pending:0};
  const snap=await schoolRef(school).get(),state=snap.exists?snap.data():{};
  if(state.schoolId&&state.schoolId!==school)throw Error('Foreign notification state');
  const entries=Object.entries(state.entries||{}).filter(([,r])=>r.nextAttemptAt<=now()).sort((a,b)=>a[1].createdAt-b[1].createdAt).slice(0,5);
  let repaired=0;
  for(const [key,row]of entries){const ticket={school,key,...row};try{
   const claimed=await mutate(school,items=>{if(items[key]?.token!==row.token || items[key].nextAttemptAt>now())return false;
    items[key]={...items[key],nextAttemptAt:now()+60000};return true;});
   if(!claimed)continue;
   // Even after a lost response/crash, only a verified same-operation record
   // can promote a prepared intent. A newer record is left to normal catch-up.
   if(row.state!=='committed' && !await verify(ticket)) {
    await mutate(school,items=>{if(items[key]?.token===row.token) {
      if(now()-row.createdAt>86400000)delete items[key];
      else items[key]={...items[key],attempts:row.attempts+1,nextAttemptAt:now()+Math.min(3600000,2000*2**Math.min(row.attempts,10))};
    }});continue;
   }
   await publish(ticket);repaired++;
  }catch(_){await mutate(school,items=>{if(items[key]?.token===row.token)items[key]={...items[key],attempts:row.attempts+1,
    nextAttemptAt:now()+Math.min(3600000,2000*2**Math.min(row.attempts,10))};}).catch(()=>{});}}
  return {repaired,pending:Object.keys(state.entries||{}).length-repaired};
 }
 return {prepare,committed,remove,rejected,recover};
}
module.exports={createSchoolSyncDelivery};
