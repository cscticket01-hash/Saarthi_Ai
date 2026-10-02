/** Spark platform bridge. Install ONLY in this school's own Apps Script.
 * The developer website provisions a school-scoped monitoring identity.
 * No student record, QR, session token, FCM token or owner OAuth goes centrally.
 */
const VS_CENTRAL_PROJECT = 'saarthi-ai-df12b';
const VS_CENTRAL_API_KEY = 'AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
function VS_centralBase(){return 'https://firestore.googleapis.com/v1/projects/'+VS_CENTRAL_PROJECT+'/databases/(default)/documents';}
function VS_central(method,path,data,token){
 const options={method:method,muteHttpExceptions:true,headers:{}};
 if(token)options.headers.Authorization='Bearer '+token;
 if(data){options.contentType='application/json';options.payload=JSON.stringify(data);}
 const r=UrlFetchApp.fetch(VS_centralBase()+(path[0]===':'?'':'/')+path,options);
 const code=r.getResponseCode();let body;try{body=JSON.parse(r.getContentText()||'{}');}catch(_){throw new Error('Developer monitoring service unavailable');}
 if(code===404)return null;
 if(code>=400){const err=new Error('Developer monitoring operation failed ('+code+')');err.httpCode=code;throw err;}
 return body;
}
function VS_centralAuth(action,data){
 const r=UrlFetchApp.fetch('https://identitytoolkit.googleapis.com/v1/accounts:'+action+'?key='+VS_CENTRAL_API_KEY,
  {method:'post',contentType:'application/json',payload:JSON.stringify(data),muteHttpExceptions:true});
 const result=JSON.parse(r.getContentText()||'{}');
 if(r.getResponseCode()!==200)throw new Error('Developer Firebase authentication unavailable. Check the school monitoring setup and enabled sign-in providers.');
 return result;
}
function VS_schoolTrial(){
 const path='platform_school_trials/'+VS_project();let raw=VS_central('get',path);
 if(!raw){
  const auth=VS_centralAuth('signUp',{returnSecureToken:true});
  try{
   VS_central('post',':commit',{writes:[{update:{name:'projects/'+VS_CENTRAL_PROJECT+'/databases/(default)/documents/'+path,fields:{}},
    currentDocument:{exists:false},updateTransforms:[{fieldPath:'createdAt',setToServerValue:'REQUEST_TIME'}]},
    {update:{name:'projects/'+VS_CENTRAL_PROJECT+'/databases/(default)/documents/platform_trial_claims/'+auth.localId,fields:{target:VS_encode(path)}},
     currentDocument:{exists:false},updateTransforms:[{fieldPath:'createdAt',setToServerValue:'REQUEST_TIME'}]}]},auth.idToken);
  }catch(err){if(err.httpCode!==409)throw err;}
  finally{try{VS_centralAuth('delete',{idToken:auth.idToken});}catch(_) {}}
  raw=VS_central('get',path);
 }
 if(!raw)throw new Error('School trial verification unavailable');
 return VS_doc(raw).createdAt;
}
function VS_platformStatus(force){
 const props=PropertiesService.getScriptProperties(),cache=CacheService.getScriptCache(),key='VS_PLATFORM_STATUS';
 if(!force){const cached=cache.get(key);if(cached){const d=JSON.parse(cached);if(d.expiresAt<=Date.now()){d.allowed=false;if(d.status!=='blocked')d.status='expired';}return d;}}
 const hash=props.getProperty('VS_LICENSE_KEY_HASH');let status,expires;
 if(hash){
  const raw=VS_central('get','platform_license_status/'+hash),license=VS_doc(raw);
  if(!license||license.schoolId!==VS_project())throw new Error('Licence does not belong to this school');
  expires=license.expiresAt;status=license.revoked?'blocked':expires>Date.now()?'licensed':'expired';
 }else{expires=VS_schoolTrial()+5*86400000;status=expires>Date.now()?'trial':'expired';}
 const result={schoolId:VS_project(),allowed:status==='trial'||status==='licensed',status:status,expiresAt:expires,serverTime:Date.now(),licenseHash:hash||null};
 cache.put(key,JSON.stringify(result),300);return result;
}
function VS_setupPlatform(bundle){
 if(!bundle||bundle.projectId!==VS_project())throw new Error('Monitoring setup belongs to a different school');
 if(!/^monitor-[a-f0-9]{24}@vidyasaarthi\.invalid$/.test(String(bundle.monitorEmail||''))||!/^[a-f0-9]{48}$/.test(String(bundle.monitorPassword||'')))throw new Error('Copy a fresh school setup from the developer website');
 const auth=VS_centralAuth('signInWithPassword',{email:bundle.monitorEmail,password:bundle.monitorPassword,returnSecureToken:true});
 const props=PropertiesService.getScriptProperties();
 props.setProperties({VS_MONITOR_EMAIL:bundle.monitorEmail,VS_MONITOR_PASSWORD:bundle.monitorPassword,VS_MONITOR_ID_TOKEN:auth.idToken,VS_MONITOR_TOKEN_UNTIL:String(Date.now()+3500000)});
 if(bundle.licenseKey)VS_activatePlatformLicense(bundle.licenseKey);
 const installed=ScriptApp.getProjectTriggers().some(t=>t.getHandlerFunction()==='VS_platformMaintenance');
 if(!installed)ScriptApp.newTrigger('VS_platformMaintenance').timeBased().everyMinutes(5).create();
 VS_publishMonitor();return {projectId:VS_project(),configured:true};
}
function VS_monitorToken(){
 const p=PropertiesService.getScriptProperties();if(!p.getProperty('VS_MONITOR_EMAIL'))return '';
 if(Number(p.getProperty('VS_MONITOR_TOKEN_UNTIL'))>Date.now())return p.getProperty('VS_MONITOR_ID_TOKEN');
 const a=VS_centralAuth('signInWithPassword',{email:p.getProperty('VS_MONITOR_EMAIL'),password:p.getProperty('VS_MONITOR_PASSWORD'),returnSecureToken:true});
 p.setProperties({VS_MONITOR_ID_TOKEN:a.idToken,VS_MONITOR_TOKEN_UNTIL:String(Date.now()+3500000)});return a.idToken;
}
function VS_activatePlatformLicense(key){
 key=String(key||'').trim().toUpperCase();if(!/^VS-[A-F0-9]{32}$/.test(key))throw new Error('Enter the licence key supplied by the developer');
 const hash=VS_hash(key),doc=VS_doc(VS_central('get','platform_license_status/'+hash));
 if(!doc||doc.schoolId!==VS_project()||doc.revoked||doc.expiresAt<=Date.now())throw new Error('Licence is expired, revoked or belongs to a different school');
 PropertiesService.getScriptProperties().setProperty('VS_LICENSE_KEY_HASH',hash);
 CacheService.getScriptCache().remove('VS_PLATFORM_STATUS');return VS_platformStatus(true);
}
function VS_platformAdmin(b){
 if(b.schoolProjectId!==VS_project())throw new Error('School identity mismatch');
 const p=PropertiesService.getScriptProperties();
 if(b.action==='platform_activate')return VS_activatePlatformLicense(b.key);
 if(b.action==='platform_notice'){VS_notifySchoolNotice(String(b.noticeId||''));return {sent:true};}
 if(b.action==='platform_complaint')return VS_queueComplaint(b,'admin','windows');
 if(b.action==='platform_bind'||b.action==='platform_heartbeat'){
  p.setProperty('VS_WINDOWS_LAST_ACTIVE',String(Date.now()));
  if(b.version)p.setProperty('VS_WINDOWS_VERSION',String(b.version).slice(0,32));
  // Publishing an aggregate can fail without blocking the school licence.
  try{VS_publishMonitor();}catch(err){console.warn(String(err.message||err));}
  return VS_platformStatus(b.action==='platform_bind');
 }
 if(b.action==='platform_status')return VS_platformStatus();
 throw new Error('Unknown school platform action');
}
function VS_count(col,field,value){
 const query={from:[{collectionId:col}]};
 if(field)query.where={fieldFilter:{field:{fieldPath:field},op:'EQUAL',value:VS_encode(value)}};
 const raw=VS_firestore('post',':runAggregationQuery',{structuredAggregationQuery:{structuredQuery:query,aggregations:[{alias:'total',count:{}}]}})||[];
 return Number(raw[0]&&raw[0].result&&raw[0].result.aggregateFields.total.integerValue||0);
}
function VS_touchPresence(session,version){
 // Approximate live counts are cached in this school only. Eviction can lower
 // the estimate; these caches never authorise access or validate a licence.
 const cache=CacheService.getScriptCache(),id=VS_hash(session.role+'/'+session.personId).slice(0,24),shard=id[0],key='VS_PRESENCE_'+shard;
 const lock=LockService.getScriptLock();if(!lock.tryLock(3000))return;
 try{
  const bucket=JSON.parse(cache.get(key)||'{}'),now=Date.now();
  Object.keys(bucket).forEach(k=>{if(bucket[k].at<now-300000)delete bucket[k];});
  bucket[id]={at:now,role:session.role};cache.put(key,JSON.stringify(bucket),600);
  cache.put('VS_ACTIVITY_AT',String(now),21600);
  if(version)cache.put('VS_MOBILE_VERSION',String(version).slice(0,32),21600);
 }finally{lock.releaseLock();}
}
function VS_presenceCounts(){
 const cache=CacheService.getScriptCache(),now=Date.now();let students=0,teachers=0;
 '0123456789abcdef'.split('').forEach(shard=>{
  const bucket=JSON.parse(cache.get('VS_PRESENCE_'+shard)||'{}');
  Object.keys(bucket).forEach(k=>{const d=bucket[k];if(d.at>=now-300000){if(d.role==='student')students++;else if(d.role==='teacher')teachers++;}});
 });return {students:students,teachers:teachers};
}
function VS_publishMonitor(){
 const p=PropertiesService.getScriptProperties();if(!p.getProperty('VS_MONITOR_EMAIL'))return;
 const lock=LockService.getScriptLock();if(!lock.tryLock(3000))return;
 try{
  if(Date.now()-Number(p.getProperty('VS_MONITOR_LAST_SENT')||0)<301000)return;
  const online=VS_presenceCounts(),data={schoolId:VS_project(),studentCount:VS_count('students_directory'),teacherCount:VS_count('teachers_directory'),
   studentAppUsers:VS_count('mobile_users','role','student'),onlineStudents:online.students,onlineTeachers:online.teachers,
   windowsVersion:p.getProperty('VS_WINDOWS_VERSION')||'',mobileVersion:CacheService.getScriptCache().get('VS_MOBILE_VERSION')||''};
  const lastActive=Math.max(Number(p.getProperty('VS_WINDOWS_LAST_ACTIVE')||0),Number(CacheService.getScriptCache().get('VS_ACTIVITY_AT')||0));
  const fields={lastSeenAt:{timestampValue:new Date(lastActive).toISOString()}};Object.keys(data).forEach(k=>fields[k]=VS_encode(data[k]));
  VS_central('post',':commit',{writes:[{update:{name:'projects/'+VS_CENTRAL_PROJECT+'/databases/(default)/documents/platform_school_summaries/'+VS_project(),fields:fields},
   updateTransforms:[{fieldPath:'reportedAt',setToServerValue:'REQUEST_TIME'}]}]},VS_monitorToken());
  p.setProperty('VS_MONITOR_LAST_SENT',String(Date.now()));
 }finally{lock.releaseLock();}
}
function VS_queueComplaint(b,role,source,personId){
 const message=String(b.message||'').trim();if(message.length<3||message.length>3000)throw new Error('Use 3–3000 characters for the problem');
 const id=VS_project()+'_'+VS_secret().slice(0,32);
 // The school's private queue keeps a report during internet/quota outages.
 const limitId=VS_hash((personId||'admin')+'/'+VS_day()),limit=VS_get('support_limits',limitId)||{count:0};
 if(limit.count>=5)throw new Error('Five reports per person per day are allowed');
 VS_set('support_limits',limitId,{count:limit.count+1});
 VS_set('support_outbox',id,{schoolId:VS_project(),source:source,role:role,message:message,version:String(b.version||'').slice(0,32),status:'open',createdAt:Date.now()});
 try{VS_flushSupport();}catch(err){console.warn(String(err.message||err));}
 return {queued:true};
}
function VS_flushSupport(){
 const token=VS_monitorToken();if(!token)return;
 const props=PropertiesService.getScriptProperties();if(Date.now()-Number(props.getProperty('VS_SUPPORT_LAST_SENT')||0)<31000)return;
 const raw=VS_firestore('post',':runQuery',{structuredQuery:{from:[{collectionId:'support_outbox'}],limit:1}})||[];
 if(!raw[0]||!raw[0].document)return;const report=VS_doc(raw[0].document),id=report.id;delete report.id;delete report.createdAt;
 const fields={};Object.keys(report).forEach(k=>fields[k]=VS_encode(report[k]));
 try{
  VS_central('post',':commit',{writes:[
   {update:{name:'projects/'+VS_CENTRAL_PROJECT+'/databases/(default)/documents/platform_complaints/'+id,fields:fields},currentDocument:{exists:false},updateTransforms:[{fieldPath:'createdAt',setToServerValue:'REQUEST_TIME'}]},
   {update:{name:'projects/'+VS_CENTRAL_PROJECT+'/databases/(default)/documents/platform_support_limits/'+VS_project(),fields:{complaintId:VS_encode(id)}},updateTransforms:[{fieldPath:'lastSentAt',setToServerValue:'REQUEST_TIME'}]}
  ]},token);
 }catch(err){if(err.httpCode!==409)throw err;}
 props.setProperty('VS_SUPPORT_LAST_SENT',String(Date.now()));VS_firestore('delete','support_outbox/'+encodeURIComponent(id));
}
function VS_setupMessaging(androidAppId,senderId){
 if(!/^\d+$/.test(String(senderId))||!new RegExp('^1:'+senderId+':android:[a-fA-F0-9]+$').test(String(androidAppId)))throw new Error('Use the Android app ID and project number from this school Firebase Android app (com.example.saarthi_ai)');
 PropertiesService.getScriptProperties().setProperties({VS_ANDROID_APP_ID:String(androidAppId),VS_FCM_SENDER_ID:String(senderId)});
 return {projectId:VS_project(),configured:true};
}
function VS_messagingOptions(){
 const p=PropertiesService.getScriptProperties(),appId=p.getProperty('VS_ANDROID_APP_ID'),sender=p.getProperty('VS_FCM_SENDER_ID');
 return appId&&sender?{projectId:VS_project(),apiKey:p.getProperty('VS_FIREBASE_API_KEY'),appId:appId,messagingSenderId:sender}:null;
}
function VS_notifySchoolNotice(id){
 if(!id||id.length>180)throw new Error('Invalid school notice');
 const notice=VS_get('school_notices',id);if(!notice)throw new Error('School notice has not synced yet');
 const job=VS_get('notification_jobs',VS_hash(id));if(job&&job.sent)return;
 if(!VS_messagingOptions())throw new Error('Complete this school Android messaging setup first');
 // Topics carry only an invalidation signal. Private titles/messages are fetched
 // through the recipient's authenticated school session, including in background.
 const r=UrlFetchApp.fetch('https://fcm.googleapis.com/v1/projects/'+encodeURIComponent(VS_project())+'/messages:send',{
  method:'post',contentType:'application/json',headers:{Authorization:'Bearer '+ScriptApp.getOAuthToken()},muteHttpExceptions:true,
  payload:JSON.stringify({message:{topic:'school_notices',data:{schoolId:VS_project(),type:'school_notice',noticeId:id},android:{priority:'high',ttl:'86400s'}}})});
 if(r.getResponseCode()!==200)throw new Error('School notification could not be sent. Check the school Cloud Messaging API and Apps Script permission.');
 VS_set('notification_jobs',VS_hash(id),{sent:true,sentAt:Date.now()});
}
function VS_platformMaintenance(){
 try{VS_publishMonitor();}catch(e){console.warn(String(e.message||e));}
 try{VS_flushSupport();}catch(e){console.warn(String(e.message||e));}
}
