import {test} from 'node:test';
import assert from 'node:assert/strict';
import {validateDomainCandidate,validatePayrollAdvance,validatePayrollMonth,validateClosedPayrollMonth,validatePayrollLeave} from '../src/domain-policy.ts';
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


test('one-time fee admission month is generation-bound and immutable',async()=>{
 const {validatePersonCandidate}=await import('../src/domain-policy.ts');
 const g='p-'+'a'.repeat(64),n='p-'+'b'.repeat(64);
 const original={schoolId:school,id:'student-one',mobileStableId:g,class:'Class 1',section:'A',rollNo:'1'};
 const check=(next,{current=original,id='student-one'}={})=>validatePersonCandidate({
  schoolId:school,collection:'students_directory',id,operation:'write',
  current,next:{...original,...next,schoolId:school},readPeers:()=>[original]});
 assert.doesNotThrow(()=>check({feeAdmissionMonth:'2026-04',feeAdmissionPersonId:g}));
 assert.throws(()=>check({feeAdmissionMonth:'2026-13',feeAdmissionPersonId:g}),e=>e.code==='PERSON_FEE_ADMISSION_INVALID');
 assert.throws(()=>check({feeAdmissionMonth:'2026-04'}),e=>e.code==='PERSON_FEE_ADMISSION_INVALID');
 assert.throws(()=>check({feeAdmissionMonth:'2026-04',feeAdmissionPersonId:n}),e=>e.code==='PERSON_FEE_ADMISSION_INVALID');
 const locked={...original,feeAdmissionMonth:'2026-04',feeAdmissionPersonId:g};
 assert.doesNotThrow(()=>check({name:'edited',feeAdmissionMonth:'2026-04',feeAdmissionPersonId:g},{current:locked}));
 assert.throws(()=>check({feeAdmissionMonth:'2026-05',feeAdmissionPersonId:g},{current:locked}),e=>e.code==='PERSON_FEE_ADMISSION_IMMUTABLE');
 assert.throws(()=>check({},{current:locked}),e=>e.code==='PERSON_FEE_ADMISSION_IMMUTABLE');
 assert.doesNotThrow(()=>check({mobileStableId:n,replacesStudentGeneration:g},{current:locked}));
});


test('one-time fee payments require the server-locked student admission month',()=>{
 const owner={...student,feeAdmissionMonth:'2026-04',feeAdmissionPersonId:'generation-one'};
 const valid={studentId:'student',personId:'generation-one',month:'2026-04',
  feeBillingPolicyVersion:1,expectedAmount:150,totalPaid:150,balance:0,status:'PAID',
  installmentAmount:150,lastPaymentId:'event-one',
  feeItems:{Admission:150},feeFrequencies:{Admission:'once'},
  feeAdmissionMonth:'2026-04',feeAdmissionPersonId:'generation-one'};
 assert.doesNotThrow(()=>run(valid,{owner}));
 const unversioned={...valid};delete unversioned.feeBillingPolicyVersion;
 assert.throws(()=>run(unversioned,{owner}),e=>e.code==='DOMAIN_FEE_BILLING_VERSION_REQUIRED');
 assert.throws(()=>run({...valid,month:'2026-05'},{owner}),e=>e.code==='DOMAIN_FEE_ONCE_NOT_AUTHORIZED');
 assert.throws(()=>run({...valid,feeAdmissionPersonId:'generation-two'},{owner}),e=>e.code==='DOMAIN_FEE_ONCE_NOT_AUTHORIZED');
 assert.throws(()=>run({...valid,feeAdmissionMonth:'2026-03'},{owner}),e=>e.code==='DOMAIN_FEE_ONCE_NOT_AUTHORIZED');
 assert.throws(()=>run({...valid,feeFrequencies:{Admission:'weekly'}},{owner}),e=>e.code==='DOMAIN_FEE_BILLING_FREQUENCY_INVALID');
 const monthly={...valid,feeFrequencies:{Admission:'monthly'}};
 delete monthly.feeAdmissionMonth;delete monthly.feeAdmissionPersonId;
 assert.doesNotThrow(()=>run(monthly,{owner:student}));
 assert.throws(()=>run({...monthly,feeItems:{Admission:151}},{owner:student}),e=>e.code==='DOMAIN_FEE_ITEMS_TOTAL_MISMATCH');
});

