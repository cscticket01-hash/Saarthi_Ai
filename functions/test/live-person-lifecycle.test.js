'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createLivePersonLifecycle}=require('../live-person-lifecycle');
const {fixture}=require('./helpers/managed-school-broker');
const {storage,A}=require('./helpers/managed-storage');
const G='p-'+'1'.repeat(64),N='p-'+'2'.repeat(64),S='Class 1_Roll_1';
function setup(){
 const f=fixture(),s=storage({lifecycle:true,bundle:true});let calls=0,lose=false;
 const rpc=async(school,body)=>{assert.equal(school,A);const reply=s.call(body);if(body.operation!=='read'){calls++;if(lose){lose=false;throw Error('lost ACK');}}return reply;};
 const gate=()=>createLivePersonLifecycle({db:f.db,rpc});
 return {f,s,rpc,gate,get calls(){return calls;},lose(){lose=true;}};
}
const write=(collection,id,data,base='',operationId='domain-create-operation-0001')=>({action:'managed_records',collection,id,operation:'write',syncProtocol:2,operationId,expectedRecordRevision:base,data:{schoolId:A,...data}});
const create=()=>write('students_directory',S,{name:'Synthetic domain pupil',class:'Class 1',rollNo:'1',mobileStableId:G});
test('durable student operation resumes lost GS ACK without duplicate write or record payload journal',async()=>{
 const f=setup();f.lose();await assert.rejects(f.gate().execute(A,create()),/lost ACK/);
 const pending=[...f.f.docs.entries()].find(([key])=>key.startsWith('school_person_lifecycle_operations/'))[1];
 assert.equal(pending.state,'planned');assert.equal(JSON.stringify(pending).includes('Synthetic domain pupil'),false);assert.equal(f.calls,1);
 const ack=await f.gate().execute(A,create());assert.equal(ack.record.mobileStableId,G);assert.equal(f.calls,1);
 assert.equal((await f.gate().execute(A,create())).recordRevision,ack.recordRevision);
 await assert.rejects(f.gate().execute(A,{...create(),data:{...create().data,name:'Changed'}}),e=>e.code==='OPERATION_ID_CONFLICT');
});
test('student delete verifies generation cascade and preserves unrelated child before releasing parent fence',async()=>{
 const f=setup(),a=await f.gate().execute(A,create());
 assert.equal(f.s.call(write('fee_payments','owned',{studentId:S,personId:G,amount:100},'','child-owned-operation-0001')).success,true);
 assert.equal(f.s.call(write('fee_payments','other',{studentId:'other',personId:N,amount:200},'','child-other-operation-0001')).success,true);
 const request={action:'managed_records',collection:'students_directory',id:S,operation:'delete',syncProtocol:2,operationId:'domain-delete-operation-0001',expectedRecordRevision:a.recordRevision,deletedStudentGeneration:G};
 const deleted=await f.gate().execute(A,request);assert.equal(deleted.record._syncDeletedOwner,G);
 const rows=f.s.call({action:'managed_records',collection:'fee_payments',operation:'read',syncProtocol:2}).records;
 assert.equal(rows.owned._syncDeleted,true);assert.equal(rows.other.amount,200);
 await assert.rejects(f.gate().assertDependency(A,S,G),e=>e.code==='PERSON_GENERATION_RETIRED');
 const next=await f.gate().execute(A,write('students_directory',S,{name:'Next pupil',class:'Class 1',rollNo:'1',mobileStableId:N,replacesStudentGeneration:G},deleted.recordRevision,'domain-recreate-operation-0001'));
 assert.equal(next.record.mobileStableId,N);await f.gate().assertDependency(A,S,N);
});
test('cascade proof failure retains durable person fence and never returns a successful deletion',async()=>{
 const f=setup(),a=await f.gate().execute(A,create());
 assert.equal(f.s.call(write('fee_payments','owned',{studentId:S,personId:G,amount:100},'','child-owned-operation-0001')).success,true);
 let after=false;
 const gate=createLivePersonLifecycle({db:f.f.db,rpc:async(school,body)=>{const reply=await f.rpc(school,body);if(body.operation==='delete')after=true;if(after&&body.collection==='fee_payments'&&body.operation==='read'&&body.id==='owned')reply.records.owned={schoolId:A,_syncRevision:'unverified-other',personId:N};return reply;}});
 await assert.rejects(gate.execute(A,{action:'managed_records',collection:'students_directory',id:S,operation:'delete',syncProtocol:2,operationId:'domain-delete-proof-0001',expectedRecordRevision:a.recordRevision,deletedStudentGeneration:G}),e=>e.code==='PERSON_CASCADE_UNVERIFIED');
 await assert.rejects(gate.assertDependency(A,S,G),e=>e.code==='PERSON_LIFECYCLE_IN_FLIGHT');
});
test('teacher identity changes remain blocked and retirement is generation-bound',async()=>{
 const f=setup(),a=await f.gate().execute(A,write('teachers_directory','teacher-1',{name:'Teacher',teacherId:'T1'}));
 await assert.rejects(f.gate().execute(A,write('teachers_directory','teacher-1',{name:'Teacher',teacherId:'T2'},a.recordRevision,'teacher-reassign-operation-0001')),e=>e.code==='TEACHER_IDENTITY_REPLACEMENT_REQUIRES_REVIEW');
 const retired=await f.gate().execute(A,{action:'managed_records',collection:'teachers_directory',id:'teacher-1',operation:'delete',syncProtocol:2,operationId:'teacher-retire-operation-0001',expectedRecordRevision:a.recordRevision});assert.equal(retired.record._syncDeletedOwner,'teacher-1');
});
test('embedded staff directory checks teacher employee uniqueness and preserves staff identity',async()=>{
 const f=setup();await f.gate().execute(A,write('teachers_directory','teacher-1',{name:'Teacher',teacherId:'T1'}));
 const staff=entries=>write('school_settings','staff_payroll_directory',{staff:entries},'','staff-create-operation-0001');
 await assert.rejects(f.gate().execute(A,staff([{id:'staff:1',name:'Staff',employeeId:'t1'}])),e=>e.code==='STAFF_EMPLOYEE_ID_CONFLICT');
 const a=await f.gate().execute(A,staff([{id:'staff:1',name:'Staff',employeeId:'E1'}]));
 await assert.rejects(f.gate().execute(A,{...staff([]),operationId:'staff-remove-operation-0001',expectedRecordRevision:a.recordRevision}),e=>e.code==='STAFF_IDENTITY_RETIREMENT_REQUIRES_REVIEW');
});
test('uncertain parent mutation fences child delivery and foreign readback never creates journal admission',async()=>{
 const f=setup();f.lose();await assert.rejects(f.gate().execute(A,create()),/lost ACK/);
 await assert.rejects(f.gate().assertDependency(A,S,G),e=>e.code==='PERSON_LIFECYCLE_IN_FLIGHT');
 const other=setup(),gate=createLivePersonLifecycle({db:other.f.db,rpc:async(school,body)=>({...await other.rpc(school,body),schoolId:'vs-'+'b'.repeat(32)})});
 await assert.rejects(gate.execute(A,create()),e=>e.code==='PERSON_READ_UNVERIFIED');
 assert.equal([...other.f.docs.keys()].some(k=>k.startsWith('school_person_lifecycle_')),false);
});
test('person generation cannot be removed by patch and another operation cannot cross an unresolved parent fence',async()=>{
 const f=setup(),a=await f.gate().execute(A,create());
 const patch=write('students_directory',S,{_syncFieldPatch:{version:1,set:{},remove:['mobileStableId'],before:{}}},a.recordRevision,'domain-generation-patch-0001');
 await assert.rejects(f.gate().execute(A,patch),e=>e.code==='PERSON_GENERATION_PATCH_REJECTED');
 f.lose();
 const update=write('students_directory',S,{name:'Updated pupil',class:'Class 1',rollNo:'1',mobileStableId:G},a.recordRevision,'domain-update-operation-0001');
 await assert.rejects(f.gate().execute(A,update),/lost ACK/);
 const current=f.s.call({action:'managed_records',collection:'students_directory',operation:'read',id:S,syncProtocol:2}).records[S];
 await assert.rejects(f.gate().execute(A,write('students_directory',S,{name:'Another update',class:'Class 1',rollNo:'1',mobileStableId:G},current._syncRevision,'domain-another-operation-0001')),e=>e.code==='PERSON_LIFECYCLE_IN_FLIGHT');
 await f.gate().execute(A,update);
});
test('old deployed GS cannot perform teacher retirement and admission remains untouched',async()=>{
 const f=setup(),a=await f.gate().execute(A,write('teachers_directory','teacher-1',{name:'Teacher',teacherId:'T1'}));
 const before=f.calls,gate=createLivePersonLifecycle({db:f.f.db,rpc:async(school,body)=>{
  const reply=await f.rpc(school,body);if(body.action==='managed_health')delete reply.teacherRetirementVersion;return reply;
 }});
 await assert.rejects(gate.execute(A,{action:'managed_records',collection:'teachers_directory',id:'teacher-1',operation:'delete',syncProtocol:2,operationId:'teacher-old-script-operation-0001',expectedRecordRevision:a.recordRevision}),e=>e.code==='PERSON_RETIREMENT_UPGRADE_REQUIRED');
 const current=f.s.call({action:'managed_records',collection:'teachers_directory',id:'teacher-1',operation:'read',syncProtocol:2}).records['teacher-1'];assert.equal(current._syncDeleted,undefined);
 assert.equal([...f.f.docs.values()].some(row=>row.operationId==='teacher-old-script-operation-0001'),false);
});
test('staff field patch preserves GS field intent while validating the resulting embedded directory',async()=>{
 const f=setup(),row={id:'staff:1',name:'Staff',employeeId:'E1',active:true};
 const a=await f.gate().execute(A,write('school_settings','staff_payroll_directory',{staff:[row]},'','staff-patch-create-operation-0001'));
 const proof={exists:true,revision:a.record._syncFieldRevisions.staff};
 const patch=write('school_settings','staff_payroll_directory',{_syncFieldPatch:{version:1,set:{staff:[{...row,active:false}]},remove:[],before:{staff:proof}}},a.recordRevision,'staff-retire-patch-operation-0001');
 const ack=await f.gate().execute(A,patch);assert.equal(ack.record.staff[0].active,false);assert.equal(ack.record.staff[0].employeeId,'E1');
 const invalid=write('school_settings','staff_payroll_directory',{_syncFieldPatch:{version:1,set:{staff:[]},remove:[],before:{staff:{exists:true,revision:ack.record._syncFieldRevisions.staff}}}},ack.recordRevision,'staff-remove-patch-operation-0001');
 await assert.rejects(f.gate().execute(A,invalid),e=>e.code==='STAFF_IDENTITY_RETIREMENT_REQUIRES_REVIEW');
});
test('teacher inactive field patch requires deployed retirement capability before durable admission',async()=>{
 const f=setup(),a=await f.gate().execute(A,write('teachers_directory','teacher-1',{name:'Teacher',teacherId:'T1',mobileStableId:G}));
 assert.equal(f.s.call(write('documents','field-card',{teacherId:'T1',personId:G,ownerRole:'teacher',documentRevision:'field-card-v1'},'','teacher-field-card-operation-0001')).success,true);
 const patch=write('teachers_directory','teacher-1',{_syncFieldPatch:{version:1,set:{active:false},remove:[],before:{active:{exists:false,revision:'absent'}},identity:{teacherId:'T1',mobileStableId:G}}},a.recordRevision,'teacher-retire-fieldpatch-0001');
 const old=createLivePersonLifecycle({db:f.f.db,rpc:async(school,body)=>{const reply=await f.rpc(school,body);if(body.action==='managed_health')delete reply.teacherRetirementVersion;return reply;}});
 await assert.rejects(old.execute(A,patch),e=>e.code==='PERSON_RETIREMENT_UPGRADE_REQUIRED');
 assert.equal([...f.f.docs.values()].some(row=>row.operationId===patch.operationId),false);
 assert.equal(f.s.call({action:'managed_records',collection:'teachers_directory',operation:'read',id:'teacher-1',syncProtocol:2}).records['teacher-1'].active,undefined);
 const done=await f.gate().execute(A,patch);assert.equal(done.record.active,false);
 const journal=[...f.f.docs.entries()].find(([path,row])=>path.startsWith('school_person_lifecycle_operations/')&&row.operationId===patch.operationId)[1];
 assert.equal(journal.retiredGeneration,G);assert.equal(journal.state,'verified');assert.equal(journal.children.some(row=>row.collection==='documents'&&row.id==='field-card'),true);
 assert.equal(f.s.call({action:'managed_records',collection:'documents',operation:'read',id:'field-card',syncProtocol:2}).records['field-card']._syncDeleted,true);
});
test('existing addStaff shape uses stable staff ID without imposing an employee field and permits explicit first enrollment',async()=>{
 const f=setup(),row={id:'staff:legacy-1',name:'Existing staff',role:'Driver',designation:'Driver'};
 const a=await f.gate().execute(A,write('school_settings','staff_payroll_directory',{staff:[row]},'','legacy-staff-create-0001'));assert.equal(a.record.staff[0].employeeId,undefined);
 const retired=await f.gate().execute(A,write('school_settings','staff_payroll_directory',{staff:[{...row,active:false}]},a.recordRevision,'legacy-staff-retire-0001'));assert.equal(retired.record.staff[0].active,false);
 const enrolled=await f.gate().execute(A,write('school_settings','staff_payroll_directory',{staff:[{...row,active:true,employeeId:'E1'}]},retired.recordRevision,'legacy-staff-enroll-0001'));assert.equal(enrolled.record.staff[0].employeeId,'E1');
 await assert.rejects(f.gate().execute(A,write('school_settings','staff_payroll_directory',{staff:[{...row,employeeId:'E2'}]},enrolled.recordRevision,'legacy-staff-reassign-0001')),e=>e.code==='STAFF_IDENTITY_RETIREMENT_REQUIRES_REVIEW');
});

