'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createHash}=require('node:crypto');
const {createCloudflareDelivery}=require('../cloudflare-delivery');
const school='vs-'+'a'.repeat(32);
const bytes=Buffer.alloc(1024,7);
const original={uploadKey:'measured-file-operation-0001',sha256:createHash('sha256').update(bytes).digest('hex'),
 sizeBytes:bytes.length,name:'test.pdf',mime:'application/pdf'};
const id='a'.repeat(64),lane='file-'+id;
function fixture(){
 let at=10000;
 const row={id,state:'pending',created:5000,payload:JSON.stringify(original),response:null,manifest:original};
 const rpc=async (s,l,b)=>{
  assert.equal(s,school);assert.equal(l,lane);
  if(b.command==='pending')return row.state==='pending'||row.state==='retry'?[row]:[];
  if(b.command==='claim')return true;
  if(b.command==='readPart')return {offset:b.offset,sizeBytes:512,base64:bytes.subarray(b.offset,b.offset+512).toString('base64'),chunkSha256:createHash('sha256').update(bytes.subarray(b.offset,b.offset+512)).digest('hex')};
  if(b.command==='finish'){row.state=b.values.state;row.response=b.values;return true;}
  if(b.command==='status')return row;
  throw Error('Unexpected command '+b.command);
 };
 const adapter=createCloudflareDelivery({edge:{rpc},now:()=>at});
 return {adapter,row,advance:(ms)=>{at+=ms}};
}
test('Drive progress exposes only Google-acknowledged bytes and stays below 100 until verified',async()=>{
 const f=fixture(),sends=[];
 await f.adapter.drain(school,lane,async request=>{
  sends.push(request.operation);
  return {success:true,schoolId:school,uploadResumableVersion:1,
   uploadKey:original.uploadKey,sha256:original.sha256,sizeBytes:1024,
   offset:request.operation==='begin'?0:512,committed:false};
 });
 const pending=await f.adapter.status(school,lane,id);
 assert.equal(pending.driveState,'pending');
 assert.deepEqual(pending.driveProgress,{version:1,acknowledgedBytes:512,totalBytes:1024});
 assert.equal(pending.driveDurationMillis,undefined);
 assert.deepEqual(sends,['begin','part']);
 f.row.state='retry';
 await f.adapter.drain(school,lane,async request=>{
  return {success:true,schoolId:school,uploadResumableVersion:1,
   uploadKey:original.uploadKey,sha256:original.sha256,sizeBytes:1024,
   offset:1024,committed:true,fileId:'drive-file-1'};
 });
 const done=await f.adapter.status(school,lane,id);
 assert.equal(done.driveState,'verified');
 assert.equal(done.driveProgress,undefined);
 assert.equal(done.driveDurationMillis,5000);
});
test('Cloudflare-only staged size is never mistaken for Google progress',async()=>{
 const f=fixture();
 f.row.manifest={...original,received:1024};
 const status=await f.adapter.status(school,lane,id);
 assert.equal(status.driveProgress,undefined);
 assert.equal(status.driveState,'pending');
});
test('invalid offsets and record queues do not manufacture Drive progress',async()=>{
 const f=fixture();
 f.row.response={driveProgress:{version:1,acknowledgedBytes:1024,totalBytes:1024}};
 assert.equal((await f.adapter.status(school,lane,id)).driveProgress,undefined);
 f.row.response={driveProgress:{version:1,acknowledgedBytes:512,totalBytes:2048}};
 assert.equal((await f.adapter.status(school,lane,id)).driveProgress,undefined);
});
