'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm'),crypto=require('node:crypto'),path=require('node:path');
function backend(){
 const props=new Map([['VS_FIREBASE_PROJECT_ID','school-one'],['VS_FIREBASE_API_KEY','AIza'+'a'.repeat(30)]]),cache=new Map(),sent=[];
 const context=vm.createContext({Date,JSON,Math,Number,String,Object,Array,Error,console,
  PropertiesService:{getScriptProperties:()=>({getProperty:k=>props.get(k)||null,setProperty:(k,v)=>props.set(k,v),setProperties:d=>Object.entries(d).forEach(([k,v])=>props.set(k,v))})},
  CacheService:{getScriptCache:()=>({get:k=>cache.get(k)||null,put:(k,v)=>cache.set(k,v),remove:k=>cache.delete(k)})},
  LockService:{getScriptLock:()=>({tryLock:()=>true,releaseLock(){}})},
  Utilities:{DigestAlgorithm:{SHA_256:'SHA_256'},computeDigest:(_,s)=>[...crypto.createHash('sha256').update(s).digest()],getUuid:()=>crypto.randomUUID()},
  ScriptApp:{getOAuthToken:()=> 'school-owner-oauth'},
  UrlFetchApp:{fetch:(url,opt)=>{sent.push({url,opt});return {getResponseCode:()=>200,getContentText:()=>JSON.stringify({name:'projects/school-one/messages/sent'})};}}
 });
 for(const file of ['SaarthiMobile.gs','SaarthiPlatform.gs'])vm.runInContext(fs.readFileSync(path.join(__dirname,'../../school-backend',file),'utf8'),context);
 return {context,props,cache,sent};
}
const doc=(school,expires=Date.now()+86400000,revoked=false)=>({name:'projects/p/databases/(default)/documents/status/id',fields:{schoolId:{stringValue:school},expiresAt:{timestampValue:new Date(expires).toISOString()},revoked:{booleanValue:revoked}}});
test('Spark school licence activation rejects another school, expired and revoked keys',()=>{
 for(const invalid of [doc('school-two'),doc('school-one',Date.now()-1),doc('school-one',Date.now()+86400000,true)]){
  const {context,props}=backend();context.VS_central=()=>invalid;
  assert.throws(()=>context.VS_activatePlatformLicense('VS-'+'A'.repeat(32)),/different school/);
  assert.equal(props.has('VS_LICENSE_KEY_HASH'),false);
 }
});
test('Spark school activation stores only a hashed key and returns its server-checked lease',()=>{
 const {context,props}=backend();context.VS_central=()=>doc('school-one');
 const lease=context.VS_activatePlatformLicense('VS-'+'A'.repeat(32));
 assert.equal(lease.allowed,true);assert.equal(lease.schoolId,'school-one');
 assert.equal(props.get('VS_LICENSE_KEY_HASH'),crypto.createHash('sha256').update('VS-'+'A'.repeat(32)).digest('hex'));
 assert.equal([...props.values()].some(v=>v==='VS-'+'A'.repeat(32)),false);
});
test('an activated revoked key cannot fall back to an unexpired school trial',()=>{
 const {context,props}=backend();props.set('VS_LICENSE_KEY_HASH','a'.repeat(64));
 context.VS_central=()=>doc('school-one',Date.now()+86400000,true);context.VS_schoolTrial=()=>Date.now();
 const lease=context.VS_platformStatus(true);assert.equal(lease.status,'blocked');assert.equal(lease.allowed,false);
});
test('school trial expires five days after its immutable central creation time',()=>{
 const {context}=backend();context.VS_schoolTrial=()=>Date.now()-5*86400000-1;
 const lease=context.VS_platformStatus(true);assert.equal(lease.status,'expired');assert.equal(lease.allowed,false);
});
test('binding a school four days later retains the original Windows trial start',()=>{
 const {context}=backend(),device='a'.repeat(64),started=Date.now()-4*86400000;
 const original={fields:{createdAt:{timestampValue:new Date(started).toISOString()}}};
 let school=null,commit;const authActions=[];
 context.VS_centralAuth=(action)=>{authActions.push(action);return {localId:'trial-user',idToken:'trial-token'};};
 context.VS_central=(method,path,data)=>{
  if(path==='platform_school_trials/school-one')return school;
  if(path==='platform_device_trials/'+device)return original;
  if(method==='post'&&path===':commit'){commit=data;school=data.writes[0].update;return {};}
  throw Error('Unexpected central request');
 };
 assert.equal(context.VS_schoolTrial(device),started);
 assert.equal(commit.writes[0].update.fields.deviceTrialId.stringValue,device);
 assert.equal(context.VS_platformStatus(true).expiresAt,started+5*86400000);
 assert.deepEqual(authActions,['signUp','delete']);
});
test('a new school trial requires a previously verified Windows device',()=>{
 const {context}=backend();context.VS_central=()=>null;
 context.VS_centralAuth=()=>{throw Error('Anonymous registration must not run');};
 assert.throws(()=>context.VS_schoolTrial(),/Connect the Windows app/);
 assert.throws(()=>context.VS_schoolTrial('a'.repeat(64)),/not been verified/);
});
test('school-owned FCM contains only an invalidation signal and the correct project',()=>{
 const {context,props,sent}=backend();props.set('VS_ANDROID_APP_ID','1:123:android:aabb');props.set('VS_FCM_SENDER_ID','123');
 context.VS_get=(col)=>col==='school_notices'?{title:'Private title',description:'Private message'}:null;
 context.VS_set=()=>{};context.VS_notifySchoolNotice('notice-1');
 assert.equal(sent.length,1);assert.equal(sent[0].url,'https://fcm.googleapis.com/v1/projects/school-one/messages:send');
 const body=JSON.parse(sent[0].opt.payload);assert.equal(body.message.topic,'school_notices');
 assert.deepEqual(body.message.data,{schoolId:'school-one',type:'school_notice',noticeId:'notice-1'});
 assert.equal(sent[0].opt.payload.includes('Private'),false);assert.equal(sent[0].opt.payload.includes('saarthi-ai-df12b'),false);
});
test('school monitor exports aggregate counts without records, QR, session or notification tokens',()=>{
 const {context,props}=backend();props.set('VS_MONITOR_EMAIL','monitor@example.invalid');
 context.VS_count=col=>col==='students_directory'?3000:col==='mobile_users'?3000:50;
 context.VS_presenceCounts=()=>({students:25,teachers:1});context.VS_monitorToken=()=> 'school-scoped-token';
 let sent;context.VS_central=(method,path,data,token)=>{sent={method,path,data,token};return {};};
 context.VS_publishMonitor();const write=sent.data.writes[0];
 assert.equal(write.update.name.endsWith('/platform_school_summaries/school-one'),true);
 assert.deepEqual(Object.keys(write.update.fields).sort(),['activeLicenseHash','lastSeenAt','schoolId','studentCount','teacherCount','studentAppUsers','onlineStudents','onlineTeachers','windowsVersion','mobileVersion'].sort());
 assert.equal(write.update.fields.studentCount.integerValue,'3000');
 assert.deepEqual(JSON.parse(JSON.stringify(write.updateTransforms)),[{fieldPath:'reportedAt',setToServerValue:'REQUEST_TIME'}]);
 context.VS_central=()=>{throw Error('Too frequent');};context.VS_publishMonitor();
});
test('monitoring bundle from another school is rejected before authentication',()=>{
 const {context}=backend();context.VS_centralAuth=()=>{throw Error('Must not run');};
 assert.throws(()=>context.VS_setupPlatform({projectId:'school-two'}),/different school/);
});
test('the developer Firebase cannot be configured as a school operational backend',()=>{
 const {context}=backend();assert.throws(()=>context.VS_setupSchool('saarthi-ai-df12b','AIza'+'a'.repeat(30)),/separate Firebase/);
});
test('school Firestore queries use the canonical REST action URL',()=>{
 const {context,sent}=backend();context.VS_firestore('post',':runQuery',{structuredQuery:{}});
 assert.equal(sent[0].url,'https://firestore.googleapis.com/v1/projects/school-one/databases/(default)/documents:runQuery');
});
test('recent school activity is deduplicated and counts only the selected school roles',()=>{
 const {context}=backend();const pupil={role:'student',personId:'same-pupil'};
 context.VS_touchPresence(pupil,'1');context.VS_touchPresence(pupil,'1');
 context.VS_touchPresence({role:'teacher',personId:'same-pupil'},'1');
 const count=context.VS_presenceCounts();assert.equal(count.students,1);assert.equal(count.teachers,1);
});
