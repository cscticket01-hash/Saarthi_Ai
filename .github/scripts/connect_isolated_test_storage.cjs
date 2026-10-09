'use strict';
// Owner-approved pairing of the single isolated TEST school; never replaces storage.
const fs = require('node:fs');
const schoolId = 'vs-db8afb01a3be46a983c8284714d06e5d';
const endpoint = 'https://saarthi-sync-v2-test.onrender.com/school-cloud';
const scriptUrl = 'https://script.google.com/macros/s/AKfycbyADteva09QBdr8TVB87MYvH_qoaEigph6heLrH83u66Zg1MUW3eoaBrBhK3Stujx28tg/exec';
const apiKey = 'AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const report = {schoolId, scope:'Owner-approved isolated TEST storage pairing and signed readback', checks:[]};
async function post(url, body, token) {
  const start = performance.now();
  const response = await fetch(url, {method:'POST', headers:{'Content-Type':'application/json', ...(token?{Authorization:`Bearer ${token}`}:{})}, body:JSON.stringify(body), signal:AbortSignal.timeout(120000)});
  const data = await response.json();
  return {http:response.status, data, elapsedMs:Math.round(performance.now()-start)};
}
function check(name, r, ok) {
  report.checks.push({name, status:ok?'PASS':'FAIL', http:r.http, elapsedMs:r.elapsedMs, reference:r.data.requestId||null, ...(!ok && typeof r.data.code==='string'?{code:r.data.code}:{})});
  if (!ok) throw new Error(name);
}
async function run() {
  if (process.env.GITHUB_ACTIONS!=='true' || process.env.VS_TEST_CONNECT_CONFIRM!==schoolId) throw new Error('Isolated owner-approved runner required');
  const email=process.env.VS_TEST_LOGIN_EMAIL, password=process.env.VS_TEST_LOGIN_PASSWORD;
  if(!email||!password) throw new Error('TEST login unavailable');
  let r=await post('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key='+apiKey,{email,password,returnSecureToken:true});
  check('TEST Firebase authentication',r,r.http===200&&typeof r.data.idToken==='string');
  const token=r.data.idToken;
  r=await post(endpoint,{action:'managed/session',schoolId},token);
  check('Authenticated TEST identity',r,r.http===200&&r.data.success===true&&r.data.schoolId===schoolId);
  r=await post(endpoint,{action:'managed/storage/connect',schoolId,scriptUrl},token);
  check('Approved TEST pairing',r,r.http===200&&r.data.success===true&&r.data.schoolId===schoolId&&r.data.storageReady===true);
  r=await post(endpoint,{action:'managed/storage/check',schoolId},token);
  check('Signed real TEST storage readback',r,r.http===200&&r.data.success===true&&r.data.schoolId===schoolId&&r.data.storageReady===true&&r.data.brokerRecordSyncVersion===2&&r.data.recordSyncVersion===2);
  report.status='PASS';
}
run().catch(()=>{report.status='FAIL';process.exitCode=1;}).finally(()=>{
  fs.mkdirSync('build/cloud-prerequisites',{recursive:true});
  fs.writeFileSync('build/cloud-prerequisites/storage-pairing.json',JSON.stringify(report,null,2));
  console.log(JSON.stringify(report)); // Never log response bodies or credentials.
});
