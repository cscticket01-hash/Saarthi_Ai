'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {createMobileComplaints}=require('../mobile-complaints');
function fixture(){const rows=new Map();let identity={attendancePolicy:{role:'student',personId:'verified'},person:{name:'Pupil',class:'7',rollNo:'4'}};const db={doc:path=>({path}),runTransaction:async fn=>fn({get:async r=>({exists:rows.has(r.path),data:()=>rows.get(r.path)}),set:(r,v)=>rows.set(r.path,v)}),collection:path=>{
 let filters=[],after='';const q={where:(k,op,v)=>{filters.push([k,v]);return q;},orderBy:()=>q,startAfter:id=>{after=id;return q;},limit:()=>q,get:async()=>({docs:[...rows].filter(([key,v])=>key.startsWith(path+'/')&&key.split('/').pop()>after&&filters.every(([k,val])=>v[k]===val)).map(([key,v])=>({id:key.split('/').pop(),data:()=>v}))})};return q;}};
 const call=createMobileComplaints({db,now:()=>1800000000000,fail:(status,message)=>{throw Object.assign(Error(message),{status});},verify:async()=>identity});return {rows,call,setIdentity:v=>identity=v};}
test('verified class/person override client claims; retries are idempotent and histories cannot cross person/school',async()=>{
 const f=fixture(),request={action:'mobile_complaint',complaintId:'a'.repeat(32),message:'Cannot see my ID',personId:'forged',class:'Other class',device:'Samsung Android'};
 await f.call('schoolA',request);await f.call('schoolA',request);
 const value=f.rows.get('platform_complaints/schoolA_'+request.complaintId);assert.equal(value.studentClass,'7');assert.equal(value.personId,'verified');assert.equal(value.audience,'school');
 assert.equal((await f.call('schoolA',{action:'mobile_complaints'})).complaints.length,1);
 assert.equal((await f.call('schoolB',{action:'mobile_complaints'})).complaints.length,0);
 f.setIdentity({personId:'another',role:'student'});assert.equal((await f.call('schoolA',{action:'mobile_complaints'})).complaints.length,0);
 await assert.rejects(f.call('schoolA',request),e=>e.status===409);
 f.setIdentity({});await assert.rejects(f.call('schoolA',{action:'mobile_complaints'}),e=>e.status===403);
});
