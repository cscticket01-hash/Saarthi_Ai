'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createLiveMigration}=require('../live-sync-migration');
const {fixture,A,B}=require('./helpers/managed-school-broker');
const write={action:'managed_records',collection:'school_expenses',operation:'write'};
test('migration closes admission before waiting for an existing writer and queued delivery',async()=>{
 const f=fixture(),gate=createLiveMigration({db:f.db,drainGraceMs:0});let finish,started;
 const ready=new Promise(r=>started=r),pending=gate.legacy(A,write,()=>{started();return new Promise(r=>finish=r);});
 await ready;let seeds=0;
 const seed=async()=>{seeds++;return {state:'active'};};
 await assert.rejects(gate.prepare(A,write.collection,async()=>true,seed),e=>e.code==='LIVE_LEGACY_WRITES_IN_FLIGHT');
 await assert.rejects(gate.legacy(A,write,async()=>{}),e=>e.code==='LIVE_LEGACY_WRITE_FENCED');
 finish('saved');assert.equal(await pending,'saved');
 await assert.rejects(gate.prepare(A,write.collection,async()=>false,seed),e=>e.code==='LIVE_LEGACY_DELIVERY_PENDING');
 assert.equal(seeds,0);
 await gate.prepare(A,write.collection,async()=>true,seed);assert.equal(seeds,1);
 await gate.assertActive(A,write.collection);
 await assert.rejects(gate.legacy(A,write,async()=>{}),e=>e.code==='LIVE_LEGACY_WRITE_FENCED');
 assert.equal(await gate.legacy(B,write,async()=>42),42);
 assert.equal(await gate.legacy(A,{...write,operation:'read'},async()=>43),43);
 await gate.prepare(A,write.collection,async()=>false,seed);assert.equal(seeds,1);
});
test('uncertain write, broker restart and failed seeding never reopen legacy admission',async()=>{
 const f=fixture();let gate=createLiveMigration({db:f.db,drainGraceMs:0});
 await assert.rejects(gate.legacy(A,write,async()=>{throw Error('transport timeout');}));
 gate=createLiveMigration({db:f.db,drainGraceMs:0});
 await assert.rejects(gate.prepare(A,write.collection,async()=>true,async()=>({state:'active'})),e=>e.code==='LIVE_LEGACY_WRITES_IN_FLIGHT');
 await assert.rejects(gate.assertActive(A,write.collection),e=>e.code==='LIVE_MIGRATION_NOT_ACTIVE');
 await assert.rejects(gate.prepare(B,write.collection,async()=>true,async()=>{throw Error('seed failed');}));
 await assert.rejects(gate.legacy(B,{action:'managed_recycle',operation:'restore'},async()=>{}),e=>e.code==='LIVE_LEGACY_WRITE_FENCED');
 await gate.prepare(B,write.collection,async()=>true,async()=>({state:'active'}));
 await gate.assertActive(B,write.collection);
});
test('deployment drain grace survives retries and broad actions cannot spoof a collection',async()=>{
 const f=fixture();let time=1000;const gate=createLiveMigration({db:f.db,now:()=>time});let seeded=0;
 const seed=async()=>{seeded++;return {state:'active'};};
 await assert.rejects(gate.prepare(A,write.collection,async()=>true,seed),e=>e.code==='LIVE_LEGACY_DRAIN_GRACE');
 time+=119999;
 await assert.rejects(gate.prepare(A,write.collection,async()=>true,seed),e=>e.code==='LIVE_LEGACY_DRAIN_GRACE');
 assert.equal(seeded,0);
 time++;
 await gate.prepare(A,write.collection,async()=>true,seed);assert.equal(seeded,1);
 await assert.rejects(gate.legacy(A,{action:'managed_records_batch',collection:'unrelated',operation:'read'},async()=>{}),e=>e.code==='LIVE_LEGACY_WRITE_FENCED');
});
test('public broker cannot commit before activation or seed while legacy delivery is pending',async()=>{
 const commands=[],edge={enabled:()=>true,rpc:async(s,l,b)=>{commands.push({lane:l,command:b.command});return {pending:l==='records'?1:0,needsAttention:0};}};
 const f=fixture(null,{cloudflareSync:edge,liveSyncSchools:[A]});
 await assert.rejects(f.call({action:'managed/live/commit',liveProtocol:1,collection:write.collection,id:'one',operation:'write'}),e=>e.code==='LIVE_MIGRATION_NOT_ACTIVE');
 assert.equal(commands.length,0);
 const {time}=require('./helpers/managed-school-broker');
 f.docs.set('school_live_migrations/'+A,{collections:{[write.collection]:{state:'preparing',startedAt:time-120001}},inflight:{}});
 await assert.rejects(f.call({action:'managed/live/prepare',liveProtocol:1,collection:write.collection,confirmIsolatedMigration:true}),e=>e.code==='LIVE_LEGACY_DELIVERY_PENDING');
 assert.deepEqual(commands,[{lane:'records',command:'stats'},{lane:'notices',command:'stats'}]);
 assert.equal(f.sent.length,0);
});
const activeGate=()=>{
 const f=fixture(),gate=createLiveMigration({db:f.db,drainGraceMs:0});
 f.docs.set('school_live_migrations/'+A,{collections:{[write.collection]:{state:'active'}},inflight:{},liveInflight:{}});
 return {...f,gate};
};
const rollbackProof=context=>({success:true,liveProtocol:1,schoolId:context.schoolId,collection:context.collection,rollbackToken:context.rollbackToken,state:'legacy',driveVerified:true,pending:0,needsAttention:0,cursor:12,fingerprint:'a'.repeat(64)});
test('rollback fences live admission before waiting for current writes and requires sealed Drive proof',async()=>{
 const f=activeGate();let finish,started;
 const ready=new Promise(r=>started=r),pending=f.gate.live(A,write.collection,()=>{started();return new Promise(r=>finish=r);});
 await ready;let verified=0;
 const verify=async context=>{verified++;return rollbackProof(context);};
 await assert.rejects(f.gate.rollback(A,write.collection,verify),e=>e.code==='LIVE_WRITES_IN_FLIGHT');
 await assert.rejects(f.gate.live(A,write.collection,async()=>{}),e=>e.code==='LIVE_MIGRATION_NOT_ACTIVE');
 await assert.rejects(f.gate.legacy(A,write,async()=>{}),e=>e.code==='LIVE_LEGACY_WRITE_FENCED');
 await assert.rejects(f.gate.prepare(A,write.collection,async()=>true,async()=>({state:'active'})),e=>e.code==='LIVE_MIGRATION_REVIEW_REQUIRED');
 assert.equal(verified,0);finish('committed');assert.equal(await pending,'committed');
 assert.equal((await f.gate.rollback(A,write.collection,verify)).state,'legacy');assert.equal(verified,1);
 assert.equal(await f.gate.legacy(A,write,async()=>42),42);
 assert.equal((await f.gate.rollback(A,write.collection,async()=>{throw Error('must not verify twice');})).cursor,12);
 await assert.rejects(f.gate.prepare(A,write.collection,async()=>true,async()=>({state:'active'})),e=>e.code==='LIVE_MIGRATION_REVIEW_REQUIRED');
});
test('rollback retains frozen state on backup, content, scope, seal or epoch verification failure',async()=>{
 for(const alter of [p=>({...p,pending:1}),p=>({...p,needsAttention:1}),p=>({...p,schoolId:B}),p=>({...p,collection:'school_calendar'}),p=>({...p,fingerprint:'unverified'}),p=>({...p,driveVerified:false}),p=>({...p,rollbackToken:'other'}),p=>({...p,state:'active'}),p=>({...p,cursor:-1})]){
  const f=activeGate();
  await assert.rejects(f.gate.rollback(A,write.collection,async context=>alter(rollbackProof(context))),e=>e.code==='LIVE_ROLLBACK_UNVERIFIED');
  assert.equal(f.docs.get('school_live_migrations/'+A).collections[write.collection].state,'rolling_back');
  await assert.rejects(f.gate.legacy(A,write,async()=>{}),e=>e.code==='LIVE_LEGACY_WRITE_FENCED');
 }
 const f=activeGate();await assert.rejects(f.gate.rollback(A,write.collection,async()=>{throw Error('seal failed');}));
 assert.equal(f.docs.get('school_live_migrations/'+A).collections[write.collection].state,'rolling_back');
 await assert.rejects(f.gate.rollback(A,write.collection),e=>e.code==='LIVE_ROLLBACK_VERIFIER_REQUIRED');
});
test('uncertain live write survives restart and blocks rollback without deleting any state',async()=>{
 const f=activeGate();await assert.rejects(f.gate.live(A,write.collection,async()=>{throw Error('Cloudflare response lost');}));
 const gate=createLiveMigration({db:f.db,drainGraceMs:0});let verified=0;
 await assert.rejects(gate.rollback(A,write.collection,async context=>{verified++;return rollbackProof(context);}),e=>e.code==='LIVE_WRITES_IN_FLIGHT');
 assert.equal(verified,0);assert.equal(Object.keys(f.docs.get('school_live_migrations/'+A).liveInflight).length,1);
});

