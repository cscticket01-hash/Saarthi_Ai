'use strict';
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
function createManagedSchools({auth,db,projectId,encryptionKey,fetchImpl=fetch,now=Date.now,attendanceStore,attendanceCollection='attendance_outbox',messaging,scheduleHint=callback=>setTimeout(callback,250),pushDiagnostics=entry=>console.info(JSON.stringify(entry)),monitor=async()=>({available:false,reason:'Monitoring access has not been configured'})}){
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
  if(p.open!==true)fail(400,'School is closed today. Attendance is disabled for everyone');
  const lat=Number(request.latitude),lng=Number(request.longitude),accuracy=Number(request.accuracy),radius=Number(p.radiusMeters);
  if(!Number.isFinite(lat)||!Number.isFinite(lng)||Math.abs(lat)>90||Math.abs(lng)>180||!Number.isFinite(accuracy)||accuracy<0||accuracy>radius||!Number.isFinite(radius)||radius<25||radius>200||!Number.isFinite(Number(p.latitude))||!Number.isFinite(Number(p.longitude)))fail(400,'Accurate school location required');
  const rad=x=>x*Math.PI/180,h=Math.sin(rad(p.latitude-lat)/2)**2+Math.cos(rad(lat))*Math.cos(rad(p.latitude))*Math.sin(rad(p.longitude-lng)/2)**2;
  if(6371000*2*Math.atan2(Math.sqrt(h),Math.sqrt(1-h))>radius)fail(400,'Attendance can be marked only within the school location');
  return p;
 }
 let attendanceWake=()=>{};
 const queue=createAttendanceQueue({store:attendanceStore||firestoreAttendanceStore(db,{collectionName:attendanceCollection}),now,deliver:async(schoolId,items)=>{
  const state=await mobileState(schoolId),e=state.entitlement;
  if(!state.school||!e||!e.active||e.blocked||state.school.deletedAt) return items.map(i=>({operationId:i.operationId,success:false,authoritative:true}));
  if(e.status!=='trial'){
   if(!state.licence||state.licence.revoked||state.licence.schoolId!==schoolId)return items.map(i=>({operationId:i.operationId,success:false,authoritative:true}));
   e.expiresAt=Number(state.licence.expiresAt?.toMillis?.()??state.licence.expiresAt);
  }
  const m={schoolId,entitlement:e};
  if(!lease(m).allowed||e.status!=='trial'&&!e.activated)return items.map(i=>({operationId:i.operationId,success:false,authoritative:true}));
  const result=await signed(m,{action:'managed_attendance_batch',lease:{schoolId,expiresAt:lease(m).expiresAt},
   operations:items.map(i=>({operationId:i.operationId,request:{...JSON.parse(unprotect(i.payload,encryptionKey)),operationId:i.operationId,submittedAt:i.createdAt}}))});
  if(!Array.isArray(result.acknowledgements))throw Error('Attendance acknowledgement missing');
  if(result.acknowledgements.some(ack=>ack.success===true)){invalidate(schoolId);await notifyChanged(schoolId,'attendance-ack',false).catch(()=>{});}
  return result.acknowledgements;
 }});
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
 return {uid:u.uid,schoolId:id,entitlement};}
 function lease(m){const e=m.entitlement,t=now(),paid=e.status!=='trial',end=Number(e.expiresAt||0);return {success:true,managed:true,schoolId:m.schoolId,uid:m.uid,projectId,serverTime:t,activated:e.activated===true,expiresAt:end,allowed:e.startsAt<=t&&end>t,status:e.startsAt>t?'pending':end>t?(paid?'licensed':'trial'):'expired'};}
 // Context is attached only after identity/entitlement verification, never from
 // an unauthenticated request's schoolId or arbitrary Script response.
 async function signed(m,body){
  try{return await signedRequest(m,body);}catch(error){
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
 async function signedRequest(m,body){const started=performance.now();const s=await cachedRead(storageStates,m.schoolId,()=>db.doc('school_storage_private/'+m.schoolId).get());if(!s.exists||s.data().ready!==true)fail(409,'Developer must connect this school Apps Script first','SCHOOL_STORAGE_NOT_CONNECTED');const c=s.data(),payload=JSON.stringify(body),timestamp=now(),nonce=randomBytes(24).toString('hex'),signature=createHmac('sha256',unprotect(c.secret,encryptionKey)).update(m.schoolId+'\n'+timestamp+'\n'+nonce+'\n'+payload).digest('hex');let url=scriptUrl(c.url);const scriptStarted=performance.now();let response=await fetchScript(url,{method:'POST',redirect:'manual',headers:{'Content-Type':'application/json'},body:JSON.stringify({schoolId:m.schoolId,timestamp,nonce,payload,signature}),signal:AbortSignal.timeout(90000)});if([301,302,303].includes(response.status)){const target=new URL(response.headers.get('location'));if(target.protocol!=='https:'||target.hostname!=='script.googleusercontent.com'||target.username||target.password)fail(502,'Unexpected script redirect');response=await fetchScript(target.href,{redirect:'error',signal:AbortSignal.timeout(90000)},'redirect');}if(!response.ok)fail(502,'School script request failed','SCRIPT_HTTP_ERROR');const raw=await readScript(response);if(raw.length>30*1024*1024)fail(502,'School script response is too large');let out;try{out=JSON.parse(raw);}catch{fail(502,'School script returned invalid JSON','SCRIPT_INVALID_RESPONSE');}if(out.schoolId!==m.schoolId)fail(502,'School script identity or operation failed','SCRIPT_IDENTITY_MISMATCH');if(out.success!==true){if(out.message==='Record revision conflict')fail(409,'Record revision conflict','RECORD_REVISION_CONFLICT');if(out.message==='Sync operation ID conflict')fail(409,'Sync operation ID conflict','OPERATION_ID_CONFLICT');const safe=['This QR is invalid or has not synced to this school. Ask the school to sync or regenerate the ID card.','Ask your school to regenerate this ID card.','Class, roll number or date of birth is incorrect','School session expired. Scan your ID again.','School session expired','School login required','School identity mismatch','This QR does not belong to the active school','School record or ID card was changed; scan again'];if(body.action==='managed_mobile'&&safe.includes(out.message))fail(403,out.message);const codes={'School data organization in progress; retry Sync. Pending data retained':'SCRIPT_MIGRATION_PENDING','Migration conflict; both versions retained':'SCRIPT_MIGRATION_CONFLICT','Verified school tab is missing; operator recovery required':'SCRIPT_MISSING_MIGRATED_TAB','School record verification failed':'SCRIPT_RECORD_VERIFY_FAILED','Managed storage not prepared':'SCRIPT_STORAGE_NOT_PREPARED'};fail(502,'School script identity or operation failed',codes[out.message]||(['SCRIPT_WORKBOOK_IDENTITY_MISMATCH','SCRIPT_WORKBOOK_REVIEW_REQUIRED','SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED','SCRIPT_FOREIGN_RECORD_REJECTED','SCRIPT_INVALID_SYNC_OPERATION','SCRIPT_DOCUMENT_REVISION_REQUIRED','SCRIPT_DOCUMENT_REVISION_CONFLICT','SCRIPT_MIGRATION_CONFLICT','SCRIPT_MISSING_MIGRATED_TAB','SCRIPT_RECORD_VERIFY_FAILED','SCRIPT_STORAGE_NOT_PREPARED','SCRIPT_MIGRATION_PENDING','SCRIPT_PERMISSION_DENIED','SCRIPT_QUOTA_EXCEEDED','SCRIPT_TIMEOUT','SCRIPT_TYPE_ERROR','SCRIPT_PARSE_ERROR'].includes(out.code)?out.code:'SCRIPT_OPERATION_FAILED'));}return {...out,syncTiming:{brokerPreparationMillis:Math.round(scriptStarted-started),scriptRoundTripMillis:Math.round(performance.now()-scriptStarted)}};}
 async function scriptRequest(url,body){
  let response=await fetchImpl(url,{method:'POST',redirect:'manual',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(30000)});
  if([301,302,303].includes(response.status)){const target=new URL(response.headers.get('location'));if(target.protocol!=='https:'||target.hostname!=='script.googleusercontent.com'||target.username||target.password)fail(502,'Unexpected script redirect');response=await fetchImpl(target.href,{redirect:'error',signal:AbortSignal.timeout(30000)});}
  if(!response.ok)fail(502,'School script is unavailable');
  const raw=await response.text();if(raw.length>8192)fail(502,'Invalid school script connection response');
  try{return JSON.parse(raw);}catch{fail(502,'Update this school managed Apps Script deployment before connecting');}
 }
 const handler=async req=>{
 const b=req.body||{},action=b.action;if(req.method!=='POST')fail(405,'Use POST');
 // This capability authorizes ONLY a bounded presence write, never school data.
 // Membership/licence revocation is rechecked when the 15-minute lease renews.
 if(action==='managed/presence'){
  const p=verifiedPresence(b.presenceToken);if(b.schoolId&&b.schoolId!==p.schoolId)fail(403,'Another school is not accessible');
  await db.doc('platform_schools/'+p.schoolId).set({lastSeenAt:now()},{merge:true});
  return {success:true,schoolId:p.schoolId};
 }
 // A server-generated, short-lived capability; Firebase tokens never reach GS.
 if(action==='managed/storage/authorize'){
  const ticket=pairingTickets.get(hash(String(b.ticket||'')));
  if(!ticket||ticket.used||ticket.expiresAt<=now()||ticket.schoolId!==b.schoolId)fail(403,'Invalid school storage connection ticket');
  const m=await identity(ticket.req,ticket.schoolId);
  if(!lease(m).allowed||m.entitlement.status!=='trial'&&m.entitlement.activated!==true)fail(403,'School licence is inactive');
  ticket.used=true;return {success:true,schoolId:m.schoolId};
 }
 if(action?.startsWith('developer/managed/')){
  const admin=await developer(req),id=b.schoolId;if(action==='developer/managed/create'){
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
  if(!SCHOOL.test(id||''))fail(400,'Invalid school ID');if(!['developer/managed/exams','developer/managed/view'].includes(action))invalidate(id);const school=await cachedRead(developerViews,id,()=>db.doc('platform_schools/'+id).get());if(!school.exists||school.data().managed!==true)fail(404,'Managed school not found');const data=school.data(),ref=db.doc('school_entitlements/'+id);
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
  if(!b.request||typeof b.request!=='object'||JSON.stringify(b.request).length>16000||!['mobile_login','mobile_refresh','mobile_logout','mobile_heartbeat','mobile_dashboard','mobile_notice','mobile_attendance_list','mobile_mark_attendance','mobile_attendance_status','mobile_asset','mobile_document','mobile_complaint'].includes(b.request.action))fail(400,'Invalid mobile operation');
  if(b.request.action==='mobile_attendance_status'){
   const permit=verifyAttendanceIdentity(b.schoolId,b.request),ids=b.request.operationIds;
   if(!Array.isArray(ids)||ids.length<1||ids.length>25||ids.some(id=>!/^[a-f0-9]{64}$/.test(id))||new Set(ids).size!==ids.length)fail(400,'Invalid attendance status batch');
   const rows=await Promise.all(ids.map(id=>db.doc(attendanceCollection+'/'+id).get()));
   const operations=rows.map((row,index)=>{
    if(!row.exists)return {operationId:ids[index],state:'unknown'};
    const value=row.data();if(value.schoolId!==b.schoolId)fail(403,'Another school is not accessible');
    const payload=JSON.parse(unprotect(value.payload,encryptionKey));
    if(payload.personId!==permit.documentId||payload.role!==permit.role)fail(403,'Another person attendance is not accessible');
    return {operationId:ids[index],state:value.state,createdAt:value.createdAt,
      ...(value.state==='completed'?{completedAt:value.completedAt}:{})};
   });
   return {success:true,schoolId:b.schoolId,projectId:b.schoolId,syncProtocol:2,operations};
  }
  if(b.request.action==='mobile_mark_attendance'&&b.request.attendancePermit){
   const permit=verifyAttendance(b.schoolId,b.request);
   const captured=b.request.clientCapturedAt;
   if(captured!==undefined&&(!Number.isSafeInteger(captured)||captured<=0||captured>now()+120000||new Date(captured+19800000).toISOString().slice(0,10)!==permit.day))fail(409,'Attendance capture date needs school review; original data retained.','ATTENDANCE_CAPTURE_REVIEW');
   const result=await queue.enqueue({schoolId:b.schoolId,role:permit.role,personId:permit.personId,day:permit.day,mode:b.request.mode==='exit'?'exit':'entry',payload:protect(JSON.stringify({...b.request,attendancePermit:undefined}),encryptionKey)});
   attendanceWake();
   return {success:true,schoolId:b.schoolId,projectId:b.schoolId,syncProtocol:2,...result};
  }
  const body={action:'managed_mobile',request:b.request,lease:{schoolId:m.schoolId,expiresAt:lease(m).expiresAt}};
  const result=b.request.action==='mobile_dashboard'
   ?await readView(m.schoolId,body,()=>signed(m,body),true):await signed(m,body);
  if(['mobile_logout','mobile_mark_attendance','mobile_complaint'].includes(b.request.action))invalidate(m.schoolId);
  await registerDevice(b.schoolId,b.request,result);
  if(result.attendancePolicy) result.attendancePermit=attendancePermit(b.schoolId,b.request.sessionToken||result.sessionToken,result.attendancePolicy,e.expiresAt);
  delete result.attendancePolicy;
  return {...result,policyExpiresAt:Math.min(e.expiresAt,now()+72*3600000)};
 }
 const m=await identity(req,b.schoolId);
 if(action==='managed/session'){const access=lease(m);await db.doc('platform_schools/'+m.schoolId).set({lastSeenAt:access.allowed?now():0},{merge:true});const storage=await db.doc('school_storage_private/'+m.schoolId).get();return {...access,presenceToken:presence(m,access),storageReady:storage.exists&&storage.data().ready===true,scriptUrl:storage.exists?storage.data().url:''};}
 if(action==='managed/disconnect'){invalidate(m.schoolId);await db.doc('platform_schools/'+m.schoolId).set({lastSeenAt:0},{merge:true});return {success:true};}
 if(action==='managed/summary'){
  if(!lease(m).allowed||m.entitlement.status!=='trial'&&m.entitlement.activated!==true)fail(403,'School licence is inactive');
  const school=await db.doc('platform_schools/'+m.schoolId).get();
  if(now()-Number(school.data()?.summaryAt||0)<300000)return {success:true,cached:true};
  const result=await signed(m,{action:'managed_summary'});
  if(!Number.isSafeInteger(result.studentCount)||result.studentCount<0||!Number.isSafeInteger(result.driveBytes)||result.driveBytes<0)fail(502,'Invalid school storage summary');
  await db.doc('platform_schools/'+m.schoolId).set({studentCount:result.studentCount,driveBytes:result.driveBytes,driveBytesPartial:result.partial===true,summaryAt:now()},{merge:true});return {success:true};
 }
 if(action==='managed/licence/activate'){if(hash(String(b.key||'').trim().toUpperCase())!==m.entitlement.licenseHash||!lease(m).allowed)fail(403,'Licence does not belong to this school or has expired');const ref=db.doc('school_entitlements/'+m.schoolId);
 await db.runTransaction(async tx=>{const current=await tx.get(ref);const e=current.data();if(!e||e.active!==true||e.blocked===true||e.licenseHash!==m.entitlement.licenseHash||Number(e.expiresAt)<=now()||Number(e.startsAt)>now())fail(403,'School licence changed or access was blocked');tx.set(ref,{activated:true},{merge:true});});return {...lease(m),activated:true,status:'licensed'};}
 if(!lease(m).allowed||(m.entitlement.status!=='trial'&&m.entitlement.activated!==true))fail(403,'Activate the school licence before normal operations');
 // Lightweight enrollment metadata is independent of the PC and school Drive.
 // Media and operational records remain in the school's own storage.
 if(action==='managed/profile'){
  const ref=db.doc('school_registration_profiles/'+m.schoolId);
  if(b.operation==='initialize'){
   const name=String(b.schoolName||'').trim(),principal=String(b.principalName||'').trim();
   if(name.length<2||name.length>160||principal.length<2||principal.length>160)fail(400,'Valid school and principal names required');
   await db.runTransaction(async tx=>{
    const entitlement=await tx.get(db.doc('school_entitlements/'+m.schoolId)),existing=await tx.get(ref);
    const current={...m,entitlement:entitlement.data()||{}};
    if(current.entitlement.active!==true||current.entitlement.blocked===true||!lease(current).allowed||current.entitlement.status!=='trial'&&current.entitlement.activated!==true||current.entitlement.licenseHash!==m.entitlement.licenseHash)fail(403,'School access changed during registration');
    if(!existing.exists)tx.set(ref,{schoolId:m.schoolId,schoolName:name,principalName:principal,completedAt:now()});
   });
  }else if(b.operation!=='read')fail(400,'Invalid school profile operation');
  const profile=await ref.get(),school=await db.doc('platform_schools/'+m.schoolId).get(),storage=await db.doc('school_storage_private/'+m.schoolId).get();
  const data=profile.data();
  if(profile.exists&&(data.schoolId!==m.schoolId||typeof data.schoolName!=='string'||data.schoolName.trim().length<2||typeof data.principalName!=='string'||data.principalName.trim().length<2))fail(409,'Saved school registration requires recovery');
  let registrationState=profile.exists?'complete':school.data()?.registrationState==='new'?'new':'unknown';
  let recovered=profile.exists?{schoolId:m.schoolId,schoolName:data.schoolName,principalName:data.principalName}:null;
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
   await db.runTransaction(async tx=>{const current=await tx.get(ref);if(current.exists&&(!old.exists||b.replace!==true||b.expectedScriptUrl!==current.data().url))fail(409,'Existing storage retained. Confirm the current school Drive connection before replacement');tx.set(ref,{url,secret:protect(secret,encryptionKey),ready:true,...(current.exists?{previousConnections:[...(current.data().previousConnections||[]),{url:current.data().url,secret:current.data().secret,at:now()}]}:{})});});
   // A concurrent readiness read may have cached the missing pre-pairing snapshot.
   // Invalidate after the durable binding commit, not only before pairing starts.
   invalidate(m.schoolId);
   await db.doc('platform_schools/'+m.schoolId).set({storageReady:true,storageCheckedAt:now()},{merge:true});
   await db.collection('platform_audit').add({action,schoolId:m.schoolId,actor:m.uid,at:now()});
   return {success:true,schoolId:m.schoolId,storageReady:true,scriptUrl:url,googleEmail:health.googleEmail||''};
  }finally{pairingTickets.delete(ticketHash);}
 }
 if(action==='managed/storage/check')return {...await signed(m,{action:'managed_health'}),brokerRecordSyncVersion:2};
 if(action==='managed/attendance/status'){
  if(!Array.isArray(b.operationIds)||b.operationIds.length>25||b.operationIds.some(id=>!/^[a-f0-9]{64}$/.test(id))||new Set(b.operationIds).size!==b.operationIds.length)fail(400,'Invalid attendance status batch');
  const rows=await Promise.all(b.operationIds.map(id=>db.doc(attendanceCollection+'/'+id).get()));
  const operations=rows.map((row,index)=>{if(row.exists&&row.data().schoolId!==m.schoolId)fail(403,'Another school is not accessible');const value=row.data()||{};return {operationId:b.operationIds[index],state:row.exists?value.state:'unknown',createdAt:value.createdAt||null,completedAt:value.state==='completed'?value.completedAt:null};});
  return {success:true,schoolId:m.schoolId,operations};
 }
 if(action==='managed/changes'){
  const collections=b.collections,known=b.knownRevisions||{};
  if(!Array.isArray(collections)||collections.length>22||new Set(collections).size!==collections.length||collections.some(col=>!COLLECTIONS.has(col))||!known||typeof known!=='object'||Array.isArray(known)||Object.entries(known).some(([key,value])=>!collections.includes(key)||typeof value!=='string'||value.length>1000))fail(400,'Invalid delta checkpoint');
  const body={action:'managed_delta',collections,knownRevisions:known};
  const result=await readView(m.schoolId,body,()=>signed(m,body));
  if(result.syncProtocol!==2||!result.changes||typeof result.changes!=='object'||Object.keys(result.changes).length!==collections.length)fail(502,'Invalid delta response');
  for(const col of collections){const group=result.changes[col];if(!group||group.syncProtocol!==2||typeof group.collectionRevision!=='string'||!group.records||typeof group.records!=='object'||Array.isArray(group.records)||Object.values(group.records).some(row=>!row||row.schoolId!==m.schoolId))fail(502,'Foreign or invalid school delta');}
  return result;
 }
 if(action==='managed/records'){
  if(!COLLECTIONS.has(b.collection)||!['read','write','delete'].includes(b.operation))fail(400,'Invalid school collection operation');if(b.operation!=='read'&&(!/^[^/]{1,200}$/.test(b.id||'')||['.','..'].includes(b.id)))fail(400,'Invalid record ID');const data=b.operation==='write'?{...clean(b.data),schoolId:m.schoolId}:undefined;
  if(b.expectedRevision!==undefined&&(b.collection!=='documents'||typeof b.expectedRevision!=='string'||b.expectedRevision.length>100))fail(400,'Invalid document version');if(b.syncProtocol!==undefined&&b.syncProtocol!==2)fail(400,'Invalid sync protocol');
  if(b.syncProtocol===2&&b.operation!=='read'&&(!/^[A-Za-z0-9_-]{16,100}$/.test(b.operationId||'')||typeof b.expectedRecordRevision!=='string'||b.expectedRecordRevision.length>100))fail(400,'Invalid sync operation');
  const acknowledged=await signed(m,{action:'managed_records',operation:b.operation,collection:b.collection,
    ...(b.syncProtocol===2?{syncProtocol:2,...(b.operation==='read'?{knownRevision:typeof b.knownRevision==='string'?b.knownRevision:''}:{operationId:b.operationId,expectedRecordRevision:b.expectedRecordRevision})}:{}),...(b.id?{id:b.id}:{}),...(data?{data}:{}),...(b.expectedRevision!==undefined?{expectedRevision:b.expectedRevision}:{}),...(Number.isFinite(b.expectedUploadedAt)?{expectedUploadedAt:b.expectedUploadedAt}:{})});
  if(b.operation!=='read')invalidate(m.schoolId);
  // Only verified durable Script ACK permits a hint. FCM is optional and never
  // changes the storage acknowledgement or sends private school content.
  const owner=b.operation==='write'&&(b.collection==='students_directory'||b.collection==='teachers_directory')?{personId:data.mobileStableId||b.id,role:b.collection==='students_directory'?'student':'teacher'}:b.operation==='write'&&data?.personId?{personId:data.personId,role:data.ownerRole||'student'}:undefined;
  if((b.syncProtocol===2||(b.collection==='documents'&&typeof b.expectedRevision==='string'))&&acknowledged.syncProtocol===2&&typeof acknowledged.recordRevision==='string'&&b.operation!=='read'&&['school_notices','school_config','school_settings','school_calendar','students_directory','teachers_directory','teacher_schedules','attendance_records','attendance_logs','teacher_attendance','fee_settings','fee_ledger','fee_payments','teacher_salary','exams','exam_center_results','exam_results','documents'].includes(b.collection))
   void notifyChanged(m.schoolId,b.operationId||hash(m.schoolId+'/'+b.collection+'/'+b.id+'/'+acknowledged.recordRevision),b.collection==='school_notices'&&b.operation==='write',owner).catch(error=>{const safe=['messaging/authentication-error','messaging/mismatched-credential','messaging/server-unavailable'];try{pushDiagnostics({event:'managed_push_hint_failure',code:safe.includes(error.code)?error.code:'FCM_UNAVAILABLE'});}catch{}});
  return acknowledged;
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
 if(action==='managed/backup')return signed(m,{action:'managed_backup'});
 if(action==='managed/restore'){if(!/^[A-Za-z0-9_-]{1,200}$/.test(b.fileId||''))fail(400,'Invalid backup file ID');return signed(m,{action:'managed_restore',fileId:b.fileId});}
 fail(400,'Unknown managed school operation');
 };
 handler.syncReadMetrics=()=>({hits:viewHits,misses:viewMisses,entries:readViews.size,bytes:readBytes,ttlMillis:5000});
 handler.drainAttendance=queue.drain;handler.attendanceMetrics=queue.metrics;handler.setAttendanceWake=wake=>{attendanceWake=wake;};
 return handler;
}
module.exports={createManagedSchools,scriptUrl,protect,unprotect,clean,COLLECTIONS};
