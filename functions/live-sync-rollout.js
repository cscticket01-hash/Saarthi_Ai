'use strict';
const SCHOOL=/^vs-[a-f0-9]{32}$/;
const ISOLATED='vs-db8afb01a3be46a983c8284714d06e5d';
// Admission is explicit. A wildcard must never silently migrate existing schools.
function liveSyncSchools(env={}){
 const values=String(env.SAARTHI_LIVE_SYNC_SCHOOLS||'').split(',').map(s=>s.trim()).filter(Boolean);
 const legacy=String(env.SAARTHI_LIVE_SYNC_TEST_SCHOOL_ID||'').trim();
 if(legacy&&legacy!==ISOLATED)throw Error('Invalid isolated live sync school');
 if(legacy)values.push(legacy);
 if(values.length>401||values.some(s=>!SCHOOL.test(s)))throw Error('Invalid live sync rollout school list');
 const schools=[...new Set(values)];
 if(schools.length>400)throw Error('Live sync rollout exceeds 400 schools');
 return schools;
}
module.exports={liveSyncSchools};
