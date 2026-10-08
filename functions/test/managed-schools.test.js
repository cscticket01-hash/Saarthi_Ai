'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto'),vm=require('node:vm'),fs=require('node:fs');
const {createManagedSchools,protect,unprotect,clean,scriptUrl}=require('../managed-schools');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32),key='c'.repeat(64),secret='d'.repeat(64),time=1800000000000;
function fixture(fetchOverride,options={}){const docs=new Map(),users=new Map(),sent=[];
 const snap=p=>({exists:docs.has(p),data:()=>docs.get(p)});
 const db={doc:p=>({path:p,get:async()=>snap(p),set:async(v,o)=>docs.set(p,o?.merge?{...docs.get(p),...v}:v)}),collection:name=>({add:async()=>{},where:(field,op,value)=>({get:async()=>({docs:[...docs.entries()].filter(([path,data])=>path.startsWith(name+'/')&&data[field]===value).map(([path,data])=>({id:path.split('/').pop(),data:()=>data}))}),limit:()=>({get:async()=>({empty:![...docs.entries()].some(([path,data])=>path.startsWith(name+'/')&&data[field]===value)})})})}),batch:()=>{const queue=[];return {create:(r,v)=>queue.push(()=>{assert(!docs.has(r.path));docs.set(r.path,v)}),set:(r,v,o)=>queue.push(()=>docs.set(r.path,o?.merge?{...docs.get(r.path),...v}:v)),commit:async()=>queue.forEach(f=>f())}}};
 db.runTransaction=async fn=>fn({get:async ref=>snap(ref.path),set:(ref,value,options)=>docs.set(ref.path,options?.merge?{...docs.get(ref.path),...value}:value)});
 const auth={verifyIdToken:async t=>{if(t==='developer')return {uid:'dev',developer:true};if(users.get(t)?.disabled)throw Error();if(!['A','B','forged','A-new-pc'].includes(t))throw Error();return {uid:['forged','A-new-pc'].includes(t)?'A':t,auth_time:time/1000-10,...(t==='forged'?{admin:true,schoolId:B}:{})}},createUser:async v=>{users.set('new',v);return {uid:'new'}},deleteUser:async u=>users.delete(u),generatePasswordResetLink:async e=>'https://reset.example/'+e,updateUser:async(u,v)=>users.set(u,{...users.get(u),...v}),revokeRefreshTokens:async()=>{}};
 for(const [uid,id]of [['A',A],['B',B]]){docs.set('school_memberships/'+uid,{schoolId:id,role:'school_admin',managed:true,active:true});docs.set('school_entitlements/'+id,{active:true,blocked:false,status:'trial',startsAt:time-1000,expiresAt:time+86400000});docs.set('platform_schools/'+id,{managed:true,authUid:uid,loginEmail:uid+'@school.example'});docs.set('school_storage_private/'+id,{url:'https://script.google.com/macros/s/'+id+'/exec',secret:protect(secret,key),ready:true});}
 const fetchImpl=async(url,opt)=>{sent.push({url,opt});if(fetchOverride)return fetchOverride(url,opt,body=>handle({method:'POST',headers:{},body}));const b=JSON.parse(opt.body);assert.equal(b.signature,crypto.createHmac('sha256',secret).update(b.schoolId+'\n'+b.timestamp+'\n'+b.nonce+'\n'+b.payload).digest('hex'));return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:b.schoolId,records:{},storageReady:true,personId:'verified-pupil',role:'student',expiresAt:time+30*86400000}),json:async()=>({success:true,schoolId:b.schoolId,storageReady:true})}};
 const handle=createManagedSchools({auth,db,projectId:'central',encryptionKey:key,fetchImpl,now:()=>time,scheduleHint:callback=>setImmediate(callback),...options});const call=(body,token='A')=>handle({method:'POST',headers:{authorization:'Bearer '+token},body});return {docs,users,sent,call,db,auth,handle};}
