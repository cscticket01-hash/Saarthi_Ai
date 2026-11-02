'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {fixture,A,time}=require('./helpers/managed-school-broker');
function setup(){
 const commands=[],google=[],rows={one:{schoolId:A,title:'live value',_syncRevision:'live-original',_syncOperationId:'original-operation-0001'}};
 let cursor=1,failId=null;
 const edge={enabled:()=>true,rpc:async(s,l,b)=>{
  assert.equal(s,A);assert.equal(l,'live');commands.push(b);
  if(b.command==='head')return {schoolId:A,liveProtocol:1,cursor,collections:[{collection:'school_expenses',state:'active',cursor}]};
  if(b.command==='read')return {schoolId:A,liveProtocol:1,cursor,record:rows[b.id]||null,recordRevision:rows[b.id]?._syncRevision,source:rows[b.id]?'cloudflare':'missing'};
  if(b.command==='snapshot'){assert.equal(b.at,cursor);const records=Object.entries(rows).filter(([id])=>Buffer.compare(Buffer.from(id),Buffer.from(b.after||''))>0).map(([id,record])=>({id,record}));return {schoolId:A,liveProtocol:1,cursor,records,next:records.length?records.at(-1).id:null};}
  if(b.command==='commit'){
   if(b.id===failId)throw Object.assign(Error('Record revision conflict'),{status:409,code:'RECORD_REVISION_CONFLICT'});
   assert.equal(b.expectedRevision,rows[b.id]?._syncRevision||'');cursor++;
   rows[b.id]={...b.data,schoolId:A,_syncRevision:'live-'+cursor,_syncOperationId:b.operationId};
   return {schoolId:A,liveProtocol:1,cloudState:'committed',backupState:'pending',recordRevision:rows[b.id]._syncRevision,operationId:b.operationId,record:rows[b.id],cursor};
  }
  throw Error('Unexpected '+b.command);
 }};
 const f=fixture(async(url,opt)=>{
  const body=JSON.parse(JSON.parse(opt.body).payload);google.push(body);
  const result=body.action==='managed_delta'?{changes:Object.fromEntries(body.collections.map(c=>[c,{syncProtocol:2,collectionRevision:'drive-head',records:{old:{schoolId:A,_syncRevision:'drive-old',title:'Drive stale'}}}]))}:
   body.operation==='write'?{syncProtocol:2,recordRevision:'drive-write',record:{...body.data,_syncRevision:'drive-write',_syncOperationId:body.operationId}}:{syncProtocol:2,records:{one:{schoolId:A,_syncRevision:'drive-old',title:'Drive stale'}}};
  return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,syncProtocol:2,...result})};
 },{cloudflareSync:edge,liveSyncSchools:[A]});
 f.docs.set('school_live_migrations/'+A,{collections:{school_expenses:{state:'active',activatedAt:time}},inflight:{}});
 return {...f,commands,google,rows,fail:id=>failId=id};
}
const read={action:'managed/records',collection:'school_expenses',operation:'read',syncProtocol:2,liveProtocol:1};
test('activated business route reads live authority and blocks stale unnegotiated clients',async()=>{
 const f=setup();
 await assert.rejects(f.call({...read,liveProtocol:undefined}),e=>e.code==='LIVE_PROTOCOL_REQUIRED');assert.equal(f.google.length,0);assert.equal(f.commands.length,0);
 const result=await f.call(read);assert.equal(result.records.one.title,'live value');assert.equal(result.collectionRevision,'live:school_expenses:1');assert.equal(result.recordAuthority,'cloudflare-live');assert.equal(f.google.length,0);
 const point=await f.call({...read,id:'one'});assert.equal(point.pointRead,true);assert.equal(point.records.one._syncRevision,'live-original');assert.equal(f.google.length,0);
});
test('mixed delta excludes active live collections from Google reads and preserves record checkpoints',async()=>{
 const f=setup(),request={action:'managed/changes',collections:['school_expenses','fee_settings'],liveProtocol:1,knownRecordRevisions:{school_expenses:{one:'live-original'}}};
 const result=await f.call(request);assert.deepEqual(result.changes.school_expenses.records,{});assert.equal(result.changes.school_expenses.partialRecords,true);assert.equal(result.changes.fee_settings.records.old.title,'Drive stale');assert.deepEqual(f.google[0].collections,['fee_settings']);
 const heads=await f.call({...request,collections:['school_expenses'],knownRecordRevisions:undefined,headOnly:true});assert.equal(heads.revisions.school_expenses,'live:school_expenses:1');
 await assert.rejects(f.call({...request,liveProtocol:undefined}),e=>e.code==='LIVE_PROTOCOL_REQUIRED');
});
test('mixed batches validate all entries before any write and preserve independent partial receipts',async()=>{
 const f=setup(),op=(collection,id,operationId)=>({collection,id,operation:'write',syncProtocol:2,operationId,expectedRecordRevision:'',data:{title:id}});
 const operations=[op('school_expenses','two','live-batch-operation-0002'),op('fee_settings','settings','drive-batch-operation-0003')];
 await assert.rejects(f.call({action:'managed/records/batch',operations}),e=>e.code==='LIVE_PROTOCOL_REQUIRED');assert.equal(f.commands.length,0);assert.equal(f.google.length,0);
 await assert.rejects(f.call({action:'managed/records/batch',liveProtocol:1,operations:[operations[0],{...operations[1],id:'bad/id'}]}),e=>e.status===400);assert.equal(f.commands.length,0);
 const result=await f.call({action:'managed/records/batch',liveProtocol:1,operations});assert.equal(result.acknowledgements.length,2);assert.equal(result.acknowledgements[0].backupState,'pending');assert.equal(result.acknowledgements[0].cloudState,'committed');assert.equal(result.acknowledgements[1].recordRevision,'drive-write');
 f.fail('failure');
 const partial=await f.call({action:'managed/records/batch',liveProtocol:1,operations:[op('school_expenses','failure','failed-batch-operation-0004'),op('fee_settings','another','drive-batch-operation-0005')]});
 assert.equal(partial.acknowledgements[0].success,false);assert.equal(partial.acknowledgements[0].code,'SCRIPT_RECORD_REVISION_CONFLICT');assert.equal(partial.acknowledgements[1].success,true);
});
test('rollback state blocks business reads and delta rather than serving stale Drive records',async()=>{
 const f=setup();f.docs.get('school_live_migrations/'+A).collections.school_expenses.state='rolling_back';
 await assert.rejects(f.call(read),e=>e.code==='LIVE_ROLLBACK_PENDING');
 await assert.rejects(f.call({action:'managed/changes',collections:['school_expenses'],liveProtocol:1}),e=>e.code==='LIVE_ROLLBACK_PENDING');
 assert.equal(f.google.length,0);assert.equal(f.commands.length,0);
});
