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
test('QR connection information cannot authorise a legacy admin action',()=>{const {context}=backend();assert.throws(()=>context.VS_requireAdmin({schoolProjectId:'school-one'}),/administrator login/);});
test('administrator proof from another school is rejected',()=>{const {context}=backend();assert.throws(()=>context.VS_requireAdmin({schoolProjectId:'school-two',schoolAdminIdToken:'t'.repeat(60)}),/administrator login/);});
test('a reused class/roll ID cannot reveal another pupil history',()=>{const {context}=backend();context.VS_query=()=>[{id:'foreign',studentId:'Class 5_Roll_12',personId:'p-other',studentName:'Other pupil'},{id:'own',studentId:'Class 5_Roll_12',personId:'p-own'}];const own=context.VS_own('fee_payments',{personId:'p-own',person:{id:'Class 5_Roll_12'}});assert.equal(own.length,1);assert.equal(own[0].id,'own');});

test('unmigrated history on a reused roll requires matching pupil identity',()=>{const {context}=backend();context.VS_query=()=>[{id:'foreign',studentId:'Class 5_Roll_12',studentName:'Other pupil'},{id:'unknown',studentId:'Class 5_Roll_12'},{id:'own',studentId:'Class 5_Roll_12',studentName:'Private pupil',dob:'15/03/2015'}];const own=context.VS_own('fee_payments',{personId:'p-own',person:{id:'Class 5_Roll_12',name:'Private pupil',dob:'15/03/2015'}});assert.equal(own.length,1);assert.equal(own[0].id,'own');});
function promotionSheet(){
 const {context}=backend();const headers=['Name','Parent Name','Class','Roll No','Date of Birth','Timestamp'];
 const students={rows:[headers,['Private pupil','Parent','Class 5','12','15/03/2015','original'],['Other pupil','Other parent','Class 6','12','01/01/2014','original']]};
 const documents={rows:[['type','studentId','name','class','roll'],['ID','Class 5_Roll_12','Private pupil','Class 5','12']]};
 for(const sheet of [students,documents]){sheet.getLastRow=()=>sheet.rows.length;sheet.getRange=(row,col,count,width)=>({getValues:()=>sheet.rows.slice(row-1,row-1+count).map(r=>r.slice(col-1,col-1+width)),setValues:values=>{if(sheet.fail){sheet.fail=false;throw Error('Document write failed');}values.forEach((v,i)=>sheet.rows[row-1+i].splice(col-1,width,...v));}});}
 Object.assign(context,{STUDENT_SHEET_NAME:'students',STUDENT_HEADERS:headers,STUDENT_DOCUMENT_INDEX_SHEET:'documents',STUDENT_DOCUMENT_HEADERS:documents.rows[0],LockService:{getScriptLock:()=>({waitLock(){},releaseLock(){}})},getOrCreateDatabaseSheet:name=>name==='students'?students:documents,findStudentRow:(s,c,r)=>s.rows.findIndex((v,i)=>i>0&&v[2]===c&&v[3]===r)+1,normalizeClass:v=>String(v),normalizeRoll:v=>String(v)});
 // Existing backend returns -1 when a student row does not exist.
 context.findStudentRow=(s,c,r)=>{const i=s.rows.findIndex((v,i)=>i>0&&v[2]===c&&v[3]===r);return i<0?-1:i+1;};
 const body={oldClass:'Class 5',newClass:'Class 6',rollNo:'12',newRollNo:'13',oldStudentId:'Class 5_Roll_12',newStudentId:'Class 6_Roll_13',studentName:'Private pupil',dob:'15/03/2015'};
 return {context,students,documents,body};
}
test('promotion uses a free roll and preserves the pupil already in the next class',()=>{const {context,students,documents,body}=promotionSheet();context.VS_changeStudentClass(body);assert.equal(students.rows[1][2],'Class 6');assert.equal(students.rows[1][3],'13');assert.equal(students.rows[2][0],'Other pupil');assert.equal(students.rows[2][3],'12');assert.equal(documents.rows[1][1],'Class 6_Roll_13');});
test('promotion refuses an occupied destination without changing either pupil',()=>{const {context,students,body}=promotionSheet();const before=JSON.stringify(students.rows);assert.throws(()=>context.VS_changeStudentClass({...body,newRollNo:'12'}),/occupied/);assert.equal(JSON.stringify(students.rows),before);});
test('a document-index failure rolls back both student and document sheet data',()=>{const {context,students,documents,body}=promotionSheet();const before=JSON.stringify([students.rows,documents.rows]);documents.fail=true;assert.throws(()=>context.VS_changeStudentClass(body),/Document write failed/);assert.equal(JSON.stringify([students.rows,documents.rows]),before);});
test('promotion accepts a DOB stored as a real Google Sheet date',()=>{const {context,students,body}=promotionSheet();context.Utilities.formatDate=(date)=>date.toISOString().slice(0,10);students.rows[1][4]=new Date('2015-03-15T00:00:00Z');context.VS_changeStudentClass(body);assert.equal(students.rows[1][3],'13');});
