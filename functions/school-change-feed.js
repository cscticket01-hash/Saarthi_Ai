'use strict';
const {randomUUID}=require('node:crypto');
// Durable bounded hints only. Record data, receipts and conflict decisions stay
// with the existing signed storage owner. Firestore listeners cross instances.
function createSchoolChangeFeed({db,collections,waitMillis=20000,maxWaiters=500}) {
 const allowed=new Set(collections);let waiting=0;const perSchool=new Map();
 const enabled=typeof db.doc('school_sync_hints/probe').onSnapshot==='function';
 const ref=id=>db.doc('school_sync_hints/'+id);
 function valid(id){if(!/^vs-[a-f0-9]{32}$/.test(id))throw Error('Invalid hint school');}
 function validRecordId(id){return typeof id==='string'&&id.length>0&&id.length<=200&&!['.','..','__proto__','prototype','constructor'].includes(id)&&!id.includes('/');}
 function project(state,cursor){
  const epoch=state?.epoch||'empty',sequence=state?.sequence??0,current=epoch+':'+sequence;
  // Corrupt metadata cannot certify an idle listener or a received cursor.
  if(!/^(?:empty|[a-f0-9-]{36})$/.test(epoch)||!Number.isSafeInteger(sequence)||sequence<0||sequence>999999999999999)
   throw Object.assign(Error('Change feed state requires review'),{status:503,code:'CHANGE_FEED_UNAVAILABLE',publicMessage:true});
  const events=Array.isArray(state?.events)?state.events:[];
  const split=cursor?.split(':'),after=Number(split?.[1]);
  // A missing/interleaved event inside the retained window is a gap too.
  // Fall back to authoritative collection reconciliation, never skip to idle.
  const intact=events.length<=64&&events.every((e,i)=>e&&allowed.has(e.collection)&&
   Number.isSafeInteger(e.sequence)&&e.sequence===sequence-events.length+i+1&&
   (!Object.hasOwn(e,'id')||validRecordId(e.id)))&&(sequence===0||events.length>0);
  const reset=!intact||!cursor||split[0]!==epoch||!Number.isSafeInteger(after)||after>sequence||after<(events[0]?.sequence??sequence)-1;
  if(cursor===current&&!reset)return null;
  const selected=reset?[]:events.filter(e=>e.sequence>after);
  const names=reset?[...allowed]:[...new Set(selected.map(e=>e.collection))];
  const records={};for(const col of names){const rows=selected.filter(e=>e.collection===col);if(!reset&&rows.length&&rows.every(e=>validRecordId(e.id)))records[col]=[...new Set(rows.map(e=>e.id))];}
  return {cursor:current,reset,collections:names,records};
 }
 async function publishMany(school,collections,id){
  valid(school);const selected=[...new Set(collections)].filter(c=>allowed.has(c));
  if(!enabled||!selected.length)return;
  await db.runTransaction(async tx=>{const r=ref(school),snap=await tx.get(r),old=snap.exists?snap.data():{};
   const previous=Number.isSafeInteger(old.sequence)?old.sequence:0;
   const events=selected.map((collection,index)=>({sequence:previous+index+1,collection,
    ...(validRecordId(id)?{id}:{})}));
   tx.set(r,{version:1,epoch:old.epoch||randomUUID(),sequence:previous+events.length,
    events:[...(Array.isArray(old.events)?old.events:[]),...events].slice(-64)});
  },{maxAttempts:2});
 }
 return {enabled,collections:[...allowed],publishMany,async publish(school,collection,id){return publishMany(school,[collection],id);
 },async wait(school,cursor){
  valid(school);if(!enabled)throw Object.assign(Error('Change feed unavailable'),{status:503,code:'CHANGE_FEED_UNAVAILABLE',publicMessage:true});
  if(cursor!==undefined&&(typeof cursor!=='string'||cursor.length>80||! /^(?:empty|[a-f0-9-]{36}):[0-9]{1,15}$/.test(cursor)))throw Object.assign(Error('Invalid change cursor'),{status:400,publicMessage:true});
  if(waiting>=maxWaiters||(perSchool.get(school)||0)>=10)throw Object.assign(Error('Change feed busy'),{status:429,publicMessage:true});
  waiting++;perSchool.set(school,(perSchool.get(school)||0)+1);
  try{return await new Promise((resolve,reject)=>{
   let done=false,unsubscribe,latest=cursor||'empty:0';
   const finish=(error,value)=>{if(done)return;done=true;clearTimeout(timer);unsubscribe?.();error?reject(error):resolve(value);};
   const timer=setTimeout(()=>finish(null,{cursor:latest,reset:false,collections:[],records:{}}),waitMillis);
   try{unsubscribe=ref(school).onSnapshot(snap=>{try{const state=snap.exists?snap.data():null;const event=project(state,cursor);latest=(state?.epoch||'empty')+':'+(state?.sequence||0);if(event)finish(null,event);}catch(error){finish(error);}},error=>finish(error));if(done)unsubscribe?.();}catch(error){finish(error);}
  });}finally{waiting--;const count=(perSchool.get(school)||1)-1;if(count)perSchool.set(school,count);else perSchool.delete(school);}
 },project};
}
module.exports={createSchoolChangeFeed};
