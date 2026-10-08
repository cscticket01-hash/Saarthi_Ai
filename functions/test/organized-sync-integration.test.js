'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {storage}=require('./helpers/managed-storage');
const {fixture,A,B,time}=require('./helpers/managed-school-broker');
test('signed broker -> organized Script CAS ACK -> mobile delta + automatic website delta; cloud reads continue with no Windows heartbeat',async()=>{
 const gs=storage();class FixedDate extends Date {constructor(...args){super(...(args.length?args:[time]));}static now(){return time;}}gs.context.Date=FixedDate;
 const broker=fixture(async(_,opt)=>({ok:true,status:200,text:async()=>JSON.stringify(gs.context.VS_managedHandle({postData:{contents:opt.body}}))}));
 let serial=0;
 async function write(col,id,data,revision=''){return broker.call({action:'managed/records',collection:col,operation:'write',id,syncProtocol:2,operationId:'integration-op-'+String(++serial).padStart(16,'0'),expectedRecordRevision:revision,data});}
 await write('students_directory','pupil',{name:'Own Student',class:'1',rollNo:'1',dob:'2015-01-01',mobileLinkToken:'x'.repeat(48),mobileStableId:'own'});
 await write('students_directory','other',{name:'Other',class:'2',rollNo:'2',dob:'2015-01-01',mobileLinkToken:'y'.repeat(48)});
 const login=await broker.call({action:'managed/mobile',schoolId:A,request:{action:'mobile_login',role:'student',personId:'pupil',projectId:A,linkToken:'x'.repeat(48),studentClass:'1',rollNo:'1',dob:'2015-01-01'}});
 gs.context.VS_beginOrganizedStorageMigration();for(let i=0;i<100&&gs.context.VS_organizedStorageStatus().phase!=='complete';i++)gs.context.VS_stepOrganizedStorageMigration();assert.equal(gs.context.VS_organizedStorageStatus().phase,'complete');
 const ack=await write('exam_center_results','exam_own',{personId:'own',studentName:'Own Student',examId:'exam',marks:88,timestamp:1});assert.equal(ack.syncProtocol,2);assert(ack.recordRevision);
 await write('exams','exam',{examName:'Unit Test'});await write('fee_settings','Class_1__2026-2027',{className:'Class 1',academicSession:'2026-2027',fees:{Tuition:125.75}});await write('fee_settings','Class_2',{className:'Class 2',fees:{Tuition:999}});await write('school_notices','notice',{title:'Cloud notice',timestamp:1});
 assert(!broker.docs.get('platform_schools/'+A).lastSeenAt);
 const mobile=await broker.call({action:'managed/mobile',schoolId:A,request:{action:'mobile_dashboard',sessionToken:login.sessionToken,projectId:A}});
 assert.equal(mobile.reportCards.length,1);assert.equal(mobile.reportCards[0].marks,88);assert.equal(mobile.feeStructures.length,1);assert.equal(mobile.feeStructures[0].fees.Tuition,125.75);assert.equal(mobile.examinations[0].examName,'Unit Test');assert.equal(mobile.notices[0].title,'Cloud notice');
 const website=await broker.call({action:'developer/managed/view',schoolId:A},'developer');assert.equal(website.groups.examResults.rows[0].marks,88);assert.equal(website.groups.fee_settings.count,2);
 const unchanged=await broker.call({action:'developer/managed/view',schoolId:A,knownRevisions:website.revisions},'developer');assert.deepEqual(unchanged.groups,{});
 await assert.rejects(broker.call({action:'developer/managed/view',schoolId:A},'B'),error=>error.status===403);
 await assert.rejects(broker.call({action:'managed/mobile',schoolId:B,request:{action:'mobile_dashboard',sessionToken:login.sessionToken,projectId:A}}));
});
test('website view validates tenant/shape before returning data and rejects malformed checkpoints',async()=>{
 const f=fixture(async()=>({ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,groups:{exams:{count:1,rows:[{id:'foreign',schoolId:B}]}},revisions:{exams:'r'}})}));
 await assert.rejects(f.call({action:'developer/managed/view',schoolId:A},'developer'),e=>e.status===502);
 await assert.rejects(f.call({action:'developer/managed/view',schoolId:A,knownRevisions:[]},'developer'),e=>e.status===400);
});
