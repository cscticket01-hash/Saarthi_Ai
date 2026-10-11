'use strict';
const {createHash}=require('node:crypto');
const MAX_ROWS=1000;
const FIELDS=new Set(['schoolId','studentId','name','class','section','rollNo','expectedRevision']);
const dangerous=new Set(['__proto__','prototype','constructor']);
function plain(value){return value!==null&&typeof value==='object'&&!Array.isArray(value)&&[Object.prototype,null].includes(Object.getPrototypeOf(value));}
function canonical(value){if(Array.isArray(value))return '['+value.map(canonical).join(',')+']';if(plain(value))return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical(value[k])).join(',')+'}';return JSON.stringify(value);}
function digest(value){return createHash('sha256').update(canonical(value)).digest('hex');}
function text(v,max){return typeof v==='string'&&v.trim().length>0&&v.length<=max&&!/[\u0000-\u001f\u007f]/.test(v);}
function id(v){return text(v,200)&&v===v.trim()&&!/[\/\\]/.test(v)&&!dangerous.has(v);}
/** Preview foundation only. No API, authorization grant, provider read or write.
 * Current records must be an authoritative school-scoped snapshot supplied by
 * the caller. A future authorized commit must recheck every baseline revision.
 */
function planStudentImport({schoolId,rows,currentRecords}={}){
 if(!id(schoolId))throw new TypeError('Explicit school identity required');
 if(!Array.isArray(rows)||rows.length<1||rows.length>MAX_ROWS)throw new TypeError('Import requires 1–1000 rows');
 if(!Array.isArray(currentRecords)||currentRecords.length>100000)throw new TypeError('Bounded authoritative snapshot required');
 const existing=new Map(),slots=new Map();
 for(const r of currentRecords){
  if(!plain(r)||Object.keys(r).some(k=>dangerous.has(k))||r.schoolId!==schoolId||!id(r.studentId)||!text(r.revision,200)||!text(r.class,100)||!text(r.section,100)||!text(r.rollNo,40))throw new TypeError('Invalid or foreign authoritative snapshot');
  if(existing.has(r.studentId))throw new TypeError('Duplicate authoritative student ID');
  const slot=canonical([r.class.trim(),r.section.trim(),r.rollNo.trim()]);
  if(slots.has(slot))throw new TypeError('Ambiguous authoritative class/section/roll');
  slots.set(slot,r.studentId);existing.set(r.studentId,r);
 }
 const errors=[],operations=[],seen=new Set(),inputSlots=new Set();
 rows.forEach((r,index)=>{
  const issue=code=>errors.push({row:index+1,code});
  if(!plain(r)){issue('INVALID_ROW');return;}
  const keys=Object.keys(r);
  if(keys.some(k=>dangerous.has(k))){issue('UNSAFE_KEY');return;}
  if(keys.some(k=>!FIELDS.has(k))){issue('UNSUPPORTED_FIELD');return;}
  if(r.schoolId!==schoolId){issue('FOREIGN_SCHOOL');return;}
  if(!id(r.studentId)||!text(r.name,300)||!text(r.class,100)||!text(r.section,100)||!text(r.rollNo,40)){issue('INVALID_STUDENT_FIELDS');return;}
  if(seen.has(r.studentId)){issue('DUPLICATE_STUDENT_ID');return;}seen.add(r.studentId);
  const record={schoolId,studentId:r.studentId,name:r.name.trim(),class:r.class.trim(),section:r.section.trim(),rollNo:r.rollNo.trim()};
  const slot=canonical([record.class,record.section,record.rollNo]);
  if(inputSlots.has(slot)){issue('DUPLICATE_CLASS_ROLL');return;}inputSlots.add(slot);
  if(slots.has(slot)&&slots.get(slot)!==r.studentId){issue('EXISTING_CLASS_ROLL');return;}
  const prior=existing.get(r.studentId),expected=r.expectedRevision;
  if(prior ? expected!==prior.revision : expected!==null){issue('REVISION_CONFLICT');return;}
  if(prior&&['name','class','section','rollNo'].every(k=>prior[k]===record[k]))return;
  const operation={protocol:'student-import-preview-v1',schoolId,studentId:r.studentId,kind:prior?'update':'create',expectedRevision:prior?prior.revision:null,record};
  operations.push({...operation,operationId:digest(operation)});
 });
 operations.sort((a,b)=>a.studentId.localeCompare(b.studentId,'en'));
 // Invalid batches never expose an executable subset.
 const proposed=errors.length?[]:operations;
 return {previewOnly:true,committable:false,valid:errors.length===0,schoolId,rowCount:rows.length,errors,operations:proposed,planId:digest({protocol:'student-import-preview-v1',schoolId,operations:proposed,errors})};
}
module.exports={planStudentImport,MAX_ROWS};
