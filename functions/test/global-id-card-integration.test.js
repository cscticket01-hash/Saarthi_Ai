'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createGlobalIdCardLibrary}=require('../global-id-card-library');
const {createGlobalIdCardR2}=require('../global-id-card-r2');
const {syntheticProbePdf,probeRuntime}=require('../global-id-card-analysis');
const {createHash}=require('node:crypto');
const front='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGMwaDgAAAJUAXHIMWMAAAAAAElFTkSuQmCC';
function fixture(useR2=false){
 const docs=new Map(),objects=new Map();
 const snapshot=path=>({exists:docs.has(path),data:()=>structuredClone(docs.get(path))});
 const db={doc:path=>({path,get:async()=>snapshot(path)}),collection:root=>({orderBy:()=>({limit:()=>({get:async()=>({docs:[...docs.keys()].filter(k=>k.startsWith(root+'/')&&k.split('/').length===2).map(snapshot)})})})}),
  runTransaction:async fn=>{const changes=[];
   const result=await fn({get:async ref=>snapshot(ref.path),
    create:(ref,value)=>changes.push(()=>{if(docs.has(ref.path))throw Error('exists');docs.set(ref.path,structuredClone(value));}),
    set:(ref,value,opts)=>changes.push(()=>docs.set(ref.path,structuredClone(opts?.merge?{...docs.get(ref.path),...value}:value)))});
   changes.forEach(apply=>apply());return result;
  }};
 const firebaseBucket={getMetadata:async()=>[{iamConfiguration:{uniformBucketLevelAccess:{enabled:true},publicAccessPrevention:'enforced'}}],
  iam:{getPolicy:async()=>[{bindings:[]}]},
  file:path=>({save:async bytes=>{if(objects.has(path))throw Object.assign(Error('exists'),{code:412});objects.set(path,Buffer.from(bytes));},
   download:async()=>{if(!objects.has(path))throw Error('missing object');return [Buffer.from(objects.get(path))];}})};
 const bucket=useR2?createGlobalIdCardR2({
  db,accountId:'1'.repeat(32),bucketName:'saarthi-id-library-staging',
  request:async(url,options)=>{
   const key=new URL(url).pathname.split('/').slice(2).join('/');
   if(options.method==='HEAD')return new Response(null,{status:200});
   if(options.method==='GET')return objects.has(key)?new Response(objects.get(key)):new Response(null,{status:404});
   assert.equal(options.method,'PUT');
   assert.equal(options.headers['If-None-Match'],'*');
   if(objects.has(key))return new Response(null,{status:412});
   objects.set(key,Buffer.from(options.body));
   return new Response(null,{status:200});
  },
 }):firebaseBucket;
 const clock=1700000000000,actor={uid:'synthetic-developer'},member={uid:'synthetic-account',schoolId:'vs-'+'1'.repeat(32),entitlement:{expiresAt:clock+3600000}};
 const library=createGlobalIdCardLibrary({db,bucket,policyReviewed:true,now:()=>clock,analyzer:null,imageAnalyzer:null,rasterizer:null});
 return {library,docs,objects,member,actor,db,bucket,clock};
}
function pkg(id){return {manifest:{id,version:1,canvasWidth:300,canvasHeight:300,printWidthMm:54,printHeightMm:54,
  regions:[{key:'name',side:'front',kind:'text',x:10,y:10,width:180,height:20},{key:'qr',side:'front',kind:'qr',x:10,y:100,width:80,height:80}]},backgrounds:{front}};}
