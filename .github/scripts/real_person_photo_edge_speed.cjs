'use strict';
// TEST-only real Cloudflare -> Google Script/Drive measurement for three
// synthetic identities with a real valid synthetic PNG. NO production school.
const fs=require('node:fs'),crypto=require('node:crypto'),zlib=require('node:zlib');
const {performance}=require('node:perf_hooks');
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d';
const ENDPOINT='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const LOGIN='https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const OUT='build/cloud-prerequisites/real-person-photo-edge-speed.json';
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
const makeOp=()=>crypto.randomBytes(16).toString('hex');
const now=()=>performance.now();
const round=n=>Math.round(n*100)/100;
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
function check(ok,label){if(!ok)throw Error(label);}
function png(){
 const w=144,h=176,raw=Buffer.alloc(h*(w*3+1)),bits=crypto.randomBytes(w*h*3);
 for(let y=0;y<h;y++){raw[y*(w*3+1)]=0;bits.copy(raw,y*(w*3+1)+1,y*w*3,(y+1)*w*3);}
 const crcTable=Array.from({length:256},(_,i)=>{let c=i;for(let j=0;j<8;j++)c=(c&1)?(0xedb88320^(c>>>1)):(c>>>1);return c>>>0;});
 const crc=b=>{let c=0xffffffff;for(const octet of b)c=crcTable[(c^octet)&255]^(c>>>8);return (c^0xffffffff)>>>0;};
 const chunk=(type,data)=>{const tag=Buffer.from(type),len=Buffer.alloc(4),sum=Buffer.alloc(4);len.writeUInt32BE(data.length);sum.writeUInt32BE(crc(Buffer.concat([tag,data])));return Buffer.concat([len,tag,data,sum]);};
 const ihdr=Buffer.alloc(13);ihdr.writeUInt32BE(w,0);ihdr.writeUInt32BE(h,4);ihdr[8]=8;ihdr[9]=2;
 return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',ihdr),chunk('IDAT',zlib.deflateSync(raw)),chunk('IEND',Buffer.alloc(0))]);
}
const report={scope:'real TEST Sync V2 API only; real photo PNG; signed GS readback',schoolId:SCHOOL,
 liveNetworkMeasured:true,windowsAppMeasured:false,productionCertified:false,photoBytesVerified:false,roles:[],
 createdAt:new Date().toISOString()};
