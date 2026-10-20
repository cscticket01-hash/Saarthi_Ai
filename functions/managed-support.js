'use strict';
const {Timestamp}=require('firebase-admin/firestore');
function createManagedSupport({db,now,fail}) {
 const text=(value)=>{const s=String(value||'').trim();if(s.length<3||s.length>3000)fail(400,'Use 3–3000 characters');return s;};
 const id=(value)=>{if(typeof value!=='string'||!/^[-_a-zA-Z0-9]{1,120}$/.test(value))fail(400,'Invalid complaint identity');return value;};
 const millis=v=>v?.toMillis?.()??(typeof v==='number'?v:0);
 const plain=(d)=>{const v=d.data();return {id:d.id,...v,createdAt:millis(v.createdAt),...(v.updatedAt!==undefined?{updatedAt:millis(v.updatedAt)}:{})};};
 async function page(query,cursor){if(cursor!==undefined)query=query.startAfter(id(cursor));const rows=(await query.limit(51).get()).docs;return {rows:rows.slice(0,50).map(plain),cursor:rows.length>50?rows[49].id:null};}
 return async (action,b,m)=>{
  const schoolId=m.schoolId;
  if(action==='managed/support/list'){
   const p=await page(db.collection('platform_complaints').where('schoolId','==',schoolId).orderBy('__name__'),b.cursor);
   if(p.rows.some(r=>r.schoolId!==schoolId))fail(502,'Complaint school identity mismatch');
   return {success:true,schoolId,complaints:p.rows,cursor:p.cursor};
  }
  const complaintId=id(b.complaintId),ref=db.doc('platform_complaints/'+complaintId);
  if(action==='managed/support/create'){
   if(!new RegExp('^'+schoolId+'_[a-f0-9]{32}$').test(complaintId))fail(400,'Invalid school complaint identity');
   const message=text(b.message),limit=db.doc('platform_support_limits/'+schoolId);
   await db.runTransaction(async tx=>{
    const old=await tx.get(ref),rate=await tx.get(limit);
    if(old.exists){if(old.data().schoolId!==schoolId||old.data().message!==message)fail(409,'Complaint identity already used');return;}
    if(rate.exists&&now()-Number(rate.data().lastSentAt?.toMillis?.()??rate.data().lastSentAt)<30000)fail(429,'Wait 30 seconds before sending another complaint');
    tx.set(ref,{schoolId,source:'windows',role:'admin',message,status:'open',version:String(b.version||'').slice(0,32),createdAt:Timestamp.fromMillis(now()),supportHistoryVersion:1});
    tx.set(limit,{lastSentAt:Timestamp.fromMillis(now()),complaintId});
   });
   return {success:true,schoolId,complaintId};
  }
  const parent=await ref.get();if(!parent.exists||parent.data().schoolId!==schoolId)fail(404,'Complaint not found for this school');
  if(action==='managed/support/thread'){
   const p=await page(db.collection('platform_complaints/'+complaintId+'/messages').orderBy('__name__'),b.cursor);
   if(p.rows.some(r=>r.schoolId!==schoolId))fail(502,'Complaint message school identity mismatch');
   return {success:true,schoolId,complaint:plain(parent),messages:p.rows,cursor:p.cursor};
  }
  if(action==='managed/support/reply'){
   const message=text(b.message),messageId=id(b.messageId);
   if(!/^[0-9]{13}_[a-f0-9]{32}$/.test(messageId))fail(400,'Invalid reply identity');
   const messageRef=db.doc('platform_complaints/'+complaintId+'/messages/'+messageId);
   await db.runTransaction(async tx=>{
    const current=await tx.get(ref),old=await tx.get(messageRef);
    if(!current.exists||current.data().schoolId!==schoolId)fail(404,'Complaint not found for this school');
    if(old.exists){if(old.data().schoolId!==schoolId||old.data().role!=='school'||old.data().message!==message)fail(409,'Reply identity already used');return;}
    tx.set(messageRef,{schoolId,role:'school',message,createdAt:Timestamp.fromMillis(now())});tx.set(ref,{status:'open',updatedAt:Timestamp.fromMillis(now())},{merge:true});
   });return {success:true,schoolId,complaintId,messageId};
  }
  fail(400,'Unknown complaint action');
 };
}
module.exports={createManagedSupport};