for(const useR2 of [false,true])test('private upload, publish, refresh, revision and rollback (mock '+(useR2?'R2':'Firebase Storage')+')',async()=>{
 const {library,docs,objects,actor,member}=fixture(useR2);
 const source=syntheticProbePdf(),pdfBase64=source.toString('base64');
 async function upload(kind,previousId){
  const response=await library.developerAction('upload',{name:'Synthetic design',kind,syntheticSampleConfirmed:true,pdfBase64,...(previousId?{previousId}:{})},actor);
  assert.equal(response.template.state,'draft');return response.template;
 }
 function simulateAnalysis(id){
  // Separate parser tests cover geometry detection. Here the Firebase and
  // runtime adapters are intentionally mocked, not a production test.
  const row=docs.get('global_id_card_library/'+id);
  row.mappingState='review_required';row.analysis={pages:[{side:'front',printWidthMm:54,printHeightMm:54}]};return row;
 }
 async function publish(id){
  const row=simulateAnalysis(id),packageData=pkg(id);
  await assert.rejects(library.developerAction('publish',{id,sourceSha256:row.sourceSha256,package:packageData,reviewConfirmed:false},actor));
  const wrong=pkg(id);wrong.manifest.printWidthMm=55;wrong.manifest.printHeightMm=55;
  await assert.rejects(library.developerAction('publish',{id,sourceSha256:row.sourceSha256,package:wrong,reviewConfirmed:true},actor));
  return library.developerAction('publish',{id,sourceSha256:row.sourceSha256,package:packageData,reviewConfirmed:true},actor);
 }
 for(const kind of ['studentId','teacherId','otherStaffId']){
  const first=await upload(kind);
  assert.equal((await library.schoolAction('list',{},member)).templates.some(t=>t.id===first.id),false);
  await assert.rejects(library.schoolAction('package',{id:first.id,version:1},member));
  await publish(first.id);
  const list=await library.schoolAction('list',{},member),item=list.templates.find(t=>t.id===first.id);
  assert.equal(item.unlocked,true);assert.equal(item.kind,kind);assert.equal('sourcePath' in item,false);
  const result=await library.schoolAction('package',{id:first.id,version:1},member);
  const bytes=Buffer.from(result.packageBase64,'base64');
  assert.equal(createHash('sha256').update(bytes).digest('hex'),item.packageSha256);
  assert.equal(JSON.parse(bytes).manifest.id,first.id);
  assert.equal(bytes.includes(source),false);
  const second=await upload(kind,first.id);assert.equal(second.version,2);await publish(second.id);
  assert.equal((await library.schoolAction('list',{},member)).templates.find(t=>t.id===second.id).isCurrent,true);
  await library.developerAction('make-current',{id:first.id},actor);
  assert.equal((await library.schoolAction('list',{},member)).templates.find(t=>t.id===first.id).isCurrent,true);
  await library.developerAction('archive',{id:first.id},actor);
  await assert.rejects(library.schoolAction('package',{id:first.id,version:1},member));
  await library.developerAction('make-current',{id:first.id},actor);
  const row=docs.get('global_id_card_library/'+first.id);
  objects.set(row.packagePath,Buffer.from('corrupted'));
  await assert.rejects(library.schoolAction('package',{id:first.id,version:1},member));
 }
});
test('unconfigured runtime probe fails closed without invoking tools',async()=>{
 assert.deepEqual(await probeRuntime(null,null,null),{text:false,imageGeometry:false,raster:false});
 const pdf=syntheticProbePdf();assert.match(pdf.toString(),/^%PDF-1\.4/);
 assert.match(pdf.toString(),/%%EOF\n$/);
});
test('unreviewed Firebase policy blocks school refresh and developer upload',async()=>{
 const {db,bucket,actor,member,clock}=fixture();
 const library=createGlobalIdCardLibrary({db,bucket,now:()=>clock,policyReviewed:false,analyzer:null});
 await assert.rejects(library.schoolAction('list',{},member));
 await assert.rejects(library.developerAction('upload',{name:'Synthetic',kind:'studentId',syntheticSampleConfirmed:true,pdfBase64:syntheticProbePdf().toString('base64')},actor));
});

test('R2 enforces the 2 GB reservation before writing and does not double-count retries',async()=>{
 const {bucket,docs,objects}=fixture(true);
 const scope='global_id_card_storage/'+'1'.repeat(32);
 docs.set(scope,{reservedBytes:1_999_999_997});
 const options={metadata:{contentType:'application/pdf'}};
 const key='global-id-card-library/private/gid-'+'a'.repeat(32)+'/source.pdf';
 await bucket.file(key).save(Buffer.from('PDF'),options);
 await assert.rejects(bucket.file(key).save(Buffer.from('PDF'),options),{code:412});
 assert.equal(docs.get(scope).reservedBytes,2_000_000_000);
 const another=key.replace('a'.repeat(32),'b'.repeat(32));
 await assert.rejects(bucket.file(another).save(Buffer.from('PDF'),options),{status:507});
 assert.equal(objects.size,1);
});

