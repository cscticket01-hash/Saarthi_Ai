'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {storage,A,B}=require('./helpers/managed-storage');
const {fixture}=require('./helpers/managed-school-broker');

const bytes=Buffer.from('Original tiny synthetic pupil portrait bytes, not real user media');
const sha=crypto.createHash('sha256').update(bytes).digest('hex');
const original={uploadKey:'fixed-photo-retry-0001',name:'photo_optimized_school_0001.png',
 mime:'image/png',sizeBytes:bytes.length,sha256:sha};
const signedProbe={action:'managed_upload_receipt',...original};

for(const bundle of [false,true]){
 test('Script '+(bundle?'generated bundle':'adapter')+' verifies timed-out original photo bytes without a write',()=>{
  const f=storage({bundle});
  const before=f.all.size;
  const unknown=f.call(signedProbe);
  assert.equal(unknown.success,true);
  assert.equal(unknown.verified,false);
  assert.equal(unknown.status,'unknown');
  assert.equal(unknown.fileId,undefined);
  assert.equal(f.all.size,before,'read-only probe must not create a file or folder');
  const saved=f.call({action:'managed_upload',
    ...original,base64:bytes.toString('base64')});
  assert.equal(saved.success,true);
  const after=f.all.size;
  const proof=f.call(signedProbe);
  assert.equal(proof.success,true);
  assert.equal(proof.schoolId,A);
  assert.equal(proof.photoReceiptVersion,1);
  assert.equal(proof.verified,true);
  assert.equal(proof.sha256,sha);
  assert.equal(proof.sizeBytes,bytes.length);
  assert.equal(proof.fileId,saved.fileId);
  assert.equal(f.all.size,after,'verification must not create duplicate photo bytes');
  const file=f.all.get(saved.fileId);
  file.setContent('changed file bytes after saved ACK');
  const tampered=f.call(signedProbe);
  assert.equal(tampered.success,false,'wrong actual Drive bytes must never be green');
  assert.equal(f.all.size,after);
 });
 test('Script '+(bundle?'generated bundle':'adapter')+' rejects unrelated original photo keys/digests',()=>{
  const f=storage({bundle});
  const saved=f.call({action:'managed_upload',
    ...original,base64:bytes.toString('base64')});
  assert.equal(saved.success,true);
  for(const data of [{uploadKey:'other-key'},{sha256:'0'.repeat(64)},
    {sizeBytes:bytes.length+1},{name:'other-photo.png'}, {mime:'image/jpeg'}]){
   const response=f.call({...signedProbe,...data});
   assert.notEqual(response.verified,true); // non-match must never be proved
  }
 });
}

test('school-owned Script photo proof is not transferable to another school',()=>{
 const owner=storage(),foreign=storage({schoolId:B});
 assert.equal(owner.call({action:'managed_upload',...original,
   base64:bytes.toString('base64')}).success,true);
 const r=foreign.call(signedProbe);
 assert.equal(r.schoolId,B);
 assert.equal(r.verified,false);
 assert.equal(r.fileId,undefined);
});

test('broker verifies exact signed photo receipt identity and refuses a forged Drive file',async()=>{
 function response(change={}){
  return fixture(async(_url,opts)=>{
   const signed=JSON.parse(opts.body),req=JSON.parse(signed.payload);
   assert.equal(req.action,'managed_upload_receipt');
   return {ok:true,status:200,text:async()=>JSON.stringify({
    success:true,schoolId:A,photoReceiptVersion:1,verified:true,
    fileId:'original-google-file-id',...original,...change})};
  });
 }
 const query={action:'managed/file/receipt',...original};
 const f=response();
 const verified=await f.call(query);
 assert.equal(verified.verified,true);
 assert.equal(verified.fileId,'original-google-file-id');
 assert.equal(verified.fileUrl,
  'https://drive.google.com/file/d/original-google-file-id/view');
 for(const body of [{schoolId:B},{sha256:'bad'},{sizeBytes:-1},{mime:'application/pdf'}]){
  await assert.rejects(f.call({...query,...body}),
   e=>[400,403].includes(e.status));
 }
 for(const bad of [{schoolId:B},{sha256:'0'.repeat(64)},{sizeBytes:2},
  {name:'wrong'},{mime:'image/jpeg'},{verified:true,fileId:'../unsafe'},
  {photoReceiptVersion:0},{verified:false,fileId:'claimed-id'},
  {verified:false,status:'unknown',fileId:undefined, fileUrl:'https://foreign'}]){
  await assert.rejects(response(bad).call(query),
   e=>e.status===502);
 }
});
test('unconfirmed school Drive original stays explicitly unknown, not success',async()=>{
 const f=fixture(async()=>({ok:true,status:200,text:async()=>JSON.stringify({
  success:true,schoolId:A,photoReceiptVersion:1,...original,
  verified:false,status:'unknown'})}));
 const reply=await f.call({action:'managed/file/receipt',...original});
 assert.equal(reply.verified,false);
 assert.equal(reply.status,'unknown');
 assert.equal(reply.fileId,undefined);
});
