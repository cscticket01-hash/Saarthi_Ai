'use strict';
const {createHash}=require('node:crypto');
const {canonical}=require('./live-sync-canonical');
const STUDENT_CHILDREN=['documents','attendance_records','attendance_logs','fee_ledger','fee_payments','exam_results','exam_center_results','student_scan_index','mobile_sessions','mobile_users','mobile_complaints'];
const hash=value=>createHash('sha256').update(canonical(value)).digest('hex');
const fail=(status,code)=>{throw Object.assign(Error('Person lifecycle verification is pending; saved changes are retained.'),{status,code,publicMessage:true});};
const validId=v=>typeof v==='string'&&v.length>0&&v.length<=200&&!v.includes('/')&&!['.','..','__proto__','prototype','constructor'].includes(v);
const business=record=>Object.fromEntries(Object.entries(record).filter(([key])=>key!=='id'&&!key.startsWith('_sync')));
function studentOwns(collection,id,data,generation,aliases){
 if(!data||data._syncDeleted)return false;
 if(data.personId!=null)return data.personId===generation&&data.role!=='teacher'&&data.ownerRole!=='teacher';
 if(data.role==='teacher'||data.ownerRole==='teacher')return false;
 if(collection==='mobile_users'&&id===createHash('sha256').update('student/'+generation).digest('hex'))return true;
 return ['studentId','studentDocId','studentDocumentId','documentId','oldStudentId','previousStudentId'].some(k=>typeof data[k]==='string'&&aliases.includes(data[k]))||collection==='student_scan_index'&&aliases.includes(id);
}

function teacherOwns(collection,id,data,generation,parentId,teacherId){
 if(!data||data._syncDeleted||data.role==='student'||data.ownerRole==='student')return false;
 if(data.personId!=null)return data.personId===generation&&(data.role==='teacher'||data.ownerRole==='teacher'||typeof data.teacherId==='string');
 if(collection==='mobile_users'&&id===createHash('sha256').update('teacher/'+generation).digest('hex'))return true;
 return data.teacherId===teacherId||data.teacherDocumentId===parentId||collection==='mobile_sessions'&&data.role==='teacher'&&data.documentId===parentId;
}