test('category preflight and wrong-category upload create no durable data; correction retains the source',async()=>{
 const {db,bucket,objects,docs,actor,clock}=fixture(true);
 const analysis={category:{kind:'studentId',evidence:'explicit_card_heading'},pages:[{side:'front',candidates:[],imageCandidates:[],labelSlots:[]}]};
 const library=createGlobalIdCardLibrary({db,bucket,policyReviewed:true,now:()=>clock,analyzer:'test',analyzeSource:async()=>analysis});
 const payload={name:'Synthetic student card',kind:'teacherId',syntheticSampleConfirmed:true,pdfBase64:syntheticProbePdf().toString('base64')};
 const p=await library.developerAction('preflight',payload,actor);
 assert.equal(p.category.kind,'studentId');assert.equal(objects.size,0);assert.equal(docs.size,0);
 await assert.rejects(library.developerAction('upload',payload,actor),{status:400});
 assert.equal(objects.size,0);assert.equal(docs.size,0);
 const {template}=await library.developerAction('upload',{...payload,kind:'studentId'},actor);
 const row=docs.get('global_id_card_library/'+template.id);
 const before=row.sourceSha256;
 // Emulate a legacy wrongly classified draft only.
 row.kind='teacherId';
 await library.developerAction('change-category',{id:template.id,kind:'studentId'},actor);
 assert.equal(docs.get('global_id_card_library/'+template.id).kind,'studentId');
 assert.equal(docs.get('global_id_card_library/'+template.id).sourceSha256,before);
 assert.equal(objects.size,1);
});
test('unknown category needs explicit confirmation; delete hides only never-published drafts',async()=>{
 const {db,bucket,docs,objects,actor,member,clock}=fixture(true);
 const library=createGlobalIdCardLibrary({db,bucket,policyReviewed:true,now:()=>clock,analyzer:'test',analyzeSource:async()=>({category:{kind:null,evidence:'unknown'},pages:[]})});
 const payload={name:'Synthetic',kind:'teacherId',syntheticSampleConfirmed:true,pdfBase64:syntheticProbePdf().toString('base64')};
 await assert.rejects(library.developerAction('upload',payload,actor),{status:400});
 const {template}=await library.developerAction('upload',{...payload,categoryConfirmed:true},actor);
 await assert.rejects(library.developerAction('delete',{id:template.id},actor),{status:400});
 await library.developerAction('delete',{id:template.id,confirmed:true},actor);
 assert.equal(docs.get('global_id_card_library/'+template.id).state,'deleted');
 assert.equal(objects.size,1);
 assert.equal((await library.developerAction('list',{},actor)).templates.length,0);
 assert.equal((await library.schoolAction('list',{},member)).templates.length,0);
 await assert.rejects(library.developerAction('restore',{id:template.id},actor),{status:404});
 const {template:published}=await library.developerAction('upload',{...payload,categoryConfirmed:true},actor);
 docs.get('global_id_card_library/'+published.id).state='published';
 docs.get('global_id_card_library/'+published.id).packageVerified=true;
 await assert.rejects(library.developerAction('delete',{id:published.id,confirmed:true},actor),{status:409});
});

test('developer gallery preview is read-only and unavailable to schools',async()=>{
 const {db,bucket,docs,objects,actor,member,clock}=fixture(true);
 const library=createGlobalIdCardLibrary({db,bucket,policyReviewed:true,now:()=>clock,analyzer:null,rasterizer:'test',analyzeSource:async()=>({pages:[{side:'front',canvasWidth:300,canvasHeight:300,printWidthMm:54,printHeightMm:54,candidates:[{key:'name'}]}]}),renderSource:async(bytes,pages,executable,dpi)=>{
  assert.ok([150,600].includes(dpi));return {front};
 }});
 const {template}=await library.developerAction('upload',{name:'Synthetic preview',kind:'studentId',syntheticSampleConfirmed:true,pdfBase64:syntheticProbePdf().toString('base64')},actor);
 const row=docs.get('global_id_card_library/'+template.id);
 row.analysis={pages:[{side:'front',canvasWidth:300,canvasHeight:300,printWidthMm:54,printHeightMm:54}]};
 row.mappingState='review_required';
 const before=structuredClone(row);
 const preview=await library.developerAction('preview',{id:template.id},actor);
 assert.equal(preview.mode,'private_reference');assert.equal(preview.rasters.front,front);assert.equal(preview.analysis,undefined);
 const tracked=await library.developerAction('preview',{id:template.id,trackMapping:true},actor);
 assert.equal(tracked.analysis.pages[0].candidates[0].key,'name');assert.equal(tracked.rasters.front,front);
 assert.deepEqual(docs.get('global_id_card_library/'+template.id),before);
 assert.equal(objects.size,1);
 await assert.rejects(library.schoolAction('preview',{id:template.id},member),{status:400});
 await library.developerAction('publish',{id:template.id,sourceSha256:row.sourceSha256,package:pkg(template.id),reviewConfirmed:true},actor);
 const published=await library.developerAction('preview',{id:template.id},actor);
 assert.equal(published.mode,'verified');assert.equal(published.rasters.front,front);assert.equal(published.manifest.id,template.id);
});
