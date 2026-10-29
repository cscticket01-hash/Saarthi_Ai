const {createRepairKnowledge}=require('./repair-knowledge');
const {createCloudflareDelivery}=require('./cloudflare-delivery');
const {createProviderPressure,retryAfterMillis,firebaseQuota,quotaError}=require('./provider-pressure');
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
function createManagedSchools({repairKnowledgeOptions={},cloudflareAllDataEnabled=false,providerPressureJournal=null,googleQuotaScopes={},changeFeedIdleGraceMillis=0,deviceAccessEnforced=false,deviceManagementEnabled=false,deviceEnrollmentEnabled=false,deviceOfflinePrivateKey,deviceStore,studentImportEnabled=false,cardIssueEnabled=false,cardReaderEnforced=false,cardReaderPrivateKey,auth,db,projectId,encryptionKey,fetchImpl=fetch,now=Date.now,cloudflareSync=null,attendanceStore,attendanceCollection='attendance_outbox',messaging,scheduleHint=callback=>setTimeout(callback,250),pushDiagnostics=entry=>console.info(JSON.stringify(entry)),monitor=async()=>({available:false,reason:'Monitoring access has not been configured'})}){
 const windowsTheme=createWindowsTheme({db,now});
 const repairKnowledge=createRepairKnowledge({...repairKnowledgeOptions,db,now});
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
 const mobileStates=new Map(),storageStates=new Map(),developerViews=new Map(),readViews=new Map(),uploadCapabilities=new Map();
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
 const queue=createAttendanceQueue({store:legacyAttendanceStore,now,deliver:deliverAttendance,retryAtForSchool:school=>googlePressure.retryAt(googleQuotaScopes[school]||school,'SCRIPT_QUOTA_EXCEEDED')});
 const edgeEnabled=school=>cloudflareSync?.enabled(school)===true;
 const allEdge=school=>cloudflareAllDataEnabled===true&&edgeEnabled(school);
 const edgeDelivery=cloudflareSync?createCloudflareDelivery({edge:cloudflareSync,now}):null;
 const edgeQueue=(school,lane)=>createAttendanceQueue({store:cloudflareSync.attendanceStore(school,lane),now,deliver:deliverAttendance,retryAtForSchool:id=>googlePressure.retryAt(googleQuotaScopes[id]||id,'SCRIPT_QUOTA_EXCEEDED')});
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
  if(allEdge(m.schoolId)&&m.edgeDeliveryVersion===1){
   if(body.action==='managed_records'&&body.collection!=='school_notices'&&['write','delete'].includes(body.operation))return edgeDelivery.record(m.schoolId,body);
   if(body.action==='managed_records_batch')return edgeDelivery.record(m.schoolId,body);
   if(['managed_upload_resumable','managed_upload'].includes(body.action)){
    const capability=await cachedRead(uploadCapabilities,m.schoolId,()=>signedRequest(m,{action:'managed_health'}));
    // Older protocol-2 Scripts can still support only verified full uploads.
    // Do not accept bytes into a delivery lane they cannot drain.
    if(capability.storageReady===true&&capability.uploadResumableVersion===1)
     return body.action==='managed_upload_resumable'?edgeDelivery.file(m.schoolId,body):edgeDelivery.wholeFile(m.schoolId,body);
   }
  }

  if(edgeEnabled(m.schoolId)&&body.action==='managed_records'&&body.collection==='school_notices'&&body.operation!=='read'&&(body.syncProtocol!==2||!['write','delete'].includes(body.operation)))fail(409,'Cloudflare notice writes require versioned sync','SYNC_PROTOCOL_REQUIRED');
  if(edgeEnabled(m.schoolId)&&body.action==='managed_records'&&body.collection==='school_notices'&&body.syncProtocol===2&&['read','write','delete'].includes(body.operation)){
   if(body.operation!=='read'){const ack=await cloudflareSync.writeNotice(m.schoolId,body,()=>noticeBaseline(m.schoolId));invalidate(m.schoolId);await changeHint(m.schoolId,'school_notices',body.id);return ack;}
   const state=await cloudflareSync.notices(m.schoolId,()=>noticeBaseline(m.schoolId));const records=body.id?{...(state.records[body.id]?{[body.id]:state.records[body.id]}:{})}:state.records;return {success:true,schoolId:m.schoolId,syncProtocol:2,collectionRevision:state.revision,records:body.knownRevision===state.revision?{}:records,...(body.id?{pointRead:true}:{}),...(body.knownRevision===state.revision?{unchanged:true}:{}),cloudflareAccepted:true};
  }
  const ticket=await deliveryBudget(syncDelivery.prepare(m.schoolId,body));
  try{const result=await signedRequest(m,body);
   if(body.action==='managed_health'){
    if(uploadCapabilities.size>=5000)uploadCapabilities.delete(uploadCapabilities.keys().next().value);
    uploadCapabilities.set(m.schoolId,{promise:Promise.resolve(result),until:now()+30000});
   }
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
 if(!googleQuotaScopes||Array.isArray(googleQuotaScopes)||typeof googleQuotaScopes!=='object'||Object.entries(googleQuotaScopes).some(([school,owner])=>!SCHOOL.test(school)||typeof owner!=='string'||!/^[a-f0-9]{64}$/.test(owner)))throw Error('Invalid trusted Google quota scopes');
 const googlePressure=createProviderPressure({now,journal:providerPressureJournal,isQuotaError:error=>error?.code==='SCRIPT_QUOTA_EXCEEDED'});
 async function signedRequest(m,body){return googlePressure.run(googleQuotaScopes[m.schoolId]||m.schoolId,'SCRIPT_QUOTA_EXCEEDED',()=>signedRequestRaw(m,body));}
 async function signedRequestRaw(m,body){const started=performance.now();const s=await cachedRead(storageStates,m.schoolId,()=>db.doc('school_storage_private/'+m.schoolId).get());if(!s.exists||s.data().ready!==true)fail(409,'Developer must connect this school Apps Script first','SCHOOL_STORAGE_NOT_CONNECTED');const c=s.data(),payload=JSON.stringify(body),timestamp=now(),nonce=randomBytes(24).toString('hex'),signature=createHmac('sha256',unprotect(c.secret,encryptionKey)).update(m.schoolId+'\n'+timestamp+'\n'+nonce+'\n'+payload).digest('hex');let url=scriptUrl(c.url);const scriptStarted=performance.now(),scriptSignal=AbortSignal.timeout(90000);let response=await fetchScript(url,{method:'POST',redirect:'manual',headers:{'Content-Type':'application/json'},body:JSON.stringify({schoolId:m.schoolId,timestamp,nonce,payload,signature}),signal:scriptSignal});const redirects=new Set([301,302,303,307,308]),seen=new Set();let hops=0;while(redirects.has(response.status)){if(hops++>=5)fail(502,'School script redirect limit exceeded','SCRIPT_REDIRECT_LIMIT');let target;try{const location=response.headers.get('location');if(!location)throw Error();target=new URL(location,url);}catch{fail(502,'School script redirect rejected','SCRIPT_REDIRECT_REJECTED');}if(target.protocol!=='https:'||target.hostname!=='script.googleusercontent.com'||target.username||target.password||target.port)fail(502,'School script redirect rejected','SCRIPT_REDIRECT_REJECTED');if(seen.has(target.href))fail(502,'School script redirect limit exceeded','SCRIPT_REDIRECT_LIMIT');seen.add(target.href);url=target.href;response=await fetchScript(url,{method:'GET',redirect:'manual',signal:scriptSignal},'redirect');}if(response.status===429)throw quotaError('SCRIPT_QUOTA_EXCEEDED',retryAfterMillis(response.headers?.get('retry-after'),now())||60000);if(!response.ok)fail(502,'School script request failed','SCRIPT_HTTP_ERROR');const raw=await readScript(response);if(raw.length>30*1024*1024)fail(502,'School script response is too large');let out;try{out=JSON.parse(raw);}catch{fail(502,'School script returned invalid JSON','SCRIPT_INVALID_RESPONSE');}if(out.schoolId!==m.schoolId)fail(502,'School script identity or operation failed','SCRIPT_IDENTITY_MISMATCH');if(out.success!==true){if(!out.code&&typeof out.message==='string'){if(/quota|too many times|limit exceeded/i.test(out.message))out.code='SCRIPT_QUOTA_EXCEEDED';else if(/lock|timed out|timeout/i.test(out.message))out.code='SCRIPT_TIMEOUT';}if(out.code==='SCRIPT_QUOTA_EXCEEDED')fail(429,'Google school storage quota is temporarily exceeded; pending changes are retained','SCRIPT_QUOTA_EXCEEDED');if(out.code==='SCRIPT_TIMEOUT')fail(504,'School storage is busy; retry Sync. Existing data and pending changes are retained','SCRIPT_TIMEOUT');if(['SCRIPT_SHEET_RECOVERY_REQUIRED','SCRIPT_STUDENT_PARENT_PENDING'].includes(out.code))fail(503,'Verified local Sheet recovery required before editing',out.code);if(out.code==='SCRIPT_EXTERNAL_EDIT_REVIEW_REQUIRED')fail(409,'External Sheet edit requires review',out.code);if(['SCRIPT_RECOVERY_MISMATCH','SCRIPT_STUDENT_GENERATION_DELETED','SCRIPT_SYNC_STATE_IDENTITY','SCRIPT_SYNC_STATE_UNAVAILABLE'].includes(out.code))fail(409,'School record recovery needs review',out.code);if(['SCRIPT_BLANK_SCHOOL_PROFILE','SCRIPT_EMPTY_PROFILE_OVERWRITE','SCRIPT_INVALID_SYNC_OPERATION'].includes(out.code))fail(422,'School record validation failed; original retained',out.code);if(out.code==='SCRIPT_DOCUMENT_REVISION_CONFLICT'||out.message==='Newer cloud document retained; resolve version conflict')fail(409,'Document version conflict; both copies retained','SCRIPT_DOCUMENT_REVISION_CONFLICT');if(out.message==='Student class/section/roll conflict')fail(409,'Student class/section/roll conflict','STUDENT_SLOT_CONFLICT');if(out.message==='Record revision conflict')fail(409,'Record revision conflict','RECORD_REVISION_CONFLICT');if(out.message==='Sync operation ID conflict')fail(409,'Sync operation ID conflict','OPERATION_ID_CONFLICT');if(body.action==='managed_mobile'&&out.message==='Student attendance is outside the school schedule')fail(400,out.message,'ATTENDANCE_SCHEDULE_CLOSED');const safe=['This QR is invalid or has not synced to this school. Ask the school to sync or regenerate the ID card.','Ask your school to regenerate this ID card.','Class, roll number or date of birth is incorrect','School session expired. Scan your ID again.','School session expired','School login required','School identity mismatch','This QR does not belong to the active school','School record or ID card was changed; scan again'];if(body.action==='managed_mobile'&&safe.includes(out.message))fail(403,out.message);const codes={'School data organization in progress; retry Sync. Pending data retained':'SCRIPT_MIGRATION_PENDING','Migration conflict; both versions retained':'SCRIPT_MIGRATION_CONFLICT','Verified school tab is missing; operator recovery required':'SCRIPT_MISSING_MIGRATED_TAB','School record verification failed':'SCRIPT_RECORD_VERIFY_FAILED','Managed storage not prepared':'SCRIPT_STORAGE_NOT_PREPARED'};fail(502,'School script identity or operation failed',codes[out.message]||(['SCRIPT_ROOT_IDENTITY_MISMATCH','SCRIPT_WORKBOOK_IDENTITY_MISMATCH','SCRIPT_WORKBOOK_REVIEW_REQUIRED','SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED','SCRIPT_FOREIGN_RECORD_REJECTED','SCRIPT_INVALID_SYNC_OPERATION','SCRIPT_DOCUMENT_REVISION_REQUIRED','SCRIPT_DOCUMENT_REVISION_CONFLICT','SCRIPT_MIGRATION_CONFLICT','SCRIPT_MISSING_MIGRATED_TAB','SCRIPT_RECORD_VERIFY_FAILED','SCRIPT_STORAGE_NOT_PREPARED','SCRIPT_MIGRATION_PENDING','SCRIPT_PERMISSION_DENIED','SCRIPT_QUOTA_EXCEEDED','SCRIPT_TIMEOUT','SCRIPT_TYPE_ERROR','SCRIPT_PARSE_ERROR'].includes(out.code)?out.code:'SCRIPT_OPERATION_FAILED'));}return {...out,syncTiming:{brokerPreparationMillis:Math.round(scriptStarted-started),scriptRoundTripMillis:Math.round(performance.now()-scriptStarted)}};}
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
  if(!edgeEnabled(b.schoolId)||!cloudflareSync.verify(b,req.headers||{})||! /^(?:attendance-[a-f0-9]{2}|notices|records|file-[a-f0-9]{64})$/.test(b.lane||''))fail(403,'Cloudflare delivery authorization required');
  let result;
  if(b.lane==='notices'||b.lane==='records'||/^file-[a-f0-9]{64}$/.test(b.lane||'')){
   const state=await mobileState(b.schoolId),e={...state.entitlement};
   if(!state.school||!e.active||e.blocked||state.school.deletedAt)fail(403,'School is inactive');
   if(e.status!=='trial'){if(!state.licence||state.licence.revoked||state.licence.schoolId!==b.schoolId)fail(403,'School licence inactive');e.expiresAt=Number(state.licence.expiresAt?.toMillis?.()??state.licence.expiresAt);}
   const m={schoolId:b.schoolId,entitlement:e};if(!lease(m).allowed||e.status!=='trial'&&!e.activated)fail(403,'School licence inactive');
   if(b.lane==='notices')result=await cloudflareSync.drainNotices(b.schoolId,body=>signedRequest(m,body));
   else result=await edgeDelivery.drain(b.schoolId,b.lane,async body=>{
    const tickets=body.action==='managed_records_batch'?await Promise.all(body.operations.map(op=>syncDelivery.prepare(m.schoolId,op))):[];
    const ack=await signed(m,body);
    if(body.action==='managed_records_batch'&&Array.isArray(ack.acknowledgements)){
     for(const receipt of ack.acknowledgements)if(receipt.success&&typeof receipt.recordRevision==='string'){
      const index=body.operations.findIndex(op=>op.operationId===receipt.operationId);if(index<0)continue;
      if(tickets[index])await syncDelivery.committed(tickets[index],receipt.recordRevision).catch(()=>{});
      else await changeHint(m.schoolId,body.operations[index].collection,body.operations[index].id);
     }
    }
    if(body.action==='managed_records'&&typeof ack.recordRevision==='string') {
     const data=body.data||{};const owner=['students_directory','teachers_directory'].includes(body.collection)?{personId:data.mobileStableId||body.id,role:body.collection==='students_directory'?'student':'teacher'}:data.personId?{personId:data.personId,role:data.ownerRole||'student'}:undefined;
     void notifyChanged(m.schoolId,body.operationId,false,owner).catch(()=>{});
    }
    invalidate(m.schoolId);return ack;
   });
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
  const admin=await developer(req),id=b.schoolId;
  if(action==='developer/managed/repair-knowledge/status')return {success:true,...await repairKnowledge.status()};
  if(action==='developer/managed/repair-knowledge/publish')return {success:true,...await repairKnowledge.publish(b.publication,admin.uid)};
  if(action==='developer/managed/theme/get')return {success:true,theme:await windowsTheme.read()};if(action==='developer/managed/theme/save')return {success:true,theme:await windowsTheme.save(b.theme,admin.uid)};if(action==='developer/managed/create'){
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
 m.edgeDeliveryVersion=b.edgeDeliveryVersion===1?1:0;
 const deviceDecision=await deviceAccess.authorize({req,body:b,identity:m,entitlement:lease(m)});if(deviceDecision.handled)return deviceDecision.result;
 if(action==='managed/repair-knowledge/pull'){if(!lease(m).allowed)fail(403,'School licence is inactive');return {success:true,schoolId:m.schoolId,...await repairKnowledge.pull(m,b.observation||{})};}
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
 uploadCapabilities.delete(m.schoolId);invalidate(m.schoolId);
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
 if(action==='managed/cloudflare/operation'){
  if(!edgeEnabled(m.schoolId))fail(503,'Cloudflare delivery is not enabled','EDGE_DELIVERY_DISABLED');
  const until=Date.now()+Math.min(20000,Math.max(0,Number(b.waitMillis)||0));
  let result;
  do {result=await edgeDelivery.status(m.schoolId,b.lane,b.id);if(!result.delivery||Date.now()>=until)break;await new Promise(resolve=>setTimeout(resolve,1000));}while(true);
  return result;
 }
 if(action==='managed/storage/quota')return signed(m,{action:'managed_storage_quota',schoolId:m.schoolId});
 if(action==='managed/storage/check')return {...await signed(m,{action:'managed_health',...(b.profilePhoto===true?{profilePhoto:true}:{})}),brokerEdgeDeliveryVersion:allEdge(m.schoolId)?1:0,brokerUploadResumableVersion:1,brokerSheetIntegrityAuditVersion:1,brokerRecordSyncVersion:2,brokerRecordWriteBatchVersion:1,brokerRecordDeltaRecordsVersion:1,brokerChangeHeadsVersion:1,brokerChangeFeedVersion:changeFeed.enabled?1:0,brokerChangeFeedReplayVersion:changeFeed.enabled?1:0,brokerDisasterRehearsalVersion:5,brokerDisasterReadbackVersion:1};
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
    return {...op,data,operationId:canonicalHa…55795 tokens truncated…      _dispatch.request(_nextRetry!.difference(DateTime.now()));
          }
          state.value = SchoolCloudState.syncPending;
          return;
        }
        await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
          () => FirebaseFirestore.instance
              .collection('_windows_sync_status')
              .doc('last')
              .set({
                'successfulAt': DateTime.now().millisecondsSinceEpoch,
                if (completedReconciliation)
                  'checkpointAt': DateTime.now().millisecondsSinceEpoch,
                if (!completedReconciliation && lastVerifiedCheckpoint != null)
                  'checkpointAt':
                      lastVerifiedCheckpoint!.millisecondsSinceEpoch,
              }),
        );
        lastSuccessfulSync = DateTime.now();
        if (completedReconciliation) {
          lastVerifiedCheckpoint = lastSuccessfulSync;
          _schedule.armCheckpoint(_lastIntegrityAttempt ?? DateTime.now());
        }
        _failures = 0;
        _nextRetry = null;
        state.value = SchoolCloudState.synced;
        return;
      }
      final firebaseStatus = await WindowsFirebaseRemote.status();

      String? projectId;
      String? idToken;

      if (firebaseStatus.authenticated &&
          firebaseStatus.projectId.trim().isNotEmpty) {
        projectId = firebaseStatus.projectId.trim();
        idToken = await WindowsFirebaseRemote.freshIdToken();

        // Never sync into a profile that no longer matches the live Firebase
        // connection. This protects against a connection switch racing a timer.
        if (_activeFirebaseProject.isNotEmpty &&
            projectId != _activeFirebaseProject) {
          unawaited(activateCurrentConnections(allowPairing: false));
          return;
        }

        _admitBatch();
        await _pushFirebaseOutbox(projectId: projectId, idToken: idToken);
        _admitBatch();
        await _pullFirebase(projectId: projectId, idToken: idToken);
      }

      final scriptUrl = await _googleScriptUrl();
      if (_activeGoogleUrl.isNotEmpty && scriptUrl != _activeGoogleUrl) {
        unawaited(activateCurrentConnections(allowPairing: false));
        return;
      }

      if (scriptUrl.isNotEmpty && central.isEmpty) {
        _admitBatch();
        await _pullGoogleSnapshot(scriptUrl);
      }

      if (scriptUrl.isNotEmpty && central.isEmpty) {
        _admitBatch();
        await WindowsBackendBridge.flushPending(
          canAdmit: () => !isPaused,
          respectBackoff: true,
          onActivity: _recordActivity,
        );
      }

      if (central['managed'] == true) {
        _admitBatch();
        await WindowsBackendBridge.flushDocumentPending(
          canAdmit: () => !isPaused,
          respectBackoff: true,
          onActivity: _recordActivity,
        );
      }

      _admitBatch();
      lastSuccessfulSync = DateTime.now();
      if (_activeProfileId == syncOrigin) state.value = SchoolCloudState.synced;
    } on _SyncAdmissionPaused {
      // A safe boundary was reached. Pending operations and ACKs remain intact.
    } catch (e) {
      if (_activeProfileId != syncOrigin) return;
      lastError = e.toString();
      recoveryDecision = windowsSyncRecovery(e);
      _failures++;
      final learnedFloor=WindowsSharedRepairKnowledge.value('retry_floor',_activeSchoolSyncId,
        category:recoveryDecision!.kind.name);
      final originalDelay=recoveryDecision!.delay(_failures);
      final retryDelay=learnedFloor!=null && originalDelay<Duration(seconds:learnedFloor)
        ? Duration(seconds:learnedFloor) : originalDelay;
      _nextRetry = recoveryDecision!.retry
          ? syncRetryDeadline(now: DateTime.now(), previous: _nextRetry,
              delay: retryDelay)
          : null;
      if (recoveryDecision!.kind == SyncFailureKind.quota) {
        _quotaRetryAt = _nextRetry;
        try {
          await FirebaseFirestore.instance.collection('_windows_sync_status').doc('provider-pressure').set({
            'version': 1, 'schoolId': _activeSchoolSyncId,
            'observedAtMillis': DateTime.now().millisecondsSinceEpoch,
            'retryAtMillis': _nextRetry!.millisecondsSinceEpoch,
          });
        } catch (_) { /* In-memory admission stays closed if diagnostic persistence fails. */ }
      }
      if (_activeProfileId != syncOrigin) return;
      if (recoveryHistory.length >= 100) recoveryHistory.removeAt(0);
      recoveryHistory.add({
        'atUtc': DateTime.now().toUtc().toIso8601String(),
        'category': recoveryDecision!.kind.name,
        'attempt': _failures,
        'outcome': recoveryDecision!.retry
            ? 'retained_for_retry'
            : 'retained_for_review',
      });
      try {
        await _persistRepairHistory(syncOrigin);
      } catch (_) {
        /* A failed diagnostic write never removes the durable queue. */
      }
      if (_activeProfileId == syncOrigin)
        state.value = SchoolCloudState.syncError;
    } finally {
      watch.stop();
      metrics['reconciliationMicros'] = watch.elapsedMicroseconds;
      _checkingCloud = false;
      _syncing = false;
      if (isPaused && _activeProfileId == syncOrigin)
        state.value = SchoolCloudState.syncPending;
      await refreshDetails();
      if ((lastError != null &&
              recoveryDecision?.retry == true &&
              _failures <= 5) ||
          _rerunRequested ||
          (lastError == null &&
              (_remoteCollections.isNotEmpty ||
                  _remoteRecordIds.isNotEmpty ||
                  _remoteResetPending ||
                  _pendingIdInputs.isNotEmpty))) {
        final independentMutation =
            _rerunRequested && recoveryDecision?.independentRecords == true;
        _rerunRequested = false;
        scheduleSoon(
          localMutation: independentMutation,
          delay: lastError == null
              ? const Duration(milliseconds: 250)
              : schoolRetryDelay(_failures),
        );
      }
    }
  }

  bool _manualSync = false;

  /// Guardian may repair the owner's local timer, never its queue or ACKs.
  bool get automaticScheduleExpected =>
      _initialized &&
      automaticSyncEnabled &&
      !_syncBlocked &&
      !_resetPaused &&
      !isPaused &&
      _activeSchoolSyncId.isNotEmpty &&
      FirebaseFirestore.instance.activeProfileId == _activeProfileId;
  bool get automaticScheduleRunning =>
      _schedule.reconciliation?.isActive == true;
  bool get retryDispatchExpected =>
      automaticScheduleExpected &&
      !_syncing &&
      _activating == 0 &&
      canRestoreOwnerDispatch(
        retryAllowed: recoveryDecision?.retry != false,
        admittedAt: _dispatch.scheduledAt,
        nextRetry: _nextRetry,
        quotaRetry: _quotaRetryAt,
      );
  bool get retryDispatchRunning => _dispatch.running;
  bool get checkpointTimerExpected =>
      automaticScheduleExpected && !_syncing && _schedule.checkpointExpected;
  bool get checkpointTimerRunning => _schedule.checkpointRunning;
  void repairRetryDispatch({required String school, required String profile}) {
    if (!retryDispatchExpected ||
        school != _activeSchoolSyncId ||
        profile != _activeProfileId) {
      throw StateError('Owner dispatch repair is not admitted.');
    }
    // Restores the captured deadline only. It does not call syncNow, reset
    // backoff, select a queue item or authorize a business retry.
    _dispatch.repair();
  }

  void repairCheckpointTimer({
    required String school,
    required String profile,
  }) {
    if (!checkpointTimerExpected ||
        school != _activeSchoolSyncId ||
        profile != _activeProfileId) {
      throw StateError('Owner checkpoint timer repair is not admitted.');
    }
    _schedule.repairCheckpoint();
  }

  void repairAutomaticSchedule({
    required String school,
    required String profile,
  }) {
    if (!automaticScheduleExpected ||
        school != _activeSchoolSyncId ||
        profile != _activeProfileId) {
      throw StateError('Automatic scheduling is paused or the school changed.');
    }
    if (automaticScheduleRunning) return;
    // No immediate sync, backoff reset, pause override or business submission.
    // Subsequent timer ticks still enter scheduleSoon's owner admission policy.
    _schedule.repairReconciliationTimer(reconciliationInterval);
  }

  Future<void> setAutomaticSync(bool enabled) async {
    final origin = _activeProfileId;
    await FirebaseFirestore.instance
        .collection('_windows_sync_status')
        .doc('settings')
        .set({'automaticSync': enabled}, const SetOptions(merge: true));
    if (_activeProfileId != origin) return;
    automaticSyncEnabled = enabled;
    if (!enabled) {
      _dispatch.cancel();
      _remoteFeed.stop();
      _rerunRequested = false;
    } else
      scheduleSoon();
    await refreshDetails();
  }

  bool _rerunRequested = false;
  Future<void> requestSync() async {
    final generation = ++_pauseGeneration;
    final origin = _activeProfileId;
    final ref = FirebaseFirestore.instance
        .collection('_windows_sync_status')
        .doc('pause');
    // Persist cancellation before admitting resumed work.
    final write = _pauseWrite
        .catchError((Object _) {})
        .then((_) => ref.set({'pausedUntilMillis': 0, 'startedAtMillis': 0}));
    _pauseWrite = write;
    await write;
    if (_activeProfileId != origin || generation != _pauseGeneration) return;
    _pause.resume();
    _pauseTimer?.cancel();
    if (_syncing) _rerunRequested = true;
    _dispatch.cancel();
    _nextRetry = null;
    recoveryDecision = null;
    _failures = 0;
    _manualSync = true;
    try {
      await SchoolCloudEngine.instance.verify();
      await syncNow();
    } finally {
      _manualSync = false;
    }
  }

  /// One reviewed transient record/document retry through the same serial admission lane.
  /// It never clears a queue, replaces operation IDs, or resumes a user pause.
  Future<void> retryRecoverableOperation({
    required String queueCollection,
    required String queueId,
    required String expectedOperationId,
    required String expectedSchoolId,
  }) async {
    final documentRetry = queueCollection == '_windows_document_outbox';
    final operationField = documentRetry ? 'documentRevision' : 'operationId';
    if (!documentRetry && queueCollection != '_windows_firebase_outbox') {
      throw StateError('This queue requires its own verified recovery action.');
    }
    if (_syncing ||
        _activating > 0 ||
        _syncBlocked ||
        _resetPaused ||
        isPaused) {
      throw StateError(
        'Sync is busy, paused, or unavailable. Pending data retained.',
      );
    }
    _syncing = true;
    final db = FirebaseFirestore.instance, origin = _activeProfileId;
    bool valid(Map<String, dynamic>? row) =>
        row != null &&
        row[operationField] == expectedOperationId &&
        expectedOperationId.isNotEmpty &&
        row['schoolId'] == expectedSchoolId &&
        expectedSchoolId == _activeSchoolSyncId &&
        db.activeProfileId == origin &&
        _activeProfileId == origin &&
        row['syncState'] == 'retry' &&
        {'networkPath', 'timeout', 'server'}.contains(row['failureCategory']);
    try {
      final ref = db.collection(queueCollection).doc(queueId);
      final row = (await ref.get()).data();
      if (!valid(row))
        throw StateError('Retry is stale or requires administrator review.');
      final central = await CentralSchoolCloud.saved();
      if (central['managed'] != true ||
          central['schoolId'] != expectedSchoolId ||
          central['storageReady'] != true)
        throw StateError('Verified managed school storage required.');
      ManagedSchoolSession.verifyBuildEndpoint(
        central['endpoint']?.toString() ?? '',
      );
      await SchoolCloudEngine.instance.verify();
      if (SchoolCloudEngine.instance.identity != null &&
          !SchoolCloudEngine.instance.canOpen) {
        throw StateError('School authorization needs verification.');
      }
      _admitBatch();
      final health = await ManagedSchoolSession.callForSchool(
        expectedSchoolId,
        'managed/storage/check',
        {},
      );
      if (health['recordSyncVersion'] != 2 ||
          health['brokerRecordSyncVersion'] != 2) {
        throw StateError('School sync protocol verification required.');
      }
      if (!valid((await ref.get()).data()))
        throw StateError('Operation changed during retry preparation.');
      _admitBatch();
      bool admit() =>
          db.activeProfileId == origin &&
          _activeProfileId == origin &&
          !isPaused;
      if (documentRetry) {
        await WindowsBackendBridge.flushDocumentPending(
          canAdmit: admit,
          admitRow: (id, record) => id == queueId && valid(record),
          onActivity: _recordActivity,
        );
      } else {
        await _pushManagedOutbox(
          onlyQueueId: queueId,
          onlyOperationId: expectedOperationId,
          canAdmit: admit,
        );
      }
      final remaining = (await ref.get()).data();
      if (remaining?[operationField] == expectedOperationId) {
        throw StateError(
          'Operation remains pending; completion is unverified.',
        );
      }
    } finally {
      _checkingCloud = false;
      _syncing = false;
      await refreshDetails();
      if (_rerunRequested) {
        _rerunRequested = false;
        scheduleSoon();
      }
    }
  }

  Future<void> _pushManagedOutbox({
    String? onlyQueueId,
    String? onlyOperationId,
    bool Function()? canAdmit,
  }) async {
    if (onlyOperationId == null) {
      await SchoolPersonIdentity.preparePendingCreates(_activeSchoolSyncId,
        canAdmit: () => !isPaused && (canAdmit?.call() ?? true));
    }
    final batchReplies = onlyOperationId == null
        ? await WindowsFirebaseRemote.prepareManagedBatch(
            _activeSchoolSyncId,
            canAdmit: () => !isPaused && (canAdmit?.call() ?? true),
          )
        : <String, Object>{};
    if (batchReplies.isNotEmpty)
      metrics['recordWriteRequests'] = metrics['recordWriteRequests']! + 1;
    final canonical = <String, Map<String, dynamic>>{};
    await WindowsPendingSchoolSync.flush(
      profileId: _activeProfileId,
      onlyQueueId: onlyQueueId,
      onlyOperationId: onlyOperationId,
      respectBackoff: onlyOperationId == null,
      diagnoseUnclassified: _manualSync,
      onActivity: _recordActivity,
      canAdmit: () => !isPaused && (canAdmit?.call() ?? true),
      send: (c, id, op, data) async {},
      prepareVersioned: (ref, item) =>
          WindowsFirebaseRemote.prepareQueuedRecord(
            ref,
            item,
            _activeSchoolSyncId,
          ),
      canonicalForAck: (item) => canonical[item['operationId']],
      sendVersioned: (item) async {
        // Refill only after this bounded batch has been consumed. Dedicated
        // parent/file/delete paths retain the original serial admission rules.
        if (onlyOperationId == null &&
            batchReplies.isEmpty &&
            WindowsFirebaseRemote.recordWriteBatchSupported &&
            item['operation'] == 'set' &&
            !{
              'students_directory',
              'teachers_directory',
              'documents',
              'backups',
              'school_config',
            }.contains(item['collection'])) {
          final next = await WindowsFirebaseRemote.prepareManagedBatch(
            _activeSchoolSyncId,
            canAdmit: () => !isPaused && (canAdmit?.call() ?? true),
          );
          if (next.isNotEmpty) {
            batchReplies.addAll(next);
            metrics['recordWriteRequests'] =
                metrics['recordWriteRequests']! + 1;
          }
        }
        if (!batchReplies.containsKey(item['operationId']))
          metrics['recordWriteRequests'] = metrics['recordWriteRequests']! + 1;
        final queuedAt = item['queuedAt'];
        final queuedMillis = queuedAt is Timestamp
            ? queuedAt.millisecondsSinceEpoch
            : queuedAt is num
            ? queuedAt.toInt()
            : null;
        if (queuedMillis != null)
          metrics['lastQueueWaitMillis'] =
              (DateTime.now().millisecondsSinceEpoch - queuedMillis)
                  .clamp(0, 1 << 53)
                  .toInt();
        final origin = FirebaseFirestore.instance.activeProfileId;
        final school = _activeSchoolSyncId;
        final watch = Stopwatch()..start();
        final batched = batchReplies.remove(item['operationId']);
        if (batched is CentralCloudException) throw batched;
        final reply = await WindowsFirebaseRemote.syncManagedRecord(
          item,
          _activeSchoolSyncId,
          batchReply: batched is Map<String, dynamic> ? batched : null,
        );
        watch.stop();
        metrics['lastRecordAckMicros'] =
            batched is Map && batched['batchRequestMicros'] is int
            ? batched['batchRequestMicros'] as int
            : watch.elapsedMicroseconds;
        // Consuming an already-verified batch receipt is not another cloud RTT.
        if (batched == null)
          _sample('cloudAckMicros', watch.elapsedMicroseconds);
        if (queuedMillis != null)
          _sample('queueWaitMillis', metrics['lastQueueWaitMillis']!);
        final timing = reply['syncTiming'];
        if (timing is Map && timing['scriptRoundTripMillis'] is num) {
          metrics['lastScriptRoundTripMillis'] =
              (timing['scriptRoundTripMillis'] as num).toInt();
          _sample(
            'scriptRoundTripMillis',
            metrics['lastScriptRoundTripMillis']!,
          );
        }
        if (FirebaseFirestore.instance.activeProfileId != origin ||
            _activeSchoolSyncId != school) {
          throw StateError(
            'School changed before retaining verified dependencies.',
          );
        }
        final revision = reply['recordRevision'] as String;
        if (item['operation'] != 'delete' && reply['record'] is Map)
          canonical[item['operationId'] as String] = Map<String, dynamic>.from(
            reply['record'],
          );
        // Persist before the outbox ACK can remove its only recovery source.
        await WindowsSyncDependencies.retain(
          school,
          item['collection'] as String,
          item['documentId'] as String,
          revision,
        );
        return revision;
      },
    );
  }

  Future<Set<String>> _managedChangedCollections(
    String school,
    Future<Map<String, String>> Function(Map<String, String>) read, {
    required bool recordDeltas,
  }) async {
    final db = FirebaseFirestore.instance,
        origin = FirebaseFirestore.instance.activeProfileId;
    if (db.activeProfileIdentity['schoolSyncId'] != school) {
      throw StateError('School identity changed before change check.');
    }
    final known = <String, String>{};
    for (final col in _firebaseCollections.where((c) => c != 'backups')) {
      final prior =
          (await db
                  .collection('_windows_sync_manifest')
                  .doc(_manifestId('managed', col))
                  .get())
              .data();
      known[col] = windowsManagedCheckpointRevision(
        prior,
        recordDeltas: recordDeltas,
      );
    }
    if (db.activeProfileId != origin)
      throw StateError('School changed before change check.');
    final heads = await read(known);
    if (db.activeProfileId != origin ||
        db.activeProfileIdentity['schoolSyncId'] != school) {
      throw StateError('School changed during change check.');
    }
    return changedWindowsCollections(known, heads);
  }

  @visibleForTesting
  Future<Set<String>> changedManagedCollectionsForTesting(
    String school,
    Future<Map<String, String>> Function(Map<String, String>) read,
  ) => _managedChangedCollections(school, read, recordDeltas: true);

  @visibleForTesting
  Future<void> reconcileManagedCacheForTesting(
    String school,
    Future<Map<String, dynamic>> Function(Map<String, String>) read, {
    Set<String>? selectedCollections,
    bool verifyInventory = true,
  }) => _pullManagedChanges(
    schoolOverride: school,
    batchReader: read,
    verifyInventory: verifyInventory,
    selectedCollections: selectedCollections,
  );

  @visibleForTesting
  Future<void> reconcileManagedRecordDeltaForTesting(
    String school,
    Future<Map<String, dynamic>> Function(
      Map<String, String>,
      Map<String, Map<String, String>>,
    )
    read, {
    Set<String>? selectedCollections,
  }) => _pullManagedChanges(
    schoolOverride: school,
    recordBatchReader: read,
    verifyInventory: false,
    selectedCollections: selectedCollections,
  );

  @visibleForTesting
  Future<void> reconcileManagedPointTargetsForTesting(
    String school,
    Map<String, Set<String>> targets,
    Future<Map<String, dynamic>> Function(String, Set<String>) read,
  ) => _pullManagedChanges(
    schoolOverride: school,
    selectedCollections: targets.keys.toSet(),
    targetRecordIds: targets,
    pointReader: read,
    recordBatchReader: (a, b) async =>
        throw StateError('Verified baseline required for point read'),
  );

  Future<void> _pullManagedChanges({
    String? schoolOverride,
    Future<Map<String, dynamic>> Function(Map<String, String>)? batchReader,
    Future<Map<String, dynamic>> Function(
      Map<String, String>,
      Map<String, Map<String, String>>,
    )?
    recordBatchReader,
    bool? verifyInventory,
    Set<String>? selectedCollections,
    Map<String, Set<String>>? targetRecordIds,
    Future<Map<String, dynamic>> Function(String, Set<String>)? pointReader,
  }) async {
    _lastManagedApplyVerified = true;
    final db = FirebaseFirestore.instance,
        origin = db.activeProfileId,
        school = schoolOverride ?? _activeSchoolSyncId;
    if (db.activeProfileIdentity['schoolSyncId'] != school)
      throw StateError('School identity changed before recovery.');
    final audit = verifyInventory ?? false;
    if (!audit &&
        !_recordDeltasSupported &&
        batchReader == null &&
        recordBatchReader == null) {
      throw StateError(
        'Record-only sync requires the matching updated school Script and central backend. Pending data retained.',
      );
    }
    final collections = _firebaseCollections
        .where(
          (c) =>
              c != 'backups' &&
              (selectedCollections == null || selectedCollections.contains(c)),
        )
        .toList();
    final pendingAtRead =
        (await db.collection('_windows_firebase_outbox').get()).docs;
    final revisions = <String, String>{};
    final recordCheckpoints = <String, Map<String, String>>{};
    for (final collection in collections) {
      final prior =
          (await db
                  .collection('_windows_sync_manifest')
                  .doc(_manifestId('managed', collection))
                  .get())
              .data();
      if ((_recordDeltasSupported || recordBatchReader != null) &&
          !audit &&
          prior?['recordRevisions'] is Map) {
        recordCheckpoints[collection] = Map<String, String>.from(
          prior!['recordRevisions'] as Map,
        );
        for (final row in pendingAtRead) {
          final item = row.data();
          if (item['collection'] == collection &&
              item['syncState'] == 'conflict') {
            recordCheckpoints[collection]!.remove(item['documentId']);
          }
        }
      }
      final needsBaseline =
          !audit &&
          (_recordDeltasSupported || recordBatchReader != null) &&
          prior?['recordRevisions'] is! Map;
      if (needsBaseline && prior?['recordDeltaBaselineAttempted'] == true)
        throw StateError(
          'Verified record revision baseline unavailable; explicit inventory repair required.',
        );
      revisions[collection] = needsBaseline
          ? ''
          : audit
          ? managedRecoveryRevision(
              prior,
              (await db.collection(collection).get()).docs
                  .map((d) => d.id)
                  .toSet(),
              {
                ...pendingAtRead
                    .where((d) => d.data()['collection'] == collection)
                    .map((d) => d.data()['documentId'])
                    .whereType<String>(),
                if (collection == 'school_config') 'google_drive_account',
              },
            )
          : prior?['revision']?.toString() ?? '';
      if (recordCheckpoints.containsKey(collection) &&
          pendingAtRead.any(
            (row) =>
                row.data()['collection'] == collection &&
                row.data()['syncState'] == 'conflict',
          )) {
        // Keep every other record revision: only conflicted IDs are fetched.
        revisions[collection] = '';
      }
    }
    if (db.activeProfileId != origin)
      throw StateError('School changed during recovery inventory.');
    // A full-school Apps Script read holds one lock while opening every
    // category and checking its retained heads. Bound each request instead:
    // verified earlier categories survive a later timeout, and local mutations
    // can drain between groups without waiting for the whole school census.
    Map<String, dynamic>? batch;
    final exactCollections = <String>{
      for (final entry in (targetRecordIds ?? <String, Set<String>>{}).entries)
        if (entry.value.isNotEmpty &&
            entry.value.length <= 64 &&
            recordCheckpoints.containsKey(entry.key) &&
            (WindowsFirebaseRemote.recordPointReadSupported ||
                pointReader != null))
          entry.key,
    };
    final remainingCollections = revisions.keys
        .where((c) => !exactCollections.contains(c))
        .toList();
    for (final collection in collections) {
      // A new durable notice must not wait for every startup collection read.
      if (_rerunRequested) {
        _rerunRequested = false;
        _admitBatch();
        await _pushManagedOutbox();
      }
      _admitBatch();
      final manifest = db
          .collection('_windows_sync_manifest')
          .doc(_manifestId('managed', collection));
      if (!exactCollections.contains(collection) &&
          (_deltaBatchSupported ||
              batchReader != null ||
              recordBatchReader != null)) {
        if (batch == null || !batch.containsKey(collection)) {
          final group = <String, String>{
            for (final name in remainingCollections.take(2))
              name: revisions[name]!,
          };
          metrics['recordReadRequests'] = metrics['recordReadRequests']! + 1;
          batch = await (recordBatchReader != null
              ? recordBatchReader(group, {
                  for (final name in group.keys)
                    if (recordCheckpoints.containsKey(name))
                      name: recordCheckpoints[name]!,
                })
              : batchReader != null
              ? batchReader(group)
              : WindowsFirebaseRemote.readManagedBatch(
                  school,
                  group,
                  knownRecordRevisions: {
                    for (final name in group.keys)
                      if (recordCheckpoints.containsKey(name))
                        name: recordCheckpoints[name]!,
                  },
                ));
          if (db.activeProfileId != origin)
            throw StateError('School changed during reconciliation.');
          if (batch.length != group.length ||
              group.keys.any((name) => batch![name] is! Map))
            throw StateError('Incomplete school delta; checkpoint retained.');
          remainingCollections.removeRange(0, group.length);
        }
      } else {
        metrics['recordReadRequests'] = metrics['recordReadRequests']! + 1;
      }
      final result = exactCollections.contains(collection)
          ? <String, dynamic>{
              'syncProtocol': 2,
              'partialRecords': true,
              'collectionRevision': revisions[collection]!,
              'records': await (pointReader != null
                  ? pointReader(collection, targetRecordIds![collection]!)
                  : WindowsFirebaseRemote.readManagedPoints(
                      school,
                      collection,
                      targetRecordIds![collection]!,
                    )),
            }
          : batch != null && batch.containsKey(collection)
          ? Map<String, dynamic>.from(batch[collection] as Map)
          : await WindowsFirebaseRemote.readManagedChanges(
              school,
              collection,
              revisions[collection] ?? '',
            );
      if (db.activeProfileId != origin)
        throw StateError('School changed during reconciliation.');
      if (result['syncProtocol'] != 2 ||
          result['collectionRevision'] is! String ||
          result['records'] is! Map)
        throw StateError('Invalid authoritative recovery response.');
      if (result['partialRecords'] == true &&
          !recordCheckpoints.containsKey(collection))
        throw StateError('Incremental baseline missing.');
      if (result['unchanged'] == true) continue;
      final records = Map<String, dynamic>.from(result['records'] as Map);
      if (result['missingRecords'] is List &&
          batchReader == null &&
          recordBatchReader == null) {
        final restored = await recoverMissingSheetRecords(
          school,
          collection,
          result['missingRecords'] as List,
        );
        if (restored > 0) {
          _rerunRequested = true;
          scheduleSoon(localMutation: true);
        }
      }
      if (result['partialRecords'] == true &&
          result['missingRecords'] is List &&
          (result['missingRecords'] as List).isNotEmpty)
        throw StateError(
          'Missing Sheet records require verified recovery; checkpoint retained.',
        );
      // Validate the whole response before recording any inventory or applying it.
      if (records.values.any(
        (value) => value is! Map || value['schoolId'] != school,
      ))
        throw StateError('Foreign or invalid school inventory rejected.');
      final downloadable = records.entries
          .where(
            (entry) =>
                collection != 'school_config' ||
                entry.key != 'google_drive_account',
          )
          .length;
      final progress = db.collection('_windows_sync_downloads').doc(collection);
      var remaining = downloadable, verifiedDownloads = 0, blockedDownloads = 0;
      await progress.set({
        'schoolId': school,
        'collection': collection,
        'collectionRevision': result['collectionRevision'],
        'observedAt': DateTime.now().millisecondsSinceEpoch,
        'inventoryScope': 'records_only',
        'state': 'downloading',
        'remaining': remaining,
        'verified': 0,
        'blocked': 0,
      });
      final pending =
          (await db.collection('_windows_firebase_outbox').get()).docs;
      if (db.activeProfileId != origin)
        throw StateError('School changed during reconciliation.');
      final pendingById = {
        for (final row in pending.where(
          (row) => row.data()['collection'] == collection,
        ))
          row.data()['documentId']: row,
      };
      var processed = 0;
      final applyWatch = Stopwatch()..start();
      final entries = records.entries
          .where(
            (entry) =>
                collection != 'school_config' ||
                entry.key != 'google_drive_account',
          )
          .toList();
      for (var offset = 0; offset < entries.length; offset += 100) {
        final chunk = entries.skip(offset).take(100).toList();
        final incoming = <String, Map<String, dynamic>>{};
        for (final entry in chunk) {
          if (db.activeProfileId != origin)
            throw StateError('School changed during reconciliation.');
          final data = Map<String, dynamic>.from(entry.value as Map);
          if (data['schoolId'] != school)
            throw StateError('Foreign school manifest rejected.');
          if (data['id'] != null && data['id'] != entry.key)
            throw StateError('Cloud record identity mismatch.');
          data['id'] = entry.key;
          if (collection == 'students_directory' &&
              data['_syncRevision'] is String) {
            for (final generation in verifiedDeletedStudentGenerations(data)) {
              await db.applyVerifiedStudentDeletion(
                school,
                entry.key,
                generation,
                data['_syncRevision'],
              );
            }
          }
          final queued = pendingById[entry.key];
          if (queued != null &&
              ((data['_syncRevision'] ?? '') !=
                      (queued.data()['baseCloudRevision'] ?? '') ||
                  queued.data()['syncState'] == 'conflict')) {
            // Still compare the live operation inside the existing durable writer.
            await db.recordOutboxConflict(
              queued.reference,
              queued.data(),
              data,
            );
            if (automaticDuplicateReadback(queued.data(), data)) {
              final history =
                  (await db
                          .collection('_windows_sync_conflict_history')
                          .doc(queued.data()['operationId'] as String)
                          .get())
                      .data();
              if (db.activeProfileId != origin)
                throw StateError(
                  'School changed after duplicate reconciliation.',
                );
              if (history?['resolution'] ==
                      'automatic identical authenticated readback' &&
                  history?['verifiedCloud'] is Map &&
                  history!['verifiedCloud']['_syncRevision'] ==
                      data['_syncRevision']) {
                _recordActivity({
                  'schoolId': school,
                  'queueCollection': '_windows_firebase_outbox',
                  'queueId': queued.id,
                  'operationId': queued.data()['operationId'],
                  'collection': collection,
                  'documentId': entry.key,
                  'stage': 'duplicateReconciled',
                  'failureCategory': 'verifiedDuplicate',
                  'at': DateTime.now().millisecondsSinceEpoch,
                });
              }
            }
          }
          incoming[entry.key] = data;
        }
        await cacheVerifiedSheetRecords(school, collection, {
          for (final entry in incoming.entries)
            if (entry.value['_syncRevision'] is String) entry.key: entry.value,
        });
        if (db.activeProfileId != origin)
          throw StateError('School changed during reconciliation.');
        await db.applySyncedCollectionBatch(collection, incoming);
        // Read back after commit. A newer local edit is retained by the same
        // live queue guard and must not be counted as a verified download.
        for (final entry in incoming.entries) {
          final data = entry.value;
          if (await db.syncedDocumentMatches(
            db.collection(collection).doc(entry.key),
            data['_syncDeleted'] == true ? null : data,
          )) {
            verifiedDownloads++;
            remaining--;
          } else {
            blockedDownloads++;
          }
          processed++;
          if (processed % 50 == 0 || processed == downloadable) {
            await progress.set({
              'remaining': remaining,
              'verified': verifiedDownloads,
              'blocked': blockedDownloads,
              if (verifiedDownloads > 0)
                'lastVerifiedLocalReadbackAt':
                    DateTime.now().millisecondsSinceEpoch,
            }, const SetOptions(merge: true));
          }
        }
      }
      _sample('collectionApplyMicros', applyWatch.elapsedMicroseconds);
      // Missing IDs are not deletions: only explicit server tombstones delete.
      if (db.activeProfileId != origin)
        throw StateError('School changed during reconciliation.');
      final partial = result['partialRecords'] == true;
      if (partial && !recordCheckpoints.containsKey(collection))
        throw StateError('Incremental baseline missing.');
      final nextRecordRevisions = <String, String>{
        if (partial) ...recordCheckpoints[collection]!,
        for (final entry in records.entries)
          if ((entry.value as Map)['_syncRevision'] is String)
            entry.key: (entry.value as Map)['_syncRevision'] as String,
      };
      final priorManifest = partial ? (await manifest.get()).data() : null;
      final deletedIds = <String>{
        if (partial)
          ...((priorManifest?['deletedIds'] as List?) ?? [])
              .whereType<String>(),
      };
      for (final entry in records.entries) {
        if ((entry.value as Map)['_syncDeleted'] == true) {
          deletedIds.add(entry.key);
        } else {
          deletedIds.remove(entry.key);
        }
      }
      // Persist dependent work before advancing the record checkpoint. A crash
      // before this write leaves the old checkpoint and the delta is replayed.
      await WindowsSyncDependencies.retainMany(school, collection, {
        for (final entry in records.entries)
          if (WindowsSyncDependencies.relevant(collection, entry.key))
            entry.key:
                ((entry.value as Map)['_syncRevision'] as String?) ??
                result['collectionRevision'] as String,
      });
      await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
        () => manifest.set({
          'revision': result['collectionRevision'],
          'collection': collection,
          'ids': <String>{
            if (partial)
              ...((priorManifest?['ids'] as List?) ?? []).whereType<String>(),
            ...records.keys,
          }.toList(),
          'recordRevisions':
              records.values.every(
                (row) =>
                    row is Map &&
                    row['_syncRevision'] is String &&
                    (row['_syncRevision'] as String).isNotEmpty,
              )
              ? nextRecordRevisions
              : null,
          'recordDeltaBaselineAttempted': true,
          'deletedIds': deletedIds.toList(),
        }),
      );
      for (final id in records.keys) {
        _noteIdInput(collection, id);
      }
      if (remaining != 0) _lastManagedApplyVerified = false;
      await progress.set({
        'state': remaining == 0 ? 'verified' : 'needsReview',
        'finishedAt': DateTime.now().millisecondsSinceEpoch,
      }, const SetOptions(merge: true));
    }
  }

  Future<void> _pullFirebase({
    required String projectId,
    required String idToken,
  }) async {
    final pullProfile = FirebaseFirestore.instance.activeProfileId;
    final pending = await _firebasePendingKeys();

    for (final collection in _firebaseCollections) {
      _admitBatch();
      if (projectId != platformProjectId &&
          _firebaseCollections.indexOf(collection) >= 12)
        continue;
      if (FirebaseFirestore.instance.activeProfileId != pullProfile)
        throw StateError('School profile changed during sync.');
      final remote = await WindowsFirebaseRemote.readCollection(
        projectId: projectId,
        idToken: idToken,
        collection: collection,
      );

      if (FirebaseFirestore.instance.activeProfileId != pullProfile)
        throw StateError('School profile changed during sync.');
      final localSnapshot = await FirebaseFirestore.instance
          .collection(collection)
          .get();

      final local = <String, Map<String, dynamic>>{
        for (final doc in localSnapshot.docs)
          doc.id: Map<String, dynamic>.from(doc.data()),
      };

      final manifestRef = FirebaseFirestore.instance
          .collection('_windows_sync_manifest')
          .doc(_manifestId('firebase', collection));

      final manifest = await manifestRef.get();

      final oldIds = _stringSet(manifest.data()?['ids']);

      final remoteIds = remote.keys.toSet();

      for (final entry in remote.entries) {
        if (FirebaseFirestore.instance.activeProfileId != pullProfile)
          throw StateError('School profile changed during sync.');
        // Windows connection selector is authoritative for its own Drive URL.
        // A stale Firestore copy must never switch the active backend behind
        // the user's back or revive another school's Drive link.
        if (collection == 'school_config' &&
            entry.key == 'google_drive_account') {
          continue;
        }

        final key = _pendingKey(collection, entry.key);

        final localData = local[entry.key];

        if (pending.contains(key)) {
          // Local unsynced change wins until its
          // outbox has been pushed.
          continue;
        }

        if (localData == null) {
          await _remoteSetLocal(collection, entry.key, entry.value);
          continue;
        }

        final localMs = _modifiedMillis(localData);
        final remoteMs = _modifiedMillis(entry.value);

        if (localMs > 0 && remoteMs > 0 && localMs > remoteMs) {
          // Local is clearly newer. Re-writing the
          // same document records it in the outbox.
          await FirebaseFirestore.instance
              .collection(collection)
              .doc(entry.key)
              .set(localData);
          pending.add(key);
          continue;
        }

        final merged = <String, dynamic>{...localData, ...entry.value};

        await _remoteSetLocal(collection, entry.key, merged);
      }

      // A document that existed on Firebase in an
      // earlier successful snapshot but is absent now
      // is a confirmed remote deletion.
      final deletedRemote = oldIds.difference(remoteIds);

      for (final id in deletedRemote) {
        if (collection == 'school_config' && id == 'google_drive_account') {
          continue;
        }

        final key = _pendingKey(collection, id);

        if (pending.contains(key)) {
          continue;
        }

        await _remoteDeleteLocal(collection, id);
      }

      // Existing local-only documents on the first
      // sync must not be lost. Queue them to Firebase.
      for (final entry in local.entries) {
        if (remoteIds.contains(entry.key) || oldIds.contains(entry.key)) {
          continue;
        }

        final key = _pendingKey(collection, entry.key);

        if (pending.contains(key)) {
          continue;
        }

        await FirebaseFirestore.instance
            .collection(collection)
            .doc(entry.key)
            .set(entry.value);

        pending.add(key);
      }

      await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
        () => manifestRef.set(<String, dynamic>{
          'source': 'firebase',
          'collection': collection,
          'ids': remoteIds.toList()..sort(),
          'updatedAt': FieldValue.serverTimestamp(),
        }),
      );
    }
  }

  Future<Set<String>> _firebasePendingKeys() async {
    final snapshot = await FirebaseFirestore.instance
        .collection('_windows_firebase_outbox')
        .get();

    return snapshot.docs
        .map((doc) {
          final data = doc.data();
          return _pendingKey(
            data['collection']?.toString() ?? '',
            data['documentId']?.toString() ?? '',
          );
        })
        .where((value) {
          return !value.startsWith('\u0000');
        })
        .toSet();
  }

  Future<void> _pushFirebaseOutbox({
    required String projectId,
    required String idToken,
  }) => WindowsPendingSchoolSync.flush(
    profileId: FirebaseFirestore.instance.activeProfileId,
    respectBackoff: true,
    onActivity: _recordActivity,
    canAdmit: () => !isPaused,
    send: (collection, id, operation, data) async {
      if (operation == 'delete') {
        await WindowsFirebaseRemote.deleteDocument(
          projectId: projectId,
          idToken: idToken,
          collection: collection,
          documentId: id,
        );
      } else {
        await WindowsFirebaseRemote.writeDocument(
          projectId: projectId,
          idToken: idToken,
          collection: collection,
          documentId: id,
          data: data!,
        );
      }
    },
  );

  Future<String> _googleScriptUrl() {
    return WindowsExternalConnections.googleScriptUrl();
  }

  Future<void> _pullGoogleSnapshot(String scriptUrl) async {
    final response = await WindowsBackendBridge.post(
      Uri.parse(scriptUrl),
      headers: const <String, String>{
        'Content-Type': 'text/plain;charset=utf-8',
      },
      body: jsonEncode(const <String, dynamic>{
        'action': 'windows_sync_snapshot',
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return;
    }

    final decoded = jsonDecode(response.body);

    if (decoded is! Map) {
      return;
    }

    final result = Map<String, dynamic>.from(decoded);

    if (result['success'] != true || result['windowsLocalFallback'] == true) {
      return;
    }

    await _importGoogleList(
      sourceName: 'students',
      collection: 'students_directory',
      rawList: result['students'],
      idFor: (item) => _canonicalStudentDocumentId(item),
      coreFirebaseCollection: true,
    );

    await _importGoogleList(
      sourceName: 'teachers',
      collection: 'teachers_directory',
      rawList: result['teachers'],
      idFor: (item) => item['teacherId']?.toString().trim() ?? '',
      coreFirebaseCollection: true,
    );

    await _importGoogleList(
      sourceName: 'feePayments',
      collection: 'fee_payments',
      rawList: result['feePayments'],
      idFor: (item) => item['paymentId']?.toString().trim() ?? '',
      coreFirebaseCollection: true,
    );

    await _importGoogleList(
      sourceName: 'documents',
      collection: '_local_student_documents',
      rawList: result['documents'],
      idFor: (item) => item['documentId']?.toString().trim() ?? '',
      deleteMissing: true,
    );

    await _importGoogleList(
      sourceName: 'studentAttendance',
      collection: '_local_student_attendance',
      rawList: result['studentAttendance'],
      idFor: (item) => item['attendanceId']?.toString().trim() ?? '',
      deleteMissing: true,
    );

    await _importGoogleList(
      sourceName: 'teacherAttendance',
      collection: '_local_teacher_attendance',
      rawList: result['teacherAttendance'],
      idFor: (item) => item['attendanceId']?.toString().trim() ?? '',
      deleteMissing: true,
    );

    await _importGoogleList(
      sourceName: 'exams',
      collection: '_local_exam_center_exams',
      rawList: result['exams'],
      idFor: (item) => item['examId']?.toString().trim() ?? '',
      deleteMissing: true,
    );

    await _importGoogleList(
      sourceName: 'results',
      collection: '_local_exam_center_results',
      rawList: result['results'],
      idFor: (item) {
        final examId = item['examId']?.toString().trim() ?? '';
        final studentId = item['studentId']?.toString().trim() ?? '';

        if (examId.isEmpty || studentId.isEmpty) {
          return '';
        }

        return '${examId}_$studentId';
      },
      deleteMissing: true,
    );

    final profile = result['schoolProfile'];

    if (profile is Map) {
      await _mergeGoogleDocument(
        collection: 'school_config',
        documentId: 'school_profile_cache',
        remote: Map<String, dynamic>.from(profile),
        coreFirebaseCollection: true,
      );
    }
  }

  Future<void> _importGoogleList({
    required String sourceName,
    required String collection,
    required dynamic rawList,
    required String Function(Map<String, dynamic> item) idFor,
    bool coreFirebaseCollection = false,
    bool deleteMissing = false,
  }) async {
    if (rawList is! List) return;

    final remoteIds = <String>{};

    for (final raw in rawList) {
      if (raw is! Map) continue;

      final item = Map<String, dynamic>.from(raw);

      final id = idFor(item);

      if (id.isEmpty) continue;

      remoteIds.add(id);

      await _mergeGoogleDocument(
        collection: collection,
        documentId: id,
        remote: item,
        coreFirebaseCollection: coreFirebaseCollection,
      );
    }

    if (collection == 'students_directory' && remoteIds.isNotEmpty) {
      await _cleanupStudentAliases(remoteIds);
    }

    if (!deleteMissing) {
      return;
    }

    final manifestRef = FirebaseFirestore.instance
        .collection('_windows_sync_manifest')
        .doc(_manifestId('google', sourceName));

    final manifest = await manifestRef.get();

    final oldIds = _stringSet(manifest.data()?['ids']);

    for (final id in oldIds.difference(remoteIds)) {
      await _remoteDeleteLocal(collection, id);
    }

    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
      () => manifestRef.set(<String, dynamic>{
        'source': 'google',
        'collection': collection,
        'ids': remoteIds.toList()..sort(),
        'updatedAt': FieldValue.serverTimestamp(),
      }),
    );
  }

  String _normalizeStudentRoll(dynamic value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return '';

    if (RegExp(r'^\d+$').hasMatch(raw)) {
      final normalized = raw.replaceFirst(RegExp(r'^0+(?=\d)'), '');
      return normalized.isEmpty ? '0' : normalized;
    }

    return raw.toLowerCase();
  }

  int _studentClassNumber(dynamic value) {
    final raw = value?.toString() ?? '';
    return int.tryParse(raw.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  }

  String _canonicalStudentDocumentId(Map<String, dynamic> item) {
    final classValue = item['class'] ?? item['studentClass'];
    final rollValue = item['rollNo'] ?? item['roll'];
    final classNumber = _studentClassNumber(classValue);
    final roll = _normalizeStudentRoll(rollValue);

    if (classNumber <= 0 || roll.isEmpty) {
      return '';
    }

    return 'Class ${classNumber}_Roll_$roll';
  }

  Future<void> _cleanupStudentAliases(Set<String> canonicalRemoteIds) async {
    final snapshot = await FirebaseFirestore.instance
        .collection('students_directory')
        .get();

    for (final doc in snapshot.docs) {
      final data = doc.data();
      final canonicalId = _canonicalStudentDocumentId(data);

      if (canonicalId.isEmpty ||
          !canonicalRemoteIds.contains(canonicalId) ||
          doc.id == canonicalId) {
        continue;
      }

      // This is a real tracked delete on purpose. It removes old Firebase
      // aliases such as Class 1_Roll_01 after the canonical Roll_1 record
      // has been imported from Google.
      await doc.reference.delete();
    }
  }

  Future<void> _mergeGoogleDocument({
    required String collection,
    required String documentId,
    required Map<String, dynamic> remote,
    required bool coreFirebaseCollection,
  }) async {
    final ref = FirebaseFirestore.instance
        .collection(collection)
        .doc(documentId);

    final current = await ref.get();
    final local = current.data();

    if (local == null) {
      if (coreFirebaseCollection) {
        await ref.set(remote);
      } else {
        await _remoteSetLocal(collection, documentId, remote);
      }
      return;
    }

    final localMs = _modifiedMillis(local);
    final remoteMs = _modifiedMillis(remote);

    if (remoteMs > 0 && localMs > 0 && remoteMs < localMs) {
      return;
    }

    final merged = <String, dynamic>{...local, ...remote};

    if (coreFirebaseCollection) {
      // Only create a Firebase outbox entry when
      // Google is actually newer or fills a missing
      // record/field set.
      if (_jsonStable(local) != _jsonStable(merged)) {
        await ref.set(merged);
      }
    } else {
      await _remoteSetLocal(collection, documentId, merged);
    }
  }

  Future<void> _remoteSetLocal(
    String collection,
    String documentId,
    Map<String, dynamic> data,
  ) {
    final db = FirebaseFirestore.instance;
    return db.applySyncedDocument(
      db.collection(collection).doc(documentId),
      data,
    );
  }

  Future<void> _remoteDeleteLocal(String collection, String documentId) {
    final db = FirebaseFirestore.instance;
    return db.applySyncedDocument(
      db.collection(collection).doc(documentId),
      null,
    );
  }

  String _pendingKey(String collection, String documentId) {
    return '$collection\u0000$documentId';
  }

  String _manifestId(String source, String collection) {
    return base64Url
        .encode(utf8.encode('$source\n$collection'))
        .replaceAll('=', '');
  }

  Set<String> _stringSet(dynamic value) {
    if (value is! Iterable) {
      return <String>{};
    }

    return value
        .map((item) => item.toString())
        .where((item) => item.isNotEmpty)
        .toSet();
  }

  int _modifiedMillis(Map<String, dynamic> data) {
    const keys = <String>[
      'updatedAt',
      'lastEdited',
      'timestamp',
      'paidAt',
      'uploadedAt',
      'createdAt',
      'queuedAt',
    ];

    for (final key in keys) {
      final value = data[key];

      if (value is Timestamp) {
        return value.millisecondsSinceEpoch;
      }

      if (value is DateTime) {
        return value.millisecondsSinceEpoch;
      }

      if (value is num) {
        return value.toInt();
      }

      if (value is String) {
        final asInt = int.tryParse(value);
        if (asInt != null) {
          return asInt;
        }

        final parsed = DateTime.tryParse(value);
        if (parsed != null) {
          return parsed.millisecondsSinceEpoch;
        }
      }
    }

    return 0;
  }

  String _jsonStable(Map<String, dynamic> value) {
    dynamic clean(dynamic input) {
      if (input is Timestamp) {
        return input.millisecondsSinceEpoch;
      }

      if (input is DateTime) {
        return input.millisecondsSinceEpoch;
      }

      if (input is Map) {
        final keys = input.keys.map((key) => key.toString()).toList()..sort();

        return <String, dynamic>{
          for (final key in keys) key: clean(input[key]),
        };
      }

      if (input is Iterable) {
        return input.map(clean).toList();
      }

      return input;
    }

    return jsonEncode(clean(value));
  }

  void dispose() {
    _schedule.stop();
    _changeTimer?.cancel();
    _remoteFeed.stop();
    _pauseTimer?.cancel();
    _dispatch.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _initialized = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) _schedule.wake();
  }
}

class _GoogleIdentity {
  const _GoogleIdentity({
    required this.schoolSyncId,
    required this.backendInstanceId,
  });

  final String schoolSyncId;
  final String backendInstanceId;
}

class _ResolvedSyncProfile {
  const _ResolvedSyncProfile({
    required this.profileId,
    required this.schoolSyncId,
    required this.firebaseProjectId,
    required this.googleUrl,
    required this.googleEmail,
    required this.googleBackendId,
    required this.blocked,
    required this.message,
  });

  final String profileId;
  final String schoolSyncId;
  final String firebaseProjectId;
  final String googleUrl;
  final String googleEmail;
  final String googleBackendId;
  final bool blocked;
  final String message;

  _ResolvedSyncProfile copyWith({String? googleEmail}) {
    return _ResolvedSyncProfile(
      profileId: profileId,
      schoolSyncId: schoolSyncId,
      firebaseProjectId: firebaseProjectId,
      googleUrl: googleUrl,
      googleEmail: googleEmail ?? this.googleEmail,
      googleBackendId: googleBackendId,
      blocked: blocked,
      message: message,
    );
  }
}

class _SyncAdmissionPaused implements Exception {
  const _SyncAdmissionPaused();
}
