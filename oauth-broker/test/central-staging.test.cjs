'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createServer}=require('../server.cjs');
const {createHandler}=require('../../staging-school-cloud/server.cjs');
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
