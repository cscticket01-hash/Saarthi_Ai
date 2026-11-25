'use strict';
const {expired}=require('./complaint-retention');
const {createHash}=require('node:crypto');
const sha=v=>createHash('sha256').update(v).digest('hex');
const SUPPORT_ACTIONS=['list','create','createWithScreenshot','thread','reply','resolve','attachment','readReceipts'].map(x=>'managed/support/'+x);
function createManagedSupport({db,now,fail}) {
 const text=(value)=>{const s=String(value||'').trim();if(s.length<3||s.length>3000)fail(400,'Use 3–3000 characters');return s;};
 const id=(value)=>{if(typeof value!=='string'||!/^[-_a-zA-Z0-9]{1,120}$/.test(value))fail(400,'Invalid complaint identity');return value;};
 const millis=v=>v?.toMillis?.()??v?.getTime?.()??(typeof v==='number'?v:0);
 const plain=(d)=>{const v=d.data();const {screenshotBase64,...metadata}=v;return {id:d.id,...metadata,createdAt:millis(v.createdAt),resolvedAt:millis(v.resolvedAt),...(v.updatedAt!==undefined?{updatedAt:millis(v.updatedAt)}:{}),...(v.developerUpdatedAt!==undefined?{developerUpdatedAt:millis(v.developerUpdatedAt)}:{})};};
 async function page(query,cursor){if(cursor!==undefined)query=query.startAfter(id(cursor));const rows=(await query.limit(51).get()).docs;return {rows:rows.slice(0,50).map(plain),cursor:rows.length>50?rows[49].id:null};}
 return async (action,b,m)=>{
  const schoolId=m.schoolId;
  if(action==='managed/support/list'){
   const p=await page(db.collection('platform_complaints').where('schoolId','==',schoolId).orderBy('__name__'),b.cursor);
   if(p.rows.some(r=>r.schoolId!==schoolId))fail(502,'Complaint school identity mismatch');
   const complaints=p.rows.filter(r=>!r.purging&&!expired(r,now()));
   const revision=sha(JSON.stringify([complaints,p.cursor]));
   return {success:true,schoolId,revision,cursor:p.cursor,
    ...(b.ifRevision===revision?{unchanged:true}:{complaints})};
  }
  // Receipt IDs are scoped to the authenticated school and to a specific
  // notification revision; an old read cannot mark a later reply as read.
  if(action==='managed/support/readReceipts'){
   if(!Array.isArray(b.keys)||b.keys.length>100||b.keys.some(k=>typeof k!=='string'||!(/^[a-f0-9]{64}$/).test(k))||
      !Array.isArray(b.marked)||b.marked.length>100||b.marked.some(k=>!b.keys.includes(k)))fail(400,'Invalid support read receipts');
   const keys=[...new Set(b.keys)],marked=new Set(b.marked);
   const receipt=k=>db.doc('platform_support_reads/'+schoolId+'/receipts/'+k);
   if(marked.size){
    const batch=db.batch();for(const k of marked)batch.set(receipt(k),{schoolId,readAt:new Date(now())});await batch.commit();
   }
   const found=await Promise.all(keys.map(async k=>{const d=await receipt(k).get();return d.exists&&d.data().schoolId===schoolId?k:null;}));
   return {success:true,schoolId,read:found.filter(Boolean)};
  }
  const complaintId=id(b.complaintId),ref=db.doc('platform_complaints/'+complaintId);
  if(action==='managed/support/create'||action==='managed/support/createWithScreenshot'){
   if(!new RegExp('^'+schoolId+'_[a-f0-9]{32}$').test(complaintId))fail(400,'Invalid school complaint identity');
   const message=text(b.message),limit=db.doc('platform_support_limits/'+schoolId);
   let screenshotBase64, screenshotSha256;
   if(action==='managed/support/createWithScreenshot'){
    screenshotBase64=b.screenshot;
    if(typeof screenshotBase64!=='string'||screenshotBase64.length>131072||
      !/^[A-Za-z0-9+/]+={0,2}$/.test(screenshotBase64))fail(400,'Invalid screenshot');
    const bytes=Buffer.from(screenshotBase64,'base64');
    if(bytes.length<57||bytes.length>98304||bytes.toString('base64')!==screenshotBase64||
      bytes.subarray(0,8).toString('hex')!=='89504e470d0a1a0a'||
      bytes.readUInt32BE(8)!==13||bytes.toString('ascii',12,16)!=='IHDR'||
      bytes.readUInt32BE(16)<1||bytes.readUInt32BE(16)>1280||
      bytes.readUInt32BE(20)<1||bytes.readUInt32BE(20)>1280||
      bytes.subarray(-12).toString('hex')!=='0000000049454e44ae426082')fail(400,'Use a valid bounded PNG screenshot');
    screenshotSha256=sha(bytes);
   }
   await db.runTransaction(async tx=>{
    const old=await tx.get(ref),rate=await tx.get(limit);
    if(old.exists){if(old.data().schoolId!==schoolId||old.data().message!==message||(old.data().screenshotSha256||null)!==(screenshotSha256||null))fail(409,'Complaint identity already used');return;}
    if(rate.exists&&now()-Number(rate.data().lastSentAt?.toMillis?.()??rate.data().lastSentAt)<30000)fail(429,'Wait 30 seconds before sending another complaint');
    tx.set(ref,{schoolId,source:'windows',role:'admin',message,status:'open',version:String(b.version||'').slice(0,32),createdAt:new Date(now()),supportHistoryVersion:1,...(screenshotBase64?{screenshotSha256,hasScreenshot:true}:{})});
    if(screenshotBase64)tx.set(db.doc('platform_complaints/'+complaintId+'/attachments/screenshot'),{schoolId,base64:screenshotBase64,sha256:screenshotSha256});
    tx.set(limit,{lastSentAt:new Date(now()),complaintId});
   });
   return {success:true,schoolId,complaintId,...(screenshotSha256?{screenshotSha256}:{})};
  }
  const parent=await ref.get();if(!parent.exists||parent.data().schoolId!==schoolId||parent.data().purging||expired(parent.data(),now()))fail(404,'Complaint not found for this school');
  if(action==='managed/support/attachment'){
   const v=parent.data();
   if(v.audience==='school'||v.hasScreenshot!==true)fail(404,'Screenshot unavailable');
   const file=await db.doc('platform_complaints/'+complaintId+'/attachments/screenshot').get();
   const a=file.exists?file.data():null;
   if(!a||a.schoolId!==schoolId||typeof a.base64!=='string'||a.base64.length>131072||a.sha256!==v.screenshotSha256||sha(Buffer.from(a.base64,'base64'))!==v.screenshotSha256)fail(404,'Screenshot unavailable');
   return {success:true,schoolId,complaintId,screenshot:a.base64,screenshotSha256:v.screenshotSha256};
  }
  if(action==='managed/support/resolve'){
   await db.runTransaction(async tx=>{
    const current=await tx.get(ref),v=current.data();
    if(!current.exists||v.schoolId!==schoolId||v.audience!=='school'||v.purging||expired(v,now()))fail(404,'School complaint unavailable');
    const status=b.status;if(!['open','in_progress','resolved'].includes(status))fail(400,'Invalid status');
    const reply=String(b.reply||'').trim();if(reply.length>3000)fail(400,'Use at most 3000 characters');
    tx.set(ref,{status,schoolReply:reply,updatedAt:new Date(now()),resolvedAt:status==='resolved'?(v.resolvedAt||new Date(now())):null},{merge:true});
   });return {success:true,schoolId,complaintId};
  }
  if(action==='managed/support/thread'){
    if(parent.data().audience==='school')fail(404,'Use school complaint management for this ticket');
   const p=await page(db.collection('platform_complaints/'+complaintId+'/messages').orderBy('__name__'),b.cursor);
   if(p.rows.some(r=>r.schoolId!==schoolId))fail(502,'Complaint message school identity mismatch');
   return {success:true,schoolId,complaint:plain(parent),messages:p.rows,cursor:p.cursor};
  }
  if(action==='managed/support/reply'){
   const message=text(b.message),messageId=id(b.messageId);
   if(!/^[0-9]{13}_[a-f0-9]{32}$/.test(messageId))fail(400,'Invalid reply identity');
   const messageRef=db.doc('platform_complaints/'+complaintId+'/messages/'+messageId),limit=db.doc('platform_support_limits/reply_'+schoolId);
   await db.runTransaction(async tx=>{
    const current=await tx.get(ref),old=await tx.get(messageRef),rate=await tx.get(limit);
    if(!current.exists||current.data().schoolId!==schoolId||current.data().audience==='school'||current.data().purging||expired(current.data(),now()))fail(404,'Complaint not found for this school');
    if(old.exists){if(old.data().schoolId!==schoolId||old.data().role!=='school'||old.data().message!==message)fail(409,'Reply identity already used');return;}
    if(rate.exists&&now()-millis(rate.data().lastSentAt)<3000)fail(429,'Wait 3 seconds before another reply');
    tx.set(limit,{lastSentAt:new Date(now())});
    tx.set(messageRef,{schoolId,role:'school',message,createdAt:new Date(now())});tx.set(ref,{status:'open',resolvedAt:null,updatedAt:new Date(now())},{merge:true});
   });return {success:true,schoolId,complaintId,messageId};
  }
  fail(400,'Unknown complaint action');
 };
}
module.exports={createManagedSupport,SUPPORT_ACTIONS};
