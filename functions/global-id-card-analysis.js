'use strict';
const {execFile}=require('node:child_process');
const {promisify}=require('node:util');
const {mkdtemp,writeFile,readFile,stat,rm}=require('node:fs/promises');
const {tmpdir}=require('node:os');
const {join}=require('node:path');
const run=promisify(execFile);
const aliases={name:'name','student name':'name','teacher name':'name','father name':'parentName','father/guardian':'parentName','guardian name':'parentName','dob':'dob','d.o.b':'dob','date of birth':'dob',class:'class','roll no':'rollNo','roll number':'rollNo','ph no':'contact',phone:'contact',address:'address',pin:'pinCode',district:'district','school name':'schoolName',designation:'designation',subject:'subject'};
const decode=s=>s.replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&quot;/g,'"').replace(/&apos;/g,"'");
function parseCandidates(xml){
 const pages=[...xml.matchAll(/<page\s+width="([\d.]+)"\s+height="([\d.]+)"[^>]*>([\s\S]*?)<\/page>/g)];
 if(pages.length<1||pages.length>2)throw Object.assign(Error('Only one or two ID card pages are supported'),{status:400,publicMessage:true});
 return pages.map((page,n)=>{
  const width=Number(page[1]),height=Number(page[2]);
  if(!Number.isFinite(width)||!Number.isFinite(height)||width<=0||height<=0||width*25.4/72>150||height*25.4/72>150)throw Object.assign(Error('PDF page is not a supported ID card size'),{status:400,publicMessage:true});
  const candidates=[];
  for(const line of page[3].matchAll(/<line\b[^>]*>([\s\S]*?)<\/line>/g)){
   const words=[...line[1].matchAll(/<word\s+xMin="([\d.]+)"\s+yMin="([\d.]+)"\s+xMax="([\d.]+)"\s+yMax="([\d.]+)"[^>]*>([^<]*)<\/word>/g)].map(w=>({x:+w[1],y:+w[2],right:+w[3],bottom:+w[4],text:decode(w[5])}));
   const joined=words.map(w=>w.text).join(' ');
   const match=joined.match(/^([^:]{1,40}):\s*(.+)$/);
   const label=match&&match[1].trim().toLowerCase();
   const key=label&&Object.hasOwn(aliases,label)?aliases[label]:null;
   if(!key)continue;
   let split=words.findIndex(w=>w.text.includes(':'));
   if(split<0||split===words.length-1||!words[split].text.endsWith(':'))continue;
   const value=words.slice(split+1);
   const x=Math.min(...value.map(v=>v.x)),y=Math.min(...value.map(v=>v.y)),right=Math.max(...value.map(v=>v.right)),bottom=Math.max(...value.map(v=>v.bottom));
   if(x<0||y<0||right>width||bottom>height||right<=x||bottom<=y)continue;
   candidates.push({key,side:n?'back':'front',x,y,width:right-x,height:bottom-y,reviewRequired:true});
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
    const images=parseImageCandidates(await readFile(output,'utf8'),pages);
    pages.forEach((page,i)=>{page.imageCandidates=images[i];});
    warnings.push('Embedded image locations are candidates only; classify each image and check vector QR artwork.');
   }catch(_){warnings.push('Image candidate extraction unavailable; manually review every photo/logo/seal/signature/QR region.');}
  }else warnings.push('Central image candidate runtime not configured.');
  return {pages,reviewRequired:true,warnings};
 }finally{await rm(dir,{recursive:true,force:true});}
}
module.exports={parseCandidates,parseImageCandidates,analyzePdf};
