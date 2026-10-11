'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {unprotect,protect}=require('../managed-schools');
const {fixture,A,B,key}=require('./helpers/managed-school-broker');
const row=(id='S1',extra={})=>({schoolId:A,studentId:id,name:'New Name',class:'VI',section:'',rollNo:id,expectedRevision:null,...extra});
function setup(options={}){
 const records={},writes=[];let mode='';
 const f=fixture(async(url,opt)=>{
  const envelope=JSON.parse(opt.body),b=JSON.parse(envelope.payload);let result={success:true,schoolId:envelope.schoolId,syncProtocol:2};
  if(b.operation==='read')result={...result,collectionRevision:'head',records:structuredClone(records)};
  else {
   const prior=records[b.id];
   if(mode==='race'){records[b.id]={...prior,name:'Concurrent',_syncRevision:'newer'};mode='';}
   if((records[b.id]?._syncRevision||'')!==b.expectedRecordRevision)result={...result,success:false,message:'Record revision conflict'};
   else {writes.push(b);records[b.id]={...structuredClone(b.data),_syncRevision:'rev-'+writes.length,_syncOperationId:b.operationId};result.recordRevision=records[b.id]._syncRevision;
    if(mode==='lost'){mode='';throw Error('Response lost after commit');}
    if(mode==='badread')records[b.id].name='Mismatch';
   }
  }
  return {ok:true,status:200,text:async()=>JSON.stringify(result)};
 },{studentImportEnabled:true,...options});
 return {...f,records,writes,setMode:v=>{mode=v;},preview:rows=>f.call({action:'managed/student-import/preview',rows}),commit:(rows,planId)=>f.call({action:'managed/student-import/commit',rows,planId})};
}
test('import is inactive by default, admin/school bound and limited to100 rows',async()=>{
 const f=setup({studentImportEnabled:false});await assert.rejects(f.preview([row()]),e=>e.code==='IMPORT_DISABLED');assert.equal(f.writes.length,0);
 const g=setup();await assert.rejects(g.call({action:'managed/student-import/preview',schoolId:B,rows:[row()]},'A'),e=>e.status===403);
 g.docs.get('school_memberships/A').role='student';await assert.rejects(g.preview([row()]),e=>e.status===403);
 const h=setup();await assert.rejects(h.preview(Array(101).fill(row())),e=>e.status===400);
});
test('preview omits sensitive existing fields; CAS update preserves them and verifies complete readback',async()=>{
 const f=setup();f.records.S1={schoolId:A,name:'Old',studentClass:'VI',section:'',rollNo:'S1',mobileLinkToken:'original-token',photoUrl:'original-photo',feeRef:'original-fee',_syncRevision:'r1'};
 const rows=[row('S1',{expectedRevision:'r1'})],preview=await f.preview(rows);
 assert.equal(JSON.stringify(preview).includes('original-token'),false);assert.equal(f.writes.length,0);
 const out=await f.commit(rows,preview.planId);assert.equal(out.verified,true);assert.equal(f.writes[0].expectedRecordRevision,'r1');
 for(const [key,value]of Object.entries({mobileLinkToken:'original-token',photoUrl:'original-photo',feeRef:'original-fee'}))assert.equal(f.records.S1[key],value);
 assert.equal((await f.commit(rows,preview.planId)).verified,true);assert.equal(f.writes.length,1);
});
test('lost response stays pending and exact saved identity reconciles without duplicate write',async()=>{
 const f=setup(),rows=[row()],p=await f.preview(rows);f.setMode('lost');const first=await f.commit(rows,p.planId);
 assert.equal(first.verified,false);assert.equal(first.outcomes[0].state,'pending');assert.equal((await f.commit(rows,p.planId)).verified,true);assert.equal(f.writes.length,1);assert.equal(first.outcomes[0].operationId,f.records.S1._syncOperationId);
});
test('newer baseline or CAS race stops and retains newer record',async()=>{
 for(const race of [false,true]){const f=setup();f.records.S1={schoolId:A,name:'Old',studentClass:'VI',section:'',rollNo:'S1',_syncRevision:'r1'};const rows=[row('S1',{expectedRevision:'r1'})],p=await f.preview(rows);if(race)f.setMode('race');else f.records.S1._syncRevision='newer';const result=await f.commit(rows,p.planId);assert.equal(result.outcomes[0].state,'conflict');assert.equal(f.writes.length,0);assert.equal(f.records.S1._syncRevision,'newer');}
});
test('mismatched plan/rows, expiry, foreign snapshot and readback mismatch cannot verify',async()=>{
 const f=setup(),rows=[row()],p=await f.preview(rows);await assert.rejects(f.commit([row('S2')],p.planId),e=>e.status===409);
 const saved=[...f.docs].find(([k])=>k.startsWith('school_import_preview_private/'))[1];const expired=JSON.parse(unprotect(saved.sealed,key));expired.expiresAt=0;saved.sealed=protect(JSON.stringify(expired),key);await assert.rejects(f.commit(rows,p.planId),e=>e.status===409);
 const g=setup();g.records.S1={schoolId:B,_syncRevision:'r1'};await assert.rejects(g.preview(rows),e=>e.status===409);
 const h=setup(),q=await h.preview(rows);h.setMode('badread');assert.equal((await h.commit(rows,q.planId)).outcomes[0].state,'pending');
});

test('client-written preview metadata or forged ciphertext cannot grant commit',async()=>{const f=setup(),rows=[row()],p=await f.preview(rows);const saved=[...f.docs].find(([k])=>k.startsWith('school_import_preview_private/'))[1];saved.actor='A';saved.operations=[{data:{name:'Injected'}}];assert.equal((await f.commit(rows,p.planId)).verified,true);assert.equal(f.records.S1.name,'New Name');saved.sealed.body='forged';await assert.rejects(f.commit(rows,p.planId),e=>e.status===409);});
