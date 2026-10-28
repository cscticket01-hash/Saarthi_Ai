'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createServer}=require('../server.cjs');
const {createHandler,fromEnvironment}=require('../../staging-school-cloud/server.cjs');
async function withServer(handler,fn){const server=createServer({schoolCloud:handler});await new Promise(r=>server.listen(0,'127.0.0.1',r));try{await fn('http://127.0.0.1:'+server.address().port);}finally{server.closeAllConnections();await new Promise(r=>server.close(r));}}
test('central staging fails closed when disabled and validates real backend health',async()=>{
 await withServer(undefined,async base=>assert.equal((await fetch(base+'/school-cloud')).status,503));
 let healthy=false,calls=0;
 const handler=createHandler({handle:async()=>({success:true}),health:async()=>{calls++;if(!healthy)throw Error('private credential text');}});
 await withServer(handler,async base=>{let r=await fetch(base+'/school-cloud/healthz');assert.equal(r.status,503);assert.equal((await r.text()).includes('private'),false);healthy=true;r=await fetch(base+'/school-cloud/healthz');assert.equal(r.status,200);assert.equal((await r.json()).projectId,'saarthi-ai-df12b');await fetch(base+'/school-cloud/healthz');assert.equal(calls,2);});
});
test('central staging bounds bodies and rejects unapproved browser origins and raw upstream errors',async()=>{
 let seen;
 const handler=createHandler({health:async()=>{},handle:async req=>{seen=req;throw Error('private secret');}});
 await withServer(handler,async base=>{
  const post=body=>fetch(base+'/school-cloud',{method:'POST',headers:{'Content-Type':'application/json','Authorization':'Bearer test'},body});
  assert.equal((await post('{')).status,400);
  assert.equal((await post(' '.repeat(256*1024+1))).status,413);
  const denied=await fetch(base+'/school-cloud',{method:'POST',headers:{Origin:'https://foreign.example','Content-Type':'application/json'},body:'{}'});assert.equal(denied.status,403);
  const r=await post('{"action":"status"}');assert.equal(r.status,503);assert.equal((await r.text()).includes('private'),false);assert.equal(seen.headers.authorization,'Bearer test');assert.deepEqual(seen.body,{action:'status'});
 });
});
test('future central web origin must be explicitly allowlisted and preflight cannot invoke data operations',async()=>{
 let calls=0;
 const handler=createHandler({health:async()=>{},allowedOrigins:['https://school.example'],handle:async()=>{calls++;return{success:true};}});
 await withServer(handler,async base=>{const r=await fetch(base+'/school-cloud',{method:'OPTIONS',headers:{Origin:'https://school.example'}});assert.equal(r.status,204);assert.equal(r.headers.get('access-control-allow-origin'),'https://school.example');assert.equal(calls,0);});
});
test('allowlisted browser can preflight exact device proof headers without invoking records',async()=>{
 let calls=0;const handler=createHandler({health:async()=>{},handle:async()=>{calls++;return {};},allowedOrigins:['https://school.example']});
 await withServer(handler,async base=>{
  const requested='authorization,content-type,x-vidya-device-id,x-vidya-device-credential';
  const headers={Origin:'https://school.example','Access-Control-Request-Method':'POST','Access-Control-Request-Headers':requested};
  const r=await fetch(base+'/school-cloud',{method:'OPTIONS',headers});
  assert.equal(r.status,204);const allowed=r.headers.get('access-control-allow-headers').toLowerCase().split(',');
  for(const key of requested.split(','))assert.ok(allowed.includes(key));
  assert.ok(!allowed.includes('*'));assert.ok(!allowed.includes('x-untrusted-header'));assert.equal(calls,0);
  const denied=await fetch(base+'/school-cloud',{method:'OPTIONS',headers:{...headers,Origin:'https://foreign.example'}});
  assert.equal(denied.status,403);assert.equal(denied.headers.get('access-control-allow-origin'),null);assert.equal(calls,0);
 });
});
test('real installed modular Admin SDK initializes staging with a disposable test key and rejects another project',async()=>{
 const {generateKeyPairSync}=require('node:crypto');
 const {privateKey}=generateKeyPairSync('rsa',{modulusLength:2048,privateKeyEncoding:{type:'pkcs8',format:'pem'},publicKeyEncoding:{type:'spki',format:'pem'}});
 // SDK initialization test must never start a cloud-connected queue worker.
 const env={SAARTHI_ATTENDANCE_QUEUE_ENABLED:'false',SAARTHI_GOOGLE_DESKTOP_CLIENT_ID:'test.apps.googleusercontent.com',SAARTHI_FIREBASE_ADMIN_JSON:JSON.stringify({project_id:'saarthi-ai-df12b',client_email:'test-only@saarthi-ai-df12b.iam.gserviceaccount.com',private_key:privateKey})};
 assert.throws(()=>fromEnvironment({...env,SAARTHI_FIREBASE_ADMIN_JSON:'{"project_id":"foreign-project"}'}),/Invalid central/);
 assert.equal(typeof fromEnvironment(env),'function');
 const {getApp,deleteApp}=require('firebase-admin/app');
 await deleteApp(getApp('central-render-staging'));
});