test('only developer creates accounts; passwords never enter Firestore/dashboard',async()=>{const f=fixture(),b={action:'developer/managed/create',email:'new@school.example',schoolName:'New School'};await assert.rejects(f.call(b),e=>e.status===403);const r=await f.call(b,'developer');assert(r.passwordSetupLink);assert.equal(r.password,undefined);assert(!JSON.stringify([...f.docs.values()]).includes('password'));assert.equal(f.docs.get('school_memberships/new').schoolId,r.schoolId);assert.equal(f.docs.get('school_entitlements/'+r.schoolId).expiresAt,time+5*86400000);});
test('forged tenant/developer claims never override membership',async()=>{const f=fixture();await assert.rejects(f.call({action:'managed/session',schoolId:B}),e=>e.status===403);await assert.rejects(f.call({action:'developer/managed/monitor'},'forged'),e=>e.status===403);assert.equal((await f.call({action:'managed/session'},'forged')).schoolId,A);});
test('block, expiry, disable and membership revocation deny storage before forwarding',async()=>{for(const mode of ['block','expire','disable','membership']){const f=fixture(),e=f.docs.get('school_entitlements/'+A);if(mode==='block')e.blocked=true;if(mode==='expire')e.expiresAt=time;if(mode==='disable')e.active=false;if(mode==='membership')f.docs.get('school_memberships/A').active=false;await assert.rejects(f.call({action:'managed/records',collection:'students_directory',operation:'read'}));assert.equal(f.sent.length,0);}});
test('Drive forwarding binds server schoolId and signs payload',async()=>{const f=fixture();await f.call({action:'managed/records',collection:'students_directory',operation:'write',id:'student',data:{schoolId:B,name:'Own pupil'}});const b=JSON.parse(f.sent[0].opt.body);assert.equal(b.schoolId,A);assert.equal(JSON.parse(b.payload).data.schoolId,A);assert(!f.sent[0].url.includes(B));});
test('nested secrets/media, unsafe IDs and endpoints are rejected',async()=>{assert.throws(()=>clean({nested:{password:'secret'}}));assert.throws(()=>clean({photo:{pdfBase64:'AAAA'}}));for(const u of ['http://script.google.com/macros/s/abc/exec','https://evil.example/exec','https://script.google.com/macros/s/1234567890/exec?secret=a'])assert.throws(()=>scriptUrl(u));const f=fixture();await assert.rejects(f.call({action:'managed/records',collection:'platform_licenses',operation:'read'}));await assert.rejects(f.call({action:'managed/records',collection:'students_directory',operation:'write',id:'../foreign',data:{}}));});
test('school licence activation cannot use foreign key or revive revoked trial',async()=>{const f=fixture();const r=await f.call({action:'developer/managed/licence',schoolId:A,days:30,paid:true},'developer');await assert.rejects(f.call({action:'managed/records',collection:'students_directory',operation:'read'}));await assert.rejects(f.call({action:'managed/licence/activate',key:'VS-OTHER'}));await f.call({action:'managed/licence/activate',key:r.key});await f.call({action:'managed/records',collection:'students_directory',operation:'read'});await f.call({action:'developer/managed/revoke',schoolId:A},'developer');await assert.rejects(f.call({action:'managed/records',collection:'students_directory',operation:'read'}));});
test('AES-GCM secret encryption fails with wrong or missing server key',()=>{const e=protect(secret,key);assert.equal(unprotect(e,key),secret);assert.throws(()=>unprotect(e,'e'.repeat(64)));assert.throws(()=>protect(secret,''));assert(!JSON.stringify(e).includes(secret));});
test('storage replacement requires explicit permission',async()=>{const f=fixture();await assert.rejects(f.call({action:'developer/managed/storage',schoolId:A,scriptUrl:'https://script.google.com/macros/s/'+B+'/exec',secret,replace:false},'developer'));assert(f.docs.get('school_storage_private/'+A).url.includes(A));});
test('GS signed request rejects foreign school, tampering, stale request and replay',()=>{const props=new Map([['VS_MANAGED_SCHOOL_ID',A],['VS_MANAGED_SECRET',secret]]);const p={getProperty:k=>props.get(k),setProperty:(k,v)=>props.set(k,v),getProperties:()=>Object.fromEntries(props),deleteProperty:k=>props.delete(k)};const c=vm.createContext({Date,JSON,Number,String,Object,Error,PropertiesService:{getScriptProperties:()=>p},Utilities:{Charset:{UTF_8:'UTF-8'},computeHmacSha256Signature:(s,k)=>[...crypto.createHmac('sha256',k).update(s).digest()]},LockService:{getScriptLock:()=>({waitLock(){},releaseLock(){}})}});vm.runInContext(fs.readFileSync('../school-backend/managed/SaarthiManagedAdapter.gs','utf8'),c);const b={schoolId:A,timestamp:Date.now(),nonce:'a'.repeat(48),payload:JSON.stringify({action:'managed_health'})};b.signature=crypto.createHmac('sha256',secret).update(A+'\n'+b.timestamp+'\n'+b.nonce+'\n'+b.payload).digest('hex');const req=x=>({postData:{contents:JSON.stringify(x)}});assert.throws(()=>c.VS_managedVerify(req({...b,schoolId:B})));assert.throws(()=>c.VS_managedVerify(req({...b,payload:'{}'})));assert.throws(()=>c.VS_managedVerify(req({...b,timestamp:1})));assert.equal(c.VS_managedVerify(req(b)).action,'managed_health');assert.throws(()=>c.VS_managedVerify(req(b)));});
test('GS private file ancestry refuses another school root even with a valid file ID',()=>{const own={getId:()=>A,getDescription:()=> 'VIDYA_MANAGED_SCHOOL:'+A},foreign={getId:()=>B,getParents:()=>({hasNext:()=>false})};const files={own:{getParents:()=>({hasNext:()=>true,next:()=>own})},foreign:{getParents:()=>{let n=0;return {hasNext:()=>n++===0,next:()=>foreign}}}};const c=vm.createContext({PropertiesService:{getScriptProperties:()=>({getProperty:k=>k==='VS_MANAGED_SCHOOL_ID'?A:'root'})},DriveApp:{getFolderById:()=>own,getFileById:id=>files[id]},Error});vm.runInContext(fs.readFileSync('../school-backend/managed/SaarthiManagedAdapter.gs','utf8'),c);assert.equal(c.VS_managedFile('own'),files.own);assert.throws(()=>c.VS_managedFile('foreign'),/Foreign school/);});

test('concurrent block or licence rotation cannot be overwritten by activation',async()=>{for(const change of ['block','rotate']){const f=fixture();const issued=await f.call({action:'developer/managed/licence',schoolId:A,days:30,paid:true},'developer');const transaction=f.db.runTransaction;f.db.runTransaction=async fn=>{const e=f.docs.get('school_entitlements/'+A);if(change==='block')e.blocked=true;else e.licenseHash='replacement';return transaction(fn);};await assert.rejects(f.call({action:'managed/licence/activate',key:issued.key}),e=>e.status===403);const e=f.docs.get('school_entitlements/'+A);assert.equal(e.activated,false);if(change==='block')assert.equal(e.blocked,true);else assert.equal(e.licenseHash,'replacement');}});

