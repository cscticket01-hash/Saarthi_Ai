'use strict';
const millis=v=>v?.toMillis?.()??v?.getTime?.()??(typeof v==='number'?v:0);
function expiresAt(value){
 const start=millis(value);if(!start)return 0;
 const date=new Date(start),day=date.getUTCDate();date.setUTCDate(1);date.setUTCMonth(date.getUTCMonth()+3);
 const last=new Date(Date.UTC(date.getUTCFullYear(),date.getUTCMonth()+1,0)).getUTCDate();date.setUTCDate(Math.min(day,last));return date.getTime();
}
const expired=(row,now)=>row.status==='resolved'&&expiresAt(row.resolvedAt)>0&&expiresAt(row.resolvedAt)<=now;
// The lock is transactional: reopening cannot race with a recursive deletion.
async function cleanupComplaints({db,now=Date.now,schoolId}){
 let query=db.collection('platform_complaints').where('status','==','resolved');
 if(schoolId)query=db.collection('platform_complaints').where('schoolId','==',schoolId);
 let cursor=null,deleted=0;
 for(;;){
  let q=query.orderBy('__name__').limit(100);if(cursor)q=q.startAfter(cursor);
  const rows=(await q.get()).docs;if(!rows.length)break;
  for(const snapshot of rows){
   const ref=db.doc('platform_complaints/'+snapshot.id);
   const remove=await db.runTransaction(async tx=>{
    const current=await tx.get(ref);if(!current.exists)return false;const row=current.data();
    if(schoolId&&row.schoolId!==schoolId)return false;
    if(row.status!=='resolved')return false;
    if(!millis(row.resolvedAt)){tx.set(ref,{resolvedAt:row.updatedAt||new Date(now())},{merge:true});return false;}
    if(!expired(row,now()))return false;
    tx.set(ref,{purging:true},{merge:true});return true;
   });
   if(remove){await db.recursiveDelete(ref);deleted++;}
  }
  cursor=rows[rows.length-1].id;if(rows.length<100)break;
 }
 return {deleted};
}
module.exports={millis,expiresAt,expired,cleanupComplaints};
