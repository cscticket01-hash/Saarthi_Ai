type Json=Record<string,unknown>;
export const domainCollections=new Set([
 'fee_settings','fee_ledger','fee_payments','teacher_salary',
 'attendance_records','attendance_logs','teacher_attendance','teacher_schedules',
 'exams','exam_results','exam_center_results',
 'documents','student_scan_index',
]);
export interface DomainCandidate {
 schoolId:string;collection:string;id:string;operation:string;
 current:Json|null;next:Json;
 // This lookup must read an authoritative, migration-fenced owner index in the
 // SAME Durable Object transaction. Caller payloads are not lifecycle proof.
 readOwner:(collection:string,id:string)=>Json|null;
}
function reject(code:string,status=409):never {
 throw Object.assign(new Error('Domain lifecycle validation failed; original work retained.'),{status,code});
}
function boundedJson(value:unknown,depth=0,budget={left:10000}):void {
 if(--budget.left<0||depth>12)reject('DOMAIN_RECORD_TOO_LARGE',413);
 if(typeof value==='number'&&!Number.isFinite(value))reject('DOMAIN_INVALID_VALUE',400);
 if(value===null||typeof value==='string'||typeof value==='number'||typeof value==='boolean')return;
 if(Array.isArray(value)){for(const entry of value)boundedJson(entry,depth+1,budget);return;}
 if(typeof value!=='object'||value===undefined)reject('DOMAIN_INVALID_VALUE',400);
 for(const [key,entry]of Object.entries(value)){
  if(['__proto__','prototype','constructor'].includes(key))reject('DOMAIN_INVALID_FIELD',400);
  boundedJson(entry,depth+1,budget);
 }
}
const nonempty=(value:unknown):value is string=>typeof value==='string'&&value.length>0&&value.length<=200;
function generation(owner:Json):unknown {return owner.mobileStableId||owner.generation||owner._syncDeletedOwner||owner.id;}
function owned(school:string,owner:Json|null):Json {
 if(!owner)reject('DOMAIN_PARENT_NOT_READY',412);
 if(owner.schoolId!==school)reject('DOMAIN_FOREIGN_OWNER',403);
 return owner;
}
// Validate the modern exact-paise ledger at the authoritative CAS boundary.
// Legacy amount-only rows remain readable and compatible; a modern row must
// never fall back to the legacy schema to discard its financial history.
function salaryPaise(value:unknown):number {
 if(typeof value!=='number'||!Number.isSafeInteger(value)||value<0)reject('SALARY_INVALID_AMOUNT',400);
 return value;
}
function salaryEvents(value:unknown):Json[] {
 if(value===undefined||value===null)return [];
 if(!Array.isArray(value)||value.some(v=>!v||typeof v!=='object'||Array.isArray(v)))reject('SALARY_INVALID_HISTORY',400);
 return value as Json[];
}
function salaryCanonical(value:unknown):string {
 if(Array.isArray(value))return '['+value.map(salaryCanonical).join(',')+']';
 if(value&&typeof value==='object')return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+salaryCanonical((value as Json)[k])).join(',')+'}';
 return JSON.stringify(value)??'null';
}
function salaryAppendOnly(before:Json[],after:Json[]):void {
 if(after.length<before.length||before.some((event,i)=>salaryCanonical(event)!==salaryCanonical(after[i])))reject('SALARY_HISTORY_IMMUTABLE');
}
function salaryEventTotal(row:Json):number {
 const payments=salaryEvents(row.payments),corrections=salaryEvents(row.paymentCorrections);
 const effective=new Map<string,number>(),originals=new Map<string,number>(),ids=new Set<string>();
 for(const p of payments){
  if(!nonempty(p.id)||ids.has(p.id))reject('SALARY_DUPLICATE_EVENT');
  const amount=salaryPaise(p.amountPaise);
  if(!amount)reject('SALARY_INVALID_AMOUNT',400);
  ids.add(p.id);effective.set(p.id,amount);originals.set(p.id,amount);
 }
 for(const c of corrections){
  if(!nonempty(c.id)||ids.has(c.id)||!nonempty(c.paymentId)||!effective.has(c.paymentId))reject('SALARY_INVALID_CORRECTION');
  const before=salaryPaise(c.previousPaise),after=salaryPaise(c.correctedPaise);
  if(before!==effective.get(c.paymentId)||before===after||c.originalPaise!==originals.get(c.paymentId)||c.differencePaise!==after-before)reject('SALARY_INVALID_CORRECTION');
  ids.add(c.id);effective.set(c.paymentId,after);
 }
 return salaryPaise([...effective.values()].reduce((a,b)=>a+b,0));
}
function validateSalaryLedger(current:Json|null,next:Json):void {
 if(next.netPaise===undefined){
  if(current?.netPaise!==undefined)reject('SALARY_SCHEMA_DOWNGRADE');
  return;
 }
 const net=salaryPaise(next.netPaise),paid=salaryPaise(next.paidPaise),balance=salaryPaise(next.balancePaise===undefined&&(!current||current.balancePaise===undefined)?net-paid:next.balancePaise);
 if(paid>net||balance!==net-paid)reject('SALARY_BALANCE_MISMATCH');
 const expectedStatus=paid===net?'Paid':paid===0?'Pending':'Part paid';
 if(next.status!==expectedStatus)reject('SALARY_STATUS_MISMATCH');
 if(next.amount!==undefined&&(typeof next.amount!=='number'||Math.round(next.amount*100)!==net))reject('SALARY_NET_MISMATCH');
 const keys=['basicPaise','allowancePaise','bonusPaise','overtimePaise','deductionPaise'];
 if(keys.some(k=>next[k]!==undefined)){
  const amounts=keys.map(k=>salaryPaise(next[k]??0));
  if(amounts[0]+amounts[1]+amounts[2]+amounts[3]-amounts[4]!==net)reject('SALARY_NET_MISMATCH');
 }
 if(next.attendanceAdjustment!==undefined){
  const adj=next.attendanceAdjustment as Json;
  if(!adj||typeof adj!=='object'||Array.isArray(adj)||!Array.isArray(adj.unpaidDates)||typeof adj.reason!=='string'||!adj.reason.trim())reject('SALARY_ATTENDANCE_INVALID');
  const dates=adj.unpaidDates;
  if(dates.length>31||new Set(dates).size!==dates.length||dates.some(d=>typeof d!=='string'||!/^\d{4}-\d{2}-\d{2}$/.test(d)||!d.startsWith(String(next.month)+'-')))reject('SALARY_ATTENDANCE_INVALID');
  const n=salaryPaise(adj.ratePaise)*dates.length;
  if((dates.length>0&&n===0)||n!==adj.amountPaise||n>salaryPaise(next.deductionPaise))reject('SALARY_ATTENDANCE_INVALID');
 }
 const prior=current&&!current._syncDeleted?current:null;
 if(prior&&prior.month!==undefined&&prior.month!==next.month)reject('SALARY_MONTH_IMMUTABLE');
 salaryAppendOnly(salaryEvents(prior?.payments),salaryEvents(next.payments));
 salaryAppendOnly(salaryEvents(prior?.paymentCorrections),salaryEvents(next.paymentCorrections));
 const oldLocks=salaryEvents(prior?.salaryLockHistory),newLocks=salaryEvents(next.salaryLockHistory);
 salaryAppendOnly(oldLocks,newLocks);
 let locked=prior?.salaryLocked===true;
 for(const entry of newLocks.slice(oldLocks.length)){
  if(!nonempty(entry.id)||typeof entry.locked!=='boolean'||entry.locked===locked||!Number.isSafeInteger(entry.at))reject('SALARY_LOCK_HISTORY_INVALID');
  locked=entry.locked;
 }
 if(locked!==(next.salaryLocked===true))reject('SALARY_LOCK_HISTORY_INVALID');
 if(prior?.salaryLocked===true){
  if(['basicPaise','allowancePaise','bonusPaise','overtimePaise','deductionPaise','netPaise','amount'].some(k=>prior[k]!==next[k])||
     salaryCanonical(prior.paymentCorrections??[])!==salaryCanonical(next.paymentCorrections??[])||salaryCanonical(prior.attendanceAdjustment??null)!==salaryCanonical(next.attendanceAdjustment??null))reject('SALARY_LOCKED');
 }

 // Existing unitemized legacy balances must be retained, not manufactured.
 let opening=0;
 if(prior){
  const priorPaid=prior.paidPaise!==undefined?salaryPaise(prior.paidPaise):
   String(prior.status).toLowerCase()==='paid'?salaryPaise(prior.netPaise??Math.round(Number(prior.amount??0)*100)):0;
  opening=priorPaid-salaryEventTotal(prior);
 }
 if(opening<0||paid!==opening+salaryEventTotal(next))reject('SALARY_PAYMENT_TOTAL_MISMATCH');
}
export function validatePayrollMonth(id:string,current:Json|null,next:Json,operation:string):void {
 if(operation==='delete'||next._syncDeleted===true)reject('SALARY_MONTH_CONTROL_IMMUTABLE');
 if(typeof next.month!=='string'||!/^\d{4}-(0[1-9]|1[0-2])$/.test(next.month)||id!=='payroll_month_'+next.month||current&&current.month!==next.month||typeof next.closed!=='boolean')reject('SALARY_MONTH_CONTROL_INVALID');
 const before=salaryEvents(current?.history),after=salaryEvents(next.history);
 salaryAppendOnly(before,after);
 const ids=new Set<string>();
 let closed=false;
 for(const e of after){
  if(!nonempty(e.id)||ids.has(e.id)||typeof e.closed!=='boolean'||e.closed===closed||!Number.isSafeInteger(e.at))reject('SALARY_MONTH_HISTORY_INVALID');
  ids.add(e.id);closed=e.closed;
 }
 if(closed!==next.closed)reject('SALARY_MONTH_HISTORY_INVALID');
}
export function validateClosedPayrollMonth(current:Json|null,next:Json,operation:string):void {
 if(operation==='delete'||!current||current._syncDeleted===true)reject('SALARY_MONTH_CLOSED');
 const allowed=new Set(['payments','paidPaise','balancePaise','status','updatedAt','salaryLocked','salaryLockHistory']);
 const immutable=(row:Json)=>Object.fromEntries(Object.entries(row).filter(([k])=>!allowed.has(k)&&!k.startsWith('_sync')));
 if(salaryCanonical(immutable(current))!==salaryCanonical(immutable(next)))reject('SALARY_MONTH_CLOSED');
}
export function validatePayrollAdvance(id:string,current:Json|null,next:Json,operation:string,readOwner:(collection:string,id:string)=>Json|null,school:string):void {
 if(!id.startsWith('payroll_advance_'))return;
 if(operation==='delete'||next._syncDeleted===true)reject('SALARY_ADVANCE_HISTORY_IMMUTABLE');
 if(!nonempty(next.staffId)||current&&current.staffId!==next.staffId)reject('SALARY_ADVANCE_OWNER_IMMUTABLE');
 boundedJson(next);
 const before=salaryEvents(current?.events),after=salaryEvents(next.events);
 salaryAppendOnly(before,after);
 let balance=0;
 const ids=new Set<string>();
 for(const e of after){
  if(!nonempty(e.id)||ids.has(e.id)||typeof e.reference!=='string'||!e.reference.trim()||e.reference.length>500||!Number.isSafeInteger(e.recordedAt))reject('SALARY_ADVANCE_EVENT_INVALID');
  ids.add(e.id);
  const amount=salaryPaise(e.amountPaise);
  if(!amount)reject('SALARY_ADVANCE_EVENT_INVALID');
  if(e.type==='advance'||e.type==='loan')balance+=amount;
  else if(e.type==='repayment')balance-=amount;
  else reject('SALARY_ADVANCE_EVENT_INVALID');
  salaryPaise(balance);
 }
 if(balance!==salaryPaise(next.balancePaise))reject('SALARY_ADVANCE_BALANCE_MISMATCH');
 const staffId=next.staffId;
 if(!current||after.slice(before.length).some(e=>e.type!=='repayment')){
  const teacher=staffId.startsWith('teacher:');
  const owner=owned(school,readOwner(teacher?'teachers_directory':'staff_payroll_directory',teacher?staffId.slice(8):staffId));
  if(owner.id!==(teacher?staffId.slice(8):staffId)||owner.active===false||owner.inactive===true||owner.deleted===true||owner._syncDeleted===true)reject('SALARY_ADVANCE_OWNER_RETIRED');
 }
}
export function validateDomainCandidate(input:DomainCandidate):void {
 const {schoolId,collection,id,operation,current,next,readOwner}=input;
 if(!domainCollections.has(collection))reject('DOMAIN_COLLECTION_NOT_ADMITTED',412);
 if(!/^vs-[a-f0-9]{32}$/.test(schoolId)||!nonempty(id)||id.includes('/')||['.','..','__proto__','prototype','constructor'].includes(id))reject('DOMAIN_IDENTITY_INVALID',400);
 if(!['write','patch','delete'].includes(operation)||next.schoolId!==schoolId||current&&current.schoolId!==schoolId)reject('DOMAIN_SCHOOL_MISMATCH',403);
 boundedJson(next);
 if(operation==='delete'){
  if(next._syncDeleted!==true)reject('DOMAIN_DELETE_UNVERIFIED',400);
  if(collection==='teacher_salary'&&current&&!current._syncDeleted&&current.netPaise!==undefined&&
     (Number(current.paidPaise??0)>0||current.salaryLocked===true||salaryEvents(current.salaryLockHistory).length||salaryEvents(current.payments).length||salaryEvents(current.paymentCorrections).length))reject('SALARY_HISTORY_IMMUTABLE');
  return;
 }
 if(next._syncDeleted===true)reject('DOMAIN_INVALID_WRITE',400);
 if(collection==='teacher_salary')validateSalaryLedger(current,next);
 // A correction edits the original event. It cannot reassign a prior person's
 // payment/payroll history to another generation under the same event key.
 if(current&&!current._syncDeleted&&['fee_payments','fee_ledger','teacher_salary'].includes(collection)){
  const keys=collection==='teacher_salary'?['teacherId','personId','staffId','employeeId']:['personId'];
  for(const key of keys)if(current[key]!=null&&next[key]!==current[key]){
   // The existing Script permits first-time assignment of a formerly blank
   // legacy employee ID, solely from the sealed staff directory's exact row.
   if(key==='employeeId'&&!String(current[key]).trim()&&current.staffId===next.staffId&&nonempty(next.staffId)){
    const staff=owned(schoolId,readOwner('staff_payroll_directory',next.staffId));
    if(staff.employeeId===next.employeeId)continue;
   }
   reject('DOMAIN_HISTORY_OWNER_IMMUTABLE');
  }
 }
 const studentRole=next.ownerRole==='student'||next.role==='student';
 const teacherRole=next.ownerRole==='teacher'||next.role==='teacher'||['teacher_salary','teacher_attendance','teacher_schedules'].includes(collection);
 if(studentRole&&teacherRole)reject('DOMAIN_OWNER_ROLE_CONFLICT');
 if(nonempty(next.studentId)&&!teacherRole){
  const parent=owned(schoolId,readOwner('students_directory',next.studentId));
  if(parent._syncDeleted===true||parent.deleted===true)reject('DOMAIN_STUDENT_GENERATION_DELETED');
  const retired=parent._syncRetiredStudentGenerations||parent.retiredGenerations;
  if(nonempty(next.personId)&&(generation(parent)!==next.personId||Array.isArray(retired)&&retired.includes(next.personId)))reject('DOMAIN_STUDENT_GENERATION_DELETED');
 }
 if(!studentRole&&(nonempty(next.teacherId)||teacherRole&&nonempty(next.personId))){
  // Same-generation historical salary corrections remain valid after teacher
  // retirement, exactly as VS_guardTeacherDependent; new salary rows do not.
  const history=collection==='teacher_salary'&&current&&!current._syncDeleted&&['teacherId','personId','staffId','employeeId'].every(key=>current[key]===next[key]);
  if(!history){
   const owner=owned(schoolId,readOwner('teachers_directory',String(next.teacherId||next.personId)));
   if(owner._syncDeleted===true||owner.deleted===true||owner.active===false)reject('DOMAIN_TEACHER_RETIRED');
   if(nonempty(next.teacherId)&&String(owner.teacherId||owner._syncRetiredTeacherId||owner.id)!==next.teacherId)reject('DOMAIN_TEACHER_IDENTITY_MISMATCH');
   if(teacherRole&&nonempty(next.personId)&&generation(owner)!==next.personId)reject('DOMAIN_TEACHER_RETIRED');
  }
 }
 if(collection==='teacher_salary'&&nonempty(next.staffId)){
  const history=current&&!current._syncDeleted&&['staffId','employeeId','personId','teacherId'].every(key=>current[key]===next[key]);
  if(!history){
   if(next.staffId.startsWith('teacher:')){
    const teacher=owned(schoolId,readOwner('teachers_directory',next.staffId.slice('teacher:'.length)));
    if(teacher.id!==next.staffId.slice('teacher:'.length)||teacher.active===false||teacher.inactive===true||teacher.deleted===true||teacher._syncDeleted===true)reject('DOMAIN_TEACHER_RETIRED');
    if(!nonempty(next.teacherId)||String(teacher.teacherId||teacher.id)!==next.teacherId||next.employeeId!==next.teacherId)reject('DOMAIN_TEACHER_IDENTITY_MISMATCH');
   }else{
    const staff=owned(schoolId,readOwner('staff_payroll_directory',next.staffId));
    if(staff.active===false||staff.deleted===true||staff._syncDeleted===true)reject('DOMAIN_STAFF_RETIRED');
    if(nonempty(staff.employeeId)&&staff.employeeId!==next.employeeId)reject('DOMAIN_STAFF_IDENTITY_MISMATCH');
   }
  }
 }
 // An explicit person ID without a parent binding cannot borrow a different
 // child's lifecycle. Legacy unlinked administrative rows retain their shape.
 if(nonempty(next.personId)&&studentRole&&!nonempty(next.studentId))reject('DOMAIN_PARENT_NOT_READY',412);
}

