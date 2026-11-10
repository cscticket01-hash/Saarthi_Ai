'use strict';
// A native person lifecycle commits directly to the signed school owner. It
// does not claim an edge enqueue. Bind its readback to the exact submitted op.
function verifiedNativeReceipt(reply, request, schoolId) {
 const row=reply?.record;
 return reply?.success===true&&reply.schoolId===schoolId&&reply.syncProtocol===2&&
  reply.personLifecycleVersion===1&&reply.operationId===request.operationId&&
  reply.reconcileRequired!==true&&!reply.delivery&&
  typeof reply.recordRevision==='string'&&reply.recordRevision.length>0&&
  !/^(cf-|live-)/.test(reply.recordRevision)&&row?.schoolId===schoolId&&
  (row.id===undefined||row.id===request.id)&&row._syncRevision===reply.recordRevision&&
  row._syncOperationId===request.operationId&&
  (request.operation==='delete'?row._syncDeleted===true&&
   reply.deleteEverywhereVersion===1&&reply.driveDeletionComplete===true&&
   reply.firebaseDeletionComplete===true:request.operation==='write'&&row._syncDeleted!==true);
}
module.exports={verifiedNativeReceipt};
