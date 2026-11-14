'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createCloudflareSync}=require('../cloudflare-sync');
const school='vs-'+'a'.repeat(32),foreign='vs-'+'b'.repeat(32);
function edge({responseSchool,command='enqueue',code='R2_CAPACITY_EXCEEDED',status=507}={}){
 const sync=createCloudflareSync({url:'https://edge.example/',key:'x'.repeat(32),schools:[school],
  fetchImpl:async(_,options)=>new Response(JSON.stringify({
    success:false,...(responseSchool?{schoolId:responseSchool}:{}),code,
    message:'Cloudflare 8 GB school data capacity reached; local work retained.'
   }),{status})});
 return sync.rpc(school,'records',{command,id:'a'.repeat(64)});
}
test('genuine private R2 507 preserves original operation without pretending to ACK',async()=>{
 await assert.rejects(edge(),e=>e.status===507&&e.code==='R2_CAPACITY_EXCEEDED'&&
   e.publicMessage===true&&/8 GB/.test(e.message));
});
test('foreign or unrelated R2 507 cannot forge same-school capacity state',async()=>{
 for(const options of [
  {responseSchool:foreign},{status:409},{code:'ANOTHER_ERROR'},
 ]){
  await assert.rejects(edge(options),e=>e.status===(options.status===409?409:503)&&e.code==='CLOUDFLARE_SYNC_UNAVAILABLE');
 }
});
