import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash,createHmac} from 'node:crypto';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
const school='vs-'+'a'.repeat(32),foreign='vs-'+'b'.repeat(32);
const key='isolated-native-lifecycle-key-00000001';
const generation=letter=>'p-'+letter.repeat(32);
const student=(id,letter,roll=1)=>({schoolId:school,id,name:'Synthetic student',mobileStableId:generation(letter),studentClass:'Class 1',section:'A',rollNo:roll});

async function setup(t,label,collections){
 const mf=new Miniflare(convertV4MiniflareOptions({workers:[{name:'native-lifecycle-'+label,
  modules:true,scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,
  compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],
  outboundService:()=>new Response('{}',{status:503}),
  durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},
  bindings:{EDGE_KEY:key,LIVE_SYNC_TEST_SCHOOL_ID:school,BROKER_URL:'https://broker.invalid/school-cloud'},
 }]}));
 t.after(()=>mf.dispose());
 async function rpc(body,tenant=school){
  const raw=JSON.stringify({...body,schoolId:tenant,lane:'live'}),time=String(Date.now());
  const response=await mf.dispatchFetch('https://worker.invalid/internal',{method:'POST',
   headers:{'content-type':'application/json','x-vidya-time':time,
    'x-vidya-signature':createHmac('sha256',key).update(time+'\n'+raw).digest('hex')},body:raw});
  return {status:response.status,...await response.json()};
 }
 const fingerprint=createHash('sha256').update('{}').digest('hex');
 for(const collection of collections){
  assert.equal((await rpc({command:'seedBegin',collection,fingerprint,count:0,sourceRevision:'verified-empty-native-baseline'})).status,200,collection+' seed');
  assert.equal((await rpc({command:'seedSeal',collection,fingerprint})).status,200,collection+' seal');
 }
 const commit=async(collection,id,operationId,data,expectedRevision='',operation='write',extra={})=>rpc({command:'commit',collection,id,operationId,data,expectedRevision,operation,...extra});
 const read=async(collection,id)=>{const result=await rpc({command:'read',collection,id});assert.equal(result.status,200);return result.value.record;};
 return {rpc,commit,read};
}
function accepted(result){assert.equal(result.status,200,JSON.stringify(result));assert.equal(result.value.cloudState,'committed');assert.equal(result.value.backupState,'pending');return result.value;}
const dependencyCollections=['students_directory','teachers_directory','fee_payments','documents','attendance_records','exam_results','student_scan_index'];

test('native parent delete atomically tombstones only exact student-owned children before Drive ACK',async t=>{
 const f=await setup(t,'cascade',dependencyCollections);
 const first=accepted(await f.commit('students_directory','student-a','native-parent-create-operation-a',student('student-a','a',1)));
 accepted(await f.commit('students_directory','student-b','native-parent-create-operation-b',student('student-b','b',2)));
 accepted(await f.commit('teachers_directory','teacher-a','native-teacher-create-operation-a',
  {schoolId:school,id:'teacher-a',teacherId:'teacher-a',mobileStableId:generation('a'),name:'Synthetic teacher'}));
 for(const collection of ['fee_payments','documents','attendance_records','exam_results','student_scan_index']){
  accepted(await f.commit(collection,'owned-'+collection,'native-child-create-'+collection,
   {schoolId:school,studentId:'student-a',personId:generation('a'),ownerRole:'student',amount:10,...(collection==='documents'?{fileId:'owned-document-file',documentRevision:'owned-document-version'}:{})}));
 }
 accepted(await f.commit('fee_payments','unrelated-payment','native-unrelated-child-payment',
  {schoolId:school,studentId:'student-b',personId:generation('b'),ownerRole:'student',amount:11}));
 accepted(await f.commit('documents','teacher-document','native-unrelated-teacher-document',
  {schoolId:school,teacherId:'teacher-a',personId:generation('a'),ownerRole:'teacher',fileId:'teacher-document-file'}));
 assert.equal((await f.commit('documents','foreign-document','native-foreign-document-operation',
  {schoolId:foreign,studentId:'student-a',personId:generation('a'),ownerRole:'student'})).status,403);
 const before=(await f.rpc({command:'head'})).value.cursor;
 const deleted=accepted(await f.commit('students_directory','student-a','native-parent-delete-operation-a',undefined,first.recordRevision,'delete',{deleteEverywhereVersion:1}));
 assert.equal(deleted.cursor,before+6,'five child tombstones and parent commit share one atomic transition');
 const events=(await f.rpc({command:'changes',after:before})).value.events;
 assert.equal(events.length,6);assert.equal(events.at(-1).collection,'students_directory');
 for(const event of events){assert.equal(event.record._syncDeleted,true);assert.equal(event.record._syncDeletedOwner,generation('a'));}
 for(const collection of ['fee_payments','documents','attendance_records','exam_results','student_scan_index']){
  assert.equal((await f.read(collection,'owned-'+collection))._syncDeleted,true);
 }
 assert.equal((await f.read('fee_payments','unrelated-payment')).amount,11);
 assert.equal((await f.read('documents','teacher-document'))._syncDeleted,undefined);
 assert.equal((await f.read('students_directory','student-b')).mobileStableId,generation('b'));
 const stats=(await f.rpc({command:'stats'})).value;
 assert.equal(stats.backups.every(row=>row.state==='pending'),true,'no Drive ACK was supplied');
});

