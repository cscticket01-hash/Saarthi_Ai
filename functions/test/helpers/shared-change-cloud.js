'use strict';
const assert=require('node:assert/strict');
function sharedCloud(){
 const records=new Map(),listeners=new Map();let tail=Promise.resolve();
 const snapshot=p=>({exists:records.has(p),data:()=>structuredClone(records.get(p))});
 const db={doc:p=>({path:p,onSnapshot(next){const rows=listeners.get(p)||new Set();listeners.set(p,rows);rows.add(next);queueMicrotask(()=>{if(rows.has(next))next(snapshot(p));});return()=>{rows.delete(next);if(!rows.size)listeners.delete(p);};}}),
  runTransaction(fn){const run=tail.then(async()=>{
   const writes=[];
   const result=await fn({get:async r=>{assert.equal(writes.length,0,'Firestore reads must precede writes');return snapshot(r.path);},
    delete:r=>writes.push([r.path,null]),set:(r,v)=>writes.push([r.path,structuredClone(v)])});
   for(const [path,value] of writes){if(value===null)records.delete(path);else records.set(path,value);}
   for(const [path] of writes)for(const next of listeners.get(path)||[])queueMicrotask(()=>next(snapshot(path)));
   return result;
  });tail=run.catch(()=>{});return run;}};
 return {db,records,listeners};
}
module.exports={sharedCloud};
