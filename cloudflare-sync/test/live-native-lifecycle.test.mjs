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

test('hourly live backup summary separates accepted work and verified original Drive receipts',async t=>{
 const f=await setup(t,'hourly-backup-proof',['school_expenses']);
 const first=accepted(await f.commit('school_expenses','a','hourly-first-original-operation',
  {schoolId:school,title:'Synthetic A',amount:1}));
 accepted(await f.commit('school_expenses','b','hourly-second-original-operation',
  {schoolId:school,title:'Synthetic B',amount:2}));
 const before=(await f.rpc({command:'backupHourly'}));
 assert.equal(before.status,200);
 assert.equal(before.value.schoolId,school);
 assert.equal(before.value.backupHourlyVersion,1);
 assert.equal(before.value.coverage,'live_native_backup_only');
 assert.equal(before.value.windowHours,24);
 assert.equal(before.value.verified.length,0,'Cloudflare acceptance is not Google verification');
 assert.equal(before.value.accepted.reduce((n,row)=>n+row.count,0),2);
 assert.deepEqual(before.value.current.map(r=>[r.collection,r.state,r.count]),
   [['school_expenses','pending',2]]);
 const job=(await f.rpc({command:'backupClaim'})).value.job;
 assert.equal(job.request.operationId,first.operationId);
 const completed=await f.rpc({command:'backupFinish',sequence:job.seq,claim:job.claim,
  verified:true,driveRevision:'synthetic-original-signed-drive-revision'});
 assert.equal(completed.status,200);
 assert.equal(completed.value.accepted,true);
 const after=(await f.rpc({command:'backupHourly'}));
 assert.equal(after.status,200);
 assert.equal(after.value.verified.reduce((n,row)=>n+row.count,0),1);
 assert.deepEqual(after.value.current.map(r=>[r.collection,r.state,r.count]),
   [['school_expenses','pending',1],['school_expenses','verified',1]]);
 assert.equal(after.value.unknown.unverifiedCompletion,0);
 assert.equal(after.value.unknown.missingAcceptedAt,0);
});

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

test('isolated UID authority binds reservations to the current person and queues one immutable backup projection',async t=>{
 const f=await setup(t,'uid-reservation',['school_config','students_directory','teachers_directory']);
 const before=await f.rpc({command:'uidStatus'});
 assert.equal(before.value.state,'migration_required');
 const profile=accepted(await f.commit('school_config','school_profile_cache','uid-test-profile-operation',
  {schoolId:school,schoolName:'Sunshine Public School',syntheticTest:true}));
 const init=await f.rpc({command:'uidSeedTest',profileRecord:profile.record});
 assert.equal(init.status,200,JSON.stringify(init));
 assert.deepEqual(init.value.counters,{STU:1,TCH:1,STF:1});
 assert.equal((await f.rpc({command:'uidSeedTest',profileRecord:profile.record})).status,409);
 const pupil=accepted(await f.commit('students_directory','uid-student','uid-student-original-operation',
  {...student('uid-student','a',7),name:'Rahul Sharma'}));
 const teacher=accepted(await f.commit('teachers_directory','uid-teacher','uid-teacher-original-operation',
  {schoolId:school,id:'uid-teacher',teacherId:'T-independent',mobileStableId:generation('b'),name:'Amit Kumar'}));
 const req={command:'uidReservePerson',collection:'students_directory',id:'uid-student',generation:generation('a'),record:pupil.record};
 assert.equal((await f.rpc({...req,record:{...pupil.record,name:'Forged'}})).status,409);
 assert.equal((await f.rpc({...req,generation:generation('b')})).status,409);
 assert.equal((await f.rpc(req,foreign)).status,412);
 const replies=await Promise.all([f.rpc(req),f.rpc(req),f.rpc(req)]);
 for(const r of replies){
  assert.equal(r.status,200,JSON.stringify(r));
  assert.equal(r.value.universalUid,'STU-SUNS-RAHU-000001');
  assert.equal(r.value.backupState,'pending');
 }
 assert.ok(replies.filter(r=>r.value.created).length<=1);
 const tUid=await f.rpc({command:'uidReservePerson',collection:'teachers_directory',id:'uid-teacher',generation:generation('b'),record:teacher.record});
 assert.equal(tUid.status,200,JSON.stringify(tUid));
 assert.equal(tUid.value.universalUid,'TCH-SUNS-AMIT-000001');
 const projection=await f.read('school_config',replies[0].value.reservationId);
 assert.equal(projection.universalUid,'STU-SUNS-RAHU-000001');
 assert.equal(projection.nextNumber,2);
 assert.equal((await f.read('students_directory','uid-student')).universalUid,undefined);
 assert.equal((await f.commit('school_config',replies[0].value.reservationId,'forged-uid-projection-operation',
  {schoolId:school,universalUid:'fake'},projection._syncRevision)).status,403);
 const renamed=accepted(await f.commit('students_directory','uid-student','uid-student-rename-operation',
  {...student('uid-student','a',7),name:'New Name'},pupil.recordRevision));
 assert.equal((await f.rpc(req)).status,409);
 const same=await f.rpc({...req,record:renamed.record});
 assert.equal(same.value.universalUid,'STU-SUNS-RAHU-000001');
 assert.equal(same.value.created,false);
 const counts=(await f.rpc({command:'uidStatus'})).value;
 assert.deepEqual(counts.counters,{STU:2,TCH:2,STF:1});
 assert.equal(counts.assignments,2);
});

