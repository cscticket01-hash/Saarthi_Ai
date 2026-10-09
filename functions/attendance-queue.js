'use strict';
const {createHash,randomUUID}=require('node:crypto');
const digest=s=>createHash('sha256').update(s).digest('hex');
/** Durable coordination only. School operational records remain in school Drive.
 * No accepted acknowledgement is sent before store.create has completed. */
function createAttendanceQueue({store,deliver,now=Date.now,batchSize=100,minBatchSize=25,maxBatchSize=200,deliveryBatchSize=25,random=Math.random,targetBatchMillis=2000,maxConcurrency=2}){
 if(!Number.isInteger(minBatchSize)||!Number.isInteger(maxBatchSize)||minBatchSize<1||maxBatchSize>200||minBatchSize>maxBatchSize||!Number.isInteger(batchSize)||batchSize<minBatchSize||batchSize>maxBatchSize||!Number.isInteger(deliveryBatchSize)||deliveryBatchSize<1||deliveryBatchSize>25||!Number.isFinite(targetBatchMillis)||targetBatchMillis<=0||typeof random!=='function'||!Number.isInteger(maxConcurrency)||maxConcurrency<1||maxConcurrency>2)throw new Error('Invalid bounded attendance batch configuration');
 let draining=false,currentBatchSize=batchSize,currentConcurrency=1;
 const metrics={accepted:0,duplicates:0,completed:0,retried:0,rejected:0,batchSize:currentBatchSize,lastBatchMillis:0,lastBatchFailures:0,concurrency:currentConcurrency};
 async function enqueue({schoolId,role,personId,day,mode,payload}){
  if(!/^vs-[a-f0-9]{32}$/.test(schoolId)||!['student','teacher'].includes(role)||!['entry','exit'].includes(mode)||!/^\d{4}-\d{2}-\d{2}$/.test(day)||typeof personId!=='string'||!personId||personId.length>200)throw new Error('Invalid attendance operation');
  const operationId=digest(JSON.stringify([schoolId,role,personId,day,mode]));
  const row={operationId,schoolId,day,mode,payload,state:'pending',attempts:0,createdAt:now(),nextAttemptAt:now()};
  const created=await store.create(operationId,row);
  if(created)metrics.accepted++;else metrics.duplicates++;
  return {accepted:true,operationId,duplicate:!created,message:created?'Attendance accepted for processing.':'Attendance submission already accepted.'};
 }
 async function drain(){
  if(draining)return {processed:0,nextRetryAt:null};draining=true;
  let processed=0,nextRetryAt=null,failures=0;const started=now();
  try{
   const rows=await store.pending(currentBatchSize),groups=new Map();
   for(const row of rows){
    if(row.nextAttemptAt>now())continue;
    if(!groups.has(row.schoolId))groups.set(row.schoolId,[]);groups.get(row.schoolId).push(row);
   }
   const processSchool=async([school,candidates])=>{
    for(let offset=0;offset<candidates.length;offset+=deliveryBatchSize){
     const items=[];
     // Claim just before delivery: queued later chunks must not expire while an earlier Script call runs.
     for(const row of candidates.slice(offset,offset+deliveryBatchSize)){
      const claim=randomUUID();if(await store.claim(row.operationId,claim,now(),now()+120000))items.push({...row,claim});
     }
     if(!items.length)continue;
    let acknowledgements;
    try{acknowledgements=await deliver(school,items);}
    catch(_){acknowledgements=[];}
    for(const item of items){
     const ack=acknowledgements.find(a=>a.operationId===item.operationId);
     const definitive=ack?.success===false&&ack.authoritative===true;
     const state=ack?.success===true?'completed':definitive?'needsAttention':'retry';
     const attempts=item.attempts+1;
     const retryAt=now()+Math.min(3600000,Math.floor(5000*2**Math.min(attempts,9)*(0.5+Math.max(0,Math.min(1,random())))));
     await store.finish(item.operationId,item.claim,{state,attempts,
       ...(state==='completed'?{completedAt:now()}:{}),
       lastError:state==='completed'?'':definitive?'Attendance requires school review.':'Attendance service unavailable; operation retained.',
       nextAttemptAt:['completed','needsAttention'].includes(state)?Number.MAX_SAFE_INTEGER:retryAt});
     processed++;
     if(state==='retry'){failures++;nextRetryAt=nextRetryAt===null?retryAt:Math.min(nextRetryAt,retryAt);}
     if(state==='completed')metrics.completed++;else if(state==='retry')metrics.retried++;else metrics.rejected++;
    }
    }
   };
   // One worker owns each school: its Script mutations remain strictly ordered.
   // Only independent schools may run concurrently, with an absolute cap of two.
   const work=[...groups];let cursor=0;
   const outcomes=await Promise.allSettled(Array.from({length:Math.min(currentConcurrency,work.length)},async()=>{
    while(cursor<work.length){const group=work[cursor++];await processSchool(group);}
   }));
   const failedWorker=outcomes.find(result=>result.status==='rejected');
   if(failedWorker)throw failedWorker.reason;
   metrics.lastBatchMillis=Math.max(0,now()-started);metrics.lastBatchFailures=failures;
   if(failures||metrics.lastBatchMillis>targetBatchMillis){currentBatchSize=Math.max(minBatchSize,Math.floor(currentBatchSize/2));currentConcurrency=1;}
   else if(processed===currentBatchSize){currentBatchSize=Math.min(maxBatchSize,currentBatchSize+25);currentConcurrency=Math.min(maxConcurrency,currentConcurrency+1);}
   metrics.batchSize=currentBatchSize;metrics.concurrency=currentConcurrency;
  }finally{draining=false;}
  return {processed,nextRetryAt};
 }
 return {enqueue,drain,metrics};
}
function firestoreAttendanceStore(db,{schoolId=null,collectionName='attendance_outbox'}={}){
 if(schoolId!==null&&!/^vs-[a-f0-9]{32}$/.test(schoolId))throw Error('Invalid attendance school scope');
 if(!['attendance_outbox','attendance_test_outbox'].includes(collectionName))throw Error('Invalid attendance collection');
 const collection=db.collection(collectionName);
 const ref=id=>db.doc(collectionName+'/'+id);
 return {
  create:async(id,row)=>{if(schoolId&&row.schoolId!==schoolId)throw Error('Foreign attendance school');try{await ref(id).create(row);return true;}catch(e){if(e.code===6||e.code==='already-exists')return false;throw e;}},
  pending:async(limit)=>{
   const scope=schoolId?collection.where('schoolId','==',schoolId):collection;
   const result=await scope.where('nextAttemptAt','<=',Date.now()).orderBy('nextAttemptAt').limit(limit).get();
   return result.docs.map(d=>({...d.data(),operationId:d.id})).filter(row=>!schoolId||row.schoolId===schoolId);
  },
  claim:(id,claim,at,expires)=>db.runTransaction(async tx=>{
   const r=ref(id),snap=await tx.get(r);if(!snap.exists)return false;const row=snap.data();
   if(schoolId&&row.schoolId!==schoolId)return false;
   if(!['pending','retry','processing'].includes(row.state)||row.nextAttemptAt>at||row.state==='processing'&&row.claimExpiresAt>at)return false;
   tx.set(r,{state:'processing',claim,claimExpiresAt:expires,nextAttemptAt:expires},{merge:true});return true;
  }),
  finish:(id,claim,values)=>db.runTransaction(async tx=>{
   const r=ref(id),snap=await tx.get(r);if(!snap.exists||snap.data().claim!==claim)return;
   if(schoolId&&snap.data().schoolId!==schoolId)return;
   tx.set(r,{...values,claim:'',claimExpiresAt:0},{merge:true});
  }),
 };
}
// Wake on committed submissions; only restart/recovery scans poll while idle.
function createAttendanceWorker({drain,setTimer=setTimeout,clearTimer=clearTimeout,now=Date.now,onError=()=>{}}){
 let timer=null,running=false,woken=false,stopped=false;
 function schedule(delay){if(stopped)return;if(timer!==null)clearTimer(timer);timer=setTimer(run,delay);timer?.unref?.();}
 async function run(){timer=null;if(running){woken=true;return;}running=true;let delay=240000;
  try{const result=await drain();if(result?.processed>0)delay=2000;
   if(result?.nextRetryAt!==null&&result?.nextRetryAt!==undefined)delay=Math.min(delay,Math.max(1000,result.nextRetryAt-now()));
  }catch(e){onError(e);delay=30000;}finally{running=false;const urgent=woken;woken=false;schedule(urgent?0:delay);}
 }
 function wake(){if(running){woken=true;return;}schedule(0);}
 schedule(0);
 return {wake,stop:()=>{stopped=true;if(timer!==null)clearTimer(timer);timer=null;}};
}
module.exports={createAttendanceQueue,firestoreAttendanceStore,createAttendanceWorker};