test('zero admission snapshot permits ordinary monthly payment without admission ownership',()=>{
 const monthly={studentId:'student',personId:'generation-one',month:'2026-05',
  feeBillingPolicyVersion:1,expectedAmount:100,totalPaid:100,balance:0,status:'PAID',
  installmentAmount:100,lastPaymentId:'event-one',
  feeItems:{Tuition:100,Admission:0},feeFrequencies:{Tuition:'monthly',Admission:'once'}};
 assert.doesNotThrow(()=>run(monthly));
 assert.doesNotThrow(()=>run(monthly,{collection:'fee_ledger'}));
 assert.throws(()=>run({...monthly,feeItems:{Tuition:90,Admission:10}}),
  e=>e.code==='DOMAIN_FEE_ONCE_NOT_AUTHORIZED');
});

test('record-only payment pair checks exact prior balance, owner and receipt identity',async()=>{
 const {validateRecordOnlyFeePair}=await import('../src/domain-policy.ts');
 const terms={schoolId:school,feeBillingPolicyVersion:1,studentId:'student',
   personId:'generation-one',feeIdentity:'person:generation-one',month:'2026-05',
   expectedAmount:125.5,feeItems:{Tuition:125.5},feeFrequencies:{Tuition:'monthly'}};
 const payment={...terms,paymentId:'payment-one',installmentAmount:50,totalPaid:50,
   balance:75.5,status:'PARTIAL'};
 const ledger={...terms,lastPaymentId:'payment-one',totalPaid:50,balance:75.5,status:'PARTIAL'};
 const input={schoolId:school,paymentId:'payment-one',payment,ledger,currentLedger:null};
 assert.doesNotThrow(()=>validateRecordOnlyFeePair(input));
 assert.throws(()=>validateRecordOnlyFeePair({...input,ledger:{...ledger,totalPaid:51}}),
   e=>e.code==='DOMAIN_FEE_PAIR_MISMATCH');
 assert.throws(()=>validateRecordOnlyFeePair({...input,ledger:{...ledger,personId:'other'}}),
   e=>e.code==='DOMAIN_FEE_PAIR_MISMATCH');
 assert.throws(()=>validateRecordOnlyFeePair({...input,payment:{...payment,receiptDocumentId:'file'}}),
   e=>e.code==='DOMAIN_FEE_PAIR_INVALID');
 const secondPayment={...payment,paymentId:'payment-two',installmentAmount:75.5,totalPaid:125.5,
   balance:0,status:'PAID'};
 const secondLedger={...ledger,lastPaymentId:'payment-two',totalPaid:125.5,balance:0,status:'PAID'};
 const second={...input,paymentId:'payment-two',payment:secondPayment,ledger:secondLedger,currentLedger:ledger};
 assert.doesNotThrow(()=>validateRecordOnlyFeePair(second));
 assert.throws(()=>validateRecordOnlyFeePair({...second,currentLedger:{...ledger,totalPaid:55}}),
   e=>e.code==='DOMAIN_FEE_PAIR_STALE_BALANCE');
 assert.throws(()=>validateRecordOnlyFeePair({...second,currentLedger:{...ledger,feeIdentity:'different'}}),
   e=>e.code==='DOMAIN_FEE_PAIR_LEDGER_CHANGED');
});

