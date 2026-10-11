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
test('registered universal Sheet previews then commits with real Script ACK/readback; Sheet edits reject plan',async()=>{
 const {storage}=require('./helpers/managed-storage'),{time}=require('./helpers/managed-school-broker');
 const s=storage();s.context.Date=class extends Date{static now(){return time;}};
 const f=fixture(async(url,opt)=>({ok:true,status:200,text:async()=>JSON.stringify(s.context.VS_managedHandle({postData:{contents:opt.body}}))}),{studentImportEnabled:true});
 const sheet=await f.call({action:'managed/student-import/sheet/setup',confirmCreate:true});assert.equal(sheet.headerVersion,1);
 const tab=s.books.get(sheet.sheetId).getSheetByName('Student Import v1');tab.getRange(2,1,1,7).setValues([[A,'S1','Synthetic Test','VI','',1,'']]);
 const preview=await f.call({action:'managed/student-import/preview',source:'designated-sheet'});assert.equal(preview.valid,true);assert.equal(preview.sourceSheetId,sheet.sheetId);
 const commit=await f.call({action:'managed/student-import/commit',source:'designated-sheet',planId:preview.planId});assert.equal(commit.verified,true);assert.equal((await f.call({action:'managed/student-import/commit',source:'designated-sheet',planId:preview.planId})).verified,true);
 tab.getRange(2,3,1,1).setValues([['Edited after preview']]);await assert.rejects(f.call({action:'managed/student-import/commit',source:'designated-sheet',planId:preview.planId}),e=>e.status===409);
});
test('numeric rolls and unrelated tombstones/legacy slots retain conservative affected-record protections',async()=>{
 const f=setup();f.records.deleted={schoolId:A,_syncRevision:'deleted-r',_syncDeleted:true};f.records.legacy={schoolId:A,name:'Old',_syncRevision:'legacy-r'};
 const p=await f.preview([row('S1',{rollNo:12})]);assert.equal(p.valid,true);assert.equal(p.uniquenessScope,'partial-legacy');assert.equal((await f.commit([row('S1',{rollNo:12})],p.planId)).verified,true);
 const deleted=await f.preview([row('deleted',{expectedRevision:'deleted-r'})]);assert.equal(deleted.valid,false);assert.equal(deleted.errors[0].code,'TOMBSTONE_REQUIRES_RESTORE');
});
test('encrypted admission bounds active previews to20 without school record deletion',async()=>{
 const f=setup();for(let i=0;i<20;i++)assert.equal((await f.preview([row('S'+i)])).valid,true);await assert.rejects(f.preview([row('overflow')]),e=>e.status===429);assert.equal(f.writes.length,0);
 const ledger=f.docs.get('school_import_admission_private/'+A);assert.equal(ledger.plans,undefined);assert.equal(JSON.parse(unprotect(ledger.sealed,key)).plans.length,20);
});
test('shared device hook enforces future PC import route and derives fresh registration auth from verified token',async()=>{
 const {generateKeyPairSync}=require('node:crypto');const states=new Map();const deviceStore={transaction:async(school,work)=>{const change=await work(states.get(school));states.set(school,change.state);return change.result;}};
 const f=setup({deviceAccessEnforced:true,deviceOfflinePrivateKey:generateKeyPairSync('ed25519').privateKey,deviceStore});
 await assert.rejects(f.preview([row()]),e=>e.code==='DEVICE_PROOF_REQUIRED');assert.equal(f.sent.length,0);
 const headers={authorization:'Bearer A','x-vidya-device-id':'D'.repeat(32),'x-vidya-device-credential':'C'.repeat(43)};
 const registered=await f.handle({method:'POST',headers,body:{action:'managed/device/register',deviceName:'TEST PC',deviceOs:'Windows'}});assert.equal(registered.success,true);assert.ok(registered.offlineLease);assert.equal(registered.deviceEnforced,true);
 const session=await f.handle({method:'POST',headers,body:{action:'managed/session'}});assert.equal(session.deviceEnforced,true);assert.ok(session.offlineLease);assert.ok(session.offlineExpiresAt);
 const p=await f.handle({method:'POST',headers,body:{action:'managed/student-import/preview',rows:[row()]}});assert.equal(p.valid,true);
});
test('expired preview metadata reuses fixed slots without growing retained documents or accepting old plan',async()=>{
 const {time}=require('./helpers/managed-school-broker');let clock=time;const f=setup({now:()=>clock});const previews=[];
 for(let i=0;i<20;i++)previews.push(await f.preview([row('OLD'+i)]));clock+=1800001;assert.equal((await f.preview([row('NEW')])).valid,true);
 assert.equal([...f.docs.keys()].filter(p=>p.startsWith('school_import_preview_private/')).length,20);await assert.rejects(f.commit([row('OLD0')],previews[0].planId),e=>e.status===409);assert.equal(f.writes.length,0);
});
