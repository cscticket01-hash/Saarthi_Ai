'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {storage,A}=require('./helpers/managed-storage');
function fixture(){
 const s=storage({lifecycle:true});
 const ack=s.call({action:'managed_records',collection:'school_notices',operation:'write',id:'timing-row',syncProtocol:2,operationId:'head-reuse-initial-0001',expectedRecordRevision:'',data:{schoolId:A,title:'Synthetic'}});
 assert.equal(ack.success,true);
 const store=s.context.VS_managedSheet('school_notices'),item=s.context.VS_sheetItem(store,'timing-row');
 return {s,store,item};
}
test('one head save opens its verified workbook once, but another save revalidates it',()=>{
 const {s,store,item}=fixture(),stateId=s.props.get('VS_SYNC_STATE_SHEET_ID');
 const open=s.context.SpreadsheetApp.openById;let opens=0;
 s.context.SpreadsheetApp.openById=id=>{if(id===stateId)opens++;return open(id);};
 item.data={...item.data,_syncRevision:'next-revision'};
 s.context.VS_saveRecordHead(store,item);assert.equal(opens,1);
 assert.equal(s.context.VS_recordHead('school_notices',item.id).head.revision,'next-revision');
 opens=0;s.context.VS_saveRecordHead(store,item);assert.equal(opens,1);
 s.all.get(stateId).setTrashed(true);
 assert.throws(()=>s.context.VS_saveRecordHead(store,item),/Sync state unavailable/);
});
test('post-flush head readback remains fresh and rejects corrupted committed metadata',()=>{
 const {s,store,item}=fixture(),tab=s.context.VS_syncStateSheet(false,'school_notices');
 s.context.SpreadsheetApp.flush=()=>{tab.getRange(2,2,1,1).setValues([[JSON.stringify({schoolId:A,collection:'school_notices',id:item.id,revision:'corrupted'})]]);};
 item.data={...item.data,_syncRevision:'new-revision'};
 assert.throws(()=>s.context.VS_saveRecordHead(store,item),/Sync state verification failed/);
});
test('post-flush duplicate head detection is preserved rather than trusting a cached row',()=>{
 const {s,store,item}=fixture(),tab=s.context.VS_syncStateSheet(false,'school_notices');
 s.context.SpreadsheetApp.flush=()=>{tab.getRange(3,1,1,2).setValues(tab.getRange(2,1,1,2).getValues());};
 item.data={...item.data,_syncRevision:'new-revision'};
 assert.throws(()=>s.context.VS_saveRecordHead(store,item),/Duplicate sync state/);
});