function createLivePersonLifecycle({db,rpc,now=Date.now,maxChildren=1000}){
 if(typeof rpc!=='function')throw TypeError('Authenticated school Script RPC required');
 const handled=body=>body.action==='managed_records'&&['write','delete'].includes(body.operation)&&(['students_directory','teachers_directory'].includes(body.collection)||body.collection==='school_settings'&&body.id==='staff_payroll_directory');
 async function read(school,collection,id){
  const reply=await rpc(school,{action:'managed_records',operation:'read',collection,syncProtocol:2,...(id!==undefined?{id}:{})});
  if(reply?.success!==true||reply.schoolId!==school||reply.syncProtocol!==2||!reply.records||typeof reply.records!=='object'||Array.isArray(reply.records)||id!==undefined&&reply.pointRead!==true||reply.missingRecords?.length)fail(503,'PERSON_READ_UNVERIFIED');
  for(const [key,record]of Object.entries(reply.records))if(!validId(key)||!record||record.schoolId!==school||record.id!==undefined&&record.id!==key||typeof record._syncRevision!=='string'||!record._syncRevision||/^(live-|cf-)/.test(record._syncRevision))fail(503,'PERSON_READ_UNVERIFIED');
  return id===undefined?reply.records:reply.records[id]||null;
 }
 async function plan(school,body,parent){
  const student=body.collection==='students_directory',teacher=body.collection==='teachers_directory';
  if(!student&&!teacher&&body.data?._syncFieldPatch){
   const patch=body.data._syncFieldPatch;
   if(!parent||parent._syncDeleted||patch.version!==1||!patch.set||typeof patch.set!=='object'||Array.isArray(patch.set)||!Array.isArray(patch.remove)||patch.remove.some(key=>typeof key!=='string'||key.startsWith('_sync')||['id','schoolId','createdAt'].includes(key))||Object.keys(patch.set).some(key=>key.startsWith('_sync')||['id','schoolId','createdAt'].includes(key)))fail(409,'STAFF_DIRECTORY_PATCH_INVALID');
   const data={...parent,...patch.set};for(const key of patch.remove)delete data[key];
   body={...body,data};
  }
  const oldGeneration=parent?(student?parent._syncDeletedOwner||parent.mobileStableId||body.id:teacher?parent._syncDeletedOwner||parent.mobileStableId||body.id:body.id):'';
  let generation=oldGeneration,retiring=false,kind=student?'student':teacher?'teacher':'staff';
  if(body.operation==='write'){
   if(!body.data||body.data.schoolId!==school||typeof body.data!=='object'||Array.isArray(body.data))fail(400,'PERSON_IDENTITY_INVALID');
   if(body.data.id!==undefined&&body.data.id!==body.id)fail(400,'PERSON_IDENTITY_INVALID');
   if(body.data._syncFieldPatch){
    if(!student&&!teacher)fail(409,'STAFF_DIRECTORY_REQUIRES_FULL_CAS');
    // Preserve the existing field-revision owner; generation changes may never
    // be smuggled through a field patch. The Script verifies other fields.
    const patch=body.data._syncFieldPatch;
    if(!parent||parent._syncDeleted||patch.version!==1||!patch.set||typeof patch.set!=='object'||!Array.isArray(patch.remove)||[...Object.keys(patch.set),...patch.remove].some(k=>['mobileStableId','teacherId','replacesStudentGeneration'].includes(k)))fail(409,'PERSON_GENERATION_PATCH_REJECTED');
    retiring=teacher&&!parent._syncDeleted&&patch.set.active===false;
   }else if(student){
    generation=body.data.mobileStableId;
    if(typeof generation!=='string'||!/^p-[a-f0-9]{32,64}$/.test(generation))fail(400,'PERSON_GENERATION_INVALID');
    if(parent&&oldGeneration!==generation){
     if(body.data.replacesStudentGeneration!==oldGeneration)fail(409,'PERSON_GENERATION_REPLACEMENT_REQUIRED');
     retiring=!parent._syncDeleted;
    }
   }else if(teacher){
    generation=body.data.mobileStableId||body.id;
    if(typeof generation!=='string'||!generation||generation.length>200)fail(400,'PERSON_GENERATION_INVALID');
    // Existing teacher identity has no generation cascade in GS. Keep the
    // identity immutable instead of silently reassigning salary/documents.
    if(parent&&(oldGeneration!==generation||(parent.teacherId||parent._syncRetiredTeacherId||body.id)!==(body.data.teacherId||body.id)))fail(409,'TEACHER_IDENTITY_REPLACEMENT_REQUIRES_REVIEW');
    retiring=!!parent&&!parent._syncDeleted&&body.data.active===false;
   }else{
    if(!Array.isArray(body.data.staff)||body.data.staff.length>1000)fail(400,'STAFF_DIRECTORY_INVALID');
    const ids=new Set(),employees=new Set(),teachers=await read(school,'teachers_directory');
    const teacherIds=new Set(Object.entries(teachers).map(([id,r])=>String(r.teacherId||r._syncRetiredTeacherId||id).trim().toLowerCase()));
    for(const row of body.data.staff){
     const employee=String(row?.employeeId||'').trim().toLowerCase();
     if(!row||!validId(row.id)||ids.has(row.id)||employee&&(employee.length>60||employees.has(employee)||teacherIds.has(employee)))fail(409,'STAFF_EMPLOYEE_ID_CONFLICT');
     ids.add(row.id);if(employee)employees.add(employee);
    }
    for(const previous of parent?.staff||[]){
     const current=body.data.staff.find(row=>row.id===previous.id);
     if(!current||String(previous.employeeId||'').trim()&&current.employeeId!==previous.employeeId)fail(409,'STAFF_IDENTITY_RETIREMENT_REQUIRES_REVIEW');
    }
   }
  }else{
   if(!parent)fail(409,'PERSON_DELETE_BASELINE_REQUIRED');
   if(!student&&!teacher)fail(409,'PERSON_RETIREMENT_DOMAIN_REQUIRED');
   if(student&&body.deletedStudentGeneration!==oldGeneration||teacher&&body.deletedTeacherGeneration!==undefined&&body.deletedTeacherGeneration!==oldGeneration)fail(409,'PERSON_DELETE_GENERATION_REQUIRED');
   retiring=!parent._syncDeleted;
  }
  if((parent?._syncRevision||'')!==body.expectedRecordRevision)fail(409,'RECORD_REVISION_CONFLICT');
  if((student||teacher)&&retiring||kind==='staff'){
   const capability=await rpc(school,{action:'managed_health'});
   if(capability?.success!==true||capability.schoolId!==school||capability.recordSyncVersion!==2||(student?(capability.sheetLifecycleVersion===1&&capability.recordJsonBackupVersion===0?1:0):teacher?capability.teacherRetirementVersion:capability.staffRetirementVersion)!==1)fail(412,'PERSON_RETIREMENT_UPGRADE_REQUIRED');
  }
  const children=[];
  if((student||teacher)&&retiring){
   const aliases=[body.id,...(Array.isArray(parent.previousStudentIds)?parent.previousStudentIds:[])];
   for(const collection of student?STUDENT_CHILDREN:['documents','teacher_schedules','mobile_sessions','mobile_users']){
    const records=await read(school,collection);
    for(const [id,data]of Object.entries(records))if(student?studentOwns(collection,id,data,oldGeneration,aliases):teacherOwns(collection,id,data,oldGeneration,body.id,parent.teacherId||body.id)){
     children.push({collection,id,revision:data._syncRevision});
     if(children.length>maxChildren)fail(413,'PERSON_CASCADE_TOO_LARGE');
    }
   }
  }
  return {kind,generation,retiredGeneration:retiring?oldGeneration:null,parentWasDeleted:parent?._syncDeleted===true,children};
 }
 function deleteReceipt(school,body,record,ack){
  const canonical=ack?.record,targets=ack?.deletionTargets;
  if(ack?.success!==true||ack.schoolId!==school||ack.syncProtocol!==2||
     ack.deleteEverywhereVersion!==1||ack.driveDeletionComplete!==true||ack.firebaseDeletionComplete!==true||
     !record||record._syncDeleted!==true||record._syncOperationId!==body.operationId||
     ack.recordRevision!==record._syncRevision||!canonical||canonical.schoolId!==school||
     canonical.id!==undefined&&canonical.id!==body.id||canonical._syncDeleted!==true||
     canonical._syncRevision!==record._syncRevision||canonical._syncOperationId!==body.operationId||
     canonical._syncDeletedOwner!==record._syncDeletedOwner||canonical._syncErasePlan?.complete!==true||
     !Array.isArray(targets)||targets.length<1||targets.length>5000||
     JSON.stringify(canonical._syncErasePlan.targets)!==JSON.stringify(targets)||
     !targets.some(target=>target.collection===body.collection&&target.id===body.id&&target.revision===record._syncRevision))
   fail(503,'PERSON_DELETE_RECEIPT_UNVERIFIED');
  return ack;
 }
 function validate(school,body){
  if(!/^vs-[a-f0-9]{32}$/.test(school)||!handled(body)||!validId(body.id)||body.syncProtocol!==2||!/^[A-Za-z0-9_-]{16,100}$/.test(body.operationId||'')||typeof body.expectedRecordRevision!=='string')fail(400,'PERSON_OPERATION_INVALID');
  if(body.collection==='students_directory'&&body.operation==='write'&&body.data?.schoolId===school&&
     !body.data._syncFieldPatch&&!/^p-[a-f0-9]{32,64}$/.test(body.data.mobileStableId||''))
   fail(400,'PERSON_GENERATION_INVALID');
 }
 async function execute(school,body){
  validate(school,body);
  const ownerId=hash([school,body.collection,body.id]),operationKey=hash([school,body.operationId]);
  const ownerRef=db.doc('school_person_lifecycle_owners/'+ownerId),operationRef=db.doc('school_person_lifecycle_operations/'+operationKey);
  const fingerprint=hash(body);
  let operation=(await operationRef.get()).data();
  if(operation&&operation.fingerprint!==fingerprint)fail(409,'OPERATION_ID_CONFLICT');
  if(!operation){
   const parent=await read(school,body.collection,body.id),manifest=await plan(school,body,parent);
   operation=await db.runTransaction(async tx=>{
    const old=(await tx.get(operationRef)).data(),owner=(await tx.get(ownerRef)).data();
    if(old){if(old.fingerprint!==fingerprint)fail(409,'OPERATION_ID_CONFLICT');return old;}
    if(owner?.operationId&&owner.operationId!==body.operationId)fail(503,'PERSON_LIFECYCLE_IN_FLIGHT');
    const next={schoolId:school,collection:body.collection,id:body.id,operationId:body.operationId,fingerprint,state:'planned',startedAt:now(),...manifest};
    // Journals contain identity/revision metadata only, never names, photos,
    // contacts, request bodies or copies of cloud record payloads.
    tx.set(operationRef,next);tx.set(ownerRef,{schoolId:school,collection:body.collection,id:body.id,operationId:body.operationId,state:'fenced'});return next;
   });
  }
  if(operation.schoolId!==school||operation.collection!==body.collection||operation.id!==body.id)fail(403,'PERSON_OPERATION_IDENTITY_MISMATCH');
  const everywhere=body.operation==='delete'&&body.deleteEverywhereVersion===1;
  if(operation.state==='verified'){
   let record=await read(school,body.collection,body.id),receipt;
   // Recover the original signed completion proof, never infer Firebase/Drive
   // deletion from a lifecycle journal or replay an old delete over a new head.
   if(everywhere&&record?._syncRevision===operation.recordRevision){
    const ack=await rpc(school,body);record=await read(school,body.collection,body.id);
    receipt=deleteReceipt(school,body,record,ack);
   }
   return {...receipt,success:true,schoolId:school,syncProtocol:2,personLifecycleVersion:1,operationId:body.operationId,recordRevision:operation.recordRevision,record:record?._syncRevision===operation.recordRevision?record:null,reconcileRequired:record?._syncRevision!==operation.recordRevision};
  }
  let record=await read(school,body.collection,body.id);
  const already=record?._syncOperationId===body.operationId||body.operation==='delete'&&operation.parentWasDeleted&&record?._syncDeleted&&record._syncRevision===body.expectedRecordRevision;
  let ack;
  if(!already||everywhere)ack=await rpc(school,body);
  record=await read(school,body.collection,body.id);
  if(!record||ack&&(ack.success!==true||ack.schoolId!==school||ack.syncProtocol!==2||ack.recordRevision!==record._syncRevision)||!already&&record._syncOperationId!==body.operationId)fail(503,'PERSON_ACK_UNVERIFIED');
  if(body.operation==='delete'){
   if(record._syncDeleted!==true||record._syncDeletedOwner!==operation.generation)fail(503,'PERSON_GENERATION_UNVERIFIED');
  }else if(record._syncDeleted||operation.kind==='student'&&record.mobileStableId!==operation.generation||operation.kind==='teacher'&&(record.mobileStableId||body.id)!==operation.generation)fail(503,'PERSON_GENERATION_UNVERIFIED');
  if(body.operation==='write'&&!body.data._syncFieldPatch&&hash(business(record))!==hash(business(body.data)))fail(503,'PERSON_CONTENT_UNVERIFIED');
  for(const child of operation.children){
   const proof=await read(school,child.collection,child.id);
   if(!proof||proof._syncDeleted!==true||proof._syncDeletedOwner!==operation.retiredGeneration)fail(503,'PERSON_CASCADE_UNVERIFIED');
  }
  const receipt=everywhere?deleteReceipt(school,body,record,ack):null;
  await db.runTransaction(async tx=>{
   const current=(await tx.get(operationRef)).data(),owner=(await tx.get(ownerRef)).data();
   if(current?.fingerprint!==fingerprint||owner?.operationId!==body.operationId)fail(409,'PERSON_LIFECYCLE_STATE_CHANGED');
   tx.set(operationRef,{...current,state:'verified',recordRevision:record._syncRevision,verifiedAt:now()});
   tx.set(ownerRef,{schoolId:school,collection:body.collection,id:body.id,state:'verified',generation:operation.generation,retiredGeneration:operation.retiredGeneration});
  });
  return {...receipt,success:true,schoolId:school,syncProtocol:2,personLifecycleVersion:1,operationId:body.operationId,recordRevision:record._syncRevision,record};
 }
 async function assertDependency(school,parentId,generation){
  if(!validId(parentId)||typeof generation!=='string'||!generation)fail(400,'PERSON_DEPENDENCY_INVALID');
  const owner=(await db.doc('school_person_lifecycle_owners/'+hash([school,'students_directory',parentId])).get()).data();
  if(owner?.state==='fenced')fail(503,'PERSON_LIFECYCLE_IN_FLIGHT');
  const parent=await read(school,'students_directory',parentId);
  if(!parent||parent._syncDeleted||parent.mobileStableId!==generation)fail(409,'PERSON_GENERATION_RETIRED');
 }
 return {handled,validate,execute,assertDependency};
}
module.exports={createLivePersonLifecycle,studentOwns,STUDENT_CHILDREN};
