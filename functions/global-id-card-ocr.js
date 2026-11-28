'use strict';
const {execFile}=require('node:child_process');
const {promisify}=require('node:util');
const {mkdtemp,writeFile,rm}=require('node:fs/promises');
const {join}=require('node:path');
const {tmpdir}=require('node:os');
const run=promisify(execFile);
let busy=false;
const esc=s=>s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&apos;');
function toPageXml(result,page){
 if(!result||!Number.isInteger(result.width)||!Number.isInteger(result.height)||result.width<1||result.height<1||
  result.width*result.height>6000000||!Array.isArray(result.words))throw Error('invalid OCR geometry');
 const sx=page.canvasWidth/result.width,sy=page.canvasHeight/result.height;
 const words=result.words.slice(0,1024).flatMap(w=>{
  const b=w.bbox;
  if(typeof w.text!=='string'||w.text.length>120||!b||![b.x0,b.y0,b.x1,b.y1,w.confidence].every(Number.isFinite)||
    w.confidence<50||b.x0<0||b.y0<0||b.x1>b.x0+result.width||b.x1>result.width||b.y1>result.height||b.x1<=b.x0||b.y1<=b.y0)return [];
  return ['<word xMin="'+(b.x0*sx).toFixed(5)+'" yMin="'+(b.y0*sy).toFixed(5)+'" xMax="'+Math.min(page.canvasWidth,b.x1*sx).toFixed(5)+'" yMax="'+Math.min(page.canvasHeight,b.y1*sy).toFixed(5)+'">'+esc(w.text.trim())+'</word>'];
 });
 return '<page width="'+page.canvasWidth+'" height="'+page.canvasHeight+'">'+words.join('')+'</page>';
}
async function recognize(png,mode='all'){
 if(busy)throw Error('OCR busy');busy=true;
 let dir;
 try{
  dir=await mkdtemp(join(tmpdir(),'saarthi-id-ocr-'));
  const input=join(dir,'page.png');await writeFile(input,png,{mode:0o600});
  const {stdout}=await run(process.execPath,['--max-old-space-size=128',join(__dirname,'../oauth-broker/id-ocr-worker.cjs'),input,mode],
   {cwd:dir,timeout:30000,maxBuffer:512*1024,env:{PATH:'/usr/bin:/bin',LANG:'C',HOME:dir,TMPDIR:dir}});
  return JSON.parse(stdout);
 }catch(e){
  const phase=String(e?.stderr||'').match(/OCR_SAFE_PHASE ([a-z_]+)/)?.[1]||'unknown';
  const safe=Object.assign(Error('OCR process failed'),{phase,signal:e?.signal||null,killed:e?.killed===true,exitCode:typeof e?.code==='number'?e.code:null});
  throw safe;
 }finally{try{if(dir)await rm(dir,{recursive:true,force:true});}finally{busy=false;}}
}
module.exports={recognize,toPageXml};