test('developer sets initial password only in Firebase Auth; response and Firestore never expose it',async()=>{
 const f=fixture(),password='Initial-School-Password-2026';
 const r=await f.call({action:'developer/managed/create',email:'new@school.example',schoolName:'New School',password},'developer');
 assert.equal(f.users.get('new').password,password);assert.equal(r.password,undefined);assert.equal(r.passwordSetupLink,undefined);
 assert(!JSON.stringify([...f.docs.values()]).includes(password));
 await assert.rejects(f.call({action:'developer/managed/create',email:'bad@school.example',schoolName:'Bad',password:'short'},'developer'),e=>e.status===400);
});
test('delete archives and disables only the selected account and retains school Drive and data',async()=>{
 const f=fixture();f.docs.set('schools/'+A,{schoolName:'School A'});const storage=f.docs.get('school_storage_private/'+A);
 await f.call({action:'developer/managed/delete',schoolId:A},'developer');
 assert.equal(f.users.get('A').disabled,true);assert.equal(f.docs.get('school_memberships/A').active,false);assert.equal(f.docs.get('platform_schools/'+A).deletedAt,time);
 assert.equal(f.docs.get('school_storage_private/'+A),storage);assert(f.docs.has('schools/'+A));assert.equal(f.docs.get('school_memberships/B').active,true);
 await assert.rejects(f.call({action:'managed/session'}),e=>e.status===401||e.status===403);
});
test('mobile cannot access Drive when school is blocked, trial expires, or licence is revoked',async()=>{
 for(const mode of ['blocked','expiry','revoked']){const f=fixture();f.docs.get('platform_schools/'+A).lastSeenAt=0;
 const e=f.docs.get('school_entitlements/'+A);if(mode==='blocked')e.blocked=true;if(mode==='expiry')e.expiresAt=time;if(mode==='revoked'){e.status='licensed';e.activated=true;e.licenseHash='revoked';}
 await assert.rejects(f.call({action:'managed/mobile',schoolId:A,request:{action:'mobile_dashboard',sessionToken:'test'}}));assert.equal(f.sent.length,0);}
});
test('student forwarding signs the selected school and never renews Windows presence',async()=>{
 const f=fixture();f.docs.get('platform_schools/'+A).lastSeenAt=time-1000;
 await f.call({action:'managed/mobile',schoolId:A,request:{action:'mobile_heartbeat',schoolId:B,sessionToken:'test'}});
 const envelope=JSON.parse(f.sent[0].opt.body),payload=JSON.parse(envelope.payload);assert.equal(envelope.schoolId,A);assert.equal(payload.lease.schoolId,A);assert.equal(f.docs.get('platform_schools/'+A).lastSeenAt,time-1000);
 await assert.rejects(f.call({action:'managed/mobile',schoolId:A,request:{action:'managed_records'}}),e=>e.status===400);
});
test('disconnect sets only the authenticated school offline and cannot target another school',async()=>{
 const f=fixture();f.docs.get('platform_schools/'+A).lastSeenAt=time;f.docs.get('platform_schools/'+B).lastSeenAt=time;
 await assert.rejects(f.call({action:'managed/disconnect',schoolId:B}),e=>e.status===403);await f.call({action:'managed/disconnect'});
 assert.equal(f.docs.get('platform_schools/'+A).lastSeenAt,0);assert.equal(f.docs.get('platform_schools/'+B).lastSeenAt,time);
});

test('same Firebase account on a new PC retains activated licence, expiry and Drive binding; other school is denied',async()=>{
 const f=fixture(),issued=await f.call({action:'developer/managed/licence',schoolId:A,days:30,paid:true},'developer');
 await f.call({action:'managed/licence/activate',key:issued.key});const original=await f.call({action:'managed/session'});
 await f.call({action:'managed/disconnect'});const fresh=await f.call({action:'managed/session'},'A-new-pc');
 for(const field of ['schoolId','uid','activated','expiresAt','status','allowed','scriptUrl'])assert.equal(fresh[field],original[field]);
 assert.equal(fresh.activated,true);assert.equal(fresh.status,'licensed');
 await f.call({action:'managed/records',collection:'students_directory',operation:'read'},'A-new-pc');assert(f.sent[0].url.includes(A));
 await assert.rejects(f.call({action:'managed/licence/activate',key:issued.key},'B'),e=>e.status===403);
 await assert.rejects(f.call({action:'managed/session',schoolId:B},'A-new-pc'),e=>e.status===403);
});
test('new PC never restarts the school account trial',async()=>{
 const f=fixture(),before={...f.docs.get('school_entitlements/'+A)};
 const fresh=await f.call({action:'managed/session'},'A-new-pc');assert.equal(fresh.expiresAt,before.expiresAt);
 assert.deepEqual(f.docs.get('school_entitlements/'+A),before);
 f.docs.get('school_entitlements/'+A).expiresAt=time;assert.equal((await f.call({action:'managed/session'},'A-new-pc')).allowed,false);
});

function existingGoogle(f){
 const account={uid:'google-user',email:'existing@school.example',disabled:false,providerData:[{providerId:'google.com'}],customClaims:{}};
 f.auth.createUser=async()=>{const e=new Error('duplicate');e.code='auth/email-already-exists';throw e;};f.auth.getUserByEmail=async()=>account;return account;
}
const linkBody={action:'developer/managed/create',email:'existing@school.example',schoolName:'Existing School',password:'Secure-School-Password-2026',linkExistingGoogle:true};
test('developer links an unassigned Google login using the same UID; credentials never enter school records',async()=>{
 const f=fixture(),account=existingGoogle(f);f.docs.set('users/'+account.uid,{name:'Retained profile'});
 const r=await f.call(linkBody,'developer');assert.equal(f.docs.get('school_memberships/'+account.uid).schoolId,r.schoolId);
 assert.equal(f.docs.get('platform_schools/'+r.schoolId).authUid,account.uid);assert.equal(f.docs.get('users/'+account.uid).name,'Retained profile');
 assert.equal(f.users.get(account.uid).password,linkBody.password);assert(!JSON.stringify([...f.docs.values()]).includes(linkBody.password));
});
test('existing Google account conversion requires explicit developer selection',async()=>{
 const f=fixture();existingGoogle(f);await assert.rejects(f.call({...linkBody,linkExistingGoogle:false},'developer'),e=>e.code==='auth/email-already-exists');assert(!f.docs.has('school_memberships/google-user'));
 await assert.rejects(f.call(linkBody,'A'),e=>e.status===403);
});
test('linking never steals another school, disabled account, developer, student or legacy school owner',async()=>{
 for(const mode of ['membership','disabled','developer','student','owner','password-only']){
 const f=fixture(),a=existingGoogle(f);if(mode==='membership')f.docs.set('school_memberships/'+a.uid,{schoolId:B});
 if(mode==='disabled')a.disabled=true;if(mode==='developer')a.customClaims={developer:true};
 if(mode==='student')f.docs.set('users/'+a.uid,{role:'student'});if(mode==='owner')f.docs.set('schools/legacy',{ownerUid:a.uid});
 if(mode==='password-only')a.providerData=[{providerId:'password'}];
 await assert.rejects(f.call(linkBody,'developer'),e=>e.status===409);assert(!f.users.has(a.uid));
 }
});
test('a metadata write failure never deletes the existing Google account',async()=>{
 const f=fixture();existingGoogle(f);let deleted=false;f.auth.deleteUser=async()=>{deleted=true;};f.db.batch=()=>({create(){},commit:async()=>{throw Error('write failed');}});
 await assert.rejects(f.call(linkBody,'developer'));assert.equal(deleted,false);
});

