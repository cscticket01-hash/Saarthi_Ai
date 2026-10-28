'use strict';
const {isQuota}=require('./provider-pressure');
const {createHash,randomUUID}=require('node:crypto');
const digest=s=>createHash('sha256').update(s).digest('hex');
// Independent record transactions may overlap without changing Script order.
// All in-flight work settles before the queue drain guard is released.
async function boundedResults(rows,visit,limit=4){
 const results=new Array(rows.length);let next=0;
 await Promise.all(Array.from({length:Math.min(limit,rows.length)},async()=>{
  while(next<rows.length){
   const index=next++;
   try{results[index]={status:'fulfilled',value:await visit(rows[index])};}
   catch(reason){results[index]={status:'rejected',reason};}
  }
 }));
 return results;
}
/** Durable coordination only. School operational records remain in school Drive.
 * No accepted acknowledgement is sent before store.create has completed. */
function createAttendanceQueue({store,deliver,now=Date.now,batchSize=100,minBatchSize=25,maxBatchSize=200,deliveryBatchSize=25,random=Math.random,targetBatchMillis=2000,maxConcurrency=2,retryAtForSchool=()=>0}){
 if(typeof retryAtForSchool!=='function'||!Number.isInteger(minBatchSize)||!Number.isInteger(maxBatchSize)||minBatchSize<1||maxBatchSize>200||minBatchSize>maxBatchSize||!Number.isInteger(batchSize)||batchSize<minBatchSize||batchSize>maxBatchSize||!Number.isInteger(deliveryBatchSize)||deliveryBatchSize<1||deliveryBatchSize>25||!Number.isFinite(targetBatchMillis)||targetBatchMillis<=0||typeof random!=='function'||!Number.isInteger(maxConcurrency)||maxConcurrency<1||maxConcurrency>2)throw new Error('Invalid bounded attendance batch configuration');
 let draining=false,currentBatchSize=batchSize,currentConcurrency=1;
 const schoolCooldowns=new Map();let lastSchool=null;
 const metrics={accepted:0,duplicates:0,completed:0,retried:0,rejected:0,batchSize:currentBatchSize,lastBatchMillis:0,lastBatchFailures:0,concurrency:currentConcurrency,lastPhaseTiming:null};
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
  let processed=0,nextRetryAt=null,failures=0;const started=now(),clock=performance.now();
  const phases={queueReadMs:0,claimMs:0,scriptMs:0,finishMs:0,scriptBatches:0};
  try{
   const queryStart=performance.now();
   const rows=await store.pending(currentBatchSize),groups=new Map();
   phases.queueReadMs+=Math.round(performance.now()-queryStart);
   for(const row of rows){
    if(row.nextAttemptAt>now())continue;
    const cooldown=schoolCooldowns.get(row.schoolId)||0;
    if(cooldown>now()){nextRetryAt=nextRetryAt===null?cooldown:Math.min(nextRetryAt,cooldown);continue;}
    schoolCooldowns.delete(row.schoolId);
    if(!groups.has(row.schoolId))groups.set(row.schoolId,[]);groups.get(row.schoolId).push(row);
   }
   const processSchool=async([school,candidates])=>{
    const providerDeadline=retryAtForSchool(school);
    if(Number.isSafeInteger(providerDeadline)&&providerDeadline>now()){
     nextRetryAt=nextRetryAt===null?providerDeadline:Math.min(nextRetryAt,providerDeadline);return false;
    }
    for(let offset=0;offset<candidates.length;offset+=deliveryBatchSize){
     // Claim separate Firestore rows with at most four transactions running.
     // Keep the original order inside the <=25-record Script batch.
     const claimStart=performance.now();
     const claims=await boundedResults(candidates.slice(offset,offset+deliveryBatchSize),async row=>{
      const claim=randomUUID();
      return await store.claim(row.operationId,claim,now(),now()+120000)?{...row,claim}:null;
     });
     phases.claimMs+=Math.round(performance.now()-claimStart);
     const claimFailure=claims.find(x=>x.status==='rejected');
     const items=claims.filter(x=>x.status==='fulfilled'&&x.value!==null).map(x=>x.value);
     if(!items.length){
      if(claimFailure)throw claimFailure.reason;
      continue;
     }
     let acknowledgements,deliveryError;
     const scriptStart=performance.now();
     try{acknowledgements=await deliver(school,items);}
     catch(error){deliveryError=error;acknowledgements=[];}
     finally{phases.scriptMs+=Math.round(performance.now()-scriptStart);phases.scriptBatches++;}
    // Only one unambiguous receipt for this claimed operation can finish it.
    // Missing, malformed or duplicated receipts remain durable retry work.
    const receipts=new Map(),duplicates=new Set(),claimed=new Set(items.map(i=>i.operationId));
    for(const ack of Array.isArray(acknowledgements)?acknowledgements:[]){
     if(!ack||!claimed.has(ack.operationId))continue;
     if(receipts.has(ack.operationId)){duplicates.add(ack.operationId);continue;}
     receipts.set(ack.operationId,ack);
    }
    // Commit exact matched receipts to distinct Firestore rows with a cap
    // of four; if a transaction fails, its original claim stays recoverable.
    const finishStart=performance.now();
    const finishes=await boundedResults(items,async item=>{
     const ack=duplicates.has(item.operationId)?null:receipts.get(item.operationId);
     const definitive=ack?.success===false&&ack.authoritative===true;
     const state=ack?.success===true?'completed':definitive?'needsAttention':'retry';
     const attempts=item.attempts+1;
     const retryAt=now()+Math.max(isQuota(deliveryError)?60000:0,Math.min(86400000,Number(deliveryError?.retryAfterMs)||0),Math.min(3600000,Math.floor(5000*2**Math.min(attempts,9)*(0.5+Math.max(0,Math.min(1,random()))))));
     await store.finish(item.operationId,item.claim,{state,attempts,
       ...(state==='completed'?{completedAt:now()}:{}),
       lastError:state==='completed'?'':definitive?'Attendance requires school review.':'Attendance service unavailable; operation retained.',
       nextAttemptAt:['completed','needsAttention'].includes(state)?Number.MAX_SAFE_INTEGER:retryAt});
     return {state,retryAt};
    });
    phases.finishMs+=Math.round(performance.now()-finishStart);
    for(const outcome of finishes){
     if(outcome.status!=='fulfilled')continue;
     const {state,retryAt}=outcome.value;
     processed++;
     if(state==='retry'){failures++;nextRetryAt=nextRetryAt===null?retryAt:Math.min(nextRetryAt,retryAt);}
     if(state==='completed')metrics.completed++;else if(state==='retry')metrics.retried++;else metrics.rejected++;
    }
    const failedFinish=finishes.find(x=>x.status==='rejected');
    if(failedFinish)throw failedFinish.reason;
    if(claimFailure)throw claimFailure.reason;
    if(isQuota(deliveryError)){
     const until=now()+Math.max(60000,Math.min(86400000,Number(deliveryError.retryAfterMs)||0));
     if(schoolCooldowns.size>=2000&&!schoolCooldowns.has(school))schoolCooldowns.delete(schoolCooldowns.keys().next().value);
     schoolCooldowns.set(school,until);return false;
    }
    }
   };
   // One worker owns each school: its Script mutations remain strictly ordered.
   // Only independent schools may run concurrently, with an absolute cap of two.
   // Rotate school turns; at most one batch from each school is in flight.
   // Fairness applies to the bounded fetched window, not unseen queue rows.
   const work=[...groups].map(([school,rows])=>({school,rows,offset:0,busy:false,blocked:false}));
   let cursor=0;
   const previous=work.findIndex(group=>group.school===lastSchool);
   if(previous>=0)cursor=(previous+1)%work.length;
   function nextTurn(){
    for(let i=0;i<work.length;i++){
     const group=work[cursor++%work.length];
     if(group.busy||group.blocked||group.offset>=group.rows.length)continue;
     group.busy=true;const items=group.rows.slice(group.offset,group.offset+deliveryBatchSize);
     group.offset+=items.length;lastSchool=group.school;return {group,items};
    }
    return null;
   }
   const outcomes=await Promise.allSettled(Array.from({length:Math.min(currentConcurrency,work.length)},async()=>{
    for(;;){const turn=nextTurn();if(!turn)return;
     try{if(await processSchool([turn.group.school,turn.items])===false)turn.group.blocked=true;}
     finally{turn.group.busy=false;}
    }
   }));
   const failedWorker=outcomes.find(result=>result.status==='rejected');
   if(failedWorker)throw failedWorker.reason;
   metrics.lastBatchMillis=Math.max(0,now()-started);metrics.lastBatchFailures=failures;
   if(failures||metrics.lastBatchMillis>targetBatchMillis){currentBatchSize=Math.max(minBatchSize,Math.floor(currentBatchSize/2));currentConcurrency=1;}
   else if(processed===currentBatchSize){currentBatchSize=Math.min(maxBatchSize,currentBatchSize+25);currentConcurrency=Math.min(maxConcurrency,currentConcurrency+1);}
   metrics.batchSize=currentBatchSize;metrics.concurrency=currentConcurrency;
  }finally{
   // Aggregate stage durations only: no school/person IDs or payloads.
   metrics.lastPhaseTiming={...phases,totalMs:Math.round(performance.now()-clock),processed};
   draining=false;
  }
  return {processed,nextRetryAt};
 }
 return {enqueue,drain,metrics};
}
function firestoreAttendanceStore(db,{schoolId=null,collectionName='attendance_outbox'}={}){
 if(schoolId!==null&&!/^vs-[a-f0-9]{32}$/.test(schoolId))throw Error('Invalid attendance school scope');
 if(!['attendance_outbox','attendance_test_outbox'].includes(collectionName))throw Error('Invalid attendance collection');
 const collection=db.collection(collectionName);
 // The isolated TEST outbox is dedicated to TEST traffic. Query by due time
 // without a composite (schoolId,nextAttemptAt) index; filter results again.
 // Production keeps its existing scoped query and transactional school fences.
 const isolatedTestQuery=schoolId!==null&&collectionName==='attendance_test_outbox';
 const ref=id=>db.doc(collectionName+'/'+id);
 return {
  create:async(id,row)=>{if(schoolId&&row.schoolId!==schoolId)throw Error('Foreign attendance school');try{await ref(id).create(row);return true;}catch(e){if(e.code===6||e.code==='already-exists')return false;throw e;}},
  pending:async(limit)=>{
   const scope=schoolId&&!isolatedTestQuery?collection.where('schoolId','==',schoolId):collection;
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
 // Keep a known retry deadline across empty due-queue scans: a short scan
 // must not turn a 10-second retry into a four-minute idle wait.
 // No extra Firestore reads and no queue mutation are introduced.
 let timer=null,running=false,woken=false,stopped=false,earliestRetryAt=null,blockedUntil=0;
 function schedule(delay){if(stopped)return;if(timer!==null)clearTimer(timer);timer=setTimer(run,Math.max(delay,blockedUntil-now(),0));timer?.unref?.();}
 async function run(){timer=null;if(running){woken=true;return;}running=true;let delay=240000;
  try{
   if(earliestRetryAt!==null&&earliestRetryAt<=now())earliestRetryAt=null;
   const result=await drain();if(result?.processed>0)delay=2000;
   if(Number.isSafeInteger(result?.nextRetryAt)&&result.nextRetryAt>0)
    earliestRetryAt=earliestRetryAt===null?result.nextRetryAt:Math.min(earliestRetryAt,result.nextRetryAt);
   if(earliestRetryAt!==null)delay=Math.min(delay,Math.max(1000,earliestRetryAt-now()));
  }catch(e){onError(e);delay=30000;
   if(isQuota(e))blockedUntil=Math.max(blockedUntil,now()+Math.max(60000,Math.min(86400000,Number(e.retryAfterMs)||0)));
   if(earliestRetryAt!==null)delay=Math.min(delay,Math.max(1000,earliestRetryAt-now()));
  }finally{running=false;const urgent=woken;woken=false;schedule(urgent?0:delay);}
 }
 function wake(){if(running){woken=true;return;}schedule(0);}
 schedule(0);
 return {wake,stop:()=>{stopped=true;if(timer!==null)clearTimer(timer);timer=null;}};
}
module.exports={createAttendanceQueue,firestoreAttendanceStore,createAttendanceWorker};
