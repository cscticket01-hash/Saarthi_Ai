/** Add this file to each SCHOOL'S own Apps Script project.
 * At the top of existing doPost(e):
 *   const mobile = VS_handleMobile(e); if (mobile) return mobile;
 * Run VS_setupSchool('your-school-firebase-project-id', 'your-school-api-key') once as script owner.
 * All Firestore calls use the script owner's OAuth identity. Never expose it.
 */
function VS_setupSchool(projectId, apiKey) {
  if (!/^[a-z][a-z0-9-]{4,61}[a-z0-9]$/.test(projectId)) throw new Error('Invalid Firebase project ID');
  if(!/^AIza[A-Za-z0-9_-]{20,}$/.test(String(apiKey||'')))throw new Error('Supply this school Firebase Web API key as the second setup argument');
  PropertiesService.getScriptProperties().setProperty('VS_FIREBASE_PROJECT_ID', projectId);
  PropertiesService.getScriptProperties().setProperty('VS_FIREBASE_API_KEY', String(apiKey));
  VS_firestore('GET', 'school_settings/calendar');
}
function VS_project() { const p=PropertiesService.getScriptProperties().getProperty('VS_FIREBASE_PROJECT_ID'); if(!p)throw new Error('School mobile integration has not been configured');return p; }
function VS_hash(s) {return Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,String(s)).map(v=>('0'+((v+256)%256).toString(16)).slice(-2)).join('');}
function VS_secret() {return Utilities.getUuid().replace(/-/g,'')+Utilities.getUuid().replace(/-/g,'');}
function VS_encode(v) {if(v===null||v===undefined)return {nullValue:null};if(typeof v==='boolean')return {booleanValue:v};if(typeof v==='number')return Number.isInteger(v)?{integerValue:String(v)}:{doubleValue:v};if(Array.isArray(v))return {arrayValue:{values:v.map(VS_encode)}};if(typeof v==='object'){const fields={};Object.keys(v).forEach(k=>fields[k]=VS_encode(v[k]));return {mapValue:{fields:fields}};}return {stringValue:String(v)};}
function VS_decode(v) {if(v.stringValue!==undefined)return v.stringValue;if(v.integerValue!==undefined)return Number(v.integerValue);if(v.doubleValue!==undefined)return v.doubleValue;if(v.booleanValue!==undefined)return v.booleanValue;if(v.timestampValue!==undefined)return Date.parse(v.timestampValue);if(v.mapValue){const o={};Object.keys(v.mapValue.fields||{}).forEach(k=>o[k]=VS_decode(v.mapValue.fields[k]));return o;}if(v.arrayValue)return (v.arrayValue.values||[]).map(VS_decode);return null;}
function VS_doc(raw) {if(!raw||!raw.fields)return null;const o={id:raw.name.split('/').pop()};Object.keys(raw.fields).forEach(k=>o[k]=VS_decode(raw.fields[k]));return o;}
function VS_firestore(method,path,data) {
 const base='https://firestore.googleapis.com/v1/projects/'+encodeURIComponent(VS_project())+'/databases/(default)/documents/';
 const opt={method:method,muteHttpExceptions:true,headers:{Authorization:'Bearer '+ScriptApp.getOAuthToken()}};
 if(data){opt.contentType='application/json';opt.payload=JSON.stringify(data);}
 const r=UrlFetchApp.fetch(base+path,opt);const code=r.getResponseCode();if(code===404)return null;const body=JSON.parse(r.getContentText()||'{}');if(code>=400)throw new Error('School database operation failed ('+code+')');return body;
}
function VS_get(col,id){return VS_doc(VS_firestore('GET',col+'/'+encodeURIComponent(id)));}
function VS_set(col,id,data){const fields={};Object.keys(data).forEach(k=>fields[k]=VS_encode(data[k]));return VS_doc(VS_firestore('PATCH',col+'/'+encodeURIComponent(id),{fields:fields}));}
function VS_query(col,field,value){const query={from:[{collectionId:col}]};if(field)query.where={fieldFilter:{field:{fieldPath:field},op:'EQUAL',value:VS_encode(value)}};const result=VS_firestore('POST',':runQuery',{structuredQuery:query})||[];return result.filter(r=>r.document).map(r=>VS_doc(r.document));}
function VS_dob(raw){if(raw instanceof Date&&!isNaN(raw.getTime()))return Utilities.formatDate(raw,'Asia/Kolkata','yyyy-MM-dd');const s=String(raw||'').trim();const m=s.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})$/);if(m)return m[3]+'-'+('0'+m[2]).slice(-2)+'-'+('0'+m[1]).slice(-2);const iso=s.match(/^(\d{4})-(\d{2})-(\d{2})/);if(iso)return iso[0];return s.toLowerCase();}
function VS_day(){return Utilities.formatDate(new Date(),'Asia/Kolkata','yyyy-MM-dd');}
function VS_isOpen(day){const d=VS_get('school_calendar',day);if(d&&typeof d.isOpen==='boolean')return d.isOpen;const config=VS_get('school_settings','calendar')||{};const closed=config.closedWeekdays||[0];return closed.indexOf(new Date(day+'T12:00:00+05:30').getUTCDay())<0;}
function VS_person(b){const type=b.role||b.type;if(type!=='student'&&type!=='teacher')throw new Error('Invalid QR role');const col=type==='teacher'?'teachers_directory':'students_directory';const token=String(b.linkToken||'');if(token.length<20)throw new Error('This ID card needs a new secure school QR');let p=VS_get(col,String(b.personId||''));if(!p||p.mobileLinkToken!==token){const found=VS_query(col,'mobileLinkToken',token);p=found.length===1?found[0]:null;}if(!p||p.mobileLinkToken!==token)throw new Error('This QR does not belong to the active school');return {person:p,role:type};}
function VS_session(b){const token=String(b.sessionToken||'');if(token.length<40)throw new Error('School login required');const doc=VS_get('mobile_sessions',VS_hash(token));if(!doc||doc.expiresAt<=Date.now())throw new Error('School session expired');let person=VS_get(doc.role==='teacher'?'teachers_directory':'students_directory',doc.documentId);if(!person||person.mobileLinkToken!==doc.linkToken){const found=VS_query(doc.role==='teacher'?'teachers_directory':'students_directory','mobileLinkToken',doc.linkToken);person=found.length===1?found[0]:null;}if(!person||person.mobileLinkToken!==doc.linkToken)throw new Error('School record or ID card was changed; scan again');return {doc:doc,person:person,role:doc.role,personId:person.mobileStableId||doc.personId};}
function VS_own(col,session){const records=VS_query(col,'personId',session.personId).concat(VS_query(col,'studentId',session.person.id));const seen={};return records.filter(d=>{if(d.personId){if(d.personId!==session.personId)return false;}else{const name=String(d.studentName||d.name||'').trim().toLowerCase(),owner=String(session.person.name||'').trim().toLowerCase();if(!name||name!==owner)return false;if((d.dob||d.dateOfBirth)&&VS_dob(d.dob||d.dateOfBirth)!==VS_dob(session.person.dob||session.person.dateOfBirth))return false;}if(seen[d.id])return false;seen[d.id]=true;return true;});}
function VS_safePerson(p){const allowed=['id','name','class','rollNo','dob','dateOfBirth','parentName','fatherName','parentContact','photoUrl','studentUid','teacherId','designation','subject','idCardUrl','mobileStableId'];const out={};allowed.forEach(k=>{if(p[k]!==undefined)out[k]=p[k];});return out;}
function VS_distance(a,b,c,d){const rad=x=>x*Math.PI/180;const h=Math.sin(rad(c-a)/2)**2+Math.cos(rad(a))*Math.cos(rad(c))*Math.sin(rad(d-b)/2)**2;return 6371000*2*Math.atan2(Math.sqrt(h),Math.sqrt(1-h));}
function VS_handleMobile(e){
 let b;try{b=JSON.parse(e.postData.contents);}catch(_){return null;}
 if(!String(b.action||'').startsWith('mobile_')){
  try{
   VS_requireAdmin(b);
   if(['mark_attendance','mark_student_attendance','mark_teacher_attendance'].indexOf(b.action)>=0&&!VS_isOpen(VS_day()))throw new Error('School is closed today. Attendance is disabled for everyone');
   if(b.action==='change_student_class' && b.newRollNo!==undefined)return ContentService.createTextOutput(JSON.stringify(Object.assign({success:true},VS_changeStudentClass(b)))).setMimeType(ContentService.MimeType.JSON);
   return null;
  }catch(err){return ContentService.createTextOutput(JSON.stringify({success:false,code:'SCHOOL_ADMIN_REQUIRED',message:String(err.message||err)})).setMimeType(ContentService.MimeType.JSON);}
 }
 let result;
 try{result=VS_mobileAction(b);result=Object.assign({success:true,projectId:VS_project()},result);}catch(err){result={success:false,message:String(err.message||err)};}
 return ContentService.createTextOutput(JSON.stringify(result)).setMimeType(ContentService.MimeType.JSON);
}
function VS_mobileAction(b){
 const action=b.action;
 if(action==='mobile_project_info')return {projectId:VS_project(),windowsAdminProtection:!!PropertiesService.getScriptProperties().getProperty('VS_FIREBASE_API_KEY'),mobileProtocol:3};
 if(action==='mobile_login'){
  const expected=VS_project();if(b.projectId!==expected)throw new Error('The QR Firebase project and this school backend do not match');
  const verified=VS_person(b);const p=verified.person;
  if(verified.role==='student'){
   const selected=String(b.studentClass||'').replace(/[^0-9]/g,'');const assigned=String(p.class||'').replace(/[^0-9]/g,'');
   const roll=String(b.rollNo||'').replace(/^0+/,'');const savedRoll=String(p.rollNo||'').replace(/^0+/,'');
   if(!selected||selected!==assigned||!roll||roll!==savedRoll||!VS_dob(b.dob)||!VS_dob(p.dob||p.dateOfBirth)||VS_dob(b.dob)!==VS_dob(p.dob||p.dateOfBirth))throw new Error('Class, roll number or date of birth is incorrect');
  }
  const token=VS_secret();const expires=Date.now()+30*86400000;const stable=p.mobileStableId||p.id;
  VS_set('mobile_sessions',VS_hash(token),{personId:stable,documentId:p.id,role:verified.role,linkToken:p.mobileLinkToken,expiresAt:expires,createdAt:Date.now()});
  return {sessionToken:token,personId:stable,role:verified.role,expiresAt:expires,person:VS_safePerson(p)};
 }
 if(b.projectId && b.projectId!==VS_project())throw new Error('School identity mismatch');
 const session=VS_session(b);
 if(action!=='mobile_session_verify'&&action!=='mobile_logout')VS_requireLicense();
 if(action==='mobile_session_verify')return {personId:session.personId,role:session.role,expiresAt:session.doc.expiresAt};
 if(action==='mobile_logout'){VS_firestore('DELETE','mobile_sessions/'+VS_hash(b.sessionToken));return {loggedOut:true};}
 if(action==='mobile_dashboard'){
  const profile=VS_get('school_config','school_profile_cache')||VS_get('school_settings','school_profile')||{};
  const notices=VS_query('school_notices').sort((a,c)=>(c.timestamp||c.createdAt||0)-(a.timestamp||a.createdAt||0)).slice(0,100);
  const result={person:VS_safePerson(session.person),school:profile,notices:notices,templates:VS_get('school_settings','document_templates')||{},calendar:VS_query('school_calendar'),calendarSettings:VS_get('school_settings','calendar')||{closedWeekdays:[0]}};
  if(session.role==='student'){
   result.reportCards=VS_own('exam_results',session);
   result.fees=VS_own('fee_ledger',session);
   result.payments=VS_own('fee_payments',session);
  }else{result.salary=VS_query('teacher_salary','teacherId',session.person.teacherId||session.person.id);}
  return result;
 }
 if(action==='mobile_attendance_list'){
  const month=String(b.month||'');if(!/^\d{4}-\d{2}$/.test(month))throw new Error('Select a month');
  return {attendance:VS_query('attendance_records','personId',session.personId).filter(d=>String(d.date||'').startsWith(month)),calendar:VS_query('school_calendar').filter(d=>d.id.startsWith(month)),calendarSettings:VS_get('school_settings','calendar')||{closedWeekdays:[0]}};
 }
 if(action==='mobile_mark_attendance'){
  const day=VS_day();if(!VS_isOpen(day))throw new Error('School is closed today. Attendance is disabled for everyone');
  const loc=VS_get('school_settings','school_location')||{};const lat=Number(b.latitude),lng=Number(b.longitude);
  if(!Number.isFinite(lat)||!Number.isFinite(lng)||Math.abs(lat)>90||Math.abs(lng)>180)throw new Error('Enable your device location');
  if(loc.latitude===undefined||loc.longitude===undefined)throw new Error('School location is not configured');
  const distance=VS_distance(lat,lng,Number(loc.latitude),Number(loc.longitude));if(distance>Number(loc.radiusMeters||200))throw new Error('Attendance can be marked only within the school location');
  // A scan at attendance time must be the same person as the verified session.
  const qr=VS_person(b);if(qr.role!==session.role||qr.person.mobileLinkToken!==session.person.mobileLinkToken)throw new Error('Scan your own school ID card');
  const id=VS_hash(session.role+'/'+session.personId+'/'+day);const lock=LockService.getScriptLock();lock.waitLock(20000);
  try{
   const current=VS_get('attendance_records',id)||{};const mode=b.mode==='exit'?'exit':'entry';
   if(mode==='entry'&&current.checkIn)throw new Error('Today’s check-in is already recorded');
   if(mode==='exit'&&!current.checkIn)throw new Error('Check in before checking out');
   if(mode==='exit'&&current.checkOut)throw new Error('Today’s check-out is already recorded');
   const doc=Object.assign({},current,{personId:session.personId,documentId:session.person.id,role:session.role,name:session.person.name||'',studentClass:session.person.class||'',rollNo:session.person.rollNo||'',date:day,source:'ANDROID_QR',updatedAt:Date.now()});delete doc.id;
   doc[mode==='entry'?'checkIn':'checkOut']=Date.now();VS_set('attendance_records',id,doc);
   return {message:mode==='entry'?'Check-in recorded':'Check-out recorded',record:doc};
  }finally{lock.releaseLock();}
 }
 throw new Error('Unknown school mobile action');
}

