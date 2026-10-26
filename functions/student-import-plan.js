'use strict';
const {createHash}=require('node:crypto');
const MAX_ROWS=1000;
const FIELDS=new Set(['schoolId','studentId','name','class','section','rollNo','expectedRevision']);
const dangerous=new Set(['__proto__','prototype','constructor']);
function plain(value){return value!==null&&typeof value==='object'&&!Array.isArray(value)&&[Object.prototype,null].includes(Object.getPrototypeOf(value));}
function canonical(value){if(Array.isArray(value))return '['+value.map(canonical).join(',')+']';if(plain(value))return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical(value[k])).join(',')+'}';return JSON.stringify(value);}
function digest(value){return createHash('sha256').update(canonical(value)).digest('hex');}
function text(v,max){return typeof v==='string'&&v.trim().length>0&&v.length<=max&&!/[\u0000-\u001f\u007f]/.test(v);}
function roll(v){return typeof v==='number'&&Number.isSafeInteger(v)&&v>=0?String(v):v;}
function section(v){return typeof v==='string'&&v.length<=100&&!/[\u0000-\u001f\u007f]/.test(v);}
function id(v){return text(v,200)&&v===v.trim()&&!/[\/\\]/.test(v)&&!dangerous.has(v)&&!['.','..'].includes(v);}
/** Preview foundation only. No API, authorization grant, provider read or write.
 * Current records must be an authoritative school-scoped snapshot supplied by
 * the caller. A future authorized commit must recheck every baseline revision.
 */
function planStudentImport({schoolId,rows,currentRecords}={}){
 if(!id(schoolId))throw new TypeError('Explicit school identity required');
 if(!Array.isArray(rows)||rows.length<1||rows.length>MAX_ROWS)throw new TypeError('Import requires 1–1000 rows');
 if(!Array.isArray(currentRecords)||currentRecords.length>100000)throw new TypeError('Bounded authoritative snapshot required');
 const existing=new Map(),slots=new Map(),warnings=[];
 for(const original of currentRecords){
  if(!plain(original)||Object.keys(original).some(k=>dangerous.has(k))||original.schoolId!==schoolId||!id(original.studentId)||!text(original.revision,200))throw new TypeError('Invalid or foreign authoritative snapshot');
  const r={...original,section:original.section??'',rollNo:roll(original.rollNo)};
  if(existing.has(r.studentId))throw new TypeError('Duplicate authoritative student ID');
  existing.set(r.studentId,r);
  if(r.deleted===true)continue;
  if(!text(r.class,100)||!section(r.section)||!text(r.rollNo,40)){warnings.push({code:'LEGACY_SLOT_UNMEASURED',studentId:r.studentId});continue;}
  const slot=canonical([r.class.trim(),r.section.trim(),r.rollNo.trim()]);
  if(!slots.has(slot))slots.set(slot,new Set());slots.get(slot).add(r.studentId);
 }

 const errors=[],operations=[],seen=new Set(),inputSlots=new Set();
 rows.forEach((raw,index)=>{
  const r=plain(raw)?{...raw,section:raw.section??'',rollNo:roll(raw.rollNo)}:raw;
  const issue=code=>errors.push({row:index+1,code});
  if(!plain(r)){issue('INVALID_ROW');return;}
  const keys=Object.keys(r);
  if(keys.some(k=>dangerous.has(k))){issue('UNSAFE_KEY');return;}
  if(keys.some(k=>!FIELDS.has(k))){issue('UNSUPPORTED_FIELD');return;}
  if(r.schoolId!==schoolId){issue('FOREIGN_SCHOOL');return;}
  if(!id(r.studentId)||!text(r.name,300)||!text(r.class,100)||!section(r.section)||!text(r.rollNo,40)){issue('INVALID_STUDENT_FIELDS');return;}
  if(seen.has(r.studentId)){issue('DUPLICATE_STUDENT_ID');return;}seen.add(r.studentId);
  const record={schoolId,studentId:r.studentId,name:r.name.trim(),class:r.class.trim(),section:r.section.trim(),rollNo:r.rollNo.trim()};
  const slot=canonical([record.class,record.section,record.rollNo]);
  if(inputSlots.has(slot)){issue('DUPLICATE_CLASS_ROLL');return;}inputSlots.add(slot);
  if(slots.has(slot)&&(slots.get(slot).size>1||!slots.get(slot).has(r.studentId))){issue('EXISTING_CLASS_ROLL');return;}
  const prior=existing.get(r.studentId),expected=r.expectedRevision;
  if(prior?.deleted===true){issue('TOMBSTONE_REQUIRES_RESTORE');return;}
  if(prior ? expected!==prior.revision : expected!==null){issue('REVISION_CONFLICT');return;}
  if(prior&&['name','class','section','rollNo'].every(k=>prior[k]===record[k]))return;
  const operation={protocol:'student-import-preview-v1',schoolId,studentId:r.studentId,kind:prior?'update':'create',expectedRevision:prior?prior.revision:null,record};
  operations.push({...operation,operationId:digest(operation)});
 });
 operations.sort((a,b)=>a.studentId.localeCompare(b.studentId,'en'));
 // Invalid batches never expose an executable subset.
 const proposed=errors.length?[]:operations;
 return {previewOnly:true,committable:false,valid:errors.length===0,schoolId,rowCount:rows.length,errors,warnings,uniquenessScope:warnings.length?'partial-legacy':'measured-active-slots',operations:proposed,planId:digest({protocol:'student-import-preview-v1',schoolId,operations:proposed,errors})};
}
module.exports={planStudentImport,MAX_ROWS,canonicalHash:digest};
