'use strict';
// Isolated queue-component benchmark: real fsync-backed journal, mocked remote
// acknowledgements. This is NOT a live Firebase/Drive or 50k API capacity claim.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),{performance}=require('node:perf_hooks');
const {createAttendanceQueue}=require('../../functions/attendance-queue');
const percentile=(a,p)=>a.slice().sort((x,y)=>x-y)[Math.min(a.length-1,Math.floor(a.length*p))]||0;
async function run(count){
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'vs-attendance-load-')),journal=path.join(dir,'queue.jsonl'),fd=fs.openSync(journal,'a'),rows=new Map();
 const latencies=[],processing=[];let duplicatePrevented=0,remoteApplied=new Set(),pending=[],flushing=false;
 async function persist(row){return new Promise((resolve,reject)=>{pending.push({row,resolve,reject});if(!flushing){flushing=true;setImmediate(flush);}});}
 function flush(){const batch=pending;pending=[];try{fs.writeSync(fd,batch.map(x=>JSON.stringify(x.row)+'\n').join(''));fs.fsyncSync(fd);batch.forEach(x=>x.resolve());}catch(e){batch.forEach(x=>x.reject(e));}flushing=false;if(pending.length){flushing=true;setImmediate(flush);}}
 const commits=new Map();
 const store={
  create:async(id,row)=>{if(commits.has(id)){await commits.get(id);duplicatePrevented++;return false;}const commit=persist(row).then(()=>rows.set(id,{...row}));commits.set(id,commit);await commit;return true;},
  pending:async n=>[...rows.values()].filter(r=>r.state==='pending').slice(0,n),
  claim:async(id,claim)=>{rows.get(id).claim=claim;return true;},
  finish:async(id,claim,v)=>{const old=rows.get(id);if(old.claim!==claim)throw Error('Lease conflict');const row={...old,...v};await persist(row);rows.set(id,row);},
 };
 const q=createAttendanceQueue({store,batchSize:25,deliver:async(school,items)=>items.map(i=>{if(i.schoolId!==school)throw Error('Tenant mismatch');remoteApplied.add(i.operationId);processing.push(performance.now()-start);return {operationId:i.operationId,success:true};})});
 const event=i=>({schoolId:'vs-'+'a'.repeat(32),role:'student',personId:'test-'+i,day:'2026-10-07',mode:'entry',payload:{encrypted:'fixture'}});
 const cpuStart=process.cpuUsage(),rssStart=process.memoryUsage().rss,start=performance.now();let accepted=0,failed=0;
 await Promise.all(Array.from({length:count},async(_,i)=>{const at=performance.now();try{const r=await q.enqueue(event(i));if(r.accepted)accepted++;}catch(_){failed++;}latencies.push(performance.now()-at);}));
 const depth=rows.size;
 await Promise.all(Array.from({length:Math.min(1000,count)},(_,i)=>q.enqueue(event(i))));
 while(q.metrics.completed<count-failed)await q.drain();
 fs.closeSync(fd);
 const recovered=new Map();for(const line of fs.readFileSync(journal,'utf8').trim().split('\n')){const row=JSON.parse(line);recovered.set(row.operationId,row);}
 const completed=[...recovered.values()].filter(r=>r.state==='completed').length;
 const report={scope:'isolated fsync queue component; mocked Drive acknowledgement; NO live API/Firebase/Drive load',concurrentSubmissions:count,accepted,successful:completed,rejected:0,failed,duplicatePrevented,dataLost:accepted-completed,queueDepthAfterAccept:depth,queueDepthAfterDrain:count-completed,ackP50Ms:percentile(latencies,.5),ackP95Ms:percentile(latencies,.95),ackP99Ms:percentile(latencies,.99),processingP95Ms:percentile(processing,.95),totalMs:performance.now()-start,componentSubmissionsPerSecond:count/((performance.now()-start)/1000),cpuUsageMicros:process.cpuUsage(cpuStart),rssStartBytes:rssStart,rssEndBytes:process.memoryUsage().rss,adaptiveBatchSize:q.metrics.batchSize,adaptiveConcurrency:q.metrics.concurrency,retries:q.metrics.retried,authoritativeRejections:q.metrics.rejected,firebaseReads:'not measured: no live Firebase calls',firebaseWrites:'not measured: fsync fixture instead of Firestore'};
 fs.rmSync(dir,{recursive:true});if(report.dataLost||failed||remoteApplied.size!==count)throw Error(JSON.stringify(report));return report;
}
(async()=>{const result=[];for(const n of [1000,5000,10000,15000,25000,50000]){const r=await run(n);result.push(r);console.log(JSON.stringify(r));}const target=process.argv[2];if(target){fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,JSON.stringify(result,null,2));}})().catch(e=>{console.error(e.message);process.exitCode=1;});
