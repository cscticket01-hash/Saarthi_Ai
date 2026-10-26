'use strict';
const {randomUUID}=require('node:crypto');
// Durable bounded hints only. Record data, receipts and conflict decisions stay
// with the existing signed storage owner. Firestore listeners cross instances.
function createSchoolChangeFeed({db,collections,waitMillis=20000,maxWaiters=2500,idleGraceMillis=0}) {
 const allowed=new Set(collections);let waiting=0;const perSchool=new Map(),subscriptions=new Map();
 const enabled=typeof db.doc('school_sync_hints/probe').onSnapshot==='function';
 const ref=id=>db.doc('school_sync_hints/'+id);
 const pageSize=64,retainedPages=32;
 const pageRef=(school,epoch,index)=>db.doc('school_sync_hints/'+school+'/pages/'+epoch+'-'+index);
 // One Firestore subscription per school/process, shared by admitted PCs.
 // Waiter limits still bound sockets and memory; no listener remains when idle.
 function observe(school,next,error){
  let entry=subscriptions.get(school);
  if(!entry){if(subscriptions.size>=maxWaiters)throw Object.assign(Error('Change feed busy'),{status:429,publicMessage:true});entry={waiters:new Set(),started:false,ready:false};subscriptions.set(school,entry);}
  clearTimeout(entry.idleTimer);
  const waiter={next,error};entry.waiters.add(waiter);
  if(entry.ready)queueMicrotask(()=>{if(entry.waiters.has(waiter))next(entry.latest);});
  if(!entry.started){
   entry.started=true;
   try{entry.unsubscribe=ref(school).onSnapshot(snapshot=>{
    entry.latest=snapshot;entry.ready=true;
    for(const listener of [...entry.waiters])listener.next(snapshot);
   },failure=>{for(const listener of [...entry.waiters])listener.error(failure);});}
   catch(failure){for(const listener of [...entry.waiters])listener.error(failure);}
   if(!entry.waiters.size){entry.unsubscribe?.();if(subscriptions.get(school)===entry)subscriptions.delete(school);}
  }
  return ()=>{
   entry.waiters.delete(waiter);
   if(!entry.waiters.size){
    const close=()=>{if(!entry.waiters.size){entry.unsubscribe?.();if(subscriptions.get(school)===entry)subscriptions.delete(school);}};
    if(idleGraceMillis>0){entry.idleTimer=setTimeout(close,Math.min(30000,idleGraceMillis));entry.idleTimer.unref?.();}
    else close();
   }
  };
 }
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
   project(old); // Reject corrupt identity/sequence instead of resetting it.
   if(previous+events.length>999999999999999)throw Error('Change sequence exhausted; review required');
   const epoch=old.epoch||randomUUID(),pages=new Map();
   if(typeof tx.delete!=='function'){
    // Legacy adapters retain only the original bounded hot window.
    tx.set(r,{version:1,epoch,sequence:previous+events.length,
     events:[...(Array.isArray(old.events)?old.events:[]),...events].slice(-64)});
    return;
   }
   for(const event of events){
    const index=Math.floor((event.sequence-1)/pageSize);
    if(!pages.has(index)){
     const snap=await tx.get(pageRef(school,epoch,index)),value=snap.exists?snap.data():null;
     if(value&&(value.schoolId!==school||value.epoch!==epoch||value.index!==index||!Array.isArray(value.events)||value.events.length>pageSize))throw Error('Change replay page identity unverified');
     pages.set(index,value?.events||[]);
    }
    pages.get(index).push(event);
   }
   tx.set(r,{version:1,replayVersion:1,epoch,sequence:previous+events.length,
    events:[...(Array.isArray(old.events)?old.events:[]),...events].slice(-64)});
   for(const [index,entries] of pages){
    tx.set(pageRef(school,epoch,index),{version:1,schoolId:school,epoch,index,events:entries});
    // Bounded metadata retention; gaps older than this use normal reconciliation.
    // Older adapters without delete simply retain metadata, never record data.
    if(index>=retainedPages&&previous<index*pageSize+1&&typeof tx.delete==='function')tx.delete(pageRef(school,epoch,index-retainedPages));
   }
  },{maxAttempts:2});
 }
 // Replay at most 64 events / two immutable page ranges per request.
 // Only hints are replayed; every record still requires authenticated readback.
 async function replay(school,cursor,fallback){
  if(!cursor||!fallback.reset)return fallback;
  const [epoch,text]=cursor.split(':'),after=Number(text);
  return db.runTransaction(async tx=>{
   const snap=await tx.get(ref(school)),head=snap.exists?snap.data():null;
   if(!head||head.epoch!==epoch||head.replayVersion!==1)return fallback;
   project(head); // Validate the authoritative cursor before reading ranges.
   const end=Math.min(head.sequence,after+pageSize);
   if(after>=end||after<Math.max(0,(Math.floor((head.sequence-1)/pageSize)-retainedPages+1)*pageSize))return fallback;
   const entries=[];
   for(let index=Math.floor(after/pageSize);index<=Math.floor((end-1)/pageSize);index++){
    const page=await tx.get(pageRef(school,epoch,index)),value=page.exists?page.data():null;
    if(!value||value.version!==1||value.schoolId!==school||value.epoch!==epoch||value.index!==index||!Array.isArray(value.events)||value.events.length>pageSize)return fallback;
    entries.push(...value.events.filter(e=>e&&e.sequence>after&&e.sequence<=end));
   }
   if(entries.length!==end-after||entries.some((e,i)=>e.sequence!==after+i+1||!allowed.has(e.collection)||Object.hasOwn(e,'id')&&!validRecordId(e.id)))return fallback;
   const collections=[...new Set(entries.map(e=>e.collection))],records={};
   for(const collection of collections){const rows=entries.filter(e=>e.collection===collection);if(rows.every(e=>validRecordId(e.id)))records[collection]=[...new Set(rows.map(e=>e.id))];}
   return {cursor:epoch+':'+end,reset:false,collections,records,replayVersion:1,hasMore:end<head.sequence};
  },{maxAttempts:2});
 }
 return {enabled,collections:[...allowed],publishMany,async publish(school,collection,id){return publishMany(school,[collection],id);
 },async wait(school,cursor,{replayVersion=0}={}){
  valid(school);if(!enabled)throw Object.assign(Error('Change feed unavailable'),{status:503,code:'CHANGE_FEED_UNAVAILABLE',publicMessage:true});
  if(cursor!==undefined&&(typeof cursor!=='string'||cursor.length>80||! /^(?:empty|[a-f0-9-]{36}):[0-9]{1,15}$/.test(cursor)))throw Object.assign(Error('Invalid change cursor'),{status:400,publicMessage:true});
  if(waiting>=maxWaiters||(perSchool.get(school)||0)>=10)throw Object.assign(Error('Change feed busy'),{status:429,publicMessage:true});
  waiting++;perSchool.set(school,(perSchool.get(school)||0)+1);
  try{const event=await new Promise((resolve,reject)=>{
   let done=false,unsubscribe,latest=cursor||'empty:0';
   const finish=(error,value)=>{if(done)return;done=true;clearTimeout(timer);unsubscribe?.();error?reject(error):resolve(value);};
   const timer=setTimeout(()=>finish(null,{cursor:latest,reset:false,collections:[],records:{}}),waitMillis);
   try{unsubscribe=observe(school,snap=>{try{const state=snap.exists?snap.data():null;const event=project(state,cursor);latest=(state?.epoch||'empty')+':'+(state?.sequence||0);if(event)finish(null,event);}catch(error){finish(error);}},error=>finish(error));if(done)unsubscribe?.();}catch(error){finish(error);}
  });return replayVersion===1?await replay(school,cursor,event):event;}finally{waiting--;const count=(perSchool.get(school)||1)-1;if(count)perSchool.set(school,count);else perSchool.delete(school);}
 },project};
}
module.exports={createSchoolChangeFeed};
