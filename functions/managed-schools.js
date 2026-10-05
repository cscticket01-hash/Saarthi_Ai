'use strict';
const {randomUUID,randomBytes,createHash,createHmac,createCipheriv,createDecipheriv}=require('node:crypto');
const SCHOOL=/^vs-[a-f0-9]{32}$/;
const COLLECTIONS=new Set(['students_directory','teachers_directory','attendance_logs','teacher_attendance','attendance_records','teacher_schedules','school_notices','school_calendar','exam_results','teacher_salary','school_config','school_settings','fee_settings','fee_ledger','fee_payments','school_expenses','student_scan_index','scanner_devices','documents','backups','exams','exam_center_results']);
const hash=s=>createHash('sha256').update(s).digest('hex');
const fail=(status,message)=>{const e=new Error(message);e.status=status;e.publicMessage=true;throw e;};
function protect(value,key){if(!/^[a-f0-9]{64}$/i.test(key||''))fail(503,'Managed storage encryption is not configured');const iv=randomBytes(12),c=createCipheriv('aes-256-gcm',Buffer.from(key,'hex'),iv);return {iv:iv.toString('hex'),tag:null,body:Buffer.concat([c.update(value,'utf8'),c.final()]).toString('base64'),...{tag:c.getAuthTag().toString('hex')}};}
function unprotect(v,key){if(!/^[a-f0-9]{64}$/i.test(key||''))fail(503,'Managed storage encryption is not configured');const c=createDecipheriv('aes-256-gcm',Buffer.from(key,'hex'),Buffer.from(v.iv,'hex'));c.setAuthTag(Buffer.from(v.tag,'hex'));return Buffer.concat([c.update(Buffer.from(v.body,'base64')),c.final()]).toString('utf8');}
function scriptUrl(value){try{const u=new URL(value);if(u.protocol==='https:'&&u.hostname==='script.google.com'&&!u.username&&!u.password&&!u.port&&!u.search&&!u.hash&&/^\/macros\/s\/[A-Za-z0-9_-]{10,300}\/exec$/.test(u.pathname))return u.href;}catch{}fail(400,'Use the exact school Apps Script /exec URL');}
function clean(value,depth=0){if(depth>12)fail(400,'Record is too deeply nested');if(Array.isArray(value))return value.map(v=>clean(v,depth+1));if(value&&typeof value==='object'){const out={};for(const [k,v]of Object.entries(value)){if(['__proto__','prototype','constructor'].includes(k)||(/password|token|secret|private_key|base64|localpath/i.test(k)&&k!=='mobileLinkToken'))fail(400,'Secrets and media cannot be stored in school records');out[k]=clean(v,depth+1);}return out;}if(typeof value==='string'&&value.startsWith('data:'))fail(400,'Media belongs in Drive files');return value;}
function createManagedSchools({auth,db,projectId,encryptionKey,fetchImpl=fetch,now=Date.now,monitor=async()=>({available:false,reason:'Monitoring access has not been configured'})}){
 const pairingTickets=new Map();
 async function user(req){const token=String(req.headers.authorization||'').match(/^Bearer (.+)$/)?.[1];if(!token)fail(401,'School login required');try{return await auth.verifyIdToken(token,true);}catch{fail(401,'Login expired or disabled');}}
 async function developer(req){const u=await user(req),m=await db.doc('school_memberships/'+u.uid).get();if(m.exists||!(u.developer===true||(u.admin===true&&!u.schoolId)))fail(403,'Developer access required');return u;}
 async function identity(req,expected){const u=await user(req),m=await db.doc('school_memberships/'+u.uid).get();if(!m.exists||m.data().managed!==true||m.data().active!==true||m.data().role!=='school_admin')fail(403,'Managed school login is inactive');const id=m.data().schoolId;if(!SCHOOL.test(id)||expected&&expected!==id)fail(403,'Another school is not accessible');const e=await db.doc('school_entitlements/'+id).get();if(!e.exists||e.data().active!==true||e.data().blocked===true)fail(403,'School is blocked or disabled');if(Number(e.data().sessionValidAfter||0)>Number(u.auth_time||0))fail(401,'Sign in again');const entitlement={...e.data()};
 if(entitlement.status!=='trial'&&entitlement.licenseHash){const licence=await db.doc('platform_license_status/'+entitlement.licenseHash).get();if(!licence.exists||licence.data().schoolId!==id||licence.data().revoked!==false){entitlement.expiresAt=0;}else{const end=licence.data().expiresAt;entitlement.expiresAt=typeof end?.toMillis==='function'?end.toMillis():Number(end||0);}}
 return {uid:u.uid,schoolId:id,entitlement};}
 function lease(m){const e=m.entitlement,t=now(),paid=e.status!=='trial',end=Number(e.expiresAt||0);return {success:true,managed:true,schoolId:m.schoolId,uid:m.uid,projectId,serverTime:t,activated:e.activated===true,expiresAt:end,allowed:e.startsAt<=t&&end>t,status:e.startsAt>t?'pending':end>t?(paid?'licensed':'trial'):'expired'};}
 async function signed(m,body){const s=await db.doc('school_storage_private/'+m.schoolId).get();if(!s.exists||s.data().ready!==true)fail(409,'Developer must connect this school Apps Script first');const c=s.data(),payload=JSON.stringify(body),timestamp=now(),nonce=randomBytes(24).toString('hex'),signature=createHmac('sha256',unprotect(c.secret,encryptionKey)).update(m.schoolId+'\n'+timestamp+'\n'+nonce+'\n'+payload).digest('hex');let url=scriptUrl(c.url);let response=await fetchImpl(url,{method:'POST',redirect:'manual',headers:{'Content-Type':'application/json'},body:JSON.stringify({schoolId:m.schoolId,timestamp,nonce,payload,signature}),signal:AbortSignal.timeout(90000)});if([301,302,303].includes(response.status)){const target=new URL(response.headers.get('location'));if(target.protocol!=='https:'||target.hostname!=='script.googleusercontent.com'||target.username||target.password)fail(502,'Unexpected script redirect');response=await fetchImpl(target.href,{redirect:'error',signal:AbortSignal.timeout(90000)});}if(!response.ok)fail(502,'School script request failed');const raw=await response.text();if(raw.length>30*1024*1024)fail(502,'School script response is too large');let out;try{out=JSON.parse(raw);}catch{fail(502,'School script returned invalid JSON');}if(out.schoolId!==m.schoolId)fail(502,'School script identity or operation failed');if(out.success!==true){const safe=['This QR is invalid or has not synced to this school. Ask the school to sync or regenerate the ID card.','Ask your school to regenerate this ID card.','Class, roll number or date of birth is incorrect','School session expired. Scan your ID again.','School record or ID card was changed; scan again'];if(body.action==='managed_mobile'&&safe.includes(out.message))fail(403,out.message);fail(502,'School script identity or operation failed');}return out;}
 async function scriptRequest(url,body){
  let response=await fetchImpl(url,{method:'POST',redirect:'manual',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(30000)});
  if([301,302,303].includes(response.status)){const target=new URL(response.headers.get('location'));if(target.protocol!=='https:'||target.hostname!=='script.googleusercontent.com'||target.username||target.password)fail(502,'Unexpected script redirect');response=await fetchImpl(target.href,{redirect:'error',signal:AbortSignal.timeout(30000)});}
  if(!response.ok)fail(502,'School script is unavailable');
  const raw=await response.text();if(raw.length>8192)fail(502,'Invalid school script connection response');
  try{return JSON.parse(raw);}catch{fail(502,'Update this school managed Apps Script deployment before connecting');}
 }
 return async req=>{
 const b=req.body||{},action=b.action;if(req.method!=='POST')fail(405,'Use POST');
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
  if(!SCHOOL.test(id||''))fail(400,'Invalid school ID');const school=await db.doc('platform_schools/'+id).get();if(!school.exists||school.data().managed!==true)fail(404,'Managed school not found');const data=school.data(),ref=db.doc('school_entitlements/'+id);
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
  await db.collection('platform_audit').add({action,schoolId:id,actor:admin.uid,at:now()});return {success:true};
 }
 if(action==='managed/mobile'){
  if(!SCHOOL.test(b.schoolId||''))fail(400,'Invalid school ID');
  const school=await db.doc('platform_schools/'+b.schoolId).get(),entitlement=await db.doc('school_entitlements/'+b.schoolId).get();
  if(!school.exists||school.data().managed!==true||school.data().deletedAt||!entitlement.exists||!entitlement.data().active||entitlement.data().blocked)fail(403,'Unable to connect: school is unavailable');
  const e={...entitlement.data()};
  if(e.status!=='trial'){const licence=await db.doc('platform_license_status/'+e.licenseHash).get();if(!licence.exists||licence.data().revoked!==false||licence.data().schoolId!==b.schoolId)fail(403,'Unable to connect: school licence is inactive');const end=licence.data().expiresAt;e.expiresAt=typeof end?.toMillis==='function'?end.toMillis():Number(end||0);}
  const m={schoolId:b.schoolId,entitlement:e};
  if(!lease(m).allowed||e.status!=='trial'&&e.activated!==true)fail(403,'Unable to connect: school trial or licence has ended');
  const seen=Number(school.data().lastSeenAt||0);
  if(seen>now()||now()-seen>90000)fail(409,'Unable to connect: school Windows app is offline');
  if(!b.request||typeof b.request!=='object'||JSON.stringify(b.request).length>16000||!['mobile_login','mobile_logout','mobile_heartbeat','mobile_dashboard','mobile_notice','mobile_attendance_list','mobile_mark_attendance','mobile_asset','mobile_complaint'].includes(b.request.action))fail(400,'Invalid mobile operation');
  return signed(m,{action:'managed_mobile',request:b.request,lease:{schoolId:m.schoolId,expiresAt:lease(m).expiresAt}});
 }
 const m=await identity(req,b.schoolId);
 if(action==='managed/session'){const access=lease(m);await db.doc('platform_schools/'+m.schoolId).set({lastSeenAt:access.allowed?now():0},{merge:true});const storage=await db.doc('school_storage_private/'+m.schoolId).get();return {...access,storageReady:storage.exists&&storage.data().ready===true,scriptUrl:storage.exists?storage.data().url:''};}
 if(action==='managed/disconnect'){await db.doc('platform_schools/'+m.schoolId).set({lastSeenAt:0},{merge:true});return {success:true};}
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
   await db.doc('platform_schools/'+m.schoolId).set({storageReady:true,storageCheckedAt:now()},{merge:true});
   await db.collection('platform_audit').add({action,schoolId:m.schoolId,actor:m.uid,at:now()});
   return {success:true,schoolId:m.schoolId,storageReady:true,scriptUrl:url,googleEmail:health.googleEmail||''};
  }finally{pairingTickets.delete(ticketHash);}
 }
 if(action==='managed/storage/check')return signed(m,{action:'managed_health'});
 if(action==='managed/records'){
  if(!COLLECTIONS.has(b.collection)||!['read','write','delete'].includes(b.operation))fail(400,'Invalid school collection operation');if(b.operation!=='read'&&(!/^[^/]{1,200}$/.test(b.id||'')||['.','..'].includes(b.id)))fail(400,'Invalid record ID');const data=b.operation==='write'?{...clean(b.data),schoolId:m.schoolId}:undefined;
  return signed(m,{action:'managed_records',operation:b.operation,collection:b.collection,...(b.id?{id:b.id}:{}),...(data?{data}:{})});
 }
 if(action==='managed/file/upload'){
  if(typeof b.base64!=='string'||b.base64.length>28*1024*1024||!b.base64.length||!/^[-\w.+]+\/[-\w.+]+$/.test(b.mime||'')||typeof b.name!=='string'||b.name.length>200)fail(400,'Invalid school file');return signed(m,{action:'managed_upload',name:b.name,mime:b.mime,base64:b.base64});
 }
 if(action==='managed/file/read'){if(!/^[A-Za-z0-9_-]{1,200}$/.test(b.fileId||''))fail(400,'Invalid file ID');return signed(m,{action:'managed_file',fileId:b.fileId});}
 if(action==='managed/backup')return signed(m,{action:'managed_backup'});
 if(action==='managed/restore'){if(!/^[A-Za-z0-9_-]{1,200}$/.test(b.fileId||''))fail(400,'Invalid backup file ID');return signed(m,{action:'managed_restore',fileId:b.fileId});}
 fail(400,'Unknown managed school operation');
 };
}
module.exports={createManagedSchools,scriptUrl,protect,unprotect,clean,COLLECTIONS};
