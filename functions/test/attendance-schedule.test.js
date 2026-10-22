'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {storage,A,B}=require('./helpers/managed-storage');
function fixture(){
 const f=storage();let clock=Date.parse('2026-10-19T05:30:00Z'); // 11 IST, after window.
 f.context.Date=class extends Date {constructor(...args){super(...(args.length?args:[clock]));}};
 f.context.Utilities.formatDate=d=>new Date(+d+19800000).toISOString().slice(0,10);
 const write=(collection,id,data)=>{const r=f.call({action:'managed_records',operation:'write',collection,id,data:{...data,schoolId:A}});assert.equal(r.success,true,JSON.stringify(r));};
 const mobile=request=>f.call({action:'managed_mobile',lease:{schoolId:A,expiresAt:Date.now()+86400000},request});
 write('school_settings','school_location',{latitude:24,longitude:92,radiusMeters:200});
 write('school_settings','attendance_schedule',{enabled:true,startMinute:480,endMinute:600});
 write('school_calendar','2026-10-19',{isOpen:true});
 write('students_directory','pupil',{name:'Pupil',class:'1',rollNo:'1',dob:'2015-01-01',mobileLinkToken:'x'.repeat(48)});
 write('teachers_directory','teacher',{name:'Teacher',mobileLinkToken:'t'.repeat(48)});
 function login(role,id,token){return mobile({action:'mobile_login',projectId:A,role,personId:id,linkToken:token,studentClass:'1',rollNo:'1',dob:'2015-01-01'}).sessionToken;}
 const sessionToken=login('student','pupil','x'.repeat(48));assert.ok(sessionToken);
 const request={action:'mobile_mark_attendance',sessionToken,role:'student',personId:'pupil',linkToken:'x'.repeat(48),latitude:24,longitude:92,accuracy:3,mode:'entry',submittedAt:clock};
 return {...f,write,mobile,request,login,setClock:at=>{clock=at;}};
}
test('Script enforces opening/closing minute, accepts delayed in-window capture, and preserves exact retry ACK',()=>{
 const f=fixture(),capture=iso=>Date.parse('2026-10-19T'+iso+'Z');
 for(const at of [capture('02:29:59'),capture('04:30:00')]){
  const r=f.mobile({...f.request,clientCapturedAt:at});assert.equal(r.success,false);assert.match(r.message,/outside the school schedule/);
 }
 const operationId=crypto.createHash('sha256').update('entry').digest('hex');
 const r=f.mobile({...f.request,operationId,clientCapturedAt:capture('02:30:00')});assert.equal(r.success,true,JSON.stringify(r));
 const stored=r.record;assert.equal(stored.entryCapturedAt,capture('02:30:00'));
 assert.equal(f.mobile({action:'mobile_refresh',sessionToken:f.request.sessionToken}).attendancePolicy.recorded,true);
 // Committed receipt survives schedule changes. New submissions cannot replace it.
 f.write('school_settings','attendance_schedule',{enabled:true,startMinute:700,endMinute:800});
 assert.equal(f.mobile({...f.request,operationId,clientCapturedAt:capture('02:30:00')}).success,true);
 assert.equal(f.mobile({...f.request,operationId:'b'.repeat(64),clientCapturedAt:capture('02:30:00')}).success,false);
 const rows=f.call({action:'managed_records',collection:'attendance_records',operation:'read'}).records;
 assert.equal(Object.keys(rows).length,1);assert.equal(Object.values(rows)[0].entryCapturedAt,stored.entryCapturedAt);
});
test('teacher has one daily entry without student schedule; foreign school and malformed windows cannot grant attendance',()=>{
 const f=fixture(),token=f.login('teacher','teacher','t'.repeat(48));
 const request={...f.request,sessionToken:token,role:'teacher',personId:'teacher',linkToken:'t'.repeat(48)};
 assert.equal(f.mobile(request).success,true);assert.equal(f.mobile(request).success,false);
 f.write('school_settings','attendance_schedule',{enabled:true,startMinute:600,endMinute:480});
 assert.equal(f.mobile({...f.request,clientCapturedAt:Date.parse('2026-10-19T03:30:00Z')}).success,false);
 const foreign=f.call({action:'managed_mobile',lease:{schoolId:B,expiresAt:Date.now()+60000},request:f.request});assert.equal(foreign.success,false);
 const policy=f.mobile({action:'mobile_refresh',sessionToken:f.request.sessionToken}).attendancePolicy;
 assert.equal(policy.recorded,false);assert.equal(policy.schedule.startMinute,600);
});