function everywhereFixture(f,{alter,loseOnce=false}={}){
 let deletes=0,lost=false;
 const gate=createLivePersonLifecycle({db:f.f.db,rpc:async(school,body)=>{
  const reply=await f.rpc(school,{...body,deleteEverywhereVersion:undefined});
  if(body.operation!=='delete')return reply;
  deletes++;
  const record=f.s.call({action:'managed_records',collection:body.collection,id:body.id,operation:'read',syncProtocol:2}).records[body.id];
  const targets=[{collection:body.collection,id:body.id,revision:record._syncRevision,generation:record._syncDeletedOwner}];
  const receipt={...reply,deleteEverywhereVersion:1,driveDeletionComplete:true,firebaseDeletionComplete:true,
   deletionTargets:targets,deletedFileIds:[],record:{...record,_syncErasePlan:{complete:true,targets}}};
  if(loseOnce&&!lost){lost=true;throw Error('lost final delete receipt');}
  return alter?alter(receipt):receipt;
 }});
 return {gate,get deletes(){return deletes;}};
}
function everywhereDelete(base){
 return {action:'managed_records',collection:'students_directory',id:S,operation:'delete',syncProtocol:2,
  operationId:'everywhere-delete-operation-0001',expectedRecordRevision:base,deletedStudentGeneration:G,deleteEverywhereVersion:1};
}
test('native lifecycle forwards the actual verified final deletion receipt without journaling payloads',async()=>{
 const f=setup(),created=await f.gate().execute(A,create()),fixture=everywhereFixture(f);
 const ack=await fixture.gate.execute(A,everywhereDelete(created.recordRevision));
 assert.equal(ack.deleteEverywhereVersion,1);assert.equal(ack.driveDeletionComplete,true);assert.equal(ack.firebaseDeletionComplete,true);
 assert.equal(ack.deletionTargets[0].id,S);assert.equal(ack.record._syncDeletedOwner,G);
 const journal=[...f.f.docs.entries()].find(([path,row])=>path.startsWith('school_person_lifecycle_operations/')&&row.operationId===ack.operationId)[1];
 assert.equal(journal.state,'verified');assert.equal(Object.hasOwn(journal,'record'),false);assert.equal(Object.hasOwn(journal,'deletionTargets'),false);
});
test('lost final deletion response rechecks the original provider receipt before releasing the fence',async()=>{
 const f=setup(),created=await f.gate().execute(A,create()),fixture=everywhereFixture(f,{loseOnce:true}),request=everywhereDelete(created.recordRevision);
 await assert.rejects(fixture.gate.execute(A,request),/lost final delete receipt/);
 const ack=await fixture.gate.execute(A,request);
 assert.equal(fixture.deletes,2);assert.equal(ack.firebaseDeletionComplete,true);assert.equal(ack.record._syncDeleted,true);
});
test('verified deletion replay retrieves original completion proof instead of fabricating flags from the journal',async()=>{
 const f=setup(),created=await f.gate().execute(A,create()),fixture=everywhereFixture(f),request=everywhereDelete(created.recordRevision);
 const first=await fixture.gate.execute(A,request),again=await fixture.gate.execute(A,request);
 assert.equal(fixture.deletes,2);assert.equal(again.recordRevision,first.recordRevision);assert.equal(again.firebaseDeletionComplete,true);
 assert.deepEqual(again.deletionTargets,first.deletionTargets);
});
test('missing or mismatched final deletion proof retains the original lifecycle fence',async()=>{
 for(const alter of [r=>({...r,driveDeletionComplete:false}),r=>({...r,firebaseDeletionComplete:false}),
  r=>({...r,deletionTargets:[]}),r=>({...r,record:{...r.record,_syncOperationId:'another-delete-operation-0001'}}),
  r=>({...r,record:{...r.record,_syncErasePlan:{complete:true,targets:[]}}})]){
  const f=setup(),created=await f.gate().execute(A,create()),fixture=everywhereFixture(f,{alter});
  await assert.rejects(fixture.gate.execute(A,everywhereDelete(created.recordRevision)),e=>{assert.equal(e.code,'PERSON_DELETE_RECEIPT_UNVERIFIED',String(alter));return true;});
  await assert.rejects(fixture.gate.assertDependency(A,S,G),e=>e.code==='PERSON_LIFECYCLE_IN_FLIGHT');
 }
});
test('an old verified deletion never replays against a replacement person generation',async()=>{
 const f=setup(),created=await f.gate().execute(A,create()),fixture=everywhereFixture(f),request=everywhereDelete(created.recordRevision);
 const removed=await fixture.gate.execute(A,request);
 await f.gate().execute(A,write('students_directory',S,{name:'Replacement',class:'Class 1',rollNo:'1',mobileStableId:N,replacesStudentGeneration:G},removed.recordRevision,'everywhere-replacement-operation-0001'));
 const old=await fixture.gate.execute(A,request);
 assert.equal(fixture.deletes,1);assert.equal(old.reconcileRequired,true);assert.equal(old.record,null);assert.equal(old.firebaseDeletionComplete,undefined);
 assert.equal(f.s.call({action:'managed_records',collection:'students_directory',id:S,operation:'read',syncProtocol:2}).records[S].mobileStableId,N);
});

test('teacher Delete Everywhere also forwards the verified generation-bound final receipt',async()=>{
 const f=setup(),id='teacher-everywhere-1';
 const created=await f.gate().execute(A,write('teachers_directory',id,{name:'Synthetic teacher',teacherId:'T1',mobileStableId:G}));
 const fixture=everywhereFixture(f),request={action:'managed_records',collection:'teachers_directory',id,operation:'delete',syncProtocol:2,
  operationId:'teacher-everywhere-delete-0001',expectedRecordRevision:created.recordRevision,deletedTeacherGeneration:G,deleteEverywhereVersion:1};
 const ack=await fixture.gate.execute(A,request);
 assert.equal(ack.firebaseDeletionComplete,true);assert.equal(ack.driveDeletionComplete,true);assert.equal(ack.record._syncDeletedOwner,G);
 assert.equal(ack.deletionTargets[0].collection,'teachers_directory');assert.equal(ack.deletionTargets[0].id,id);
});
