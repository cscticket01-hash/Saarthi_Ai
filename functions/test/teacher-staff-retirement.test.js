'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {storage,A}=require('./helpers/managed-storage');
const G='p-'+'1'.repeat(64),N='p-'+'2'.repeat(64),ID='teacher-one',TOKEN='synthetic-teacher-link-token-000001';
let serial=0;
function write(s,col,id,data,base='',op='retirement-write-operation-'+(++serial)){
 return s.call({action:'managed_records',collection:col,id,operation:'write',syncProtocol:2,operationId:op,expectedRecordRevision:base,data:{schoolId:A,...data}});
}
const read=(s,col,id)=>s.call({action:'managed_records',collection:col,operation:'read',syncProtocol:2,...(id?{id}:{})});
const teacher=s=>write(s,'teachers_directory',ID,{name:'Synthetic teacher',teacherId:'T1',mobileStableId:G,mobileLinkToken:TOKEN});
const mobile=(s,request)=>s.call({action:'managed_mobile',request,lease:{schoolId:A,expiresAt:Date.now()+3600000}});
test('teacher retirement revokes exact access, preserves salary/attendance history and replays once',()=>{
 const s=storage({lifecycle:true,bundle:true}),a=teacher(s);assert.equal(a.success,true);
 assert.equal(write(s,'teacher_salary','salary',{teacherId:'T1',personId:G,amount:100}).success,true);
 assert.equal(write(s,'teacher_attendance','attendance',{teacherId:'T1',personId:G,day:'2026-11-02'}).success,true);
 assert.equal(write(s,'documents','card',{teacherId:'T1',personId:G,ownerRole:'teacher',documentKind:'idCard',documentRevision:'card-v1'}).success,true);
 assert.equal(write(s,'teachers_directory','teacher-two',{name:'Other teacher',teacherId:'T2',mobileStableId:N}).success,true);
 assert.equal(write(s,'documents','other',{teacherId:'T2',personId:N,ownerRole:'teacher',documentKind:'idCard',documentRevision:'card-v2'}).success,true);
 const login=mobile(s,{action:'mobile_login',role:'teacher',personId:ID,linkToken:TOKEN,projectId:A});assert.equal(login.success,true,JSON.stringify(login));
 const request={action:'managed_records',collection:'teachers_directory',id:ID,operation:'delete',syncProtocol:2,operationId:'teacher-retirement-delete-0001',expectedRecordRevision:a.recordRevision,deletedTeacherGeneration:G};
 const deleted=s.call(request);assert.equal(deleted.success,true,JSON.stringify(deleted));assert.equal(s.call(request).recordRevision,deleted.recordRevision);
 const parent=read(s,'teachers_directory',ID).records[ID];assert.equal(parent._syncDeletedOwner,G);assert.equal(parent._syncRetiredTeacherId,'T1');
 assert.equal(read(s,'documents','card').records.card._syncDeleted,true);assert.equal(read(s,'documents','other').records.other._syncDeleted,undefined);
 assert.equal(read(s,'teacher_salary','salary').records.salary.amount,100);assert.equal(read(s,'teacher_attendance','attendance').records.attendance.day,'2026-11-02');
 assert.equal(mobile(s,{action:'mobile_session_verify',sessionToken:login.sessionToken}).success,false);
 assert.equal(mobile(s,{action:'mobile_login',role:'teacher',personId:ID,linkToken:TOKEN,projectId:A}).success,false);
 assert.equal(write(s,'documents','late-card',{teacherId:'T1',personId:G,ownerRole:'teacher',documentRevision:'late-v1'}).success,false);
 assert.equal(write(s,'teacher_salary','late-payroll',{teacherId:'T1',personId:G,amount:100}).success,false);
 const salary=read(s,'teacher_salary','salary').records.salary;
 assert.equal(write(s,'teacher_salary','salary',{teacherId:'T1',personId:G,amount:101},salary._syncRevision).success,true);
});
test('wrong teacher retirement generation and identity reassignment retain original teacher/access',()=>{
 const s=storage({lifecycle:true,bundle:true}),a=teacher(s);
 const wrong=s.call({action:'managed_records',collection:'teachers_directory',id:ID,operation:'delete',syncProtocol:2,operationId:'teacher-retirement-wrong-0001',expectedRecordRevision:a.recordRevision,deletedTeacherGeneration:N});assert.equal(wrong.success,false);
 assert.equal(read(s,'teachers_directory',ID).records[ID]._syncRevision,a.recordRevision);
 assert.equal(write(s,'teachers_directory',ID,{name:'Other teacher',teacherId:'T2',mobileStableId:N},a.recordRevision).success,false);
});
test('teacher inactive retirement blocks fresh and existing mobile sessions while preserving profile/history',()=>{
 const s=storage({lifecycle:true,bundle:true}),a=teacher(s);
 const login=mobile(s,{action:'mobile_login',role:'teacher',personId:ID,linkToken:TOKEN,projectId:A});assert.equal(login.success,true);
 const retired=write(s,'teachers_directory',ID,{...a.record,active:false},a.recordRevision);assert.equal(retired.success,true,JSON.stringify(retired));
 assert.equal(read(s,'teachers_directory',ID).records[ID].active,false);
 assert.equal(mobile(s,{action:'mobile_session_verify',sessionToken:login.sessionToken}).success,false);
 assert.equal(mobile(s,{action:'mobile_login',role:'teacher',personId:ID,linkToken:TOKEN,projectId:A}).success,false);
});
test('retirement preserves shared Drive references and removes only unshared teacher card bytes',()=>{
 const s=storage({lifecycle:true,bundle:true}),shared=s.roots[A].createFile('shared','image','image/png'),card=s.roots[A].createFile('card','pdf','application/pdf');
 const a=write(s,'teachers_directory',ID,{name:'Teacher',teacherId:'T1',mobileStableId:G,photoFileId:shared.id});assert.equal(a.success,true);
 assert.equal(write(s,'school_config','shared-assets',{logoUrl:'https://drive.google.com/uc?export=view&id='+shared.id}).success,true);
 assert.equal(write(s,'documents','card',{teacherId:'T1',personId:G,ownerRole:'teacher',fileId:card.id,documentRevision:'card-v1'}).success,true);
 const retired=s.call({action:'managed_records',collection:'teachers_directory',id:ID,operation:'delete',syncProtocol:2,operationId:'teacher-retirement-files-0001',expectedRecordRevision:a.recordRevision,deletedTeacherGeneration:G});assert.equal(retired.success,true,JSON.stringify(retired));
 assert.equal(shared.isTrashed(),false);assert.equal(card.isTrashed(),true);
});
test('staff active false retires access identity without removing payroll history or permitting employee reuse',()=>{
 const s=storage({lifecycle:true,bundle:true});teacher(s);
 const row={id:'staff:1',name:'Synthetic staff',employeeId:'E1',role:'Driver',active:true};
 const a=write(s,'school_settings','staff_payroll_directory',{staff:[row]});assert.equal(a.success,true);
 const payroll=write(s,'teacher_salary','staff-payroll',{staffId:'staff:1',employeeId:'E1',amount:500});assert.equal(payroll.success,true);
 const retired=write(s,'school_settings','staff_payroll_directory',{staff:[{...row,active:false}]},a.recordRevision);assert.equal(retired.success,true);
 assert.equal(read(s,'teacher_salary','staff-payroll').records['staff-payroll'].amount,500);
 assert.equal(write(s,'school_settings','staff_payroll_directory',{staff:[]},retired.recordRevision).success,false);
 assert.equal(write(s,'school_settings','staff_payroll_directory',{staff:[{...row,employeeId:'E2'}]},retired.recordRevision).success,false);
 assert.equal(write(s,'school_settings','staff_payroll_directory',{staff:[{...row,active:false},{id:'staff:2',employeeId:'e1',role:'Guard'}]},retired.recordRevision).success,false);
 const health=s.call({action:'managed_health'});assert.equal(health.teacherRetirementVersion,1);assert.equal(health.staffRetirementVersion,1);assert.equal(health.scriptBundleVersion,'2026-11-02.4');
});
test('active teacher dependents require exact explicit person generation and never borrow another teacher generation',()=>{
 const s=storage({lifecycle:true,bundle:true}),a=teacher(s);assert.equal(a.success,true);
 assert.equal(write(s,'documents','wrong-generation',{teacherId:'T1',personId:N,ownerRole:'teacher',documentRevision:'wrong-v1'}).success,false);
 assert.equal(read(s,'documents','wrong-generation').records['wrong-generation'],undefined);
 assert.equal(write(s,'teacher_attendance','wrong-attendance',{teacherId:'T1',personId:N,role:'teacher',day:'2026-11-02'}).success,false);
 assert.equal(write(s,'documents','proper-generation',{teacherId:'T1',personId:G,ownerRole:'teacher',documentRevision:'proper-v1'}).success,true);
 assert.equal(write(s,'documents','pending-parent',{teacherId:'T2',personId:N,ownerRole:'teacher',documentRevision:'pending-v1'}).success,false);
});
test('legacy salary history without generation remains auditable but cannot acquire a guessed generation after retirement',()=>{
 const s=storage({lifecycle:true,bundle:true}),a=teacher(s),before=write(s,'teacher_salary','legacy-payroll',{teacherId:'T1',amount:500});assert.equal(before.success,true);
 const retired=s.call({action:'managed_records',collection:'teachers_directory',id:ID,operation:'delete',syncProtocol:2,operationId:'legacy-teacher-retirement-0001',expectedRecordRevision:a.recordRevision,deletedTeacherGeneration:G});assert.equal(retired.success,true);
 const corrected=write(s,'teacher_salary','legacy-payroll',{teacherId:'T1',amount:501},before.recordRevision);assert.equal(corrected.success,true);
 assert.equal(write(s,'teacher_salary','legacy-payroll',{teacherId:'T1',personId:G,amount:502},corrected.recordRevision).success,false);
 assert.equal(read(s,'teacher_salary','legacy-payroll').records['legacy-payroll'].amount,501);
});
test('addStaff shaped legacy entries retain stable IDs, paid history and optional employee enrollment across retirement/return',()=>{
 const s=storage({lifecycle:true,bundle:true}),row={id:'staff:legacy-1',name:'Legacy staff',role:'Driver',designation:'Driver'};
 const directory=write(s,'school_settings','staff_payroll_directory',{staff:[row]});assert.equal(directory.success,true);
 const history={staffId:row.id,teacherId:'',employeeId:'',month:'2026-11',amount:500,netPaise:50000,paidPaise:50000,status:'Paid',payments:[{id:'payment-1',amountPaise:50000}]};
 const paid=write(s,'teacher_salary','paid-staff-history',history);assert.equal(paid.success,true);
 const inactive=write(s,'school_settings','staff_payroll_directory',{staff:[{...row,active:false}]},directory.recordRevision);assert.equal(inactive.success,true);
 const enrolled=write(s,'school_settings','staff_payroll_directory',{staff:[{...row,active:true,employeeId:'E1'}]},inactive.recordRevision);assert.equal(enrolled.success,true);
 const updated=write(s,'teacher_salary','paid-staff-history',{...history,employeeId:'E1'},paid.recordRevision);assert.equal(updated.success,true,JSON.stringify(updated));
 const final=read(s,'teacher_salary','paid-staff-history').records['paid-staff-history'];assert.equal(final.paidPaise,50000);assert.equal(final.status,'Paid');assert.equal(final.payments[0].id,'payment-1');
 assert.equal(write(s,'teacher_salary','paid-staff-history',{...history,employeeId:'E2'},updated.recordRevision).success,false);
});
test('nested staff photos and template arrays protect shared Drive URLs including encoded uc IDs',()=>{
 const s=storage({lifecycle:true,bundle:true}),photo=s.roots[A].createFile('photo','image','image/png'),card=s.roots[A].createFile('card','pdf','application/pdf');
 const a=write(s,'teachers_directory',ID,{name:'Teacher',teacherId:'T1',mobileStableId:G,photoFileId:photo.id});assert.equal(a.success,true);
 assert.equal(write(s,'documents','card',{teacherId:'T1',personId:G,ownerRole:'teacher',fileId:card.id,documentRevision:'card-v1'}).success,true);
 const encoded='%'+photo.id.charCodeAt(0).toString(16)+photo.id.slice(1);
 assert.equal(write(s,'school_settings','staff_payroll_directory',{staff:[{id:'staff:shared',name:'Shared photo',photoUrl:'https://drive.google.com/uc?export=view&id='+encoded}]}).success,true);
 assert.equal(write(s,'school_settings','nested_templates',{templates:[{layers:[{assetUrl:'https://drive.google.com/file/d/'+card.id+'/view'}]}]}).success,true);
 const retired=s.call({action:'managed_records',collection:'teachers_directory',id:ID,operation:'delete',syncProtocol:2,operationId:'teacher-nested-shared-retire-0001',expectedRecordRevision:a.recordRevision,deletedTeacherGeneration:G});assert.equal(retired.success,true,JSON.stringify(retired));
 assert.equal(photo.isTrashed(),false);assert.equal(card.isTrashed(),false);
 assert.deepEqual(Array.from(s.context.VS_referencedDriveFileIds('https://evil.example/uc?id='+photo.id)),[]);
});
test('unverified missing active records and over-deep reference scans retain bytes rather than guess unshared',()=>{
 for(const missing of [true,false]){
  const s=storage({lifecycle:true,bundle:true}),photo=s.roots[A].createFile('uncertain-photo','image','image/png');
  const a=write(s,'teachers_directory',ID,{name:'Teacher',teacherId:'T1',mobileStableId:G,photoFileId:photo.id});assert.equal(a.success,true);
  let deep={};if(!missing){deep='https://drive.google.com/uc?id='+photo.id;for(let i=0;i<20;i++)deep={nested:[deep]};}
  assert.equal(write(s,'school_config','unverified-reference',{nested:deep}).success,true);
  if(missing){const store=s.context.VS_managedSheet('school_config'),item=s.context.VS_sheetItem(store,'unverified-reference');store.sheet.getRange(item.row,1,1,33).setValues([Array(33).fill('')]);}
  const retired=s.call({action:'managed_records',collection:'teachers_directory',id:ID,operation:'delete',syncProtocol:2,operationId:'teacher-uncertain-retire-'+(missing?'missing':'deep')+'-0001',expectedRecordRevision:a.recordRevision,deletedTeacherGeneration:G});assert.equal(retired.success,true,JSON.stringify(retired));
  assert.equal(photo.isTrashed(),false);
 }
});
