'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {fixture,A,B}=require('./helpers/managed-school-broker');
const {storage}=require('./helpers/managed-storage');
const bytes=Buffer.from('isolated synthetic PDF bytes'),digest=crypto.createHash('sha256').update(bytes).digest('hex');
const item={fileId:'file1',name:'synthetic.pdf',mime:'application/pdf',sizeBytes:bytes.length,sha256:digest,version:'100-'+bytes.length+'-'+digest,verification:'bytes_hashed'};
const inventory={binaryInventoryVersion:1,inventoryFingerprint:digest,inventoryScope:'application_media_folders',observedAt:Date.now(),items:[item],nextCursor:null,partial:false,scanLimited:false,coverageComplete:true,hashedBytes:bytes.length};
function response(data){return async(_,options)=>({ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:JSON.parse(options.body).schoolId,...data})});}
test('binary inventory is authenticated school-scoped and does not upload records',async()=>{
 const f=fixture(response(inventory));const result=await f.call({action:'managed/file/inventory'});
 assert.equal(result.items[0].sha256,digest);assert.equal(result.coverageComplete,true);assert.equal(f.sent.length,1);
 assert.equal(JSON.parse(JSON.parse(f.sent[0].opt.body).payload).action,'managed_binary_inventory');
 await assert.rejects(f.call({action:'managed/file/inventory',schoolId:B}),e=>e.status===403);
 await assert.rejects(f.call({action:'managed/file/inventory',cursor:'../foreign'}),e=>e.status===400);
});
test('old or malformed Script inventory cannot be reported as a complete binary download',async()=>{
 for(const data of [{},{...inventory,items:[{...item,sha256:'bad'}]},{...inventory,items:[item,item]},{...inventory,items:[{...item,verification:'unavailable'}]}]){
  await assert.rejects(fixture(response(data)).call({action:'managed/file/inventory'}),e=>e.status===502);
 }
});
test('valid binary bytes are checked in broker, not accepted from metadata alone',async()=>{
 const data={...item,binaryDownloadVersion:1,base64:bytes.toString('base64')};const f=fixture(response(data));
 const result=await f.call({action:'managed/file/download',fileId:item.fileId,expectedSha256:digest,expectedVersion:item.version});assert.equal(Buffer.from(result.base64,'base64').toString(),bytes.toString());
 for(const changed of [{base64:Buffer.from('corrupt').toString('base64')},{base64:undefined},{version:'stale'},{fileId:'foreign'}]){
  await assert.rejects(fixture(response({...data,...changed})).call({action:'managed/file/download',fileId:item.fileId,expectedSha256:digest,expectedVersion:item.version}),e=>e.status===502);
 }
 await assert.rejects(f.call({action:'managed/file/download',schoolId:B,fileId:item.fileId,expectedSha256:digest,expectedVersion:item.version}),e=>e.status===403);
});
function media(f,name='photo.jpg',text='synthetic photo'){
 const folders=f.roots[A].getFoldersByName('Student_Photos');const folder=folders.hasNext()?folders.next():f.roots[A].createFolder('Student_Photos');
 const binary=folder.createFile(name,text,'image/jpeg');binary.getLastUpdated=()=>new Date(1000);return binary;
}
test('signed Script inventory hashes real bytes; download verifies exact immutable generation',()=>{
 const f=storage(),file=media(f);const list=f.call({action:'managed_binary_inventory'});assert.equal(list.success,true);assert.equal(list.items.length,1);assert.equal(list.coverageComplete,true);
 const expected=crypto.createHash('sha256').update(file.text).digest('hex');assert.equal(list.items[0].sha256,expected);
 const got=f.call({action:'managed_binary_download',fileId:file.id,expectedSha256:expected,expectedVersion:list.items[0].version});assert.equal(got.success,true);assert.equal(Buffer.from(got.base64,'base64').toString(),file.text);
 file.setContent('newer photo');const stale=f.call({action:'managed_binary_download',fileId:file.id,expectedSha256:expected,expectedVersion:list.items[0].version});assert.equal(stale.success,false);assert.equal(file.text,'newer photo');
});
test('binary inventory paginates with five actual hashes and no fabricated completion',()=>{
 const f=storage();for(let i=0;i<8;i++)media(f,'photo'+i+'.jpg','photo'+i);
 const first=f.call({action:'managed_binary_inventory'});assert.equal(first.items.length,5);assert.equal(first.partial,true);assert.equal(first.coverageComplete,false);
 const last=f.call({action:'managed_binary_inventory',cursor:first.nextCursor});assert.equal(last.items.length,3);assert.equal(last.coverageComplete,true);
 assert.equal(new Set([...first.items,...last.items].map(x=>x.fileId)).size,8);
});
test('foreign, archive and native Google files cannot be downloaded through binary route',()=>{
 const f=storage();const foreign=f.roots[B].createFolder('Student_Photos').createFile('foreign','private','image/jpeg');foreign.getLastUpdated=()=>new Date(1000);
 const backup=f.roots[A].createFolder('Backups').createFile('private.json','backup','application/json');backup.getLastUpdated=()=>new Date(1000);
 const native=f.roots[A].createFolder('Other_Files').createFile('sheet','','application/vnd.google-apps.spreadsheet');native.getLastUpdated=()=>new Date(1000);
 for(const file of [foreign,backup,native])assert.equal(f.call({action:'managed_binary_download',fileId:file.id,expectedSha256:digest,expectedVersion:item.version}).success,false);
 assert.equal(f.call({action:'managed_binary_inventory'}).items.length,0);assert.equal(foreign.isTrashed(),false);assert.equal(backup.isTrashed(),false);
});
test('oversized cloud original is retained and explicitly partial without downloading blob',()=>{
 const f=storage(),file=media(f);file.getSize=()=>21*1024*1024;file.getBlob=()=>{throw Error('oversized blob must not be loaded');};
 const result=f.call({action:'managed_binary_inventory'});assert.equal(result.success,true);assert.equal(result.partial,true);assert.equal(result.coverageComplete,false);assert.equal(result.items[0].verification,'unavailable');assert.equal(file.isTrashed(),false);
});
test('concurrently changed bytes are rejected without altering original',()=>{
 const f=storage(),file=media(f);let reads=0;file.getLastUpdated=()=>new Date(++reads===1?1000:2000);
 assert.equal(f.call({action:'managed_binary_inventory'}).success,false);assert.equal(file.text,'synthetic photo');
});
