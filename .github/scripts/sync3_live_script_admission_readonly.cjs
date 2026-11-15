'use strict';
// No school records are changed. This explicitly verifies PR #299's new
// capability field; unchanged scriptBundleVersion alone is not evidence.
const assert=require('node:assert/strict'),fs=require('node:fs');
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d';
const ENDPOINT='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const LOGIN='https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const report={status:'BLOCKED',scope:'read-only TEST owner Script authenticated-admission capability',expectedAdmissionErrorVersion:1};
async function send(url,body,token){
 const r=await fetch(url,{method:'POST',redirect:'error',headers:{'content-type':'application/json',...(token?{authorization:'Bearer '+token}:{})},
  body:JSON.stringify(body),signal:AbortSignal.timeout(60000)});
 return{status:r.status,data:await r.json()};
}
async function run(){
 assert.equal(process.env.GITHUB_ACTIONS,'true');
 assert.equal(process.env.GITHUB_REPOSITORY,'cscticket01-hash/Saarthi_Ai');
 assert.ok(process.env.VS_TEST_LOGIN_EMAIL&&process.env.VS_TEST_LOGIN_PASSWORD,'TEST credentials not configured');
 const login=await send(LOGIN,{email:process.env.VS_TEST_LOGIN_EMAIL,password:process.env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});
 assert.equal(login.status,200,'TEST school Firebase login unavailable');
 assert.ok(typeof login.data.idToken==='string');
 const school=await send(ENDPOINT,{action:'managed/storage/check',schoolId:SCHOOL},login.data.idToken);
 assert.equal(school.status,200,'TEST signed Script health unavailable');
 assert.equal(school.data.success,true);
 assert.equal(school.data.schoolId,SCHOOL);
 const version=require('./reviewed_script_version.cjs').currentReviewedScriptVersion();
 assert.equal(school.data.scriptBundleVersion,version,'TEST school Script version mismatch');
 report.scriptBundleVersion=version;
 report.actualAdmissionErrorVersion=Number.isInteger(school.data.requestAdmissionErrorVersion)?
   school.data.requestAdmissionErrorVersion:'not_advertised';
 if(school.data.requestAdmissionErrorVersion!==1)
   throw Error('PR299 authenticated admission patch NOT deployed at TEST owner Script');
 report.status='PASS';
}
run().catch(e=>{
 report.status='BLOCKED';
 report.blocker=/PR299 authenticated admission patch/.test(e.message)?
  'TEST owner must manually deploy reviewed PR299 Apps Script patch':'Owner-connected signed Script capability cannot be verified';
 process.exitCode=1;
}).finally(()=>{
 fs.mkdirSync('build/cloud-prerequisites',{recursive:true});
 fs.writeFileSync('build/cloud-prerequisites/script-admission-capability.json',JSON.stringify(report,null,2));
 console.log(JSON.stringify(report));
});
