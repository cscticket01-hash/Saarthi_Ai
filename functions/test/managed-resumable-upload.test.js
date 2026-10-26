'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {fixture,A,B}=require('./helpers/managed-school-broker');
const bytes=Buffer.alloc(262144,65),sha256=crypto.createHash('sha256').update(bytes).digest('hex');
const body={action:'managed/file/upload/resumable',operation:'part',uploadKey:'retained-key',name:'file.pdf',mime:'application/pdf',sha256,sizeBytes:bytes.length,offset:0,base64:bytes.toString('base64'),chunkSha256:sha256};
function fixtureReply(change={}){return fixture(async(_,options)=>({ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,uploadResumableVersion:1,uploadKey:body.uploadKey,sha256,sizeBytes:bytes.length,offset:bytes.length,committed:true,fileId:'verified-file',url:'PRIVATE_PROVIDER_URL',...change})}));}
test('broker forwards school-bound chunk and returns only verified safe receipt fields',async()=>{
 const f=fixtureReply();const out=await f.call(body);assert.equal(out.fileId,'verified-file');assert(!JSON.stringify(out).includes('PRIVATE_PROVIDER_URL'));
 const sent=JSON.parse(JSON.parse(f.sent[0].opt.body).payload);assert.equal(sent.action,'managed_upload_resumable');assert.equal(sent.uploadKey,body.uploadKey);
 await assert.rejects(f.call({...body,schoolId:B}),e=>e.status===403);assert.equal(f.sent.length,1);
});
test('malformed, oversized and mismatched upload chunks fail before provider access',async()=>{
 for(const change of [{offset:-1},{chunkSha256:'0'.repeat(64)},{sizeBytes:21*1024*1024},{mime:'application/vnd.google-apps.document'},{base64:'$$$'},{operation:'delete'}]){
  const f=fixtureReply();await assert.rejects(f.call({...body,...change}),e=>e.status===400);assert.equal(f.sent.length,0);
 }
});
test('wrong key, digest, size or premature completion never becomes a committed receipt',async()=>{
 for(const change of [{uploadKey:'other'},{sha256:'0'.repeat(64)},{sizeBytes:3},{offset:1},{fileId:undefined},{committed:false}]){
  await assert.rejects(fixtureReply(change).call(body),e=>e.code==='UPLOAD_ACK_UNVERIFIED');
 }
});
