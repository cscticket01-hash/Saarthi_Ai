'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {storage,A,B}=require('./helpers/managed-storage');
const {fixture}=require('./helpers/managed-school-broker');
const write=(s,id,data={title:'Original'})=>s.call({action:'managed_records',operation:'write',collection:'school_notices',id,syncProtocol:2,operationId:'integrity-operation-'+id,expectedRecordRevision:'',data:{schoolId:A,...data}});
const audit=(s,body={})=>s.call({action:'managed_integrity_audit',collection:'school_notices',...body});
function replacePayload(s,id,change){const store=s.context.VS_managedSheet('school_notices'),item=s.context.VS_sheetItem(store,id),range=store.sheet.getRange(item.row,1,1,33),row=range.getValues()[0];const data=change({...item.data}),text=JSON.stringify({id,schoolId:A,data});for(let i=0;i<27;i++){const part=text.slice(i*20000,(i+1)*20000);row[6+i]=part?JSON.stringify(part):'';}range.setValues([row]);return {store,item,data};}
test('bounded audit catches payload drift without modifying original rows, heads or properties',()=>{
 const s=storage({lifecycle:true});assert(write(s,'one').success);replacePayload(s,'one',data=>({...data,title:'Edited directly'}));
 const store=s.context.VS_managedSheet('school_notices'),before=JSON.stringify(store.sheet.getRange(1,1,store.sheet.getLastRow(),33).getValues()),props=JSON.stringify([...s.props].filter(([key])=>!key.startsWith('VS_NONCE_')));
 const out=audit(s);assert.equal(out.success,true);assert.deepEqual(out.findings,[{id:'one',reason:'unmanaged_payload_change'}]);assert.equal(out.readOnly,true);
 assert.equal(JSON.stringify(store.sheet.getRange(1,1,store.sheet.getLastRow(),33).getValues()),before);assert.equal(JSON.stringify([...s.props].filter(([key])=>!key.startsWith('VS_NONCE_'))),props);
 const blocked=s.call({action:'managed_records',operation:'write',collection:'school_notices',id:'one',syncProtocol:2,operationId:'integrity-later-operation',expectedRecordRevision:s.context.VS_sheetItem(store,'one').data._syncRevision,data:{schoolId:A,title:'Overwrite'}});
 assert.equal(blocked.success,false);assert.equal(blocked.code,'SCRIPT_EXTERNAL_EDIT_REVIEW_REQUIRED');assert.equal(s.context.VS_sheetItem(store,'one').data.title,'Edited directly');
});
test('identical operation retry cannot acknowledge externally changed payload',()=>{
 const s=storage({lifecycle:true});assert(write(s,'one').success);replacePayload(s,'one',data=>({...data,title:'Changed'}));assert.equal(write(s,'one').code,'SCRIPT_EXTERNAL_EDIT_REVIEW_REQUIRED');
});
test('missing live row and deliberate tombstone never restore during audit',()=>{
 const s=storage({lifecycle:true});const first=write(s,'live'),second=write(s,'deleted');assert(first.success&&second.success);
 assert(s.call({action:'managed_records',operation:'delete',collection:'school_notices',id:'deleted',syncProtocol:2,operationId:'integrity-delete-operation',expectedRecordRevision:second.recordRevision}).success);
 const store=s.context.VS_managedSheet('school_notices');for(const id of ['live','deleted']){const row=s.context.VS_sheetItem(store,id).row;store.sheet.getRange(row,1,1,33).setValues([Array(33).fill('')]);}
 assert.deepEqual(audit(s).findings,[{id:'live',reason:'missing_live_row'}]);assert.equal(s.context.VS_sheetItem(store,'live'),null);assert.equal(s.context.VS_sheetItem(store,'deleted'),null);
});
test('at most 25 existing heads per page; foreign identity rejected',()=>{
 const s=storage({lifecycle:true});for(let i=0;i<31;i++)assert(write(s,'record-'+i).success);
 const first=audit(s);assert.equal(first.checked,25);assert.equal(first.nextRow,27);assert.equal(audit(s,{afterRow:27}).checked,6);
 const sheet=s.context.VS_syncStateSheet(false,'school_notices'),head=JSON.parse(sheet.getRange(2,2,1,1).getValues()[0][0]);head.schoolId=B;sheet.getRange(2,2,1,1).setValues([[JSON.stringify(head)]]);
 assert.equal(audit(s).success,false);assert.equal(audit(s,{afterRow:-1}).success,false);
});
test('student readable edit is detected without importing or overwriting it',()=>{
 const s=storage({lifecycle:true});assert(s.call({action:'managed_records',operation:'write',collection:'students_directory',id:'Class_1_Roll_1',syncProtocol:2,operationId:'integrity-student-operation',expectedRecordRevision:'',data:{schoolId:A,name:'Original',class:'Class 1',rollNo:'1'}}).success);
 const store=s.context.VS_managedSheet('students_directory'),item=s.context.VS_sheetItem(store,'Class_1_Roll_1');store.sheet.getRange(item.row,34,1,1).setValues([['Direct name']]);
 const out=s.call({action:'managed_integrity_audit',collection:'students_directory'});assert.equal(out.findings[0].reason,'readable_projection_change');assert.equal(s.context.VS_sheetItem(store,item.id).data.name,'Original');assert.equal(store.sheet.getRange(item.row,34,1,1).getValues()[0][0],'Direct name');
});
test('new school audit creates no workbook; legacy mode safely reports unsupported',()=>{
 const s=storage({lifecycle:true}),size=s.books.size;assert.equal(audit(s).coverage,'no_verified_heads');assert.equal(s.books.size,size);assert.equal(audit(storage()).coverage,'unsupported_storage');
});
test('broker signs bounded audit and rejects cross-school access',async()=>{
 let sent;const f=fixture(async(url,opt)=>{sent=JSON.parse(JSON.parse(opt.body).payload);return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,integrityAuditVersion:1})};});
 await f.call({action:'managed/integrity/audit',schoolId:A,collection:'school_notices',afterRow:27,rootId:'ignored'});assert.deepEqual(sent,{action:'managed_integrity_audit',collection:'school_notices',afterRow:27});
 await assert.rejects(f.call({action:'managed/integrity/audit',schoolId:B,collection:'school_notices'}),e=>e.status===403);
 await assert.rejects(f.call({action:'managed/integrity/audit',collection:'platform_schools'}),e=>e.status===400);
});

