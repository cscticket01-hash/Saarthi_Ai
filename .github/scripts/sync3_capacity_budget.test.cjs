'use strict';
const {test}=require('node:test');const assert=require('node:assert/strict');
const {capacityBudget}=require('./sync3_capacity_budget.cjs');
test('400-school eight-hour licensed long-poll bounds exceed shared free quota even at one PC',()=>{
 const v=capacityBudget();assert.equal(v.students,100000);assert.equal(v.idleLongPoll.requests,576000);
 assert.equal(v.idleLongPoll.minimumIdentityReads,1728000);assert.equal(v.idleLongPoll.quotaMultiple,34.56);
 assert.equal(v.oneEntryPerStudent.minimumOutboxWrites,300000);assert.equal(v.oneEntryPerStudent.quotaMultiple,15);
});
test('five PCs multiply authentication reads, not the school student/entry population',()=>{
 const a=capacityBudget(),b=capacityBudget({pcsPerSchool:5});
 assert.equal(b.idleLongPoll.minimumIdentityReads,8640000);assert.equal(b.idleLongPoll.requests,a.idleLongPoll.requests*5);
 assert.equal(b.oneEntryPerStudent.minimumOutboxWrites,a.oneEntryPerStudent.minimumOutboxWrites);
});
test('fractional active time is supported but unsafe, invalid and over-policy inputs fail closed',()=>{
 assert.equal(capacityBudget({activeHours:0.5}).idleLongPoll.requests,36000);
 for(const args of [{schools:0},{schools:1.5},{pcsPerSchool:6},{pollSeconds:NaN},{pollSeconds:Number.MIN_VALUE},{activeHours:25},{studentsPerSchool:Number.MAX_SAFE_INTEGER}])assert.throws(()=>capacityBudget(args));
});
test('Cloudflare planning removes only attendance queue writes and retains auth read scenarios',()=>{
 const before=capacityBudget(),after=capacityBudget({attendanceStorage:'cloudflare',eventsPerStudent:2,burstSeconds:60});
 assert.equal(after.oneEntryPerStudent.minimumOutboxWrites,0);
 assert.equal(after.idleLongPoll.minimumIdentityReads,before.idleLongPoll.minimumIdentityReads);
 assert.equal(after.requiredBurst.events,200000);
 assert.equal(after.requiredBurst.globalAcceptsPerSecond,200000/60);
 assert.equal(after.requiredBurst.perSchoolAcceptsPerSecond,500/60);
 for(const args of [{attendanceStorage:'none'},{eventsPerStudent:3},{burstSeconds:0},{burstSeconds:NaN}])assert.throws(()=>capacityBudget(args));
});
