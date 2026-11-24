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
function stableJson(value:unknown):string {
 if(Array.isArray(value))return '['+value.map(stableJson).join(',')+']';
 if(value&&typeof value==='object'){
  const object=value as Record<string,unknown>,keys=Object.keys(object).sort();
  return '{'+keys.map(key=>JSON.stringify(key)+':'+stableJson(object[key])).join(',')+'}';
 }
 return JSON.stringify(value)??'null';
}
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
 if(current&&current.feeBillingPolicyVersion===1&&next.feeBillingPolicyVersion!==1)
  reject('DOMAIN_FEE_BILLING_VERSION_IMMUTABLE');
 if(['fee_payments','fee_ledger'].includes(collection)&&
    (next.feeBillingPolicyVersion===1||next.feeFrequencies!==undefined)){
  if(next.feeBillingPolicyVersion!==1)
   reject('DOMAIN_FEE_BILLING_VERSION_REQUIRED',400);
  const rawItems=next.feeItems,rawFrequencies=next.feeFrequencies;
  if(!rawItems||typeof rawItems!=='object'||Array.isArray(rawItems)||
     !rawFrequencies||typeof rawFrequencies!=='object'||Array.isArray(rawFrequencies)||
     !nonempty(next.studentId)||!nonempty(next.personId)||
     typeof next.month!=='string'||!/^\\d{4}-(0[1-9]|1[0-2])$/.test(next.month))
   reject('DOMAIN_FEE_BILLING_SNAPSHOT_INVALID',400);
  const items=rawItems as Record<string,unknown>;
  const frequencies=rawFrequencies as Record<string,unknown>;
  if(Object.keys(items).length===0||
     Object.keys(items).some(head=>!Object.hasOwn(frequencies,head))||
     Object.keys(frequencies).some(head=>!Object.hasOwn(items,head)))
   reject('DOMAIN_FEE_BILLING_SNAPSHOT_INVALID',400);
  const paise=(value:unknown):value is number=>typeof value==='number'&&
   Number.isFinite(value)&&Math.abs(value*100-Math.round(value*100))<=0.000001;
  const expected=next.expectedAmount,totalPaid=next.totalPaid,balance=next.balance;
  if(!paise(expected)||expected<=0||!paise(totalPaid)||totalPaid<=0||
     !paise(balance)||balance<0||Math.abs(expected-totalPaid-balance)>0.001||
     next.status!==(totalPaid===expected?'PAID':'PARTIAL'))
   reject('DOMAIN_FEE_TOTALS_INVALID',400);
  const installment=next.installmentAmount;
  if(collection==='fee_payments'&&(!paise(installment)||installment<=0||installment>totalPaid))
   reject('DOMAIN_FEE_INSTALLMENT_INVALID',400);
  if(collection==='fee_ledger'&&!nonempty(next.lastPaymentId))
   reject('DOMAIN_FEE_LAST_PAYMENT_MISSING',400);
  let itemTotal=0;
  for(const [head,amount] of Object.entries(items)){
   if(!nonempty(head)||!paise(amount)||amount<0)
    reject('DOMAIN_FEE_BILLING_SNAPSHOT_INVALID',400);
   itemTotal+=amount;
   const frequency=frequencies[head];
   if(!['monthly','annual','once'].includes(String(frequency)))
    reject('DOMAIN_FEE_BILLING_FREQUENCY_INVALID',400);
   // Zero-value heads are descriptive snapshots, not admission charges.
   // A positive once-only amount must still match the authoritative owner.
   if(frequency==='once'&&amount>0){
    const parent=owned(schoolId,readOwner('students_directory',next.studentId));
    const ownerGeneration=generation(parent);
    if(parent.feeAdmissionPersonId!==ownerGeneration||
       parent.feeAdmissionMonth!==next.month||
       next.personId!==ownerGeneration||
       next.feeAdmissionPersonId!==parent.feeAdmissionPersonId||
       next.feeAdmissionMonth!==parent.feeAdmissionMonth)
     reject('DOMAIN_FEE_ONCE_NOT_AUTHORIZED');
   }
  }
  if(Math.abs(itemTotal-expected)>0.001)
   reject('DOMAIN_FEE_ITEMS_TOTAL_MISMATCH',400);
  if(collection==='fee_ledger'&&current&&current.feeBillingPolicyVersion===1){
   const previousPaid=current.totalPaid;
   if(!paise(previousPaid)||current.expectedAmount!==expected||
      stableJson(current.feeItems)!==stableJson(items)||
      stableJson(current.feeFrequencies)!==stableJson(frequencies)||
      totalPaid<previousPaid)
    reject('DOMAIN_FEE_LEDGER_TERMS_IMMUTABLE');
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

/**
 * Record-only payment + monthly ledger pair preflight for the atomic owner.
 * The caller MUST supply the current ledger from its own transaction, never
 * from a client claim. This helper does not perform writes or enable a route.
 */
export function validateRecordOnlyFeePair(input:{
 schoolId:string;paymentId:string;payment:Json;ledger:Json;currentLedger:Json|null;
}):void {
 const {schoolId,paymentId,payment,ledger,currentLedger}=input;
 if(!/^vs-[a-f0-9]{32}$/.test(schoolId)||!nonempty(paymentId)||
    payment.schoolId!==schoolId||ledger.schoolId!==schoolId||
    currentLedger&&currentLedger.schoolId!==schoolId)
  reject('DOMAIN_FEE_PAIR_SCHOOL_MISMATCH',403);
 if(payment.feeBillingPolicyVersion!==1||ledger.feeBillingPolicyVersion!==1||
    payment.paymentId!==paymentId||ledger.lastPaymentId!==paymentId||
    !nonempty(payment.personId)||!nonempty(payment.studentId)||
    !nonempty(payment.feeIdentity)||
    typeof payment.month!=='string'||!/^\d{4}-(0[1-9]|1[0-2])$/.test(payment.month)||
    Boolean(payment.receiptDocumentId)||Boolean(ledger.receiptDocumentId))
  reject('DOMAIN_FEE_PAIR_INVALID',400);
 for(const key of ['personId','studentId','feeIdentity','month','expectedAmount',
   'totalPaid','balance','status','feeItems','feeFrequencies','feeAdmissionMonth',
   'feeAdmissionPersonId']){
  if(stableJson(payment[key])!==stableJson(ledger[key]))
   reject('DOMAIN_FEE_PAIR_MISMATCH');
 }
 const paise=(raw:unknown):number=>{
  if(typeof raw!=='number'||!Number.isFinite(raw)||raw<0||
     !Number.isSafeInteger(Math.round(raw*100))||
     Math.abs(raw*100-Math.round(raw*100))>0.000001)
   reject('DOMAIN_FEE_PAIR_AMOUNT_INVALID',400);
  return Math.round(raw*100);
 };
 const expected=paise(payment.expectedAmount),total=paise(payment.totalPaid),
   installment=paise(payment.installmentAmount),balance=paise(payment.balance);
 if(expected<=0||installment<=0||total>expected||total+balance!==expected||
    payment.status!==(total===expected?'PAID':'PARTIAL'))
  reject('DOMAIN_FEE_PAIR_AMOUNT_INVALID',400);
 if(currentLedger){
  // Unbound legacy ledgers require explicit reconciliation before adoption.
  if(currentLedger._syncDeleted===true||currentLedger.deleted===true||
     currentLedger.personId!==payment.personId||
     currentLedger.feeIdentity!==payment.feeIdentity||
     currentLedger.month!==payment.month||
     paise(currentLedger.expectedAmount)!==expected||
     stableJson(currentLedger.feeItems)!==stableJson(payment.feeItems)||
     currentLedger.feeBillingPolicyVersion!==1||
     stableJson(currentLedger.feeFrequencies)!==stableJson(payment.feeFrequencies))
   reject('DOMAIN_FEE_PAIR_LEDGER_CHANGED');
 }
 const previous=currentLedger?paise(currentLedger.totalPaid):0;
 if(previous>expected||previous+installment!==total)
  reject('DOMAIN_FEE_PAIR_STALE_BALANCE');
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
  const admissionMonth=next.feeAdmissionMonth;
  const admissionPerson=next.feeAdmissionPersonId;
  const hasAdmissionMonth=admissionMonth!==undefined&&admissionMonth!==null&&admissionMonth!=='';
  const hasAdmissionPerson=admissionPerson!==undefined&&admissionPerson!==null&&admissionPerson!=='';
  if(hasAdmissionMonth!==hasAdmissionPerson||
     hasAdmissionMonth&&(
      typeof admissionMonth!=='string'||!/^20\d{2}-(0[1-9]|1[0-2])$|^2100-(0[1-9]|1[0-2])$/.test(admissionMonth)||
      admissionPerson!==next.mobileStableId))
   reject('PERSON_FEE_ADMISSION_INVALID',400);
  // A first admission month is recorded once for this exact person generation.
  // Profile edits cannot move, clear, or reassign an already authorized month.
  if(current&&oldGeneration===next.mobileStableId&&
     ((current.feeAdmissionMonth!==undefined&&current.feeAdmissionMonth!==null&&current.feeAdmissionMonth!=='')||
      (current.feeAdmissionPersonId!==undefined&&current.feeAdmissionPersonId!==null&&current.feeAdmissionPersonId!==''))&&
     (next.feeAdmissionMonth!==current.feeAdmissionMonth||
      next.feeAdmissionPersonId!==current.feeAdmissionPersonId))
   reject('PERSON_FEE_ADMISSION_IMMUTABLE');
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
