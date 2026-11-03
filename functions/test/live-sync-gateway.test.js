'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createLiveGateway}=require('../live-sync-gateway');
const school='vs-'+'a'.repeat(32),collection='school_expenses',operationId='operation-live-000001';
const record=(revision='live-one',op=operationId)=>({schoolId:school,title:'saved',_syncRevision:revision,_syncOperationId:op});
const envelope={schoolId:school,liveProtocol:1};
const request={action:'managed_records',collection,syncProtocol:2,liveProtocol:1,operation:'write',id:'one',operationId,expectedRecordRevision:'',data:{schoolId:school,title:'saved'}};
function fixture(overrides={}){
 const calls=[];const liveSync={
  command:async(s,b)=>{calls.push(b);return {...envelope,cursor:2,collections:[{collection,cursor:1,state:'active'}]};},
  read:async()=>({...envelope,cursor:2,recordRevision:'live-one',record:record()}),
  replay:async(s,b)=>({...envelope,cursor:2,records:b.after?[]:[{id:'one',record:record()}],next:b.after?null:'one'}),
  commit:async(s,b)=>{calls.push(b);return {...envelope,cloudState:'committed',backupState:'pending',recordRevision:'live-one',operationId,record:record()};},...overrides};
 const gate={live:async(s,c,run)=>{calls.push({admitted:s+'/'+c});return run();}};
 return {calls,liveSync,gateway:createLiveGateway({liveSync,migration:gate})};
}
test('gateway negotiates before any read or mutation and limits admission to reviewed collections',async()=>{
 const f=fixture();
 await assert.rejects(f.gateway.records(school,{...request,liveProtocol:undefined}),e=>e.code==='LIVE_PROTOCOL_REQUIRED');
 await assert.rejects(f.gateway.records(school,{...request,collection:'backups'}),e=>e.code==='LIVE_COLLECTION_NOT_ADMITTED');
 await assert.rejects(f.gateway.records(school,{...request,operation:'recover'}),e=>e.code==='LIVE_OPERATION_NOT_ADMITTED');
 assert.deepEqual(f.calls,[]);
});
test('Cloudflare write receipt remains pending Drive verification and operation identity is preserved',async()=>{
 const f=fixture(),result=await f.gateway.records(school,request,async()=>{});
 assert.equal(result.success,true);assert.equal(result.syncProtocol,2);assert.equal(result.liveProtocol,1);assert.equal(result.cloudState,'committed');assert.equal(result.backupState,'pending');assert.equal(result.recordAuthority,'cloudflare-live');
 assert.deepEqual(f.calls[0],{admitted:school+'/'+collection});assert.equal(f.calls[1].expectedRevision,'');assert.equal(f.calls[1].operationId,operationId);
});
test('cleaned replay is hydrated only at its original revision; newer canonical versions require reconciliation',async()=>{
 const receipt={...envelope,cloudState:'committed',backupState:'verified',recordRevision:'live-one',operationId,record:null};
 const f=fixture({commit:async()=>receipt});
 assert.deepEqual((await f.gateway.records(school,request)).record,record());
 f.liveSync.read=async()=>({...envelope,recordRevision:'live-newer',record:record('live-newer')});
 await assert.rejects(f.gateway.records(school,request),e=>e.code==='RECORD_REVISION_CONFLICT');
});
test('unchanged and offline duplicate receipts keep original canonical metadata',async()=>{
 for(const flags of [{unchanged:true},{duplicate:true,resolution:'cloudRetained'}]){
  const original=record('original-GS-revision','original-operation');
  const f=fixture({commit:async()=>({...envelope,cloudState:'committed',backupState:'verified',recordRevision:original._syncRevision,operationId,record:original,...flags})});
  const result=await f.gateway.records(school,request);assert.equal(result.record._syncOperationId,'original-operation');assert.equal(result.recordRevision,'original-GS-revision');
 }
});
test('snapshot pages share one head and collection revision excludes other collection traffic',async()=>{
 const f=fixture();const body={...request,operation:'read',id:undefined};
 const result=await f.gateway.records(school,body);
 assert.equal(result.collectionRevision,'live:'+collection+':1');assert.deepEqual({...result.records},{one:record()});
 const unchanged=await f.gateway.records(school,{...body,knownRevision:result.collectionRevision});assert.equal(unchanged.unchanged,true);assert.deepEqual(unchanged.records,{});
 let reads=0;f.liveSync.command=async()=>({...envelope,cursor:++reads===1?2:3,collections:[{collection,cursor:1}]});
 await assert.rejects(f.gateway.records(school,body),e=>e.code==='LIVE_SNAPSHOT_CHANGED');
});
test('unverified records, cursor loops and oversized snapshots fail without an apparently complete response',async()=>{
 const body={...request,operation:'read',id:undefined};
 const foreign=fixture({replay:async()=>({...envelope,cursor:2,next:'one',records:[{id:'one',record:{...record(),schoolId:'foreign'}}]})});
 await assert.rejects(foreign.gateway.records(school,body),e=>e.code==='LIVE_GATEWAY_RECORD_UNVERIFIED');
 const looping=fixture({replay:async()=>({...envelope,cursor:2,next:'one',records:[{id:'one',record:record()}]})});
 await assert.rejects(looping.gateway.records(school,body),e=>e.code==='LIVE_GATEWAY_SNAPSHOT_UNVERIFIED');
 const f=fixture(),bounded=createLiveGateway({liveSync:f.liveSync,maxBytes:1});
 await assert.rejects(bounded.records(school,body),e=>e.code==='LIVE_GATEWAY_SNAPSHOT_TOO_LARGE');
});
test('point reads preserve missing semantics and reject unresolved Drive references',async()=>{
 const f=fixture({read:async()=>({...envelope,cursor:2,source:'missing',record:null})});
 const result=await f.gateway.records(school,{...request,operation:'read'});assert.equal(result.pointRead,true);assert.deepEqual(result.records,{});
 f.liveSync.read=async()=>({...envelope,cursor:2,source:'drive',record:null});
 await assert.rejects(f.gateway.records(school,{...request,operation:'read'}),e=>e.code==='LIVE_GATEWAY_READ_UNVERIFIED');
});
test('field patches map only changed fields into the existing exact-CAS live owner',async()=>{
 const f=fixture(),patch={version:1,set:{title:'corrected'},remove:['note'],before:{title:{exists:true,revision:'live-old'}}};
 await f.gateway.records(school,{...request,expectedRecordRevision:'live-old',data:{schoolId:school,_syncFieldPatch:patch}});
 assert.equal(f.calls[1].operation,'patch');assert.equal(f.calls[1].expectedRevision,'live-old');assert.deepEqual(f.calls[1].data,{schoolId:school,set:{title:'corrected'},remove:['note']});
 await assert.rejects(f.gateway.records(school,{...request,data:{schoolId:school,_syncFieldPatch:{...patch,set:{personId:'changed'}}}}),e=>e.code==='LIVE_PATCH_INVALID');
});