test('URL-only storage pairing authorizes a single-use server ticket and keeps secrets off Windows',async()=>{
 let ticket;
 const f=fixture(async(url,opt,authorize)=>{
  const b=JSON.parse(opt.body);
  if(b.action==='managed_connect'){
   ticket=b.ticket;assert.equal(opt.headers.Authorization,undefined);assert(!opt.body.includes('Bearer'));
   assert.equal((await authorize({action:'managed/storage/authorize',schoolId:A,ticket})).schoolId,A);
   await assert.rejects(authorize({action:'managed/storage/authorize',schoolId:A,ticket}),e=>e.status===403);
   return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,storageReady:true,connectionSecret:secret})};
  }
  assert.equal(b.signature,crypto.createHmac('sha256',secret).update(A+'\n'+b.timestamp+'\n'+b.nonce+'\n'+b.payload).digest('hex'));
  return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,storageReady:true})};
 });
 f.docs.delete('school_storage_private/'+A);
 const result=await f.call({action:'managed/storage/connect',scriptUrl:'https://script.google.com/macros/s/SchoolADeployment/exec'});
 assert.equal(result.storageReady,true);assert(!JSON.stringify(result).includes(secret));assert(!JSON.stringify(result).includes(ticket));
 assert.equal(unprotect(f.docs.get('school_storage_private/'+A).secret,key),secret);
 assert(f.docs.get('school_storage_private/'+B).url.includes(B));
 await assert.rejects(f.call({action:'managed/storage/authorize',schoolId:A,ticket}),e=>e.status===403);
});
test('URL-only pairing rejects foreign script identity, unused tickets, blocked access and replacement',async()=>{
 for(const mode of ['foreign','unused','blocked','replacement','foreign-request']){
  const f=fixture(async(url,opt,authorize)=>{
   const b=JSON.parse(opt.body);
   if(mode!=='unused')await authorize({action:'managed/storage/authorize',schoolId:A,ticket:b.ticket});
   if(mode==='blocked')f.docs.get('school_entitlements/'+A).blocked=true;
   return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:mode==='foreign'?B:A,storageReady:true,connectionSecret:secret})};
  });
  if(!['replacement','foreign-request'].includes(mode))f.docs.delete('school_storage_private/'+A);
  await assert.rejects(f.call({action:'managed/storage/connect',schoolId:mode==='foreign-request'?B:A,scriptUrl:'https://script.google.com/macros/s/AnotherDeployment/exec'}));
  if(mode==='replacement')assert(f.docs.get('school_storage_private/'+A).url.includes(A));
  else if(mode!=='foreign-request')assert(!f.docs.has('school_storage_private/'+A));
  assert(f.docs.get('school_storage_private/'+B).url.includes(B));
 }
});
test('GS connection exposes no secret before fixed-school and central ticket verification',()=>{
 let called=0;const props=new Map([['VS_MANAGED_SCHOOL_ID',A],['VS_MANAGED_ROOT_ID','root'],['VS_MANAGED_SECRET',secret]]);
 const c=vm.createContext({JSON,String,Error,PropertiesService:{getScriptProperties:()=>({getProperty:k=>props.get(k)})},DriveApp:{getFolderById:()=>({getDescription:()=> 'VIDYA_MANAGED_SCHOOL:'+A})},UrlFetchApp:{fetch:(url,opt)=>{called++;assert.equal(url,'https://saarthi-oauth-staging.onrender.com/school-cloud');assert.equal(JSON.parse(opt.payload).schoolId,A);return {getResponseCode:()=>403,getContentText:()=>JSON.stringify({success:false})};}}});
 vm.runInContext(fs.readFileSync('../school-backend/managed/SaarthiManagedAdapter.gs','utf8'),c);
 assert.throws(()=>c.VS_managedConnect({schoolId:B,ticket:'a'.repeat(64)}));assert.equal(called,0);
 assert.throws(()=>c.VS_managedConnect({schoolId:A,ticket:'a'.repeat(64)}),/ticket rejected/);assert.equal(called,1);
});
test('no-argument GS preparation preserves existing root and secret and refuses rebinding',()=>{
 const props=new Map([['VS_MANAGED_SCHOOL_ID',A],['VS_MANAGED_ROOT_ID','existing-root'],['VS_MANAGED_SECRET',secret]]);
 let created=0;
 const c=vm.createContext({JSON,String,Error,PropertiesService:{getScriptProperties:()=>({getProperty:k=>props.get(k),setProperty:(k,v)=>props.set(k,v)})},DriveApp:{createFolder:()=>{created++;throw Error('Unexpected new root');},getFolderById:id=>{assert.equal(id,'existing-root');return {getDescription:()=> 'VIDYA_MANAGED_SCHOOL:'+A};}}});
 const source=fs.readFileSync('../school-backend/managed/SaarthiManagedAdapter.gs','utf8');
 vm.runInContext(source,c);
 const out=c.VS_prepareSchoolStorage();assert.equal(out.schoolId,A);assert.equal(out.storageReady,true);assert.equal(out.connectionSecret,undefined);assert.equal(created,0);assert.equal(props.get('VS_MANAGED_SECRET'),secret);
 const foreign=vm.createContext({JSON,String,Error,PropertiesService:c.PropertiesService,DriveApp:c.DriveApp});vm.runInContext(source.replace("const VS_SETUP_SCHOOL_ID = '';",`const VS_SETUP_SCHOOL_ID = '${B}';`),foreign);
 assert.throws(()=>foreign.VS_prepareSchoolStorage(),/rebinding/);assert.equal(created,0);
});
test('fresh GS preparation requires explicit school ID and new-storage consent',()=>{
 const c=vm.createContext({JSON,String,Error,PropertiesService:{getScriptProperties:()=>({getProperty:()=>null})}});
 vm.runInContext(fs.readFileSync('../school-backend/managed/SaarthiManagedAdapter.gs','utf8'),c);
 assert.throws(()=>c.VS_prepareSchoolStorage(),/Set VS_SETUP_SCHOOL_ID/);
});
test('new GS storage creates one marked root only after explicit operator consent',()=>{
 const source=fs.readFileSync('../school-backend/managed/SaarthiManagedAdapter.gs','utf8').replace("const VS_SETUP_SCHOOL_ID = '';",`const VS_SETUP_SCHOOL_ID = '${A}';`);
 const props=new Map();let created=0,description='';const root={getId:()=> 'new-root',setDescription:d=>description=d,getDescription:()=>description};
 const environment=()=>({JSON,String,Error,Utilities:{getUuid:()=> '01234567-89ab-cdef-0123-456789abcdef'},PropertiesService:{getScriptProperties:()=>({getProperty:k=>props.get(k),setProperty:(k,v)=>props.set(k,v)})},DriveApp:{createFolder:()=>{created++;return root;},getFolderById:()=>root}});
 const noConsent=vm.createContext(environment());vm.runInContext(source,noConsent);assert.throws(()=>noConsent.VS_prepareSchoolStorage(),/NEW storage connection/);assert.equal(created,0);
 const consent=vm.createContext(environment());vm.runInContext(source.replace('const VS_SETUP_CREATE_NEW_STORAGE = false;','const VS_SETUP_CREATE_NEW_STORAGE = true;'),consent);const result=consent.VS_prepareSchoolStorage();assert.equal(result.schoolId,A);assert.equal(result.connectionSecret,undefined);assert.equal(description,'VIDYA_MANAGED_SCHOOL:'+A);assert.equal(created,1);
 consent.VS_prepareSchoolStorage();assert.equal(created,1);assert.equal(props.get('VS_MANAGED_ROOT_ID'),'new-root');
});

