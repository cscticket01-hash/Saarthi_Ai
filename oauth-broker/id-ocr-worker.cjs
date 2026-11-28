'use strict';
// Only receives Poppler-produced, bounded PNGs. All trained data is installed
// locally. No sample text is logged; the parent receives bounded word geometry.
const {join,resolve}=require('node:path');
const {mkdtemp,symlink,stat,readFile,rm}=require('node:fs/promises');
const {tmpdir}=require('node:os');
const {createWorker,PSM}=require('tesseract.js');
const languages=['eng','hin','ben','asm'];
async function main(){
 const input=process.argv[2],mode=process.argv[3];
 if(!['eng','all'].includes(mode)||!/^\/tmp\/saarthi-id-ocr-[A-Za-z0-9]{6,32}\/page\.png$/.test(input))throw Error('invalid OCR request');
 const png=await readFile(input);
 if(png.length<24||png.length>8*1024*1024||png.subarray(0,8).toString('hex')!=='89504e470d0a1a0a'||
   png.readUInt32BE(16)*png.readUInt32BE(20)>6000000)throw Error('invalid OCR raster');
 const selected=mode==='eng'?['eng']:languages;
 const dir=await mkdtemp(join(tmpdir(),'saarthi-id-models-'));let worker;
 try{
  for(const lang of selected){
   const model=resolve(__dirname,'node_modules','@tesseract.js-data',lang,'4.0.0_best_int',lang+'.traineddata.gz');
   const size=(await stat(model)).size;
   if(size<10000||size>32*1024*1024)throw Error('local model unavailable');
   await symlink(model,join(dir,lang+'.traineddata.gz'));
  }
  worker=await createWorker(selected,1,{langPath:dir,cacheMethod:'none',workerPath:require.resolve('tesseract.js/src/worker-script/node/index.js')});
  await worker.setParameters({tessedit_pageseg_mode:PSM.SPARSE_TEXT});
  const result=await worker.recognize(png,{}, {text:false,blocks:true});
  const words=(result.data.blocks||[]).flatMap(b=>(b.paragraphs||[]).flatMap(p=>(p.lines||[]).flatMap(l=>l.words||[])))
    .filter(w=>w.confidence>=50&&typeof w.text==='string'&&w.text.trim()&&w.text.length<=120&&w.bbox)
    .slice(0,1024).map(w=>({text:w.text,bbox:w.bbox,confidence:w.confidence}));
  console.log(JSON.stringify({width:png.readUInt32BE(16),height:png.readUInt32BE(20),words,languages:selected}));
 }finally{if(worker)await worker.terminate();await rm(dir,{recursive:true,force:true});}
}
main().catch(()=>{console.error('OCR processing failed');process.exitCode=1;});
