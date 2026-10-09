/** Managed mobile bridge. Only called AFTER central server verification and
 * the adapter's HMAC/replay verification. Legacy per-project code is untouched. */
function VS_managedMobile(request,lease) {
 const lock=LockService.getScriptLock();lock.waitLock(30000);
 try{return VS_managedMobileUnlocked(request,lease);}finally{lock.releaseLock();}
}
function VS_managedMobileUnlocked(request,lease) {
 const school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID');
 if(!lease||lease.schoolId!==school||lease.expiresAt<=Date.now())throw new Error('School licence is inactive');
 function VS_project(){return school;}
 function VS_requireLicense(){if(lease.expiresAt<=Date.now())throw new Error('School licence expired');}
 const recordCache={},storeCache={},readContext={};
 function VS_store(col){return storeCache[col]||(storeCache[col]=VS_managedSheet(col,readContext));}
 function VS_records(col){if(recordCache[col])return recordCache[col];const all=VS_sheetRecords(VS_store(col)),rows=Object.create(null);Object.keys(all).forEach(id=>{if(!all[id]._syncDeleted)rows[id]=all[id];});return recordCache[col]=rows;}
 function VS_get(col,id){const item=VS_sheetItem(VS_store(col),String(id));if(!item||item.data._syncDeleted)return null;return Object.assign({},item.data,{id:String(id)});}
 function VS_query(col,field,value){const records=VS_records(col);return Object.keys(records).filter(id=>!field||records[id][field]===value).map(id=>Object.assign({},records[id],{id:id}));}
 function VS_set(col,id,data){const request={operation:'write',collection:col,id:id,data:Object.assign({},data,{schoolId:school})};if(col==='attendance_records'){request.syncProtocol=2;request.operationId=Utilities.getUuid();request.expectedRecordRevision=data._syncRevision||'';}VS_managedRecordUnlocked(request);delete recordCache[col];return Object.assign({},data,{id:id});}
 function VS_firestore(method,path){if(method!=='DELETE'||path.indexOf('mobile_sessions/')!==0)throw new Error('Unsupported mobile operation');VS_managedRecordUnlocked({operation:'delete',collection:'mobile_sessions',id:path.slice(16)});}
 function VS_touchPresence(){} // Windows presence is central and cannot be renewed by mobile.
 function VS_messagingOptions(){return null;} // No per-school Firebase project is required.
 function VS_mobileSchoolProfile(){const p=VS_get('school_config','school_profile_cache')||{};const out={};['schoolName','principalName','schoolContactNo'].forEach(k=>{if(p[k]!==undefined)out[k]=p[k];});return out;}
 function VS_queueComplaint(b,role,app,personId){const text=String(b.message||b.description||'').slice(0,3000);if(!text)throw new Error('Describe the problem');VS_set('mobile_complaints',VS_secret(),{message:text,role:role,personId:personId,createdAt:Date.now()});return {message:'Problem reported to school'};}
 function VS_mobileAsset(b,session){const profile=VS_get('school_config','school_profile_cache')||{};let url;if(b.kind==='photo')url=session.person.photoUrl;else if(b.kind==='logo')url=profile.logoUrl;else if(b.kind==='signature')url=profile.principalSignatureUrl;else if(b.kind==='seal')url=profile.sealUrl;else throw new Error('Invalid asset');const match=String(url||'').match(/\/file\/d\/([A-Za-z0-9_-]+)/);if(!match)throw new Error('School Drive asset unavailable');const blob=VS_managedFile(match[1]).getBlob();if(blob.getBytes().length>5*1024*1024)throw new Error('Asset too large');return {base64:Utilities.base64Encode(blob.getBytes()),mime:blob.getContentType()};}
function VS_hash(s) {return Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,String(s)).map(v=>('0'+((v+256)%256).toString(16)).slice(-2)).join('');}
function VS_secret() {return Utilities.getUuid().replace(/-/g,'')+Utilities.getUuid().replace(/-/g,'');}
function VS_dob(raw){if(raw instanceof Date&&!isNaN(raw.getTime()))return Utilities.formatDate(raw,'Asia/Kolkata','yyyy-MM-dd');const s=String(raw||'').trim();const m=s.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})$/);if(m)return m[3]+'-'+('0'+m[2]).slice(-2)+'-'+('0'+m[1]).slice(-2);const iso=s.match(/^(\d{4})-(\d{2})-(\d{2})/);if(iso)return iso[0];return s.toLowerCase();}
function VS_day(){return Utilities.formatDate(new Date(),'Asia/Kolkata','yyyy-MM-dd');}
function VS_isOpen(day){const d=VS_get('school_calendar',day);if(d&&typeof d.isOpen==='boolean')return d.isOpen;const config=VS_get('school_settings','calendar')||{};const closed=config.closedWeekdays||[0];return closed.indexOf(new Date(day+'T12:00:00+05:30').getUTCDay())<0;}
function VS_person(b){const type=b.role||b.type;if(type!=='student'&&type!=='teacher')throw new Error('Invalid QR role');const col=type==='teacher'?'teachers_directory':'students_directory';const token=String(b.linkToken||'');if(token.length<20)throw new Error('This ID card needs a new secure school QR');let p=VS_get(col,String(b.personId||''));if(!p||p.mobileLinkToken!==token){const found=VS_query(col,'mobileLinkToken',token);p=found.length===1?found[0]:null;}if(!p||p.mobileLinkToken!==token)throw new Error('This QR does not belong to the active school');return {person:p,role:type};}
function VS_session(b){const token=String(b.sessionToken||'');if(token.length<40)throw new Error('School login required');const doc=VS_get('mobile_sessions',VS_hash(token));if(!doc||(b.action!=='mobile_refresh'&&doc.expiresAt<=Date.now()))throw new Error('School session expired');let person=VS_get(doc.role==='teacher'?'teachers_directory':'students_directory',doc.documentId);if(!person||person.mobileLinkToken!==doc.linkToken){const found=VS_query(doc.role==='teacher'?'teachers_directory':'students_directory','mobileLinkToken',doc.linkToken);person=found.length===1?found[0]:null;}if(!person||person.mobileLinkToken!==doc.linkToken)throw new Error('School record or ID card was changed; scan again');return {doc:doc,person:person,role:doc.role,personId:person.mobileStableId||doc.personId};}
function VS_own(col,session){const records=VS_query(col,'personId',session.personId).concat(VS_query(col,'studentId',session.person.id));const seen=Object.create(null);return records.filter(d=>{if(d.personId){if(d.personId!==session.personId)return false;}else{const name=String(d.studentName||d.name||'').trim().toLowerCase(),owner=String(session.person.name||'').trim().toLowerCase();if(!name||name!==owner)return false;if((d.dob||d.dateOfBirth)&&VS_dob(d.dob||d.dateOfBirth)!==VS_dob(session.person.dob||session.person.dateOfBirth))return false;}if(seen[d.id])return false;seen[d.id]=true;return true;});}
function VS_safePerson(p){const allowed=['id','name','class','rollNo','dob','dateOfBirth','parentName','fatherName','parentContact','photoUrl','studentUid','teacherId','designation','subject','idCardUrl','mobileStableId'];const out={};allowed.forEach(k=>{if(p[k]!==undefined)out[k]=p[k];});return out;}
function VS_distance(a,b,c,d){const rad=x=>x*Math.PI/180;const h=Math.sin(rad(c-a)/2)**2+Math.cos(rad(a))*Math.cos(rad(c))*Math.sin(rad(d-b)/2)**2;return 6371000*2*Math.atan2(Math.sqrt(h),Math.sqrt(1-h));}
function VS_attendancePolicy(session){const loc=VS_get('school_settings','school_location')||{},day=VS_day();return {role:session.role,personId:session.personId,documentId:session.person.id,qrHash:VS_hash(session.role+'/'+session.person.id+'/'+session.doc.linkToken),day:day,open:VS_isOpen(day),latitude:loc.latitude,longitude:loc.longitude,radiusMeters:loc.radiusMeters||200};}
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
  VS_requireLicense();
  const token=VS_secret();const expires=Date.now()+30*86400000;const stable=p.mobileStableId||p.id;
  VS_set('mobile_sessions',VS_hash(token),{personId:stable,documentId:p.id,role:verified.role,linkToken:p.mobileLinkToken,expiresAt:expires,createdAt:Date.now()});
  VS_set('mobile_users',VS_hash(verified.role+'/'+stable),{role:verified.role});
  return {sessionToken:token,personId:stable,role:verified.role,expiresAt:expires,person:VS_safePerson(p),messaging:VS_messagingOptions(),schoolName:VS_mobileSchoolProfile().schoolName||'School'};
 }
 if(b.projectId && b.projectId!==VS_project())throw new Error('School identity mismatch');
 const session=VS_session(b);
 if(action!=='mobile_session_verify'&&action!=='mobile_logout')VS_requireLicense();
 if(action==='mobile_refresh'){VS_requireLicense();const expires=Date.now()+30*86400000;VS_set('mobile_sessions',VS_hash(b.sessionToken),Object.assign({},session.doc,{expiresAt:expires}));return {personId:session.personId,role:session.role,expiresAt:expires,attendancePolicy:VS_attendancePolicy(session)};}
 if(action==='mobile_session_verify')return {personId:session.personId,role:session.role,expiresAt:session.doc.expiresAt};
 if(action==='mobile_logout'){VS_firestore('DELETE','mobile_sessions/'+VS_hash(b.sessionToken));return {loggedOut:true};}
 if(action==='mobile_heartbeat'){VS_touchPresence(session,b.version);return {allowed:true};}
 if(action==='mobile_messaging_config')return {messaging:VS_messagingOptions()};
 if(action==='mobile_complaint')return VS_queueComplaint(b,session.role,'android',session.personId);
 if(action==='mobile_notice'){const notice=VS_get('school_notices',String(b.noticeId||''));if(!notice)throw new Error('School notice unavailable');return {notice:notice};}
 if(action==='mobile_asset')return VS_mobileAsset(b,session);
 if(action==='mobile_dashboard'){
  VS_touchPresence(session,b.version);
  const props=PropertiesService.getScriptProperties(),known=b.knownRevisions||{};
  const policy=VS_attendancePolicy(session);
  const revisions={},result={person:VS_safePerson(session.person),attendancePolicy:policy,sessionExpiresAt:session.doc.expiresAt};
  const groups={school:'school_config',templates:'school_settings',notices:'school_notices',calendar:'school_calendar',documents:'documents',examinations:'exams'};
  if(session.role==='student')Object.assign(groups,{reportCards:'exam_results',fees:'fee_ledger',payments:'fee_payments',feeStructures:'fee_settings'});
  else groups.salary='teacher_salary';
  Object.keys(groups).forEach(key=>{
   const col=groups[key];if(props.getProperty('VS_SHEET_MIGRATED_'+col)!=='1')VS_managedSheet(col);
   if(key==='reportCards'&&props.getProperty('VS_SHEET_MIGRATED_exam_center_results')!=='1')VS_managedSheet('exam_center_results');
   const revision=key==='reportCards'
    ? JSON.stringify([props.getProperty('VS_RECORD_REV_exam_results')||'legacy',props.getProperty('VS_RECORD_REV_exam_center_results')||'legacy'])
    : props.getProperty('VS_RECORD_REV_'+col)||'legacy';revisions[key]=revision;
   if(known[key]===revision)return;
   if(key==='school')result.school=VS_mobileSchoolProfile();
   else if(key==='templates'){result.templates=VS_get('school_settings','document_templates')||{};result.calendarSettings=VS_get('school_settings','calendar')||{closedWeekdays:[0]};}
   else if(key==='notices'){
    const notices=VS_query(col).sort((a,c)=>(c.timestamp||c.createdAt||0)-(a.timestamp||a.createdAt||0)).slice(0,100).map(n=>Object.assign({},n,{_noticeRevision:n._syncRevision||VS_hash(JSON.stringify(n))}));
    const prior=b.knownNoticeRevisions&&typeof b.knownNoticeRevisions==='object'?b.knownNoticeRevisions:{};
    result.noticeIds=notices.map(n=>n.id);result.noticesDelta=true;
    result.notices=notices.filter(n=>prior[n.id]!==n._noticeRevision);
   }
   else if(key==='examinations')result.examinations=VS_query(col);
   else if(key==='feeStructures'){const normalize=value=>String(value||'').toLowerCase().replace(/[ _]/g,'').replace(/^class/,'');const assigned=normalize(session.person.class);result.feeStructures=VS_query(col).filter(row=>assigned&&normalize(row.className||row.class||String(row.id).split('__')[0])===assigned);}
   else if(key==='calendar')result.calendar=VS_query(col);
   else if(key==='salary')result.salary=VS_query(col,'teacherId',session.person.teacherId||session.person.id);
   else if(key==='documents'){
    const docs=VS_own(col,session).filter(d=>!d.deleted&&!d._syncDeleted);
    result.documents=docs.filter(d=>d.documentKind!=='idCard').map(d=>({documentId:d.id,documentName:d.documentName,mimeType:d.mimeType,sizeBytes:d.sizeBytes,documentRevision:d.documentRevision,contentHash:d.contentHash}));
    const card=docs.find(d=>d.documentKind==='idCard'&&d.ownerRole===session.role);
    result.idCardPackage=card?{documentId:card.id,documentRevision:card.documentRevision,contentHash:card.contentHash,sizeBytes:card.sizeBytes}:null;
   } else if(key==='reportCards') {
    // Both existing writers remain authoritative. A tombstone in either store
    // suppresses its duplicate; do not revive results through the other writer.
    const canonical=VS_sheetRecords(VS_store('exam_results'));
    const centre=VS_sheetRecords(VS_store('exam_center_results'));
    const rows=Object.create(null),removed=Object.create(null);
    [canonical,centre].forEach(records=>Object.keys(records).forEach(id=>{if(records[id]._syncDeleted||records[id].deleted)removed[id]=true;}));
    recordCache.exam_results={};recordCache.exam_center_results={};
    [[canonical,'exam_results'],[centre,'exam_center_results']].forEach(pair=>Object.keys(pair[0]).forEach(id=>{if(!removed[id])recordCache[pair[1]][id]=pair[0][id];}));
    ['exam_center_results','exam_results'].forEach(source=>VS_own(source,session).forEach(row=>{
     if(removed[row.id])return;
     const old=rows[row.id];
     if(!old||Number(row.timestamp||row.updatedAt||0)>=Number(old.timestamp||old.updatedAt||0))rows[row.id]=row;
    }));
    result.reportCards=Object.keys(rows).map(id=>rows[id]);
   } else result[key]=VS_own(col,session);
  });
  result.revisions=revisions;
  result.revision=VS_hash(JSON.stringify([revisions,session.person._syncRevision||'',VS_safePerson(session.person)]));
  if(b.knownRevision===result.revision)return {unchanged:true,revision:result.revision,revisions:revisions,attendancePolicy:policy,sessionExpiresAt:session.doc.expiresAt};

  return result;
 }
 if(action==='mobile_document'){
  const document=VS_get('documents',String(b.documentId||''));
  if(!document||document.deleted||document._syncDeleted||
   !((document.personId===session.personId)||(document.studentId===session.person.id&&(!document.ownerRole||document.ownerRole===session.role))))throw new Error('School document is not accessible');
  if(b.knownRevision===document.documentRevision)return {unchanged:true,documentRevision:document.documentRevision};
  const blob=VS_managedFile(document.fileId).getBlob(),bytes=blob.getBytes();
  if(bytes.length>20*1024*1024)throw new Error('File limit exceeded');
  return {base64:Utilities.base64Encode(bytes),mime:blob.getContentType(),documentRevision:document.documentRevision,contentHash:document.contentHash};
 }
 if(action==='mobile_attendance_list'){
  const month=String(b.month||'');if(!/^\d{4}-\d{2}$/.test(month))throw new Error('Select a month');
  return {attendance:VS_query('attendance_records','personId',session.personId).filter(d=>String(d.date||'').startsWith(month)),calendar:VS_query('school_calendar').filter(d=>d.id.startsWith(month)),calendarSettings:VS_get('school_settings','calendar')||{closedWeekdays:[0]}};
 }
 if(action==='mobile_mark_attendance'){
  const day=b.submittedAt?Utilities.formatDate(new Date(b.submittedAt),'Asia/Kolkata','yyyy-MM-dd'):VS_day();if(!VS_isOpen(day))throw new Error('School is closed today. Attendance is disabled for everyone');
  const loc=VS_get('school_settings','school_location')||{};const lat=Number(b.latitude),lng=Number(b.longitude);
  if(!Number.isFinite(lat)||!Number.isFinite(lng)||Math.abs(lat)>90||Math.abs(lng)>180)throw new Error('Enable your device location');
  if(loc.latitude===undefined||loc.longitude===undefined)throw new Error('School location is not configured');
  const distance=VS_distance(lat,lng,Number(loc.latitude),Number(loc.longitude));const radius=Number(loc.radiusMeters||200),accuracy=Number(b.accuracy);if(radius<25||radius>200||!Number.isFinite(radius)||!Number.isFinite(accuracy)||accuracy<0||accuracy>radius)throw new Error('Accurate school location required');if(distance>radius)throw new Error('Attendance can be marked only within the school location');
  // A scan at attendance time must be the same person as the verified session.
  const qr=VS_person(b);if(qr.role!==session.role||qr.person.mobileLinkToken!==session.person.mobileLinkToken)throw new Error('Scan your own school ID card');
  const id=VS_hash(session.role+'/'+session.personId+'/'+day);
  {
   const current=VS_get('attendance_records',id)||{};const mode=b.mode==='exit'?'exit':'entry';
   const operationField=mode==='entry'?'entryOperationId':'exitOperationId';
   if(b.operationId&&current[operationField]===b.operationId)return {message:'Attendance already recorded',record:current};
   if(mode==='entry'&&current.checkIn)throw new Error('Today’s check-in is already recorded');
   if(mode==='exit'&&!current.checkIn)throw new Error('Check in before checking out');
   if(mode==='exit'&&current.checkOut)throw new Error('Today’s check-out is already recorded');
   const doc=Object.assign({},current,{personId:session.personId,documentId:session.person.id,role:session.role,name:session.person.name||'',studentClass:session.person.class||'',rollNo:session.person.rollNo||'',date:day,source:'ANDROID_QR',updatedAt:Date.now()});delete doc.id;
   // Client capture is explicitly device-reported metadata, never a licence/session clock.
   if(Number.isSafeInteger(b.clientCapturedAt)&&b.clientCapturedAt>0&&b.clientCapturedAt<=Date.now()+120000){
    doc[mode==='entry'?'entryCapturedAt':'exitCapturedAt']=b.clientCapturedAt;
    doc.captureTimeSource='DEVICE_REPORTED';
   }
   doc[mode==='entry'?'checkIn':'checkOut']=b.submittedAt||Date.now();if(b.operationId)doc[operationField]=b.operationId;VS_set('attendance_records',id,doc);
   return {message:mode==='entry'?'Check-in recorded':'Check-out recorded',record:doc};
  }
 }
 throw new Error('Unknown school mobile action');
}

return Object.assign({projectId:school},VS_mobileAction(Object.assign({},request,{projectId:school})));
}
function VS_managedSummary(){
 const root=VS_managedRoot();let bytes=0,files=0,folders=0,partial=false;const until=Date.now()+15000;
 function visit(folder){if(++folders>1000||Date.now()>until){partial=true;return;}const it=folder.getFiles();while(it.hasNext()){if(++files>10000||Date.now()>until){partial=true;return;}bytes+=it.next().getSize();}const children=folder.getFolders();while(children.hasNext()){if(Date.now()>until){partial=true;return;}visit(children.next());}}
 visit(root);return {studentCount:Object.keys(VS_managedRecord({collection:'students_directory',operation:'read'}).records).length,driveBytes:bytes,partial:partial};
}