test('deleted student generation cannot create late fee, attendance, document or scan children',async t=>{
 const f=await setup(t,'late-child',dependencyCollections);
 const parent=accepted(await f.commit('students_directory','student-a','native-late-parent-add-operation',student('student-a','a')));
 accepted(await f.commit('students_directory','student-a','native-late-parent-delete-operation',undefined,parent.recordRevision,'delete',{deleteEverywhereVersion:1}));
 const before=(await f.rpc({command:'head'})).value.cursor;
 for(const collection of ['fee_payments','attendance_records','documents','student_scan_index']){
  const result=await f.commit(collection,'late-'+collection,'native-late-child-'+collection,
   {schoolId:school,studentId:'student-a',personId:generation('a'),ownerRole:'student',amount:1});
  assert.equal(result.status,409,collection+' must reject retired generation');
 }
 assert.equal((await f.rpc({command:'head'})).value.cursor,before,'failed late writes create no event or backup');
});

test('explicit generation replacement retires old children and prevents old generation resurrection',async t=>{
 const f=await setup(t,'replacement',dependencyCollections);
 const original=accepted(await f.commit('students_directory','slot','native-slot-parent-first-generation',student('slot','a')));
 accepted(await f.commit('fee_payments','old-fee','native-slot-old-fee-operation',
  {schoolId:school,studentId:'slot',personId:generation('a'),ownerRole:'student',amount:10}));
 const before=(await f.rpc({command:'head'})).value.cursor;
 assert.equal((await f.commit('students_directory','slot','native-slot-unapproved-replacement',student('slot','b'),original.recordRevision)).status,409);
 assert.equal((await f.rpc({command:'head'})).value.cursor,before);
 const replacement=accepted(await f.commit('students_directory','slot','native-slot-approved-replacement',
  {...student('slot','b'),replacesStudentGeneration:generation('a')},original.recordRevision));
 assert.deepEqual(replacement.record._syncRetiredStudentGenerations,[generation('a')]);
 assert.equal((await f.read('fee_payments','old-fee'))._syncDeleted,true);
 assert.equal((await f.commit('fee_payments','late-old-fee','native-slot-late-old-fee-operation',
  {schoolId:school,studentId:'slot',personId:generation('a'),ownerRole:'student',amount:99})).status,409);
 accepted(await f.commit('fee_payments','new-fee','native-slot-new-fee-operation',
  {schoolId:school,studentId:'slot',personId:generation('b'),ownerRole:'student',amount:10}));
 assert.equal((await f.commit('students_directory','slot','native-slot-resurrect-retired-parent',
  {...student('slot','a'),replacesStudentGeneration:generation('b')},replacement.recordRevision)).status,409);
});

test('salary correction cannot change historical owner and financial creates never use generic duplicate shortcut',async t=>{
 const f=await setup(t,'financial',['students_directory','teachers_directory','teacher_salary','fee_payments']);
 for(const id of ['teacher-a','teacher-b'])accepted(await f.commit('teachers_directory',id,'native-financial-parent-'+id,
  {schoolId:school,id,teacherId:id,name:id}));
 const salaryData={schoolId:school,teacherId:'teacher-a',personId:'teacher-a',role:'teacher',amount:100};
 const salary=accepted(await f.commit('teacher_salary','salary-event','native-financial-salary-original',salaryData));
 assert.equal((await f.commit('teacher_salary','salary-event','native-financial-salary-reassign',
  {...salaryData,teacherId:'teacher-b',personId:'teacher-b'},salary.recordRevision)).status,409);
 assert.equal((await f.commit('teacher_salary','salary-event','native-financial-salary-duplicate',salaryData,'','write',{createIntent:true})).status,409);
 const pupil=student('student-a','a');accepted(await f.commit('students_directory','student-a','native-financial-student-original',pupil));
 const paymentData={schoolId:school,studentId:'student-a',personId:generation('a'),role:'student',amount:25};
 accepted(await f.commit('fee_payments','payment-event','native-financial-payment-original',paymentData));
 assert.equal((await f.commit('fee_payments','payment-event','native-financial-payment-duplicate',paymentData,'','write',{createIntent:true})).status,409);
 assert.equal((await f.read('teacher_salary','salary-event')).teacherId,'teacher-a');
});

