'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {evaluateEvidence}=require('./sync3_original_release_gate.cjs');
function fixture(){return {
 audit:{status:'NO_BLOCKERS',stage:'complete',exactRuntimeVerified:true,queuesVerifiedBefore:true,
  previewResponseShape:{previewOnly:true,cleared:0},
  before:{unsettledWrites:0,pending:0,needsAttention:0},
  after:{unsettledWrites:0,pending:0,needsAttention:0},
  reconciliation:{scanned:0,cleared:0,retained:0,previewWouldClear:0,more:false}},
 cloud:{status:'PASS',deployedScriptEvidence:{matchesReviewedSource:true}},
 script:{status:'PASS',actualAdmissionErrorVersion:1},
 delivery:{status:'PASS',bytesReadbackVerified:true,bytesWritten:786432,
  verifiedRoutes:[{collection:'school_calendar',route:'Cloudflare-ACK-then-Drive'},
   {collection:'documents',route:'Cloudflare-ACK-then-Drive'},
   {collection:'teachers_directory',route:'signed-person-lifecycle-Drive'},
   {collection:'teachers_directory',route:'signed-person-lifecycle-Drive'}]}
};}
test('clean original TEST proof cannot authorize production',()=>{
 const r=evaluateEvidence(fixture());
 assert.equal(r.status,'TEST_ORIGINAL_PROOFS_CLEARED');
 assert.equal(r.productionAuthorized,false);
 assert.ok(r.independentProductionGates.includes('PHYSICAL_WINDOWS_ANDROID'));
});
test('14 unresolved original operations block release even with zero queue and green Drive',()=>{
 const f=fixture();Object.assign(f.audit,{status:'READONLY_DIAGNOSTIC_COMPLETE_RELEASE_BLOCKED',
  before:{unsettledWrites:14,pending:0,needsAttention:0},
  after:{unsettledWrites:14,pending:0,needsAttention:0},
  reconciliation:{scanned:14,retained:14,cleared:0,previewWouldClear:0,more:false}});
 const r=evaluateEvidence(f);
 assert.equal(r.status,'RELEASE_BLOCKED');
 assert.equal(r.unresolvedOriginalCount,14);
 assert.ok(r.blockerCodes.includes('UNSETTLED_ORIGINAL_OPERATIONS'));
});
test('incomplete or changed read-only scan fails closed',()=>{
 for(const change of [
  f=>{f.audit.status='READONLY_DIAGNOSTIC_COMPLETE_RELEASE_BLOCKED'},
  f=>{f.audit.previewResponseShape.cleared=1},
  f=>{f.audit.reconciliation.more=true},
  f=>{f.audit.concurrentMarkerChange=true},
  f=>{f.audit.after.unsettledWrites=undefined},
  f=>{f.audit.reconciliation.scanned=-1},
  f=>{f.audit.reconciliation.retained=2},
 ]){
  const f=fixture();change(f);assert.equal(evaluateEvidence(f).status,'RELEASE_BLOCKED');
 }
});
test('signed Script, owner and Cloudflare Drive byte proofs cannot be skipped',()=>{
 for(const change of [
  f=>{f.cloud.deployedScriptEvidence.matchesReviewedSource=false},
  f=>{f.script.actualAdmissionErrorVersion=0},
  f=>{f.delivery.bytesReadbackVerified=false},
  f=>{f.delivery.verifiedRoutes=f.delivery.verifiedRoutes.slice(1)},
  f=>{f.delivery.verifiedRoutes=f.delivery.verifiedRoutes.slice(0,3)},
  f=>{f.audit.queuesVerifiedBefore=false},
  f=>{f.audit.before.pending=1},
 ]){
  const f=fixture();change(f);assert.equal(evaluateEvidence(f).status,'RELEASE_BLOCKED');
 }
});
test('missing artifacts fail closed',()=>{
 for(const key of ['audit','cloud','script','delivery']){
  const f=fixture();delete f[key];assert.equal(evaluateEvidence(f).status,'RELEASE_BLOCKED');
 }
});