export interface PersonCandidate extends Omit<DomainCandidate,'readOwner'> {
 // Peers are sealed, school-scoped lifecycle metadata. No names/photos/contact
 // fields are necessary for identity uniqueness or retired-generation fences.
 readPeers:(collection:string)=>Iterable<Json>;
}
export const personCollections=new Set(['students_directory','teachers_directory']);
function slot(data:Json|null):string|null {
 if(!data||data._syncDeleted||data.deleted)return null;
 const cls=data.studentClass===undefined?data.class:data.studentClass,section=data.section===undefined?'':data.section,roll=data.rollNo;
 if(typeof cls!=='string'||!cls.trim()||typeof section!=='string'||!(typeof roll==='string'||typeof roll==='number')||typeof roll==='number'&&(!Number.isSafeInteger(roll)||roll<0)||!String(roll).trim())return null;
 return JSON.stringify([cls.trim(),section.trim(),String(roll).trim()]);
}
export function validatePersonCandidate(input:PersonCandidate):void {
 const {schoolId,collection,id,operation,current,next,readPeers}=input;
 if(!personCollections.has(collection))reject('PERSON_COLLECTION_NOT_ADMITTED',412);
 if(!/^vs-[a-f0-9]{32}$/.test(schoolId)||!nonempty(id)||id.includes('/')||['.','..','__proto__','prototype','constructor'].includes(id))reject('PERSON_IDENTITY_INVALID',400);
 if(next.schoolId!==schoolId||current&&current.schoolId!==schoolId||next.id!==undefined&&next.id!==id)reject('PERSON_FOREIGN_RECORD',403);
 if(!['write','patch','delete'].includes(operation))reject('PERSON_OPERATION_INVALID',400);
 boundedJson(next);
 if(operation==='delete'){
  if(next._syncDeleted!==true)reject('PERSON_DELETE_UNVERIFIED',400);
  return;
 }
 if(next._syncDeleted===true)reject('PERSON_INVALID_WRITE',400);
 const oldGeneration=current?(generation(current)||id):null;
 if(collection==='students_directory'){
  if(typeof next.mobileStableId!=='string'||!/^p-[a-f0-9]{32,64}$/.test(next.mobileStableId))reject('PERSON_GENERATION_INVALID',400);
  if(current&&oldGeneration!==next.mobileStableId&&next.replacesStudentGeneration!==oldGeneration)reject('PERSON_GENERATION_REPLACEMENT_REQUIRED');
  const retired=current?._syncRetiredStudentGenerations||current?.retiredGenerations;
  if(Array.isArray(retired)&&retired.includes(next.mobileStableId))reject('PERSON_GENERATION_RETIRED');
  if(current&&(current._syncDeleted===true||current.deleted===true)&&oldGeneration===next.mobileStableId)reject('PERSON_GENERATION_RETIRED');
  const nextSlot=slot(next),oldSlot=slot(current);
  for(const peer of readPeers('students_directory')){
   if(peer.schoolId!==schoolId)reject('PERSON_FOREIGN_OWNER',403);
   // Like the Script, preserve unrelated edits to pre-existing duplicated
   // legacy slots; a newly assigned duplicate slot is always rejected.
   if(peer.id!==id&&nextSlot!==null&&slot(peer)===nextSlot&&nextSlot!==oldSlot)reject('PERSON_STUDENT_SLOT_CONFLICT');
  }
 }else{
  const employee=String(next.teacherId||id).trim().toLowerCase(),nextGeneration=next.mobileStableId||id;
  if(!employee||employee.length>200||!nonempty(nextGeneration))reject('PERSON_GENERATION_INVALID',400);
  if(current&&(oldGeneration!==nextGeneration||String(current.teacherId||current._syncRetiredTeacherId||id)!==String(next.teacherId||id)))reject('PERSON_TEACHER_REASSIGNMENT_REQUIRES_REVIEW');
  for(const peer of readPeers('teachers_directory')){
   if(peer.schoolId!==schoolId)reject('PERSON_FOREIGN_OWNER',403);
   if(peer.id!==id&&String(peer.teacherId||peer._syncRetiredTeacherId||peer.id).trim().toLowerCase()===employee)reject('PERSON_PAYROLL_IDENTITY_CONFLICT');
  }
  for(const peer of readPeers('staff_payroll_directory')){
   if(peer.schoolId!==schoolId)reject('PERSON_FOREIGN_OWNER',403);
   if(String(peer.employeeId||'').trim().toLowerCase()===employee)reject('PERSON_PAYROLL_IDENTITY_CONFLICT');
  }
 }
}
