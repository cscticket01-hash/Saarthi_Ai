'use strict';
// Live TEST-school proof. Never run against production, existing students or
// another school. Uses the same signed broker actions as Windows/Android/Web;
// it does NOT assert that a physical PC, phone or hosted website UI was tested.
const crypto=require('node:crypto'),fs=require('node:fs');
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d';
const ENDPOINT='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const LOGIN='https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const OUT='build/cloud-prerequisites/delete-everywhere-live.json';
const digest=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
const report={schoolId:SCHOOL,scope:'real signed TEST-school APIs / Google Drive / Cloudflare, no physical devices',sourceCommit:process.env.GITHUB_SHA,
  verifiedRuntime:null,scriptBundleVersion:null,realProviderCalls:true,windowsClientBinaryExecuted:false,
  androidOsExecuted:false,websiteBrowserExecuted:false,status:'RUNNING',checks:[],createdAt:new Date().toISOString()};
const ensure=(condition,name)=>{if(!condition)throw Error(name);report.checks.push({name,status:'PASS'});};
async function http(url,body,token){
 const r=await fetch(url,{method:body?'POST':'GET',redirect:'error',
 headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},
 ...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(120000)});
 let data={};try{data=await r.json();}catch{}
 return {http:r.status,data};
}
async function main(){
 ensure(process.env.GITHUB_ACTIONS==='true'&&process.env.GITHUB_REPOSITORY==='cscticket01-hash/Saarthi_Ai'&&process.env.GITHUB_REF==='refs/heads/feature/smart-sync-3'
   &&process.env.VS_DELETE_EVERYWHERE_TEST===SCHOOL,'strict isolated TEST-only opt-in');
 ensure(/^[a-f0-9]{40}$/.test(process.env.VS_EXPECTED_TEST_RUNTIME||''),'reviewed commit pin');
 ensure(Boolean(process.env.VS_TEST_LOGIN_EMAIL&&process.env.VS_TEST_LOGIN_PASSWORD),'isolated TEST-only credentials exist');
 await require('./test_runtime_identity.cjs').waitForRuntime(process.env.VS_EXPECTED_TEST_RUNTIME);
 const health=await http('https://saarthi-sync-v2-test.onrender.com/school-cloud/healthz');
 ensure(health.http===200&&health.data.ready===true&&health.data.projectId==='saarthi-ai-df12b'&&
   health.data.runtimeCommit===process.env.VS_EXPECTED_TEST_RUNTIME,'actual deployed TEST Render source matches reviewed commit');
 report.verifiedRuntime=health.data.runtimeCommit;
 const signIn=await http(LOGIN,{email:process.env.VS_TEST_LOGIN_EMAIL,password:process.env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});
 ensure(signIn.http===200&&typeof signIn.data.idToken==='string','Firebase isolated TEST administrator');
 const token=signIn.data.idToken;
 const admin=body=>http(ENDPOINT,{...body,schoolId:SCHOOL},token);
 const call=async(body,stage)=>{const r=await admin(body);if(r.http!==200||r.data.success!==true||r.data.schoolId!==SCHOOL)
   throw Object.assign(Error(stage+' HTTP '+r.http+' '+(/^[A-Z_]{2,90}$/.test(r.data.code||'')?r.data.code:'PROVIDER_REJECTED')),{code:r.data.code,status:r.http});return r.data;};
 const mobile=request=>http(ENDPOINT,{action:'managed/mobile',schoolId:SCHOOL,request});
 const session=await call({action:'managed/session'},'TEST licence');
 ensure(session.allowed===true&&session.activated===true&&session.status==='licensed','active isolated TEST licence');
 const caps=await call({action:'managed/storage/check'},'TEST storage');
 report.scriptBundleVersion=caps.scriptBundleVersion;
 ensure(caps.storageReady===true&&caps.deleteEverywhereVersion===1&&caps.brokerEdgeDeliveryVersion===1&&caps.brokerAtomicSmallFilesVersion===1,
   'TEST Google Drive + delete everywhere + Cloudflare prerequisites');
 ensure(caps.scriptBundleVersion===require('./reviewed_script_version.cjs').currentReviewedScriptVersion(),
   'deployed school Apps Script version matches reviewed contract');
 const run=String(process.env.GITHUB_RUN_ID||'');
 ensure(/^[1-9][0-9]{3,19}$/.test(run),'GitHub isolated run identity');
 const nonce=crypto.randomBytes(4).toString('hex');
 const student='TEST_DELETE_'+run+'_'+nonce;
 const generation='p-'+digest('test-delete/'+student);
 const linkToken=digest('test-mobile-link/'+student);
 const documentId='TEST_DELETE_CARD_'+run+'_'+nonce, feeId='TEST_DELETE_FEE_'+run+'_'+nonce;
 const rollNo=String((Number(run.slice(-6))%900000)+100000);
 const pdf=Buffer.from('%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n');
 const fileHash=digest(pdf),newOperation=()=>crypto.randomBytes(16).toString('hex');
 const delivery=async (initial,stage,request)=>{
  if(request&&require('./native_person_receipt.cjs').verifiedNativeReceipt(initial,request,SCHOOL)){
   ensure(true,stage+' exact signed native person readback');return initial;
  }
  ensure(initial.cloudflareAccepted===true,stage+' Cloudflare committed enqueue');
  if(!initial.delivery){ensure(initial.driveState==='verified',stage+' direct signed Drive commit');return initial;}
  const ticket=initial.delivery;
  ensure(/^[a-f0-9]{64}$/.test(ticket.id)&&/^(records|file-[a-f0-9]{64})$/.test(ticket.lane),stage+' stable exact receipt');
  for(let n=0;n<50;n++){
   const reply=await call({action:'managed/cloudflare/operation',lane:ticket.lane,id:ticket.id,waitMillis:18000},stage+' poll');
   if(!reply.delivery){ensure(reply.driveState==='verified',stage+' final independent provider ACK');return reply;}
   if(reply.delivery.id!==ticket.id||reply.delivery.lane!==ticket.lane)throw Error(stage+' receipt identity changed');
  }
  throw Error(stage+' original work retained but verified completion timed out');
 };
 const read=async (collection,id)=>call({action:'managed/records',operation:'read',collection,id,syncProtocol:2},'exact '+collection+' read');
 const fixtures={student,documentId,feeId,fileId:null,deleteOperationId:null};
 report.fixtureIds={student,documentId,feeId}; // synthetic-only, no emails/tokens
 let parentRevision='',deleted=false;
 try{
  const addRequest={action:'managed/records',edgeDeliveryVersion:1,
    operation:'write',collection:'students_directory',id:student,syncProtocol:2,
    operationId:newOperation(),expectedRecordRevision:'',data:{
      schoolId:SCHOOL,name:'SYNTHETIC TEST DELETE '+run,class:'1',section:'TEST_DEL_'+nonce,rollNo,dob:'2015-01-01',
      mobileStableId:generation,mobileLinkToken:linkToken,syntheticTest:true,
      parentName:'TEST ONLY',contact:'0000000000'
    }};
  report.fixtureIds.addOperationId=addRequest.operationId;
  const add=await delivery(await call(addRequest,'synthetic student add'),'student add',addRequest);
  parentRevision=add.recordRevision;
  const before=await read('students_directory',student);
  ensure(before.records?.[student]?._syncDeleted!==true&&before.records?.[student]?._syncRevision===parentRevision,
    'Windows signed read sees original TEST person');
  const uploaded=await delivery(await call({action:'managed/file/upload',edgeDeliveryVersion:1,
    name:'synthetic-delete-'+run+'.pdf',mime:'application/pdf',uploadKey:'delpdf_'+run+'_'+nonce,
    base64:pdf.toString('base64')},'synthetic PDF upload'),'PDF upload');
  ensure(/^[A-Za-z0-9_-]{1,200}$/.test(uploaded.fileId||''),'permanent TEST Drive ID received');
  fixtures.fileId=uploaded.fileId;report.fixtureIds.fileId=uploaded.fileId;
  const bytes=await call({action:'managed/file/read',fileId:uploaded.fileId},'PDF pre-delete readback');
  ensure(bytes.mime==='application/pdf'&&digest(Buffer.from(bytes.base64||'','base64'))===fileHash,
    'actual Google Drive original PDF byte SHA-256');
  const doc=await delivery(await call({action:'managed/records',edgeDeliveryVersion:1,operation:'write',
    collection:'documents',id:documentId,syncProtocol:2,operationId:newOperation(),expectedRecordRevision:'',
    data:{schoolId:SCHOOL,studentId:student,personId:generation,ownerRole:'student',documentKind:'idCard',
      documentName:'SYNTHETIC TEST DELETE PDF',mimeType:'application/pdf',fileId:uploaded.fileId,
      contentHash:fileHash,sizeBytes:pdf.length,documentRevision:fileHash,syntheticTest:true}
  },'signed document add'),'document add');
  ensure(Boolean(doc.recordRevision),'real TEST document saved');
  const fee=await delivery(await call({action:'managed/records',edgeDeliveryVersion:1,operation:'write',
    collection:'fee_payments',id:feeId,syncProtocol:2,operationId:newOperation(),expectedRecordRevision:'',
    data:{schoolId:SCHOOL,studentId:student,personId:generation,amount:123,
      note:'SYNTHETIC DELETE TEST ONLY',syntheticTest:true}
  },'linked fee add'),'linked fee add');
  ensure(Boolean(fee.recordRevision),'linked TEST fee saved');
  const browserRead=await call({action:'managed/changes',
    collections:['students_directory','documents','fee_payments'],knownRevisions:{}},'Website delta before delete');
  const beforeRows=browserRead.changes||{};
  ensure(beforeRows.students_directory?.records?.[student]?._syncDeleted!==true&&
    beforeRows.documents?.records?.[documentId]?._syncDeleted!==true,
    'Website API delta sees student and document before delete');
  const mobileLogin=await mobile({action:'mobile_login',projectId:SCHOOL,role:'student',personId:generation,
    linkToken,studentClass:'1',rollNo,dob:'2015-01-01'});
  ensure(mobileLogin.http===200&&typeof mobileLogin.data.sessionToken==='string',
    'actual Android mobile protocol can authenticate synthetic student');
  const sessionToken=mobileLogin.data.sessionToken;
  const docRead=await mobile({action:'mobile_document',sessionToken,documentId});
  ensure(docRead.http===200&&docRead.data.base64===pdf.toString('base64'),
    'Android mobile protocol gets original TEST PDF before delete');
  // This exact signed action/body is emitted by Windows Firebase Sync 3.0.
  const delOp=newOperation();fixtures.deleteOperationId=delOp;
  const deleteRequest={action:'managed/records',edgeDeliveryVersion:1,operation:'delete',
    collection:'students_directory',id:student,syncProtocol:2,
    operationId:delOp,expectedRecordRevision:parentRevision,
    deletedStudentGeneration:generation,deleteEverywhereVersion:1};
  const finalDelete=await require('./native_person_receipt.cjs').retryExactDelete(deleteRequest,
    request=>call(request,'Windows protocol delete'),{attempts:48,
     observeProgress:require('./delete_plan_progress.cjs').observeDeletePlan(read,SCHOOL,
      progress=>{report.deleteProgress=progress;console.log('TEST_DELETE_PROGRESS '+JSON.stringify(progress));})});
  const del=await delivery(finalDelete,'Delete Everywhere',deleteRequest);
  ensure(del.deleteEverywhereVersion===1&&del.driveDeletionComplete===true&&del.firebaseDeletionComplete===true,
    'Drive deletion and Firebase deletion both fully verified');
  ensure(Array.isArray(del.deletionTargets)&&del.deletionTargets.some(x=>x.collection==='documents'&&x.id===documentId)
    &&del.deletionTargets.some(x=>x.collection==='fee_payments'&&x.id===feeId),
    'signed Google cascade includes the precise document and fee');
  ensure(del.deletedFileIds?.includes(uploaded.fileId),
    'original Google Drive PDF was permanently deleted by source owner');
  deleted=true;
  const afterPerson=await read('students_directory',student);
  ensure(afterPerson.records?.[student]?._syncDeleted===true,
    'Windows signed point read contains deletion tombstone');
  const afterDoc=await read('documents',documentId),afterFee=await read('fee_payments',feeId);
  ensure(afterDoc.records?.[documentId]?._syncDeleted===true&&afterFee.records?.[feeId]?._syncDeleted===true,
    'Google Sheet child records are tombstoned');
  const websiteAfter=await call({action:'managed/changes',
    collections:['students_directory','documents','fee_payments'],knownRevisions:{}},'Website read after delete');
  ensure(websiteAfter.changes?.students_directory?.records?.[student]?._syncDeleted===true&&
    websiteAfter.changes?.documents?.records?.[documentId]?._syncDeleted===true,
    'Website backend API receives both deletion tombstones');
  const afterMobile=await mobile({action:'mobile_document',sessionToken,documentId});
  ensure(afterMobile.http!==200||!afterMobile.data.base64,
    'Android mobile protocol cannot retrieve deleted student PDF');
  const relogin=await mobile({action:'mobile_login',projectId:SCHOOL,role:'student',
    personId:generation,linkToken,studentClass:'1',rollNo,dob:'2015-01-01'});
  ensure(relogin.http!==200||typeof relogin.data.sessionToken!=='string',
    'deleted synthetic student cannot log in again on Android');
  const gone=await admin({action:'managed/file/read',fileId:uploaded.fileId});
  ensure(gone.http!==200||gone.data.success!==true||!gone.data.base64,
    'original Google Drive PDF bytes are inaccessible after delete');
  report.status='PASS';
  report.recordDeletionVerified=true;report.drivePermanentFileDeleteVerified=true;
  report.androidApiVerified=true;report.websiteDeltaApiVerified=true;
 }finally{
  report.syntheticDeleted=deleted;
  // Never guess a different generation or force-purge a fixture. If the
  // operation stalls, preserve its identity for owner-guided safe retry.
  if(!deleted)report.reviewRequired={...fixtures,originalParentRevision:parentRevision,
    reason:'TEST-only fixture may need exact immutable delete reconciliation'};
 }
}
main().catch(e=>{report.status='FAIL';report.blocker=String(e.message).slice(0,180);process.exitCode=1;})
.finally(()=>{fs.mkdirSync('build/cloud-prerequisites',{recursive:true});fs.writeFileSync(OUT,JSON.stringify(report,null,2));
 console.log('DELETE_EVERYWHERE_LIVE_ACCEPTANCE '+JSON.stringify({status:report.status,checks:report.checks.length,
 runtime:report.verifiedRuntime,blocker:report.blocker||null,syntheticDeleted:report.syntheticDeleted||false}));});
