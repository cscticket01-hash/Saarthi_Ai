'use strict';
const {createHash}=require('node:crypto');
const {probeSandbox,analyzePdf,syntheticProbePdf,renderReviewSource}=require('../functions/global-id-card-analysis');
async function run({app,db,bucket,env}){
 if(app.options.projectId!=='saarthi-ai-df12b'||env.SAARTHI_ID_LIBRARY_STAGING==='true'||env.RENDER_SERVICE_ID!=='srv-db06j2id0e5s73aafdi0'||env.SAARTHI_GLOBAL_ID_R2_BUCKET!=='saarthi-id-library-prod'||env.SAARTHI_ID_PDF_DIAGNOSTIC!=='20261128-upload')return;
 const checks={};const a=env.SAARTHI_GLOBAL_ID_PDFTOTEXT,i=env.SAARTHI_GLOBAL_ID_PDFTOHTML,r=env.SAARTHI_GLOBAL_ID_PDFTOPPM;
 try{const p=await probeSandbox();checks.sandbox=Object.values(p).every(Boolean);}catch(_){checks.sandbox=false;}
 try{
  const pdf=syntheticProbePdf(),p=await analyzePdf(pdf,a,i,{ocr:false,rasterizer:r});
  checks.synthetic=p.pages.length===1&&p.pages[0].candidates.some(v=>v.key==='name');
  checks.raster=Boolean((await renderReviewSource(pdf,p.pages,r,150)).front);
 }catch(_){checks.synthetic=false;}
 try{
  const id='gid-68771d8300f84539a44bfd6a11e713c1',row=(await db.doc('global_id_card_library/'+id).get()).data();
  checks.originalState=row?.state==='deleted'?'deleted':row?.state==='draft'?'draft':'other';
  if(row?.sourcePath!=='global-id-card-library/private/'+id+'/source.pdf'||!['deleted','draft'].includes(row.state))throw Error('source identity');
  const [bytes]=await bucket.file(row.sourcePath).download();
  checks.sourceHash=bytes.length<=8*1024*1024&&createHash('sha256').update(bytes).digest('hex')===row.sourceSha256;
  if(!checks.sourceHash)throw Error('source mismatch');
  const analysis=await analyzePdf(bytes,a,i,{ocr:true,rasterizer:r});
  checks.realPreflight=analysis.pages.length>0;checks.studentCategory=analysis.category.kind==='studentId';
  checks.actualRaster=Boolean((await renderReviewSource(bytes,analysis.pages,r,150)).front);
  checks.fields=analysis.pages.flatMap(p=>p.candidates.map(x=>x.key));
 }catch(_){checks.realPreflight=false;}
 console.info('ID_UPLOAD_DIAGNOSTIC '+JSON.stringify(checks));
}
module.exports={run};