'use strict';
const {execFile}=require('node:child_process');
const {promisify}=require('node:util');
const {mkdtemp,writeFile,rm}=require('node:fs/promises');
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
   const key=match&&aliases[match[1].trim().toLowerCase()];
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
async function analyzePdf(bytes,executable){
 if(!executable)throw Object.assign(Error('Central PDF analysis runtime is not configured'),{status:503,publicMessage:true});
 const dir=await mkdtemp(join(tmpdir(),'saarthi-id-analysis-'));
 try{
  const file=join(dir,'source.pdf');await writeFile(file,bytes,{mode:0o600});
  // Fixed executable and arguments; no shell. Runtime must additionally be isolated and resource-limited.
  const {stdout}=await run(executable,['-f','1','-l','3','-bbox-layout','-enc','UTF-8',file,'-'],{timeout:12000,maxBuffer:2*1024*1024,windowsHide:true});
  return {pages:parseCandidates(stdout),reviewRequired:true,warnings:['Text candidates only: verify fonts, unlabeled fields, image/QR slots, and remove every sample element before publication.']};
 }finally{await rm(dir,{recursive:true,force:true});}
}
module.exports={parseCandidates,analyzePdf};
