'use strict';
// Stable within one hosted attempt, fresh across runs/attempts. Never retime an
// older synthetic attendance record to satisfy a newly issued day permit.
function isolatedRunPrefix(env=process.env) {
 const id=env.GITHUB_RUN_ID,attempt=env.GITHUB_RUN_ATTEMPT||'1';
 if(!/^[1-9][0-9]{0,19}$/.test(id||'')||! /^[1-9][0-9]{0,9}$/.test(attempt))throw Error('Hosted isolated TEST run identity required');
 return `isolated-v2-${id}-${attempt}`;
}
function isolatedAttendanceDay(schoolId,at=Date.now()) {
 if(schoolId!=='vs-db8afb01a3be46a983c8284714d06e5d'||!Number.isSafeInteger(at)||at<=0)throw Error('Isolated TEST calendar scope required');
 return new Date(at+19800000).toISOString().slice(0,10);
}
module.exports={isolatedRunPrefix,isolatedAttendanceDay};