test('new school is explicitly unregistered; reinstall restores lightweight enrollment without Drive',async()=>{
 const f=fixture();f.docs.delete('school_storage_private/'+A);f.docs.get('platform_schools/'+A).registrationState='new';
 const entitlement={...f.docs.get('school_entitlements/'+A)};
 assert.equal((await f.call({action:'managed/profile',operation:'read'})).registrationState,'new');
 const saved=await f.call({action:'managed/profile',operation:'initialize',schoolName:'School A',principalName:'Principal A',password:'must-not-be-stored',logoUrl:'data:image/png;base64,abc'});
 assert.equal(saved.storageReady,false);assert.equal(saved.registrationState,'complete');
 const fresh=await f.call({action:'managed/profile',operation:'read'},'A-new-pc');assert.deepEqual(fresh.profile,saved.profile);
 assert.deepEqual(f.docs.get('school_entitlements/'+A),entitlement);assert.equal(f.sent.length,0);
 const data=f.docs.get('school_registration_profiles/'+A);assert.deepEqual(Object.keys(data).sort(),['completedAt','principalName','schoolId','schoolName']);
});
test('registration initialization is create-only and cannot reset an existing school',async()=>{
 const f=fixture();await f.call({action:'managed/profile',operation:'initialize',schoolName:'Original',principalName:'Original principal'});
 const before={...f.docs.get('school_registration_profiles/'+A)};
 const r=await f.call({action:'managed/profile',operation:'initialize',schoolName:'Replacement',principalName:'Replacement principal'},'A-new-pc');
 assert.equal(r.profile.schoolName,'Original');assert.deepEqual(f.docs.get('school_registration_profiles/'+A),before);
});
test('legacy unknown enrollment is never silently classified as a new school',async()=>{
 const f=fixture();for(const storage of [true,false]){
 if(!storage)f.docs.delete('school_storage_private/'+A);
 const result=await f.call({action:'managed/profile',operation:'read'},'A-new-pc');assert.equal(result.registrationState,'unknown');assert.equal(result.profile,null);
 }
});
test('registration read/write rejects foreign mapping, blocked school, expired trial, unactivated or revoked licence and invalid login',async()=>{
 for(const mode of ['foreign','blocked','expired','unactivated','revoked','wrong-login'])for(const operation of ['read','initialize']){
 const f=fixture();let token='A';const body={action:'managed/profile',operation,schoolName:'School A',principalName:'Principal A'};
 const e=f.docs.get('school_entitlements/'+A);
 if(mode==='foreign')body.schoolId=B;if(mode==='blocked')e.blocked=true;if(mode==='expired')e.expiresAt=time;
 if(['unactivated','revoked'].includes(mode)){e.status='licensed';e.activated=mode==='revoked';e.licenseHash='missing';}
 if(mode==='wrong-login')token='bad-password-token';
 await assert.rejects(f.call(body,token));assert(!f.docs.has('school_registration_profiles/'+A));assert(!f.docs.has('school_registration_profiles/'+B));assert.equal(f.sent.length,0);
 }
});
test('active paid licence restores registration without reactivation and tenant B sees only B',async()=>{
 const f=fixture();const issued=await f.call({action:'developer/managed/licence',schoolId:A,days:30,paid:true},'developer');await f.call({action:'managed/licence/activate',key:issued.key});
 await f.call({action:'managed/profile',operation:'initialize',schoolName:'School A',principalName:'Principal A'});
 const before={...f.docs.get('school_entitlements/'+A)};
 assert.equal((await f.call({action:'managed/profile',operation:'read'},'A-new-pc')).profile.schoolId,A);
 assert.equal((await f.call({action:'managed/profile',operation:'read'},'B')).profile,null);
 assert.deepEqual(f.docs.get('school_entitlements/'+A),before);
});
test('a concurrent block cannot be overwritten by registration initialization',async()=>{
 const f=fixture(),transaction=f.db.runTransaction;f.db.runTransaction=async fn=>{f.docs.get('school_entitlements/'+A).blocked=true;return transaction(fn);};
 await assert.rejects(f.call({action:'managed/profile',operation:'initialize',schoolName:'School A',principalName:'Principal A'}),e=>e.status===403);
 assert(!f.docs.has('school_registration_profiles/'+A));
});
test('legacy developer account recovery uses matching authoritative ownership and preserves all data',async()=>{
 for(const storage of [true,false]){
 const f=fixture();if(!storage)f.docs.delete('school_storage_private/'+A);
 Object.assign(f.docs.get('platform_schools/'+A),{schoolId:A,name:'Original School'});
 f.docs.set('schools/'+A,{schoolId:A,ownerUid:'A',schoolName:'Original School'});
 const before=JSON.stringify([...f.docs]);
 const result=await f.call({action:'managed/profile',operation:'read'},'A-new-pc');
 assert.equal(result.registrationState,'recovery');assert.deepEqual(result.profile,{schoolId:A,schoolName:'Original School',principalName:''});
 assert.equal(JSON.stringify([...f.docs]),before);assert.equal(f.sent.length,0);
 const foreign=await f.call({action:'managed/profile',operation:'read'},'B');assert.equal(foreign.profile,null);
 }
});
test('recovery refuses inconsistent account ownership and retains explicit new-school setup',async()=>{
 for(const mode of ['owner','schoolId','name','new','blocked','expired','wrong']){
 const f=fixture();const account=f.docs.get('platform_schools/'+A);
 Object.assign(account,{schoolId:A,name:'Original School'});f.docs.set('schools/'+A,{schoolId:A,ownerUid:'A',schoolName:'Original School'});
 if(mode==='owner')f.docs.get('schools/'+A).ownerUid='B';
 if(mode==='schoolId')account.schoolId=B;if(mode==='name')f.docs.get('schools/'+A).schoolName='Other';
 if(mode==='new')account.registrationState='new';
 if(mode==='blocked')f.docs.get('school_entitlements/'+A).blocked=true;
 if(mode==='expired')f.docs.get('school_entitlements/'+A).expiresAt=time;
 if(['blocked','expired','wrong'].includes(mode))await assert.rejects(f.call({action:'managed/profile',operation:'read'},mode==='wrong'?'bad':'A'));
 else{const result=await f.call({action:'managed/profile',operation:'read'});assert.equal(result.registrationState,mode==='new'?'new':'unknown');assert.equal(result.profile,null);}
 assert(!f.docs.has('school_registration_profiles/'+A));
 }
});

