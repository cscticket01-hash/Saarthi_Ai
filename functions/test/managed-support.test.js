'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {fixture,A,B,time}=require('./helpers/managed-school-broker');
function setup(){const f=fixture();f.db.collection=path=>{
 const filters=[];let after='',max=50;
 const q={where:(key,op,value)=>{filters.push([key,value]);return q;},orderBy:()=>q,startAfter:value=>{after=value;return q;},limit:value=>{max=value;return q;},get:async()=>({docs:[...f.docs].filter(([p,v])=>p.startsWith(path+'/')&&!p.slice(path.length+1).includes('/')&&p.slice(path.length+1)>after&&filters.every(([key,value])=>v[key]===value)).sort(([a],[b])=>a.localeCompare(b)).slice(0,max).map(([p,v])=>({id:p.slice(path.length+1),data:()=>v}))})};return q;};return f;}
const id=A+'_'+'a'.repeat(32),other=B+'_'+'b'.repeat(32);
test('school complaint creation is durable and idempotent; foreign school cannot enumerate, reply or spoof sender',async()=>{
 const f=setup(),message='Synthetic local app problem';
 await f.call({action:'managed/support/create',complaintId:id,message,version:'test'});
 await f.call({action:'managed/support/create',complaintId:id,message,version:'test'});
 assert.equal(f.docs.get('platform_complaints/'+id).schoolId,A);
 assert.equal(f.docs.get('platform_complaints/'+id).createdAt.getTime(),time);
 assert.equal(f.docs.get('platform_support_limits/'+A).lastSentAt.getTime(),time);
 await assert.rejects(f.call({action:'managed/support/create',complaintId:A+'_'+'d'.repeat(32),message}),e=>e.status===429);
 await assert.rejects(f.call({action:'managed/support/create',complaintId:id,message:'Changed body'}),e=>e.status===409);
 f.docs.set('platform_complaints/'+other,{schoolId:B,message:'Foreign private complaint',createdAt:time});
 const list=await f.call({action:'managed/support/list'});assert.equal(list.complaints.length,1);assert.equal(list.complaints[0].id,id);assert(!JSON.stringify(list).includes('Foreign private'));
 await assert.rejects(f.call({action:'managed/support/thread',complaintId:id},'B'),e=>e.status===404);
 await assert.rejects(f.call({action:'managed/support/reply',complaintId:id,messageId:time+'_'+'c'.repeat(32),message:'Foreign reply'},'B'),e=>e.status===404);
 await assert.rejects(f.call({action:'managed/support/list',schoolId:B}),e=>e.status===403);
 const reply={action:'managed/support/reply',complaintId:id,messageId:time+'_'+'c'.repeat(32),message:'More details',role:'developer'};
 await f.call(reply);await f.call(reply);
 const thread=await f.call({action:'managed/support/thread',complaintId:id});assert.equal(thread.messages.length,1);assert.equal(thread.messages[0].role,'school');
 await assert.rejects(f.call({...reply,message:'Changed retry'}),e=>e.status===409);
 assert.equal(f.sent.length,0,'support never calls school Drive or uploads operational data');
});
test('complaint history paginates beyond 50 records and validates identifiers',async()=>{
 const f=setup();for(let i=0;i<55;i++)f.docs.set('platform_complaints/'+A+'_'+i.toString(16).padStart(32,'0'),{schoolId:A,message:'Record '+i,createdAt:time+i});
 const first=await f.call({action:'managed/support/list'});assert.equal(first.complaints.length,50);assert(first.cursor);
 const second=await f.call({action:'managed/support/list',cursor:first.cursor});assert.equal(second.complaints.length,5);assert.equal(second.cursor,null);
 await assert.rejects(f.call({action:'managed/support/thread',complaintId:'../foreign'}),e=>e.status===400);
 f.docs.get('school_memberships/A').active=false;await assert.rejects(f.call({action:'managed/support/list'}),e=>e.status===403);
});
