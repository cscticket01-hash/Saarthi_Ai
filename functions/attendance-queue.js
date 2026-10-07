'use strict';
const {createHash,randomUUID}=require('node:crypto');
const digest=s=>createHash('sha256').update(s).digest('hex');
/** Durable coordination only. School operational records remain in school Drive.
 * No accepted acknowledgement is sent before store.create has completed. */
function createAttendanceQueue({store,deliver,now=Date.now,batchSize=25}){
 let draining=false;
 const metrics={accepted:0,duplicates:0,completed:0,retried:0,rejected:0};
 async function enqueue({schoolId,role,personId,day,mode,payload}){
  if(!/^vs-[a-f0-9]{32}$/.test(schoolId)||!['student','teacher'].includes(role)||!['entry','exit'].includes(mode)||!/^\d{4}-\d{2}-\d{2}$/.test(day)||typeof personId!=='string'||!personId||personId.length>200)throw new Error('Invalid attendance operation');
  const operationId=digest(JSON.stringify([schoolId,role,personId,day,mode]));
  const row={operationId,schoolId,day,mode,payload,state:'pending',attempts:0,createdAt:now(),nextAttemptAt:now()};
  const created=await store.create(operationId,row);
  if(created)metrics.accepted++;else metrics.duplicates++;
  return {accepted:true,operationId,duplicate:!created,message:created?'Attendance accepted for processing.':'Attendance submission already accepted.'};
 }
 async function drain(){
  if(draining)return;draining=true;
  try{
   const rows=await store.pending(batchSize),groups=new Map();
   for(const row of rows){
    if(row.nextAttemptAt>now())continue;
    const claim=randomUUID();if(!await store.claim(row.operationId,claim,now(),now()+120000))continue;
    const item={...row,claim};if(!groups.has(row.schoolId))groups.set(row.schoolId,[]);groups.get(row.schoolId).push(item);
   }
   for(const [school,items]of groups){
    let acknowledgements;
    try{acknowledgements=await deliver(school,items);}
    catch(_){acknowledgements=[];}
    for(const item of items){
     const ack=acknowledgements.find(a=>a.operationId===item.operationId);
     const definitive=ack?.success===false&&ack.authoritative===true;
     const state=ack?.success===true?'completed':definitive?'needsAttention':'retry';
     const attempts=item.attempts+1;
     await store.finish(item.operationId,item.claim,{state,attempts,
       ...(state==='completed'?{completedAt:now()}:{}),
       lastError:state==='completed'?'':definitive?'Attendance requires school review.':'Attendance service unavailable; operation retained.',
       nextAttemptAt:['completed','needsAttention'].includes(state)?Number.MAX_SAFE_INTEGER:now()+Math.min(3600000,5000*2**Math.min(attempts,9))});
     if(state==='completed')metrics.completed++;else if(state==='retry')metrics.retried++;else metrics.rejected++;
    }
   }
  }finally{draining=false;}
 }
 return {enqueue,drain,metrics};
}
function firestoreAttendanceStore(db){
 const collection=db.collection('attendance_outbox');
 const ref=id=>db.doc('attendance_outbox/'+id);
 return {
  create:async(id,row)=>{try{await ref(id).create(row);return true;}catch(e){if(e.code===6||e.code==='already-exists')return false;throw e;}},
  pending:async(limit)=>{
   const result=await collection.where('nextAttemptAt','<=',Date.now()).orderBy('nextAttemptAt').limit(limit).get();
   return result.docs.map(d=>({...d.data(),operationId:d.id}));
  },
  claim:(id,claim,at,expires)=>db.runTransaction(async tx=>{
   const r=ref(id),snap=await tx.get(r);if(!snap.exists)return false;const row=snap.data();
   if(!['pending','retry','processing'].includes(row.state)||row.nextAttemptAt>at||row.state==='processing'&&row.claimExpiresAt>at)return false;
   tx.set(r,{state:'processing',claim,claimExpiresAt:expires,nextAttemptAt:expires},{merge:true});return true;
  }),
  finish:(id,claim,values)=>db.runTransaction(async tx=>{
   const r=ref(id),snap=await tx.get(r);if(!snap.exists||snap.data().claim!==claim)return;
   tx.set(r,{...values,claim:'',claimExpiresAt:0},{merge:true});
  }),
 };
}
module.exports={createAttendanceQueue,firestoreAttendanceStore};
