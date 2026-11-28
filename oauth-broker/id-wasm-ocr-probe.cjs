'use strict';
// Synthetic-only staging probe. No uploaded files, school data, Firebase
// client, credentials, public HTTP route or runtime OCR integration.
const {join}=require('node:path');
const {access}=require('node:fs/promises');
const {createWorker,PSM}=require('tesseract.js');
const {syntheticProbePdf,analyzePdf,renderReviewSource}=require('../functions/global-id-card-analysis');
(async()=>{
 let worker;
 try{
  const langPath=join(__dirname,'node_modules','@tesseract.js-data','eng','4.0.0_best_int');
  await access(join(langPath,'eng.traineddata.gz'));
  const source=syntheticProbePdf();
  const analysis=await analyzePdf(source,'/usr/bin/pdftotext','/usr/bin/pdftohtml');
  const rasters=await renderReviewSource(source,analysis.pages,'/usr/bin/pdftoppm');
  const png=Buffer.from(rasters.front,'base64');
  worker=await createWorker('eng',1,{langPath,cacheMethod:'none',
    workerPath:require.resolve('tesseract.js/src/worker-script/node/index.js')});
  await worker.setParameters({tessedit_pageseg_mode:PSM.SPARSE_TEXT});
  const result=await worker.recognize(png,{}, {text:true,blocks:true});
  const words=(result.data.blocks||[]).flatMap(b=>(b.paragraphs||[]).flatMap(p=>(p.lines||[]).flatMap(l=>l.words||[])));
  const checks={localLanguageModel:true,syntheticText:/name\s*:\s*synthetic/i.test(result.data.text||''),
   wordGeometry:words.some(w=>/^synthetic$/i.test(w.text||'')&&w.bbox?.x1>w.bbox?.x0&&w.bbox?.y1>w.bbox?.y0)};
  console.log('ID_WASM_OCR_SYNTHETIC '+JSON.stringify(checks));
  if(!Object.values(checks).every(Boolean))process.exitCode=1;
 }catch(_){console.log('ID_WASM_OCR_SYNTHETIC_FAILED');process.exitCode=1;}
 finally{if(worker)await worker.terminate();}
})();
