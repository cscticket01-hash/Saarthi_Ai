import {schoolPattern} from './protocol';
type RolloutEnv={LIVE_SYNC_TEST_SCHOOL_ID?:string;LIVE_SYNC_SCHOOLS?:string};
// The broker still authenticates the school and durably fences/seeds every
// collection. Allowlisting only permits those commands; it never seeds data.
export function liveSchoolEnabled(env:RolloutEnv,school:string):boolean{
 if(!schoolPattern.test(school))return false;
 const schools=(env.LIVE_SYNC_SCHOOLS||'').split(',').map(s=>s.trim()).filter(Boolean);
 // Keep the existing isolated-test binding for compatible TEST deployments.
 if(env.LIVE_SYNC_TEST_SCHOOL_ID)schools.push(env.LIVE_SYNC_TEST_SCHOOL_ID);
 if(schools.length>401||schools.some(s=>!schoolPattern.test(s))||new Set(schools).size>400)return false;
 return schools.includes(school);
}
