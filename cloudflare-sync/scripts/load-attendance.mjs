// Local workerd/SQLite stress test only. No production API or school is contacted.
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {createHash,createHmac} from 'node:crypto';
import {writeFile,mkdir} from 'node:fs/promises';
const count=Number(process.env.ATTENDANCE_LOAD_RECORDS||100000),concurrency=Number(process.env.ATTENDANCE_LOAD_CONCURRENCY||256);
if(!Number.isInteger(count)||count<1||count>100000||!Number.isInteger(concurrency)||concurrency<1||concurrency>512)throw Error('Invalid synthetic load size');
const key='local-load-test-only-not-production-0000',school='vs-'+'f'.repeat(31)+'1';
const mf=new Miniflare(convertV4MiniflareOptions({name:'synthetic-load',modules:true,scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],outboundService:async()=>new Response('{}',{status:503}),durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},bindings:{EDGE_KEY:key,BROKER_URL:'https://broker.invalid/school-cloud'}}));
const sha=s=>createHash('sha256').update(s).digest('hex');
const started=performance.now(),day=new Date(Date.now()+19800000).toISOString().slice(0,10),times=[];let next=0,accepted=0,failed=0;
try{
 await mf.ready;
 await Promise.all(Array.from({length:concurrency},async()=>{
  while(next<count){const index=next++,person='synthetic-'+index;
   const claims={schoolId:school,sessionHash:sha('synthetic-session'),expiresAt:Date.now()+900000,role:'student',personId:person,documentId:person,qrHash:sha('student/'+person+'/synthetic-qr'),day,open:true,latitude:26,longitude:92,radiusMeters:100};
   const value=Buffer.from(JSON.stringify(claims)).toString('base64url'),grant=value+'.'+createHmac('sha256',key).update(value).digest('hex');
   const before=performance.now();
   const reply=await mf.dispatchFetch('https://local.invalid/mobile',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({schoolId:school,grant,request:{action:'mobile_mark_attendance',role:'student',personId:person,linkToken:'synthetic-qr',sessionToken:'synthetic-session',latitude:26,longitude:92,accuracy:5,clientCapturedAt:Date.now()}})});
   const result=await reply.json();times.push(performance.now()-before);if(reply.status===200&&result.accepted===true&&result.driveState==='pending')accepted++;else failed++;
   if((accepted+failed)%10000===0)process.stdout.write(JSON.stringify({processed:accepted+failed,accepted,failed})+'\n');
  }
 }));
 times.sort((a,b)=>a-b);const elapsedMs=performance.now()-started;
 const report={scope:'local workerd only; not a live Cloudflare capacity guarantee',count,concurrency,accepted,failed,elapsedMs,requestsPerSecond:count/(elapsedMs/1000),p50Ms:times[Math.floor(times.length*.5)],p95Ms:times[Math.floor(times.length*.95)],p99Ms:times[Math.floor(times.length*.99)],driveDelivery:'not benchmarked; broker.invalid is deliberately unreachable',generatedAt:new Date().toISOString()};
 await mkdir('build',{recursive:true});await writeFile('build/attendance-load-report.json',JSON.stringify(report,null,2));process.stdout.write(JSON.stringify(report)+'\n');if(failed)process.exitCode=1;
}finally{await mf.dispose();}
