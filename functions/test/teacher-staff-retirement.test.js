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
 assert.equal(write(s,'school_config','shared-assets',{logoUrl:'https://drive.google.com/file/d/'+shared.id+'/view'}).success,true);
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
 const health=s.call({action:'managed_health'});assert.equal(health.teacherRetirementVersion,1);assert.equal(health.staffRetirementVersion,1);assert.equal(health.scriptBundleVersion,'2026-11-02.1');
});
