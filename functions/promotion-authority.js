'use strict';

/**
 * Validates one Final Exam class movement against signed, authoritative school
 * records. The broker supplies these after verified Cloudflare/Drive reads;
 * client-provided exam, marks or approval flags are never accepted as proof.
 */
const deny=(code)=>{throw Object.assign(
  Error('Final Exam promotion requires verified school records.'),
  {status:409,code,publicMessage:true});};
const cls=(value)=>{
 const found=/^Class ([1-9]|1[0-2])$/.exec(String(value??''));
 return found?Number(found[1]):0;
};
const same=(a,b)=>String(a??'')===String(b??'');

function hasChangedPromotion(old,next){
 if(!old||!next)return false;
 return old.promotionTransactionId!==next.promotionTransactionId ||
  old.classMovement!==next.classMovement ||
  old.promotionExamId!==next.promotionExamId;
}

function validatePromotionAuthority({schoolId,studentId,previous,next,exam,result,policy}){
 if(!previous||!next||!exam||!result||
    previous.schoolId!==schoolId||next.schoolId!==schoolId||
    exam.schoolId!==schoolId||result.schoolId!==schoolId||
    previous._syncDeleted===true||next._syncDeleted===true||
    previous.active===false||previous.deleted===true)
  deny('PROMOTION_SCHOOL_OR_OWNER_INVALID');
 const examId=next.promotionExamId,move=next.classMovement;
 if(typeof examId!=='string'||!examId||examId.includes('/')||
    next.promotionTransactionId!=='promotion:'+examId+':'+studentId||
    exam.examId!==examId||exam.isFinal!==true||
    exam.completed===false||['draft','scheduled','in_progress'].includes(exam.status)||
    result.examId!==undefined&&result.examId!==examId||
    result.studentId!==studentId||result._syncDeleted===true)
  deny('PROMOTION_FINAL_EXAM_INVALID');
 if(previous.mobileStableId!==next.mobileStableId||
    previous.rollNo!==next.rollNo||!same(previous.section,next.section)||
    result.personId!=null&&result.personId!==(previous.mobileStableId||studentId))
  deny('PROMOTION_PERSON_IDENTITY_CHANGED');
 const before=cls(previous.class??previous.studentClass),
   after=cls(next.class??next.studentClass);
 if(!before||!after||cls(exam.studentClass)!==before||
    result.studentClass&&cls(result.studentClass)!==before||
    next.studentClass!==undefined&&next.studentClass!==next.class||
    next.previousClass!==undefined&&next.previousClass!==previous.class||
    !same(exam.academicSession,result.academicSession)||
    next.promotionPending!==true||next.promotionSyncState!=='Pending')
  deny('PROMOTION_CLASS_SESSION_MISMATCH');
 const subjects=exam.subjects,marks=result.marks;
 const full=exam.fullMarks,pass=exam.passMarks;
 if(!Array.isArray(subjects)||!subjects.length||
    subjects.some(s=>typeof s!=='string'||!s.trim())||
    new Set(subjects.map(s=>s.toLowerCase())).size!==subjects.length||
    !marks||typeof marks!=='object'||Array.isArray(marks)||
    Object.keys(marks).length!==subjects.length||
    typeof full!=='number'||!Number.isFinite(full)||full<=0||
    typeof pass!=='number'||!Number.isFinite(pass)||pass<0||pass>full)
  deny('PROMOTION_MARKS_NOT_VERIFIED');
 const values=subjects.map(s=>marks[s]);
 if(values.some(v=>typeof v!=='number'||!Number.isFinite(v)||v<0||v>full))
  deny('PROMOTION_MARKS_INVALID');
 const actual=values.every(v=>v>=pass)?'PASS':'FAIL';
 if(result.result!==actual||next.lastExamResult!==actual)
  deny('PROMOTION_RESULT_MISMATCH');
 const isPass=actual==='PASS',isFail=actual==='FAIL';
 const permitted=move==='PROMOTED'&&isPass&&before<12&&after===before+1 ||
  move==='RETAINED'&&isFail&&after===before ||
  move==='GRADUATED'&&isPass&&before===12&&after===12 ||
  move==='FORCE_PROMOTED'&&isFail&&before<12&&after===before+1&&
    previous.classMovement==='RETAINED'&&
    previous.promotionExamId===examId&&
    policy?.schoolId===schoolId&&policy.allowForcedPromotion===true&&
    typeof next.promotionOverrideReason==='string'&&
    next.promotionOverrideReason.trim().length>0&&
    next.promotionOverrideReason.length<=500;
 if(!permitted)deny('PROMOTION_DECISION_NOT_AUTHORIZED');
 return {examId,movement:move,studentId};
}
module.exports={hasChangedPromotion,validatePromotionAuthority};
