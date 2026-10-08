'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {fixture,A,B,time}=require('./helpers/managed-school-broker');
function cachedFixture(){let at=time,calls=0;
 const f=fixture(async(_,opt)=>{calls++;const body=JSON.parse(JSON.parse(opt.body).payload);return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,sessionExpiresAt:at+20000,person:{id:'pupil',schoolId:A},revision:'r'+calls,recordRevision:'ack',syncProtocol:2,...(body.action==='managed_view'?{groups:{exams:{count:0,rows:[]}},revisions:{exams:'r'+calls}}:{})})};},{now:()=>at});
 return {...f,get calls(){return calls;},advance:n=>at+=n};
}
const request=token=>({action:'managed/mobile',schoolId:A,request:{action:'mobile_dashboard',sessionToken:token}});
test('verified dashboard cache avoids Script reads for same session, returns independent copies, expires and never crosses sessions',async()=>{
 const f=cachedFixture();const first=await f.call(request('x'.repeat(48)));first.person.id='changed-client';
 assert.equal((await f.call(request('x'.repeat(48)))).person.id,'pupil');assert.equal(f.calls,1);
 await f.call(request('y'.repeat(48)));assert.equal(f.calls,2);
 f.advance(5001);await f.call(request('x'.repeat(48)));assert.equal(f.calls,3);
});
test('acknowledged Windows writes invalidate cached dashboard and website view; logout invalidates a session view',async()=>{
 const f=cachedFixture();await f.call(request('x'.repeat(48)));await f.call({action:'developer/managed/view',schoolId:A},'developer');
 await f.call({action:'managed/records',collection:'school_notices',operation:'write',id:'new',syncProtocol:2,operationId:'operation-1234567890',expectedRecordRevision:'',data:{title:'Updated'}});
 const before=f.calls;await f.call(request('x'.repeat(48)));await f.call({action:'developer/managed/view',schoolId:A},'developer');assert.equal(f.calls,before+2);
 await f.call({action:'managed/mobile',schoolId:A,request:{action:'mobile_logout',sessionToken:'x'.repeat(48)}});const logout=f.calls;await f.call(request('x'.repeat(48)));assert.equal(f.calls,logout+1);
});
test('cache never bypasses disabled school access or foreign signed identity',async()=>{
 const f=cachedFixture();await f.call(request('x'.repeat(48)));
 await f.call({action:'developer/managed/block',schoolId:A,blocked:true},'developer');await assert.rejects(f.call(request('x'.repeat(48))),e=>e.status===403);
 const foreign=fixture(async()=>({ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:B,sessionExpiresAt:time+10000})}));
 await assert.rejects(foreign.call(request('x'.repeat(48))),e=>e.status===502);await assert.rejects(foreign.call(request('x'.repeat(48))),e=>e.status===502);assert.equal(foreign.sent.length,2);
});
test('missing or expired signed session expiry cannot populate cache',async()=>{
 for(const expiry of [undefined,time-1]){const f=fixture(async()=>({ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,sessionExpiresAt:expiry})}));await f.call(request('x'.repeat(48)));await f.call(request('x'.repeat(48)));assert.equal(f.sent.length,2);}
});
test('attendance status exposes only same-school durable ACK state, never queued payload or another school',async()=>{
 const f=fixture();const one='a'.repeat(64),two='b'.repeat(64);f.docs.set('attendance_outbox/'+one,{schoolId:A,state:'completed',createdAt:time-10,completedAt:time,payload:'private'});f.docs.set('attendance_outbox/'+two,{schoolId:B,state:'pending',payload:'foreign'});
 const result=await f.call({action:'managed/attendance/status',operationIds:[one]});assert.equal(result.operations[0].state,'completed');assert.equal(result.operations[0].completedAt,time);assert(!JSON.stringify(result).includes('private'));
 await assert.rejects(f.call({action:'managed/attendance/status',operationIds:[two]}),e=>e.status===403);
 await assert.rejects(f.call({action:'managed/attendance/status',operationIds:[one,one]}),e=>e.status===400);
});
test('an in-flight old dashboard cannot repopulate cache after an acknowledged mutation',async()=>{
 let release,reads=0;const wait=new Promise(r=>release=r);
 const f=fixture(async(_,opt)=>{const body=JSON.parse(JSON.parse(opt.body).payload);if(body.action==='managed_mobile'&&body.request.action==='mobile_dashboard'){reads++;if(reads===1)await wait;}return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,sessionExpiresAt:time+10000,syncProtocol:2,recordRevision:'ack'})};});
 const first=f.call(request('x'.repeat(48)));await new Promise(r=>setImmediate(r));
 await f.call({action:'managed/records',collection:'school_notices',operation:'write',id:'new',syncProtocol:2,operationId:'race-operation-12345',expectedRecordRevision:'',data:{title:'Updated'}});
 release();await first;await f.call(request('x'.repeat(48)));assert.equal(reads,2);
});
