import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {createHmac} from 'node:crypto';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
const school='vs-'+'a'.repeat(32),key='live-lifecycle-admission-test-key-00000001';
const mf=new Miniflare(convertV4MiniflareOptions({workers:[{name:'live-lifecycle-admission',modules:true,scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],outboundService:()=>new Response('{}',{status:503}),durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},bindings:{EDGE_KEY:key,LIVE_SYNC_TEST_SCHOOL_ID:school,BROKER_URL:'https://broker.invalid/school-cloud'}}]}));
after(()=>mf.dispose());
async function rpc(body){
 const raw=JSON.stringify({...body,schoolId:school,lane:'live'}),time=String(Date.now());
 const response=await mf.dispatchFetch('https://worker.invalid/internal',{method:'POST',headers:{'content-type':'application/json','x-vidya-time':time,'x-vidya-signature':createHmac('sha256',key).update(time+'\n'+raw).digest('hex')},body:raw});
 return {status:response.status,body:await response.json()};
}
// These collections have cross-record, person, financial or binary semantics.
// An authenticated broker request must not accidentally opt them into generic
// per-record CAS by changing an allowlist on only one side of the protocol.
test('unsupported lifecycle collections remain closed even to signed broker commands',async()=>{
 for(const collection of ['students_directory','teachers_directory','teacher_salary','teacher_schedules','fee_settings','fee_ledger','fee_payments','attendance_logs','teacher_attendance','attendance_records','student_scan_index','scanner_devices','documents','backups','school_config','exam_results','exams','exam_center_results']){
  for(const command of [
   {command:'seedBegin',fingerprint:'a'.repeat(64),count:0,sourceRevision:'drive-source'},
   {command:'read',id:'one'},
   {command:'commit',id:'one',operation:'write',operationId:'rejected-lifecycle-write-0001',expectedRevision:'',data:{schoolId:school}},
   {command:'snapshot',at:0},
  ]){
   const response=await rpc({...command,collection});
   assert.equal(response.status,412,collection+' '+command.command);
  }
 }
 const head=await rpc({command:'head'});assert.equal(head.status,200);
 assert.equal(head.body.value.cursor,0);assert.deepEqual(head.body.value.collections,[]);
 const stats=await rpc({command:'stats'});assert.deepEqual(stats.body.value.backups,[]);
 assert.deepEqual(stats.body.value.payloadCopies,{records:0,events:0,backups:0,operations:0});
});