test('concurrent immutable legacy retries retain migration fence until every admitted request settles',async()=>{
 const f=fixture(),gate=createLiveMigration({db:f.db,drainGraceMs:0});
 const body={...write,syncProtocol:2,id:'one',operationId:'concurrent-legacy-retry-0001',expectedRecordRevision:'',data:{schoolId:A,amount:1}};
 let endFirst,endSecond,started=0,ready;const both=new Promise(r=>ready=r);
 const launch=end=>()=>new Promise(r=>{end(r);if(++started===2)ready();});
 const first=gate.legacy(A,body,launch(r=>endFirst=r));
 const second=gate.legacy(A,body,launch(r=>endSecond=r));
 await both;
 assert.equal(Object.keys(f.docs.get('school_live_migrations/'+A).inflight).length,1);
 assert.equal(Object.values(f.docs.get('school_live_migrations/'+A).inflight)[0].activeAttempts,2);
 endFirst({success:true});await first;
 assert.equal(Object.values(f.docs.get('school_live_migrations/'+A).inflight)[0].activeAttempts,1);
 await assert.rejects(gate.prepare(A,write.collection,async()=>true,async()=>({state:'active'})),e=>e.code==='LIVE_LEGACY_WRITES_IN_FLIGHT');
 endSecond({success:true});await second;
 assert.equal(Object.keys(f.docs.get('school_live_migrations/'+A).inflight).length,0);
 await gate.prepare(A,write.collection,async()=>true,async()=>({state:'active'}));
 await gate.assertActive(A,write.collection);
});
test('concurrent immutable live retries prevent rollback while a peer still runs',async()=>{
 const f=activeGate(),gate=f.gate;
 const body={collection:write.collection,id:'one',operation:'write',operationId:'concurrent-live-retry-0001',expectedRevision:'',data:{schoolId:A,amount:1}};
 let endFirst,endSecond,started=0,ready;const both=new Promise(r=>ready=r);
 const launch=end=>()=>new Promise(r=>{end(r);if(++started===2)ready();});
 const first=gate.live(A,write.collection,launch(r=>endFirst=r),body);
 const second=gate.live(A,write.collection,launch(r=>endSecond=r),body);
 await both;
 assert.equal(Object.values(f.docs.get('school_live_migrations/'+A).liveInflight)[0].activeAttempts,2);
 endFirst({liveProtocol:1,cloudState:'committed'});await first;
 assert.equal(Object.values(f.docs.get('school_live_migrations/'+A).liveInflight)[0].activeAttempts,1);
 await assert.rejects(gate.rollback(A,write.collection,async()=>{throw Error('rollback cannot begin');}),e=>e.code==='LIVE_WRITES_IN_FLIGHT');
 endSecond({liveProtocol:1,cloudState:'committed'});await second;
 assert.equal(Object.keys(f.docs.get('school_live_migrations/'+A).liveInflight).length,0);
});
test('mobile lifecycle remains available while admitted admin collections are active',async()=>{
 const f=activeGate();assert.equal(await f.gate.legacy(A,{action:'managed_mobile',operation:'session'},async()=>42),42);
});
test('owned file reads never create uncertain write markers or block active collections',async()=>{
 const f=activeGate(),before=JSON.stringify(f.docs.get('school_live_migrations/'+A));
 await assert.rejects(f.gate.legacy(A,{action:'managed_file',fileId:'owned-file'},async()=>{throw Error('download unavailable');}),/download unavailable/);
 assert.equal(JSON.stringify(f.docs.get('school_live_migrations/'+A)),before);
 assert.equal(await f.gate.legacy(A,{action:'managed_file',fileId:'owned-file'},async()=>42),42);
 assert.equal(JSON.stringify(f.docs.get('school_live_migrations/'+A)),before);
 await assert.rejects(f.gate.legacy(A,{action:'managed_file_delete',fileId:'owned-file'},async()=>42),e=>e.code==='LIVE_LEGACY_WRITE_FENCED');
});
test('uncertain retries reuse immutable operation markers instead of exhausting admission',async()=>{
 const f=fixture(),gate=createLiveMigration({db:f.db,drainGraceMs:0});
 const body={...write,syncProtocol:2,id:'one',operationId:'reused-durable-operation-001',expectedRecordRevision:'',data:{schoolId:A,amount:1}};
 for(let i=0;i<110;i++)await assert.rejects(gate.legacy(A,body,async()=>{throw Error('uncertain');}));
 assert.equal(Object.keys(f.docs.get('school_live_migrations/'+A).inflight).length,1);
 assert.equal(await gate.legacy(A,body,async()=>42),42);
 assert.equal(Object.keys(f.docs.get('school_live_migrations/'+A).inflight).length,0);
});