function VS_requireLicense(){
 const key='VS_LICENSE_LEASE';const props=PropertiesService.getScriptProperties();let lease;try{lease=JSON.parse(props.getProperty(key)||'null');}catch(_){}
 if(!lease||Date.now()-lease.checkedAt>300000){const response=UrlFetchApp.fetch('https://asia-south1-saarthi-ai-df12b.cloudfunctions.net/platformApi',{method:'post',contentType:'application/json',payload:JSON.stringify({action:'school/public_status',projectId:VS_project()}),muteHttpExceptions:true});const d=JSON.parse(response.getContentText());if(!d.success)throw new Error('School license service unavailable');lease={allowed:d.allowed,expiresAt:d.expiresAt,checkedAt:Date.now()};props.setProperty(key,JSON.stringify(lease));}
 if(!lease.allowed||lease.expiresAt<=Date.now())throw new Error('School trial or licence has ended');
}

// Legacy Windows actions carry a refreshed Firebase ID token. A QR exposes only
// public connection details, never an administrator token or an owner credential.
function VS_requireAdmin(b){
 const project=VS_project();const apiKey=PropertiesService.getScriptProperties().getProperty('VS_FIREBASE_API_KEY');
 if(!apiKey)throw new Error('School owner must complete VS_setupSchool(projectId, apiKey)');
 const token=String(b.schoolAdminIdToken||'');if(b.schoolProjectId!==project||token.length<40)throw new Error('This school administrator login is required');
 const cache=CacheService.getScriptCache(),key='VS_ADMIN_'+VS_hash(project+'/'+token);if(cache.get(key)==='ok')return;
 let claims;try{claims=JSON.parse(Utilities.newBlob(Utilities.base64DecodeWebSafe(token.split('.')[1])).getDataAsString());}catch(_){throw new Error('Invalid school administrator token');}
 if(claims.aud!==project||claims.iss!=='https://securetoken.google.com/'+project||claims.exp*1000<=Date.now()||(claims.admin!==true&&claims.role!=='admin'))throw new Error('Administrator proof belongs to a different school or has expired');
 // accounts:lookup verifies the complete signed Firebase ID token, not just its payload.
 const r=UrlFetchApp.fetch('https://identitytoolkit.googleapis.com/v1/accounts:lookup?key='+encodeURIComponent(apiKey),{method:'post',contentType:'application/json',payload:JSON.stringify({idToken:token}),muteHttpExceptions:true});
 const d=JSON.parse(r.getContentText());const user=(d.users||[])[0];
 if(r.getResponseCode()!==200||!user||user.disabled||user.localId!==claims.sub||Number(user.validSince||0)>Number(claims.auth_time||0))throw new Error('School administrator verification failed');
 cache.put(key,'ok',Math.max(1,Math.min(60,Math.floor(claims.exp-Date.now()/1000))));
}

