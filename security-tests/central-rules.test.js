'use strict';
const {before,after,beforeEach,test}=require('node:test');
const {readFileSync}=require('node:fs');
const {initializeTestEnvironment,assertFails,assertSucceeds}=require('@firebase/rules-unit-testing');
const {doc,collection,getDoc,getDocs,setDoc,updateDoc,deleteDoc,collectionGroup,writeBatch}=require('firebase/firestore');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32);
let env;
before(async()=>{env=await initializeTestEnvironment({projectId:'demo-saarthi-central',firestore:{rules:readFileSync('../firestore.platform.rules','utf8')}});});
after(async()=>{await env?.cleanup();});
beforeEach(async()=>{await env.clearFirestore();await env.withSecurityRulesDisabled(async c=>{
 await setDoc(doc(c.firestore(),'school_memberships/owner-a'),{schoolId:A,role:'school_admin',active:true});
 await setDoc(doc(c.firestore(),'school_memberships/owner-b'),{schoolId:B,role:'school_admin',active:true});
});});
const a=(claims={schoolId:A,schoolRole:'school_admin'})=>env.authenticatedContext('owner-a',claims).firestore();
const b=()=>env.authenticatedContext('owner-b',{schoolId:B,schoolRole:'school_admin'}).firestore();
const collections=['students_directory','teachers_directory','attendance_logs','teacher_attendance',
 'attendance_records','teacher_schedules','school_notices','school_calendar','exam_results','teacher_salary',
 'school_config','school_settings','fee_settings','fee_ledger','fee_payments','school_expenses',
 'student_scan_index','scanner_devices','documents','backups','exams','exam_center_results'];
test('School A cannot read, query, create, update or delete School B in any operational collection',async()=>{
 for(const name of collections){
  const path='schools/'+B+'/'+name+'/record';
  await assertSucceeds(setDoc(doc(b(),path),{schoolId:B,value:'B private'}));
  await assertFails(getDoc(doc(a(),path)));
  await assertFails(getDocs(collection(a(),'schools/'+B+'/'+name)));
  await assertFails(setDoc(doc(a(),path+'/nested/escape'),{schoolId:A}));
  await assertFails(setDoc(doc(a(),'schools/'+B+'/'+name+'/new'),{schoolId:B}));
  await assertFails(updateDoc(doc(a(),path),{value:'tampered'}));
  await assertFails(deleteDoc(doc(a(),path)));
  await assertSucceeds(setDoc(doc(a(),'schools/'+A+'/'+name+'/own'),{schoolId:A,value:'A private'}));
  await assertSucceeds(getDoc(doc(a(),'schools/'+A+'/'+name+'/own')));
  await assertSucceeds(getDocs(collection(a(),'schools/'+A+'/'+name)));
 }
});
test('Membership, schoolId claims and admin claims cannot grant another school access',async()=>{
 await assertSucceeds(setDoc(doc(b(),'schools/'+B+'/students_directory/pupil'),{schoolId:B}));
 for(const claims of [{schoolId:B,schoolRole:'school_admin'},{admin:true,schoolId:A},{admin:true}])
  await assertFails(getDoc(doc(a(claims),'schools/'+B+'/students_directory/pupil')));
 await assertFails(setDoc(doc(a(),'school_memberships/owner-a'),{schoolId:B,role:'school_admin',active:true}));
 await assertFails(setDoc(doc(a(),'school_memberships/attacker'),{schoolId:A,role:'school_admin',active:true}));
 await assertFails(getDoc(doc(a(),'school_memberships/owner-b')));
 await assertFails(setDoc(doc(a(),'schools/'+A),{ownerUid:'owner-a',schoolId:A}));
 await assertFails(setDoc(doc(a(),'platform_licenses/key'),{schoolId:A}));
});
test('Untagged, mismatched, private credential and root-level writes fail',async()=>{
 for(const data of [{name:'No school'},{schoolId:B},{schoolId:A,refreshToken:'private'},
   {schoolId:A,fileBase64:'bytes'},{schoolId:A,localPath:'private-device'}])
  await assertFails(setDoc(doc(a(),'schools/'+A+'/students_directory/test'),data));
 await assertFails(setDoc(doc(a(),'students_directory/global'),{schoolId:A}));
 await assertFails(getDocs(collectionGroup(a(),'students_directory')));
 await assertFails(getDocs(collection(a(),'schools')));
 await assertFails(setDoc(doc(a(),'schools/'+A+'/unknown/test'),{schoolId:A}));
 const ownDb=a();const batch=writeBatch(ownDb);batch.set(doc(ownDb,'schools/'+A+'/fee_payments/own'),{schoolId:A});
 batch.set(doc(ownDb,'schools/'+B+'/fee_payments/foreign'),{schoolId:B});await assertFails(batch.commit());
});
test('Anonymous users and revoked memberships cannot access either tenant',async()=>{
 for(const db of [env.unauthenticatedContext().firestore(),env.authenticatedContext('stranger',{schoolId:A,schoolRole:'school_admin'}).firestore()])
  await assertFails(getDoc(doc(db,'schools/'+A+'/school_settings/settings')));
 await env.withSecurityRulesDisabled(c=>updateDoc(doc(c.firestore(),'school_memberships/owner-a'),{active:false}));
 await assertFails(setDoc(doc(a(),'schools/'+A+'/school_settings/settings'),{schoolId:A}));
});
test('Tenant audit logs are append-only and private Drive references stay tenant-scoped',async()=>{
 const path='schools/'+A+'/audit_logs/event';
 await assertSucceeds(setDoc(doc(a(),path),{schoolId:A,event:'saved'}));
 await assertFails(updateDoc(doc(a(),path),{event:'rewritten'}));await assertFails(deleteDoc(doc(a(),path)));
 await assertFails(getDoc(doc(b(),path)));
 await assertSucceeds(setDoc(doc(a(),'schools/'+A+'/documents/photo'),{schoolId:A,fileId:'own-drive-file',fileUrl:'https://drive.google.com/file/d/own-drive-file/view'}));
 await assertFails(getDoc(doc(b(),'schools/'+A+'/documents/photo')));
});
