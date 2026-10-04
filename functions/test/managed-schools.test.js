'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto'),vm=require('node:vm'),fs=require('node:fs');
const {createManagedSchools,protect,unprotect,clean,scriptUrl}=require('../managed-schools');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32),key='c'.repeat(64),secret='d'.repeat(64),time=1800000000000;
function fixture(fetchOverride){const docs=new Map(),users=new Map(),sent=[];
 const snap=p=>({exists:docs.has(p),data:()=>docs.get(p)});
 const db={doc:p=>({path:p,get:async()=>snap(p),set:async(v,o)=>docs.set(p,o?.merge?{...docs.get(p),...v}:v)}),collection:name=>({add:async()=>{},where:(field,op,value)=>({limit:()=>({get:async()=>({empty:![...docs.entries()].some(([path,data])=>path.startsWith(name+'/')&&data[field]===value)})})})}),batch:()=>{const queue=[];return {create:(r,v)=>queue.push(()=>{assert(!docs.has(r.path));docs.set(r.path,v)}),set:(r,v,o)=>queue.push(()=>docs.set(r.path,o?.merge?{...docs.get(r.path),...v}:v)),commit:async()=>queue.forEach(f=>f())}}};
 db.runTransaction=async fn=>fn({get:async ref=>snap(ref.path),set:(ref,value,options)=>docs.set(ref.path,options?.merge?{...docs.get(ref.path),...value}:value)});
 const auth={verifyIdToken:async t=>{if(t==='developer')return {uid:'dev',developer:true};if(users.get(t)?.disabled)throw Error();if(!['A','B','forged','A-new-pc'].includes(t))throw Error();return {uid:['forged','A-new-pc'].includes(t)?'A':t,auth_time:time/1000-10,...(t==='forged'?{admin:true,schoolId:B}:{})}},createUser:async v=>{users.set('new',v);return {uid:'new'}},deleteUser:async u=>users.delete(u),generatePasswordResetLink:async e=>'https://reset.example/'+e,updateUser:async(u,v)=>users.set(u,{...users.get(u),...v}),revokeRefreshTokens:async()=>{}};
 for(const [uid,id]of [['A',A],['B',B]]){docs.set('school_memberships/'+uid,{schoolId:id,role:'school_admin',managed:true,active:true});docs.set('school_entitlements/'+id,{active:true,blocked:false,status:'trial',startsAt:time-1000,expiresAt:time+86400000});docs.set('platform_schools/'+id,{managed:true,authUid:uid,loginEmail:uid+'@school.example'});docs.set('school_storage_private/'+id,{url:'https://script.google.com/macros/s/'+id+'/exec',secret:protect(secret,key),ready:true});}
 const fetchImpl=async(url,opt)=>{sent.push({url,opt});if(fetchOverride)return fetchOverride(url,opt,body=>handle({method:'POST',headers:{},body}));const b=JSON.parse(opt.body);assert.equal(b.signature,crypto.createHmac('sha256',secret).update(b.schoolId+'\n'+b.timestamp+'\n'+b.nonce+'\n'+b.payload).digest('hex'));return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:b.schoolId,records:{},storageReady:true}),json:async()=>({success:true,schoolId:b.schoolId,storageReady:true})}};
 const handle=createManagedSchools({auth,db,projectId:'central',encryptionKey:key,fetchImpl,now:()=>time});const call=(body,token='A')=>handle({method:'POST',headers:{authorization:'Bearer '+token},body});return {docs,users,sent,call,db,auth};}
