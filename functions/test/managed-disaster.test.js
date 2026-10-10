'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {storage,A}=require('./helpers/managed-storage');
const TEST='vs-db8afb01a3be46a983c8284714d06e5d';
function setup(){const f=storage();f.props.set('VS_MANAGED_SCHOOL_ID',TEST);f.roots[A].getDescription=()=> 'VIDYA_MANAGED_SCHOOL:'+TEST;f.context.VS_enableTestBackupRecovery();return f;}
function row(f,id='notice',col='school_notices',extra={}){return f.context.VS_managedRecord({collection:col,operation:'write',id,syncProtocol:2,operationId:crypto.createHash('sha256').update('disaster/'+col+'/'+id).digest('hex'),expectedRecordRevision:'',data:{schoolId:TEST,title:'Retained',capturedAt:123,...extra}});}
function job(f,operation='backup',fileId){return {operation,operationId:crypto.randomBytes(32).toString('hex'),...(fileId?{fileId}:{})};}
function finish(f,b){let result;for(let n=0;n<200;n++){result=f.context.VS_managedDisaster(b);if(result.complete)return result;}throw Error('bounded TEST job failed to finish');}
test('complete TEST backup and private Sheets/Drive rehearsal preserve records, tombstones, bytes and operation identities',()=>{
 const f=setup();row(f);const fee=row(f,'fee','fee_payments',{amount:321});const document=row(f,'document','documents');
 f.context.VS_managedRecord({collection:'documents',operation:'delete',id:'document',syncProtocol:2,operationId:'disaster_delete_operation_0001',expectedRecordRevision:document.recordRevision});
 const bytes=f.context.VS_managedFolder(f.roots[A],'Files').createFile('existing-QR-card.pdf','original QR bytes','application/pdf');
 const activeBook=f.props.get('VS_MANAGED_SHEET_ID'),before=JSON.stringify(f.context.VS_sheetRecords(f.context.VS_managedSheet('fee_payments')));
 const b=job(f),backup=finish(f,b);assert.equal(backup.verified,true);assert.equal(backup.binaryCount,1);assert.equal(f.context.VS_managedDisaster(b).fileId,backup.fileId,'lost ACK must return identical completed checkpoint');
 const r=job(f,'rehearse',backup.fileId),restored=finish(f,r),state=f.context.VS_disasterRead(restored.fileId);
 assert.equal(restored.verified,true);assert.equal(restored.recordCount,3);assert.equal(restored.activeStorageChanged,false);
 assert.equal(f.context.VS_managedDisaster(r).fileId,restored.fileId);assert.equal(f.all.get(state.copies[0].copyId).getBlob().getDataAsString(),'original QR bytes');
 const tab=f.books.get(state.workbookId).getSheetByName('ArchiveRecords'),rows=tab.getRange(2,1,3,4).getValues();
 const feeData=JSON.parse(rows.find(row=>row[0]==='fee_payments')[3].slice(5));assert.equal(feeData._syncRevision,fee.recordRevision);assert.equal(feeData.capturedAt,123);
 assert.equal(JSON.parse(rows.find(row=>row[0]==='documents')[3].slice(5))._syncDeleted,true);
 assert.equal(f.props.get('VS_MANAGED_SHEET_ID'),activeBook);assert.equal(JSON.stringify(f.context.VS_sheetRecords(f.context.VS_managedSheet('fee_payments'))),before);
 assert.equal(bytes.parent.getName(),'Files');assert.equal(bytes.isTrashed(),false);
});
test('source writes invalidate a partially captured backup without activating it',()=>{
 const f=setup();row(f);const b=job(f);f.context.VS_managedDisaster(b);row(f,'newer');assert.throws(()=>f.context.VS_managedDisaster(b),/source changed/);assert.equal(f.props.get('VS_LAST_VERIFIED_RECORD_BACKUP'),undefined);
});
test('restore rejects corrupt checkpoints, foreign roots and incomplete backups',()=>{
 const f=setup();row(f);const b=job(f),partial=f.context.VS_managedDisaster(b);assert.throws(()=>f.context.VS_managedDisaster(job(f,'rehearse',partial.fileId)),/complete disaster backup/);
 const completed=finish(f,b);f.all.get(completed.fileId).text='corrupt';assert.throws(()=>f.context.VS_managedDisaster(job(f,'rehearse',completed.fileId)),/checkpoint integrity/);
 assert.throws(()=>f.context.VS_managedDisaster(job(f,'rehearse','rootB')),/Foreign school file|not a function/);
});
test('binary tampering blocks verified rehearsal and retains the original source',()=>{
 const f=setup();row(f);const source=f.roots[A].createFile('scan.pdf','verified bytes','application/pdf');const b=finish(f,job(f));
 const archived=f.context.VS_disasterRead(b.fileId);f.all.get(archived.copies[0].copyId).text='altered';const r=job(f,'rehearse',b.fileId);f.context.VS_managedDisaster(r);
 assert.throws(()=>f.context.VS_managedDisaster(r),/source integrity/);assert.equal(source.text,'verified bytes');assert.equal(source.isTrashed(),false);
});
test('concurrent resumption is leased and operation IDs cannot change their source',()=>{
 const f=setup();row(f);const b=finish(f,job(f)),r=job(f,'rehearse',b.fileId);f.context.VS_managedDisaster(r);
 assert.throws(()=>f.context.VS_managedDisaster({...r,fileId:'another'}),/operation ID conflict/);
 const request=job(f);f.props.set('VS_DISASTER_backup_'+request.operationId+'_LEASE',String(Date.now()+60000));assert.throws(()=>f.context.VS_managedDisaster(request),/busy/);
});
test('one step copies at most one binary without holding the school lock',()=>{
 const f=setup();row(f);for(let n=0;n<3;n++)f.roots[A].createFile('file'+n+'.pdf','bytes'+n,'application/pdf');let held=false;
 f.context.LockService={getScriptLock:()=>({waitLock(){assert.equal(held,false);held=true;},releaseLock(){held=false;}})};
 const original=f.context.VS_disasterCopy;f.context.VS_disasterCopy=(...args)=>{assert.equal(held,false);return original(...args);};
 const b=job(f);let prior=0;for(let n=0;n<20;n++){const result=f.context.VS_managedDisaster(b);assert.ok(result.copied-prior<=1);prior=result.copied;if(result.complete)break;}assert.equal(prior,3);
});
test('large records are chunked below Sheets cell limits with identical readback',()=>{
 const f=setup();row(f,'large','school_notices',{body:'x'.repeat(85000)});const b=finish(f,job(f)),r=finish(f,job(f,'rehearse',b.fileId)),state=f.context.VS_disasterRead(r.fileId);
 const sheet=f.books.get(state.workbookId).getSheetByName('ArchiveRecords'),chunks=sheet.getRange(2,1,3,4).getValues();assert.equal(JSON.parse(chunks.map(r=>r[3].slice(5)).join('')).body.length,85000);assert.equal(r.recordCount,1);
});
test('unsupported native files fail closed and original school cannot run any disaster step',()=>{
 const original=storage();assert.throws(()=>original.context.VS_managedDisaster(job(original)),/TEST backup authorization/);
 const f=setup();f.roots[A].createFile('native doc','','application/vnd.google-apps.document');const b=job(f);f.context.VS_managedDisaster(b);assert.throws(()=>f.context.VS_managedDisaster(b),/binary scope requires review/);
});
test('unmigrated legacy JSON cannot be silently omitted or automatically migrated by disaster capture',()=>{
 const f=setup();f.context.VS_managedCollection('school_notices').createFile('legacy.json','retained legacy source','application/json');
 assert.throws(()=>f.context.VS_managedDisaster(job(f)),/Legacy disaster record scope/);
 assert.equal(f.props.get('VS_MANAGED_SHEET_ID'),undefined);
});
test('rehearsal rechecks Sheets rows after writes and safely prefixes formula-like record IDs/JSON chunks',()=>{
 const f=setup();row(f,'=formula');const b=finish(f,job(f)),r=job(f,'rehearse',b.fileId);let state;
 for(let n=0;n<20;n++){const result=f.context.VS_managedDisaster(r);state=f.context.VS_disasterRead(result.fileId);if(state.phase==='recordsVerification')break;}
 assert.equal(state.phase,'recordsVerification');const sheet=f.books.get(state.workbookId).getSheetByName('ArchiveRecords'),rowValues=sheet.getRange(2,1,1,4).getValues()[0];
 assert.equal(rowValues[1],'"=formula"');assert.ok(rowValues[3].startsWith('json:'));sheet.getRange(2,4,1,1).setValues([['altered']]);
 assert.throws(()=>f.context.VS_managedDisaster(r),/Sheets readback failed/);
 assert.equal(f.context.VS_sheetRecords(f.context.VS_managedSheet('school_notices'))['=formula'].title,'Retained');
});
