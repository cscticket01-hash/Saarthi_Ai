import test from 'node:test';
import assert from 'node:assert/strict';
import {checkedR2Admission,verifiedR2PurgeDue,r2MayPurge,R2_SCHOOL_DATA_BYTES,R2_SYSTEM_RESERVE_BYTES,R2_TOTAL_BYTES,R2_VERIFIED_RETENTION_MS} from '../src/r2-capacity.mjs';
test('R2 school admissions stop precisely at 8 decimal GB; preserve 2GB reserve',()=>{
 assert.equal(R2_SCHOOL_DATA_BYTES,8_000_000_000);
 assert.equal(R2_SYSTEM_RESERVE_BYTES,2_000_000_000);
 assert.equal(R2_TOTAL_BYTES,10_000_000_000);
 assert.equal(checkedR2Admission(0,0,8_000_000_000).accepted,true);
 const full=checkedR2Admission(8_000_000_000,0,1);
 assert.equal(full.accepted,false);assert.equal(full.code,'R2_CAPACITY_EXCEEDED');
 assert.equal(checkedR2Admission(8_000_000_000,0,2_000_000_000,'system').accepted,true);
 assert.equal(checkedR2Admission(8_000_000_000,2_000_000_000,1,'system').accepted,false);
 assert.equal(checkedR2Admission(0,2_000_000_000,8_000_000_000).accepted,true);
 assert.equal(checkedR2Admission(0,2_000_000_000,8_000_000_001).accepted,false);
});
test('Invalid R2 usage never becomes a cheap success via nonfinite, negative or fractional inputs',()=>{
 for(const value of [-1,NaN,Infinity,0.5,Number.MAX_SAFE_INTEGER])
  assert.throws(()=>checkedR2Admission(value,0,1));
 for(const value of [0,-1,NaN,Infinity,0.5])
  assert.throws(()=>checkedR2Admission(0,0,value));
 assert.throws(()=>checkedR2Admission(0,0,1,'untrusted'));
});
test('24h cache may be purged only after actual Drive verification',()=>{
 const accepted=Date.now()-R2_VERIFIED_RETENTION_MS-1000;
 const pending={state:'pending',accepted_at:accepted,verified_at:0,purge_due:0};
 assert.equal(r2MayPurge(pending,Date.now()),false);
 const now=Date.now();assert.equal(verifiedR2PurgeDue(accepted,now),now); // verified after minimum age
 const verified=accepted+1000;
 const due=verifiedR2PurgeDue(accepted,verified);
 const record={state:'verified',accepted_at:accepted,verified_at:verified,purge_due:due};
 assert.equal(r2MayPurge(record,due-1),false);
 assert.equal(r2MayPurge(record,due),true);
 assert.equal(r2MayPurge({...record,purge_due:accepted},due),false);
 assert.equal(r2MayPurge({...record,verified_at:0},due),false);
 assert.throws(()=>verifiedR2PurgeDue(accepted,accepted-1));
});
