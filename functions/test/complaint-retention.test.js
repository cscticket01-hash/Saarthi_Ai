'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {expiresAt,expired,cleanupComplaints}=require('../complaint-retention');
test('retention uses calendar months and clamps month end; reopening disables expiry',()=>{
 assert.equal(new Date(expiresAt(Date.parse('2026-11-30T12:34:56Z'))).toISOString(),'2027-02-28T12:34:56.000Z');
 assert.equal(new Date(expiresAt(Date.parse('2027-11-30T00:00:00Z'))).toISOString(),'2028-02-29T00:00:00.000Z');
 const resolvedAt=Date.parse('2026-01-31T10:00:00Z'),end=Date.parse('2026-04-30T10:00:00Z');
 assert(!expired({status:'resolved',resolvedAt},end-1));assert(expired({status:'resolved',resolvedAt},end));
 assert(!expired({status:'open',resolvedAt},end));assert(!expired({status:'resolved'},end));
});
test('cleanup scopes schools and locks before recursively deleting the complaint and thread',async()=>{
 const now=()=>Date.parse('2026-10-23T00:00:00Z');
 const rows=new Map([['a',{schoolId:'A',status:'resolved',resolvedAt:new Date('2026-01-01')}],['b',{schoolId:'B',status:'resolved',resolvedAt:new Date('2026-01-01')}],['c',{schoolId:'A',status:'open'}],['d',{schoolId:'A',status:'resolved',updatedAt:new Date('2026-10-22')}] ]),removed=[];let failChildren=true;
 const db={doc:path=>({id:path.split('/').pop(),delete:async()=>{const id=path.split('/').pop();removed.push(id);rows.delete(id);}}),collection:path=>{
  let after='',max=100,filter;const q={path,where:(k,op,v)=>{filter=[k,v];return q;},orderBy:()=>q,startAfter:v=>{after=v;return q;},limit:v=>{max=v;return q;},get:async()=>({docs:[...rows].filter(([id,v])=>id>after&&(!filter||v[filter[0]]===filter[1])).slice(0,max).map(([id,v])=>({id,data:()=>v}))})};return q;
 },runTransaction:async fn=>fn({get:async r=>({exists:rows.has(r.id),data:()=>rows.get(r.id)}),set:(r,v)=>rows.set(r.id,{...rows.get(r.id),...v})}),recursiveDelete:async r=>{assert.equal(r.path,'platform_complaints/a/messages');assert(rows.get('a').purging);if(failChildren){failChildren=false;throw Error('Synthetic interrupted message cleanup');}}};
 await assert.rejects(cleanupComplaints({db,now,schoolId:'A'}),/interrupted message cleanup/);assert(rows.has('a'),'parent survives child failure so next sweep retries');
 await cleanupComplaints({db,now,schoolId:'A'});assert.deepEqual(removed,['a']);assert(rows.has('b'));assert(rows.has('c'));assert.equal(rows.get('d').resolvedAt.toISOString(),'2026-10-22T00:00:00.000Z');
});