test('office and other staff share the permanent UID sequence while keeping distinct owners',async t=>{
 const f=await setup(t,'staff-uid-reservation',['school_config','students_directory','teachers_directory']);
 const profile=accepted(await f.commit('school_config','school_profile_cache','staff-uid-profile-operation',
  {schoolId:school,schoolName:'Sunshine Public School',syntheticTest:true}));
 assert.equal((await f.rpc({command:'uidSeedTest',profileRecord:profile.record})).status,200);
 const office={id:'office-staff',mobileStableId:generation('c'),name:'Neha Kumari',role:'Office staff'};
 const other={id:'other-staff',mobileStableId:generation('d'),name:'Ravi Das',role:'Other staff'};
 const reserve=(record)=>f.rpc({command:'uidReservePerson',collection:'staff_payroll_directory',
  id:record.id,generation:record.mobileStableId,record});
 const first=await reserve(office);
 assert.equal(first.status,200,JSON.stringify(first));
 assert.equal(first.value.universalUid,'STF-SUNS-NEHA-000001');
 const second=await reserve(other);
 assert.equal(second.status,200,JSON.stringify(second));
 assert.equal(second.value.universalUid,'STF-SUNS-RAVI-000002');
 const replay=await reserve({...office,name:'Renamed Staff',role:'Other staff'});
 assert.equal(replay.value.universalUid,first.value.universalUid);
 assert.equal(replay.value.created,false);
 assert.equal((await reserve({...office,id:'different-staff'})).status,409);
 assert.equal((await reserve({...other,active:false})).status,412);
});

test('concurrent teacher mobile claims conflict and edits preserve identity',async t=>{
 const f=await setup(t,'teacher-phone',['teachers_directory']);
 const collection='teachers_directory';
 const first={schoolId:school,id:'phone-a',teacherId:'teacher-phone-a',phone:'9876543210'};
 const second={schoolId:school,id:'phone-b',teacherId:'teacher-phone-b',phone:'+91 98765 43210'};
 const results=await Promise.all([
  f.commit(collection,first.id,'teacher-phone-create-first',first),
  f.commit(collection,second.id,'teacher-phone-create-second',second),
 ]);
 assert.deepEqual(results.map(result=>result.status).sort(),[200,409]);
 const winner=results[0].status===200?first:second;
 const loser=winner===first?second:first;
 const committed=results.find(result=>result.status===200).value;
 const edited=accepted(await f.commit(collection,winner.id,'teacher-phone-edit-winner',
  {...winner,phone:'9876543211'},committed.recordRevision));
 assert.equal(edited.record.teacherId,winner.teacherId);
 accepted(await f.commit(collection,loser.id,'teacher-phone-create-after-edit',loser));
});

test('teacher phone backfill accepts current school proof and rejects changed records',async t=>{
 const f=await setup(t,'teacher-phone-backfill',['teachers_directory']);
 const collection='teachers_directory',id='legacy-teacher';
 const saved=accepted(await f.commit(collection,id,'teacher-backfill-create-proof',
  {schoolId:school,id,teacherId:'legacy-proof-id',phone:'9876543210'}));
 const pending=await f.rpc({command:'teacherPhoneBackfillList',collection});
 assert.equal(pending.status,200);
 assert.deepEqual(pending.value.ids,[]);
 const proof={command:'teacherPhoneBackfillApply',collection,id,expectedRevision:saved.recordRevision};
 assert.equal((await f.rpc({...proof,record:{...saved.record,phone:'9876543211'}})).status,409);
 assert.equal((await f.rpc({...proof,record:saved.record})).value.indexed,true);
 const changed=accepted(await f.commit(collection,id,'teacher-backfill-change-proof',
  {schoolId:school,id,teacherId:'legacy-proof-id',phone:'9876543211'},saved.recordRevision));
 assert.equal(changed.record.teacherId,'legacy-proof-id');
 assert.equal((await f.rpc({...proof,record:saved.record})).status,409);
});

test('isolated UID allocation is queued with person commits and drains idempotently',async t=>{
 const f=await setup(t,'uid-auto-queue',['school_config','students_directory','teachers_directory']);
 const profile=accepted(await f.commit('school_config','school_profile_cache','uid-auto-profile-operation',
  {schoolId:school,schoolName:'Sunshine Public School',syntheticTest:true}));
 assert.equal((await f.rpc({command:'uidSeedTest',profileRecord:profile.record})).status,200);

 const person={...student('uid-auto-person','c',9),name:'Asha Sen'};
 const ack=accepted(await f.commit('students_directory','uid-auto-person','uid-auto-person-create-operation',person));
 assert.equal(ack.record.universalUid,undefined);
 assert.equal((await f.rpc({command:'uidDrain'})).status,200);
 const projection=await f.read('school_config','universal_uid_v1_'+generation('c'));
 assert.equal(projection.universalUid,'STU-SUNS-ASHA-000001');
 const replay=accepted(await f.commit('students_directory','uid-auto-person','uid-auto-person-create-operation',person));
 assert.equal(replay.recordRevision,ack.recordRevision);
 assert.equal((await f.rpc({command:'uidDrain'})).value.nextUidDue,null);
 assert.equal((await f.rpc({command:'uidStatus'})).value.assignments,1);
});
