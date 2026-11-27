'use strict';
const {execFile}=require('node:child_process');
const {promisify}=require('node:util');
const {mkdtemp,writeFile,readFile,stat,readdir,rm}=require('node:fs/promises');
const {tmpdir}=require('node:os');
const {join}=require('node:path');
const run=promisify(execFile);
const aliases={name:'name','student name':'name','teacher name':'name','father name':'parentName','father/guardian':'parentName','father/guardain':'parentName','father/guardian name':'parentName','father':'parentName','parent name':'parentName','guardian name':'parentName','dob':'dob','d.o.b':'dob','date of birth':'dob',class:'class','roll no':'rollNo','roll number':'rollNo','ph no':'contact',phone:'contact','phone no':'contact','contact no':'contact',contact:'contact',address:'address',pin:'pinCode','pin code':'pinCode',district:'district',dist:'district',state:'state',country:'country','school name':'schoolName',designation:'designation',subject:'subject'};
// Optional fictional placeholder phrases are useful for label-free fields in
// a filled reference. Only exact reserved phrases are recognized.
const sampleMarkers=new Map([
 ['sample school name','schoolName'],['sample school address','schoolAddress'],
 ['sample student name','name'],['sample teacher name','name'],['sample staff name','name'],
 ['sample guardian name','parentName'],['sample designation','designation'],['sample subject','subject'],
 ['sample town/village','address'],['sample district','district'],['sample state','state'],
 ['sample country','country'],['sample employee id','employeeId']
]);
const decode=s=>s.replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&quot;/g,'"').replace(/&apos;/g,"'");
function parseCandidates(xml){
 const pages=[...xml.matchAll(/<page\s+width="([\d.]+)"\s+height="([\d.]+)"[^>]*>([\s\S]*?)<\/page>/g)];
 if(pages.length<1||pages.length>2)throw Object.assign(Error('Only one or two ID card pages are supported'),{status:400,publicMessage:true});
 return pages.map((page,n)=>{
  const width=Number(page[1]),height=Number(page[2]);
  if(!Number.isFinite(width)||!Number.isFinite(height)||width<=0||height<=0||width*25.4/72>150||height*25.4/72>150)throw Object.assign(Error('PDF page is not a supported ID card size'),{status:400,publicMessage:true});
  const candidates=[];
  // Canva frequently stores labels and values as separate text objects.
  // Group by vertical geometry rather than the PDF block boundaries.
  const words=[...page[3].matchAll(/<word\s+xMin="([\d.]+)"\s+yMin="([\d.]+)"\s+xMax="([\d.]+)"\s+yMax="([\d.]+)"[^>]*>([^<]*)<\/word>/g)]
    .slice(0,2048).map(w=>({x:+w[1],y:+w[2],right:+w[3],bottom:+w[4],text:decode(w[5]).trim()}))
    .filter(w=>w.text&&w.x>=0&&w.y>=0&&w.right>w.x&&w.bottom>w.y&&w.right<=width&&w.bottom<=height);
  words.sort((a,b)=>(a.y+a.bottom)-(b.y+b.bottom)||a.x-b.x);
  const rows=[];
  for(const word of words){
   const overlap=r=>Math.min(r.bottom,word.bottom)-Math.max(r.y,word.y);
   const row=rows.find(r=>overlap(r)>=.6*Math.min(r.bottom-r.y,word.bottom-word.y)&&
    Math.abs((r.y+r.bottom-word.y-word.bottom)/2)<=.45*Math.max(r.bottom-r.y,word.bottom-word.y));
   if(row)row.words.push(word);
   else rows.push({y:word.y,bottom:word.bottom,words:[word]});
  }
  for(const row of rows){
   const line=row.words.sort((a,b)=>a.x-b.x),anchors=[];
   const reserved=sampleMarkers.get(line.map(w=>w.text).join(' ').trim().toLowerCase());
   if(reserved){
    const x=Math.min(...line.map(v=>v.x)),y=Math.min(...line.map(v=>v.y)),right=Math.max(...line.map(v=>v.right)),bottom=Math.max(...line.map(v=>v.bottom));
    candidates.push({key:reserved,side:n?'back':'front',x,y,width:right-x,height:bottom-y,reviewRequired:true,evidence:'reserved_sample_phrase'});
    continue;
   }
   for(let i=0;i<line.length;i++){
    if(!/[:：]$/.test(line[i].text))continue;
    // A combined label/value in the same word has no separable bbox.
    for(let j=Math.max(0,i-4);j<=i;j++){
     const label=line.slice(j,i+1).map(w=>w.text).join(' ').replace(/[:：]\s*$/,'').trim().toLowerCase();
     if(!Object.hasOwn(aliases,label))continue;
     anchors.push({start:j,end:i,key:aliases[label]});break;
    }
   }
   for(let i=0;i<anchors.length;i++){
    const a=anchors[i],value=line.slice(a.end+1,anchors[i+1]?.start??line.length);
    if(!value.length||value.some(w=>w.text.endsWith(':')))continue;
    const x=Math.min(...value.map(v=>v.x)),y=Math.min(...value.map(v=>v.y)),right=Math.max(...value.map(v=>v.right)),bottom=Math.max(...value.map(v=>v.bottom));
    if(x<0||y<0||right>width||bottom>height||right<=x||bottom<=y)continue;
    candidates.push({key:a.key,side:n?'back':'front',x,y,width:right-x,height:bottom-y,reviewRequired:true});
   }
  }
  return {side:n?'back':'front',canvasWidth:width,canvasHeight:height,printWidthMm:width*25.4/72,printHeightMm:height*25.4/72,candidates:candidates.slice(0,128)};
 });
}
// Poppler XML geometry is only a review candidate. Embedded images can be
// decorative artwork, photos, logos, signatures or QR; never infer their role
// from size alone or return their original bytes to the school.
function parseImageCandidates(xml,pages){
 const blocks=[...xml.matchAll(/<page\b([^>]*)>([\s\S]*?)<\/page>/g)];
 if(blocks.length!==pages.length)throw Error('PDF image geometry page count differs');
 const attrs=s=>Object.fromEntries([...s.matchAll(/([A-Za-z]+)="([^"]*)"/g)].map(x=>[x[1],x[2]]));
 return blocks.map((block,index)=>{
  const page=pages[index],a=attrs(block[1]),w=Number(a.width),h=Number(a.height);
  if(!(w>0&&h>0)||Math.abs(w/h-page.canvasWidth/page.canvasHeight)>.02)throw Error('PDF image geometry aspect differs');
  const sx=page.canvasWidth/w,sy=page.canvasHeight/h;
  const images=[];
  for(const match of block[2].matchAll(/<image\b([^>]*?)\/?\s*>/g)){
   const a=attrs(match[1]),x=Number(a.left)*sx,y=Number(a.top)*sy,width=Number(a.width)*sx,height=Number(a.height)*sy;
   if(![x,y,width,height].every(Number.isFinite)||x<0||y<0||width<=0||height<=0||
      x+width>page.canvasWidth+.1||y+height>page.canvasHeight+.1)continue;
   images.push({side:page.side,x,y,width,height,kind:'image',role:'unclassified',reviewRequired:true});
   if(images.length>=128)break;
  }
  return images;
 });
}
// Source style and explicit image-label evidence. Never return raw text,
// source filenames, embedded font data or sample values to the catalog.
function enrichCandidates(xml,pages){
 const attr=s=>Object.fromEntries([...s.matchAll(/([A-Za-z]+)="([^"]*)"/g)].map(x=>[x[1],x[2]]));
 const blocks=[...xml.matchAll(/<page\b([^>]*)>([\s\S]*?)<\/page>/g)];
 if(blocks.length!==pages.length)return;
 const imageLabels=new Map([['photo','photo'],['student photo','photo'],['teacher photo','photo'],['staff photo','photo'],['school logo','logo'],['logo','logo'],['signature','signature'],["principal's signature",'signature'],['principal signature','signature'],['school seal','seal'],['seal','seal'],['qr code','qr'],['qr','qr']]);
 for(let i=0;i<blocks.length;i++){
  const block=blocks[i],page=pages[i],a=attr(block[1]),w=Number(a.width),h=Number(a.height);
  if(!(w>0&&h>0))continue;
  const sx=page.canvasWidth/w,sy=page.canvasHeight/h,fonts=new Map(),texts=[];
  for(const match of block[2].matchAll(/<fontspec\b([^>]*?)\/?\s*>/g)){
   const a=attr(match[1]),family=String(a.family||'').replace(/^[A-Z]{6}\+/,'');
   if(!/^[A-Za-z0-9 ._-]{1,80}$/.test(family))continue;
   const size=Number(a.size)*sy;
   if(!Number.isFinite(size)||size<6||size>72||!/^#[0-9a-f]{6}$/i.test(a.color||''))continue;
   fonts.set(a.id,{sourceFont:family,fontSize:size,textColor:a.color,bold:/bold|black|heavy|semibold/i.test(family)});
  }
  for(const match of block[2].matchAll(/<text\b([^>]*)>([\s\S]*?)<\/text>/g)){
   const a=attr(match[1]),x=Number(a.left)*sx,y=Number(a.top)*sy,width=Number(a.width)*sx,height=Number(a.height)*sy;
   if(![x,y,width,height].every(Number.isFinite)||x<0||y<0||width<=0||height<=0||x+width>page.canvasWidth+.5||y+height>page.canvasHeight+.5)continue;
   const text=decode(match[2].replace(/<[^>]*>/g,'')).trim().replace(/[:.]+$/,'').toLowerCase();
   const style=fonts.get(a.font);
   texts.push({x,y,width,height,role:imageLabels.get(text),style:style?{...style,bold:style.bold||/^\s*<b>[^<]*<\/b>\s*$/.test(match[2])}:null});
  }
  for(const r of page.candidates){
   const matches=texts.filter(t=>Math.max(0,Math.min(t.x+t.width,r.x+r.width)-Math.max(t.x,r.x))*Math.max(0,Math.min(t.y+t.height,r.y+r.height)-Math.max(t.y,r.y))>=.8*r.width*r.height);
   if(matches.length===1&&matches[0].style)Object.assign(r,matches[0].style);
  }
  const images=page.imageCandidates||[],suggestions=[];
  for(const t of texts.filter(t=>t.role)){
   const near=images.filter(r=>{
    const horizontal=Math.min(t.x+t.width,r.x+r.width)-Math.max(t.x,r.x);
    const vertical=Math.min(t.y+t.height,r.y+r.height)-Math.max(t.y,r.y);
    const dx=Math.max(0,t.x-r.x-r.width,r.x-t.x-t.width),dy=Math.max(0,t.y-r.y-r.height,r.y-t.y-t.height);
    return (horizontal>=Math.min(t.width,r.width)*.55&&dy<=10)||(vertical>=Math.min(t.height,r.height)*.55&&dx<=10);
   });
   if(near.length===1)suggestions.push({image:near[0],role:t.role});
  }
  for(const s of suggestions)if(suggestions.filter(x=>x.image===s.image).length===1&&suggestions.filter(x=>x.role===s.role).length===1)
    Object.assign(s.image,{suggestedRole:s.role,roleEvidence:'unique_explicit_label'});
 }
}
async function analyzePdf(bytes,executable,imageExecutable){
 if(!executable)throw Object.assign(Error('Central PDF analysis runtime is not configured'),{status:503,publicMessage:true});
 const dir=await mkdtemp(join(tmpdir(),'saarthi-id-analysis-'));
 try{
  const file=join(dir,'source.pdf');await writeFile(file,bytes,{mode:0o600});
  // Fixed executable and arguments; no shell. Runtime must additionally be isolated and resource-limited.
  const {stdout}=await run(executable,['-f','1','-l','3','-bbox-layout','-enc','UTF-8',file,'-'],{timeout:12000,maxBuffer:2*1024*1024,windowsHide:true});
  const pages=parseCandidates(stdout);
  const warnings=['Review text positions, fonts, unlabeled fields and every sample element before publication.'];
  if(imageExecutable){
   try{
    const output=join(dir,'geometry.xml');
    // Do not supply a shell or user-controlled command arguments. The runtime
    // must be isolated with CPU/memory/disk limits before enabling either tool.
    await run(imageExecutable,['-f','1','-l','3','-xml','-zoom','1','-noroundcoord',file,output],{cwd:dir,timeout:12000,maxBuffer:1024*1024,windowsHide:true});
    if((await stat(output)).size>2*1024*1024)throw Error('Image geometry too large');
    const xml=await readFile(output,'utf8');
    const images=parseImageCandidates(xml,pages);
    pages.forEach((page,i)=>{page.imageCandidates=images[i];});
    enrichCandidates(xml,pages);
    warnings.push('Embedded image locations are candidates only; classify each image and check vector QR artwork.');
   }catch(_){warnings.push('Image candidate extraction unavailable; manually review every photo/logo/seal/signature/QR region.');}
  }else warnings.push('Central image candidate runtime not configured.');
  return {pages,reviewRequired:true,warnings};
 }finally{await rm(dir,{recursive:true,force:true});}
}
// Developer-only reference raster. Never distribute this filled artwork.
async function renderReviewSource(bytes,pages,executable){
 if(!executable)throw Object.assign(Error('Central review rasterizer is not configured'),{status:503,publicMessage:true});
 if(!Array.isArray(pages)||pages.length<1||pages.length>2)throw Error('Analyze source before review');
 const dir=await mkdtemp(join(tmpdir(),'saarthi-id-review-'));
 try{
  const input=join(dir,'source.pdf'),prefix=join(dir,'review');
  await writeFile(input,bytes,{mode:0o600});
  // Explicit configured, isolated runtime. Keep original physical size.
  await run(executable,['-f','1','-l',String(pages.length),'-r','600','-png',input,prefix],
    {cwd:dir,timeout:20000,maxBuffer:1024*1024,windowsHide:true});
  const names=(await readdir(dir)).filter(n=>/^review-\d+\.png$/.test(n)).sort((a,b)=>a.localeCompare(b,undefined,{numeric:true}));
  if(names.length!==pages.length)throw Error('Review page count mismatch');
  const rasters={};let total=0;
  for(let i=0;i<names.length;i++){
   const file=join(dir,names[i]);total+=(await stat(file)).size;
   if(total>8*1024*1024)throw Object.assign(Error('600 DPI review exceeds the 8 MiB raster budget; use reviewed artwork package'),{status:413,publicMessage:true});
   const b=await readFile(file);
   if(b.length<24||b.subarray(0,8).toString('hex')!=='89504e470d0a1a0a'||
      b.readUInt32BE(16)*b.readUInt32BE(20)>20000000||
      Math.abs(b.readUInt32BE(16)/b.readUInt32BE(20)-pages[i].canvasWidth/pages[i].canvasHeight)>.01)
       throw Error('Review raster geometry mismatch');
   rasters[pages[i].side]=b.toString('base64');
  }
  return rasters;
 }finally{await rm(dir,{recursive:true,force:true});}
}
module.exports={parseCandidates,parseImageCandidates,enrichCandidates,analyzePdf,renderReviewSource};
