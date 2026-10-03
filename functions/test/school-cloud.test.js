'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createSchoolCloud,uidFor,authorizeSchool,verifyGoogle}=require('../school-cloud-core');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32),clientId='desktop.apps.googleusercontent.com';
function fixture(){
 const documents=new Map();
 const db={doc:path=>({path,get:async()=>snap(path),set:async value=>documents.set(path,value),create:async value=>{assert(!documents.has(path));documents.set(path,value);}}),
  runTransaction:async run=>run({get:async ref=>snap(ref.path),create:(ref,value)=>{assert(!documents.has(ref.path));documents.set(ref.path,value);}})};
 function snap(path){return {exists:documents.has(path),data:()=>documents.get(path)};}
 const auth={verifyIdToken:async token=>{if(!['A','B'].includes(token))throw Error('invalid token');return {uid:token==='A'?uidFor('123'):uidFor('456')};},
  createCustomToken:async(uid,claims)=>{assert.equal(claims.admin,undefined);assert.equal(claims.developer,undefined);return 'custom-'+uid;}};
 let googleSub='123',aud=clientId,scope='openid email https://www.googleapis.com/auth/drive.file',folderSchool=A;
 const fetchImpl=async url=>({ok:true,json:async()=>url.includes('tokeninfo')?{aud,scope,expires_in:3600,sub:googleSub}:
  url.includes('userinfo')?{sub:googleSub,email:'school'+googleSub+'@gmail.com',email_verified:true}:
  {id:'folder',mimeType:'application/vnd.google-apps.folder',owners:[{me:true}],capabilities:{canAddChildren:true},appProperties:{schoolId:folderSchool}}});
 const handle=createSchoolCloud({auth,db,projectId:'central-project',clientIds:[clientId],fetchImpl,verifyLegacy:async(project,token)=>{if(token!=='legacy-admin')throw Error('invalid source');return {admin:true};}});
 const req=(body,token='A')=>handle({method:'POST',headers:{authorization:'Bearer '+token},body});
 const seed=()=>{documents.set('school_memberships/'+uidFor('123'),{schoolId:A,role:'school_admin',active:true});documents.set('school_memberships/'+uidFor('456'),{schoolId:B,role:'school_admin',active:true});};
 return {documents,req,seed,auth,db,fetchImpl,setSub:v=>googleSub=v,setAud:v=>aud=v,setScope:v=>scope=v,setFolder:v=>folderSchool=v};
}
test('Onboarding is server-assigned, idempotent and never issues developer/admin claims',async()=>{
 const f=fixture(),body={action:'onboard',schoolName:'School',googleAccessToken:'google-access-token'};
 const first=await f.req(body),second=await f.req(body);assert.equal(first.schoolId,second.schoolId);assert.match(first.schoolId,/^vs-[a-f0-9]{32}$/);assert.equal(first.uid,uidFor('123'));
 assert.equal([...f.documents.keys()].filter(k=>k.startsWith('schools/')).length,1);
 await assert.rejects(f.req({...body,schoolId:B}),e=>e.status===400);
 await assert.rejects(f.req({...body,expectedSchoolId:B}),e=>e.status===409);
 f.setSub('456');const other=await f.req(body);assert.notEqual(other.schoolId,first.schoolId);
});
test('Wrong OAuth audience, missing Drive permission and expired verification fail before tenancy creation',async()=>{
 const f=fixture(),b={action:'onboard',schoolName:'School',googleAccessToken:'google-access-token'};
 f.setAud('attacker');await assert.rejects(f.req(b),e=>e.status===401);assert.equal(f.documents.size,0);
 f.setAud(clientId);f.setScope('openid email cloud-platform');await assert.rejects(f.req(b),e=>e.status===401);assert.equal(f.documents.size,0);
});
test('School A cannot request School B status or change membership with a client schoolId',async()=>{
 const f=fixture();f.seed();await assert.rejects(f.req({action:'status',schoolId:B}),e=>e.status===403);
 const status=await f.req({action:'status',schoolId:A});assert.equal(status.schoolId,A);assert.equal(status.uid,uidFor('123'));
 f.documents.set('school_memberships/'+uidFor('123'),{schoolId:A,role:'school_admin',active:false});
 await assert.rejects(f.req({action:'status'}),e=>e.status===403);
});
test('Drive link requires the same Google owner and folder school marker',async()=>{
 const f=fixture();f.seed();const b={action:'drive/link',schoolId:A,folderId:'folder',googleAccessToken:'google-access-token'};
 assert.equal((await f.req(b)).schoolId,A);
 f.setSub('456');await assert.rejects(f.req(b),e=>e.status===403);
 f.setSub('123');f.setFolder(B);await assert.rejects(f.req(b),e=>e.status===403);
});
test('Migration requires legacy admin proof, is create-only and cannot assign source to another school',async()=>{
 const f=fixture();f.seed();const b={action:'migration/import',schoolId:A,sourceProjectId:'legacy-school',sourceAdminToken:'legacy-admin',records:[{collection:'students_directory',id:'same',data:{name:'Original',password:'secret',schoolId:B}}]};
 const first=await f.req(b);assert.equal(first.copied,1);
 const path='schools/'+A+'/students_directory/same';assert.deepEqual(f.documents.get(path),{name:'Original',schoolId:A});
 const next=await f.req({...b,records:[{...b.records[0],data:{name:'Overwrite'}}]});assert.equal(next.skipped,1);assert.equal(f.documents.get(path).name,'Original');
 await assert.rejects(f.req({...b,schoolId:B},'B'),e=>e.status===403);
 await assert.rejects(f.req({...b,sourceAdminToken:'bad'}));
 await assert.rejects(f.req({...b,records:[{...b.records[0],collection:'school_memberships'}]}),e=>e.status===400);
});
test('License activation rejects a foreign school and preserves existing trial start',async()=>{
 const f=fixture();f.seed();const crypto=require('node:crypto');const hash=crypto.createHash('sha256').update('KEY').digest('hex');
 f.documents.set('platform_license_status/'+hash,{schoolId:B,revoked:false,expiresAt:Date.now()+86400000});
 await assert.rejects(f.req({action:'license/activate',key:'key'}),e=>e.status===403);
 const device='a'.repeat(64),start=Date.now()-4*86400000;f.documents.set('platform_device_trials/'+device,{createdAt:start});
 await f.req({action:'school/bind',deviceFingerprint:device});await f.req({action:'school/bind',deviceFingerprint:device});
 assert.equal(f.documents.get('platform_school_trials/'+A).createdAt,start);
 f.documents.set('platform_license_status/'+hash,{schoolId:A,revoked:false,expiresAt:Date.now()+86400000});
 assert.equal((await f.req({action:'license/activate',key:'key'})).status,'licensed');
 f.documents.get('platform_license_status/'+hash).revoked=true;assert.equal((await f.req({action:'installation/status'})).status,'blocked');
});

