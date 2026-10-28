'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {fixture,A,B}=require('./helpers/managed-school-broker');
const bytes=Buffer.alloc(700000,73),digest=crypto.createHash('sha256').update(bytes).digest('hex');
const request={action:'managed/file/download/part',schoolId:A,fileId:'owned_file',expectedSha256:digest,expectedVersion:'immutable-version-1',offset:0,length:262144};
function setup(){let reads=0;const f=fixture(async(url,opt)=>{reads++;const outer=JSON.parse(opt.body);return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:outer.schoolId,binaryDownloadVersion:1,fileId:'owned_file',sha256:digest,version:'immutable-version-1',sizeBytes:bytes.length,base64:bytes.toString('base64')})};});return {...f,reads:()=>reads};}
test('version-bound chunks resume at exact offsets; cached full provider bytes are not fetched repeatedly',async()=>{
 const f=setup();const chunks=[];for(let offset=0;offset<bytes.length;offset+=262144){const result=await f.call({...request,offset});const part=Buffer.from(result.base64,'base64');assert.equal(result.offset,offset);assert.equal(result.nextOffset,offset+part.length);assert.equal(result.chunkSha256,crypto.createHash('sha256').update(part).digest('hex'));chunks.push(part);}
 assert.deepEqual(Buffer.concat(chunks),bytes);assert.equal(f.reads(),1);
});
test('cache cannot cross school identity, bypass membership or accept invalid range bounds',async()=>{
 const f=setup();await f.call(request);
 await assert.rejects(f.call({...request,schoolId:B}),e=>e.status===403);
 await f.call({...request,schoolId:B},'B');assert.equal(f.reads(),2);
 for(const mutation of [{offset:-1},{length:600000},{offset:bytes.length},{expectedSha256:'bad'}])await assert.rejects(f.call({...request,...mutation}),e=>e.status===400);
});
test('failed full hash never emits a chunk receipt',async()=>{
 const f=setup();await assert.rejects(f.call({...request,expectedSha256:'a'.repeat(64)}),e=>e.status===502&&e.code==='BINARY_DOWNLOAD_UNVERIFIED');
});
