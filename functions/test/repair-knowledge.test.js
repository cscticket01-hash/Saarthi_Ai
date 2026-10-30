'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {generateKeyPairSync,verify,createHash}=require('node:crypto');
const {fixture,A,B,time}=require('./helpers/managed-school-broker');
const {policyHash,policy,reports}=require('../repair-knowledge');
const keys=generateKeyPairSync('ed25519');
const options={enabled:true,privateKey:keys.privateKey.export({type:'pkcs8',format:'pem'}),keyId:'repair-test',reportSalt:'synthetic-test-report-salt-not-production'};
const p={enabled:true,rules:[{id:'card-wait',module:'documents',category:'idCardInputs',action:'card_probe_cooldown',value:300,rolloutPercent:100}]},evidenceId='a'.repeat(64);
function setup(){const f=fixture(undefined,{repairKnowledgeOptions:options});f.docs.set('repair_knowledge_evidence/'+evidenceId,{passed:true,protocol:1,suite:'shared-repair-policy-v1',policyHash:policyHash(p),sourceCommit:'b'.repeat(40),verifiedAt:time,expiresAt:time+86400000});return f;}
const publish=(f,policy=p,expectedSequence=0)=>f.call({action:'developer/managed/repair-knowledge/publish',publication:{expectedSequence,policy,evidenceId}},'developer');
const pull=(f,token='A',observation={})=>f.call({action:'managed/repair-knowledge/pull',schoolId:token==='B'?B:A,observation},token);
const unpack=e=>JSON.parse(Buffer.from(e.payload,'base64url').toString());
test('reviewed evidence, CAS, signature and common A/B envelope without school data',async()=>{
 const f=setup(),saved=await publish(f);assert.equal(saved.sequence,1);
 const a=await pull(f),b=await pull(f,'B');assert.deepEqual(a.envelope,b.envelope);assert.equal(a.schoolId,A);assert.equal(b.schoolId,B);
 assert(verify(null,Buffer.from(a.envelope.payload),keys.publicKey,Buffer.from(a.envelope.signature,'base64url')));
 assert(!JSON.stringify(unpack(a.envelope)).includes(A));await assert.rejects(publish(f),e=>e.status===409);
 await assert.rejects(publish(f,{enabled:true,rules:[{...p.rules[0],value:600}]},1),e=>e.code==='REPAIR_KNOWLEDGE_EVIDENCE');
 assert.equal(f.sent.length,0);
});
test('permanent signed server history survives client reset and delivers latest approved policy to school B',async()=>{
 const f=setup();
 const first=await publish(f);
 const immutable=structuredClone(f.docs.get('repair_knowledge/version-1'));
 assert.equal(immutable.sequence,1);
 assert.equal(immutable.policyHash,policyHash(p));
 assert.equal(immutable.envelope.payload,first.envelope.payload);
 const a=await pull(f,'A');
 const b=await pull(f,'B');
 assert.deepEqual(a.envelope,b.envelope);
 // A removed/reinstalled client is represented by a fresh authenticated pull,
 // not by restoring a Windows-local memory snapshot.
 const newClient=await pull(f,'A');
 assert.deepEqual(newClient.envelope,a.envelope);
 const disabled=await publish(f,{enabled:false,rules:[]},1);
 assert.equal(disabled.sequence,2);
 assert.deepEqual(f.docs.get('repair_knowledge/version-1'),immutable);
 assert.equal(f.docs.get('repair_knowledge/version-2').sequence,2);
 assert.equal(unpack((await pull(f,'B')).envelope).enabled,false);
 assert.equal(f.docs.get('repair_knowledge/version-1').policy.enabled,true);
 const stored=JSON.stringify(f.docs.get('repair_knowledge/version-1'));
 assert(!stored.includes(A)&&!stored.includes(B));
});
test('school and licence isolation precedes knowledge routes; schools cannot publish',async()=>{
 const f=setup();await publish(f);
 await assert.rejects(f.call({action:'developer/managed/repair-knowledge/publish',publication:{expectedSequence:1,policy:{enabled:false,rules:[]}}}),e=>e.status===403);
 await assert.rejects(f.call({action:'managed/repair-knowledge/pull',schoolId:B}),e=>e.status===403);
 f.docs.get('school_entitlements/'+A).expiresAt=time-1;await assert.rejects(pull(f),e=>e.status===403);
});
test('strict telemetry whitelist, deduplication and untrusted reports never publish rules',async()=>{
 const f=setup();await publish(f);
 for(const extra of [{schoolId:A},{documentId:'student-1'},{error:'private text'},{password:'secret'}])
  await assert.rejects(pull(f,'A',{batchId:'1'.repeat(64),reports:[{module:'documents',category:'timeout',outcome:'retry',...extra}]}),e=>e.status===400);
 const obs={batchId:'2'.repeat(64),reports:[{module:'documents',category:'timeout',outcome:'resolved'}]};
 await pull(f,'A',obs);await pull(f,'A',obs);await pull(f,'B',obs);
 const catalog=f.docs.get('repair_knowledge/catalog'),row=Object.values(catalog.patterns)[0];assert.equal(row.observations,2);assert.equal(row.untrusted,true);
 assert(!JSON.stringify(catalog).includes(A));assert(!JSON.stringify(catalog).includes(B));assert.equal(f.docs.get('repair_knowledge/published').sequence,1);
});
test('server retains sanitized error fingerprints but rejects custom injected error codes',async()=>{
 const f=setup();await publish(f);
 const observed={batchId:'a'.repeat(64),reports:[
  {module:'fee_payments',category:'conflict',outcome:'resolved',code:'RECORD_REVISION_CONFLICT'}
 ]};
 const response=await pull(f,'A',observed);
 assert.equal(response.schoolId,A);
 const entries=Object.values(f.docs.get('repair_knowledge/catalog').patterns);
 assert.equal(entries.length,1);assert.equal(entries[0].code,'RECORD_REVISION_CONFLICT');
 assert.equal(entries[0].untrusted,true);
 await assert.rejects(pull(f,'B',{batchId:'b'.repeat(64),
  reports:[{module:'fee_payments',category:'conflict',outcome:'resolved',
   code:'student-private-amount-900'}]}),e=>e.status===400);
 assert(!JSON.stringify(entries).includes(A));
 assert(!JSON.stringify(entries).includes(B));
 assert(!JSON.stringify(entries).includes('student-private-amount'));
});
test('disabled default, action/schema bounds and signed kill switch',async()=>{
 const f=fixture();await assert.rejects(pull(f),e=>e.code==='REPAIR_KNOWLEDGE_DISABLED');
 for(const rule of [{...p.rules[0],action:'execute_code'},{...p.rules[0],value:999999},{...p.rules[0],url:'https://evil.example'},{...p.rules[0],rolloutPercent:101}])assert.throws(()=>policy({enabled:true,rules:[rule]}));
 assert.throws(()=>reports([{module:'documents',category:'timeout',outcome:'resolved',payload:{}}]));
 const g=setup();await publish(g);const killed=await publish(g,{enabled:false,rules:[]},1);assert.equal(killed.sequence,2);assert.equal(unpack(killed.envelope).enabled,false);
});
test('evidence expiry bounds signed lease and withdrawn proof advances kill-switch sequence',async()=>{
 const f=setup();f.docs.get('repair_knowledge_evidence/'+evidenceId).expiresAt=time+60000;
 const saved=await publish(f);assert.equal(unpack(saved.envelope).expiresAt,time+60000);
 f.docs.get('repair_knowledge_evidence/'+evidenceId).passed=false;
 const result=await pull(f);assert.equal(unpack(result.envelope).sequence,2);assert.equal(unpack(result.envelope).enabled,false);
});
test('telemetry rate limits never block shared rule delivery',async()=>{
 const f=setup();await publish(f);
 for(let n=0;n<12;n++)assert((await pull(f,'A',{batchId:createHash('sha256').update('batch'+n).digest('hex'),reports:[{module:'documents',category:'timeout',outcome:'retry'}]})).envelope);
 assert.equal(Object.values(f.docs.get('repair_knowledge/catalog').patterns)[0].observations,6);
});
test('browser developer wildcard excludes signing state, source hashes and CI evidence',()=>{
 const source=require('node:fs').readFileSync('../firestore.platform.rules','utf8');
 assert.match(source,/!\(root in \['repair_knowledge','repair_knowledge_evidence','repair_knowledge_sources'\]\)/);
});
test('optional signing misconfiguration disables knowledge without disabling normal school access',async()=>{
 const f=fixture(undefined,{repairKnowledgeOptions:{enabled:true,privateKey:'invalid',reportSalt:'short'}});
 const normal=await f.call({action:'managed/storage/check',schoolId:A});assert.equal(normal.success,true);
 await assert.rejects(pull(f),e=>e.code==='REPAIR_KNOWLEDGE_DISABLED');
 const status=await f.call({action:'developer/managed/repair-knowledge/status'},'developer');assert.equal(status.configured,false);
});
