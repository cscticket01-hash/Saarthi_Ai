'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {storage,A}=require('./helpers/managed-storage');
const operations=n=>Array.from({length:n},(_,i)=>({operationId:(i+1).toString(16).padStart(64,'0'),request:{sessionToken:'synthetic-only'}}));
test('slow attendance returns partial receipts, never acknowledges unstarted operations, and resumes unchanged IDs',()=>{
 const s=storage({lifecycle:true}),ops=operations(25);let clock=Date.now(),calls=[];
 s.context.Date=class extends Date {static now(){return clock;}};
 s.context.VS_managedMobile=(request)=>{clock+=20000;calls.push(request.operationId);return {};};
 const first=s.context.VS_managedAttendanceBatch({operations:ops,lease:{schoolId:A}});
 assert.equal(first.acknowledgements.length,2);assert.equal(first.partial,true);assert.equal(first.deferredCount,23);
 assert.deepEqual(calls,ops.slice(0,2).map(op=>op.operationId));
 assert(first.acknowledgements.every(ack=>ack.success&&calls.includes(ack.operationId)));
 const next=s.context.VS_managedAttendanceBatch({operations:ops.slice(2),lease:{schoolId:A}});
 assert.equal(next.acknowledgements[0].operationId,ops[2].operationId);
 assert.equal(calls.length,4);
});
test('batch validates every identity before any write, including malformed and duplicate trailing items',()=>{
 const s=storage();let calls=0;s.context.VS_managedMobile=()=>{calls++;};
 for(const invalid of [null,{},operations(26),[...operations(1),null],[...operations(1),{operationId:'bad',request:{}}],[...operations(1),operations(1)[0]],[{operationId:'a'.repeat(64),request:[]}]] ){
  assert.throws(()=>s.context.VS_managedAttendanceBatch({operations:invalid}),/Invalid attendance/);
  assert.equal(calls,0);
 }
});
test('temporary and authoritative failures remain distinct and fast batches finish all 25 operations',()=>{
 const s=storage(),ops=operations(25);let calls=0;
 s.context.VS_managedMobile=()=>{calls++;if(calls===1)throw Error('Google quota exceeded');if(calls===2)throw Error('School session expired');};
 const out=s.context.VS_managedAttendanceBatch({operations:ops});
 assert.equal(out.partial,false);assert.equal(out.deferredCount,0);assert.equal(out.acknowledgements.length,25);
 assert.equal(out.acknowledgements[0].success,false);assert.equal(out.acknowledgements[0].authoritative,false);
 assert.equal(out.acknowledgements[1].authoritative,true);assert(out.acknowledgements.slice(2).every(ack=>ack.success));
});
test('signed full bundle exposes bounded batch capability and preserves school verification',()=>{
 const s=storage({bundle:true,lifecycle:true}),out=s.call({action:'managed_health'});
 assert.equal(out.success,true);assert.equal(out.scriptBundleVersion,'2026-10-26.1');assert.equal(out.attendanceBatchVersion,2);
 assert.equal(out.attendanceBatchMaxOperations,25);assert.equal(out.attendanceBatchBudgetMillis,45000);
 assert.equal(s.call({action:'managed_attendance_batch',operations:operations(1),lease:{schoolId:A,expiresAt:0}}).acknowledgements[0].success,false);
});
test('lost ACK retry reuses an identical verified sync head without rewriting it',()=>{
 const s=storage({lifecycle:true}),request={action:'managed_records',operation:'write',collection:'school_notices',id:'retry',syncProtocol:2,operationId:'safe-retry-operation-123456',expectedRecordRevision:'',data:{schoolId:A,title:'Retain'}};
 const first=s.call(request);assert.equal(first.success,true);
 const sheet=s.context.VS_syncStateSheet(false,'school_notices'),get=sheet.getRange.bind(sheet);let writes=0;
 sheet.getRange=(...args)=>{const r=get(...args),set=r.setValues.bind(r);r.setValues=v=>{writes++;return set(v);};return r;};
 const retry=s.call(request);assert.equal(retry.success,true);assert.equal(retry.recordRevision,first.recordRevision);assert.equal(writes,0);
 const row=get(2,2,1,1).getValues(),head=JSON.parse(row[0][0]);head.payloadHash='damaged';get(2,2,1,1).setValues([[JSON.stringify(head)]]);
 assert.equal(s.call(request).success,true);assert.equal(writes,1,'a differing head must still be written and verified');
});
