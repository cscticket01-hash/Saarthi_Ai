'use strict';
const crypto=require('node:crypto');
const {expired,millis}=require('./complaint-retention');
function createMobileComplaints({db,now,fail,verify}){
 return async(schoolId,request)=>{
  const identity=await verify(request.action==='mobile_complaint');
  const role=identity.attendancePolicy?.role||identity.role;
  const personId=identity.attendancePolicy?.personId||identity.personId;
  if(!['student','teacher'].includes(role)||typeof personId!=='string'||!personId)fail(403,'Verified school person required');
  const owner=crypto.createHash('sha256').update(schoolId+'\n'+role+'\n'+personId).digest('hex');
  if(request.action==='mobile_complaints'){
   let q=db.collection('platform_complaints').where('schoolId','==',schoolId).orderBy('__name__');
   if(request.cursor!==undefined){if(!/^[-_a-zA-Z0-9]{1,120}$/.test(request.cursor))fail(400,'Invalid history cursor');q=q.startAfter(request.cursor);}
   const rows=(await q.limit(101).get()).docs;
   const complaints=rows.slice(0,100).filter(d=>{const v=d.data();return v.schoolId===schoolId&&v.owner===owner&&!v.purging&&!expired(v,now());}).map(d=>{const v=d.data();return {id:d.id,message:v.message,status:v.status,createdAt:millis(v.createdAt),resolvedAt:millis(v.resolvedAt),reply:v.schoolReply||''};});
   return {success:true,schoolId,projectId:schoolId,complaints,cursor:rows.length>100?rows[99].id:null};
  }
  const message=String(request.message||'').trim();
  if(message.length<3||message.length>3000)fail(400,'Use 3–3000 characters');
  const clientId=request.complaintId||crypto.createHash('sha256').update(owner+'\n'+String(request.sessionToken||'')+'\n'+message).digest('hex').slice(0,32);
  if(!/^[a-f0-9]{32}$/.test(clientId))fail(400,'Invalid complaint identity');
  const complaintId=schoolId+'_'+clientId,ref=db.doc('platform_complaints/'+complaintId),limit=db.doc('platform_support_limits/mobile_'+owner);
  const person=identity.person||{};
  await db.runTransaction(async tx=>{
   const old=await tx.get(ref),rate=await tx.get(limit);
   if(old.exists){if(old.data().owner!==owner||old.data().message!==message)fail(409,'Complaint identity already used');return;}
   if(rate.exists&&now()-millis(rate.data().lastSentAt)<30000)fail(429,'Wait 30 seconds before another complaint');
   tx.set(ref,{schoolId,owner,personId,role,audience:'school',source:'android',message,status:'open',
    studentName:String(person.name||'').slice(0,160),studentClass:String(person.class||'').slice(0,80),rollNo:String(person.rollNo||'').slice(0,40),
    device:String(request.device||'Android').slice(0,240),deviceId:String(request.deviceId||'').slice(0,160),version:String(request.version||'').slice(0,32),
    createdAt:new Date(now()),supportHistoryVersion:1});
   tx.set(limit,{lastSentAt:new Date(now())});
  });
  return {success:true,schoolId,projectId:schoolId,complaintId};
 };
}
module.exports={createMobileComplaints};
