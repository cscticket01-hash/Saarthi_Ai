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
 // Fixed diagnostic category only; never log record contents or identifiers.
 console.warn('DOMAIN_POLICY_REJECT_'+code);
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
export function validateDomainCandidate(input:DomainCandidate):void {
 const {schoolId,collection,id,operation,current,next,readOwner}=input;
 if(!domainCollections.has(collection))reject('DOMAIN_COLLECTION_NOT_ADMITTED',412);
 if(!/^vs-[a-f0-9]{32}$/.test(schoolId)||!nonempty(id)||id.includes('/')||['.','..','__proto__','prototype','constructor'].includes(id))reject('DOMAIN_IDENTITY_INVALID',400);
 if(!['write','patch','delete'].includes(operation)||next.schoolId!==schoolId||current&&current.schoolId!==schoolId)reject('DOMAIN_SCHOOL_MISMATCH',403);
 boundedJson(next);
 if(operation==='delete'){
  if(next._syncDeleted!==true)reject('DOMAIN_DELETE_UNVERIFIED',400);
  return;
 }
 if(next._syncDeleted===true)reject('DOMAIN_INVALID_WRITE',400);
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
   const staff=owned(schoolId,readOwner('staff_payroll_directory',next.staffId));
   if(staff.active===false||staff.deleted===true||staff._syncDeleted===true)reject('DOMAIN_STAFF_RETIRED');
   if(nonempty(staff.employeeId)&&staff.employeeId!==next.employeeId)reject('DOMAIN_STAFF_IDENTITY_MISMATCH');
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
