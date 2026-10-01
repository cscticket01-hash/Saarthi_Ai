'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');
function backend(role = 'student') {
 const person={id:'Class 5_Roll_12',name:'Private pupil',class:'Class 5',rollNo:'12',dob:'15/03/2015',mobileLinkToken:'a'.repeat(48)};
 const context = vm.createContext({Date,JSON,Math,Number,String,Object,Array,Error,PropertiesService:{getScriptProperties:()=>({getProperty:()=> 'school-one'})},Utilities:{DigestAlgorithm:{SHA_256:'SHA_256'},computeDigest:(_,s)=>[...crypto.createHash('sha256').update(s).digest()],getUuid:()=>crypto.randomUUID(),formatDate:()=> '2026-10-01'}});
 vm.runInContext(fs.readFileSync(require('node:path').join(__dirname,'../../school-backend/SaarthiMobile.gs'),'utf8'), context);
 context.VS_get=(col)=>col==='mobile_sessions'?{personId:person.id,documentId:person.id,role,linkToken:person.mobileLinkToken,expiresAt:Date.now()+60000}:col===`${role==='teacher'?'teachers':'students'}_directory`?person:null;
 context.VS_query=()=>[];context.VS_set=()=>({});context.VS_requireLicense=()=>{};
 return {context,person};
}
function credentials(p){return {action:'mobile_login',projectId:'school-one',role:'student',personId:p.id,linkToken:p.mobileLinkToken,studentClass:'Class 5',rollNo:'12',dob:'15/03/2015'};}
test('a foreign Firebase project cannot sign into this school backend',()=>{const {context,person}=backend();assert.throws(()=>context.VS_mobileAction({...credentials(person),projectId:'school-two'}),/do not match/);});
test('a student QR still requires matching class, roll and DOB',()=>{const {context,person}=backend();for(const wrong of [{studentClass:'Class 6'},{rollNo:'13'},{dob:'14/03/2015'}])assert.throws(()=>context.VS_mobileAction({...credentials(person),...wrong}),/incorrect/);assert.equal(context.VS_mobileAction(credentials(person)).role,'student');});
test('teacher QR cannot be used as a student login',()=>{const {context,person}=backend('teacher');assert.throws(()=>context.VS_mobileAction(credentials(person)),/does not belong/);});
test('a closed date rejects attendance for both roles before location checks',()=>{for(const role of ['student','teacher']){const {context}=backend(role);context.VS_isOpen=()=>false;assert.throws(()=>context.VS_mobileAction({action:'mobile_mark_attendance',sessionToken:'s'.repeat(50)}),/closed today/);}});
test('student DOB cannot be skipped when the school record has no DOB',()=>{const {context,person}=backend();person.dob='';assert.throws(()=>context.VS_mobileAction({...credentials(person),dob:''}),/incorrect/);});
