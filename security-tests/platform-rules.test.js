'use strict';
const {before,after,beforeEach,test}=require('node:test');
const {readFileSync}=require('node:fs');
const {initializeTestEnvironment,assertFails,assertSucceeds}=require('@firebase/rules-unit-testing');
const {doc,collection,getDoc,getDocs,setDoc,updateDoc,deleteDoc,serverTimestamp,Timestamp,writeBatch}=require('firebase/firestore');
let env;
before(async()=>{env=await initializeTestEnvironment({projectId:'demo-saarthi-platform',firestore:{rules:readFileSync('../firestore.platform.rules','utf8')}});});
after(async()=>{await env?.cleanup();});
beforeEach(async()=>{await env.clearFirestore();});
const dev=()=>env.authenticatedContext('developer',{developer:true}).firestore();
const school=(uid='school-one-monitor')=>env.authenticatedContext(uid,{firebase:{sign_in_provider:'password'}}).firestore();
const anon=(uid='installation')=>env.authenticatedContext(uid,{firebase:{sign_in_provider:'anonymous'}}).firestore();
const publicDb=()=>env.unauthenticatedContext().firestore();
async function seed(path,data){await env.withSecurityRulesDisabled(c=>setDoc(doc(c.firestore(),path),data));}
async function access(){await seed('platform_monitor_access/school-one-monitor',{schoolId:'school-one'});await seed('platform_monitor_access/school-two-monitor',{schoolId:'school-two'});}
function summary(id='school-one'){return {schoolId:id,lastSeenAt:Timestamp.now(),reportedAt:serverTimestamp(),studentCount:3000,teacherCount:50,studentAppUsers:3000,onlineStudents:30,onlineTeachers:2,windowsVersion:'2.1.80',mobileVersion:'1.0.473'};}
function report(db,id='school-one_'+'a'.repeat(32),schoolId='school-one'){
 const batch=writeBatch(db);
 batch.set(doc(db,'platform_complaints/'+id),{schoolId,source:'android',role:'student',message:'Attendance problem',version:'1.0.473',status:'open',createdAt:serverTimestamp()});
 batch.set(doc(db,'platform_support_limits/'+schoolId),{lastSentAt:serverTimestamp(),complaintId:id});return batch.commit();
}
test('licence creation, renewal and monitoring provisioning require the developer claim',async()=>{
 await access();const key='a'.repeat(64);
 for(const db of [publicDb(),anon(),school(),env.authenticatedContext('ordinary').firestore()]){
  for(const path of ['platform_licenses/'+key,'platform_license_status/'+key,'platform_schools/school-one','platform_monitor_access/fake'])
   await assertFails(setDoc(doc(db,path),{schoolId:'school-one',expiresAt:Timestamp.fromMillis(Date.now()+86400000)}));
 }
 await assertSucceeds(setDoc(doc(dev(),'platform_licenses/'+key),{schoolId:'school-one'}));
 await assertSucceeds(updateDoc(doc(dev(),'platform_licenses/'+key),{revoked:true}));
});
test('a school can write only its own aggregate and cannot read either school dashboard',async()=>{
 await access();await assertSucceeds(setDoc(doc(school(),'platform_school_summaries/school-one'),summary()));
 await assertFails(setDoc(doc(school(),'platform_school_summaries/school-two'),summary('school-two')));
 await assertFails(setDoc(doc(school('school-two-monitor'),'platform_school_summaries/school-one'),summary()));
 for(const db of [publicDb(),anon(),school()]){
  await assertFails(getDoc(doc(db,'platform_school_summaries/school-one')));
  await assertFails(getDocs(collection(db,'platform_school_summaries')));
  await assertFails(getDoc(doc(db,'platform_monitor_access/school-one-monitor')));
 }
 await assertSucceeds(getDocs(collection(dev(),'platform_school_summaries')));
});
test('aggregate schema rejects student records, tokens and invalid counts',async()=>{
 await access();
 for(const extra of [{students:[{name:'Private student'}]},{fcmToken:'private'}, {studentCount:-1},{onlineStudents:1000001},{teacherCount:'50'}, {schoolId:'school-two'}])
  await assertFails(setDoc(doc(school(),'platform_school_summaries/school-one'),{...summary(),...extra}));
});
test('central summary writes are limited to one per school every five minutes',async()=>{
 await access();const ref=doc(school(),'platform_school_summaries/school-one');
 await assertSucceeds(setDoc(ref,summary()));await assertFails(setDoc(ref,summary()));
 await seed('platform_school_summaries/school-one',{...summary(),reportedAt:Timestamp.fromMillis(Date.now()-301000)});
 await assertSucceeds(setDoc(ref,summary()));
});
test('school and device trials use immutable server time and cannot be reset',async()=>{
 for(const path of ['platform_device_trials/'+'a'.repeat(64),'platform_school_trials/school-one']){
  const uid=path.split('/')[0],db=anon(uid),ref=doc(db,path);await assertFails(setDoc(ref,{createdAt:Timestamp.fromMillis(Date.now()+86400000)}));
  await assertFails(setDoc(ref,{createdAt:serverTimestamp(),expiresAt:Timestamp.fromMillis(Date.now()+86400000)}));
  await assertFails(setDoc(doc(publicDb(),path),{createdAt:serverTimestamp()}));
  const batch=writeBatch(db);batch.set(ref,{createdAt:serverTimestamp()});
  batch.set(doc(db,'platform_trial_claims/'+uid),{target:path,createdAt:serverTimestamp()});
  await assertSucceeds(batch.commit());
  const another=writeBatch(db);another.set(doc(db,'platform_device_trials/'+'c'.repeat(64)),{createdAt:serverTimestamp()});
  another.set(doc(db,'platform_trial_claims/'+uid),{target:'platform_device_trials/'+'c'.repeat(64),createdAt:serverTimestamp()});
  await assertFails(another.commit());
  await assertFails(updateDoc(ref,{createdAt:serverTimestamp()}));await assertFails(deleteDoc(ref));
  await assertSucceeds(getDoc(doc(publicDb(),path)));
 }
 await assertFails(getDocs(collection(anon(),'platform_school_trials')));
});
test('public exact licence status reads cannot enumerate keys or expose purchase details',async()=>{
 const hash='b'.repeat(64);await seed('platform_license_status/'+hash,{schoolId:'school-one',revoked:false,expiresAt:Timestamp.now()});
 await seed('platform_licenses/'+hash,{amount:999,issuedBy:'developer'});
 await assertSucceeds(getDoc(doc(publicDb(),'platform_license_status/'+hash)));
 await assertFails(getDocs(collection(publicDb(),'platform_license_status')));
 await assertFails(getDoc(doc(publicDb(),'platform_licenses/'+hash)));
});
test('complaints must use the school scope and atomic server-time rate limit',async()=>{
 await access();await assertFails(setDoc(doc(school(),'platform_complaints/school-one_'+'a'.repeat(32)),{
  schoolId:'school-one',source:'android',role:'student',message:'Problem',version:'1',status:'open',createdAt:serverTimestamp()}));
 await assertSucceeds(report(school()));
 await assertFails(report(school(),'school-one_'+'b'.repeat(32)));
 await seed('platform_support_limits/school-one',{lastSentAt:Timestamp.fromMillis(Date.now()-31000)});
 await assertSucceeds(report(school(),'school-one_'+'b'.repeat(32)));
 await assertFails(report(school(),'school-two_'+'c'.repeat(32),'school-two'));
 await assertFails(updateDoc(doc(school(),'platform_complaints/school-one_'+'a'.repeat(32)),{status:'resolved'}));
 await assertFails(getDocs(collection(school(),'platform_complaints')));
 await assertSucceeds(updateDoc(doc(dev(),'platform_complaints/school-one_'+'a'.repeat(32)),{status:'resolved'}));
});
test('removing monitoring access immediately revokes an old identity',async()=>{
 await access();await assertSucceeds(deleteDoc(doc(dev(),'platform_monitor_access/school-one-monitor')));
 await assertFails(setDoc(doc(school(),'platform_school_summaries/school-one'),summary()));
});
test('completed-release update metadata remains public but cannot be overwritten or listed',async()=>{
 await seed('app_config/android_update',{versionCode:472});
 await assertSucceeds(getDoc(doc(publicDb(),'app_config/android_update')));
 await assertFails(getDocs(collection(publicDb(),'app_config')));
 await assertFails(setDoc(doc(school(),'app_config/android_update'),{versionCode:999}));
});
test('mobile sessions, raw school records and unlisted data remain private centrally',async()=>{
 await access();for(const path of ['platform_mobile_sessions/private','students_directory/student','mobile_users/private','unknown/private']){
  await seed(path,{name:'Private student'});
  await assertFails(getDoc(doc(school(),path)));await assertFails(setDoc(doc(school(),path),{name:'Changed'}));
 }
});