test('managed QR returns safe actionable errors and hides arbitrary or foreign-script failures',async()=>{
 const safe='This QR is invalid or has not synced to this school. Ask the school to sync or regenerate the ID card.';
 for(const [schoolId,message,status] of [[A,safe,403],[A,'Secret internal folder ID and password',502],[B,safe,502]]){
  const f=fixture(async()=>({ok:true,status:200,text:async()=>JSON.stringify({success:false,schoolId,message})}));
  f.docs.get('platform_schools/'+A).lastSeenAt=time;
  await assert.rejects(f.call({action:'managed/mobile',schoolId:A,request:{action:'mobile_login',role:'teacher',personId:'own',linkToken:'x'.repeat(48)}}),e=>e.status===status && (status===403?e.message===safe:!e.message.includes('Secret')));
 }
});
test('school storage change requires exact old connection and preserves both schools previous data',async()=>{
 const f=fixture(async(url,opt,authorize)=>{
  const b=JSON.parse(opt.body);
  if(b.action==='managed_connect')await authorize({action:'managed/storage/authorize',schoolId:A,ticket:b.ticket});
  return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,storageReady:true,connectionSecret:secret,googleEmail:'school-a@gmail.com'})};
 });
 const old=f.docs.get('school_storage_private/'+A),foreign=f.docs.get('school_storage_private/'+B);
 const request={action:'managed/storage/connect',scriptUrl:'https://script.google.com/macros/s/NewOwnDeployment/exec',replace:true};
 await assert.rejects(f.call({...request,expectedScriptUrl:'https://script.google.com/macros/s/WrongDeployment/exec'}),e=>e.status===409);
 const result=await f.call({...request,expectedScriptUrl:old.url});
 assert.equal(result.googleEmail,'school-a@gmail.com');
 assert.equal(f.docs.get('school_storage_private/'+A).previousConnections[0].url,old.url);
 assert.equal(f.docs.get('school_storage_private/'+A).previousConnections[0].secret,old.secret);
 assert.deepEqual(f.docs.get('school_storage_private/'+B),foreign);
});

test('bounded presence renewals avoid account/Firestore reads and cannot access school data',async()=>{
 const f=fixture();const session=await f.call({action:'managed/session'});assert.equal(typeof session.presenceToken,'string');
 let reads=0,authReads=0;const doc=f.db.doc;f.db.doc=p=>{const r=doc(p);const get=r.get;r.get=async()=>{reads++;return get();};return r;};
 const verify=f.auth.verifyIdToken;f.auth.verifyIdToken=async t=>{authReads++;return verify(t);};
 const result=await f.call({action:'managed/presence',schoolId:A,presenceToken:session.presenceToken},'invalid-bearer');
 assert.equal(result.schoolId,A);assert.equal(reads,0);assert.equal(authReads,0);assert.equal(f.docs.get('platform_schools/'+A).lastSeenAt,time);
 await assert.rejects(f.call({action:'managed/presence',schoolId:B,presenceToken:session.presenceToken}),e=>e.status===403);
 await assert.rejects(f.call({action:'managed/presence',presenceToken:session.presenceToken+'x'}),e=>e.status===401);
 await assert.rejects(f.call({action:'managed/records',collection:'students_directory',operation:'read',presenceToken:session.presenceToken},'invalid-bearer'),e=>e.status===401);
});
test('broker forwards version CAS, operation identity and known collection revision only for authenticated school',async()=>{
 const f=fixture();await f.call({action:'managed/records',collection:'school_notices',operation:'write',id:'n',syncProtocol:2,
  operationId:'operation-0000000000000001',expectedRecordRevision:'server-1',data:{title:'Own'}});
 const payload=JSON.parse(JSON.parse(f.sent[0].opt.body).payload);assert.equal(payload.operationId,'operation-0000000000000001');assert.equal(payload.expectedRecordRevision,'server-1');assert.equal(payload.data.schoolId,A);
 await f.call({action:'managed/records',collection:'school_notices',operation:'read',syncProtocol:2,knownRevision:'collection-1'});
 assert.equal(JSON.parse(JSON.parse(f.sent[1].opt.body).payload).knownRevision,'collection-1');
});


