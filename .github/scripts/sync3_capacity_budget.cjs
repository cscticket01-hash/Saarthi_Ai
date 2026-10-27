'use strict';
// Arithmetic planning only. No network, credentials, database writes or load generation.
function capacityBudget({schools=400,studentsPerSchool=250,pcsPerSchool=1,activeHours=8,pollSeconds=20}={}) {
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
  const attendanceWrites=students*3;
  return {scope:'arithmetic scenario; not observed provider throughput or an SLA',inputs:{schools,studentsPerSchool,pcsPerSchool,activeHours,pollSeconds},students,
    idleLongPoll:{requests,minimumIdentityReads:reads,freeReadQuota:50000,quotaMultiple:reads/50000},
    oneEntryPerStudent:{entries:students,minimumOutboxWrites:attendanceWrites,freeWriteQuota:20000,quotaMultiple:attendanceWrites/20000},
    exclusions:['listener delivery and reconnect reads','record hint and replay writes','transactions/retries','auth/provider calls','presence and monitoring','media and documents','exit attendance'],
    quotaSource:'https://firebase.google.com/docs/firestore/quotas',verifiedOn:'2026-10-26'};
}
if(require.main===module){
  console.log(JSON.stringify([1,5].map(pcsPerSchool=>capacityBudget({pcsPerSchool})),null,2));
}
module.exports={capacityBudget};
