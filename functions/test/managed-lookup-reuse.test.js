'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {storage,A}=require('./helpers/managed-storage');
const request=(id,revision='',op='lookup-operation-0001')=>({action:'managed_records',operation:'write',collection:'teachers_directory',syncProtocol:2,id,operationId:op,expectedRecordRevision:revision,data:{schoolId:A,name:'Teacher',role:'teacher'}});
function countLookups(s){let count=0;const original=s.context.VS_sheetItem;s.context.VS_sheetItem=(...args)=>{count++;return original(...args);};return ()=>count;}
test('locked record write uses two authoritative lookups; replay does not rewrite the row',()=>{
 const s=storage(),count=countLookups(s),body=request('T1');const first=s.call(body);
 assert.equal(first.success,true);assert.equal(count(),2,'initial conflict lookup and final verification remain');
 const before=count(),replay=s.call(body);assert.equal(replay.success,true);assert.equal(replay.recordRevision,first.recordRevision);assert.equal(count()-before,1);
 const updated=s.call(request('T1',first.recordRevision,'lookup-operation-0002'));assert.equal(updated.success,true);assert.equal(count()-before,3);
 assert.equal(s.call(request('T1',first.recordRevision,'lookup-operation-0003')).success,false,'stale PC cannot overwrite');
});
test('duplicate inserted after initial lookup is rejected by final verification',()=>{
 const s=storage();assert.equal(s.call(request('T1')).success,true);
 const original=s.context.VS_sheetPut;s.context.VS_sheetPut=(store,item,lookup)=>{
  const values=store.sheet.getRange(2,1,1,33).getValues();store.sheet.getRange(3,1,1,33).setValues(values);
  return original(store,item,lookup);
 };
 const rev=s.context.VS_sheetItem(s.context.VS_managedSheet('teachers_directory'),'T1').data._syncRevision;
 assert.equal(s.call(request('T1',rev,'lookup-operation-0002')).success,false);
});
test('manual edit between conflict lookup and write is retained and receives no ACK',()=>{
 const s=storage(),first=s.call(request('T1'));const original=s.context.VS_sheetPut;
 s.context.VS_sheetPut=(store,item,lookup)=>{
  const raw=store.sheet.getRange(2,1,1,33).getValues(),record=JSON.parse(JSON.parse(raw[0][6]));
  record.data.name='Owner edit';raw[0][6]=JSON.stringify(JSON.stringify(record));store.sheet.getRange(2,1,1,33).setValues(raw);
  return original(store,item,lookup);
 };
 assert.equal(s.call(request('T1',first.recordRevision,'lookup-operation-0002')).success,false);
 assert.equal(s.context.VS_sheetItem(s.context.VS_managedSheet('teachers_directory'),'T1').data.name,'Owner edit');
});
test('changed bytes after flush cannot produce a verified receipt',()=>{
 const s=storage(),first=s.call(request('T1')),store=s.context.VS_managedSheet('teachers_directory');
 s.context.SpreadsheetApp.flush=()=>{const raw=store.sheet.getRange(2,1,1,33).getValues();const item=JSON.parse(JSON.parse(raw[0][6]));item.data.name='Corrupted';raw[0][6]=JSON.stringify(JSON.stringify(item));store.sheet.getRange(2,1,1,33).setValues(raw);};
 assert.equal(s.call(request('T1',first.recordRevision,'lookup-operation-0002')).success,false);
});
test('timing diagnostics are TEST-only and include teacher lookup counts',()=>{
 const s=storage({schoolId:'vs-db8afb01a3be46a983c8284714d06e5d'}),body=request('T1');body.data.schoolId=s.props.get('VS_MANAGED_SCHOOL_ID');body.data.syntheticTest=true;
 const result=s.call(body);assert.equal(result.success,true);assert.equal(result.testScriptTiming.recordLookupCount,2);assert.equal(result.testScriptTiming.scope,'isolated_synthetic_TEST_only');
 const ordinary=storage(),normal=request('T1');normal.data.syntheticTest=true;
 assert.equal(ordinary.call(normal).testScriptTiming,undefined);
 body.operationId='lookup-operation-0002';body.expectedRecordRevision=result.recordRevision;body.data.syntheticTest=false;
 assert.equal(s.call(body).testScriptTiming,undefined,'instrumentation cannot leak to the next request');
});