test('coalesced mobile school/storage policy uses three Firebase reads for 100 refreshes; block invalidates it',async()=>{
 const f=fixture();f.docs.get('platform_schools/'+A).lastSeenAt=time;
 let reads=0;const doc=f.db.doc;f.db.doc=p=>{const r=doc(p),get=r.get;r.get=async()=>{reads++;return get();};return r;};
 for(let i=0;i<100;i++)await f.call({action:'managed/mobile',schoolId:A,request:{action:'mobile_dashboard',sessionToken:'same'}});
 assert.equal(reads,3);assert.equal(f.sent.length,100);
 await f.call({action:'developer/managed/block',schoolId:A,blocked:true},'developer');
 await assert.rejects(f.call({action:'managed/mobile',schoolId:A,request:{action:'mobile_dashboard',sessionToken:'same'}}),e=>e.status===403);
});
test('verified attendance permit -> encrypted durable queue -> batched school Drive acknowledgement; tampering/GPS/foreign school denied',async()=>{
 const rows=new Map(),store={create:async(id,row)=>{if(rows.has(id))return false;rows.set(id,{...row});return true;},pending:async n=>[...rows.values()].filter(r=>r.state==='pending').slice(0,n),claim:async(id,claim)=>{rows.get(id).claim=claim;return true;},finish:async(id,claim,v)=>{assert.equal(rows.get(id).claim,claim);Object.assign(rows.get(id),v);}};
 const day=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Kolkata',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(time));
 const f=fixture(async(url,opt)=>{
  const envelope=JSON.parse(opt.body),payload=JSON.parse(envelope.payload);
  const result=payload.action==='managed_attendance_batch'?{acknowledgements:payload.operations.map(i=>({operationId:i.operationId,success:true}))}:
   {projectId:A,attendancePolicy:{role:'student',personId:'stable-pupil',documentId:'pupil',qrHash:crypto.createHash('sha256').update('student/pupil/'+'x'.repeat(48)).digest('hex'),day,open:true,latitude:24,longitude:92,radiusMeters:200}};
  return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,...result})};
 },{attendanceStore:store});
 f.docs.get('platform_schools/'+A).lastSeenAt=0; // PC off: backend worker must still deliver.
 const session='s'.repeat(64),verified=await f.call({action:'managed/mobile',schoolId:A,request:{action:'mobile_dashboard',sessionToken:session}});
 const request={action:'mobile_mark_attendance',sessionToken:session,attendancePermit:verified.attendancePermit,role:'student',personId:'pupil',linkToken:'x'.repeat(48),latitude:24,longitude:92,accuracy:3,mode:'entry'};
 const first=await f.call({action:'managed/mobile',schoolId:A,request});assert.equal(first.accepted,true);assert.equal(f.sent.length,1);assert.equal(rows.size,1);
 assert(!JSON.stringify([...rows.values()]).includes(session));assert(!JSON.stringify([...rows.values()]).includes('x'.repeat(48)));
 const duplicate=await f.call({action:'managed/mobile',schoolId:A,request});assert.equal(duplicate.duplicate,true);assert.equal(rows.size,1);
 await assert.rejects(f.call({action:'managed/mobile',schoolId:A,request:{...request,latitude:25}}),e=>e.status===400);
 await assert.rejects(f.call({action:'managed/mobile',schoolId:A,request:{...request,attendancePermit:request.attendancePermit+'x'}}),e=>e.status===401);
 f.docs.get('platform_schools/'+B).lastSeenAt=time;
 await assert.rejects(f.call({action:'managed/mobile',schoolId:B,request}),e=>e.status===409);
 await f.handle.drainAttendance();assert.equal([...rows.values()][0].state,'completed');assert.equal(f.sent.length,2);
});

test('broker forwards only allowlisted Script diagnostic codes and never raw failure details',async()=>{
 for(const [code,expected] of [['SCRIPT_PERMISSION_DENIED','SCRIPT_PERMISSION_DENIED'],['SCRIPT_TYPE_ERROR','SCRIPT_TYPE_ERROR'],['secret-root-token','SCRIPT_OPERATION_FAILED']]) {
  const f=fixture(async(_,opt)=>({ok:true,status:200,text:async()=>JSON.stringify({schoolId:JSON.parse(opt.body).schoolId,success:false,message:'private exception secret-root-token',code})}));
  await assert.rejects(f.call({action:'managed/records',collection:'students_directory',operation:'read'}),error=>error.status===502&&error.code===expected&&!error.message.includes('secret-root-token'));
 }
});


test('cloud mobile access remains available with PC offline while signed tenant/session authorization stays enforced',async()=>{
 for(const seen of [undefined,0,time-86400000]) {
  const f=fixture();f.docs.get('platform_schools/'+A).lastSeenAt=seen;
  for(const action of ['mobile_login','mobile_dashboard','mobile_notice','mobile_document','mobile_asset','mobile_refresh']) {
   await f.call({action:'managed/mobile',schoolId:A,request:{action,sessionToken:'existing',documentId:'own'}});
   const envelope=JSON.parse(f.sent.at(-1).opt.body),payload=JSON.parse(envelope.payload);
   assert.equal(envelope.schoolId,A);assert.equal(payload.lease.schoolId,A);
   assert.equal(f.docs.get('platform_schools/'+A).lastSeenAt,seen);
  }
 }
 const denied=fixture(async(_,opt)=>({ok:true,status:200,text:async()=>JSON.stringify({success:false,schoolId:JSON.parse(opt.body).schoolId,message:'School login required'})}));
 await assert.rejects(denied.call({action:'managed/mobile',schoolId:A,request:{action:'mobile_document'}}),e=>e.status===403);
 const foreign=fixture(async()=>({ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:B})}));
 await assert.rejects(foreign.call({action:'managed/mobile',schoolId:A,request:{action:'mobile_document',sessionToken:'existing'}}),e=>e.status===502&&e.code==='SCRIPT_IDENTITY_MISMATCH');
});

