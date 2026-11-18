'use strict';
// A native person lifecycle commits directly to the signed school owner. It
// does not claim an edge enqueue. Bind its readback to the exact submitted op.
function verifiedNativeReceipt(reply, request, schoolId) {
 const row=reply?.record;
 return reply?.success===true&&reply.schoolId===schoolId&&reply.syncProtocol===2&&
  reply.personLifecycleVersion===1&&reply.operationId===request.operationId&&
  reply.reconcileRequired!==true&&!reply.delivery&&
  typeof reply.recordRevision==='string'&&reply.recordRevision.length>0&&
  !/^(cf-|live-)/.test(reply.recordRevision)&&row?.schoolId===schoolId&&
  (row.id===undefined||row.id===request.id)&&row._syncRevision===reply.recordRevision&&
  row._syncOperationId===request.operationId&&
  (request.operation==='delete'?row._syncDeleted===true&&
   reply.deleteEverywhereVersion===1&&reply.driveDeletionComplete===true&&
   reply.firebaseDeletionComplete===true:request.operation==='write'&&row._syncDeleted!==true);
}
async function retryExactDelete(request, submit, {
 attempts=12,delay=ms=>new Promise(r=>setTimeout(r,ms)),
 observeProgress,now=()=>performance.now(),maxElapsedMs=30*60*1000,
}={}) {
 if(request.operation!=='delete'||request.syncProtocol!==2||request.deleteEverywhereVersion!==1||
    request.collection!=='students_directory'||typeof request.operationId!=='string'||
    !/^[A-Za-z0-9_-]{16,100}$/.test(request.operationId)||
    !/^p-[a-f0-9]{32,64}$/.test(request.deletedStudentGeneration||'')||
    !Number.isSafeInteger(attempts)||attempts<1||attempts>48||
    (attempts>12&&typeof observeProgress!=='function')||
    !Number.isSafeInteger(maxElapsedMs)||maxElapsedMs<1||maxElapsedMs>40*60*1000)
  throw Error('Exact generation-bound TEST delete required');
 const immutable=JSON.stringify(request),started=now();
 let previousProgress,stalled=0;
 const budget=()=>{if(now()-started>=maxElapsedMs)
  throw Object.assign(Error('Exact TEST delete exceeded elapsed budget; operation retained'),{code:'SCRIPT_DELETE_BUDGET_EXHAUSTED'});};
 const retryable=new Set(['SCRIPT_DELETE_EVERYWHERE_PENDING','SCRIPT_TIMEOUT',
  'SCRIPT_HTTP_ERROR','PERSON_ACK_UNVERIFIED','PERSON_DELETE_RECEIPT_UNVERIFIED']);
 for(let n=0;n<attempts;n++) {
  budget();
  try{return await submit(JSON.parse(immutable));}
  catch(error){if(!(retryable.has(error.code)||error.name==='TimeoutError')||n+1===attempts)throw error;}
  budget();
  if(observeProgress){
   const progress=await observeProgress(JSON.parse(immutable),n+1);
   if(typeof progress!=='string'||!progress)throw Error('Verified delete progress required');
   stalled=progress===previousProgress?stalled+1:0;previousProgress=progress;
   if(stalled>=3)throw Object.assign(Error('Exact TEST deletion made no durable progress; operation retained'),{code:'SCRIPT_DELETE_NO_PROGRESS'});
  }
  budget();await delay(Math.min(5000,Math.max(0,maxElapsedMs-(now()-started))));
 }
}
module.exports={verifiedNativeReceipt,retryExactDelete};