// Uses the existing school sheet helpers. A free destination roll avoids the
// normal annual collision when the older class has not finished its exam yet.
function VS_changeStudentClass(b){
 if(typeof getOrCreateDatabaseSheet!=='function'||typeof findStudentRow!=='function')throw new Error('This school backend needs the current student sheet helpers');
 const oldClass=String(b.oldClass||''),newClass=String(b.newClass||''),oldRoll=String(b.rollNo||''),newRoll=String(b.newRollNo||oldRoll);
 if(!oldClass||!newClass||!/^\d+$/.test(oldRoll)||!/^\d+$/.test(newRoll))throw new Error('Valid class and roll required');
 const sheet=getOrCreateDatabaseSheet(STUDENT_SHEET_NAME,STUDENT_HEADERS),lock=LockService.getScriptLock();lock.waitLock(20000);
 try{
  const from=findStudentRow(sheet,oldClass,oldRoll),to=findStudentRow(sheet,newClass,newRoll);
  function samePerson(row){return String(b.studentName||'').trim().toLowerCase()===String(row[0]||'').trim().toLowerCase()&&(!b.dob||VS_dob(b.dob)===VS_dob(row[STUDENT_HEADERS.indexOf('Date of Birth')]));}
  if(from===-1&&to>1){if(!samePerson(sheet.getRange(to,1,1,STUDENT_HEADERS.length).getValues()[0]))throw new Error('Destination belongs to another student');return {alreadyChanged:true,newClass:newClass,rollNo:newRoll};}
  if(from===-1)throw new Error('Student old class not found');
  if(to>1&&to!==from)throw new Error('Destination roll is occupied; refresh and retry');
  const studentRange=sheet.getRange(from,1,1,STUDENT_HEADERS.length),previousStudent=studentRange.getValues(),nextStudent=previousStudent.map(row=>row.slice());
  if(!samePerson(previousStudent[0]))throw new Error('Student record changed; refresh before promotion');
  nextStudent[0][2]=newClass;nextStudent[0][3]=newRoll;nextStudent[0][STUDENT_HEADERS.length-1]=new Date();
  const documents=getOrCreateDatabaseSheet(STUDENT_DOCUMENT_INDEX_SHEET,STUDENT_DOCUMENT_HEADERS);
  let documentRange,previousDocuments,nextDocuments,changed=false;
  if(documents.getLastRow()>1){documentRange=documents.getRange(2,1,documents.getLastRow()-1,STUDENT_DOCUMENT_HEADERS.length);previousDocuments=documentRange.getValues();nextDocuments=previousDocuments.map(row=>row.slice());nextDocuments.forEach(row=>{if(String(row[1])===String(b.oldStudentId)||(normalizeClass(row[3])===normalizeClass(oldClass)&&normalizeRoll(row[4])===normalizeRoll(oldRoll))){row[1]=b.newStudentId;row[3]=newClass;row[4]=newRoll;changed=true;}});}
  try{studentRange.setValues(nextStudent);if(changed)documentRange.setValues(nextDocuments);}
  catch(error){studentRange.setValues(previousStudent);if(changed)documentRange.setValues(previousDocuments);throw error;}
  return {newClass:newClass,rollNo:newRoll,oldStudentId:b.oldStudentId,newStudentId:b.newStudentId};
 }finally{lock.releaseLock();}
}
