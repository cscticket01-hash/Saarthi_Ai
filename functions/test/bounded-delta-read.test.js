'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {storage,A}=require('./helpers/managed-storage');
function write(s,collection,id,data){const out=s.call({action:'managed_records',operation:'write',collection,id,syncProtocol:2,operationId:'bounded-delta-operation-'+id,expectedRecordRevision:'',data:{schoolId:A,...data}});assert.equal(out.success,true,JSON.stringify(out));}
test('three-collection verified delta opens each school workbook once per request and revalidates next request',()=>{
 const s=storage({lifecycle:true}),cols=['students_directory','school_notices','fee_payments'];
 cols.forEach((c,n)=>write(s,c,'record-'+n,{name:'Synthetic',amount:500}));
 const request={action:'managed_delta',collections:cols,knownRevisions:{}};
 assert.equal(s.call(request).success,true);
 let opens=0;const open=s.context.SpreadsheetApp.openById;s.context.SpreadsheetApp.openById=id=>{opens++;return open(id);};
 const out=s.call(request);assert.equal(out.success,true);assert.equal(out.changes.fee_payments.records['record-2'].amount,500);assert.equal(opens,2);
 opens=0;assert.equal(s.call(request).success,true);assert.equal(opens,2,'no workbook verification persists across requests');
 s.all.get(s.props.get('VS_MANAGED_SHEET_ID')).setDescription('foreign school marker');
 assert.equal(s.call(request).success,false,'new request must recheck school ancestry and marker');
});
test('100 derived rows use one verified batch and unchanged warm projection performs no writes',()=>{
 const s=storage({lifecycle:true});for(let n=0;n<100;n++)write(s,'school_notices','notice-'+n,{title:'Synthetic '+n});
 const store=s.context.VS_managedSheet('school_notices'),key='VS_RECORD_VIEW_FIELDS_legacy:school_notices';
 s.props.set(key+'_cursor','2');let writes=0,flushes=0;const range=store.sheet.getRange.bind(store.sheet);
 store.sheet.getRange=(...args)=>{const r=range(...args),set=r.setValues.bind(r);r.setValues=v=>{if(args[1]===34)writes++;return set(v);};return r;};
 s.context.SpreadsheetApp.flush=()=>flushes++;
 s.context.VS_refreshRecordReadable(store);assert.equal(writes,1);assert.equal(flushes,1);assert.equal(s.props.get(key+'_cursor'),'102');
 assert.equal(range(101,34,1,1).getValues()[0][0],'notice-99');
 writes=0;flushes=0;s.context.VS_refreshRecordReadable(store);assert.equal(writes,0);assert.equal(flushes,0);
});
test('failed batched projection readback retains cursor and all canonical records',()=>{
 const s=storage({lifecycle:true});for(let n=0;n<3;n++)write(s,'school_notices','verify-'+n,{title:'Retain '+n});
 const store=s.context.VS_managedSheet('school_notices'),key='VS_RECORD_VIEW_FIELDS_legacy:school_notices';s.props.set(key+'_cursor','2');
 const range=store.sheet.getRange.bind(store.sheet);store.sheet.getRange=(...a)=>{const r=range(...a);if(a[0]===2&&a[1]===34&&a[2]===3){const get=r.getValues.bind(r);r.getValues=()=>{const rows=get();rows[0][0]='corrupt-readback';return rows;};}return r;};
 s.context.VS_refreshRecordReadable(store);assert.equal(s.props.get(key+'_cursor'),'2');assert.match(s.props.get('VS_RECORD_READABLE_STATUS_school_notices'),/blocked/);
 const rows=s.context.VS_sheetRecords(store);for(let n=0;n<3;n++)assert.equal(rows['verify-'+n].title,'Retain '+n);
});
