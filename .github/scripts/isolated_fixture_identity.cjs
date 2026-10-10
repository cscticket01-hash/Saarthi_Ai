'use strict';
// Stable within one hosted attempt, fresh across runs/attempts. Never retime an
// older synthetic attendance record to satisfy a newly issued day permit.
function isolatedRunPrefix(env=process.env) {
 const id=env.GITHUB_RUN_ID,attempt=env.GITHUB_RUN_ATTEMPT||'1';
 if(!/^[1-9][0-9]{0,19}$/.test(id||'')||! /^[1-9][0-9]{0,9}$/.test(attempt))throw Error('Hosted isolated TEST run identity required');
 return `isolated-v2-${id}-${attempt}`;
}
module.exports={isolatedRunPrefix};