test('metadata-bypass revision changes remain unverified; unrelated records still write safely',()=>{
 const s=storage({lifecycle:true});assert(write(s,'one').success);replacePayload(s,'one',data=>({...data,_syncRevision:'external-revision',title:'Changed'}));
 const result=s.call({action:'managed_records',operation:'write',collection:'school_notices',id:'one',syncProtocol:2,operationId:'integrity-later-operation',expectedRecordRevision:'external-revision',data:{schoolId:A,title:'Blind overwrite'}});
 assert.equal(result.code,'SCRIPT_EXTERNAL_EDIT_REVIEW_REQUIRED');assert(write(s,'independent').success);
});
test('generic readable edits are diagnosed across fee/teacher/document-style projection columns',()=>{
 const s=storage({lifecycle:true});assert(write(s,'notice').success);
 const store=s.context.VS_managedSheet('school_notices'),item=s.context.VS_sheetItem(store,'notice');store.sheet.getRange(item.row,36,1,1).setValues([['Direct edit']]);
 assert.equal(audit(s).findings[0].reason,'readable_projection_change');
});

test('neither full read nor point read can certify unmanaged canonical drift as a verified snapshot',()=>{
 const s=storage({lifecycle:true});assert(write(s,'one').success);
 replacePayload(s,'one',data=>({...data,title:'Unverified external content'}));
 for(const extra of [{},{id:'one'}]){
  const response=s.call({action:'managed_records',operation:'read',collection:'school_notices',syncProtocol:2,...extra});
  assert.equal(response.success,false);assert.equal(response.code,'SCRIPT_EXTERNAL_EDIT_REVIEW_REQUIRED');
 }
});

test('broker advertises its own audit capability independently of the deployed Script version',async()=>{
 const f=fixture();const result=await f.call({action:'managed/storage/check',schoolId:A});
 assert.equal(result.brokerSheetIntegrityAuditVersion,1);assert.equal(result.sheetIntegrityAuditVersion,undefined);
});
