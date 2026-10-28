'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {fixture,A,B}=require('./helpers/managed-school-broker');
test('developer changes same UID password without modifying school data or licence',async()=>{
 const f=fixture(),revoked=[];f.auth.revokeRefreshTokens=async uid=>revoked.push(uid);
 f.docs.set('schools/'+A+'/students_directory/student',{name:'Keep student'});
 const membership=structuredClone(f.docs.get('school_memberships/A')),entitlement=structuredClone(f.docs.get('school_entitlements/'+A)),school=structuredClone(f.docs.get('platform_schools/'+A));
 const result=await f.call({action:'developer/managed/password/change',schoolId:A,password:'new-secure-password'},'developer');
 assert.deepEqual(result,{success:true,schoolId:A,passwordChanged:true});assert.deepEqual(f.users.get('A'),{password:'new-secure-password'});assert.deepEqual(revoked,['A']);
 assert.deepEqual(f.docs.get('school_memberships/A'),membership);assert.deepEqual(f.docs.get('platform_schools/'+A),school);
 const updated=f.docs.get('school_entitlements/'+A);delete updated.sessionValidAfter;assert.deepEqual(updated,entitlement);
 assert.deepEqual(f.docs.get('schools/'+A+'/students_directory/student'),{name:'Keep student'});assert.equal(f.sent.length,0);assert.equal(JSON.stringify(result).includes('new-secure-password'),false);
});
test('school callers, malformed passwords and foreign mappings cannot reset credentials',async()=>{
 const f=fixture();await assert.rejects(f.call({action:'developer/managed/password/change',schoolId:A,password:'new-secure-password'}),e=>e.status===403);
 for(const password of ['',123,'short','x'.repeat(129)])await assert.rejects(f.call({action:'developer/managed/password/change',schoolId:A,password},'developer'),e=>e.status===400);
 f.docs.get('platform_schools/'+A).authUid='B';await assert.rejects(f.call({action:'developer/managed/password/change',schoolId:A,password:'new-secure-password'},'developer'),e=>e.status===409);
 assert.equal(f.users.size,0);assert.equal(f.docs.get('school_memberships/B').schoolId,B);
});
test('archived and disabled schools cannot regain access through password reset',async()=>{
 for(const flag of [{deletedAt:123},{loginDisabled:true}]){const f=fixture();Object.assign(f.docs.get('platform_schools/'+A),flag);await assert.rejects(f.call({action:'developer/managed/password/change',schoolId:A,password:'new-secure-password'},'developer'),e=>e.status===409);assert.equal(f.users.size,0);}
});