test('final promotion preserves stable owner and rejects forged or duplicate class movement',async()=>{
 const {validatePersonCandidate}=await import('../src/domain-policy.ts');
 const personId='p-'+'1'.repeat(64);
 const old={schoolId:school,id:'pupil-one',mobileStableId:personId,
   class:'Class 10',studentClass:'Class 10',section:'A',rollNo:'4'};
 const check=(next,{current=old,peers=[]}={})=>
   validatePersonCandidate({schoolId:school,collection:'students_directory',
     id:'pupil-one',operation:'write',current,next:{schoolId:school,...next},
     readPeers:()=>peers});
 const good={...old,class:'Class 11',studentClass:'Class 11',
   previousClass:'Class 10',promotionExamId:'final-10',lastExamResult:'PASS',
   promotionTransactionId:'promotion:final-10:pupil-one',
   classMovement:'PROMOTED',promotionPending:true,promotionSyncState:'Pending'};
 assert.doesNotThrow(()=>check(good));
 assert.throws(()=>check({...good,mobileStableId:'p-'+'2'.repeat(64)}),
   e=>e.code==='PERSON_GENERATION_REPLACEMENT_REQUIRED');
 assert.throws(()=>check({...good,class:'Class 12',studentClass:'Class 12'}),
   e=>e.code==='PERSON_PROMOTION_RULE_MISMATCH');
 assert.throws(()=>check({...good,studentClass:'Class 10'}),
   e=>e.code==='PERSON_PROMOTION_IDENTITY_MISMATCH');
 assert.throws(()=>check({...good,rollNo:'5'}),
   e=>e.code==='PERSON_PROMOTION_IDENTITY_MISMATCH');
 assert.throws(()=>check({...good,classMovement:'FORCE_PROMOTED',lastExamResult:'FAIL'}),
   e=>e.code==='PERSON_PROMOTION_RULE_MISMATCH');
 assert.throws(()=>check({...good,classMovement:'PROMOTED'},
   {current:null}),e=>e.code==='PERSON_PROMOTION_REQUIRES_EXISTING_OWNER');
 assert.throws(()=>check(good,{peers:[{...old,id:'another',
   class:'Class 11',studentClass:'Class 11',rollNo:'4'}]}),
   e=>e.code==='PERSON_STUDENT_SLOT_CONFLICT');
});

test('exact-paise payroll ledger retains immutable payment and correction history',()=>{
 const base={schoolId:school,staffId:'teacher:teacher',employeeId:'T1',teacherId:'T1',month:'2026-11',basicPaise:10000,netPaise:10000,amount:100,paidPaise:0,balancePaise:10000,status:'Pending'};
 const options={collection:'teacher_salary',owner:teacher};
 assert.doesNotThrow(()=>run(base,options));
 const p={id:'payment-1',amountPaise:3000};
 const paid={...base,paidPaise:3000,balancePaise:7000,status:'Part paid',payments:[p]};
 assert.doesNotThrow(()=>run(paid,{...options,current:base}));
 assert.throws(()=>run({...paid,balancePaise:9000},{...options,current:base}),e=>e.code==='SALARY_BALANCE_MISMATCH');
 assert.throws(()=>run({...paid,payments:[]},{...options,current:paid}),e=>e.code==='SALARY_HISTORY_IMMUTABLE');
 assert.throws(()=>run({...paid,payments:[p,p]},{...options,current:paid}),e=>e.code==='SALARY_DUPLICATE_EVENT');
 assert.throws(()=>run({...paid,paidPaise:4000,balancePaise:6000},{...options,current:paid}),e=>e.code==='SALARY_PAYMENT_TOTAL_MISMATCH');
 const reversed={...paid,paidPaise:0,balancePaise:10000,status:'Pending',paymentCorrections:[{id:'reversal-1',paymentId:p.id,originalPaise:3000,previousPaise:3000,correctedPaise:0,differencePaise:-3000,eventType:'reversal'}]};
 assert.doesNotThrow(()=>run(reversed,{...options,current:paid}));
 assert.throws(()=>run({_syncDeleted:true},{...options,current:reversed,operation:'delete'}),e=>e.code==='SALARY_HISTORY_IMMUTABLE');
 assert.throws(()=>run({...base,staffId:'teacher:wrong'},{...options}),e=>e.code==='DOMAIN_TEACHER_RETIRED');
});

