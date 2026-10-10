'use strict';
const assert=require('node:assert/strict');
// Read-only deployment fence before pairing or any fixture writes. No secrets,
// no production endpoint, and no fallback from a different backend runtime.
async function waitForRuntime(sha,{fetchImpl=fetch,delay=ms=>new Promise(r=>setTimeout(r,ms)),attempts=36}={}) {
 assert.match(sha||'',/^[a-f0-9]{40}$/);
 for(let n=0;n<attempts;n++) {
  try {
   const r=await fetchImpl('https://saarthi-sync-v2-test.onrender.com/school-cloud/healthz',{signal:AbortSignal.timeout(15000)});
   if(r.status===200) {
    const data=await r.json();
    if(data.ready===true&&data.projectId==='saarthi-ai-df12b'&&data.runtimeCommit===sha) {
     console.log('Verified isolated TEST backend runtime identity');return;
    }
   }
  } catch (_) { /* A failed GET cannot authorize fixture writes. */ }
  if(n%6===0)console.log('Waiting for the reviewed isolated TEST backend deployment');
  if(n+1<attempts)await delay(10000);
 }
 throw new Error('Reviewed isolated TEST runtime remains unverified');
}
module.exports={waitForRuntime};
