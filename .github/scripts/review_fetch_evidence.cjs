'use strict';
// Observe a clone of the exact browser fetch response before Flutter consumes
// the body. No replay, provider request, credentials or raw record is retained.
function installBrowserEvidence({endpoint,school,noticeId,title}) {
 const original=window.fetch.bind(window);
 window.__vsReviewEvidence=[];
 window.fetch=function(input,init){
  const url=typeof input==='string'?input:input&&input.url;
  let body;
  if(url===endpoint&&init&&String(init.method||'GET').toUpperCase()==='POST'){
   try{const raw=typeof init.body==='string'?init.body:
    ArrayBuffer.isView(init.body)&&init.body.byteLength<=65536?new TextDecoder().decode(init.body):'';
    body=JSON.parse(raw);
   }catch(_){}
  }
  const own=body&&body.schoolId===school;
  const write=own&&body.action==='managed/records'&&body.operation==='write'&&body.collection==='school_notices'&&body.id===noticeId;
  const read=own&&body.action==='managed/changes'&&body.headOnly!==true&&Array.isArray(body.collections)&&body.collections.includes('school_notices');
  const pending=original(input,init);
  if(write||read){
   // Capture this array now; resetting the observer cannot accept an old read.
   const events=window.__vsReviewEvidence,entry={kind:write?'write':'read',complete:false};
   if(write)entry.operationId=body.operationId;
   events.push(entry);
   pending.then(response=>{
    entry.http=response.status;
    return response.clone().json().then(reply=>{
     entry.schoolMatches=reply.schoolId===school;entry.protocolMatches=reply.syncProtocol===2;
     if(write){entry.success=reply.success===true;entry.recordRevision=typeof reply.recordRevision==='string'?reply.recordRevision:'';}
     else {const group=reply.changes&&reply.changes.school_notices;
      entry.hasNoticeChanges=!!group;entry.unchanged=!!group&&group.unchanged===true;
      const notice=group&&group.records&&group.records[noticeId];
      entry.noticeMatches=!!notice&&notice.schoolId===school&&notice.title===title&&notice._syncDeleted!==true;
     }
     entry.complete=true;
    });
   }).catch(()=>{entry.failed=true;});
  }
  return pending;
 };
}
module.exports={installBrowserEvidence};
