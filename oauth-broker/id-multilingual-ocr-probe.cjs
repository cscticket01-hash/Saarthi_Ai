'use strict';
const {syntheticProbePdf,analyzePdf,renderReviewSource}=require('../functions/global-id-card-analysis');
const {recognize}=require('../functions/global-id-card-ocr');
let step='pdf';
(async()=>{
 const pdf=syntheticProbePdf();
 const p=await analyzePdf(pdf,'/usr/bin/pdftotext','/usr/bin/pdftohtml');
 step='raster300';
 const rasters=await renderReviewSource(pdf,p.pages,'/usr/bin/pdftoppm',300);
 const png=Buffer.from(rasters.front,'base64');
 step='recognize_all';
 const words=await recognize(png);
 // Verify actual multilingual worker initialization and geometry on a known
 // English sample. Separate language recognition accuracy remains a gate.
 const lang=['eng','hin','ben','asm'].every(l=>words.languages.includes(l));
 const text=words.words.some(w=>/^synthetic$/i.test(w.text));
 step='integrated';
 const actual=await analyzePdf(pdf,'/usr/bin/pdftotext','/usr/bin/pdftohtml',{ocr:true,rasterizer:'/usr/bin/pdftoppm'});
 const checks={allLocalModels:lang,knownEnglishText:text,geometry:words.words.some(w=>w.bbox.x1>w.bbox.x0),
  integratedFallback:actual.pages[0].ocr?.state==='recognized',sampleTextNotRetained:!JSON.stringify(actual).includes('Synthetic')};
 console.info('ID_MULTILINGUAL_OCR_CHECK '+JSON.stringify(checks));
 if(!Object.values(checks).every(Boolean))process.exitCode=1;
})().catch(e=>{console.log('ID_MULTILINGUAL_OCR_FAILED '+JSON.stringify({step,phase:e?.phase||null,signal:e?.signal||null,killed:e?.killed===true,exitCode:e?.exitCode??null}));process.exitCode=1;});
