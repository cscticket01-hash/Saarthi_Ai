import {test} from 'node:test';
import assert from 'node:assert/strict';
import {validateDomainCandidate} from '../src/domain-policy.ts';
const school='vs-'+'a'.repeat(32),foreign='vs-'+'b'.repeat(32);
const student={schoolId:school,id:'student',mobileStableId:'generation-one'},teacher={schoolId:school,id:'teacher',teacherId:'T1',mobileStableId:'teacher-generation'};
function run(next,{collection='fee_payments',current=null,owner=student,operation='write'}={}){
 return validateDomainCandidate({schoolId:school,collection,id:'event-one',operation,current,next:{schoolId:school,...next},readOwner:()=>owner});
}
test('same payment cannot move to another person but class/roll alias may follow same generation',()=>{
 const current={schoolId:school,personId:'generation-one',studentId:'old-slot',amount:100};
 assert.doesNotThrow(()=>run({personId:'generation-one',studentId:'new-slot',amount:101},{current}));
 assert.throws(()=>run({personId:'generation-two',studentId:'new-slot',amount:101},{current}),e=>e.code==='DOMAIN_HISTORY_OWNER_IMMUTABLE');
});
test('late offline children cannot recreate deleted or replaced student generation',()=>{
 for(const owner of [{...student,_syncDeleted:true},{...student,mobileStableId:'new-generation'},{...student,_syncRetiredStudentGenerations:['generation-one']}]){
  assert.throws(()=>run({personId:'generation-one',studentId:'student',amount:100},{owner}),e=>e.code==='DOMAIN_STUDENT_GENERATION_DELETED');
 }
 assert.throws(()=>run({personId:'generation-one',studentId:'student',amount:100},{owner:null}),e=>e.code==='DOMAIN_PARENT_NOT_READY');
});
test('new teacher attendance/payroll rejects retired or foreign identity; exact history corrections remain allowed',()=>{
 const next={teacherId:'T1',personId:'teacher-generation',amount:100};
 assert.doesNotThrow(()=>run(next,{collection:'teacher_salary',owner:teacher}));
 assert.throws(()=>run(next,{collection:'teacher_salary',owner:{...teacher,active:false}}),e=>e.code==='DOMAIN_TEACHER_RETIRED');
 assert.throws(()=>run(next,{collection:'teacher_salary',owner:{...teacher,schoolId:foreign}}),e=>e.code==='DOMAIN_FOREIGN_OWNER');
 assert.doesNotThrow(()=>run({...next,amount:101},{collection:'teacher_salary',current:{schoolId:school,...next},owner:{...teacher,active:false}}));
 assert.throws(()=>run({...next,personId:'borrowed'},{collection:'teacher_attendance',owner:teacher}),e=>e.code==='DOMAIN_TEACHER_RETIRED');
});
test('new staff payroll requires exact active employee; historical correction preserves immutable owner',()=>{
 const next={staffId:'staff-one',employeeId:'E1',amount:100},owner={schoolId:school,id:'staff-one',employeeId:'E1',active:true};
 assert.doesNotThrow(()=>run(next,{collection:'teacher_salary',owner}));
 assert.throws(()=>run(next,{collection:'teacher_salary',owner:{...owner,active:false}}),e=>e.code==='DOMAIN_STAFF_RETIRED');
 assert.throws(()=>run({...next,employeeId:'E2'},{collection:'teacher_salary',owner}),e=>e.code==='DOMAIN_STAFF_IDENTITY_MISMATCH');
 assert.doesNotThrow(()=>run({...next,amount:101},{collection:'teacher_salary',current:{schoolId:school,...next},owner:{...owner,active:false}}));
});
test('foreign school, hidden nonfinite values, role conflicts and fake deletion cannot commit',()=>{
 assert.throws(()=>run({schoolId:foreign}),e=>e.code==='DOMAIN_SCHOOL_MISMATCH');
 assert.throws(()=>run({totals:[{amount:Infinity}]}),e=>e.code==='DOMAIN_INVALID_VALUE');
 assert.throws(()=>run({role:'student',ownerRole:'teacher'}),e=>e.code==='DOMAIN_OWNER_ROLE_CONFLICT');
 assert.throws(()=>run({},{operation:'delete'}),e=>e.code==='DOMAIN_DELETE_UNVERIFIED');
 assert.doesNotThrow(()=>run({_syncDeleted:true},{operation:'delete'}));
});

test('native person slot and generation fences preserve cloud winner across offline devices',async()=>{
 const {validatePersonCandidate}=await import('../src/domain-policy.ts');
 const g='p-'+'1'.repeat(64),n='p-'+'2'.repeat(64);
 const old={schoolId:school,id:'student-one',mobileStableId:g,class:'Class 1',section:'A',rollNo:'1'};
 const check=(next,{current=old,peers=[old],id='student-one',collection='students_directory'}={})=>validatePersonCandidate({schoolId:school,collection,id,operation:'write',current,next:{schoolId:school,...next},readPeers:()=>peers});
 assert.doesNotThrow(()=>check({...old,name:'edited'}));
 assert.throws(()=>check({...old,mobileStableId:n}),e=>e.code==='PERSON_GENERATION_REPLACEMENT_REQUIRED');
 assert.doesNotThrow(()=>check({...old,mobileStableId:n,replacesStudentGeneration:g}));
 assert.throws(()=>check({...old,id:'new-student',mobileStableId:n},{id:'new-student',current:null,peers:[old]}),e=>e.code==='PERSON_STUDENT_SLOT_CONFLICT');
 assert.throws(()=>check({...old},{current:{...old,_syncDeleted:true,_syncDeletedOwner:g}}),e=>e.code==='PERSON_GENERATION_RETIRED');
 assert.throws(()=>check({...old,mobileStableId:g},{current:{...old,mobileStableId:n,_syncRetiredStudentGenerations:[g]}}),e=>e.code==='PERSON_GENERATION_REPLACEMENT_REQUIRED');
});
test('native teacher identities remain reserved after retirement and cannot collide with staff',async()=>{
 const {validatePersonCandidate}=await import('../src/domain-policy.ts');
 const next={schoolId:school,teacherId:'T1',mobileStableId:'teacher-gen'};
 const check=(options={})=>validatePersonCandidate({schoolId:school,collection:'teachers_directory',id:'teacher-new',operation:'write',current:null,next,readPeers:collection=>collection==='teachers_directory'?[{schoolId:school,id:'teacher-old',_syncDeleted:true,_syncRetiredTeacherId:'t1'}]:[],...options});
 assert.throws(()=>check(),e=>e.code==='PERSON_PAYROLL_IDENTITY_CONFLICT');
 assert.throws(()=>check({readPeers:collection=>collection==='staff_payroll_directory'?[{schoolId:school,id:'staff',employeeId:'T1',active:false}]:[]}),e=>e.code==='PERSON_PAYROLL_IDENTITY_CONFLICT');
 assert.throws(()=>check({current:{...next,id:'teacher-new',teacherId:'T2'}}),e=>e.code==='PERSON_TEACHER_REASSIGNMENT_REQUIRES_REVIEW');
});