test('locked salary permits payments but prevents amount and correction changes until reopened',()=>{
 const base={schoolId:school,staffId:'teacher:teacher',employeeId:'T1',teacherId:'T1',month:'2026-11',basicPaise:10000,netPaise:10000,amount:100,paidPaise:0,balancePaise:10000,status:'Pending'};
 const options={collection:'teacher_salary',owner:teacher};
 const locks=[{id:'lock-one',locked:true,at:1}];
 const locked={...base,salaryLocked:true,salaryLockHistory:locks};
 assert.doesNotThrow(()=>run(locked,{...options,current:base}));
 assert.throws(()=>run({...locked,basicPaise:11000,netPaise:11000,amount:110,balancePaise:11000},{...options,current:locked}),e=>e.code==='SALARY_LOCKED');
 const paid={...locked,paidPaise:2000,balancePaise:8000,status:'Part paid',payments:[{id:'p',amountPaise:2000}]};
 assert.doesNotThrow(()=>run(paid,{...options,current:locked}));
 assert.throws(()=>run({...paid,salaryLocked:false},{...options,current:paid}),e=>e.code==='SALARY_LOCK_HISTORY_INVALID');
 const open={...paid,salaryLocked:false,salaryLockHistory:[...locks,{id:'reopen',locked:false,at:2}]};
 assert.doesNotThrow(()=>run(open,{...options,current:paid}));
});
test('attendance adjustments cannot exceed or misstate deductions',()=>{
 const base={schoolId:school,staffId:'teacher:teacher',employeeId:'T1',teacherId:'T1',month:'2026-11',basicPaise:10000,deductionPaise:2000,netPaise:8000,amount:80,paidPaise:0,balancePaise:8000,status:'Pending'};
 const options={collection:'teacher_salary',owner:teacher};
 const attendanceAdjustment={unpaidDates:['2026-11-03','2026-11-04'],ratePaise:1000,amountPaise:2000,reason:'Approved unpaid leave'};
 assert.doesNotThrow(()=>run({...base,attendanceAdjustment},options));
 assert.throws(()=>run({...base,attendanceAdjustment:{...attendanceAdjustment,amountPaise:1000}},options),e=>e.code==='SALARY_ATTENDANCE_INVALID');
 assert.throws(()=>run({...base,attendanceAdjustment:{...attendanceAdjustment,unpaidDates:['2026-11-03','2026-11-03']}},options),e=>e.code==='SALARY_ATTENDANCE_INVALID');
});

test('older salary records without stored balance retain exact financial totals',()=>{
 const legacy={schoolId:school,staffId:'staff-one',employeeId:'E1',month:'2026-11',netPaise:50000,paidPaise:50000,amount:500,status:'Paid',payments:[{id:'p',amountPaise:50000}]};
 const options={collection:'teacher_salary',owner:{schoolId:school,id:'staff-one',employeeId:'E1',active:true}};
 assert.doesNotThrow(()=>run(legacy,options));
 assert.doesNotThrow(()=>run({...legacy,balancePaise:0},{...options,current:legacy}));
 assert.throws(()=>run({...legacy,balancePaise:1},options),e=>e.code==='SALARY_BALANCE_MISMATCH');
});
test('advance ledger history and outstanding amount are immutable',()=>{
 const id='payroll_advance_fixture',owner={schoolId:school,id:'staff-one',active:true};
 const issue={id:'a',type:'advance',amountPaise:5000,reference:'recorded',recordedAt:1};
 const base={schoolId:school,staffId:'staff-one',balancePaise:5000,events:[issue]};
 const check=(current,next,operation='write')=>validatePayrollAdvance(id,current,next,operation,()=>owner,school);
 assert.doesNotThrow(()=>check(null,base));
 const repay={id:'r',type:'repayment',amountPaise:2000,reference:'recorded',recordedAt:2};
 assert.doesNotThrow(()=>check(base,{...base,balancePaise:3000,events:[issue,repay]}));
 assert.throws(()=>check(base,{...base,balancePaise:0,events:[]}),e=>e.code==='SALARY_HISTORY_IMMUTABLE');
 assert.throws(()=>check(base,{...base,balancePaise:1}),e=>e.code==='SALARY_ADVANCE_BALANCE_MISMATCH');
});
test('month closure prevents new records and changes, but allows payments',()=>{
 const marker={month:'2026-11',closed:true,history:[{id:'close',closed:true,at:1}]};
 const id='payroll_month_2026-11';
 assert.doesNotThrow(()=>validatePayrollMonth(id,null,marker,'write'));
 assert.throws(()=>validatePayrollMonth(id,marker,{...marker,closed:false},'write'),e=>e.code==='SALARY_MONTH_HISTORY_INVALID');
 const base={month:'2026-11',netPaise:10000,paidPaise:0,balancePaise:10000,status:'Pending'};
 assert.throws(()=>validateClosedPayrollMonth(null,base,'write'),e=>e.code==='SALARY_MONTH_CLOSED');
 assert.throws(()=>validateClosedPayrollMonth(base,{...base,netPaise:11000},'write'),e=>e.code==='SALARY_MONTH_CLOSED');
 assert.doesNotThrow(()=>validateClosedPayrollMonth(base,{...base,paidPaise:1000,balancePaise:9000,status:'Part paid',payments:[{id:'p',amountPaise:1000}]},'write'));
});