test('person bundle cohort stays fenced through partial seed and rollback failures',async()=>{
 const f=fixture(),gate=createLiveMigration({db:f.db,drainGraceMs:0});
 const group=['students_directory','teachers_directory','documents'];
 const state=()=>f.docs.get('school_live_migrations/'+A);
 await assert.rejects(gate.prepareGroup(A,group,async()=>true,async name=>{
  if(name==='teachers_directory')throw Error('Teacher baseline failed');
  return {state:'active'};
 }),/Teacher baseline failed/);
 assert.equal(state().nativeCohort.state,'preparing');
 for(const name of group){
  assert.equal(await gate.state(A,name),'preparing');
  await assert.rejects(gate.live(A,name,async()=>assert.fail('Premature live write')),e=>e.code==='LIVE_DEPENDENCY_PREPARING');
 }
 await gate.prepareGroup(A,group,async()=>true,async()=>({state:'active'}));
 const proof=context=>({success:true,liveProtocol:1,schoolId:A,collection:context.collection,
  state:'legacy',driveVerified:true,pending:0,needsAttention:0,cursor:0,
  fingerprint:'a'.repeat(64),rollbackToken:context.rollbackToken});
 await assert.rejects(gate.rollbackGroup(A,group,async context=>context.collection==='teachers_directory'
  ?{...proof(context),driveVerified:false}:proof(context)),e=>e.code==='LIVE_ROLLBACK_UNVERIFIED');
 const token=state().nativeCohort.rollbackToken;
 for(const name of group){
  assert.equal(await gate.state(A,name),'rolling_back');
  await assert.rejects(gate.legacy(A,{...write,collection:name},async()=>assert.fail('Premature legacy write')),e=>e.code==='LIVE_LEGACY_WRITE_FENCED');
 }
 await assert.rejects(gate.assertCohortAdmission(A),e=>e.code==='LIVE_ROLLBACK_PENDING');
 const result=await gate.rollbackGroup(A,group,async context=>{
  assert.equal(context.rollbackToken,token);return proof(context);
 });
 assert.equal(result.state,'legacy');
 for(const name of group){
  assert.equal(await gate.state(A,name),'legacy');
  assert.equal(state().collections[name].rollbackProof.driveVerified,true);
 }
 assert.deepEqual(await gate.rollbackGroup(A,group,async()=>assert.fail('Completed rollback resealed')),result);
 assert.equal(await gate.state(B,'documents'),'legacy');
});
