'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {expectedMarker,selectNonwrites,verifyReplay,verifyReport,digest,SCHOOL,manifest,evidenceHash}=require('./settle_proven_test_nonwrites.cjs');
function fixture(){
 const descriptors=manifest.entries.slice(0,2).map((d,i)=>({...d,markerHash:digest('synthetic-key-'+i)}));
 const inflight=Object.fromEntries(descriptors.map((d,i)=>['synthetic-key-'+i,expectedMarker(d)]));
 inflight.uncertain={collection:'students_directory',startedAt:2,activeAttempts:0};
 return {descriptors,state:{collections:{school_notices:{state:'legacy'}},inflight,liveInflight:{live:{pending:true}},unrelated:'preserved'}};
}
test('source reconstruction matches every exact audited record, operation and request hash',()=>{
 assert.equal(manifest.entries.length,20);for(const d of manifest.entries)expectedMarker(d);
});
test('exact nonwrites are selected while uncertain markers and original state remain unchanged',()=>{
 const f=fixture(),before=JSON.stringify(f.state),plan=selectNonwrites(f.state,f.descriptors);
 assert.equal(plan.count,2);assert.equal(plan.retained,2);assert.deepEqual(plan.remaining,{uncertain:f.state.inflight.uncertain});
 assert.equal(JSON.stringify(f.state),before);
});
test('active attempts, scope changes, changed binding and replacement metadata fail closed',()=>{
 for(const change of [r=>r.activeAttempts=1,r=>r.startedAt++,r=>r.collection='documents',r=>r.operationBinding.schoolId='foreign',
  r=>r.operationBinding.operationId='another-operation',r=>r.operationBinding.requestHash='0'.repeat(64),r=>r.requestFingerprint='new-attempt']){
  const f=fixture();change(f.state.inflight['synthetic-key-0']);const before=JSON.stringify(f.state);
  assert.throws(()=>selectNonwrites(f.state,f.descriptors));assert.equal(JSON.stringify(f.state),before);
 }
});
test('audit replay requires exact preserved metadata and no reappeared marker',()=>{
 const f=fixture(),plan=selectNonwrites(f.state,f.descriptors);
 const audit={version:1,schoolId:SCHOOL,evidenceHash,status:'reclassified_proven_nonwrites',businessRecordsChanged:false,originalMarkers:plan.selected};
 verifyReplay({...f.state,inflight:plan.remaining},audit,f.descriptors);
 assert.throws(()=>verifyReplay(f.state,audit,f.descriptors));
 assert.throws(()=>verifyReplay({...f.state,inflight:plan.remaining},{...audit,evidenceHash:'wrong'},f.descriptors));
 const changed=structuredClone(audit);changed.originalMarkers['synthetic-key-0'].startedAt++;
 assert.throws(()=>verifyReplay({...f.state,inflight:plan.remaining},changed,f.descriptors));
});
test('missing or changed original rejection and preservation checks cannot authorize settlement',()=>{
 const d=manifest.entries[0],report={schoolId:SCHOOL,checks:structuredClone(d.requiredChecks)};
 verifyReport(report,d);report.checks[0].status='FAIL';assert.throws(()=>verifyReport(report,d));
 assert.throws(()=>verifyReport({schoolId:SCHOOL,checks:d.requiredChecks.slice(0,2)},d));
});
