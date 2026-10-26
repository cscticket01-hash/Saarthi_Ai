'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {acceptance,SCHOOL,ENDPOINT}=require('./sync3_native_upload_acceptance.cjs');
const version=require('./reviewed_script_version.cjs').currentReviewedScriptVersion();
const env={VS_TEST_NATIVE_UPLOAD_ACCEPTANCE:'1',VS_EXPECTED_TEST_RUNTIME:'a'.repeat(40),VS_TEST_LOGIN_EMAIL:'test@example.invalid',VS_TEST_LOGIN_PASSWORD:'SECRET_TEST_PASSWORD',VS_TEST_NATIVE_UPLOAD_RUN_ID:'fixture'};
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
function fixture(change={}){
 const calls=[],chunks=[];let offset=0,meta;
 async function request(url,body,token){calls.push({url,body,token});
  if(url.endsWith('/healthz'))return {status:200,data:{ready:true,projectId:'saarthi-ai-df12b',runtimeCommit:env.VS_EXPECTED_TEST_RUNTIME,...change.runtime}};
  if(url.startsWith('https://identitytoolkit.googleapis.com/'))return {status:200,data:{idToken:'SECRET_TEST_TOKEN',localId:'test-user'}};
  assert.equal(url,ENDPOINT);assert.equal(token,'SECRET_TEST_TOKEN');assert.equal(body.schoolId,SCHOOL);
  let data={success:true,schoolId:SCHOOL};
  if(body.action==='managed/session')Object.assign(data,{allowed:true,uid:'test-user',...change.session});
  else if(body.action==='managed/storage/check')Object.assign(data,{storageReady:true,scriptBundleVersion:version,brokerUploadResumableVersion:1,uploadResumableVersion:1,...change.health});
  else if(body.action==='managed/file/upload/resumable'){
   meta=body;if(body.operation==='part'){
    if(change.uncertain)throw Error('SECRET_SERVER_BODY');
    const bytes=Buffer.from(body.base64,'base64');assert.equal(body.offset,offset);assert.equal(hash(bytes),body.chunkSha256);chunks.push(bytes);offset+=bytes.length;
   }
   Object.assign(data,{uploadResumableVersion:1,uploadKey:body.uploadKey,sha256:body.sha256,sizeBytes:body.sizeBytes,offset,committed:offset===body.sizeBytes,...(offset===body.sizeBytes?{fileId:'retained-test-file'}:{}),...(change.receipt||{})});
  }else if(body.action==='managed/file/read')Object.assign(data,{mime:meta.mime,base64:change.corrupt?Buffer.from('bad').toString('base64'):Buffer.concat(chunks).toString('base64')});
  else throw Error('Unexpected action');return {status:200,data};
 }
 return {request,calls};
}
test('explicit opt-in and exact runtime prevent any unapproved upload',async()=>{
 let calls=0;const request=async()=>{calls++;throw Error('unexpected');};
 for(const patch of [{VS_TEST_NATIVE_UPLOAD_ACCEPTANCE:'0'},{VS_EXPECTED_TEST_RUNTIME:'bad'}])assert.equal((await acceptance({env:{...env,...patch},request})).status,'FAIL');assert.equal(calls,0);
});
test('fixture verifies native chunk, reopened session, stable completion and exact byte readback',async()=>{
 const f=fixture(),r=await acceptance({env,request:f.request});assert.equal(r.status,'PASS');assert.equal(r.resumedFrom,262144);assert.equal(r.sizeBytes,786432);assert.equal(r.networkInterruptionTested,false);assert.equal(r.retained,true);
 assert.deepEqual(f.calls.filter(c=>c.body?.action==='managed/file/upload/resumable').map(c=>c.body.operation),['begin','part','status','begin','status','part','status']);
 assert.equal(f.calls.filter(c=>c.body?.operation==='part').length,2);assert(!JSON.stringify(r).includes('SECRET'));
});
test('wrong runtime, inactive entitlement and missing Script capability fail before mutation',async()=>{
 for(const change of [{runtime:{runtimeCommit:'b'.repeat(40)}},{session:{allowed:false}},{health:{uploadResumableVersion:0}},{health:{scriptBundleVersion:'old'}}]){
  const f=fixture(change),r=await acceptance({env,request:f.request});assert.equal(r.status,'FAIL');assert(!f.calls.some(c=>c.body?.action==='managed/file/upload/resumable'));
 }
});
test('uncertain chunk is not replayed and raw errors or secrets never enter report',async()=>{
 const f=fixture({uncertain:true}),r=await acceptance({env,request:f.request});assert.equal(r.status,'FAIL');assert.equal(f.calls.filter(c=>c.body?.operation==='part').length,1);assert(!JSON.stringify(r).includes('SECRET'));assert.equal(r.uploadKey,'sync3_native_acceptance_fixture');
});
test('foreign-school progress and corrupted readback never pass',async()=>{
 for(const change of [{receipt:{schoolId:'other-school'}},{receipt:{sha256:'0'.repeat(64)}},{corrupt:true}]){
  const f=fixture(change),r=await acceptance({env,request:f.request});assert.equal(r.status,'FAIL');
 }
});

test('HTTP rejection retains only sanitized status, allowlisted code and request ID',async()=>{
 const f=fixture(),request=async(url,body,token)=>body?.operation==='part'?{status:413,data:{success:false,code:'REQUEST_TOO_LARGE',requestId:'12345678-1234-1234-1234-123456789abc',message:'SECRET_RESPONSE',token:'SECRET_TOKEN'}}:f.request(url,body,token);
 const r=await acceptance({env,request});assert.equal(r.status,'FAIL');assert.deepEqual(r.failure,{http:413,code:'REQUEST_TOO_LARGE',requestId:'12345678-1234-1234-1234-123456789abc'});assert(!JSON.stringify(r).includes('SECRET'));
});
