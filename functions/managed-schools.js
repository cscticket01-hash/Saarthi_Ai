const {createWindowsTheme,DEFAULT_THEME}=require('./windows-theme');
const {createSchoolSyncDelivery}=require('./school-sync-delivery');
'use strict';
const {createManagedSupport}=require('./managed-support');
const {createManagedCardReader}=require('./managed-card-reader');
const {createSchoolChangeFeed}=require('./school-change-feed');
const {createManagedDeviceAccess}=require('./managed-device-access');
const {createManagedCardIssueAuthority}=require('./managed-card-issue-authority');
const {firestoreManagedDeviceStore}=require('./managed-device-registry');
const {planStudentImport,canonicalHash}=require('./student-import-plan');
const {createAttendanceQueue,firestoreAttendanceStore}=require('./attendance-queue');
const {randomUUID,randomBytes,createHash,createHmac,timingSafeEqual,createCipheriv,createDecipheriv}=require('node:crypto');
const SCHOOL=/^vs-[a-f0-9]{32}$/;
const COLLECTIONS=new Set(['students_directory','teachers_directory','attendance_logs','teacher_attendance','attendance_records','teacher_schedules','school_notices','school_calendar','exam_results','teacher_salary','school_config','school_settings','fee_settings','fee_ledger','fee_payments','school_expenses','student_scan_index','scanner_devices','documents','backups','exams','exam_center_results']);
const hash=s=>createHash('sha256').update(s).digest('hex');
const fail=(status,message,code)=>{const e=new Error(message);e.status=status;e.publicMessage=true;if(code)e.code=code;throw e;};
function protect(value,key){if(!/^[a-f0-9]{64}$/i.test(key||''))fail(503,'Managed storage encryption is not configured');const iv=randomBytes(12),c=createCipheriv('aes-256-gcm',Buffer.from(key,'hex'),iv);return {iv:iv.toString('hex'),tag:null,body:Buffer.concat([c.update(value,'utf8'),c.final()]).toString('base64'),...{tag:c.getAuthTag().toString('hex')}};}
function unprotect(v,key){if(!/^[a-f0-9]{64}$/i.test(key||''))fail(503,'Managed storage encryption is not configured');const c=createDecipheriv('aes-256-gcm',Buffer.from(key,'hex'),Buffer.from(v.iv,'hex'));c.setAuthTag(Buffer.from(v.tag,'hex'));return Buffer.concat([c.update(Buffer.from(v.body,'base64')),c.final()]).toString('utf8');}
function scriptUrl(value){try{const u=new URL(value);if(u.protocol==='https:'&&u.hostname==='script.google.com'&&!u.username&&!u.password&&!u.port&&!u.search&&!u.hash&&/^\/macros\/s\/[A-Za-z0-9_-]{10,300}\/exec$/.test(u.pathname))return u.href;}catch{}fail(400,'Use the exact school Apps Script /exec URL');}
function clean(value,depth=0){if(depth>12)fail(400,'Record is too deeply nested');if(Array.isArray(value))return value.map(v=>clean(v,depth+1));if(value&&typeof value==='object'){const out={};for(const [k,v]of Object.entries(value)){if(['__proto__','prototype','constructor'].includes(k)||(/password|token|secret|private_key|base64|localpath/i.test(k)&&k!=='mobileLinkToken'))fail(400,'Secrets and media cannot be stored in school records');out[k]=clean(v,depth+1);}return out;}if(typeof value==='string'&&value.startsWith('data:'))fail(400,'Media belongs in Drive files');return value;}
function createManagedSchools({changeFeedIdleGraceMillis=0,deviceAccessEnforced=false,deviceManagementEnabled=false,deviceEnrollmentEnabled=false,deviceOfflinePrivateKey,deviceStore,studentImportEnabled=false,cardIssueEnabled=false,cardReaderEnforced=false,cardReaderPrivateKey,auth,db,projectId,encryptionKey,fetchImpl=fetch,now=Date.now,cloudflareSync=null,attendanceStore,attendanceCollection='attendance_outbox',messaging,scheduleHint=callback=>setTimeout(callback,250),pushDiagnostics=entry=>console.info(JSON.stringify(entry)),monitor=async()=>({available:false,reason:'Monitoring access has not been configured'})}){
 const windowsTheme=createWindowsTheme({db,now});
 const deviceAccess=createManagedDeviceAccess({store:deviceStore||firestoreManagedDeviceStore(db),enforced:deviceAccessEnforced,managementEnabled:deviceManagementEnabled,enrollmentEnabled:deviceEnrollmentEnabled,offlinePrivateKey:deviceOfflinePrivateKey,now});
 const cardAuthority=createManagedCardIssueAuthority({db,now});
 const cardReader=createManagedCardReader({db,enforced:cardReaderEnforced,privateKey:cardReaderPrivateKey,now});
 if(cardIssueEnabled&&!cardReaderEnforced)throw Error('Card issuance requires all-reader enforcement');
 const changeFeed=createSchoolChangeFeed({db,idleGraceMillis:changeFeedIdleGraceMillis,collections:[...COLLECTIONS].filter(c=>c!=='backups')});
 const syncDelivery=createSchoolSyncDelivery({db,feed:changeFeed,now});
 async function changeHint(school,collection,id){
  let timer;try{await Promise.race([
   changeFeed.publishMany(school,Array.isArray(collection)?collection:[collection],id),
   new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('Hint publication budget exceeded')),1000);})
  ]);}catch(_){/* Hints never delay or reverse a verified storage ACK indefinitely; polling repairs gaps. */}
  finally{clearTimeout(timer);}
 }
 const readCard=(schoolId,request)=>cardReader.authorizeOnline({schoolId,deviceId:request.deviceId,sessionToken:request.sessionToken,cardAuthorizationToken:request.cardAuthorizationToken,role:request.role,personId:request.personId,linkToken:request.linkToken,cardIssueId:request.cardIssueId});
 if(!['attendance_outbox','attendance_test_outbox'].includes(attendanceCollection))throw Error('Invalid attendance collection');
 const mobileStates=new Map(),storageStates=new Map(),developerViews=new Map(),readViews=new Map();
 let readBytes=0,viewHits=0,viewMisses=0;
 function evictRead(key){const entry=readViews.get(key);if(entry){readBytes-=entry.bytes;readViews.delete(key);}}
 function invalidate(id){mobileStates.delete(id);storageStates.delete(id);developerViews.delete(id);for(const [key,entry]of readViews)if(entry.schoolId===id)evictRead(key);}
 async function readView(schoolId,body,read,mobile=false){
  const key=schoolId+':'+hash(JSON.stringify(body)),old=readViews.get(key);
  if(old&&old.until>now()){viewHits++;return structuredClone(await old.promise);}
  viewMisses++;
  evictRead(key);while(readViews.size>=1000||readBytes>32*1024*1024)evictRead(readViews.keys().next().value);
  const entry={schoolId,bytes:0,until:now()+5000};readViews.set(key,entry);
  entry.promise=read().then(value=>{
   const size=Buffer.byteLength(JSON.stringify(value));
   // Only a signed, verified, unexpired mobile session may populate a view.
   const expiry=mobile?Number(value.sessionExpiresAt):now()+5000;
   if(!Number.isFinite(expiry)||expiry<=now()||size>512*1024||readBytes+size>32*1024*1024){if(readViews.get(key)===entry)evictRead(key);return value;}
   if(readViews.get(key)===entry){entry.bytes=size;readBytes+=size;entry.until=Math.min(entry.until,expiry);}
   return value;
  }).catch(error=>{if(readViews.get(key)===entry)evictRead(key);throw error;});
  return structuredClone(await entry.promise);
 }
 async function cachedRead(cache,id,read){
  const old=cache.get(id);if(old&&old.until>now())return old.promise;
  if(cache.size>=5000)cache.delete(cache.keys().next().value);
  const promise=read();const value={promise,until:now()+30000};cache.set(id,value);
  try{return await promise;}catch(e){if(cache.get(id)===value)cache.delete(id);throw e;}
 }
 async function mobileState(id){return cachedRead(mobileStates,id,async()=>{
  const [school,entitlement]=await Promise.all([db.doc('platform_schools/'+id).get(),db.doc('school_entitlements/'+id).get()]);
  const e={...entitlement.data()};let licence;
  if(e.status!=='trial')licence=await db.doc('platform_license_status/'+e.licenseHash).get();
  return {school:school.exists?{...school.data()}:null,entitlement:entitlement.exists?e:null,licence:licence?.exists?{...licence.data()}:null};
 });}
 function attendancePermit(schoolId,sessionToken,policy,expiresAt){
  if(!policy||typeof policy!=='object'||!['student','teacher'].includes(policy.role)||typeof policy.personId!=='string'||typeof policy.qrHash!=='string')return undefined;
  const value=Buffer.from(JSON.stringify({...policy,purpose:'attendance',schoolId,sessionHash:hash(sessionToken),
    expiresAt:Math.min(expiresAt,now()+900000,Date.parse(policy.day+'T00:00:00+05:30')+86400000)})).toString('base64url');
  return value+'.'+createHmac('sha256',encryptionKey).update(value).digest('hex');
 }
 function verifyAttendanceIdentity(schoolId,request){
  const token=request.attendancePermit;
  if(typeof token!=='string'||token.length>3000)fail(401,'Refresh school attendance verification.');
  const parts=token.split('.');if(parts.length!==2||!/^[a-f0-9]{64}$/.test(parts[1]))fail(401,'Refresh school attendance verification.');
  if(!timingSafeEqual(createHmac('sha256',encryptionKey).update(parts[0]).digest(),Buffer.from(parts[1],'hex')))fail(401,'Attendance verification rejected.');
  let p;try{p=JSON.parse(Buffer.from(parts[0],'base64url').toString('utf8'));}catch{fail(401,'Attendance verification rejected.');}
  if(p.purpose!=='attendance'||p.schoolId!==schoolId||p.expiresAt<=now()||p.sessionHash!==hash(String(request.sessionToken||''))||
   p.role!==request.role||p.documentId!==request.personId||p.qrHash!==hash(p.role+'/'+request.personId+'/'+request.linkToken))fail(409,'Attendance verification expired or belongs to another person. Refresh school data and retry.');
  return p;
 }
 function verifyAttendance(schoolId,request){
  const p=verifyAttendanceIdentity(schoolId,request);
  if(p.open!==true)fail(400,'School is closed today. Attendance is disabled for everyone','ATTENDANCE_SCHOOL_CLOSED');
  if(p.role==='student'&&p.schedule!=null){
   const w=p.schedule,at=request.clientCapturedAt??now(),minute=new Date(at+19800000).getUTCHours()*60+new Date(at+19800000).getUTCMinutes();
   if(w.enabled!==false&&(w.enabled!==true||!Number.isInteger(w.startMinute)||!Number.isInteger(w.endMinute)||w.startMinute<0||w.endMinute>1440||w.startMinute>=w.endMinute||minute<w.startMinute||minute>=w.endMinute))fail(400,'Student attendance is outside the school schedule','ATTENDANCE_SCHEDULE_CLOSED');
  }
  const lat=Number(request.latitude),lng=Number(request.longitude),accuracy=Number(request.accuracy),radius=Number(p.radiusMeters);
  if(!Number.isFinite(lat)||!Number.isFinite(lng)||Math.abs(lat)>90||Math.abs(lng)>180||!Number.isFinite(accuracy)||accuracy<0||accuracy>radius||!Number.isFinite(radius)||radius<25||radius>200||!Number.isFinite(Number(p.latitude))||!Number.isFinite(Number(p.longitude)))fail(400,'Accurate school location required','ATTENDANCE_LOCATION_ACCURACY');
  const rad=x=>x*Math.PI/180,h=Math.sin(rad(p.latitude-lat)/2)**2+Math.cos(rad(lat))*Math.cos(rad(p.latitude))*Math.sin(rad(p.longitude-lng)/2)**2;
  if(6371000*2*Math.atan2(Math.sqrt(h),Math.sqrt(1-h))>radius)fail(400,'Attendance can be marked only within the school location','ATTENDANCE_OUTSIDE_SCHOOL');
  return p;
 }
 let attendanceWake=()=>{};
 const legacyAttendanceStore=attendanceStore||firestoreAttendanceStore(db,{collectionName:attendanceCollection});
 const deliverAttendance=async(schoolId,items)=>{
  const state=await mobileState(schoolId),e=state.entitlement;
  if(!state.school||!e||!e.active||e.blocked||state.school.deletedAt) return items.map(i=>({operationId:i.operationId,success:false,authoritative:true}));
  if(e.status!=='trial'){
   if(!state.licence||state.licence.revoked||state.licence.schoolId!==schoolId)return items.map(i=>({operationId:i.operationId,success:false,authoritative:true}));
   e.expiresAt=Number(state.licence.expiresAt?.toMillis?.()??state.licence.expiresAt);
  }
  const m={schoolId,entitlement:e};
  if(!lease(m).allowed||e.status!=='trial'&&!e.activated)return items.map(i=>({operationId:i.operationId,success:false,authoritative:true}));
  const permitted=[],rejected=[];
  for(const item of items){const request=item.payloadTransport==='cloudflare-v1'?cloudflareSync.decryptAttendance(item.payload):JSON.parse(unprotect(item.payload,encryptionKey));
   if(cardReaderEnforced){try{await readCard(schoolId,request);cardReader.verifyCapture({schoolId,request:{...request,attendancePermit:request.originalAttendancePermit},acceptedAt:item.createdAt});}catch(error){
    if([400,401,403,409].includes(error.status)){rejected.push({operationId:item.operationId,success:false,authoritative:true});continue;}throw error;
   }}
   permitted.push({operationId:item.operationId,request:{...request,operationId:item.operationId,submittedAt:item.createdAt}});
  }
  if(!permitted.length)return rejected;
  const result=await signed(m,{action:'managed_attendance_batch',lease:{schoolId,expiresAt:lease(m).expiresAt},operations:permitted});
  if(!Array.isArray(result.acknowledgements))throw Error('Attendance acknowledgement missing');
  if(result.acknowledgements.some(ack=>ack.success===true)){
   invalidate(schoolId);
   // Signed Script receipts have already passed provider verification.
   // FCM and delta hints are optional discovery, not durable queue ACK:
   // a slow push must never retain claimed attendance in processing.
   // Preserve hint-before-push order; hourly delta checks repair gaps.
   void (async()=>{
    await changeHint(schoolId,['attendance_records','attendance_logs','teacher_attendance']);
    await notifyChanged(schoolId,'attendance-ack',false);
   })().catch(()=>{});
  }
  return [...result.acknowledgements,...rejected];
 };
 const queue=createAttendanceQueue({store:legacyAttendanceStore,now,deliver:deliverAttendance});
 const edgeEnabled=school=>cloudflareSync?.enabled(school)===true;
 const edgeQueue=(school,lane)=>createAttendanceQueue({store:cloudflareSync.attendanceStore(school,lane),now,deliver:deliverAttendance});
 const attendanceRow=async(school,id)=>{if(edgeEnabled(school)){const value=await cloudflareSync.attendanceStore(school).get(id);if(value)return {exists:true,data:()=>value};}return db.doc(attendanceCollection+'/'+id).get();};
 const noticeBaseline=school=>signedRequest({schoolId:school},{action:'managed_records',collection:'school_notices',operation:'read',syncProtocol:2});
 const pushDevices=new Map();
 async function registerDevice(schoolId,request,verified) {
  if(!messaging || request.action!=='mobile_refresh' || request.fcmToken===undefined)return;
  if(typeof request.fcmToken!=='string'||request.fcmToken.length<20||request.fcmToken.length>4096||
     typeof request.deviceId!=='string'||request.deviceId.length<32||request.deviceId.length>160)fail(400,'Invalid notification device');
  if(typeof verified.personId!=='string'||!verified.personId.length||verified.personId.length>200||!['student','teacher'].includes(verified.role))fail(502,'Verified notification identity missing');
  const ref=db.doc('managed_notification_devices/'+hash(request.fcmToken)),deviceHash=hash(request.deviceId);
  await db.runTransaction(async tx=>{const old=await tx.get(ref);
   if(old.exists&&old.data().deviceHash!==deviceHash)fail(403,'Notification device binding rejected');
   tx.set(ref,{schoolId,personId:verified.personId,role:verified.role,deviceHash,token:protect(request.fcmToken,encryptionKey),expiresAt:now()+30*86400000});
   if(old.exists)pushDevices.delete(old.data().schoolId);
  });
  pushDevices.delete(schoolId);
 }
 const pendingHints=new Map();
 function notifyChanged(schoolId,operationId,notice,owner) {
  if(!messaging)return Promise.resolve();
  const key=JSON.stringify([schoolId,notice?'notice':'sync',owner?.role||'',owner?.personId||'']);
  const previous=pendingHints.get(key);
  if(previous){previous.operationId=operationId;return previous.promise;}
  const item={operationId};
  item.promise=new Promise((resolve,reject)=>scheduleHint(()=>{
   pendingHints.delete(key);
   sendChangedHint(schoolId,item.operationId,notice,owner).then(resolve,reject);
  }));
  pendingHints.set(key,item);
  return item.promise;
 }
 async function sendChangedHint(schoolId,operationId,notice,owner) {
  if(!messaging)return;
  const rows=await cachedRead(pushDevices,schoolId,()=>db.collection('managed_notification_devices').where('schoolId','==',schoolId).get());
  const tokens=[...new Set(rows.docs.filter(d=>d.data().schoolId===schoolId&&d.data().expiresAt>now()&&(!owner||(d.data().personId===owner.personId&&d.data().role===owner.role))).map(d=>unprotect(d.data().token,encryptionKey)))];
  for(let offset=0;offset<tokens.length;offset+=500)
   {
    const sent=await messaging.sendEachForMulticast({tokens:tokens.slice(offset,offset+500),data:{schoolId,type:notice?'school_notice':'school_sync',operationId,...(notice?{noticeId:operationId}:{})},android:{priority:'high'}});
    if(sent?.failureCount>0)try{pushDiagnostics({event:'managed_push_hint_failure',code:'FCM_PARTIAL_FAILURE',count:sent.failureCount});}catch{}
   }
 }
 // Bounded immutable-version media lane. Metadata/record requests never wait
 // behind these full provider reads. Cached bytes are private to school+version.
 const binaryParts=new Map(),binaryFlights=new Map();let binaryCacheBytes=0;
 async function binaryBytes(m,b){
  const result=await signed(m,{action:'managed_binary_download',fileId:b.fileId,expectedSha256:b.expectedSha256,expectedVersion:b.expectedVersion});
  if(result.binaryDownloadVersion!==1||result.fileId!==b.fileId||result.sha256!==b.expectedSha256||result.version!==b.expectedVersion||typeof result.base64!=='string'||result.base64.length>28*1024*1024||!Number.isSafeInteger(result.sizeBytes)||result.sizeBytes<1||result.sizeBytes>20*1024*1024)fail(502,'Unverified binary download','BINARY_DOWNLOAD_UNVERIFIED');
  const bytes=Buffer.from(result.base64,'base64');
  if(bytes.length!==result.sizeBytes||createHash('sha256').update(bytes).digest('hex')!==b.expectedSha256)fail(502,'Binary content verification failed','BINARY_DOWNLOAD_UNVERIFIED');
  return {bytes,fileId:b.fileId,sha256:b.expectedSha256,version:b.expectedVersion,sizeBytes:bytes.length};
 }
 async function rangedBinary(m,b){
  const key=hash(JSON.stringify([m.schoolId,b.fileId,b.expectedSha256,b.expectedVersion]));
  for(const [id,item] of binaryParts)if(item.expiresAt<=now()){binaryCacheBytes-=item.bytes.length;binaryParts.delete(id);}
  if(binaryParts.has(key))return binaryParts.get(key);
  if(binaryFlights.has(key))return binaryFlights.get(key);
  if(binaryFlights.size>=2)fail(503,'Media lane busy; retained transfer may retry','MEDIA_BACKPRESSURE');
  const promise=(async()=>{
   const item=await binaryBytes(m,b);
   while(binaryCacheBytes+item.bytes.length>24*1024*1024&&binaryParts.size){const id=binaryParts.keys().next().value;binaryCacheBytes-=binaryParts.get(id).bytes.length;binaryParts.delete(id);}
   const cached={...item,expiresAt:now()+120000};binaryParts.set(key,cached);binaryCacheBytes+=item.bytes.length;return cached;
  })();binaryFlights.set(key,promise);
  try{return await promise;}finally{if(binaryFlights.get(key)===promise)binaryFlights.delete(key);}
 }
 const pairingTickets=new Map();
 function presence(m,access){
  if(!access.allowed||access.status!=='trial'&&!access.activated)return undefined;
  if(!/^[a-f0-9]{64}$/i.test(encryptionKey||''))return undefined;
  const value=Buffer.from(JSON.stringify({purpose:'windows-presence',schoolId:m.schoolId,uid:m.uid,expiresAt:Math.min(access.expiresAt,now()+900000)})).toString('base64url');
  return value+'.'+createHmac('sha256',encryptionKey).update(value).digest('hex');
 }
 function verifiedPresence(value){
  if(typeof value!=='string'||value.length>1000||!encryptionKey)fail(401,'School presence verification required');
  const parts=value.split('.');
  if(parts.length!==2||!/^[a-f0-9]{64}$/.test(parts[1]))fail(401,'School presence verification required');
  const expected=createHmac('sha256',encryptionKey).update(parts[0]).digest();
  if(!timingSafeEqual(expected,Buffer.from(parts[1],'hex')))fail(401,'School presence verification required');
  let data;try{data=JSON.parse(Buffer.from(parts[0],'base64url').toString());}catch{fail(401,'School presence verification required');}
  if(data.purpose!=='windows-presence'||!SCHOOL.test(data.schoolId)||typeof data.uid!=='string'||data.expiresAt<=now()||data.expiresAt>now()+900000)fail(401,'School presence verification required');
  return data;
 }
 async function user(req){const token=String(req.headers.authorization||'').match(/^Bearer (.+)$/)?.[1];if(!token)fail(401,'School login required');try{return await auth.verifyIdToken(token,true);}catch{fail(401,'Login expired or disabled');}}
 async function developer(req){const u=await user(req),m=await db.doc('school_memberships/'+u.uid).get();if(m.exists||!(u.developer===true||(u.admin===true&&!u.schoolId)))fail(403,'Developer access required');return u;}
 async function identity(req,expected){const u=await user(req),m=await db.doc('school_memberships/'+u.uid).get();if(!m.exists||m.data().managed!==true||m.data().active!==true||m.data().role!=='school_admin')fail(403,'Managed school login is inactive');const id=m.data().schoolId;if(!SCHOOL.test(id)||expected&&expected!==id)fail(403,'Another school is not accessible');const e=await db.doc('school_entitlements/'+id).get();if(!e.exists||e.data().active!==true||e.data().blocked===true)fail(403,'School is blocked or disabled');if(Number(e.data().sessionValidAfter||0)>Number(u.auth_time||0))fail(401,'Sign in again');const entitlement={...e.data()};
 if(entitlement.status!=='trial'&&entitlement.licenseHash){const licence=await db.doc('platform_license_status/'+entitlement.licenseHash).get();if(!licence.exists||licence.data().schoolId!==id||licence.data().revoked!==false){entitlement.expiresAt=0;}else{const end=licence.data().expiresAt;entitlement.expiresAt=typeof end?.toMillis==='function'?end.toMillis():Number(end||0);}}
 return {uid:u.uid,schoolId:id,entitlement,authenticatedAt:Number(u.auth_time)*1000};}
 function lease(m){const e=m.entitlement,t=now(),paid=e.status!=='trial',end=Number(e.expiresAt||0);return {success:true,managed:true,schoolId:m.schoolId,uid:m.uid,projectId,serverTime:t,activated:e.activated===true,expiresAt:end,allowed:e.startsAt<=t&&end>t,status:e.startsAt>t?'pending':end>t?(paid?'licensed':'trial'):'expired'};}
 // Context is attached only after identity/entitlement verification, never from
 // an unauthenticated request's schoolId or arbitrary Script response.
 const syncEvidenceWrites=new Map();
 async function saveSyncEvidence(schoolId,evidence){
  const signature=JSON.stringify([evidence.outcome,evidence.stage,evidence.protocol??null,evidence.code??null]);
  const prior=syncEvidenceWrites.get(schoolId);if(prior&&prior.signature===signature&&now()-prior.at<60000)return;
  // Monitoring is best-effort; its failure never reverses a verified storage ACK.
  try{
   await db.doc('platform_schools/'+schoolId).update({syncServerEvidence:{version:1,observedAt:now(),...evidence}});
   if(syncEvidenceWrites.size>=1000)syncEvidenceWrites.delete(syncEvidenceWrites.keys().next().value);
   syncEvidenceWrites.set(schoolId,{at:now(),signature});
  }catch(_){}
 }
 async function deliveryBudget(work,millis=1000){let timer;try{return await Promise.race([work,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Object.assign(Error('Notification recovery storage unavailable; retry'),{status:503,code:'SYNC_DELIVERY_BUSY',publicMessage:true})),millis);})]);}finally{clearTimeout(timer);}}
 async function signed(m,body){
  if(edgeEnabled(m.schoolId)&&body.action==='managed_records'&&body.collection==='school_notices'&&body.operation!=='read'&&(body.syncProtocol!==2||!['write','delete'].includes(body.operation)))fail(409,'Cloudflare notice writes require versioned sync','SYNC_PROTOCOL_REQUIRED');
  if(edgeEnabled(m.schoolId)&&body.action==='managed_records'&&body.collection==='school_notices'&&body.syncProtocol===2&&['read','write','delete'].includes(body.operation)){
   if(body.operation!=='read'){const ack=await cloudflareSync.writeNotice(m.schoolId,body,()=>noticeBaseline(m.schoolId));invalidate(m.schoolId);await changeHint(m.schoolId,'school_notices',body.id);return ack;}
   const state=await cloudflareSync.notices(m.schoolId,()=>noticeBaseline(m.schoolId));const records=body.id?{...(state.records[body.id]?{[body.id]:state.records[body.id]}:{})}:state.records;return {success:true,schoolId:m.schoolId,syncProtocol:2,collectionRevision:state.revision,records:body.knownRevision===state.revision?{}:records,...(body.id?{pointRead:true}:{}),...(body.knownRevision===state.revision?{unchanged:true}:{}),cloudflareAccepted:true};
  }
  const ticket=await deliveryBudget(syncDelivery.prepare(m.schoolId,body));
  try{const result=await signedRequest(m,body);
   if(['managed_records','managed_delta','managed_mobile'].includes(body.action)){
    const ack=body.action==='managed_records'&&body.operation!=='read'&&result.syncProtocol===2&&typeof result.recordRevision==='string'&&result.recordRevision.length>0;
    await saveSyncEvidence(m.schoolId,{outcome:ack?'durable_ack':'verified_response',stage:body.action,protocol:result.syncProtocol===2?2:1});
   }
   if(body.action==='managed_records'&&body.operation!=='read'&&result.syncProtocol===2&&typeof result.recordRevision==='string'&&result.recordRevision){invalidate(m.schoolId);if(ticket){await deliveryBudget(syncDelivery.committed(ticket,result.recordRevision)).catch(()=>{});}else await changeHint(m.schoolId,body.collection,body.id);}
   if(!ticket&&body.action==='managed_records'&&body.collection==='students_directory'&&body.operation==='delete'&&result.syncProtocol===2&&typeof result.recordRevision==='string'&&result.recordRevision)await changeHint(m.schoolId,[...COLLECTIONS].filter(c=>c!=='backups'&&c!=='students_directory'));
   if(body.action==='managed_recycle'&&body.operation==='restore')await changeHint(m.schoolId,[...COLLECTIONS].filter(c=>c!=='backups'));
   return result;
  }catch(error){
   if(ticket && error.code==='RECORD_REVISION_CONFLICT')await syncDelivery.rejected(ticket).catch(()=>{});
   if(['managed_records','managed_delta','managed_mobile'].includes(body.action))await saveSyncEvidence(m.schoolId,{outcome:'failed',stage:body.action,code:
     ['RECORD_REVISION_CONFLICT','OPERATION_ID_CONFLICT','SCRIPT_TIMEOUT','SCRIPT_PERMISSION_DENIED','SCRIPT_QUOTA_EXCEEDED','SCRIPT_HTTP_ERROR','SCRIPT_IDENTITY_MISMATCH','SCRIPT_TRANSPORT_ERROR','SCRIPT_RESPONSE_READ_FAILED','SCRIPT_OPERATION_FAILED'].includes(error.code)?error.code:'SCRIPT_UNVERIFIED'});
   if((error.status===409&&['RECORD_REVISION_CONFLICT','OPERATION_ID_CONFLICT','SCHOOL_STORAGE_NOT_CONNECTED'].includes(error.code))||([503,504].includes(error.status)&&['SCRIPT_TRANSPORT_ERROR','SCRIPT_RESPONSE_READ_FAILED','SCRIPT_TIMEOUT'].includes(error.code))){
    error.syncDiagnostic={schoolId:m.schoolId,syncProtocol:body.syncProtocol===2?2:1,
     ...(typeof body.operationId==='string'&&/^[A-Za-z0-9_-]{16,100}$/.test(body.operationId)?{operationId:body.operationId}:{}),
     ...(error.scriptTransport?{scriptStage:error.scriptTransport.stage,transportKind:error.scriptTransport.kind}:{})};
   }
   throw error;
  }
 }
 // Classify only the network/stream boundary, never arbitrary application or
 // authentication errors. No request is retried here: the durable client keeps
 // its operation ID and revision protection after an uncertain response.
 function scriptTransportFailure(error,stage) {
  const timeout=['AbortError','TimeoutError'].includes(error?.name);
  const cause=error?.cause?.code;
  const kind=timeout?'timeout':['ECONNRESET','EPIPE','UND_ERR_SOCKET'].includes(cause)?'socket':
   ['ENOTFOUND','EAI_AGAIN'].includes(cause)?'dns':
   ['ECONNREFUSED','UND_ERR_CONNECT_TIMEOUT'].includes(cause)?'connection':'other';
  const e=new Error('School script transport did not complete. Pending data is retained; retry the same operation.');
  Object.assign(e,{status:timeout?504:503,code:timeout?'SCRIPT_TIMEOUT':stage==='response'?'SCRIPT_RESPONSE_READ_FAILED':'SCRIPT_TRANSPORT_ERROR',publicMessage:true,
   scriptTransport:{stage,kind}});throw e;
 }
 async function fetchScript(url,options,stage='request') {
  try{return await fetchImpl(url,options);}catch(error){scriptTransportFailure(error,stage);}
 }
 async function readScript(response) {
  try{return await response.text();}catch(error){scriptTransportFailure(error,'response');}
 }
 async function signedRequest(m,body){const started=performance.now();const s=await cachedRead(storageStates,m.schoolId,()=>db.doc('school_storage_private/'+m.schoolId).get());if(!s.exists||s.data().ready!==true)fail(409,'Developer must connect this school Apps Script first','SCHOOL_STORAGE_NOT_CONNECTED');const c=s.data(),payload=JSON.stringify(body),timestamp=now(),nonce=randomBytes(24).toString('hex'),signature=createHmac('sha256',unprotect(c.secret,encryptionKey)).update(m.schoolId+'\n'+timestamp+'\n'+nonce+'\n'+payload).digest('hex');let url=scriptUrl(c.url);const scriptStarted=performance.now(),scriptSignal=AbortSignal.timeout(90000);let response=await fetchScript(url,{method:'POST',redirect:'manual',headers:{'Content-Type':'application/json'},body:JSON.stringify({schoolId:m.schoolId,timestamp,nonce,payload,signature}),signal:scriptSignal});const redirects=new Set([301,302,303,307,308]),seen=new Set();let hops=0;while(redirects.has(response.status)){if(hops++>=5)fail(502,'School script redirect limit exceeded','SCRIPT_REDIRECT_LIMIT');let target;try{const location=response.headers.get('location');if(!location)throw Error();target=new URL(location,url);}catch{fail(502,'School script redirect rejected','SCRIPT_REDIRECT_REJECTED');}if(target.protocol!=='https:'||target.hostname!=='script.googleusercontent.com'||target.username||target.password||target.port)fail(502,'School script redirect rejected','SCRIPT_REDIRECT_REJECTED');if(seen.has(target.href))fail(502,'School script redirect limit exceeded','SCRIPT_REDIRECT_LIMIT');seen.add(target.href);url=target.href;response=await fetchScript(url,{method:'GET',redirect:'manual',signal:scriptSignal},'redirect');}if(!response.ok)fail(502,'School script request failed','SCRIPT_HTTP_ERROR');const raw=await readScript(response);if(raw.length>30*1024*1024)fail(502,'School script response is too large');let out;try{out=JSON.parse(raw);}catch{fail(502,'School script returned invalid JSON','SCRIPT_INVALID_RESPONSE');}if(out.schoolId!==m.schoolId)fail(502,'School script identity or operation failed','SCRIPT_IDENTITY_MISMATCH');if(out.success!==true){if(!out.code&&typeof out.message==='string'){if(/quota|too many times|limit exceeded/i.test(out.message))out.code='SCRIPT_QUOTA_EXCEEDED';else if(/lock|timed out|timeout/i.test(out.message))out.code='SCRIPT_TIMEOUT';}if(out.code==='SCRIPT_QUOTA_EXCEEDED')fail(429,'Google school storage quota is temporarily exceeded; pending changes are retained','SCRIPT_QUOTA_EXCEEDED');if(out.code==='SCRIPT_TIMEOUT')fail(504,'School storage is busy; retry Sync. Existing data and pending changes are retained','SCRIPT_TIMEOUT');if(['SCRIPT_SHEET_RECOVERY_REQUIRED','SCRIPT_STUDENT_PARENT_PENDING'].includes(out.code))fail(503,'Verified local Sheet recovery required before editing',out.code);if(out.code==='SCRIPT_EXTERNAL_EDIT_REVIEW_REQUIRED')fail(409,'External Sheet edit requires review',out.code);if(['SCRIPT_RECOVERY_MISMATCH','SCRIPT_STUDENT_GENERATION_DELETED','SCRIPT_SYNC_STATE_IDENTITY','SCRIPT_SYNC_STATE_UNAVAILABLE'].includes(out.code))fail(409,'School record recovery needs review',out.code);if(['SCRIPT_BLANK_SCHOOL_PROFILE','SCRIPT_EMPTY_PROFILE_OVERWRITE','SCRIPT_INVALID_SYNC_OPERATION'].includes(out.code))fail(422,'School record validation failed; original retained',out.code);if(out.code==='SCRIPT_DOCUMENT_REVISION_CONFLICT'||out.message==='Newer cloud document retained; resolve version conflict')fail(409,'Document version conflict; both copies retained','SCRIPT_DOCUMENT_REVISION_CONFLICT');if(out.message==='Student class/section/roll conflict')fail(409,'Student class/section/roll conflict','STUDENT_SLOT_CONFLICT');if(out.message==='Record revision conflict')fail(409,'Record revision conflict','RECORD_REVISION_CONFLICT');if(out.message==='Sync operation ID conflict')fail(409,'Sync operation ID conflict','OPERATION_ID_CONFLICT');if(body.action==='managed_mobile'&&out.message==='Student attendance is outside the school schedule')fail(400,out.message,'ATTENDANCE_SCHEDULE_CLOSED');const safe=['This QR is invalid or has not synced to this school. Ask the school to sync or regenerate the ID card.','Ask your school to regenerate this ID card.','Class, roll number or date of birth is incorrect','School session expired. Scan your ID again.','School session expired','School login required','School identity mismatch','This QR does not belong to the active school','School record or ID card was changed; scan again'];if(body.action==='managed_mobile'&&safe.includes(out.message))fail(403,out.message);const codes={'School data organization in progress; retry Sync. Pending data retained':'SCRIPT_MIGRATION_PENDING','Migration conflict; both versions retained':'SCRIPT_MIGRATION_CONFLICT','Verified school tab is missing; operator recovery required':'SCRIPT_MISSING_MIGRATED_TAB','School record verification failed':'SCRIPT_RECORD_VERIFY_FAILED','Managed storage not prepared':'SCRIPT_STORAGE_NOT_PREPARED'};fail(502,'School script identity or operation failed',codes[out.message]||(['SCRIPT_ROOT_IDENTITY_MISMATCH','SCRIPT_WORKBOOK_IDENTITY_MISMATCH','SCRIPT_WORKBOOK_REVIEW_REQUIRED','SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED','SCRIPT_FOREIGN_RECORD_REJECTED','SCRIPT_INVALID_SYNC_OPERATION','SCRIPT_DOCUMENT_REVISION_REQUIRED','SCRIPT_DOCUMENT_REVISION_CONFLICT','SCRIPT_MIGRATION_CONFLICT','SCRIPT_MISSING_MIGRATED_TAB','SCRIPT_RECORD_VERIFY_FAILED','SCRIPT_STORAGE_NOT_PREPARED','SCRIPT_MIGRATION_PENDING','SCRIPT_PERMISSION_DENIED','SCRIPT_QUOTA_EXCEEDED','SCRIPT_TIMEOUT','SCRIPT_TYPE_ERROR','SCRIPT_PARSE_ERROR'].includes(out.code)?out.code:'SCRIPT_OPERATION_FAILED'));}return {...out,syncTiming:{brokerPreparationMillis:Math.round(scriptStarted-started),scriptRoundTripMillis:Math.round(performance.now()-scriptStarted)}};}
 async function scriptRequest(url,body){
  let response=await fetchImpl(url,{method:'POST',redirect:'manual',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(30000)});
  if([301,302,303].includes(response.status)){const target=new URL(response.headers.get('location'));if(target.protocol!=='https:'||target.hostname!=='script.googleusercontent.com'||target.username||target.password)fail(502,'Unexpected script redirect');response=await fetchImpl(target.href,{redirect:'error',signal:AbortSignal.timeout(30000)});}
  if(!response.ok)fail(502,'School script is unavailable');
  const raw=await response.text();if(raw.length>8192)fail(502,'Invalid school script connection response');
  try{return JSON.parse(raw);}catch{fail(502,'Update this school managed Apps Script deployment before connecting');}
 }
 const handler=async req=>{
 const b=req.body||{},action=b.action;if(req.method!=='POST')fail(405,'Use POST');
 if(action==='managed/cloudflare/drain'){
  if(!edgeEnabled(b.schoolId)||!cloudflareSync.verify(b,req.headers||{})||! /^(?:attendance-[a-f0-9]{2}|notices)$/.test(b.lane||''))fail(403,'Cloudflare delivery authorization required');
  let result;
  if(b.lane==='notices'){
   const state=await mobileState(b.schoolId),e={...state.entitlement};
   if(!state.school||!e.active||e.blocked||state.school.deletedAt)fail(403,'School is inactive');
   if(e.status!=='trial'){if(!state.licence||state.licence.revoked||state.licence.schoolId!==b.schoolId)fail(403,'School licence inactive');e.expiresAt=Number(state.licence.expiresAt?.toMillis?.()??state.licence.expiresAt);}
   const m={schoolId:b.schoolId,entitlement:e};if(!lease(m).allowed||e.status!=='trial'&&!e.activated)fail(403,'School licence inactive');
   result=await cloudflareSync.drainNotices(b.schoolId,body=>signedRequest(m,body));
  }else result=await edgeQueue(b.schoolId,b.lane).drain();
  return {success:true,schoolId:b.schoolId,...result};
 }

 // This capability authorizes ONLY a bounded presence write, never school data.
 // Membership/licence revocation is rechecked when the 15-minute lease renews.
 if(action==='managed/presence' && !deviceAccessEnforced && !deviceManagementEnabled){
  const p=verifiedPresence(b.presenceToken);if(b.schoolId&&b.schoolId!==p.schoolId)fail(403,'Another school is not accessible');
  if(deviceEnrollmentEnabled) scheduleHint(()=>deviceAccess.observePresence(req,p).catch(()=>{}));
  await db.doc('platform_schools/'+p.schoolId).set({lastSeenAt:now()},{merge:true});
  return {success:true,schoolId:p.schoolId};
 }
 // A server-generated, short-lived capability; Firebase tokens never reach GS.
 if(action==='managed/storage/authorize'){
  const ticket=pairingTickets.get(hash(String(b.ticket||'')));
  if(!ticket||ticket.used||ticket.expiresAt<=now()||ticket.schoolId!==b.schoolId)fail(403,'Invalid school storage connection ticket');
  const m=await identity(ticket.req,ticket.schoolId);
  await deviceAccess.authorize({req:ticket.req,body:{action:'managed/storage/authorize',schoolId:ticket.schoolId},identity:m,entitlement:lease(m)});
  if(!lease(m).allowed||m.entitlement.status!=='trial'&&m.entitlement.activated!==true)fail(403,'School licence is inactive');
  ticket.used=true;return {success:true,schoolId:m.schoolId};
 }
 if(action?.startsWith('developer/managed/')){
  const admin=await developer(req),id=b.schoolId;if(action==='developer/managed/theme/get')return {success:true,theme:await windowsTheme.read()};if(action==='developer/managed/theme/save')return {success:true,theme:await windowsTheme.save(b.theme,admin.uid)};if(action==='developer/managed/create'){
   const email=String(b.email||'').trim().toLowerCase(),name=String(b.schoolName||'').trim();if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)||name.length<2||name.length>160)fail(400,'School name and valid login email required');
   const password=b.password;
   if(password!==undefined&&(typeof password!=='string'||password.length<12||password.length>128))fail(400,'Use an initial password of 12–128 characters');
   const schoolId='vs-'+randomUUID().replaceAll('-','');let account,reused=false;
   try{account=await auth.createUser({email,password:password??randomBytes(32).toString('base64url'),disabled:false});}
   catch(e){
    if(e.code!=='auth/email-already-exists'||b.linkExistingGoogle!==true)throw e;
    if(password===undefined)fail(400,'Enter the new school password before linking this Google login');
    account=await auth.getUserByEmail(email);const claims=account.customClaims||{};
    if(account.disabled||account.uid===admin.uid||Object.keys(claims).length>0)fail(409,'Existing account has protected access or is disabled; it cannot be converted');
    if(!account.providerData?.some(p=>p.providerId==='google.com'))fail(409,'Only an unassigned Google login can be linked; other existing accounts require account recovery');
    const membership=await db.doc('school_memberships/'+account.uid).get(),profile=await db.doc('users/'+account.uid).get();
    if(membership.exists||profile.exists&&(profile.data().role||profile.data().schoolId||profile.data().admin||profile.data().developer))fail(409,'Existing account is already assigned; account and school data are retained');
    const owned=await db.collection('schools').where('ownerUid','==',account.uid).limit(1).get();
    if(!owned.empty)fail(409,'Existing account owns school data; migration must be reviewed before linking');
    await auth.updateUser(account.uid,{password});await auth.revokeRefreshTokens(account.uid);reused=true;
   }
   try{const t=now(),batch=db.batch();batch.create(db.doc('school_memberships/'+account.uid),{schoolId,managed:true,role:'school_admin',active:true});batch.create(db.doc('schools/'+schoolId),{schoolId,ownerUid:account.uid,schoolName:name,architecture:'managed-v1'});batch.create(db.doc('platform_schools/'+schoolId),{schoolId,name,loginEmail:email,authUid:account.uid,managed:true,registrationState:'new',createdAt:t,trialStartedAt:t,blocked:false});batch.create(db.doc('school_entitlements/'+schoolId),{active:true,blocked:false,status:'trial',startsAt:t,expiresAt:t+5*86400000});await batch.commit();}catch(e){if(!reused)await auth.deleteUser(account.uid);throw e;}
   await db.collection('platform_audit').add({action,schoolId,actor:admin.uid,at:now()});return {success:true,schoolId,email,...(password===undefined?{passwordSetupLink:await auth.generatePasswordResetLink(email)}:{})};
  }
  if(action==='developer/managed/monitor'){const started=now();const metrics=await monitor();return {success:true,projectId,responseMs:now()-started,measuredAt:now(),metrics};}
  if(!SCHOOL.test(id||''))fail(400,'Invalid school ID');if(!['developer/managed/exams','developer/managed/view','developer/managed/sync/status'].includes(action))invalidate(id);const school=await cachedRead(developerViews,id,()=>db.doc('platform_schools/'+id).get());if(!school.exists||school.data().managed!==true)fail(404,'Managed school not found');const data=school.data(),ref=db.doc('school_entitlements/'+id);
  if(action==='developer/managed/sync/status')return {success:true,schoolId:id,serverEvidence:data.syncServerEvidence||null,latestWindowsReport:data.syncWindowsReport||null,measuredAt:now()};
  if(action==='developer/managed/view'){
   const known=b.knownRevisions||{};if(!known||typeof known!=='object'||Array.isArray(known)||JSON.stringify(known).length>16000)fail(400,'Invalid school view checkpoint');
   const body={action:'managed_view',knownRevisions:known};
   const out=await readView(id,body,()=>signed({schoolId:id},body));
   if(!out.groups||typeof out.groups!=='object'||!out.revisions||typeof out.revisions!=='object')fail(502,'Invalid school view response');
   const allowed=new Set(['exams','examResults','fee_settings','fee_ledger','fee_payments','school_notices','school_config','school_settings']);
   for(const [key,group]of Object.entries(out.groups))if(!allowed.has(key)||!group||!Array.isArray(group.rows)||group.rows.length>100||!Number.isSafeInteger(group.count)||group.count<group.rows.length||group.rows.some(row=>!row||row.schoolId!==id))fail(502,'School view identity mismatch');
   for(const [key,value]of Object.entries(out.revisions))if(!allowed.has(key)||typeof value!=='string'||value.length>1000)fail(502,'Invalid school view revision');
   return {success:true,schoolId:id,groups:out.groups,revisions:out.revisions,previewLimit:100,verifiedAt:now()};
  }
  if(action==='developer/managed/exams'){
   const groups={};
   for(const collection of ['exams','exam_center_results','exam_results']){
    const out=await signed({schoolId:id},{action:'managed_records',operation:'read',collection,syncProtocol:2});
    if(!out.records||typeof out.records!=='object'||Array.isArray(out.records))fail(502,'Invalid school exam response');
    for(const record of Object.values(out.records))if(!record||record.schoolId!==id)fail(502,'School exam identity mismatch');
    groups[collection]=out.records;
   }
   const removed=new Set(),results={};
   for(const collection of ['exam_center_results','exam_results'])for(const [key,row]of Object.entries(groups[collection])){
    if(row._syncDeleted||row.deleted)removed.add(key);
    else if(!results[key]||Number(row.timestamp||row.updatedAt||0)>=Number(results[key].timestamp||results[key].updatedAt||0))results[key]={...row,id:key};
   }
   return {success:true,schoolId:id,exams:Object.entries(groups.exams).filter(([,row])=>!row._syncDeleted&&!row.deleted).map(([key,row])=>({...row,id:key})),results:Object.entries(results).filter(([key])=>!removed.has(key)).map(([,row])=>row),verifiedAt:now()};
  }
  if(action==='developer/managed/password/change'){
   if(data.deletedAt||data.loginDisabled===true)fail(409,'Enable the school login before changing its password');
   if(typeof b.password!=='string'||b.password.length<12||b.password.length>128)fail(400,'Use a password of 12–128 characters');
   if(typeof data.authUid!=='string'||!data.authUid||data.authUid===admin.uid)fail(409,'School account mapping is invalid');
   const membership=await db.doc('school_memberships/'+data.authUid).get();
   if(!membership.exists||membership.data().managed!==true||membership.data().role!=='school_admin'||membership.data().schoolId!==id)fail(409,'School account mapping is invalid');
   // Update the SAME Firebase UID. Never recreate an account or touch school data.
   await auth.updateUser(data.authUid,{password:b.password});
   await auth.revokeRefreshTokens(data.authUid);
   await ref.set({sessionValidAfter:Math.floor(now()/1000)},{merge:true});
   await db.collection('platform_audit').add({action,schoolId:id,actor:admin.uid,at:now()});
   return {success:true,schoolId:id,passwordChanged:true};
  }
  if(action==='developer/managed/reset')return {success:true,passwordSetupLink:await auth.generatePasswordResetLink(data.loginEmail)};
  if(action==='developer/managed/delete'){
   // Archive the account, never delete its Drive, local or operational data.
   await ref.set({active:false,blocked:true,sessionValidAfter:Math.floor(now()/1000)},{merge:true});
   await auth.updateUser(data.authUid,{disabled:true});await auth.revokeRefreshTokens(data.authUid);
   await db.doc('school_memberships/'+data.authUid).set({active:false},{merge:true});
   await db.doc('platform_schools/'+id).set({deletedAt:now(),blocked:true,loginDisabled:true},{merge:true});
  }else if(action==='developer/managed/block'||action==='developer/managed/disable'){
   const blocked=b.blocked===true;await ref.set({...(action.endsWith('/block')?{blocked}:{active:!blocked}),sessionValidAfter:Math.floor(now()/1000)},{merge:true});
   if(action.endsWith('/disable'))await auth.updateUser(data.authUid,{disabled:blocked});await auth.revokeRefreshTokens(data.authUid);await db.doc('platform_schools/'+id).set(action.endsWith('/disable')?{loginDisabled:blocked}:{blocked},{merge:true});
  }else if(action==='developer/managed/licence'){
   if(!Number.isInteger(b.days)||b.days<1||b.days>3650)fail(400,'Licence duration must be 1–3650 days');const t=now(),startsAt=b.startsAt===undefined?t:Number(b.startsAt);if(!Number.isSafeInteger(startsAt)||startsAt<0)fail(400,'Invalid licence start date');const key='VS-'+randomBytes(16).toString('hex').toUpperCase(),licenseHash=hash(key),expiresAt=startsAt+b.days*86400000;
   const batch=db.batch();batch.set(db.doc('platform_licenses/'+licenseHash),{schoolId:id,issuedAt:t,expiresAt,startsAt,revoked:false,paid:b.paid===true,keyHint:key.slice(-6),issuedBy:admin.uid});batch.set(db.doc('platform_license_status/'+licenseHash),{schoolId:id,expiresAt,revoked:false});batch.set(ref,{status:b.paid===true?'paid':'licensed',startsAt,expiresAt,licenseHash,activated:false},{merge:true});batch.set(db.doc('platform_schools/'+id),{activeLicenseHash:licenseHash,licenseId:licenseHash,licenseExpiresAt:expiresAt,purchased:b.paid===true},{merge:true});await batch.commit();return {success:true,key,expiresAt};
  }else if((action==='developer/managed/revoke'||action==='developer/managed/delete-licence')){
   const e=(await ref.get()).data();await ref.set({expiresAt:0,activated:false},{merge:true});if(e.licenseHash){await db.doc('platform_license_status/'+e.licenseHash).set({schoolId:id,expiresAt:0,revoked:true});await db.doc('platform_licenses/'+e.licenseHash).set({revoked:true},{merge:true});}await db.doc('platform_schools/'+id).set({licenseExpiresAt:0},{merge:true});if(action.endsWith('/delete-licence')&&e.licenseHash)await db.doc('platform_licenses/'+e.licenseHash).delete();
  }else if(action==='developer/managed/storage'){
   const url=scriptUrl(b.scriptUrl);if(!/^[a-f0-9]{64}$/.test(b.secret||''))fail(400,'Copy the connection secret produced by school Script setup');const secret=protect(b.secret,encryptionKey);
   const old=await db.doc('school_storage_private/'+id).get();const staged={url,secret,ready:true};
   const timestamp=now(),nonce=randomBytes(24).toString('hex'),payload=JSON.stringify({action:'managed_health'}),signature=createHmac('sha256',b.secret).update(id+'\n'+timestamp+'\n'+nonce+'\n'+payload).digest('hex');
   let r=await fetchImpl(url,{method:'POST',redirect:'manual',headers:{'Content-Type':'application/json'},body:JSON.stringify({schoolId:id,timestamp,nonce,payload,signature}),signal:AbortSignal.timeout(30000)});if([301,302,303].includes(r.status)){const u=new URL(r.headers.get('location'));if(u.protocol!=='https:'||u.hostname!=='script.googleusercontent.com'||u.username||u.password)fail(502,'Unexpected script redirect');r=await fetchImpl(u.href,{redirect:'error',signal:AbortSignal.timeout(30000)});}if(!r.ok)fail(502,'School script is unavailable');const result=await r.json();if(result.schoolId!==id||result.success!==true||result.storageReady!==true)fail(409,'Script is not prepared for this school');if(old.exists&&old.data().url!==url&&b.replace!==true)fail(409,'Existing storage retained. Explicit replacement required');
   await db.doc('school_storage_private/'+id).set(staged);await db.doc('platform_schools/'+id).set({storageReady:true,storageCheckedAt:now()},{merge:true});
  }else fail(400,'Unknown developer operation');
  await db.collection('platform_audit').add({action,schoolId:id,actor:admin.uid,at:now()});invalidate(id);return {success:true};
 }
 if(action==='managed/mobile'){
  if(!SCHOOL.test(b.schoolId||''))fail(400,'Invalid school ID');
  const state=await mobileState(b.schoolId),school=state.school,entitlement=state.entitlement;
  if(!school||school.managed!==true||school.deletedAt||!entitlement||!entitlement.active||entitlement.blocked)fail(403,'Unable to connect: school is unavailable');
  const e={...entitlement};
  if(e.status!=='trial'){const licence=state.licence;if(!licence||licence.revoked!==false||licence.schoolId!==b.schoolId)fail(403,'Unable to connect: school licence is inactive');const end=licence.expiresAt;e.expiresAt=typeof end?.toMillis==='function'?end.toMillis():Number(end||0);}
  const m={schoolId:b.schoolId,entitlement:e};
  if(!lease(m).allowed||e.status!=='trial'&&e.activated!==true)fail(403,'Unable to connect: school trial or licence has ended');
  // Windows presence is monitoring only. Signed school storage and current licence
  // authorize mobile access independently of the management PC's availability.
  if(!b.request||typeof b.request!=='object'||JSON.stringify(b.request).length>(b.request.action==='mobile_dashboard'?220000:16000)||!['mobile_login','mobile_refresh','mobile_logout','mobile_heartbeat','mobile_dashboard','mobile_notice','mobile_attendance_list','mobile_mark_attendance','mobile_attendance_status','mobile_asset','mobile_document','mobile_complaint','mobile_complaints'].includes(b.request.action))fail(400,'Invalid mobile operation');
  if(b.request.action==='mobile_login'&&b.request.cardIssueId&&!cardReaderEnforced)fail(503,'Issued card readers are not enabled','CARD_READER_DISABLED');
  const cardContext=b.request.action==='mobile_login'?null:await readCard(b.schoolId,b.request);
  if(['mobile_complaint','mobile_complaints'].includes(b.request.action)){
   const result=await require('./mobile-complaints').createMobileComplaints({db,now,fail,verify:async details=>signed(m,{action:'managed_mobile',request:{...b.request,action:details?'mobile_dashboard':'mobile_session_verify',afterSignal:true},lease:{schoolId:m.schoolId,expiresAt:lease(m).expiresAt}})})(b.schoolId,b.request);
   return {...result,...cardContext,policyExpiresAt:Math.min(e.expiresAt,now()+72*3600000)};
  }
  if(b.request.action==='mobile_attendance_status'){
   const permit=verifyAttendanceIdentity(b.schoolId,b.request),ids=b.request.operationIds;
   if(!Array.isArray(ids)||ids.length<1||ids.length>25||ids.some(id=>!/^[a-f0-9]{64}$/.test(id))||new Set(ids).size!==ids.length)fail(400,'Invalid attendance status batch');
   const rows=await Promise.all(ids.map(id=>attendanceRow(b.schoolId,id)));
   const operations=rows.map((row,index)=>{
    if(!row.exists)return {operationId:ids[index],state:'unknown'};
    const value=row.data();if(value.schoolId!==b.schoolId)fail(403,'Another school is not accessible');
    const payload=value.payloadTransport==='cloudflare-v1'?cloudflareSync.decryptAttendance(value.payload):JSON.parse(unprotect(value.payload,encryptionKey));
    if(payload.personId!==permit.documentId||payload.role!==permit.role)fail(403,'Another person attendance is not accessible');
    return {operationId:ids[index],state:value.state,createdAt:value.createdAt,
      ...(value.state==='completed'?{completedAt:value.completedAt}:{})};
   });
   return {success:true,schoolId:b.schoolId,projectId:b.schoolId,syncProtocol:2,operations,...cardContext};
  }
  if(b.request.action==='mobile_mark_attendance'&&b.request.attendancePermit){
   const permit=verifyAttendance(b.schoolId,b.request);
   if(cardReaderEnforced)cardReader.verifyCapture({schoolId:b.schoolId,request:b.request});
   const captured=b.request.clientCapturedAt;
   if(captured!==undefined&&(!Number.isSafeInteger(captured)||captured<=0||captured>now()+120000||new Date(captured+19800000).toISOString().slice(0,10)!==permit.day))fail(409,'Attendance capture date needs school review; original data retained.','ATTENDANCE_CAPTURE_REVIEW');
   const result=await (edgeEnabled(b.schoolId)?edgeQueue(b.schoolId):queue).enqueue({schoolId:b.schoolId,role:permit.role,personId:permit.personId,day:permit.day,mode:b.request.mode==='exit'?'exit':'entry',payload:protect(JSON.stringify({...b.request,attendancePermit:undefined}),encryptionKey)});
   if(!edgeEnabled(b.schoolId))attendanceWake();
   return {success:true,schoolId:b.schoolId,projectId:b.schoolId,syncProtocol:2,...result,...(!cardReaderEnforced&&edgeEnabled(b.schoolId)?{cloudflareLane:cloudflareSync.grant(permit)}:{}),...cardContext};
  }
  const body={action:'managed_mobile',request:b.request,lease:{schoolId:m.schoolId,expiresAt:lease(m).expiresAt}};
  let result=edgeEnabled(b.schoolId)&&b.request.action==='mobile_notice'
   ?await signed(m,{...body,request:{...b.request,action:'mobile_session_verify'}})
   :b.request.action==='mobile_dashboard'&&b.request.afterSignal!==true
   ?await readView(m.schoolId,body,()=>signed(m,body),true):await signed(m,body);
  if(edgeEnabled(b.schoolId)&&['mobile_dashboard','mobile_notice'].includes(b.request.action)){
   const state=await cloudflareSync.notices(b.schoolId,()=>noticeBaseline(b.schoolId));
   if(b.request.action==='mobile_notice'){const record=state.records[b.request.noticeId];if(!record||record._syncDeleted)fail(404,'School notice unavailable');result={...result,notice:record};}
   else {
    const rows=Object.entries(state.records).filter(([,r])=>!r._syncDeleted).map(([id,r])=>({...r,id,_noticeRevision:r._syncRevision})).sort((a,b)=>Number(b.timestamp||b.createdAt||0)-Number(a.timestamp||a.createdAt||0)).slice(0,100);
    result={...result,unchanged:false,notices:rows,revisions:{...result.revisions,notices:state.revision},cloudflareNoticesVersion:1};
    if(b.request.mobileRecordDeltaVersion===1){result.mobileRecordDeltaVersion=1;result.groupRecordDeltas={...result.groupRecordDeltas,notices:{ids:rows.map(r=>r.id)}};result.notices=rows.map(r=>({...r,_mobileRecordId:r.id,_mobileRecordRevision:hash(JSON.stringify(r))}));delete result.noticesDelta;delete result.noticeIds;}
    else {result.noticesDelta=true;result.noticeIds=rows.map(r=>r.id);}
   }
  }
  if(b.request.action==='mobile_mark_attendance')await changeHint(m.schoolId,'attendance_records');
  if(['mobile_logout','mobile_mark_attendance','mobile_complaint'].includes(b.request.action))invalidate(m.schoolId);
  const verifiedCard=b.request.action==='mobile_login'?await cardReader.verifyLogin({schoolId:b.schoolId,role:b.request.role,personId:b.request.personId,linkToken:b.request.linkToken,deviceId:b.request.deviceId,cardIssueId:b.request.cardIssueId},result):cardContext;
  await registerDevice(b.schoolId,b.request,result);
  if(result.attendancePolicy) result.attendancePermit=attendancePermit(b.schoolId,b.request.sessionToken||result.sessionToken,result.attendancePolicy,e.expiresAt);
  if(result.attendancePolicy) result.attendanceStatus={version:result.attendancePolicy.scheduleVersion===1?1:0,day:result.attendancePolicy.day,recorded:result.attendancePolicy.recorded===true,schedule:result.attendancePolicy.schedule??null};
  if(!cardReaderEnforced&&edgeEnabled(b.schoolId)&&result.attendancePermit){const permit=JSON.parse(Buffer.from(result.attendancePermit.split('.')[0],'base64url').toString('utf8'));result.cloudflareLane=cloudflareSync.grant(permit);}
  delete result.attendancePolicy;
  return {...result,...verifiedCard,policyExpiresAt:Math.min(e.expiresAt,now()+72*3600000)};
 }
 const m=await identity(req,b.schoolId);
 const deviceDecision=await deviceAccess.authorize({req,body:b,identity:m,entitlement:lease(m)});if(deviceDecision.handled)return deviceDecision.result;
 if(['managed/support/list','managed/support/create','managed/support/thread','managed/support/reply','managed/support/resolve'].includes(action))return createManagedSupport({db,now,fail})(action,b,m);
 // A restored Firebase session predates enrollment on existing PCs. Optional
 // directory admission is background metadata, never a new school-data gate.
 if(action==='managed/session'&&deviceEnrollmentEnabled&&!deviceManagementEnabled&&!deviceAccessEnforced)
  scheduleHint(()=>deviceAccess.observeSession(req,b,m,lease(m)).catch(()=>{}));
 if(action==='managed/theme/unlock'){
  if(!lease(m).allowed)fail(403,'School licence is inactive');
  const devices=await deviceAccess.themeDevices(req,m);
  return {success:true,schoolId:m.schoolId,activation:'app-lock-unlock-v2',windowsTheme:await windowsTheme.unlock(m.schoolId,devices.deviceId,devices.devices)};
 }
 if(action==='managed/theme/state'){
  if(!lease(m).allowed)fail(403,'School licence is inactive');
  const devices=await deviceAccess.themeDevices(req,m);
  return {success:true,schoolId:m.schoolId,windowsTheme:await windowsTheme.schoolState(m.schoolId,devices.deviceId,b.locked,devices.devices)};
 }
 if(action==='managed/presence'){
  const p=verifiedPresence(b.presenceToken);if(p.schoolId!==m.schoolId||p.uid!==m.uid)fail(403,'Another school is not accessible');
  await db.doc('platform_schools/'+m.schoolId).set({lastSeenAt:now()},{merge:true});return {success:true,schoolId:m.schoolId};
 }
 if(action==='managed/session'){const access=lease(m);let appearance;if(b.appearance===true){appearance={...DEFAULT_THEME};try{appearance=await windowsTheme.readSchool(m.schoolId);}catch(_){/* Presentation failure must not deny school access. */}}const registration=await db.doc('school_registration_profiles/'+m.schoolId).get();const account=await db.doc('platform_schools/'+m.schoolId).get();access.registrationState=registration.exists?'complete':account.data()?.registrationState==='new'?'new':'unknown';await db.doc('platform_schools/'+m.schoolId).set({lastSeenAt:access.allowed?now():0},{merge:true});const storage=await db.doc('school_storage_private/'+m.schoolId).get();return {...access,...(appearance?{windowsTheme:appearance}:{}),deviceEnforced:deviceDecision.deviceEnforced===true,...(deviceDecision.deviceManaged===true?{deviceManaged:true,device:deviceDecision.device}:{}),...(deviceDecision.deviceEnforced===true?{device:deviceDecision.device,offlineLease:deviceDecision.offlineLease,offlineExpiresAt:deviceDecision.offlineExpiresAt}:{}),presenceToken:presence(m,access),storageReady:storage.exists&&storage.data().ready===true,scriptUrl:storage.exists?storage.data().url:''};}
 if(action==='managed/disconnect'){invalidate(m.schoolId);await db.doc('platform_schools/'+m.schoolId).set({lastSeenAt:0},{merge:true});return {success:true};}
 if(action==='managed/summary'){
  if(!lease(m).allowed||m.entitlement.status!=='trial'&&m.entitlement.activated!==true)fail(403,'School licence is inactive');
  const school=await db.doc('platform_schools/'+m.schoolId).get();
  const cached=school.data()||{};
  if(Number.isSafeInteger(cached.summaryAt)&&cached.summaryAt>0&&cached.summaryAt<=now()&&now()-cached.summaryAt<300000&&Number.isSafeInteger(cached.studentCount)&&cached.studentCount>=0&&Number.isSafeInteger(cached.driveBytes)&&cached.driveBytes>=0)return {success:true,schoolId:m.schoolId,cached:true,studentCount:cached.studentCount,driveBytes:cached.driveBytes,partial:cached.driveBytesPartial===true,measuredAt:cached.summaryAt};
  const result=await signed(m,{action:'managed_summary'});
  if(!Number.isSafeInteger(result.studentCount)||result.studentCount<0||!Number.isSafeInteger(result.driveBytes)||result.driveBytes<0||typeof result.partial!=='boolean')fail(502,'Invalid school storage summary');
  await db.doc('platform_schools/'+m.schoolId).set({studentCount:result.studentCount,driveBytes:result.driveBytes,driveBytesPartial:result.partial===true,summaryAt:now()},{merge:true});return {success:true,schoolId:m.schoolId,cached:false,studentCount:result.studentCount,driveBytes:result.driveBytes,partial:result.partial===true,measuredAt:now()};
 }
 if(action==='managed/licence/activate'){if(hash(String(b.key||'').trim().toUpperCase())!==m.entitlement.licenseHash||!lease(m).allowed)fail(403,'Licence does not belong to this school or has expired');const ref=db.doc('school_entitlements/'+m.schoolId);
 await db.runTransaction(async tx=>{const current=await tx.get(ref);const e=current.data();if(!e||e.active!==true||e.blocked===true||e.licenseHash!==m.entitlement.licenseHash||Number(e.expiresAt)<=now()||Number(e.startsAt)>now())fail(403,'School licence changed or access was blocked');tx.set(ref,{activated:true},{merge:true});});return {...lease(m),activated:true,status:'licensed'};}
 if(!lease(m).allowed||(m.entitlement.status!=='trial'&&m.entitlement.activated!==true))fail(403,'Activate the school licence before normal operations');
 // Lightweight enrollment metadata is independent of the PC and school Drive.
 // Media and operational records remain in the school's own storage.
 if(action==='managed/profile'){
  const ref=db.doc('school_registration_profiles/'+m.schoolId);
  if(b.operation==='initialize'){
   const name=String(b.schoolName||'').trim(),principal=String(b.principalName||'').trim(),contact=String(b.schoolContactNo||'').trim();
   if(contact&&!/^\+?[0-9][0-9 -]{5,18}[0-9]$/.test(contact))fail(400,'Valid school contact number required');
   if(name.length<2||name.length>160||principal.length<2||principal.length>160)fail(400,'Valid school and principal names required');
   await db.runTransaction(async tx=>{
    const entitlement=await tx.get(db.doc('school_entitlements/'+m.schoolId)),existing=await tx.get(ref);
    const current={...m,entitlement:entitlement.data()||{}};
    if(current.entitlement.active!==true||current.entitlement.blocked===true||!lease(current).allowed||current.entitlement.status!=='trial'&&current.entitlement.activated!==true||current.entitlement.licenseHash!==m.entitlement.licenseHash)fail(403,'School access changed during registration');
    if(!existing.exists)tx.set(ref,{schoolId:m.schoolId,schoolName:name,principalName:principal,...(contact?{schoolContactNo:contact}:{}),completedAt:now()});
   });
  }else if(b.operation!=='read')fail(400,'Invalid school profile operation');
  const profile=await ref.get(),school=await db.doc('platform_schools/'+m.schoolId).get(),storage=await db.doc('school_storage_private/'+m.schoolId).get();
  const data=profile.data();
  if(profile.exists&&(data.schoolId!==m.schoolId||typeof data.schoolName!=='string'||data.schoolName.trim().length<2||typeof data.principalName!=='string'||data.principalName.trim().length<2))fail(409,'Saved school registration requires recovery');
  let registrationState=profile.exists?'complete':school.data()?.registrationState==='new'?'new':'unknown';
  let recovered=profile.exists?{schoolId:m.schoolId,schoolName:data.schoolName,principalName:data.principalName,...(data.schoolContactNo?{schoolContactNo:data.schoolContactNo}:{})}:null;
  // Pre-marker accounts already have an authoritative developer-created name.
  // Recover that SAME account, without asserting that missing registration or
  // operational data was backed up, and without creating/changing any records.
  if(registrationState==='unknown'){
   const account=school.data(),owned=await db.doc('schools/'+m.schoolId).get(),details=owned.data();
   if(account?.managed===true&&account.authUid===m.uid&&account.schoolId===m.schoolId&&
      details?.schoolId===m.schoolId&&details.ownerUid===m.uid&&
      typeof account.name==='string'&&account.name.trim().length>=2&&typeof details.schoolName==='string'&&account.name.trim()===details.schoolName.trim()){
    registrationState='recovery';recovered={schoolId:m.schoolId,schoolName:account.name.trim(),principalName:''};
   }
  }
  return {success:true,schoolId:m.schoolId,registrationState,profile:recovered,storageReady:storage.exists&&storage.data().ready===true};
 }
 if(action==='managed/storage/connect'){
 invalidate(m.schoolId);
  const url=scriptUrl(b.scriptUrl),ref=db.doc('school_storage_private/'+m.schoolId),old=await ref.get();
  if(old.exists&&old.data().ready===true){
   if(old.data().url!==url){if(b.replace!==true||b.expectedScriptUrl!==old.data().url)fail(409,'Existing storage retained. Confirm the current school Drive connection before replacement');}
   else {const health=await signed(m,{action:'managed_health'});if(health.storageReady!==true)fail(502,'School Drive verification failed');return {success:true,schoolId:m.schoolId,storageReady:true,scriptUrl:url,googleEmail:health.googleEmail||''};}
  }
  for(const [k,v] of pairingTickets)if(v.expiresAt<=now())pairingTickets.delete(k);
  if(pairingTickets.size>=100)fail(429,'Retry storage connection shortly');
  const ticket=randomBytes(32).toString('hex'),ticketHash=hash(ticket),entry={schoolId:m.schoolId,req,expiresAt:now()+120000,used:false};pairingTickets.set(ticketHash,entry);
  try {
   const result=await scriptRequest(url,{action:'managed_connect',schoolId:m.schoolId,ticket});
   if(!entry.used||result.success!==true||result.schoolId!==m.schoolId||result.storageReady!==true||!/^[a-f0-9]{64}$/.test(result.connectionSecret||''))fail(409,'Update and prepare the managed Apps Script for this School ID');
   const secret=result.connectionSecret,timestamp=now(),nonce=randomBytes(24).toString('hex'),payload=JSON.stringify({action:'managed_health'}),signature=createHmac('sha256',secret).update(m.schoolId+'\n'+timestamp+'\n'+nonce+'\n'+payload).digest('hex');
   const health=await scriptRequest(url,{schoolId:m.schoolId,timestamp,nonce,payload,signature});
   if(health.success!==true||health.schoolId!==m.schoolId||health.storageReady!==true)fail(409,'Script is not prepared for this school');
   const fresh=await identity(req,m.schoolId);if(!lease(fresh).allowed||fresh.entitlement.status!=='trial'&&fresh.entitlement.activated!==true)fail(403,'School licence is inactive');
   await db.runTransaction(async tx=>{
    const current=await tx.get(ref);
    // A readiness-only placeholder is not a storage identity. Recheck both
    // snapshots so a binding created while the signed handshake ran is retained.
    const empty=s=>s.exists&&s.data().ready!==true&&!s.data().url&&!s.data().secret&&
      (s.data().previousConnections===undefined||Array.isArray(s.data().previousConnections)&&s.data().previousConnections.length===0);
    const firstPairing=empty(old)&&empty(current);
    if(current.exists&&!firstPairing&&(!old.exists||b.replace!==true||b.expectedScriptUrl!==current.data().url))fail(409,'Existing storage retained. Confirm the current school Drive connection before replacement');
    tx.set(ref,{url,secret:protect(secret,encryptionKey),ready:true,...(current.exists&&!firstPairing?{previousConnections:[...(current.data().previousConnections||[]),{url:current.data().url,secret:current.data().secret,at:now()}]}:{})},{merge:true});
   });
   // A concurrent readiness read may have cached the missing pre-pairing snapshot.
   // Invalidate after the durable binding commit, not only before pairing starts.
   invalidate(m.schoolId);
   await db.doc('platform_schools/'+m.schoolId).set({storageReady:true,storageCheckedAt:now()},{merge:true});
   await db.collection('platform_audit').add({action,schoolId:m.schoolId,actor:m.uid,at:now()});
   return {success:true,schoolId:m.schoolId,storageReady:true,scriptUrl:url,googleEmail:health.googleEmail||''};
  }finally{pairingTickets.delete(ticketHash);}
 }
 if(action==='managed/sync/status'){
  if(b.report!==undefined){const r=b.report;
   if(!r||typeof r!=='object'||Array.isArray(r)||Object.keys(r).some(k=>!['pending','needsAttention','verifiedReceiptCount','lastCloudAckMillis','appVersion','conflictCount','documentPending','lastReconciliationMillis','lastLocalBackupMillis','mediaPending','mediaInventoryState','lastClientSyncMillis'].includes(k))||
     !['pending','needsAttention','verifiedReceiptCount','lastCloudAckMillis'].every(k=>Number.isSafeInteger(r[k])&&r[k]>=0)||r.needsAttention>r.pending||r.pending>100000||r.verifiedReceiptCount>10000000||r.lastCloudAckMillis>now()+300000)fail(400,'Invalid aggregate Windows sync report');
   if(r.appVersion!==undefined&&(typeof r.appVersion!=='string'||! /^[A-Za-z0-9._+-]{1,80}$/.test(r.appVersion))||['conflictCount','documentPending','lastReconciliationMillis','lastLocalBackupMillis','mediaPending','lastClientSyncMillis'].some(k=>r[k]!==undefined&&(!Number.isSafeInteger(r[k])||r[k]<0))||r.conflictCount!==undefined&&r.conflictCount>r.needsAttention||r.documentPending!==undefined&&r.documentPending>r.pending||['lastReconciliationMillis','lastLocalBackupMillis','lastClientSyncMillis'].some(k=>r[k]!==undefined&&r[k]>now()+300000))fail(400,'Invalid aggregate Windows sync evidence');
   if(r.mediaPending!==undefined&&(r.mediaPending>100000 || !['PARTIAL','VERIFIED'].includes(r.mediaInventoryState)) || r.mediaInventoryState!==undefined&&!['UNKNOWN','PARTIAL','VERIFIED'].includes(r.mediaInventoryState))fail(400,'Invalid measured media evidence');
   const row=await db.doc('platform_schools/'+m.schoolId).get(),previous=row.data()?.syncWindowsReport;
   if(!previous||now()-previous.receivedAt>=300000)await db.doc('platform_schools/'+m.schoolId).update({syncWindowsReport:{version:1,receivedAt:now(),source:'latest_windows_client_report',...r}});
  }
  const row=await db.doc('platform_schools/'+m.schoolId).get(),data=row.data()||{};
  return {success:true,schoolId:m.schoolId,serverEvidence:data.syncServerEvidence||null,latestWindowsReport:data.syncWindowsReport||null,measuredAt:now()};
 }
 if(action==='managed/events'){
  if(!lease(m).allowed)fail(403,'School licence is inactive');
  await deliveryBudget(syncDelivery.recover(m.schoolId,async ticket=>{
   const response=await signed(m,{action:'managed_records',operation:'read',collection:ticket.collection,id:ticket.id,syncProtocol:2});
   const record=response.records?.[ticket.id];
   return response.schoolId===m.schoolId && response.syncProtocol===2 && record?.schoolId===m.schoolId &&
    record._syncOperationId===ticket.operationId && typeof record._syncRevision==='string' && !!record._syncRevision;
  })).catch(()=>{});
  if(b.changeFeedReplayVersion!==undefined&&b.changeFeedReplayVersion!==1)fail(400,'Unsupported change replay version');
  const event=await changeFeed.wait(m.schoolId,b.cursor,{replayVersion:b.changeFeedReplayVersion||0});
  const fresh=await identity(req,m.schoolId);if(!lease(fresh).allowed||(fresh.entitlement.status!=='trial'&&fresh.entitlement.activated!==true))fail(403,'School licence is inactive');
  await deviceAccess.authorize({req,body:b,identity:fresh,entitlement:lease(fresh)});
  return {success:true,schoolId:m.schoolId,changeFeedVersion:1,...event};
 }
 if(action==='managed/storage/quota')return signed(m,{action:'managed_storage_quota',schoolId:m.schoolId});
 if(action==='managed/storage/check')return {...await signed(m,{action:'managed_health',...(b.profilePhoto===true?{profilePhoto:true}:{})}),brokerUploadResumableVersion:1,brokerSheetIntegrityAuditVersion:1,brokerRecordSyncVersion:2,brokerRecordWriteBatchVersion:1,brokerRecordDeltaRecordsVersion:1,brokerChangeHeadsVersion:1,brokerChangeFeedVersion:changeFeed.enabled?1:0,brokerChangeFeedReplayVersion:changeFeed.enabled?1:0,brokerDisasterRehearsalVersion:5,brokerDisasterReadbackVersion:1};
 if(action==='managed/cloudflare/status'){if(!edgeEnabled(m.schoolId))return {success:true,schoolId:m.schoolId,enabled:false};const [notices,delivery]=await Promise.all([cloudflareSync.rpc(m.schoolId,'notices',{command:'stats'}),cloudflareSync.rpc(m.schoolId,'delivery',{command:'stats'})]);return {success:true,schoolId:m.schoolId,enabled:true,notices,delivery};}
 if(action==='managed/attendance/status'){
  if(!Array.isArray(b.operationIds)||b.operationIds.length>25||b.operationIds.some(id=>!/^[a-f0-9]{64}$/.test(id))||new Set(b.operationIds).size!==b.operationIds.length)fail(400,'Invalid attendance status batch');
  const rows=await Promise.all(b.operationIds.map(id=>attendanceRow(m.schoolId,id)));
  const operations=rows.map((row,index)=>{if(row.exists&&row.data().schoolId!==m.schoolId)fail(403,'Another school is not accessible');const value=row.data()||{};return {operationId:b.operationIds[index],state:row.exists?value.state:'unknown',createdAt:value.createdAt||null,completedAt:value.state==='completed'?value.completedAt:null};});
  return {success:true,schoolId:m.schoolId,operations};
 }
 if(action==='managed/integrity/audit'){
  if(!COLLECTIONS.has(b.collection)||!Number.isSafeInteger(b.afterRow??2)||(b.afterRow??2)<2||(b.afterRow??2)>10000000)fail(400,'Invalid integrity audit');
  return signed(m,{action:'managed_integrity_audit',collection:b.collection,afterRow:b.afterRow??2});
 }
 if(action==='managed/changes'){
  const collections=b.collections,known=b.knownRevisions||{};
  if(!Array.isArray(collections)||collections.length>22||new Set(collections).size!==collections.length||collections.some(col=>!COLLECTIONS.has(col))||!known||typeof known!=='object'||Array.isArray(known)||Object.entries(known).some(([key,value])=>!collections.includes(key)||typeof value!=='string'||value.length>1000))fail(400,'Invalid delta checkpoint');
  if(b.headOnly!==undefined&&typeof b.headOnly!=='boolean')fail(400,'Invalid delta mode');
  const recordCheckpoints=b.knownRecordRevisions;
  if(recordCheckpoints!==undefined){
   if(!recordCheckpoints||typeof recordCheckpoints!=='object'||Array.isArray(recordCheckpoints))fail(400,'Invalid record checkpoint');
   let count=0;for(const [col,rows] of Object.entries(recordCheckpoints)){
    if(!collections.includes(col)||!rows||typeof rows!=='object'||Array.isArray(rows))fail(400,'Invalid record checkpoint');
    for(const [id,revision] of Object.entries(rows))if(++count>100000||!id||id.length>200||id.includes('/')||['.','..'].includes(id)||typeof revision!=='string'||!revision||revision.length>1000)fail(400,'Invalid record checkpoint');
   }
  }
  const body={action:'managed_delta',collections,knownRevisions:known,...(recordCheckpoints!==undefined?{knownRecordRevisions:recordCheckpoints}:{}),...(b.headOnly===true?{headOnly:true}:{})};
  // A commit on another broker cannot invalidate this process's five-second
  // view cache. Verified delta apply must read current authoritative records.
  const cfNotices=edgeEnabled(m.schoolId)&&collections.includes('school_notices');
  const driveBody=cfNotices?{...body,collections:collections.filter(c=>c!=='school_notices'),knownRevisions:Object.fromEntries(Object.entries(known).filter(([k])=>k!=='school_notices')),...(recordCheckpoints?{knownRecordRevisions:Object.fromEntries(Object.entries(recordCheckpoints).filter(([k])=>k!=='school_notices'))}:{})}:body;
  const result=driveBody.collections.length?(b.headOnly===true?await readView(m.schoolId,driveBody,()=>signed(m,driveBody)):await signed(m,driveBody)):{success:true,schoolId:m.schoolId,syncProtocol:2,...(b.headOnly===true?{headOnly:true,revisions:{}}:{changes:{}})};
  if(cfNotices){const state=await cloudflareSync.notices(m.schoolId,()=>noticeBaseline(m.schoolId));if(b.headOnly===true)result.revisions={...result.revisions,school_notices:state.revision};else {const checkpoint=recordCheckpoints?.school_notices;const unchanged=known.school_notices===state.revision;const records=unchanged?{}:checkpoint?Object.fromEntries(Object.entries(state.records).filter(([id,r])=>checkpoint[id]!==r._syncRevision)):state.records;result.changes={...result.changes,school_notices:{syncProtocol:2,collectionRevision:state.revision,records,unchanged,...(checkpoint?{partialRecords:true}:{})}};}}

  if(b.headOnly===true){
   if(result.headOnly!==true||result.syncProtocol!==2||!result.revisions||typeof result.revisions!=='object'||Array.isArray(result.revisions)||Object.keys(result.revisions).length!==collections.length||collections.some(col=>typeof result.revisions[col]!=='string'||!result.revisions[col]||result.revisions[col].length>1000))fail(502,'Invalid school change heads');
   return {success:true,schoolId:m.schoolId,syncProtocol:2,headOnly:true,revisions:result.revisions};
  }
  if(result.syncProtocol!==2||!result.changes||typeof result.changes!=='object'||Object.keys(result.changes).length!==collections.length)fail(502,'Invalid delta response');
  for(const col of collections){const group=result.changes[col];if(!group||(group.partialRecords!==undefined&&typeof group.partialRecords!=='boolean')||group.partialRecords===true&&(!recordCheckpoints||!Object.prototype.hasOwnProperty.call(recordCheckpoints,col))||group.syncProtocol!==2||typeof group.collectionRevision!=='string'||!group.records||typeof group.records!=='object'||Array.isArray(group.records)||Object.values(group.records).some(row=>!row||row.schoolId!==m.schoolId))fail(502,'Foreign or invalid school delta');}
  return result;
 }
 // Inactive controlled-import foundation. No arbitrary managed Sheet edits.
 if(['managed/student-import/preview','managed/student-import/commit','managed/student-import/sheet/setup','managed/student-import/sheet/read'].includes(action)){
  if(studentImportEnabled!==true)fail(503,'Controlled student import is not enabled','IMPORT_DISABLED');
  let importRows=b.rows;
  const readSheet=async(create=false)=>{
   const result=await signed(m,{action:create?'managed_import_sheet_setup':'managed_import_sheet_read',...(create?{confirmCreate:b.confirmCreate===true}:{})});
   if(result.headerVersion!==1||result.source!=='designated-sheet'||typeof result.sheetId!=='string'||result.sheetId.length>200||!Array.isArray(result.rows)||result.rows.length>100||typeof result.fingerprint!=='string'||result.fingerprint.length>200)fail(502,'Unverified designated Import Sheet');
   return result;
  };
  if(action.endsWith('/sheet/setup')){if(b.confirmCreate!==true)fail(400,'Confirm designated Import Sheet creation');return readSheet(true);}
  if(action.endsWith('/sheet/read'))return readSheet();
  let sourceFingerprint=null,sourceSheetId=null;
  if(b.source!==undefined&&b.source!=='designated-sheet')fail(400,'Invalid import source');
  if(b.source==='designated-sheet'){if(b.rows!==undefined)fail(400,'Sheet source cannot accept replacement rows');const source=await readSheet();importRows=source.rows;sourceFingerprint=source.fingerprint;sourceSheetId=source.sheetId;}
  if(!Array.isArray(importRows)||importRows.length<1||importRows.length>100||JSON.stringify(importRows).length>100000)fail(400,'Import requires 1–100 bounded rows');
  const rowsHash=canonicalHash(importRows);
  const read=async()=>{
   const result=await signed(m,{action:'managed_records',collection:'students_directory',operation:'read',syncProtocol:2});
   if(result.syncProtocol!==2||typeof result.collectionRevision!=='string'||!result.records||typeof result.records!=='object'||Array.isArray(result.records)||Object.keys(result.records).length>100000)fail(502,'Unverified student snapshot');
   for(const [id,r]of Object.entries(result.records))if(['__proto__','prototype','constructor','.','..'].includes(id)||!r||r.schoolId!==m.schoolId||typeof r._syncRevision!=='string'||!r._syncRevision||r._syncRevision.length>100)fail(409,'Student snapshot needs administrator review');
   return result.records;
  };
  const records=await read();
  const refFor=slot=>db.doc('school_import_preview_private/'+hash(m.schoolId+'/'+slot));
  const relevant=r=>Object.fromEntries(Object.entries(r).filter(([k])=>!k.startsWith('_sync')));
  if(action.endsWith('/preview')){
   let plan;try{plan=planStudentImport({schoolId:m.schoolId,rows:importRows,currentRecords:Object.entries(records).map(([studentId,r])=>({schoolId:m.schoolId,studentId,name:r.name,class:r.studentClass??r.class,section:r.section??'',rollNo:r.rollNo,revision:r._syncRevision,deleted:r._syncDeleted===true}))});}catch{fail(409,'Student snapshot or import requires review');}
   if(!plan.valid)return {success:true,...plan};
   const operations=plan.operations.map(op=>{
    const prior=records[op.studentId]||{};
    const data={...prior,schoolId:m.schoolId,name:op.record.name,studentClass:op.record.class,section:op.record.section,rollNo:op.record.rollNo};
    if(!records[op.studentId]||Object.hasOwn(prior,'class'))data.class=op.record.class;
    for(const key of Object.keys(data))if(key.startsWith('_sync'))delete data[key];
    return {...op,data,operationId:canonicalHash([op.operationId,data])};
   });
   const planId=canonicalHash([plan.planId,operations,sourceFingerprint,sourceSheetId]);
   if(Buffer.byteLength(JSON.stringify(operations))>500000)fail(400,'Import preview exceeds safe storage bound');
   const expiresAt=now()+1800000,admission=db.doc('school_import_admission_private/'+m.schoolId);
   await db.runTransaction(async tx=>{
    const saved=await tx.get(admission);let ledger={schoolId:m.schoolId,plans:[]};
    try{if(saved.exists)ledger=JSON.parse(unprotect(saved.data().sealed,encryptionKey));}catch{fail(503,'Import admission requires administrator review');}
    if(ledger.schoolId!==m.schoolId||!Array.isArray(ledger.plans)||ledger.plans.length>20)fail(503,'Import admission requires administrator review');
    const active=ledger.plans.filter(p=>p.expiresAt>now());
    if(active.some(p=>!Number.isInteger(p.slot)||p.slot<0||p.slot>=20)||new Set(active.map(p=>p.slot)).size!==active.length)fail(503,'Import admission requires administrator review');
    const old=active.find(p=>p.planId===planId),occupied=new Set(active.map(p=>p.slot));
    if(!old&&active.length>=20)fail(429,'Too many active import previews; wait for expiry');
    const slot=old?old.slot:Array.from({length:20},(_,i)=>i).find(i=>!occupied.has(i));
    tx.set(admission,{sealed:protect(JSON.stringify({schoolId:m.schoolId,plans:[...active.filter(p=>p.planId!==planId),{planId,expiresAt,slot}]}),encryptionKey)});
    tx.set(refFor(slot),{sealed:protect(JSON.stringify({planId,schoolId:m.schoolId,actor:m.uid,rowsHash,sourceFingerprint,sourceSheetId,expiresAt,operations}),encryptionKey)});
   });
   return {success:true,...plan,planId,sourceFingerprint,sourceSheetId,expiresAt,operations:operations.map(({data,...op})=>op),requiresAdminCommit:true};
  }
  if(!/^[a-f0-9]{64}$/.test(b.planId||''))fail(400,'Exact preview plan required');
  const admission=await db.doc('school_import_admission_private/'+m.schoolId).get();let entry;
  try{const ledger=admission.exists?JSON.parse(unprotect(admission.data().sealed,encryptionKey)):null;if(ledger?.schoolId===m.schoolId&&Array.isArray(ledger.plans)&&ledger.plans.length<=20)entry=ledger.plans.find(p=>p.planId===b.planId&&p.expiresAt>now());}catch{fail(409,'Import preview verification failed');}
  if(!entry||!Number.isInteger(entry.slot)||entry.slot<0||entry.slot>=20)fail(409,'Import preview changed or expired');
  const saved=await refFor(entry.slot).get();let plan;
  try{if(saved.exists)plan=JSON.parse(unprotect(saved.data().sealed,encryptionKey));}catch{fail(409,'Import preview verification failed');}
  if(!saved.exists||plan.planId!==b.planId||plan.schoolId!==m.schoolId||plan.actor!==m.uid||plan.rowsHash!==rowsHash||plan.sourceFingerprint!==sourceFingerprint||plan.sourceSheetId!==sourceSheetId||plan.expiresAt<=now())fail(409,'Import preview changed or expired');
  const outcomes=[];
  for(const op of plan.operations){
   const current=records[op.studentId];
   if(current?._syncOperationId===op.operationId&&canonicalHash(relevant(current))===canonicalHash(op.data)){outcomes.push({studentId:op.studentId,operationId:op.operationId,state:'verified',recordRevision:current._syncRevision});continue;}
   if((current?._syncRevision??null)!==op.expectedRevision){outcomes.push({studentId:op.studentId,operationId:op.operationId,state:'conflict'});break;}
   try{
    const fresh=await identity(req,m.schoolId);if(!lease(fresh).allowed||fresh.entitlement.status!=='trial'&&fresh.entitlement.activated!==true)fail(403,'School access changed');
    const ack=await signed(fresh,{action:'managed_records',collection:'students_directory',operation:'write',syncProtocol:2,id:op.studentId,data:op.data,operationId:op.operationId,expectedRecordRevision:op.expectedRevision??''});
    invalidate(m.schoolId);
    if(ack.syncProtocol!==2||typeof ack.recordRevision!=='string'||!ack.recordRevision)throw Error('Unverified import ACK');
    const final=(await read())[op.studentId];
    if(!final||final._syncRevision!==ack.recordRevision||final._syncOperationId!==op.operationId||canonicalHash(relevant(final))!==canonicalHash(op.data))throw Error('Import readback pending');
    outcomes.push({studentId:op.studentId,operationId:op.operationId,state:'verified',recordRevision:ack.recordRevision});
   }catch(error){outcomes.push({studentId:op.studentId,operationId:op.operationId,state:error.status===409?'conflict':'pending'});break;}
  }
  return {success:true,schoolId:m.schoolId,planId:b.planId,atomicBatch:false,outcomes,remaining:plan.operations.length-outcomes.length,verified:outcomes.length===plan.operations.length&&outcomes.every(o=>o.state==='verified')};
 }
 if(['managed/card/issue','managed/card/reissue','managed/card/revoke','managed/card/status','managed/card/verify'].includes(action)){
  if(cardIssueEnabled!==true)fail(503,'Card lifecycle is not enabled','CARD_ISSUE_DISABLED');
  const operation=action.substring('managed/card/'.length);
  if(!lease(m).allowed||(m.entitlement.status!=='trial'&&m.entitlement.activated!==true))fail(403,'School licence is inactive');
  const readPerson=async(school,role,personId)=>{
   if(school!==m.schoolId)fail(403,'Another school is not accessible');
   const collection=role==='student'?'students_directory':'teachers_directory';
   const result=await signed(m,{action:'managed_records',collection,operation:'read',syncProtocol:2});
   if(!result||result.syncProtocol!==2||!result.records||typeof result.records!=='object'||Array.isArray(result.records)||Object.keys(result.records).length>100000)fail(502,'Verified school person inventory required','CARD_PERSON_UNVERIFIED');
   const direct=result.records[personId];
   if(direct&&direct.schoolId===school)return direct;
   const matches=Object.values(result.records).filter(r=>r&&r.schoolId===school&&r.mobileStableId===personId);
   if(matches.length!==1)fail(409,'Card person identity requires review');
   return matches[0];
  };
  return cardAuthority({request:{...b,operation},identity:m,readPerson});
 }
 if(action==='managed/records/batch'){
  if(!Array.isArray(b.operations)||b.operations.length<1||b.operations.length>10||JSON.stringify(b.operations).length>256000)fail(400,'Invalid record batch');
  const seen=new Set(),operationIds=new Set();
  const operations=b.operations.map(op=>{
   if(!op||!COLLECTIONS.has(op.collection)||['students_directory','teachers_directory','documents','backups'].includes(op.collection)||
     op.operation!=='write'||op.syncProtocol!==2||typeof op.id!=='string'||!/^[^/]{1,200}$/.test(op.id)||['.','..','__proto__','prototype','constructor'].includes(op.id)||
     !/^[A-Za-z0-9_-]{16,100}$/.test(op.operationId||'')||typeof op.expectedRecordRevision!=='string'||op.expectedRecordRevision.length>100||(seen.has(op.collection+'/'+op.id)||operationIds.has(op.operationId)))fail(400,'Invalid batch operation');
   seen.add(op.collection+'/'+op.id);operationIds.add(op.operationId);return {action:'managed_records',operation:'write',collection:op.collection,id:op.id,
    syncProtocol:2,operationId:op.operationId,expectedRecordRevision:op.expectedRecordRevision,data:{...clean(op.data),schoolId:m.schoolId}};
  });
  if(edgeEnabled(m.schoolId)&&operations.some(op=>op.collection==='school_notices')){const acknowledgements=[];for(const op of operations){try{const ack=await signed(m,op);acknowledgements.push({...ack,operationId:op.operationId,success:true});}catch(error){acknowledgements.push({operationId:op.operationId,success:false,code:error.code==='RECORD_REVISION_CONFLICT'?'SCRIPT_RECORD_REVISION_CONFLICT':'SCRIPT_OPERATION_FAILED'});}}return {success:true,schoolId:m.schoolId,syncProtocol:2,recordWriteBatchVersion:1,acknowledgements};}
  const tickets=[];for(const op of operations)tickets.push(await deliveryBudget(syncDelivery.prepare(m.schoolId,op)));
  const result=await signed(m,{action:'managed_records_batch',operations});
  if(result.syncProtocol!==2||result.recordWriteBatchVersion!==1||!Array.isArray(result.acknowledgements)||result.acknowledgements.length>operations.length)fail(502,'Invalid batch acknowledgement');
  const replied=new Set();
  for(const ack of result.acknowledgements){
   const index=operations.findIndex(op=>op.operationId===ack.operationId);
   if(index<0||replied.has(ack.operationId)||typeof ack.success!=='boolean'||ack.success&&(typeof ack.recordRevision!=='string'||!ack.recordRevision))fail(502,'Unverified batch receipt');
   replied.add(ack.operationId);
   if(ack.success){if(tickets[index])await deliveryBudget(syncDelivery.committed(tickets[index],ack.recordRevision)).catch(()=>{});else await changeHint(m.schoolId,operations[index].collection,operations[index].id);}
   else if(ack.code==='SCRIPT_RECORD_REVISION_CONFLICT'&&tickets[index])await syncDelivery.rejected(tickets[index]).catch(()=>{});
  }
  invalidate(m.schoolId);return result;
 }
 if(action==='managed/records'){
  if(!COLLECTIONS.has(b.collection)||!['read','write','delete','recover'].includes(b.operation))fail(400,'Invalid school collection operation');if(b.operation!=='read'&&(!/^[^/]{1,200}$/.test(b.id||'')||['.','..'].includes(b.id)))fail(400,'Invalid record ID');const data=['write','recover'].includes(b.operation)?{...clean(b.data),schoolId:m.schoolId}:undefined;
  if(b.expectedRevision!==undefined&&(b.collection!=='documents'||typeof b.expectedRevision!=='string'||b.expectedRevision.length>100))fail(400,'Invalid document version');if(b.syncProtocol!==undefined&&b.syncProtocol!==2)fail(400,'Invalid sync protocol');
  if(b.syncProtocol===2&&b.operation!=='read'&&(!/^[A-Za-z0-9_-]{16,100}$/.test(b.operationId||'')||typeof b.expectedRecordRevision!=='string'||b.expectedRecordRevision.length>100))fail(400,'Invalid sync operation');
  if(b.deletedStudentGeneration!==undefined&&(b.collection!=='students_directory'||b.operation!=='delete'||typeof b.deletedStudentGeneration!=='string'||!b.deletedStudentGeneration||b.deletedStudentGeneration.length>200))fail(400,'Invalid student deletion generation');
  const acknowledged=await signed(m,{action:'managed_records',operation:b.operation,collection:b.collection,
    ...(b.syncProtocol===2?{syncProtocol:2,...(b.operation==='read'?{knownRevision:typeof b.knownRevision==='string'?b.knownRevision:''}:{operationId:b.operationId,expectedRecordRevision:b.expectedRecordRevision})}:{}),...(b.id?{id:b.id}:{}),...(data?{data}:{}),...(b.deletedStudentGeneration!==undefined?{deletedStudentGeneration:b.deletedStudentGeneration}:{}),...(b.expectedRevision!==undefined?{expectedRevision:b.expectedRevision}:{}),...(Number.isFinite(b.expectedUploadedAt)?{expectedUploadedAt:b.expectedUploadedAt}:{})});
  if(b.operation!=='read')invalidate(m.schoolId);
  // Only verified durable Script ACK permits a hint. FCM is optional and never
  // changes the storage acknowledgement or sends private school content.
  const owner=b.operation==='write'&&(b.collection==='students_directory'||b.collection==='teachers_directory')?{personId:data.mobileStableId||b.id,role:b.collection==='students_directory'?'student':'teacher'}:b.operation==='write'&&data?.personId?{personId:data.personId,role:data.ownerRole||'student'}:undefined;
  if((b.syncProtocol===2||(b.collection==='documents'&&typeof b.expectedRevision==='string'))&&acknowledged.syncProtocol===2&&typeof acknowledged.recordRevision==='string'&&b.operation!=='read'&&['school_notices','school_config','school_settings','school_calendar','students_directory','teachers_directory','teacher_schedules','attendance_records','attendance_logs','teacher_attendance','fee_settings','fee_ledger','fee_payments','teacher_salary','exams','exam_center_results','exam_results','documents'].includes(b.collection))
   void notifyChanged(m.schoolId,b.operationId||hash(m.schoolId+'/'+b.collection+'/'+b.id+'/'+acknowledged.recordRevision),b.collection==='school_notices'&&b.operation==='write',owner).catch(error=>{const safe=['messaging/authentication-error','messaging/mismatched-credential','messaging/server-unavailable'];try{pushDiagnostics({event:'managed_push_hint_failure',code:safe.includes(error.code)?error.code:'FCM_UNAVAILABLE'});}catch{}});
  return acknowledged;
 }
 if(action==='managed/file/inventory'){
  if(b.cursor!==undefined&&b.cursor!==null&&!/^[A-Za-z0-9_-]{1,200}$/.test(b.cursor))fail(400,'Invalid binary inventory cursor');
  const result=await signed(m,{action:'managed_binary_inventory',...(b.cursor?{cursor:b.cursor}:{})});
  if(result.binaryInventoryVersion!==1||!/^[a-f0-9]{64}$/.test(result.inventoryFingerprint||'')||result.inventoryScope!=='application_media_folders'||!Number.isSafeInteger(result.observedAt)||typeof result.partial!=='boolean'||typeof result.scanLimited!=='boolean'||typeof result.coverageComplete!=='boolean'||!Array.isArray(result.items)||result.items.length>5||(result.nextCursor!==null&&!/^[A-Za-z0-9_-]{1,200}$/.test(result.nextCursor||'')))fail(502,'Unverified binary inventory','BINARY_INVENTORY_UNVERIFIED');
  const ids=new Set();for(const item of result.items){if(!item||! /^[A-Za-z0-9_-]{1,200}$/.test(item.fileId||'')||ids.has(item.fileId)||!Number.isSafeInteger(item.sizeBytes)||item.sizeBytes<0||typeof item.name!=='string'||item.name.length>1000||typeof item.mime!=='string'||item.mime.length>200)fail(502,'Invalid binary inventory','BINARY_INVENTORY_UNVERIFIED');ids.add(item.fileId);
   if(item.verification==='bytes_hashed'){if(item.sizeBytes<1||item.sizeBytes>20*1024*1024||!/^[a-f0-9]{64}$/.test(item.sha256||'')||typeof item.version!=='string'||item.version.length>150)fail(502,'Invalid binary verification','BINARY_INVENTORY_UNVERIFIED');}
   else if(item.verification!=='unavailable'||result.partial!==true||result.coverageComplete!==false)fail(502,'Binary hashes unavailable','BINARY_INVENTORY_UNVERIFIED');
  }return {...result,binaryRangeVersion:1};
 }
 if(action==='managed/file/download/part'){
  if(!/^[A-Za-z0-9_-]{1,200}$/.test(b.fileId||'')||!/^[a-f0-9]{64}$/.test(b.expectedSha256||'')||typeof b.expectedVersion!=='string'||b.expectedVersion.length<1||b.expectedVersion.length>150||!Number.isSafeInteger(b.offset)||b.offset<0||b.offset>=20*1024*1024||!Number.isSafeInteger(b.length)||b.length<1||b.length>512*1024)fail(400,'Invalid binary range');
  const item=await rangedBinary(m,b);
  if(b.offset>=item.sizeBytes)fail(400,'Binary range exceeds verified file');
  const bytes=item.bytes.subarray(b.offset,Math.min(item.sizeBytes,b.offset+b.length));
  return {success:true,schoolId:m.schoolId,binaryRangeVersion:1,fileId:item.fileId,sha256:item.sha256,version:item.version,sizeBytes:item.sizeBytes,offset:b.offset,nextOffset:b.offset+bytes.length,chunkSha256:createHash('sha256').update(bytes).digest('hex'),base64:bytes.toString('base64')};
 }
 if(action==='managed/file/download'){
  if(!/^[A-Za-z0-9_-]{1,200}$/.test(b.fileId||'')||!/^[a-f0-9]{64}$/.test(b.expectedSha256||'')||typeof b.expectedVersion!=='string'||b.expectedVersion.length<1||b.expectedVersion.length>150)fail(400,'Invalid binary download');
  const result=await signed(m,{action:'managed_binary_download',fileId:b.fileId,expectedSha256:b.expectedSha256,expectedVersion:b.expectedVersion});
  if(result.binaryDownloadVersion!==1||result.fileId!==b.fileId||result.sha256!==b.expectedSha256||result.version!==b.expectedVersion||typeof result.base64!=='string'||result.base64.length>28*1024*1024||!Number.isSafeInteger(result.sizeBytes)||result.sizeBytes<1||result.sizeBytes>20*1024*1024)fail(502,'Unverified binary download','BINARY_DOWNLOAD_UNVERIFIED');
  const bytes=Buffer.from(result.base64,'base64');if(bytes.length!==result.sizeBytes||createHash('sha256').update(bytes).digest('hex')!==b.expectedSha256)fail(502,'Binary content verification failed','BINARY_DOWNLOAD_UNVERIFIED');return result;
 }
 if(action==='managed/file/upload/resumable'){
  if(!['begin','status','part'].includes(b.operation)||!/^[A-Za-z0-9_-]{1,150}$/.test(b.uploadKey||'')||!/^[a-f0-9]{64}$/.test(b.sha256||'')||!Number.isSafeInteger(b.sizeBytes)||b.sizeBytes<1||b.sizeBytes>20*1024*1024||typeof b.name!=='string'||!b.name||b.name.length>200||!/^[-\w.+]+\/[-\w.+]+$/.test(b.mime||'')||b.mime.startsWith('application/vnd.google-apps.'))fail(400,'Invalid resumable school upload');
  const payload={action:'managed_upload_resumable',operation:b.operation,uploadKey:b.uploadKey,sha256:b.sha256,sizeBytes:b.sizeBytes,name:b.name,mime:b.mime};
  if(b.operation==='part'){
   if(!Number.isSafeInteger(b.offset)||b.offset<0||b.offset>=b.sizeBytes||typeof b.base64!=='string'||!b.base64||b.base64.length>700000||!/^[A-Za-z0-9+/]*={0,2}$/.test(b.base64)||!/^[a-f0-9]{64}$/.test(b.chunkSha256||''))fail(400,'Invalid upload chunk');
   const bytes=Buffer.from(b.base64,'base64');
   if(!bytes.length||bytes.length>512*1024||b.offset+bytes.length>b.sizeBytes||(b.offset+bytes.length<b.sizeBytes&&bytes.length%(256*1024)!==0)||createHash('sha256').update(bytes).digest('hex')!==b.chunkSha256)fail(400,'Invalid upload chunk');
   Object.assign(payload,{offset:b.offset,base64:b.base64,chunkSha256:b.chunkSha256});
  }
  const out=await signed(m,payload);
  if(out.uploadResumableVersion!==1||out.uploadKey!==b.uploadKey||out.sha256!==b.sha256||out.sizeBytes!==b.sizeBytes||typeof out.committed!=='boolean'||!Number.isSafeInteger(out.offset)||out.offset<0||out.offset>b.sizeBytes||out.committed&&out.offset!==b.sizeBytes||!out.committed&&out.offset===b.sizeBytes||out.committed&&!/^[A-Za-z0-9_-]{1,200}$/.test(out.fileId||''))fail(502,'Upload progress or completion is unverified','UPLOAD_ACK_UNVERIFIED');
  return {success:true,schoolId:m.schoolId,uploadResumableVersion:1,uploadKey:b.uploadKey,sha256:b.sha256,sizeBytes:b.sizeBytes,offset:out.offset,committed:out.committed,...(out.committed?{fileId:out.fileId,fileUrl:'https://drive.google.com/file/d/'+out.fileId+'/view'}:{})};
 }
 if(action==='managed/file/upload'){
  if(typeof b.base64!=='string'||b.base64.length>28*1024*1024||!b.base64.length||!/^[-\w.+]+\/[-\w.+]+$/.test(b.mime||'')||typeof b.name!=='string'||b.name.length>200)fail(400,'Invalid school file');if(b.uploadKey!==undefined&&!/^[A-Za-z0-9_-]{1,150}$/.test(b.uploadKey))fail(400,'Invalid upload key');return signed(m,{action:'managed_upload',name:b.name,mime:b.mime,base64:b.base64,...(b.uploadKey?{uploadKey:b.uploadKey}:{})});
 }
 if(action==='managed/file/read'){if(!/^[A-Za-z0-9_-]{1,200}$/.test(b.fileId||''))fail(400,'Invalid file ID');return signed(m,{action:'managed_file',fileId:b.fileId});}
 if(action==='managed/recycle'){
  if(b.operation==='list'){
   if(!COLLECTIONS.has(b.collection)||(b.after!==undefined&&typeof b.after!=='string')||(b.after||'').length>200)fail(400,'Invalid recycle inventory');
   return signed(m,{action:'managed_recycle',operation:'list',collection:b.collection,after:b.after||''});
  }
  if(!['restore','purge'].includes(b.operation)||! /^[A-Za-z0-9_-]{1,200}$/.test(b.fileId||'')||
     !/^[A-Za-z0-9_-]{16,100}$/.test(b.operationId||'')||typeof b.expectedRecordRevision!=='string'||b.expectedRecordRevision.length>100)fail(400,'Invalid recycle operation');
  const result=await signed(m,{action:'managed_recycle',operation:b.operation,fileId:b.fileId,operationId:b.operationId,expectedRecordRevision:b.expectedRecordRevision});
  invalidate(m.schoolId);return result;
 }
 if(action==='managed/disaster/readback'){
  if(m.schoolId!=='vs-db8afb01a3be46a983c8284714d06e5d')fail(403,'Disaster readback is isolated TEST only');
  if(!/^[a-f0-9]{64}$/.test(b.operationId||'')||!/^[A-Za-z0-9_-]{1,200}$/.test(b.fileId||''))fail(400,'Invalid disaster readback');
  const result=await signed(m,{action:'managed_disaster_readback',operationId:b.operationId,fileId:b.fileId});
  const bounded=(key,max)=>Number.isSafeInteger(result[key])&&result[key]>=0&&result[key]<=max;
  if(result.readbackVersion!==1||result.operationId!==b.operationId||result.readOnly!==true||result.activeStorageChanged!==false||
     result.scope!=='completed_rehearsal_rows_and_bytes'||!['records','binaries','verified'].includes(result.phase)||
     typeof result.complete!=='boolean'||typeof result.verified!=='boolean'||
     !['recordCount','rowCount','checkedRows'].every(key=>bounded(key,1000000))||
     !['binaryCount','checkedBinaries'].every(key=>bounded(key,1000))||result.recordCount>result.rowCount||
     result.checkedRows>result.rowCount||result.checkedBinaries>result.binaryCount||
     !['startedAt','observedAt','verifiedAt'].every(key=>bounded(key,now()+300000))||result.startedAt<=0||result.observedAt<result.startedAt||
     result.verified!==result.complete||result.complete!==(result.phase==='verified')||result.complete&&(result.checkedRows!==result.rowCount||
       result.checkedBinaries!==result.binaryCount||result.verifiedAt<result.startedAt||result.verifiedAt>result.observedAt)||
     !result.complete&&result.verifiedAt!==0)fail(502,'Unverified disaster readback','SCRIPT_RESPONSE_INVALID');
  return result;
 }
 if(action==='managed/disaster'){
  if(m.schoolId!=='vs-db8afb01a3be46a983c8284714d06e5d')fail(403,'Disaster rehearsal is isolated TEST only');
  if(!['backup','rehearse'].includes(b.operation)||!/^[a-f0-9]{64}$/.test(b.operationId||'')||
     b.operation==='rehearse'&&!/^[A-Za-z0-9_-]{1,200}$/.test(b.fileId||'')||b.operation==='backup'&&b.fileId!==undefined)fail(400,'Invalid disaster operation');
  return signed(m,{action:'managed_disaster',operation:b.operation,operationId:b.operationId,...(b.operation==='rehearse'?{fileId:b.fileId}:{})});
 }
 if(action==='managed/backup/snapshot')return signed(m,{action:'managed_backup_snapshot',schoolId:m.schoolId});
 if(action==='managed/backup')return signed(m,{action:'managed_backup'});
 if(action==='managed/restore'){if(!/^[A-Za-z0-9_-]{1,200}$/.test(b.fileId||''))fail(400,'Invalid backup file ID');return signed(m,{action:'managed_restore',fileId:b.fileId});}
 fail(400,'Unknown managed school operation');
 };
 handler.syncReadMetrics=()=>({hits:viewHits,misses:viewMisses,entries:readViews.size,bytes:readBytes,ttlMillis:5000});
 handler.drainAttendance=queue.drain;handler.attendanceMetrics=queue.metrics;handler.setAttendanceWake=wake=>{attendanceWake=wake;};
 return handler;
}
module.exports={createManagedSchools,scriptUrl,protect,unprotect,clean,COLLECTIONS};
