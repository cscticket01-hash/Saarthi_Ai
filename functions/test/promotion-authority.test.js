'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {hasChangedPromotion,validatePromotionAuthority}=require('../promotion-authority');

const schoolId='vs-'+'a'.repeat(32),studentId='student-one';
const personId='p-'+'1'.repeat(64);
const previous={schoolId,mobileStableId:personId,class:'Class 10',
 studentClass:'Class 10',section:'A',rollNo:'4'};
const exam={schoolId,examId:'final-10',isFinal:true,completed:true,
 studentClass:'Class 10',academicSession:'2026-2027',
 subjects:['English','Math'],fullMarks:100,passMarks:33};
const result={schoolId,examId:'final-10',studentId,personId,
 academicSession:'2026-2027',studentClass:'Class 10',
 result:'PASS',marks:{English:78,Math:89}};
const next={...previous,class:'Class 11',studentClass:'Class 11',
 previousClass:'Class 10',promotionExamId:'final-10',
 promotionTransactionId:'promotion:final-10:student-one',
 promotionPending:true,promotionSyncState:'Pending',
 classMovement:'PROMOTED',lastExamResult:'PASS'};
const check=(changes={})=>validatePromotionAuthority({
 schoolId,studentId,previous,next,exam,result,...changes});
const blocks=(changes,code)=>assert.throws(()=>check(changes),e=>e.code===code);

test('promotion admits only an approved same-owner full PASS result',()=>{
 assert.deepEqual(check(),{examId:'final-10',movement:'PROMOTED',studentId});
 assert.equal(hasChangedPromotion(previous,next),true);
 assert.equal(hasChangedPromotion(next,{...next,name:'Updated'}),false);
 blocks({result:{...result,marks:{English:32,Math:89}}},
  'PROMOTION_RESULT_MISMATCH');
 blocks({result:{...result,marks:{English:70}}},
  'PROMOTION_MARKS_NOT_VERIFIED');
 blocks({result:{...result,personId:'old-person'}},
  'PROMOTION_PERSON_IDENTITY_CHANGED');
 blocks({next:{...next,mobileStableId:'p-'+'2'.repeat(64)}},
  'PROMOTION_PERSON_IDENTITY_CHANGED');
 blocks({next:{...next,studentClass:'Class 10'}},
  'PROMOTION_CLASS_SESSION_MISMATCH');
 blocks({next:{...next,class:'Class 12',studentClass:'Class 12'}},
  'PROMOTION_DECISION_NOT_AUTHORIZED');
 blocks({exam:{...exam,schoolId:'foreign'}},
  'PROMOTION_SCHOOL_OR_OWNER_INVALID');
 blocks({exam:{...exam,isFinal:false}},
  'PROMOTION_FINAL_EXAM_INVALID');
 blocks({result:{...result,academicSession:'2025-2026'}},
  'PROMOTION_CLASS_SESSION_MISMATCH');
});

test('retention, Class 12 graduation and force override use separate strict rules',()=>{
 const failed={...result,result:'FAIL',marks:{English:20,Math:78}};
 const retain={...next,class:'Class 10',studentClass:'Class 10',
  classMovement:'RETAINED',lastExamResult:'FAIL'};
 assert.equal(check({result:failed,next:retain}).movement,'RETAINED');
 const senior={...previous,class:'Class 12',studentClass:'Class 12'};
 const seniorExam={...exam,studentClass:'Class 12'};
 const seniorResult={...result,studentClass:'Class 12'};
 assert.equal(check({previous:senior,exam:seniorExam,result:seniorResult,
  next:{...next,class:'Class 12',studentClass:'Class 12',previousClass:'Class 12',
  classMovement:'GRADUATED'}}).movement,'GRADUATED');
 const forced={...next,classMovement:'FORCE_PROMOTED',lastExamResult:'FAIL',
  promotionOverrideReason:'Approved academic review'};
 const previouslyRetained={...previous,classMovement:'RETAINED',
  promotionExamId:'final-10',promotionTransactionId:'promotion:final-10:student-one'};
 blocks({previous:previouslyRetained,result:failed,next:forced},
  'PROMOTION_DECISION_NOT_AUTHORIZED');
 assert.equal(check({previous:previouslyRetained,result:failed,next:forced,
  policy:{schoolId,allowForcedPromotion:true}}).movement,'FORCE_PROMOTED');
 blocks({previous:previouslyRetained,result:failed,
  next:{...forced,promotionOverrideReason:' '},
  policy:{schoolId,allowForcedPromotion:true}},
  'PROMOTION_DECISION_NOT_AUTHORIZED');
});
