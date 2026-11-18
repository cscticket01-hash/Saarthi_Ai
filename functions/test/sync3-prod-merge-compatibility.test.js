'use strict';
// Contract checks for code merge only. These are not live-device or Google Drive acceptance.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'../..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
function releaseNumber(url,kind){
 const re=kind==='windows'
  ? /\/releases\/download\/windows-v(\d+\.\d+\.\d+)\/Vidya_Saarthi_Setup_\1\.exe$/
  : /\/releases\/download\/android-v(\d+\.\d+\.\d+)\/Vidya-Saarthi-v\1\.apk$/;
 const m=url.match(re);
 assert.ok(m,'Installer redirect must retain matching release tag/asset names');
 return m[1].split('.').map(Number);
}
const atLeast=(v,min)=>v[0]>min[0]||v[0]===min[0]&&(v[1]>min[1]||v[1]===min[1]&&v[2]>=min[2]);
test('production Windows/Android release redirects cannot silently regress',()=>{
 const cfg=JSON.parse(read('firebase.json'));
 const redirect=name=>cfg.hosting.redirects.find(x=>x.source===name);
 const win=redirect('/downloads/windows.exe'),apk=redirect('/downloads/android.apk');
 assert.equal(win?.type,302);
 assert.equal(apk?.type,302);
 assert.ok(atLeast(releaseNumber(win.destination,'windows'),[2,1,245]));
 assert.ok(atLeast(releaseNumber(apk.destination,'android'),[1,0,701]));
});
test('Windows OCR retains sha-pinned official installer and redistribution license',()=>{
 const text=read('.github/scripts/bundle_templateforge_ocr.ps1');
 assert.match(text,/Get-FileHash \$installer -Algorithm SHA256/);
 assert.match(text,/Tesseract installer integrity check failed/);
 assert.match(text,/TESSERACT-LICENSE\.txt/);
 assert.match(text,/doc\\LICENSE/);
 assert.match(text,/tessdata_fast/);
});
test('protected production review workflows still run for production branch',()=>{
 assert.match(read('.github/workflows/templateforge-windows-review.yml'),/windows\/easy-connect-draft/);
});
test('existing production rollout and reconciliation proofs survive cloud migration',()=>{
 const server=read('staging-school-cloud/server.cjs');
 const reconcile=read('functions/live-sync-reconciliation.js');
 const broker=read('functions/managed-schools.js');
 assert.match(server,/live-sync-rollout'\)\.liveSyncSchools\(env\)/);
 assert.match(reconcile,/edgeProofMatches/);
 assert.match(reconcile,/noticeProofMatches/);
 assert.match(reconcile,/_syncErasePlan/);
 assert.match(broker,/SCRIPT_DELETE_ARCHIVE_GENERATION_REVIEW/);
 assert.match(broker,/readEdgeReceipt/);
 assert.match(broker,/readNoticeReceipt/);
});
test('new document, photo and R2 features retain verifiable school ownership',()=>{
 const broker=read('functions/managed-schools.js');
 const edge=read('functions/cloudflare-delivery.js');
 const r2=read('cloudflare-sync/src/r2-stage.ts');
 for(const name of ['brokerDocumentReplacementStageVersion','brokerPhotoRecordStageVersion',
  'brokerDocumentStageVersion','managed\/document\/stage\/resumable',
  'managed\/record\/media\/stage\/resumable']){
  assert.ok(broker.includes(name.replaceAll('\\','')),'Missing school-bound capability '+name);
 }
 for(const name of ['DOCUMENT_OWNER_CONFLICT','DOCUMENT_OWNER_READ_UNVERIFIED',
  'PHOTO_RECORD_ACK_UNVERIFIED','expectedRecordRevision']){
  assert.ok(edge.includes(name),'Missing signed Drive proof '+name);
 }
 assert.match(r2,/R2_STAGING_ENABLED|r2_staged/);
 assert.match(r2,/sha256/);
});
