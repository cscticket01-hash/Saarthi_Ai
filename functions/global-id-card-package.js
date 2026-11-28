'use strict';
const {createHash}=require('node:crypto');
const MAX=8*1024*1024;
const hash=b=>createHash('sha256').update(b).digest('hex');
const bad=message=>{throw Object.assign(Error(message),{status:400,publicMessage:true});};
const fields=new Set(['schoolName','schoolAddress','schoolLocation','schoolEmail','schoolContactNo','name','parentName','dob','class','section','rollNo','designation','subject','contact','address','pinCode','district','state','country','session','employeeId','bloodGroup','emergencyContact','academicSession','confirmedUniversalStudentUid','logo','photo','signature','seal','qr']);
const images=new Set(['logo','photo','signature','seal']);
const labels=new Set(['',': ',':','Name: ','Father Name: ','Father/Guardian: ','Guardian: ','D.O.B: ','DOB: ','Class: ','Roll No: ','Phone: ','Contact: ','Address: ','PIN: ','District: ','State: ','Country: ','Designation: ','Subject: ','Employee ID: ','Student ID - ','School: ','Town/Vill - ','P.O - ','PIN - ','Dist - ']);
const finite=(v,min,max)=>typeof v==='number'&&Number.isFinite(v)&&v>=min&&v<=max;
function png(raw,w,h){
 if(typeof raw!=='string'||raw.length>Math.ceil(MAX/3)*4||!(/^[A-Za-z0-9+/]+={0,2}$/).test(raw))bad('Invalid clean artwork');
 const b=Buffer.from(raw,'base64');
 if(b.length<45||b.length>MAX||b.toString('base64')!==raw||b.subarray(0,8).toString('hex')!=='89504e470d0a1a0a')bad('Only bounded PNG artwork is accepted');
 let offset=8,header=false,pixels=false,end=false;
 while(offset+12<=b.length){
  const n=b.readUInt32BE(offset),type=b.toString('ascii',offset+4,offset+8);
  if(n>b.length-offset-12)bad('Truncated PNG');
  if(!header){
   if(type!=='IHDR'||n!==13)bad('Invalid PNG header');
   const pw=b.readUInt32BE(offset+8),ph=b.readUInt32BE(offset+12);
   if(!pw||!ph||pw*ph>20000000||Math.abs(pw/ph-w/h)>.01)bad('Artwork dimensions do not match card');
   header=true;
  }
  if(type==='IDAT'&&n>0)pixels=true;
  offset+=n+12;
  if(type==='IEND'){end=n===0&&offset===b.length;break;}
 }
 if(!pixels||!end)bad('Incomplete PNG');
 return raw;
}
function validatePackage(input,id){
 if(!input||typeof input!=='object'||Array.isArray(input)||Object.keys(input).some(k=>!['manifest','backgrounds'].includes(k)))bad('Invalid package');
 const m=input.manifest;
 if(!m||m.id!==id||m.version!==1||!Array.isArray(m.regions)||m.regions.length<2||m.regions.length>128)bad('Invalid manifest identity');
 const {canvasWidth:w,canvasHeight:h,printWidthMm:pw,printHeightMm:ph}=m;
 if(!finite(w,1,10000)||!finite(h,1,10000)||!finite(pw,1,150)||!finite(ph,1,150)||Math.abs(w/h-pw/ph)>.01)bad('Invalid physical dimensions');
 const keys=new Set();
 const regions=m.regions.map(r=>{
  if(!r||!fields.has(r.key)||!['front','back'].includes(r.side)||r.kind!==(images.has(r.key)?'image':r.key==='qr'?'qr':'text'))bad('Unsupported field or type');
  const key=r.side+':'+r.key;
  if(keys.has(key)||!finite(r.x,0,w)||!finite(r.y,0,h)||!finite(r.width,.01,w-r.x)||!finite(r.height,.01,h-r.y))bad('Duplicate or overflowing region');
  keys.add(key);
  const fontSize=r.fontSize??12,minFontSize=r.minFontSize??8,padding=r.padding??0;
  const maxLines=r.maxLines??1,wrap=r.wrap===true,rotation=r.rotation??0,fit=r.fit??'contain',shape=r.shape??'rect';
  if(r.bold!==undefined&&typeof r.bold!=='boolean')bad('Invalid font weight');
  if(!labels.has(r.label??'')||!finite(fontSize,6,72)||!finite(minFontSize,6,fontSize)||!finite(padding,0,Math.min(r.width,r.height)/2)||padding*2>=Math.min(r.width,r.height)||
   !Number.isInteger(maxLines)||maxLines<1||maxLines>12||(!wrap&&maxLines!==1)||
   ![0,-90].includes(rotation)||(rotation!==0&&r.kind!=='text')||!['rect','oval'].includes(shape)||(shape==='oval'&&r.kind!=='image')||
   !['contain','cover'].includes(fit)||(['logo','signature','seal'].includes(r.key)&&fit!=='contain')||
   !['left','center','right'].includes(r.align??'left')||!['ellipsis','error'].includes(r.overflow??'ellipsis')||
   !/^#[0-9a-fA-F]{6}$/.test(r.textColor??'#000000')||!finite(r.focusX??.5,0,1)||!finite(r.focusY??.35,0,1))bad('Invalid region formatting');
  if(r.kind==='text'&&r.overflow!==undefined&&r.overflow!=='error')bad('Text truncation is not allowed in new ID templates: '+r.key);
  if(r.key==='qr'&&(Math.min(r.width,r.height)*pw/w<12||Math.min(r.width,r.height)<8))bad('QR region too small');
  if(r.key==='photo'&&(r.width*pw/w<8||r.height*ph/h<10))bad('Photo region too small');
  return {key:r.key,side:r.side,kind:r.kind,x:r.x,y:r.y,width:r.width,height:r.height,
   label:r.label??'',fontSize,minFontSize,padding,wrap,maxLines,rotation,fit,shape,align:r.align??'left',
   overflow:r.kind==='text'?'error':r.overflow??'error',textColor:r.textColor??'#000000',bold:r.kind==='text'&&r.bold===true,focusX:r.focusX??.5,focusY:r.focusY??.35,required:r.required===true||r.key==='confirmedUniversalStudentUid'};
 });
 if(!keys.has('front:name')||!regions.some(r=>r.key==='qr'))bad('Name and authentication QR required');
 for(let i=0;i<regions.length;i++)for(const b of regions.slice(i+1)){
  const a=regions[i];if(a.side===b.side&&a.x<b.x+b.width&&b.x<a.x+a.width&&a.y<b.y+b.height&&b.y<a.y+a.height)bad('Overlapping template regions');
 }
 const back=regions.some(r=>r.side==='back'),bg=input.backgrounds;
 if(!bg||typeof bg!=='object'||Array.isArray(bg)||Object.keys(bg).some(k=>!['front','back'].includes(k))||!!bg.back!==back)bad('Artwork sides must match manifest');
 const clean={manifest:{id,version:1,canvasWidth:w,canvasHeight:h,printWidthMm:pw,printHeightMm:ph,regions},
  backgrounds:{front:png(bg.front,w,h),...(back?{back:png(bg.back,w,h)}:{})}};
 const bytes=Buffer.from(JSON.stringify(clean));
 if(bytes.length>MAX)bad('Clean package exceeds 8 MiB');
 return {bytes,sha256:hash(bytes),clean};
}
// The original source determines physical size and side count. A reviewed
// package may use a different design-unit scale, but may not resize the card.
function verifySourceGeometry(clean,pages){
 if(!Array.isArray(pages)||pages.length<1||pages.length>2)bad('Source analysis required');
 const m=clean.manifest,hasBack=Boolean(clean.backgrounds.back);
 if(hasBack!==(pages.length===2))bad('Package side count differs from original PDF');
 const seen=new Set();
 for(const page of pages){
  if(!['front','back'].includes(page.side)||seen.has(page.side)||
     !Number.isFinite(page.printWidthMm)||!Number.isFinite(page.printHeightMm)||
     Math.abs(page.printWidthMm-m.printWidthMm)>.1||
     Math.abs(page.printHeightMm-m.printHeightMm)>.1)bad('Package physical dimensions differ from original PDF');
  seen.add(page.side);
 }
 if(!seen.has('front')||(hasBack&&!seen.has('back')))bad('Original PDF side identity mismatch');
}
module.exports={validatePackage,verifySourceGeometry,hash};