test('only developer creates accounts; passwords never enter Firestore/dashboard',async()=>{const f=fixture(),b={action:'developer/managed/create',email:'new@school.example',schoolName:'New School'};await assert.rejects(f.call(b),e=>e.status===403);const r=await f.call(b,'developer');assert(r.passwordSetupLink);assert.equal(r.password,undefined);assert(!JSON.stringify([...f.docs.values()]).includes('password'));assert.equal(f.docs.get('school_memberships/new').schoolId,r.schoolId);assert.equal(f.docs.get('school_entitlements/'+r.schoolId).expiresAt,time+5*86400000);});
test('forged tenant/developer claims never override membership',async()=>{const f=fixture();await assert.rejects(f.call({action:'managed/session',schoolId:B}),e=>e.status===403);await assert.rejects(f.call({action:'developer/managed/monitor'},'forged'),e=>e.status===403);assert.equal((await f.call({action:'managed/session'},'forged')).schoolId,A);});
test('block, expiry, disable and membership revocation deny storage before forwarding',async()=>{for(const mode of ['block','expire','disable','membership']){const f=fixture(),e=f.docs.get('school_entitlements/'+A);if(mode==='block')e.blocked=true;if(mode==='expire')e.expiresAt=time;if(mode==='disable')e.active=false;if(mode==='membership')f.docs.get('school_memberships/A').active=false;await assert.rejects(f.call({action:'managed/records',collection:'students_directory',operation:'read'}));assert.equal(f.sent.length,0);}});
test('Drive forwarding binds server schoolId and signs payload',async()=>{const f=fixture();await f.call({action:'managed/records',collection:'students_directory',operation:'write',id:'student',data:{schoolId:B,name:'Own pupil'}});const b=JSON.parse(f.sent[0].opt.body);assert.equal(b.schoolId,A);assert.equal(JSON.parse(b.payload).data.schoolId,A);assert(!f.sent[0].url.includes(B));});
test('nested secrets/media, unsafe IDs and endpoints are rejected',async()=>{assert.throws(()=>clean({nested:{password:'secret'}}));assert.throws(()=>clean({photo:{pdfBase64:'AAAA'}}));for(const u of ['http://script.google.com/macros/s/abc/exec','https://evil.example/exec','https://script.google.com/macros/s/1234567890/exec?secret=a'])assert.throws(()=>scriptUrl(u));const f=fixture();await assert.rejects(f.call({action:'managed/records',collection:'platform_licenses',operation:'read'}));await assert.rejects(f.call({action:'managed/records',collection:'students_directory',operation:'write',id:'../foreign',data:{}}));});
test('school licence activation cannot use foreign key or revive revoked trial',async()=>{const f=fixture();const r=await f.call({action:'developer/managed/licence',schoolId:A,days:30,paid:true},'developer');await assert.rejects(f.call({action:'managed/records',collection:'students_directory',operation:'read'}));await assert.rejects(f.call({action:'managed/licence/activate',key:'VS-OTHER'}));await f.call({action:'managed/licence/activate',key:r.key});await f.call({action:'managed/records',collection:'students_directory',operation:'read'});await f.call({action:'developer/managed/revoke',schoolId:A},'developer');await assert.rejects(f.call({action:'managed/records',collection:'students_directory',operation:'read'}));});
test('AES-GCM secret encryption fails with wrong or missing server key',()=>{const e=protect(secret,key);assert.equal(unprotect(e,key),secret);assert.throws(()=>unprotect(e,'e'.repeat(64)));assert.throws(()=>protect(secret,''));assert(!JSON.stringify(e).includes(secret));});
test('storage replacement requires explicit permission',async()=>{const f=fixture();await assert.rejects(f.call({action:'developer/managed/storage',schoolId:A,scriptUrl:'https://script.google.com/macros/s/'+B+'/exec',secret,replace:false},'developer'));assert(f.docs.get('school_storage_private/'+A).url.includes(A));});
test('GS signed request rejects foreign school, tampering, stale request and replay',()=>{const props=new Map([['VS_MANAGED_SCHOOL_ID',A],['VS_MANAGED_SECRET',secret]]);const p={getProperty:k=>props.get(k),setProperty:(k,v)=>props.set(k,v),getProperties:()=>Object.fromEntries(props),deleteProperty:k=>props.delete(k)};const c=vm.createContext({Date,JSON,Number,String,Object,Error,PropertiesService:{getScriptProperties:()=>p},Utilities:{computeHmacSha256Signature:(s,k)=>[...crypto.createHmac('sha256',k).update(s).digest()]},LockService:{getScriptLock:()=>({waitLock(){},releaseLock(){}})}});vm.runInContext(fs.readFileSync('../school-backend/managed/SaarthiManagedAdapter.gs','utf8'),c);const b={schoolId:A,timestamp:Date.now(),nonce:'a'.repeat(48),payload:JSON.stringify({action:'managed_health'})};b.signature=crypto.createHmac('sha256',secret).update(A+'\n'+b.timestamp+'\n'+b.nonce+'\n'+b.payload).digest('hex');const req=x=>({postData:{contents:JSON.stringify(x)}});assert.throws(()=>c.VS_managedVerify(req({...b,schoolId:B})));assert.throws(()=>c.VS_managedVerify(req({...b,payload:'{}'})));assert.throws(()=>c.VS_managedVerify(req({...b,timestamp:1})));assert.equal(c.VS_managedVerify(req(b)).action,'managed_health');assert.throws(()=>c.VS_managedVerify(req(b)));});
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
test('mobile cannot access Drive when Windows is offline, school is blocked, trial expires, or licence is revoked',async()=>{
 for(const mode of ['offline','blocked','expiry','revoked']){const f=fixture();f.docs.get('platform_schools/'+A).lastSeenAt=mode==='offline'?time-90001:time;
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