test('managed push device requires verified school session and same device proof across school changes',async()=>{
 const f=fixture(undefined,{messaging:{sendEachForMulticast:async()=>{}}});
 const request={action:'mobile_refresh',sessionToken:'verified-by-script',deviceId:'d'.repeat(64),fcmToken:'f'.repeat(40)};
 await f.call({action:'managed/mobile',schoolId:A,request});
 const id=crypto.createHash('sha256').update(request.fcmToken).digest('hex'),stored=f.docs.get('managed_notification_devices/'+id);
 assert.equal(stored.schoolId,A);assert(!JSON.stringify(stored).includes(request.fcmToken));
 await assert.rejects(f.call({action:'managed/mobile',schoolId:B,request:{...request,deviceId:'other'.repeat(12)}}),e=>e.status===403);
 assert.equal(f.docs.get('managed_notification_devices/'+id).schoolId,A);
 await f.call({action:'managed/mobile',schoolId:B,request});
 assert.equal(f.docs.get('managed_notification_devices/'+id).schoolId,B);
 await f.call({action:'developer/managed/block',schoolId:A,blocked:true},'developer');
 await assert.rejects(f.call({action:'managed/mobile',schoolId:A,request}),e=>e.status===403);
 assert.equal(f.docs.get('managed_notification_devices/'+id).schoolId,B);
});
test('verified protocol ACK precedes tenant-only content-free push hint; reads send none and failed storage sends no hint',async()=>{
 const pushes=[];const f=fixture(async(url,opt)=>({ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:JSON.parse(opt.body).schoolId,personId:'verified-pupil',role:'student',expiresAt:time+30*86400000,syncProtocol:2,recordRevision:'verified-record-ACK'})}),{messaging:{sendEachForMulticast:async message=>pushes.push(message)}});
 const device=(schoolId,token)=>f.call({action:'managed/mobile',schoolId,request:{action:'mobile_refresh',sessionToken:'school-verified',deviceId:token.repeat(64),fcmToken:token.repeat(40)}});
 await device(A,'a');await device(B,'b');
 await f.call({action:'managed/records',collection:'school_notices',operation:'write',id:'notice',data:{title:'Private notice'},syncProtocol:2,operationId:'operation-123456789',expectedRecordRevision:''});
 await new Promise(resolve=>setImmediate(resolve));
 assert.equal(pushes.length,1);assert.deepEqual(pushes[0].tokens,['a'.repeat(40)]);
 assert.equal(pushes[0].data.schoolId,A);assert(!JSON.stringify(pushes[0]).includes('Private notice'));
 await f.call({action:'managed/records',collection:'school_notices',operation:'read',syncProtocol:2});
 await new Promise(resolve=>setImmediate(resolve));assert.equal(pushes.length,1);
 const bad=fixture(async()=>({ok:true,status:200,text:async()=>JSON.stringify({success:false,schoolId:A})}),{messaging:{sendEachForMulticast:async()=>assert.fail('No ACK, no push')}});
 await assert.rejects(bad.call({action:'managed/records',collection:'school_notices',operation:'write',id:'notice',data:{},syncProtocol:2,operationId:'operation-123456789',expectedRecordRevision:''}));
});

test('optional push outage never cancels a verified storage ACK',async()=>{
 const diagnostics=[];const f=fixture(async(url,opt)=>({ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:JSON.parse(opt.body).schoolId,personId:'verified-pupil',role:'student',expiresAt:time+30*86400000,syncProtocol:2,recordRevision:'persisted-revision'})}),{pushDiagnostics:entry=>diagnostics.push(entry),messaging:{sendEachForMulticast:async()=>{throw Error('FCM unavailable');}}});
 await f.call({action:'managed/mobile',schoolId:A,request:{action:'mobile_refresh',sessionToken:'school-verified',deviceId:'d'.repeat(64),fcmToken:'f'.repeat(40)}});
 const ack=await f.call({action:'managed/records',collection:'documents',operation:'write',id:'doc',data:{documentRevision:'rev'},expectedRevision:''});
 assert.equal(ack.recordRevision,'persisted-revision');
 await new Promise(resolve=>setImmediate(resolve));
 assert.deepEqual(diagnostics,[{event:'managed_push_hint_failure',code:'FCM_UNAVAILABLE'}]);
});

test('document refresh hint targets only the Script-verified person, not another student in the same school',async()=>{
 const pushes=[];
 const f=fixture(async(url,opt)=>{const envelope=JSON.parse(opt.body),body=JSON.parse(envelope.payload);return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:envelope.schoolId,personId:body.request?.sessionToken==='person-2'?'verified-2':'verified-1',role:'student',expiresAt:time+30*86400000,syncProtocol:2,recordRevision:'ACK'})};},{messaging:{sendEachForMulticast:async message=>pushes.push(message)}});
 for(const n of [1,2])await f.call({action:'managed/mobile',schoolId:A,request:{action:'mobile_refresh',sessionToken:'person-'+n,personId:'untrusted-victim',deviceId:String(n).repeat(64),fcmToken:String(n).repeat(40)}});
 await f.call({action:'managed/records',collection:'documents',operation:'write',id:'doc',data:{personId:'verified-1',ownerRole:'student',documentRevision:'revision'},expectedRevision:''});
 await new Promise(resolve=>setImmediate(resolve));
 assert.equal(pushes.length,1);assert.deepEqual(pushes[0].tokens,['1'.repeat(40)]);
 assert(!JSON.stringify(pushes[0].data).includes('verified-1'));
});

 test('verified fee/exam/attendance changes wake school clients without payloads; reads and failed ACK send no hint',async()=>{
  const pushes=[];const f=fixture(async(url,opt)=>({ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:JSON.parse(opt.body).schoolId,personId:'verified-pupil',role:'student',expiresAt:time+86400000,syncProtocol:2,recordRevision:'ACK'})}),{messaging:{sendEachForMulticast:async m=>pushes.push(m)}});
  await f.call({action:'managed/mobile',schoolId:A,request:{action:'mobile_refresh',sessionToken:'verified',deviceId:'d'.repeat(64),fcmToken:'f'.repeat(40)}});
  for(const collection of ['fee_settings','fee_ledger','fee_payments','exams','exam_center_results','attendance_records','teacher_salary']){
   await f.call({action:'managed/records',collection,operation:'write',id:'record',data:{name:'Private school data'},syncProtocol:2,operationId:'operation-123456789',expectedRecordRevision:''});
  }
  await new Promise(resolve=>setImmediate(resolve));assert.equal(pushes.length,1); // One school-scoped burst, not one FCM send per record.
  assert(pushes.every(p=>p.data.schoolId===A&&!JSON.stringify(p.data).includes('Private')));
 });
