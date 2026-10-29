'use strict';
// Arithmetic planning only. No network, credentials, database writes or load generation.
function capacityBudget({schools=400,studentsPerSchool=250,pcsPerSchool=1,activeHours=8,pollSeconds=20,attendanceStorage='firestore',eventsPerStudent=1,burstSeconds=60}={}) {
  if(!['firestore','cloudflare'].includes(attendanceStorage)||!Number.isSafeInteger(eventsPerStudent)||eventsPerStudent<1||eventsPerStudent>2||!Number.isFinite(burstSeconds)||burstSeconds<1||burstSeconds>86400)throw Error('Invalid attendance planning scenario');
  for(const [name,value] of Object.entries({schools,studentsPerSchool,pcsPerSchool,activeHours,pollSeconds})) {
    if(!Number.isFinite(value)||value<=0)throw Error('Invalid positive planning input: '+name);
  }
  if(![schools,studentsPerSchool,pcsPerSchool].every(Number.isSafeInteger)||pcsPerSchool>5||activeHours>24)throw Error('Planning scope exceeds school/device/day bounds');
  const students=schools*studentsPerSchool;
  if(!Number.isSafeInteger(students))throw Error('Planning student count exceeds safe arithmetic');
  const requests=schools*pcsPerSchool*activeHours*3600/pollSeconds;
  // Current licensed-PC identity() reads membership, entitlement and licence status.
  if(!Number.isFinite(requests)||requests>Number.MAX_SAFE_INTEGER/3)throw Error('Planning request count exceeds safe arithmetic');
  const reads=requests*3;
  // Current accepted -> claimed -> completed Firestore attendance lifecycle.
  const entries=students*eventsPerStudent;
  if(!Number.isSafeInteger(entries))throw Error('Attendance event count exceeds safe arithmetic');
  const attendanceWrites=attendanceStorage==='firestore'?entries*3:0;
  if(!Number.isSafeInteger(attendanceWrites))throw Error('Attendance write count exceeds safe arithmetic');
  return {scope:'arithmetic scenario; not observed provider throughput or an SLA',inputs:{schools,studentsPerSchool,pcsPerSchool,activeHours,pollSeconds,attendanceStorage,eventsPerStudent,burstSeconds},students,
    idleLongPoll:{requests,minimumIdentityReads:reads,freeReadQuota:50000,quotaMultiple:reads/50000},
    oneEntryPerStudent:{entries,minimumOutboxWrites:attendanceWrites,freeWriteQuota:20000,quotaMultiple:attendanceWrites/20000},
    requiredBurst:{events:entries,seconds:burstSeconds,globalAcceptsPerSecond:entries/burstSeconds,perSchoolAcceptsPerSecond:studentsPerSchool*eventsPerStudent/burstSeconds},
    notes:['One-hour reconciliation does not remove real-time change-feed subscription requests.','Cloudflare mode excludes only Firestore attendance queue lifecycle writes; it does not mean zero Firebase or Google usage.','Only a production measurement can supply real service capacity, account quotas and p95/p99.'],
    exclusions:['listener delivery and reconnect reads','record hint and replay writes','transactions/retries','auth/provider calls','presence and monitoring','media and documents','Google Script/Drive requests and execution ownership','Cloudflare storage and request budgets'],
    quotaSource:'https://firebase.google.com/docs/firestore/quotas',scriptQuotaSource:'https://developers.google.com/apps-script/guides/services/quotas',verifiedOn:'2026-10-29'};
}
if(require.main===module){
  console.log(JSON.stringify([1,5].flatMap(pcsPerSchool=>['firestore','cloudflare'].map(attendanceStorage=>capacityBudget({pcsPerSchool,attendanceStorage}))),null,2));
}
module.exports={capacityBudget};