async function request(url,body,token){
 const t=now();
 const response=await fetch(url,{method:body?'POST':'GET',redirect:'error',headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(120000)});
 let value;try{value=await response.json();}catch{value={};}
 return {status:response.status,value,ms:round(now()-t)};
}
async function main(){
 check(process.env.VS_PERSON_PHOTO_TEST===SCHOOL,'No TEST-only opt-in');
 check(process.env.VS_TEST_LOGIN_EMAIL&&process.env.VS_TEST_LOGIN_PASSWORD,'Missing TEST login secrets');
 const health=await request(ENDPOINT+'/healthz');
 check(health.status===200&&health.value.ready===true&&health.value.projectId==='saarthi-ai-df12b','TEST broker identity failed');
 report.runtimeCommit=health.value.runtimeCommit||'unknown';
 const auth=await request(LOGIN,{email:process.env.VS_TEST_LOGIN_EMAIL,password:process.env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});
 check(auth.status===200&&typeof auth.value.idToken==='string','TEST Firebase login failed');
 const token=auth.value.idToken;
 async function call(action,body){
  const result=await request(ENDPOINT,{action,schoolId:SCHOOL,...body},token);
  if(result.status!==200||result.value?.success!==true||result.value?.schoolId!==SCHOOL){
   const code=/^[A-Z_]{2,100}$/.test(result.value?.code||'')?result.value.code:'REMOTE_FAILURE';
   throw Error(action+' HTTP '+result.status+' '+code);
  }
  return result;
 }
 const session=await call('managed/session',{});
 check(session.value.allowed===true&&session.value.activated===true&&session.value.status==='licensed'&&session.value.uid===auth.value.localId,'School not authorized');
 const storage=await call('managed/storage/check',{});
 check(storage.value.storageReady===true,'TEST Drive not ready');
 report.scriptBundleVersion=storage.value.scriptBundleVersion||'unknown';
 report.brokerEdgeDeliveryVersion=storage.value.brokerEdgeDeliveryVersion||0;
 check(report.brokerEdgeDeliveryVersion===1,'Cloudflare all-data lane unavailable in real TEST deployment');
 const run=String(process.env.GITHUB_RUN_ID||Date.now()).replace(/[^0-9]/g,'').slice(-14);
 const photo=png(),photoHash=hash(photo);
 report.syntheticPhoto={mime:'image/png',width:144,height:176,bytes:photo.length,sha256:photoHash};
 const settle=async(initial,tag)=>{
  check(initial.value.cloudflareAccepted===true,tag+' was not accepted by Cloudflare');
  const initialMs=initial.ms, ticket=initial.value.delivery;
  if(!ticket){check(initial.value.driveState==='verified',tag+' missing delivery status');return {cloudflareAckMs:initialMs,cloudToDriveMs:0,verified:initial.value};}
  check(ticket&&/^[a-f0-9]{64}$/.test(ticket.id)&&(/^(records|file-[a-f0-9]{64})$/.test(ticket.lane)),tag+' invalid Cloudflare ticket');
  const started=now();
  for(let attempt=0;attempt<15;attempt++){
   const s=await call('managed/cloudflare/operation',{lane:ticket.lane,id:ticket.id,waitMillis:18000});
   if(!s.value.delivery){
    check(s.value.driveState==='verified'&&s.value.cloudflareAccepted===true,tag+' owner ACK not verified');
    return {cloudflareAckMs:initialMs,cloudToDriveMs:round(now()-started),verified:s.value,
      ...(s.value.deliveryTiming?{ownerWorkerDeliveryMillis:s.value.deliveryTiming.deliveryMillis,workerQueueWaitMillis:s.value.deliveryTiming.queueWaitMillis??null}:{})};
   }
   check(s.value.delivery?.id===ticket.id&&s.value.delivery?.lane===ticket.lane,tag+' ticket changed');
  }
  throw Error(tag+' no verified Drive ACK after 15 polls');
 };
 const recordsRead=(collection,id)=>call('managed/records',{collection,id,operation:'read',syncProtocol:2});
 for(const [index,role] of ['student','teacher','staff'].entries()){
  const suffix=run+'_'+index+'_'+crypto.randomBytes(3).toString('hex');
  const collection=role==='student'?'students_directory':'teachers_directory';
  const id='CFSPEED_'+role.toUpperCase()+'_'+suffix;
  const entry={role,collection,recordId:id,photoBytes:photo.length,appToCloudflareRecordAddMs:null,cloudflareToDriveRecordAddMs:null,
    appToCloudflarePhotoMs:null,cloudflareToDrivePhotoMs:null,appToCloudflareDeleteMs:null,cloudflareToDriveDeleteMs:null,
    addDriveVerified:false,deleteDriveVerified:false,photoDriveVerified:false,photoDeleteVerified:null};
  report.roles.push(entry);
  let created=false,revision=null,personGeneration='p-'+crypto.randomBytes(16).toString('hex'),fileId=null;
  let operationAdd=makeOp();
  try{
   const original=await recordsRead(collection,id);
   check(!original.value.records?.[id],role+' fixture already exists');
   // Image first, to respect the real client order: upload file, then attach Drive id.
   const uploadKey='cf_photo_speed_'+suffix,meta={edgeDeliveryVersion:1,uploadKey,name:uploadKey+'.png',mime:'image/png',sha256:photoHash,sizeBytes:photo.length};
   const begin=await call('managed/file/upload/resumable',{...meta,operation:'begin'});
   const photoEdge=begin.value.cloudflareAccepted===true;
   entry.photoRoute=photoEdge?'cloudflare-first':'direct-script-fallback';
   entry.photoBeginMs=begin.ms;
   entry.photoBeginEvidence={cloudflareAccepted:photoEdge,driveState:begin.value.driveState||null,uploadResumableVersion:begin.value.uploadResumableVersion||null};
   check(begin.value.offset===0&&begin.value.committed===false,'Unexpected existing photo staging');
   const part=await call('managed/file/upload/resumable',{...meta,operation:'part',offset:0,base64:photo.toString('base64'),chunkSha256:photoHash});
   // The existing TEST broker can begin a resumable upload on Script and
   // route the byte-bearing part through Cloudflare after capability caching.
   // The byte-bearing part determines whether the photo used Cloudflare.
   const partEdge=part.value.cloudflareAccepted===true;
   entry.photoRoute=partEdge?(photoEdge?'cloudflare-first':'cloudflare-part-after-direct-begin'):'direct-script-fallback';
   let verified;
   if(partEdge){
    const result=await settle(part,role+' photo');
    entry.appToCloudflarePhotoMs=round(begin.ms+part.ms);
    entry.cloudflareToDrivePhotoMs=result.cloudToDriveMs;
    entry.photoDeliveryMillis=result.ownerWorkerDeliveryMillis??null;
    verified=result.verified;
   }else{
    // Existing TEST script may lack spool-photo capability. Never pretend that
    // this direct Drive upload measured Cloudflare.
    entry.directPhotoUploadMs=round(begin.ms+part.ms);
    verified=part.value;
   }
   check(verified.committed===true&&verified.sha256===photoHash&&
     /^[A-Za-z0-9_-]{1,200}$/.test(verified.fileId||''),'Photo Drive file ACK invalid');
   fileId=verified.fileId;
   const readPhoto=await call('managed/file/read',{fileId});
   check(readPhoto.value.mime==='image/png'&&hash(Buffer.from(readPhoto.value.base64||'','base64'))===photoHash,'Uploaded photo permanent Drive hash mismatch');
   entry.photoDriveVerified=true;
   entry.photoReadbackMs=readPhoto.ms;
   const fields={schoolId:SCHOOL,name:'SYNTHETIC PHOTO SPEED TEST - '+role,photoFileId:fileId,photoUrl:'https://drive.google.com/file/d/'+fileId+'/view'};
   const data=role==='student'?{...fields,studentId:id,mobileStableId:personGeneration,class:'CF_TEST',studentClass:'CF_TEST',rollNo:'9'+suffix.slice(-6),parentName:'SYNTHETIC'}:
    {...fields,teacherId:id,role,designation:role==='teacher'?'TEST TEACHER':'TEST STAFF',status:'active'};
   const write=await call('managed/records',{edgeDeliveryVersion:1,collection,operation:'write',id,syncProtocol:2,operationId:operationAdd,expectedRecordRevision:'',data});
   const receipt=await settle(write,role+' add');
   entry.appToCloudflareRecordAddMs=receipt.cloudflareAckMs;
   entry.cloudflareToDriveRecordAddMs=receipt.cloudToDriveMs;
   entry.addWorkerDeliveryMillis=receipt.ownerWorkerDeliveryMillis??null;
   entry.addQueueWaitMillis=receipt.workerQueueWaitMillis??null;
   check(typeof receipt.verified.recordRevision==='string'&&receipt.verified.recordRevision&&!receipt.verified.recordRevision.startsWith('cf-'),'Photo record owner ACK missing');
   revision=receipt.verified.recordRevision;
   const point=await recordsRead(collection,id);
   const stored=point.value.records?.[id];
   check(stored?.schoolId===SCHOOL&&stored._syncOperationId===operationAdd&&stored._syncRevision===revision&&
      (stored.photoFileId===fileId||stored.photoUrl===data.photoUrl),'Cloud-written profile with photo not verified on Drive');
   entry.addReadbackMs=point.ms;
   entry.addDriveVerified=true;created=true;
  }catch(e){entry.addFailure=String(e.message).slice(0,240);}
  // Cleanup only exact synthetic owner revision, never unrelated school data.
  // The unique fixture must not be force-deleted if the edge job is unresolved.
  try{
   const point=await recordsRead(collection,id),row=point.value.records?.[id];
   if(row?._syncDeleted){entry.deleteDriveVerified=true;}
   else if(row?.schoolId===SCHOOL&&row._syncOperationId===operationAdd&&
      typeof row._syncRevision==='string'&&row._syncRevision&&String(row.name||'').startsWith('SYNTHETIC PHOTO SPEED TEST')){
    const operationDelete=makeOp();
    const del=await call('managed/records',{edgeDeliveryVersion:1,collection,operation:'delete',id,syncProtocol:2,
      operationId:operationDelete,expectedRecordRevision:row._syncRevision,
      ...(role==='student'?{deletedStudentGeneration:personGeneration}:{})});
    const receipt=await settle(del,role+' delete');
    entry.appToCloudflareDeleteMs=receipt.cloudflareAckMs;
    entry.cloudflareToDriveDeleteMs=receipt.cloudToDriveMs;
    entry.deleteWorkerDeliveryMillis=receipt.ownerWorkerDeliveryMillis??null;
    entry.deleteQueueWaitMillis=receipt.workerQueueWaitMillis??null;
    const checked=await recordsRead(collection,id);
    const tombstone=checked.value.records?.[id];
    entry.deleteDriveVerified=Boolean(tombstone?._syncDeleted===true&&tombstone._syncOperationId===operationDelete);
    entry.deleteReadbackMs=checked.ms;
    check(entry.deleteDriveVerified,'Signed Drive delete tombstone not verified');
   }else if(!row){entry.deleteDriveVerified=true;entry.cleanupNote='No synthetic profile written';}
   else entry.cleanupError='Unexpected record identity; not deleted';
  }catch(e){entry.cleanupError=String(e.message).slice(0,240);}
  if(fileId&&entry.deleteDriveVerified){
   // The file read probes whether deletion cascaded to original photo bytes.
   // Do not trash files via independent credentials, which could break ownership.
   try{const old=await call('managed/file/read',{fileId});entry.photoDeleteVerified=false;entry.photoStillReadableBytes=Buffer.from(old.value.base64||'','base64').length;}
   catch(e){entry.photoDeleteVerified=/HTTP (403|404|410)/.test(e.message);entry.photoDeleteNote=entry.photoDeleteVerified?'Photo not readable after delete':'Photo removal not proven';}
  }
  if(entry.addFailure||entry.cleanupError)break;
 }
 report.status=report.roles.length===3&&report.roles.every(r=>r.addDriveVerified&&r.deleteDriveVerified&&r.photoDriveVerified)?'PASS':'INCOMPLETE';
 report.perRoleComplete=report.roles.map(r=>({role:r.role,complete:r.addDriveVerified&&r.deleteDriveVerified&&r.photoDriveVerified}));
}
main().catch(e=>{report.status='FAILED_PREREQUISITE';report.error=String(e.message).slice(0,250);})
.finally(()=>{fs.mkdirSync('build/cloud-prerequisites',{recursive:true});fs.writeFileSync(OUT,JSON.stringify(report,null,2));console.log('REAL_PERSON_PHOTO_EDGE_SPEED '+JSON.stringify(report));if(report.status!=='PASS')process.exitCode=1;});
