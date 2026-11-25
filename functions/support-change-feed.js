'use strict';
const {randomUUID}=require('node:crypto');
const {expired}=require('./complaint-retention');
// Shared bounded Firestore query listeners. After the initial server snapshot,
// Firestore delivers document changes; unchanged polls do not enumerate history.
// An evicted/restarted/oversized listener forces authoritative full-list fallback.
const instances=new WeakMap();
function supportFeed(db,plain,now){
 if(instances.has(db))return instances.get(db);
 const states=new Map(),maxSchools=48,maxRows=500,keep=32;
 function stop(school,state){
  if(states.get(school)!==state)return;
  states.delete(school);clearTimeout(state.timer);state.unsubscribe?.();
  state.readyResolve(false);
 }
 function touch(school,state){
  clearTimeout(state.timer);state.timer=setTimeout(()=>stop(school,state),120000);
  state.timer.unref?.();
 }
 async function changes(school,cursor){
  let state=states.get(school);
  if(!state){
   const query=db.collection('platform_complaints').where('schoolId','==',school).limit(maxRows+1);
   if(typeof query.onSnapshot!=='function'||states.size>=maxSchools)return {fallback:true};
   let readyResolve;
   const ready=new Promise(r=>readyResolve=r);
   state={epoch:randomUUID(),sequence:0,rows:new Map(),journal:[],ready,readyResolve,initialized:false};
   states.set(school,state);
   try{
    state.unsubscribe=query.onSnapshot(snapshot=>{
     if(states.get(school)!==state)return;
     try{
      if(snapshot.docs.length>maxRows){stop(school,state);return;}
      const next=new Map();
      for(const doc of snapshot.docs){
       const row=plain(doc);
       if(row.schoolId!==school)throw Error('Foreign ticket');
       if(!row.purging)next.set(doc.id,row);
      }
      const changed=new Set();
      for(const [id,row] of next)if(JSON.stringify(state.rows.get(id))!==JSON.stringify(row))changed.add(id);
      for(const id of state.rows.keys())if(!next.has(id))changed.add(id);
      state.rows=next;
      if(changed.size){
       state.sequence++;
       state.journal.push({sequence:state.sequence,ids:[...changed]});
       if(state.journal.length>keep)state.journal.shift();
      }
      state.initialized=true;readyResolve(true);
     }catch(_){stop(school,state);}
    },()=>stop(school,state));
    if(states.get(school)!==state){state.unsubscribe?.();return {fallback:true};}
   }catch(_){stop(school,state);return {fallback:true};}
  }
  touch(school,state);
  if(!state.initialized){
   let timer;const ok=await Promise.race([state.ready,new Promise(r=>timer=setTimeout(()=>r(false),4000))]);clearTimeout(timer);
   if(!ok||states.get(school)!==state){stop(school,state);return {fallback:true};}
  }
  const current=state.epoch+':'+state.sequence;
  const parts=typeof cursor==='string'?cursor.split(':'):[],after=Number(parts[1]);
  const floor=(state.journal[0]?.sequence??state.sequence+1)-1;
  const reset=parts.length!==2||parts[0]!==state.epoch||!Number.isSafeInteger(after)||after<floor||after>state.sequence;
  const ids=reset?[...state.rows.keys()]:[...new Set(state.journal.filter(e=>e.sequence>after).flatMap(e=>e.ids))];
  const rows=[],removed=[];
  for(const id of ids){const row=state.rows.get(id);if(row&&!expired(row,now()))rows.push(row);else removed.push(id);}
  // Retention can expire between Firestore writes; explicitly remove those rows.
  if(!reset)for(const [id,row] of state.rows)if(expired(row,now())&&!removed.includes(id))removed.push(id);
  return {cursor:current,reset,complaints:rows,removed};
 }
 const api={changes};instances.set(db,api);return api;
}
module.exports={supportFeed};
