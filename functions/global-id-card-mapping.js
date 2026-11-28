'use strict';
// Persist geometry and formatting only; no sample strings, credentials or artwork.
const fields=new Set(['','__static','schoolName','schoolAddress','schoolLocation','schoolEmail','schoolContactNo','name','parentName','dob','class','section','rollNo','designation','subject','contact','address','pinCode','district','state','country','session','employeeId','bloodGroup','emergencyContact','academicSession','confirmedUniversalStudentUid','logo','photo','signature','seal','qr']);
const images=new Set(['logo','photo','signature','seal']);
const bad=()=>{throw Object.assign(Error('Invalid mapping geometry or formatting'),{status:400,publicMessage:true});};
function sanitizeMapping(slots,pages){
 if(!Array.isArray(slots)||slots.length>128||!Array.isArray(pages)||pages.length<1||pages.length>2)bad();
 const keys=new Set();
 return slots.map(s=>{
  if(!s||!fields.has(s.key))bad();
  const p=pages.find(p=>p.side===s.side);
  if(!p||!Number.isFinite(p.canvasWidth)||!Number.isFinite(p.canvasHeight))bad();
  const key=s.side+':'+s.key;
  if(s.key&&s.key!=='__static'&&keys.has(key))bad();
  keys.add(key);
  const result={key:s.key,side:s.side,kind:images.has(s.key)||!s.key||s.key==='__static'?'image':s.key==='qr'?'qr':'text'};
  for(const prefix of ['','sample_']){
   const x=s[prefix+'x']??s.x,y=s[prefix+'y']??s.y,w=s[prefix+'width']??s.width,h=s[prefix+'height']??s.height;
   if(![x,y,w,h].every(v=>typeof v==='number'&&Number.isFinite(v))||x<0||y<0||w<=0||h<=0||x+w>p.canvasWidth+.000001||y+h>p.canvasHeight+.000001)bad();
   Object.assign(result,{[prefix+'x']:x,[prefix+'y']:y,[prefix+'width']:Math.min(w,p.canvasWidth-x),[prefix+'height']:Math.min(h,p.canvasHeight-y)});
  }
  if(s.fontSize!=null){if(typeof s.fontSize!=='number'||!Number.isFinite(s.fontSize)||s.fontSize<6||s.fontSize>72)bad();result.fontSize=s.fontSize;}
  if(s.textColor!=null){if(typeof s.textColor!=='string'||!/^#[0-9a-f]{6}$/i.test(s.textColor))bad();result.textColor=s.textColor;}
  if(s.align!=null){if(!['left','center','right'].includes(s.align))bad();result.align=s.align;}
  result.rotation=result.kind==='text'&&s.rotation===-90?-90:0;
  result.oval=result.kind==='image'&&s.oval===true;
  result.bold=result.kind==='text'&&s.bold===true;
  result.wrap=result.kind==='text'&&s.wrap===true;
  result.roleConfidence=s.roleConfidence==='low'?'low':'medium';
  result.manual=s.manual===true;
  return result;
 });
}
module.exports={sanitizeMapping};
