'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {storage,A}=require('./helpers/managed-storage');
const {fixture,time}=require('./helpers/managed-school-broker');
function write(s,id,data,revision='',operation='write'){
 const out=s.call({action:'managed_records',operation,collection:'school_notices',id,syncProtocol:2,operationId:'record-only-operation-'+id+'-'+(revision||'create'),expectedRecordRevision:revision,...(operation==='write'?{data:{schoolId:A,...data}}:{})});assert.equal(out.success,true,JSON.stringify(out));return out.recordRevision;
}
function baseline(s){const r=s.call({action:'managed_delta',collections:['school_notices'],knownRevisions:{}});assert.equal(r.success,true);const g=r.changes.school_notices;return {revision:g.collectionRevision,records:Object.fromEntries(Object.entries(g.records).map(([id,d])=>[id,d._syncRevision]))};}
const delta=(s,known)=>s.call({action:'managed_delta',collections:['school_notices'],knownRevisions:{school_notices:known.revision},knownRecordRevisions:{school_notices:known.records}});
test('unchanged incremental checkpoint reads zero Sheet or Drive files and returns no payload',()=>{
 const s=storage({lifecycle:true});write(s,'a',{title:'Keep'});const known=baseline(s);
 s.context.SpreadsheetApp.openById=()=>{throw Error('Unchanged opened Sheet');};s.context.DriveApp.getFileById=()=>{throw Error('Unchanged opened Drive');};s.context.DriveApp.getFolderById=()=>{throw Error('Unchanged opened root');};
 const out=delta(s,known);assert.equal(out.success,true);assert.equal(out.changes.school_notices.unchanged,true);assert.deepEqual(out.changes.school_notices.records,{});
});
test('changed collection returns only added edited and deleted records, never untouched payload',()=>{
 const s=storage({lifecycle:true});const revisions={};for(const id of ['a','b','c','keep'])revisions[id]=write(s,id,{title:'Original '+id});const known=baseline(s);
 write(s,'a',{title:'Edited'},revisions.a);write(s,'b',{},revisions.b,'delete');write(s,'new',{title:'New'});
 const store=s.context.VS_managedSheet('school_notices'),range=store.sheet.getRange.bind(store.sheet);let canonicalRows=0;
 store.sheet.getRange=(r,c,h,w)=>{const out=range(r,c,h,w),get=out.getValues;out.getValues=()=>{if(c===1&&w===33)canonicalRows+=h;return get();};return out;};
 const out=delta(s,known);assert.equal(out.success,true,JSON.stringify(out));const group=out.changes.school_notices;
 assert.equal(group.partialRecords,true);assert.deepEqual(Object.keys(group.records).sort(),['a','b','new']);assert.equal(group.records.b._syncDeleted,true);assert.equal(group.records.a.title,'Edited');assert.equal(canonicalRows,3,'read exactly three changed canonical rows, not the whole collection');
 const merged={revision:group.collectionRevision,records:{...known.records,...Object.fromEntries(Object.entries(group.records).map(([id,d])=>[id,d._syncRevision]))}};
 assert.equal(Object.keys(merged.records).length,5);assert.equal(delta(s,merged).changes.school_notices.unchanged,true);
});
test('corrupt sync metadata fails closed without a full-record fallback',()=>{
 const s=storage({lifecycle:true});const rev=write(s,'a',{title:'Retain'}),known=baseline(s);write(s,'a',{title:'Changed'},rev);
 const sheet=s.context.VS_syncStateSheet(false,'school_notices'),range=sheet.getRange(2,2,1,1),head=JSON.parse(range.getValues()[0][0]);head.payloadHash='damaged';range.setValues([[JSON.stringify(head)]]);
 const out=delta(s,known);assert.equal(out.success,false);assert.equal(out.code,'SCRIPT_RECORD_VERIFY_FAILED');
});
test('malformed foreign and oversized checkpoint metadata are rejected before record access',()=>{
 const s=storage({lifecycle:true});s.context.VS_managedSheet=()=>{throw Error('Record access before validation');};
 for(const checkpoints of [null,[],{foreign:{}},{school_notices:null},{school_notices:{a:''}},{school_notices:{'../bad':'r'}},{school_notices:{a:12}}]){
  const out=s.call({action:'managed_delta',collections:['school_notices'],knownRevisions:{},knownRecordRevisions:checkpoints});assert.equal(out.success,false);
 }
});
test('broker forwards signed record checkpoints and validates partial response provenance',async()=>{
 const s=storage({lifecycle:true});write(s,'a',{title:'Synthetic'});const known=baseline(s);
 class FixedDate extends Date {static now(){return time;}}s.context.Date=FixedDate;
 const b=fixture(async(_,opt)=>({ok:true,status:200,text:async()=>JSON.stringify(s.context.VS_managedHandle({postData:{contents:opt.body}}))}));
 const request={action:'managed/changes',collections:['school_notices'],knownRevisions:{school_notices:known.revision},knownRecordRevisions:{school_notices:known.records}};
 const out=await b.call(request);assert.equal(out.changes.school_notices.partialRecords,true);assert.equal(out.changes.school_notices.unchanged,true);
 await assert.rejects(b.call({...request,knownRecordRevisions:{school_notices:{a:42}}}),e=>e.status===400);
 const bad=fixture(async()=>({ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,syncProtocol:2,changes:{school_notices:{records:{},collectionRevision:'r',syncProtocol:2,partialRecords:true}}})}));
 await assert.rejects(bad.call({action:'managed/changes',collections:['school_notices'],knownRevisions:{}}),e=>e.status===502);
});
test('empty baseline discovers its first addition without another full snapshot',()=>{
 const s=storage({lifecycle:true}),known=baseline(s);write(s,'first',{title:'First'});
 const out=delta(s,known);assert.equal(out.success,true);assert.equal(out.changes.school_notices.partialRecords,true);assert.deepEqual(Object.keys(out.changes.school_notices.records),['first']);
});
test('missing sync-state identity never becomes a successful empty delta',()=>{
 const s=storage({lifecycle:true}),rev=write(s,'a',{title:'Retain'}),known=baseline(s);write(s,'a',{title:'Changed'},rev);s.props.delete('VS_SYNC_STATE_SHEET_ID');
 const out=delta(s,known);assert.equal(out.success,false);assert.equal(out.code,'SCRIPT_SYNC_STATE_UNAVAILABLE');
});
test('over-limit checkpoint metadata is rejected rather than silently truncated',()=>{
 const s=storage({lifecycle:true}),records=Object.fromEntries(Array.from({length:100001},(_,n)=>['id-'+n,'r']));
 const out=delta(s,{revision:'older',records});assert.equal(out.success,false);
});
