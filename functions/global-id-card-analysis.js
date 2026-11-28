'use strict';
const {execFile}=require('node:child_process');
const {promisify}=require('node:util');
const {mkdtemp,writeFile,readFile,stat,readdir,rm}=require('node:fs/promises');
const {tmpdir}=require('node:os');
const {join,dirname}=require('node:path');
const runRaw=promisify(execFile);
let activeSandboxJob=false;
async function run(executable,args,options){
 if(process.env.SAARTHI_GLOBAL_ID_PDF_SANDBOX!=='landlock'){
  const configured=[process.env.SAARTHI_GLOBAL_ID_PDFTOTEXT,process.env.SAARTHI_GLOBAL_ID_PDFTOHTML,process.env.SAARTHI_GLOBAL_ID_PDFTOPPM];
  if(configured.includes(executable)&&['/usr/bin/pdftotext','/usr/bin/pdftohtml','/usr/bin/pdftoppm'].includes(executable))
   throw Object.assign(Error('Central PDF sandbox is not configured'),{status:503,publicMessage:true});
  return runRaw(executable,args,options);
 }
 if(activeSandboxJob)throw Object.assign(Error('Central PDF analysis is busy; retry shortly'),{status:503,publicMessage:true});
 activeSandboxJob=true;
 try{
  return await runRaw('/usr/bin/python3',['-I','-B',join(__dirname,'id-pdf-sandbox.py'),executable,...args],{
   ...options,cwd:dirname(args.at(-2)),env:{PATH:'/usr/bin:/bin',LANG:'C',LC_ALL:'C'}
  });
 }finally{activeSandboxJob=false;}
}
async function probeSandbox(){
 const dir=await mkdtemp(join(tmpdir(),'saarthi-id-sandbox-'));
 try{
  const file=join(dir,'source.pdf');await writeFile(file,syntheticProbePdf(),{mode:0o600});
  const {stdout}=await runRaw('/usr/bin/python3',['-I','-B',join(__dirname,'id-pdf-sandbox.py'),'--self-test',file],{
   cwd:dir,timeout:10000,maxBuffer:65536,env:{PATH:'/usr/bin:/bin',LANG:'C',LC_ALL:'C'}
  });
  return JSON.parse(stdout);
 }finally{await rm(dir,{recursive:true,force:true});}
}
const aliases={name:'name','student name':'name','teacher name':'name','staff name':'name','father name':'parentName','father/guardian':'parentName','father / guardian':'parentName','father/guardain':'parentName','father/guardian name':'parentName','father':'parentName','parent name':'parentName','guardian name':'parentName','guardian':'parentName','dob':'dob','d.o.b':'dob','d.o.b.':'dob','date of birth':'dob',class:'class','roll':'rollNo','roll no':'rollNo','roll number':'rollNo','ph no':'contact',phone:'contact','phone no':'contact','contact no':'contact','contact number':'contact',contact:'contact',address:'address',pin:'pinCode','pin code':'pinCode','pincode':'pinCode',district:'district',dist:'district',state:'state',country:'country','school name':'schoolName',designation:'designation',subject:'subject','student id':'confirmedUniversalStudentUid','student uid':'confirmedUniversalStudentUid','employee id':'employeeId','teacher id':'employeeId','staff id':'employeeId'};
const normalized=s=>s.toLowerCase().replace(/[’‘]/g,"'").replace(/\s*\/\s*/g,'/').replace(/[.:：]+$/,'').trim().replace(/\s+/g,' ');
const union=words=>{
 const x=Math.min(...words.map(v=>v.x)),y=Math.min(...words.map(v=>v.y)),right=Math.max(...words.map(v=>v.right)),bottom=Math.max(...words.map(v=>v.bottom));
 return {x,y,width:right-x,height:bottom-y};
};
const categoryOf=lines=>{
 const matches=new Set();
 for(const line of lines){
  const t=normalized(line).replace(/[-–—]/g,' ');
  if(/\bstudent\s+(?:id|identity)\s+card\b/.test(t))matches.add('studentId');
  if(/\bteacher\s+(?:id|identity)\s+card\b/.test(t))matches.add('teacherId');
  if(/\b(?:other\s+staff|staff|employee|non\s+teaching\s+staff)\s+(?:id|identity)\s+card\b/.test(t))matches.add('otherStaffId');
 }
 return matches.size===1?{kind:[...matches][0],evidence:'explicit_card_heading'}:{kind:null,evidence:matches.size>1?'conflicting_headings':'unknown'};
};
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
  const labelSlots=[],lineTexts=[];
  const side=n?'back':'front';
  const add=(key,value,extra={})=>{
   if(!value.length)return;
   const rect=union(value);
   if(rect.x<0||rect.y<0||rect.width<=0||rect.height<=0||rect.x+rect.width>width||rect.y+rect.height>height)return;
   if(candidates.some(r=>r.key===key))return;
   candidates.push({key,side,...rect,reviewRequired:true,...extra});
  };
  for(const row of rows){
   const line=row.words.sort((a,b)=>a.x-b.x),raw=line.map(w=>w.text).join(' '),norm=normalized(raw);
   lineTexts.push(raw);
   const reserved=sampleMarkers.get(norm);
   if(reserved){add(reserved,line,{evidence:'reserved_sample_phrase'});continue;}
   // Explicit placeholder text is a candidate, not an invented image rectangle.
   if(norm==='school name'){add('schoolName',line,{evidence:'explicit_placeholder'});continue;}
   if(['logo','school logo','qr','qr code','photo','student photo','teacher photo','staff photo'].includes(norm)){
    const role=norm.includes('logo')?'logo':norm.includes('qr')?'qr':'photo';
    labelSlots.push({role,side,...union(line)});continue;
   }
   const anchors=[];
   for(let j=0;j<line.length;j++){
    for(let k=Math.min(j+4,line.length-1);k>=j;k--){
     const label=normalized(line.slice(j,k+1).map(w=>w.text).join(' '));
     if(!Object.hasOwn(aliases,label))continue;
     const terminal=/[:：]$/.test(line[k].text);
     const next=line[k+1];
     // Require punctuation or a clear layout gap. Avoid guessing a sample name
     // is a new label just because a common word appears inside its value.
     const gap=next?next.x-line[k].right:0;
     const separate=next&&/^[:：]+$/.test(next.text);
     const attached=next&&/^[:：]\S/.test(next.text);
     if(!terminal&&!separate&&!attached&&!(next&&gap>=Math.max(3,(line[k].bottom-line[k].y)*.48)))continue;
     anchors.push({start:j,end:k+(separate?1:0),key:aliases[label]});
     j=k+(separate?1:0);break;
    }
   }
   for(let i=0;i<anchors.length;i++){
    const anchor=anchors[i],value=line.slice(anchor.end+1,anchors[i+1]?.start??line.length);
    // A colon may be attached to the first word. Its bbox is conservatively
    // included so the sample cannot be partly retained.
    add(anchor.key,value,{evidence:'label_value_geometry'});
   }
   // Student ID is often a rotated label/value, which may form its own row.
   // Track the whole rectangle for review instead of inventing a value bbox.
   if(!anchors.some(a=>a.key==='confirmedUniversalStudentUid')&&/^student\s+id\s*[-:–—]\s*\S+/i.test(raw))
    add('confirmedUniversalStudentUid',line,{evidence:'combined_id_placeholder',rotation:line.length===1&&line[0].bottom-line[0].y>2*(line[0].right-line[0].x)?-90:0});
  }
  return {side,canvasWidth:width,canvasHeight:height,printWidthMm:width*25.4/72,printHeightMm:height*25.4/72,candidates:candidates.slice(0,128),labelSlots,category:categoryOf(lineTexts)};

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
// Layout alone can suggest a role but cannot identify the image content.
function suggestUnlabeledImageRoles(page,texts){
 const images=page.imageCandidates||[];
 const roles=new Map();
 for(const image of images){
  if(image.suggestedRole)continue;
  const {y,width,height}=image;
  const fraction=width*height/(page.canvasWidth*page.canvasHeight);
  const centerY=(y+height/2)/page.canvasHeight;
  const ratio=width/height;
  const hasNearbyName=page.candidates.some(r=>r.key==='name'&&
    Math.abs(r.y+r.height/2-y-height/2)<page.canvasHeight*.24);
  const hasHeaderText=texts.some(t=>t.y+t.height/2<page.canvasHeight*.3&&
    Math.abs(t.y+t.height/2-y-height/2)<page.canvasHeight*.12);
  let role;
  if(fraction>=.72)role='__static';
  else if(ratio>=2.5&&centerY>.63&&fraction>=.003&&fraction<=.10)role='signature';
  else if(ratio>=.55&&ratio<=1.35){
   if(fraction>=.065&&fraction<=.34&&hasNearbyName)role='photo';
   else if(fraction>=.008&&fraction<=.075&&centerY<.28&&hasHeaderText)role='logo';
   else if(fraction>=.012&&fraction<=.09&&centerY>.65)role='seal';
  }
  if(!role)continue;
  if(!roles.has(role))roles.set(role,[]);
  roles.get(role).push(image);
 }
 for(const [role,candidates] of roles){
  if(candidates.length===1&&!images.some(r=>r.suggestedRole===role)){
   Object.assign(candidates[0],{suggestedRole:role,roleEvidence:'layout_only',roleConfidence:'low'});
  }
 }
}
// Return source style and role evidence without sample values or source filenames.
function enrichCandidates(xml,pages){
 const attr=s=>Object.fromEntries([...s.matchAll(/([A-Za-z]+)="([^"]*)"/g)].map(x=>[x[1],x[2]]));
 const blocks=[...xml.matchAll(/<page\b([^>]*)>([\s\S]*?)<\/page>/g)];
 if(blocks.length!==pages.length)return;
 const imageLabels=new Map([['photo','photo'],['student photo','photo'],['teacher photo','photo'],['staff photo','photo'],['school logo','logo'],['logo','logo'],['signature','signature'],["principal's signature",'signature'],['principal signature','signature'],["principal’s signature & seal",'signature'],["principal's signature & seal",'signature'],['principal signature & seal','signature'],['school seal','seal'],['seal','seal'],['qr code','qr'],['qr','qr']]);
 for(let i=0;i<blocks.length;i++){
  const block=blocks[i],page=pages[i],a=attr(block[1]),w=Number(a.width),h=Number(a.height);
  if(!(w>0&&h>0))continue;
  const sx=page.canvasWidth/w,sy=page.canvasHeight/h,fonts=new Map(),texts=[];
  for(const match of block[2].matchAll(/<fontspec\b([^>]*?)\/?\s*>/g)){
   const a=attr(match[1]),family=String(a.family||'').replace(/^[A-Z]{6}\+/,'');
   if(!/^[A-Za-z0-9 ._-]{1,80}$/.test(family))continue;
   const size=Number(a.size)*sy;
   if(!Number.isFinite(size)||size<6||size>72||!/^#[0-9a-f]{6}$/i.test(a.color||''))continue;
   fonts.set(a.id,{sourceFont:family,fontSize:size,textColor:a.color,bold:/bold|black|heavy|semibold/i.test(family),sourceItalic:/italic|oblique/i.test(family)});
  }
  for(const match of block[2].matchAll(/<text\b([^>]*)>([\s\S]*?)<\/text>/g)){
   const a=attr(match[1]),x=Number(a.left)*sx,y=Number(a.top)*sy,width=Number(a.width)*sx,height=Number(a.height)*sy;
   if(![x,y,width,height].every(Number.isFinite)||x<0||y<0||width<=0||height<=0||x+width>page.canvasWidth+.5||y+height>page.canvasHeight+.5)continue;
   const text=normalized(decode(match[2].replace(/<[^>]*>/g,'')));
   const style=fonts.get(a.font);
   // Independent XML text objects recover placeholders that share a
   // vertical row with unrelated elements in bbox-layout.
   if(text==='school name'&&!page.candidates.some(r=>r.key==='schoolName'))
    page.candidates.push({key:'schoolName',side:page.side,x,y,width,height,reviewRequired:true,evidence:'explicit_placeholder'});
   if(['logo','school logo','qr','qr code','photo','student photo','teacher photo','staff photo'].includes(text)){
    const role=imageLabels.get(text);
    if(role&&!(page.labelSlots||[]).some(r=>r.role===role))
     (page.labelSlots??=[]).push({role,side:page.side,x,y,width,height});
   }
   texts.push({x,y,width,height,role:imageLabels.get(text),style:style?{...style,bold:style.bold||/^\s*<b>[^<]*<\/b>\s*$/.test(match[2]),sourceItalic:style.sourceItalic||/<i>[^<]*<\/i>/.test(match[2])}:null});
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
   if(near.length===1){
    const candidate=near[0];
    // A small logo label adjacent to a tall portrait must not label the portrait.
    const fraction=candidate.width*candidate.height/(page.canvasWidth*page.canvasHeight);
    const ratio=candidate.width/candidate.height;
    if(t.role==='logo'&&(fraction>.085||ratio<.6||ratio>2.2))continue;
    suggestions.push({image:candidate,role:t.role});
   }
  }
  for(const s of suggestions)if(suggestions.filter(x=>x.image===s.image).length===1&&suggestions.filter(x=>x.role===s.role).length===1)
    Object.assign(s.image,{suggestedRole:s.role,roleEvidence:'unique_explicit_label',roleConfidence:'medium'});
  suggestUnlabeledImageRoles(page,texts);
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
  const kinds=[...new Set(pages.map(p=>p.category?.kind).filter(Boolean))];
  const category=kinds.length===1&&!pages.some(p=>p.category?.evidence==='conflicting_headings')?{kind:kinds[0],evidence:'explicit_card_heading'}:{kind:null,evidence:kinds.length>1||pages.some(p=>p.category?.evidence==='conflicting_headings')?'conflicting_headings':'unknown'};
  return {pages,category,reviewRequired:true,warnings};
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
// A tiny fictional PDF with text and one embedded image for a developer-triggered runtime smoke probe.
// ASCII-only, with correct byte offsets. No school data or credentials.
function syntheticProbePdf(){
 const stream='BT /F1 10 Tf 20 90 Td (Name: Synthetic) Tj ET\nq 24 0 0 18 175 30 cm /ProbeImage Do Q\n';
 const objects=['<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 242 153] /Resources << /Font << /F1 4 0 R >> /XObject << /ProbeImage 6 0 R >> >> /Contents 5 0 R >>',
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  '<< /Length '+Buffer.byteLength(stream)+' >>\nstream\n'+stream+'endstream',
  '<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length 3 >>\nstream\nRGB\nendstream'];
 let pdf='%PDF-1.4\n';const offsets=[0];
 for(let i=0;i<objects.length;i++){offsets.push(Buffer.byteLength(pdf));pdf+=(i+1)+' 0 obj\n'+objects[i]+'\nendobj\n';}
 const xref=Buffer.byteLength(pdf);
 pdf+='xref\n0 '+offsets.length+'\n0000000000 65535 f \n';
 for(const offset of offsets.slice(1))pdf+=String(offset).padStart(10,'0')+' 00000 n \n';
 pdf+='trailer\n<< /Size '+offsets.length+' /Root 1 0 R >>\nstartxref\n'+xref+'\n%%EOF\n';
 return Buffer.from(pdf,'ascii');
}
async function probeRuntime(analyzer,imageAnalyzer,rasterizer){
 const checks={text:false,imageGeometry:false,raster:false};
 if(!analyzer)return checks;
 try{
  const pdf=syntheticProbePdf(),analysis=await analyzePdf(pdf,analyzer,imageAnalyzer);
  checks.text=analysis.pages.length===1&&analysis.pages[0].candidates.some(c=>c.key==='name');
  checks.imageGeometry=analysis.pages[0].imageCandidates?.some(r=>Math.abs(r.width-24)<1&&Math.abs(r.height-18)<1)===true;
  if(rasterizer){
   const images=await renderReviewSource(pdf,analysis.pages,rasterizer);
   const png=Buffer.from(images.front,'base64');
   const page=analysis.pages[0];
   checks.raster=!images.back&&Math.abs(png.readUInt32BE(16)-page.printWidthMm*600/25.4)<=1&&
    Math.abs(png.readUInt32BE(20)-page.printHeightMm*600/25.4)<=1;
  }
 }catch(_){/* Return only safe boolean evidence, not local paths or stderr. */}
 return checks;
}
// Clean companion PDF: preserve original vector artwork before rasterization.
async function renderCleanCompanion(bytes,sourcePages,analyzer,rasterizer){
 const analysis=await analyzePdf(bytes,analyzer,null);
 if(analysis.pages.length!==sourcePages.length)throw Object.assign(Error('Clean PDF side count differs from source'),{status:400,publicMessage:true});
 for(let i=0;i<sourcePages.length;i++){
  const a=analysis.pages[i],b=sourcePages[i];
  if(a.side!==b.side||Math.abs(a.printWidthMm-b.printWidthMm)>.05||Math.abs(a.printHeightMm-b.printHeightMm)>.05)
   throw Object.assign(Error('Clean PDF dimensions differ from source'),{status:400,publicMessage:true});
 }
 return renderReviewSource(bytes,sourcePages,rasterizer);
}
module.exports={probeSandbox,parseCandidates,parseImageCandidates,enrichCandidates,analyzePdf,renderReviewSource,syntheticProbePdf,probeRuntime,renderCleanCompanion};