test('Drive backup dependencies order parent add, child add, child delete and parent delete across child retry',async t=>{
 const f=await setup(t,'backup-order',['students_directory','fee_payments','school_expenses']);
 const parent=accepted(await f.commit('students_directory','student-a','native-order-parent-create',student('student-a','a')));
 accepted(await f.commit('fee_payments','fee-a','native-order-child-create',
  {schoolId:school,studentId:'student-a',personId:generation('a'),ownerRole:'student',amount:10}));
 accepted(await f.commit('students_directory','student-a','native-order-parent-delete',undefined,parent.recordRevision,'delete',{deleteEverywhereVersion:1}));
 const parentAdd=(await f.rpc({command:'backupClaim'})).value.job;
 assert.equal(parentAdd.request.collection,'students_directory');assert.equal(parentAdd.request.operation,'write');
 assert.equal((await f.rpc({command:'backupClaim'})).value.job,null,'child cannot reach Drive before parent registration');
 assert.equal((await f.rpc({command:'backupFinish',sequence:parentAdd.seq,claim:parentAdd.claim,verified:true,driveRevision:'drive-parent-first'})).value.accepted,true);
 const childAdd=(await f.rpc({command:'backupClaim'})).value.job;
 assert.equal(childAdd.request.collection,'fee_payments');assert.equal(childAdd.request.operation,'write');
 assert.equal((await f.rpc({command:'backupClaim'})).value.job,null,'neither child deletion nor parent deletion may overtake child write');
 assert.equal((await f.rpc({command:'backupFinish',sequence:childAdd.seq,claim:childAdd.claim,
  verified:false,retryAt:Date.now()+500,review:false})).value.accepted,true);
 accepted(await f.commit('school_expenses','independent','native-order-independent-expense',{schoolId:school,amount:1}));
 const independent=(await f.rpc({command:'backupClaim'})).value.job;
 assert.equal(independent.request.collection,'school_expenses');
 assert.equal((await f.rpc({command:'backupFinish',sequence:independent.seq,claim:independent.claim,verified:true,driveRevision:'drive-independent'})).value.accepted,true);
 assert.equal((await f.rpc({command:'backupClaim'})).value.job,null,'parent deletion remains blocked during child retry delay');
 await new Promise(resolve=>setTimeout(resolve,550));
 const retried=(await f.rpc({command:'backupClaim'})).value.job;
 assert.equal(retried.request.operationId,childAdd.request.operationId);
 assert.equal((await f.rpc({command:'backupFinish',sequence:retried.seq,claim:retried.claim,verified:true,driveRevision:'drive-child-first'})).value.accepted,true);
 const childDelete=(await f.rpc({command:'backupClaim'})).value.job;
 assert.equal(childDelete.request.collection,'fee_payments');assert.equal(childDelete.request.operation,'delete');
 assert.equal(childDelete.request.expectedRecordRevision,'drive-child-first');
 assert.equal((await f.rpc({command:'backupClaim'})).value.job,null,'parent waits for child delete proof');
 assert.equal((await f.rpc({command:'backupFinish',sequence:childDelete.seq,claim:childDelete.claim,verified:true,driveRevision:'drive-child-deleted'})).value.accepted,true);
 const parentDelete=(await f.rpc({command:'backupClaim'})).value.job;
 assert.equal(parentDelete.request.collection,'students_directory');assert.equal(parentDelete.request.operation,'delete');
 assert.equal(parentDelete.request.expectedRecordRevision,'drive-parent-first');
 assert.equal(parentDelete.request.deletedStudentGeneration,generation('a'));
 assert.equal(parentDelete.request.deleteEverywhereVersion,1);
});

test('verified explicit deletion retires older Cloudflare payloads while unrelated pending work survives',async t=>{
 const f=await setup(t,'verified-erase',['school_expenses']);
 const first=accepted(await f.commit('school_expenses','erase-one','native-erase-original-operation',
  {schoolId:school,title:'Private expense payload',amount:12}));
 const firstJob=(await f.rpc({command:'backupClaim'})).value.job;
 assert.equal((await f.rpc({command:'backupFinish',sequence:firstJob.seq,claim:firstJob.claim,
  verified:true,driveRevision:'verified-drive-original'})).value.accepted,true);
 const deletion=accepted(await f.commit('school_expenses','erase-one','native-erase-delete-operation',
  undefined,first.recordRevision,'delete',{deleteEverywhereVersion:1}));
 accepted(await f.commit('school_expenses','other-pending','native-erase-unrelated-pending',
  {schoolId:school,title:'Must survive',amount:13}));
 const job=(await f.rpc({command:'backupClaim'})).value.job;
 assert.equal(job.request.operationId,deletion.operationId);
 assert.equal(job.request.deleteEverywhereVersion,1);
 // Prior payload is retained until the trusted delivery owner proves deletion.
 assert.equal((await f.rpc({command:'operationReceipt',operationId:first.operationId})).value.receipt.record.title,'Private expense payload');
 assert.equal((await f.rpc({command:'backupFinish',sequence:job.seq,claim:job.claim,
  verified:true,driveRevision:'verified-drive-deletion'})).value.accepted,true);
 const erased=(await f.rpc({command:'operationReceipt',operationId:first.operationId})).value.receipt;
 assert.equal(erased.record,null);assert.equal(erased.source,'drive');
 assert.equal((await f.read('school_expenses','other-pending')).title,'Must survive');
 assert.equal((await f.read('school_expenses','erase-one'))._syncDeleted,true);
});