test('payroll leave decisions preserve history and reject closed months and invalid dates',()=>{
 const owner={schoolId:school,id:'staff-one',active:true};
 const leave={schoolId:school,staffId:'staff-one',month:'2026-11',events:[{id:'a',date:'2026-11-03',kind:'unpaid',reason:'approved',at:1}]};
 const lookup=(collection,id)=>collection==='staff_payroll_directory'?owner:null;
 const check=(current,next,readOwner=lookup,operation='write')=>validatePayrollLeave(current,next,operation,readOwner,school);
 assert.doesNotThrow(()=>check(null,leave));
 assert.doesNotThrow(()=>check(leave,{...leave,events:[...leave.events,{id:'b',date:'2026-11-03',kind:'paid',reason:'reviewed',at:2}]}));
 assert.throws(()=>check(leave,{...leave,events:[]}),e=>e.code==='SALARY_HISTORY_IMMUTABLE');
 assert.throws(()=>check(null,{...leave,events:[{...leave.events[0],date:'2026-11-31'}]}),e=>e.code==='SALARY_LEAVE_EVENT_INVALID');
 assert.throws(()=>check(null,leave,(collection,id)=>collection==='school_settings'?{schoolId:school,closed:true}:owner),e=>e.code==='SALARY_MONTH_CLOSED');
 assert.throws(()=>check(leave,{},lookup,'delete'),e=>e.code==='SALARY_LEAVE_HISTORY_IMMUTABLE');
});

test('person postal PIN and dates reject invalid new fields while preserving legacy data',async()=>{
 const {validatePersonContactFields}=await import('../src/domain-policy.ts');
 const row={pinCode:'788001',dateOfBirth:'29/02/2012',joiningDate:'2026-04-01'};
 assert.doesNotThrow(()=>validatePersonContactFields('students_directory',null,row));
 for(const pinCode of ['12345','1234567','abcdef',123456]){
  assert.throws(()=>validatePersonContactFields('students_directory',row,{...row,pinCode}),e=>e.code==='PERSON_POSTAL_PIN_INVALID');
 }
 for(const dateOfBirth of ['31/02/2012','29/02/2011','2100-01-01']){
  assert.throws(()=>validatePersonContactFields('students_directory',row,{...row,dateOfBirth}),e=>e.code==='PERSON_DATE_INVALID');
 }
 assert.throws(()=>validatePersonContactFields('teachers_directory',row,{...row,joiningDate:'01/01/2010'}),e=>e.code==='PERSON_DATE_ORDER_INVALID');
 const legacy={pinCode:'bad',dateOfBirth:'historical'};
 assert.doesNotThrow(()=>validatePersonContactFields('students_directory',legacy,{...legacy,name:'Updated'}));
});
