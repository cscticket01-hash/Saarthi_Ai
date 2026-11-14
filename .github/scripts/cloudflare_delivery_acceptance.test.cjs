'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {acceptance,verifiedRecordRoute,retryOriginalTimeout,ENDPOINT,LOGIN,SCHOOL}=require('./cloudflare_delivery_acceptance.cjs');
const env={VS_CF_DELIVERY_ACCEPTANCE:'1',VS_EXPECTED_RUNTIME:'a'.repeat(40),
 VS_CF_DELIVERY_RUN_ID:'synthetic-retained',VS_TEST_LOGIN_EMAIL:'secret-test-email',VS_TEST_LOGIN_PASSWORD:'secret-test-password'};
test('live acceptance cannot run without explicit opt-in and a stable run ID',async()=>{
 for(const patch of [{VS_CF_DELIVERY_ACCEPTANCE:'0'},{VS_CF_DELIVERY_RUN_ID:'../unsafe'},{VS_EXPECTED_RUNTIME:'wrong'}]){
  let requests=0;const result=await acceptance({env:{...env,...patch},request:async()=>{requests++;throw Error();}});
  assert.equal(result.status,'FAIL');assert.equal(requests,0);
 }
});
test('unexpected deployed runtime prevents TEST login and all writes',async()=>{
 const calls=[];const result=await acceptance({env,request:async(url,body)=>{
  calls.push({url,body});return {status:200,data:{ready:true,projectId:'saarthi-ai-df12b',runtimeCommit:'b'.repeat(40)}};
 }});
 assert.equal(result.status,'FAIL');assert.equal(calls.length,1);assert.equal(calls[0].url,ENDPOINT+'/healthz');assert.equal(calls[0].body,undefined);
});
test('foreign membership fails before business data and reports no credentials',async()=>{
 const calls=[];const result=await acceptance({env,request:async(url,body)=>{
  calls.push({url,body});
  if(url===ENDPOINT+'/healthz')return {status:200,data:{ready:true,projectId:'saarthi-ai-df12b',runtimeCommit:env.VS_EXPECTED_RUNTIME}};
  if(url===LOGIN)return {status:200,data:{idToken:'private-token',localId:'private-uid'}};
  assert.equal(body.schoolId,SCHOOL);assert.equal(body.action,'managed/session');
  return {status:403,data:{success:false,code:'SCHOOL_MEMBERSHIP_REQUIRED',message:'private-secret'}};
 }});
 assert.equal(result.status,'FAIL');assert.equal(calls.length,3);
 assert.doesNotMatch(JSON.stringify(result),/private-token|private-uid|private-secret|secret-test-email|secret-test-password/);
});

test('person lifecycle signed Drive proof is not mislabeled Cloudflare',()=>{
 const person={success:true,schoolId:SCHOOL,syncProtocol:2,personLifecycleVersion:1,recordRevision:'original-google-123'};
 assert.equal(verifiedRecordRoute(person,'person'),true);
 assert.equal(verifiedRecordRoute(person,'edge'),false);
 assert.equal(verifiedRecordRoute({...person,cloudflareAccepted:true},'person'),false);
 assert.equal(verifiedRecordRoute({...person,delivery:{lane:'records',id:'a'.repeat(64)}},'person'),false);
 assert.equal(verifiedRecordRoute({...person,recordRevision:'cf-unknown'},'person'),false);
});
test('Cloudflare-backed record requires verified Google Drive receipt, not pending or fake lifecycle',()=>{
 const edge={success:true,schoolId:SCHOOL,cloudflareAccepted:true,driveState:'verified',recordRevision:'google-456'};
 assert.equal(verifiedRecordRoute(edge,'edge'),true);
 for(const invalid of [
  {...edge,driveState:'pending'},
  {...edge,driveState:'retry'},
  {...edge,cloudflareAccepted:false},
  {...edge,delivery:{lane:'records',id:'b'.repeat(64)}},
  {...edge,recordRevision:'cf-staged-only'},
  {...edge,recordRevision:null},
 ])assert.equal(verifiedRecordRoute(invalid,'edge'),false);
 assert.equal(verifiedRecordRoute(edge,'person'),false);
});

const calendarRequest={action:'managed/records',operation:'write',syncProtocol:2,
 collection:'school_calendar',id:'synthetic',operationId:'a'.repeat(64),
 schoolId:SCHOOL,expectedRecordRevision:'',data:{title:'SYNTHETIC'}};
const scriptTimeout=()=>Object.assign(new Error('signed timeout'),{status:504,code:'SCRIPT_TIMEOUT'});
test('signed Script timeout resends only the exact original operation once',async()=>{
 const calls=[],waits=[];
 const result=await retryOriginalTimeout(async body=>{
  calls.push(JSON.stringify(body));
  if(calls.length===1)throw scriptTimeout();
  return {success:true,cloudflareAccepted:true,delivery:{id:'b'.repeat(64),lane:'records'}};
 },structuredClone(calendarRequest),{sleep:async ms=>waits.push(ms)});
 assert.equal(result.delivery.lane,'records');
 assert.deepEqual(calls,[JSON.stringify(calendarRequest),JSON.stringify(calendarRequest)]);
 assert.deepEqual(waits,[12000]);
});
test('unverified repeated timeout stays failed after one bounded retry',async()=>{
 let calls=0;
 await assert.rejects(retryOriginalTimeout(async()=>{calls++;throw scriptTimeout()},calendarRequest,
  {sleep:async()=>{}}),e=>e.status===504&&e.code==='SCRIPT_TIMEOUT');
 assert.equal(calls,2);
});
test('non-immutable or non-authenticated retries fail immediately',async()=>{
 for(const body of [{...calendarRequest,operationId:'wrong'},
  {...calendarRequest,operation:'delete'},{action:'managed/file/upload',uploadKey:'synthetic'}]){
  let calls=0;
  await assert.rejects(retryOriginalTimeout(async()=>{calls++;throw scriptTimeout()},body,
   {sleep:async()=>{}}));
  assert.equal(calls,1);
 }
 for(const err of [{status:503,code:'SCRIPT_TIMEOUT'},{status:504,code:'UNKNOWN'},{status:409,code:'CONFLICT'}]){
  let calls=0;
  await assert.rejects(retryOriginalTimeout(async()=>{calls++;throw Object.assign(new Error(),err)},calendarRequest,
   {sleep:async()=>{}}));
  assert.equal(calls,1);
 }
});
test('status timeout retries exactly the same authenticated receipt ticket',async()=>{
 const status={action:'managed/cloudflare/operation',schoolId:SCHOOL,lane:'records',
  id:'f'.repeat(64),waitMillis:20000};
 let calls=0;
 const result=await retryOriginalTimeout(async input=>{
  assert.deepEqual(input,status);calls++;
  if(calls===1)throw scriptTimeout();
  return {success:true,driveState:'verified',recordRevision:'drive-123'};
 },status,{sleep:async()=>{}});
 assert.equal(calls,2);
 assert.equal(result.driveState,'verified');
});
test('mutated original request cannot be reissued after signed timeout',async()=>{
 const mutated=structuredClone(calendarRequest);
 let calls=0;
 await assert.rejects(retryOriginalTimeout(async body=>{
  calls++;body.data.title='FORGED';
  throw scriptTimeout();
 },mutated,{sleep:async()=>{}}),/Immutable original request changed/);
 assert.equal(calls,1);
});
