'use strict';
// Isolated, owner-approved TEST Sync V2 remote latency only.
// No production endpoint, real person record, notice, or user media is changed.
// Unique non-functional school_settings probe is always tombstoned using exact CAS.
const {randomBytes}=require('node:crypto');
const fs=require('node:fs');
const {performance}=require('node:perf_hooks');
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d';
const ENDPOINT='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const AUTH='https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const REPORT='build/cloud-prerequisites/real-test-sync-speed.json';
const report={scope:'Isolated TEST school, REAL Google Apps Script/Drive backend, exact-ACK readback',schoolId:SCHOOL,networkMeasured:true,productionCertified:false,cloudflareLiveSyncMeasured:false,samples:[]};
function assert(ok,message){if(!ok)throw Error(message);}
function ms(value){return Math.round(value*100)/100;}
async function request(url,body,token){
 const at=performance.now();
 const response=await fetch(url,{method:body?'POST':'GET',redirect:'error',
  headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},
  ...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(90000)});
 const payload=await response.json();
 return {status:response.status,payload,elapsedMs:ms(performance.now()-at)};
}
async function main(){
 assert(process.env.VS_REAL_LATENCY_RUN===SCHOOL,'School-scoped TEST-only opt-in required');
 assert(!!process.env.VS_TEST_LOGIN_EMAIL&&!!process.env.VS_TEST_LOGIN_PASSWORD,'TEST Actions secrets unavailable');
 let r=await request(ENDPOINT+'/healthz');
 assert(r.status===200&&r.payload.ready===true&&r.payload.projectId==='saarthi-ai-df12b','Wrong TEST broker or Firebase project');
 report.runtimeCommit=/^[a-f0-9]{40}$/.test(r.payload.runtimeCommit||'')?r.payload.runtimeCommit:'unknown';
 report.healthRttMs=r.elapsedMs;
 const login=await request(AUTH,{email:process.env.VS_TEST_LOGIN_EMAIL,password:process.env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});
 assert(login.status===200&&typeof login.payload.idToken==='string','TEST Firebase login failed');
 const token=login.payload.idToken;
 report.firebaseLoginMs=login.elapsedMs;
 async function call(action,body){
  const result=await request(ENDPOINT,{...body,action,schoolId:SCHOOL},token);
  if(result.status!==200||result.payload?.success!==true||result.payload.schoolId!==SCHOOL){
   const code=/^[A-Z][A-Z0-9_]{1,79}$/.test(result.payload?.code||'')?result.payload.code:'REMOTE_ERROR';
   throw Error(action+' HTTP '+result.status+' '+code);
  }
  return {value:result.payload,elapsedMs:result.elapsedMs};
 }
 const session=await call('managed/session',{});
 assert(session.value.allowed===true&&session.value.activated===true&&session.value.status==='licensed'&&session.value.uid===login.payload.localId,'TEST entitlement not active or school membership mismatch');
 report.sessionMs=session.elapsedMs;
 const storage=await call('managed/storage/check',{});
 assert(storage.value.storageReady===true,'TEST school Drive is not connected');
 report.storageHealthMs=storage.elapsedMs;
 report.scriptBundleVersion=/^20\d{2}-\d{2}-\d{2}\.\d+$/.test(storage.value.scriptBundleVersion||'')?storage.value.scriptBundleVersion:'unknown';
 report.brokerEdgeDeliveryVersion=storage.value.brokerEdgeDeliveryVersion||0;
 report.cloudflareLiveSyncMeasured=false;
 for(let i=0;i<3;i++){
  const id='vs_latency_probe_'+Date.now().toString(36)+'_'+randomBytes(6).toString('hex');
  const writeOp='speed-write-'+randomBytes(20).toString('hex');
  const deleteOp='speed-delete-'+randomBytes(20).toString('hex');
  const sample={run:i+1,createAckMs:null,verifiedPointReadMs:null,deleteAckMs:null,tombstoneReadMs:null,verified:false,cleanupVerified:false,cloudflareAccepted:false,driveState:null};
  report.samples.push(sample);
  let candidate;
  const read=()=>call('managed/records',{collection:'school_settings',operation:'read',syncProtocol:2,id});
  try{
   const empty=await read();
   assert(!empty.value.records?.[id],'Unexpected existing probe key; refusing overwrite');
   const payload={schoolId:SCHOOL,probeKind:'temporary-sync-latency-test',probeNonce:writeOp,label:'SYNTHETIC TEST ONLY'};
   const write=await call('managed/records',{collection:'school_settings',operation:'write',syncProtocol:2,id,operationId:writeOp,expectedRecordRevision:'',data:payload});
   sample.createAckMs=write.elapsedMs;
   sample.cloudflareAccepted=write.value.cloudflareAccepted===true;
   sample.driveState=write.value.driveState||null;
   assert(typeof write.value.recordRevision==='string'&&!!write.value.recordRevision&&!/^(live-|cf-)/.test(write.value.recordRevision),'Write did not return verified owner revision');
   const point=await read();
   sample.verifiedPointReadMs=point.elapsedMs;
   candidate=point.value.records?.[id];
   assert(candidate?.schoolId===SCHOOL&&candidate._syncOperationId===writeOp&&candidate._syncRevision===write.value.recordRevision&&candidate.probeNonce===writeOp&&!candidate._syncDeleted,'Signed Drive/Sheet readback mismatch');
   sample.verified=true;
  }catch(e){
   sample.failure=String(e.message).slice(0,200);
  }finally{
   // Cleanup only if this exact unique synthetic operation owns the record.
   try{
    const latest=await read();
    candidate=latest.value.records?.[id];
    if(candidate?._syncDeleted===true){sample.cleanupVerified=true;}
    else if(candidate?.schoolId===SCHOOL&&candidate._syncOperationId===writeOp&&candidate.probeNonce===writeOp&&
      typeof candidate._syncRevision==='string'&&!/^(live-|cf-)/.test(candidate._syncRevision)){
      const deletion=await call('managed/records',{collection:'school_settings',operation:'delete',syncProtocol:2,id,operationId:deleteOp,expectedRecordRevision:candidate._syncRevision});
      sample.deleteAckMs=deletion.elapsedMs;
      assert(typeof deletion.value.recordRevision==='string'&&!!deletion.value.recordRevision,'Delete ACK not verified');
      const tombstone=await read();
      sample.tombstoneReadMs=tombstone.elapsedMs;
      const final=tombstone.value.records?.[id];
      sample.cleanupVerified=Boolean(final?._syncDeleted===true&&final._syncOperationId===deleteOp&&final._syncRevision===deletion.value.recordRevision);
    }else if(candidate){sample.cleanupWarning='Unexpected foreign operation; no deletion attempted';}
    else{sample.cleanupVerified=true;sample.cleanupWarning='No matching synthetic record remained';}
   }catch(e){sample.cleanupWarning='Exact-operation cleanup not verified: '+String(e.message).slice(0,180);}
  }
  if(sample.failure||!sample.verified||!sample.cleanupVerified)break;
 }
 const successful=report.samples.filter(x=>x.verified&&x.cleanupVerified);
 report.sampleCount=successful.length;
 function stats(field){const arr=successful.map(x=>x[field]).filter(Number.isFinite).sort((a,b)=>a-b);return arr.length?{minMs:arr[0],medianMs:arr[Math.floor(arr.length/2)],maxMs:arr[arr.length-1]}:null;}
 report.verifiedWriteAck=stats('createAckMs');
 report.verifiedPointRead=stats('verifiedPointReadMs');
 report.verifiedDeleteAck=stats('deleteAckMs');
 report.verifiedTombstoneRead=stats('tombstoneReadMs');
 report.status=successful.length===3?'PASS':'FAIL';
 if(report.brokerEdgeDeliveryVersion!==1)report.warning='TEST broker is using existing signed Google Script route; Cloudflare instant-ACK was NOT measured.';
}
main().catch(e=>{report.status='FAIL';report.failure=String(e.message).slice(0,200);})
 .finally(()=>{fs.mkdirSync('build/cloud-prerequisites',{recursive:true});fs.writeFileSync(REPORT,JSON.stringify(report,null,2));console.log('REAL_TEST_SYNC_SPEED '+JSON.stringify(report));if(report.status!=='PASS')process.exitCode=1;});
