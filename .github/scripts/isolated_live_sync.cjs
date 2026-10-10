'use strict';
// Real TEST-only protocol acceptance. No app UI/emulator/physical-device claims.
const {createHash}=require('node:crypto');
const {isolatedRunPrefix}=require('./isolated_fixture_identity.cjs');
module.exports=async function({post,check,endpoint,schoolId,token,report}){
 const safeRead=require('./safe_test_read_retry.cjs');
 const admin=body=>safeRead(post,endpoint,{...body,schoolId},token,report);
 const mobile=request=>post(endpoint,{action:'managed/mobile',schoolId,request});
 const prefix=isolatedRunPrefix();
 async function write(collection,id,data){
  const prior=await admin({action:'managed/records',operation:'read',collection,syncProtocol:2});
  check('Read TEST '+collection,prior,prior.http===200&&prior.data.schoolId===schoolId);
  const row=prior.data.records?.[id];
  if(row){if(row.syntheticTest!==true)throw Error('Existing non-synthetic record retained');return row;}
  const operationId=prefix+'-'+createHash('sha256').update(collection+'/'+id).digest('hex').slice(0,24);
  const body={action:'managed/records',operation:'write',collection,id,data:{...data,syntheticTest:true},syncProtocol:2,operationId,expectedRecordRevision:''};
  let r=await admin(body);check('Real durable Script ACK '+collection,r,r.http===200&&r.data.syncProtocol===2&&typeof r.data.recordRevision==='string');
  const revision=r.data.recordRevision;
  r=await admin(body);check('Identical retry ACK '+collection,r,r.http===200&&r.data.recordRevision===revision);
  return {...data,_syncRevision:revision};
 }
 let r=await admin({action:'managed/profile',operation:'initialize',schoolName:'TEST Sync V2',principalName:'Synthetic TEST Administrator'});
 check('TEST registration identity',r,r.http===200&&r.data.profile?.schoolName==='TEST Sync V2');
 await write('school_settings','school_location',{latitude:24.8,longitude:92.7,radiusMeters:100});
 const personId=prefix+'-student',linkToken=createHash('sha256').update(prefix+'/synthetic-qr').digest('hex');
 await write('students_directory',personId,{name:'Synthetic TEST Student',class:'1',rollNo:'900001',dob:'2015-01-01',mobileStableId:personId,mobileLinkToken:linkToken});
 r=await mobile({action:'mobile_login',projectId:schoolId,role:'student',personId,linkToken,studentClass:'1',rollNo:'900001',dob:'2015-01-01'});
 check('Real mobile protocol login',r,r.http===200&&typeof r.data.sessionToken==='string');
 const sessionToken=r.data.sessionToken;
 const noticeId=prefix+'-notice';const start=performance.now();
 const notice=await write('school_notices',noticeId,{title:'Synthetic TEST cloud notice',message:'Protocol acceptance only',timestamp:Date.now()});
 r=await mobile({action:'mobile_dashboard',sessionToken,projectId:schoolId});
 check('Mobile reads newly published real cloud notice without Windows presence',r,r.http===200&&r.data.notices?.some(n=>n.id===noticeId));
 report.noticeWriteRetryAndReadbackMs=Math.round(performance.now()-start);
 const revisions=r.data.revisions,priorCard=r.data.idCardPackage;
 r=await mobile({action:'mobile_refresh',sessionToken,projectId:schoolId});
 check('Actual Android queue refresh provides signed attendance permit',r,r.http===200&&typeof r.data.attendancePermit==='string');
 let permit=r.data.attendancePermit;
 const pdf=Buffer.from('%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n');
 const upload={action:'managed/file/upload',name:prefix+'-fixture.pdf',mime:'application/pdf',base64:pdf.toString('base64'),uploadKey:prefix+'-fixture'};
 r=await admin(upload);check('Real Drive upload ACK',r,r.http===200&&typeof r.data.fileId==='string');const fileId=r.data.fileId;
 r=await admin(upload);check('Drive duplicate retry returns same file',r,r.http===200&&r.data.fileId===fileId);
 const docId=prefix+'-card-fixture',digest=createHash('sha256').update(pdf).digest('hex');
 await write('documents',docId,{personId,ownerRole:'student',documentKind:'idCard',documentName:'Synthetic PDF transport fixture',mimeType:'application/pdf',fileId,sizeBytes:pdf.length,contentHash:digest,documentRevision:digest});
 r=await mobile({action:'mobile_document',sessionToken,documentId:docId});
 check('Mobile retrieves identical private Drive PDF bytes with Windows absent',r,r.http===200&&r.data.base64===pdf.toString('base64'));
 r=await mobile({action:'mobile_dashboard',sessionToken,knownRevisions:revisions});
 check('Mobile delta discovers or retains verified unchanged ID-card metadata',r,r.http===200&&(r.data.idCardPackage?.documentId===docId||priorCard?.documentId===docId&&r.data.revisions?.documents===revisions.documents&&!Object.hasOwn(r.data,'idCardPackage')));
 let delta=await admin({action:'managed/changes',collections:['students_directory','school_notices','documents'],knownRevisions:{}});
 check('Second PC protocol discovers shared TEST records',delta,delta.http===200&&delta.data.changes?.documents?.records?.[docId]?.fileId===fileId);
 const knownRevisions=Object.fromEntries(Object.entries(delta.data.changes).map(([k,v])=>[k,v.collectionRevision]));
 delta=await admin({action:'managed/changes',collections:Object.keys(knownRevisions),knownRevisions});
 check('Unchanged delta omits unchanged records',delta,delta.http===200&&Object.values(delta.data.changes).every(x=>x.unchanged===true&&Object.keys(x.records).length===0));
 r=await post(endpoint,{action:'managed/changes',schoolId:'vs-'+'0'.repeat(32),collections:['documents']},token);
 check('Foreign school rejected with authenticated TEST token',r,r.http===403&&r.data.code==='ISOLATED_TEST_SCOPE_REQUIRED');
 r=await admin({action:'managed/records',operation:'write',collection:'school_notices',id:noticeId,syncProtocol:2,operationId:prefix+'-stale-cas-conflict',expectedRecordRevision:'stale-test-revision',data:{title:'Rejected stale TEST edit',syntheticTest:true}});
 check('Real stale revision is HTTP 409 without ACK',r,r.http===409&&r.data.code==='RECORD_REVISION_CONFLICT');
 const originalOperation=prefix+'-'+createHash('sha256').update('school_notices/'+noticeId).digest('hex').slice(0,24);
 r=await admin({action:'managed/records',operation:'write',collection:'school_notices',id:noticeId,syncProtocol:2,operationId:originalOperation,expectedRecordRevision:'',data:{title:'Rejected changed operation TEST edit',syntheticTest:true}});
 check('Real operation ID reuse is HTTP 409 without ACK',r,r.http===409&&r.data.code==='OPERATION_ID_CONFLICT');
 r=await admin({action:'managed/records',operation:'read',collection:'school_notices',syncProtocol:2});
 check('Rejected conflicts preserve existing TEST notice',r,r.http===200&&r.data.records?.[noticeId]?._syncRevision===notice._syncRevision&&r.data.records?.[noticeId]?.title===notice.title);
 const priorAttendance=await admin({action:'managed/records',operation:'read',collection:'attendance_records',syncProtocol:2});
 if(priorAttendance.http!==200)throw Error('Attendance readback required');
 const priorEntry=Object.values(priorAttendance.data.records||{}).find(row=>row.personId===personId&&Number.isSafeInteger(row.entryCapturedAt));
 r=await mobile({action:'mobile_refresh',sessionToken,projectId:schoolId});
 check('Fresh capture-authorizing TEST permit',r,r.http===200&&typeof r.data.attendancePermit==='string');
 permit=r.data.attendancePermit;
 const captured=priorEntry?priorEntry.entryCapturedAt:Date.now();
 report.attendanceSampleAlreadyCompleted=Boolean(priorEntry);
 const attendance={action:'mobile_mark_attendance',sessionToken,attendancePermit:permit,projectId:schoolId,role:'student',personId,linkToken,latitude:24.8,longitude:92.7,accuracy:5,mode:'entry',clientCapturedAt:captured};
 r=await mobile(attendance);check('Actual isolated durable attendance acceptance',r,r.http===200&&r.data.accepted===true&&typeof r.data.operationId==='string');
 const op=r.data.operationId;report.attendanceOperationId=op;
 r=await mobile(attendance);check('Attendance identical retry deduplicated',r,r.http===200&&r.data.operationId===op&&r.data.duplicate===true);
 for(let i=0;i<30;i++){
  r=await admin({action:'managed/attendance/status',operationIds:[op]});
  if(r.http!==200)throw Error('Attendance status unavailable');
  const row=r.data.operations[0];
  if(row.state==='completed'){
   report.realAttendanceQueueToAckMs=row.completedAt-row.createdAt;
   report.realAttendanceCompletedAt=row.completedAt;
   r=await mobile({action:'mobile_attendance_list',sessionToken,month:new Date(captured+19800000).toISOString().slice(0,7)});
   check('Original capture timestamp survives actual Drive attendance ACK',r,r.http===200&&r.data.attendance?.some(x=>x.entryCapturedAt===captured));
   report.realAttendancePending=0;return;
  }
  if(row.state==='needsAttention')throw Error('Attendance needs review; durable operation retained');
  await new Promise(resolve=>setTimeout(resolve,5000));
 }
 report.realAttendancePending=1;throw Error('Actual cloud ACK not yet received; pending retained');
};