test('Expired Google login and unverified email never create a school',async()=>{
 const fetchExpired=async()=>({ok:true,json:async()=>({aud:clientId,scope:'https://www.googleapis.com/auth/drive.file',expires_in:0})});
 await assert.rejects(verifyGoogle('google-access-token',[clientId],fetchExpired),e=>e.status===401);
 const fetchUnverified=async url=>({ok:true,json:async()=>url.includes('tokeninfo')
  ? {aud:clientId,scope:'https://www.googleapis.com/auth/drive.file',expires_in:3600}
  : {sub:'123',email:'unverified@gmail.com',email_verified:false}});
 await assert.rejects(verifyGoogle('google-access-token',[clientId],fetchUnverified),e=>e.status===401);
});
test('Initial branding and timestamp migration preserve existing destination values',async()=>{
 const f=fixture();f.seed();await f.req({action:'profile/initialize',profile:{schoolName:'Original',principalName:'Principal'}});
 await f.req({action:'profile/initialize',profile:{schoolName:'Overwrite'}});
 assert.equal(f.documents.get('schools/'+A+'/school_config/school_profile_cache').schoolName,'Original');
 await assert.rejects(f.req({action:'profile/initialize',profile:{adminPassword:'secret'}}),e=>e.status===400);
 await f.req({action:'migration/import',sourceProjectId:'legacy-school',sourceAdminToken:'legacy-admin',records:[
  {collection:'attendance_records',id:'date',data:{timestamp:{__vsTimestamp:'2026-10-03T00:00:00.000Z'},nested:{refreshToken:'secret',name:'safe'}}}]
 });
 const data=f.documents.get('schools/'+A+'/attendance_records/date');
 assert.equal(data.timestamp.toISOString(),'2026-10-03T00:00:00.000Z');assert.deepEqual(data.nested,{name:'safe'});
});

test('Expired Firebase session is rejected and heartbeat cannot write another school',async()=>{
 const f=fixture();f.seed();await assert.rejects(f.req({action:'status'},'expired'),e=>e.status===401);
 await f.req({action:'school/heartbeat',studentCount:10,teacherCount:2});
 assert.equal(f.documents.get('platform_schools/'+A).studentCount,10);
 assert.equal(f.documents.has('platform_schools/'+B),false);
 await assert.rejects(f.req({action:'school/heartbeat',schoolId:B,studentCount:999}),e=>e.status===403);
 await assert.rejects(f.req({action:'school/heartbeat',studentCount:-1}),e=>e.status===400);
});