test('Central request traces expose only allowlisted actions, status and generated request IDs',async()=>{
 const logs=[];
 const handler=createHandler({health:async()=>{},logger:entry=>logs.push(entry),handle:async()=>{const e=Error('private-token-value');e.status=403;throw e;}});
 await withServer(handler,async base=>{
  const r=await fetch(base+'/school-cloud',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer secret-token'},
    body:JSON.stringify({action:'migration/import',sourceAdminToken:'secret-admin',googleAccessToken:'secret-google',schoolId:'private-school'})});
  assert.equal(r.status,403);const body=await r.json();assert(!JSON.stringify(body).includes('private-token'));
  assert.match(body.requestId,/^[a-f0-9-]{36}$/);assert.equal(r.headers.get('x-saarthi-request-id'),body.requestId);
  assert.deepEqual(logs.filter(e=>e.event==='central_request'),[{event:'central_request',endpoint:'/school-cloud',action:'migration/import',status:403,requestId:body.requestId}]);
  assert.deepEqual(logs.find(e=>e.event==='central_failure'),{event:'central_failure',action:'migration/import',status:403,code:'UNKNOWN',requestId:body.requestId});
  await fetch(base+'/school-cloud',{method:'POST',headers:{'Content-Type':'application/json'},body:'{"action":"secret-token"}'});
  assert.equal(logs.filter(e=>e.event==='central_request')[1].action,'UNKNOWN');assert(!JSON.stringify(logs).includes('secret'));
 });
});

test('isolated health exposes only a valid public deployed commit; production and malformed values stay hidden',async()=>{
 for(const [testSchoolId,runtimeCommit,expected] of [['vs-'+ 'a'.repeat(32),'b'.repeat(40),'b'.repeat(40)],[null,'b'.repeat(40),undefined],['vs-'+ 'a'.repeat(32),'private unexpected data',undefined]]) {
  await withServer(createHandler({handle:async()=>({}),health:async()=>{},testSchoolId,runtimeCommit}),async base=>{
   const r=await fetch(base+'/school-cloud/healthz');assert.equal(r.status,200);assert.equal((await r.json()).runtimeCommit,expected);
  });
 }
});

test('HTTP ingress admits actual native 256/512 KiB chunks while preserving action-specific bounds',async()=>{
 const {createHash}=require('node:crypto');const received=[];
 const handler=createHandler({health:async()=>{},logger:()=>{},handle:async req=>{received.push(req.body);return {success:true};}});
 await withServer(handler,async base=>{
  const post=(body,authorized=true)=>fetch(base+'/school-cloud',{method:'POST',headers:{'Content-Type':'application/json',...(authorized?{Authorization:'Bearer fixture'}:{})},body:JSON.stringify(body)});
  function part(size){const bytes=Buffer.alloc(size,65);return {action:'managed/file/upload/resumable',operation:'part',schoolId:'vs-'+ 'a'.repeat(32),uploadKey:'durable-native-key',name:'native.bin',mime:'application/octet-stream',sha256:'a'.repeat(64),sizeBytes:786432,offset:0,chunkSha256:createHash('sha256').update(bytes).digest('hex'),base64:bytes.toString('base64')};}
  for(const size of [256*1024,512*1024]){
   const body=part(size);assert(Buffer.byteLength(JSON.stringify(body))>256*1024);const r=await post(body);assert.equal(r.status,200);assert.equal(received.at(-1).base64,body.base64);
  }
  const count=received.length;
  for(const body of [{...part(512*1024),base64:'A'.repeat(700004)}, {...part(512*1024),padding:'x'.repeat(8192)}, {...part(256*1024),operation:'begin'}, {...part(256*1024),action:'managed/profile'}]){
   const r=await post(body);assert.equal(r.status,413);const safe=await r.json();assert.equal(safe.code,'REQUEST_TOO_LARGE');assert.match(safe.requestId,/^[a-f0-9-]{36}$/);
  }
  assert.equal((await post(part(256*1024),false)).status,413);assert.equal(received.length,count);
  // The pre-existing full-upload route retains its larger bound.
  assert.equal((await post({action:'managed/file/upload',base64:'A'.repeat(800000)})).status,200);
 });
});
