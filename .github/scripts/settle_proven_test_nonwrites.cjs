'use strict';
const assert=require('node:assert/strict'),path=require('node:path'),{createHash}=require('node:crypto');
const {canonical}=require('../../functions/live-sync-canonical');
const {bindOperation}=require('../../functions/live-sync-reconciliation');
const manifest=require('./proven_test_nonwrites.json');
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d',PROJECT='saarthi-ai-df12b';
const REPO='cscticket01-hash/Saarthi_Ai',BRANCH='refs/heads/test/settle-proven-nonwrites-20261111';
const digest=value=>createHash('sha256').update(typeof value==='string'?value:canonical(value)).digest('hex');
const evidenceHash=digest(manifest);let phase='scope';
function expectedMarker(d){
 assert.match(d.markerHash,/^[a-f0-9]{64}$/);assert.ok(Number.isSafeInteger(d.startedAt));
 if(d.kind==='read_only_inventory'){
  assert.equal(d.startedAt,1794245946971);
  return {collection:'*',startedAt:d.startedAt,activeAttempts:0};
 }
 assert.equal(d.prefix,'isolated-v2-'+d.runId+'-'+d.attempt);
 const student=d.kind==='invalid_generation',stale=d.kind==='notice_stale_rejection';
 assert.ok(student||stale||d.kind==='notice_operation_rejection');
 const id=d.prefix+(student?'-student':'-notice'),collection=student?'students_directory':'school_notices';
 const operationId=stale?d.prefix+'-stale-cas-conflict':d.prefix+'-'+digest(collection+'/'+id).slice(0,24);
 const data=student?{name:'Synthetic TEST Student',class:'1',section:'TEST-protocol-'+d.prefix,rollNo:'900001',dob:'2015-01-01',
  mobileStableId:id,mobileLinkToken:digest(d.prefix+'/synthetic-qr'),syntheticTest:true,schoolId:SCHOOL}
 :{schoolId:SCHOOL,title:stale?'Rejected stale TEST edit':'Rejected changed operation TEST edit',syntheticTest:true};
 const binding=bindOperation(SCHOOL,'legacy',{action:'managed_records',collection,id,operation:'write',syncProtocol:2,
  operationId,expectedRecordRevision:stale?'stale-test-revision':'',data});
 assert.equal(digest(id),d.recordHash);assert.equal(digest(operationId),d.operationHash);
 assert.equal(binding.requestHash,d.requestHash);
 if(student)assert.ok(!/^p-[a-f0-9]{32,64}$/.test(data.mobileStableId));
 return {collection,startedAt:d.startedAt,activeAttempts:0,operationBinding:binding};
}
function selectNonwrites(state,descriptors=manifest.entries){
 const byHash=new Map(Object.entries(state.inflight||{}).map(([key,marker])=>[digest(key),{key,marker}])),selected={};
 for(const d of descriptors){
  const value=byHash.get(d.markerHash);assert.ok(value,'Required audited marker missing');
  assert.equal(canonical(value.marker),canonical(expectedMarker(d)),'Audited marker changed or active');
  assert.ok(!Object.hasOwn(selected,value.key));selected[value.key]=value.marker;
 }
 const remaining=Object.fromEntries(Object.entries(state.inflight||{}).filter(([key])=>!Object.hasOwn(selected,key)));
 return {selected,remaining,count:Object.keys(selected).length,retained:Object.keys(remaining).length+Object.keys(state.liveInflight||{}).length};
}
function verifyReplay(state,audit,descriptors=manifest.entries){
 assert.equal(audit?.version,1);assert.equal(audit.schoolId,SCHOOL);assert.equal(audit.evidenceHash,evidenceHash);
 assert.equal(audit.status,'reclassified_proven_nonwrites');assert.equal(audit.businessRecordsChanged,false);
 assert.equal(Object.keys(audit.originalMarkers||{}).length,descriptors.length);
 const archived=new Map(Object.entries(audit.originalMarkers).map(([key,marker])=>[digest(key),marker]));
 const present=new Set(Object.keys(state.inflight||{}).map(digest));
 for(const d of descriptors){assert.equal(canonical(archived.get(d.markerHash)),canonical(expectedMarker(d)));
  assert.ok(!present.has(d.markerHash),'Audited marker reappeared');}
}
function extractReport(log){
 for(const line of log.split('\n')){const index=line.indexOf('{"schoolId"');if(index<0)continue;
  try{const value=JSON.parse(line.slice(index).trim());if(value.scope==='Owner-approved isolated TEST storage pairing and signed readback')return value;}catch(_){}
 }throw Error('Original signed TEST report missing');
}
function verifyReport(report,d){
 assert.equal(report.schoolId,SCHOOL);assert.ok(Array.isArray(report.checks));
 const names=d.kind==='invalid_generation'?['Real durable Script ACK students_directory']:
  ['Real stale revision is HTTP 409 without ACK','Real operation ID reuse is HTTP 409 without ACK','Rejected conflicts preserve existing TEST notice'];
 assert.deepEqual(d.requiredChecks.map(c=>c.name).sort(),names.sort());
 for(const expected of d.requiredChecks){
  assert.deepEqual(report.checks.find(c=>c.name===expected.name),expected);
  if(d.kind==='invalid_generation'){assert.equal(expected.status,'FAIL');assert.equal(expected.http,400);assert.equal(expected.code,'PERSON_GENERATION_INVALID');}
  else{assert.equal(expected.status,'PASS');assert.equal(expected.http,expected.name==='Rejected conflicts preserve existing TEST notice'?200:409);}
 }
}
async function github(route){
 const r=await fetch('https://api.github.com/repos/'+REPO+route,{headers:{Authorization:'Bearer '+process.env.GITHUB_TOKEN,
  Accept:'application/vnd.github+json'},signal:AbortSignal.timeout(30000)});
 assert.equal(r.status,200,'GitHub proof unavailable');return r.json();
}
async function jobLog(id){
 const r=await fetch('https://api.github.com/repos/'+REPO+'/actions/jobs/'+id+'/logs',{
  headers:{Authorization:'Bearer '+process.env.GITHUB_TOKEN},redirect:'manual',signal:AbortSignal.timeout(30000)});
 if(r.status===200)return r.text();
 assert.ok([301,302,303,307].includes(r.status));const target=new URL(r.headers.get('location'));
 assert.equal(target.protocol,'https:');assert.ok(!target.username&&!target.password&&!target.port);
 assert.ok(target.hostname.endsWith('.blob.core.windows.net')||target.hostname.endsWith('.actions.githubusercontent.com'),'Unexpected GitHub log host');
 // The GitHub token is never forwarded to a storage redirect.
 const download=await fetch(target,{signal:AbortSignal.timeout(30000)});assert.equal(download.status,200);return download.text();
}
async function verifySources(){
 const cache=new Map();
 for(const d of manifest.entries){
  expectedMarker(d);
  if(!cache.has(d.jobId)){
   const jobs=await github('/actions/runs/'+d.runId+'/jobs?filter=all&per_page=100'),job=jobs.jobs.find(j=>j.id===d.jobId);
   assert.ok(job&&job.head_sha===d.sourceSha&&job.run_attempt===d.attempt&&job.status==='completed');
   assert.ok(Date.parse(job.started_at)<=d.startedAt&&Date.parse(job.completed_at)>=d.startedAt);
   cache.set(d.jobId,await jobLog(d.jobId));
  }
  const log=cache.get(d.jobId);
  if(d.kind==='read_only_inventory'){
   // This exact ref is present in both the original failed Windows test and
   // the independently inspected Render file-inventory timeout log. The
   // original test was awaiting refreshInventory, before its business writes.
   assert.equal(d.requestId,'a68baae1-d0af-4140-9101-9d9e4856897a');
   assert.equal(d.renderOperation,'managed/file/inventory');assert.equal(d.http,504);assert.equal(d.code,'SCRIPT_TIMEOUT');
   assert.ok(log.includes(d.requestId)&&log.includes('[SCRIPT_TIMEOUT]')&&log.includes('isolated_engine_live_test.dart'));
  }else verifyReport(extractReport(log),d);
 }
}
async function verifyRuntime(){
 for(const gate of manifest.gates){
  const run=await github('/actions/runs/'+gate.id);
  assert.equal(run.name,gate.name);assert.equal(run.head_sha,manifest.runtimeCommit);
  assert.equal(run.head_branch,'feature/smart-sync-3');assert.equal(run.event,'push');
  assert.equal(run.head_repository.full_name,REPO);assert.equal(run.status,'completed');assert.equal(run.conclusion,'success');
 }
 await require('./test_runtime_identity.cjs').waitForRuntime(manifest.runtimeCommit,{attempts:6});
}
async function main(){
 assert.equal(process.env.GITHUB_ACTIONS,'true');assert.equal(process.env.GITHUB_REPOSITORY,REPO);assert.equal(process.env.GITHUB_REF,BRANCH);
 assert.equal(manifest.schoolId,SCHOOL);assert.equal(manifest.projectId,PROJECT);assert.equal(manifest.entries.length,20);
 const mode=process.argv[2];assert.ok(['--plan','--apply'].includes(mode));
 phase='immutable_source_proofs';await verifySources();phase='reviewed_test_runtime';await verifyRuntime();
 if(mode==='--apply')assert.equal(process.env.VS_RECLASSIFY_PROVEN_NONWRITES,SCHOOL);
 phase='scoped_firebase_identity';const account=JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT_JSON||'{}');
 assert.equal(account.type,'service_account');assert.equal(account.project_id,PROJECT);
 assert.ok(account.client_email?.endsWith('@'+PROJECT+'.iam.gserviceaccount.com'));
 const fromFunctions=require('node:module').createRequire(path.resolve(__dirname,'../../functions/package.json'));
 const {initializeApp,cert,deleteApp}=fromFunctions('firebase-admin/app'),{getFirestore,FieldValue}=fromFunctions('firebase-admin/firestore');
 const app=initializeApp({credential:cert(account),projectId:PROJECT},'proven-test-nonwrite-repair');
 try{
  const db=getFirestore(app),ref=db.doc('school_live_migrations/'+SCHOOL);
  const auditRef=db.doc('school_live_migration_repairs/'+SCHOOL+'-nonwrites-'+evidenceHash);
  if(mode==='--plan'){
   phase='read_only_plan';const [state,audit]=await Promise.all([ref.get(),auditRef.get()]);assert.equal(state.exists,true);
   if(audit.exists){verifyReplay(state.data(),audit.data());console.log('PROVEN_NONWRITES_PLAN already_audited=20');return;}
   const plan=selectNonwrites(state.data());console.log('PROVEN_NONWRITES_PLAN count='+plan.count+' retained='+plan.retained+' evidence='+evidenceHash);return;
  }
  phase='audited_nonwrite_reclassification';
  const result=await db.runTransaction(async tx=>{
   const [state,audit]=await Promise.all([tx.get(ref),tx.get(auditRef)]);assert.equal(state.exists,true);
   if(audit.exists){verifyReplay(state.data(),audit.data());return {count:20,replay:true};}
   const original=state.data(),plan=selectNonwrites(original);assert.equal(plan.count,20);
   // The complete original markers and source evidence are archived in the
   // SAME transaction. No pupil, fee, document, client outbox, delivery job
   // or uncertain non-target admission marker is deleted or acknowledged.
   tx.create(auditRef,{version:1,schoolId:SCHOOL,evidenceHash,status:'reclassified_proven_nonwrites',businessRecordsChanged:false,
    recordedAt:FieldValue.serverTimestamp(),sourceCommit:process.env.GITHUB_SHA,originalMarkers:plan.selected,evidence:manifest});
   tx.set(ref,{...original,inflight:plan.remaining});return {count:plan.count,replay:false,retained:plan.retained};
  });
  console.log('PROVEN_NONWRITES_RECLASSIFIED count='+result.count+' replay='+result.replay+' retained='+(result.retained??'unchanged')+' evidence='+evidenceHash);
 }finally{await deleteApp(app);}
}
if(require.main===module)main().catch(()=>{console.error('PROVEN_NONWRITES_BLOCKED phase='+phase);process.exitCode=1;});
module.exports={expectedMarker,selectNonwrites,verifyReplay,verifyReport,extractReport,digest,SCHOOL,manifest,evidenceHash};
