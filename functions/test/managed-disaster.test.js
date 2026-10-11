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
function auditRequest(fileId,operationId=crypto.randomBytes(32).toString('hex')){return {fileId,operationId};}
function auditFinish(f,b){let result;for(let n=0;n<200;n++){result=f.context.VS_managedDisasterReadback(b);if(result.complete)return result;}throw Error('bounded TEST audit failed to finish');}
function completedRehearsal(f){const backup=finish(f,job(f));return finish(f,job(f,'rehearse',backup.fileId));}
test('fresh completed audit verifies Sheets and binaries without creating or changing files',()=>{
 const f=setup();const ack=row(f);f.roots[A].createFile('photo.jpg','retained-photo-original','image/jpeg');
 const completed=completedRehearsal(f),state=f.context.VS_disasterRead(completed.fileId);
 const priorFiles=[...f.all.values()].filter(x=>x.text!==undefined).map(x=>[x.getId(),x.text,x.getDescription()]),fileCount=f.all.size,books=f.books.size;
 const b=auditRequest(completed.fileId),result=auditFinish(f,b);
 assert.equal(result.readbackVersion,1);assert.equal(result.complete,true);assert.equal(result.verified,true);assert.equal(result.checkedRows,result.rowCount);assert.equal(result.checkedBinaries,1);assert.equal(result.binaryCount,1);assert.equal(result.recordCount,1);
 assert.equal(result.readOnly,true);assert.equal(result.activeStorageChanged,false);assert.equal(result.scope,'completed_rehearsal_rows_and_bytes');assert.ok(result.verifiedAt>=result.startedAt);
 const repeated=f.context.VS_managedDisasterReadback(b);assert.equal(repeated.verifiedAt,result.verifiedAt,'same audit must retain actual verification time');
 assert.equal(f.all.size,fileCount);assert.equal(f.books.size,books);assert.deepEqual([...f.all.values()].filter(x=>x.text!==undefined).map(x=>[x.getId(),x.text,x.getDescription()]),priorFiles);
 const original=f.context.VS_sheetRecords(f.context.VS_managedSheet('school_notices')).notice;assert.equal(original._syncRevision,ack.recordRevision);assert.equal(original.capturedAt,123);assert.equal(state.complete,true);
});
test('fresh audit rejects corrupted completed Sheets instead of trusting an old success',()=>{
 const f=setup();row(f);const completed=completedRehearsal(f),state=f.context.VS_disasterRead(completed.fileId);
 assert.equal(auditFinish(f,auditRequest(completed.fileId)).complete,true);
 f.books.get(state.workbookId).getSheetByName('ArchiveRecords').getRange(2,4,1,1).setValues([['json:tampered']]);
 assert.throws(()=>f.context.VS_managedDisasterReadback(auditRequest(completed.fileId)),/fresh Sheets readback failed/);
 assert.equal(f.context.VS_disasterRead(completed.fileId).complete,true);
});
test('fresh audit rejects corrupt copied bytes and retains original bytes',()=>{
 const f=setup();row(f);const original=f.roots[A].createFile('scan.pdf','original-readable-pdf','application/pdf'),completed=completedRehearsal(f),state=f.context.VS_disasterRead(completed.fileId);
 const copy=f.all.get(state.copies[0].copyId);copy.text='X'.repeat(copy.text.length);const request=auditRequest(completed.fileId);
 assert.equal(f.context.VS_managedDisasterReadback(request).phase,'binaries');
 assert.throws(()=>f.context.VS_managedDisasterReadback(request),/fresh binary readback failed/);assert.equal(original.text,'original-readable-pdf');assert.equal(original.isTrashed(),false);
});
test('audit resumes bounded rows and binaries outside global lock and preserves lost-response cursor',()=>{
 const f=setup();for(let n=0;n<62;n++)row(f,'notice-'+n);for(let n=0;n<3;n++)f.roots[A].createFile('scan'+n+'.pdf','original'+n,'application/pdf');
 const completed=completedRehearsal(f),b=auditRequest(completed.fileId);let held=false,rowsRead=0,binariesRead=0;
 f.context.LockService={getScriptLock:()=>({waitLock(){assert.equal(held,false);held=true;},releaseLock(){held=false;}})};
 const state=f.context.VS_disasterRead(completed.fileId),tab=f.books.get(state.workbookId).getSheetByName('ArchiveRecords'),range=tab.getRange.bind(tab);
 tab.getRange=(r,c,h,w)=>{const result=range(r,c,h,w),read=result.getValues;result.getValues=()=>{assert.equal(held,false);if(r>1)rowsRead+=h;return read();};return result;};
 for(const entry of state.copies){const file=f.all.get(entry.copyId),getBlob=file.getBlob.bind(file);file.getBlob=()=>{assert.equal(held,false);binariesRead++;return getBlob();};}
 let previousRows=0,previousBinaries=0,result;
 for(let n=0;n<20;n++){
   const beforeRows=rowsRead,beforeBinaries=binariesRead;result=f.context.VS_managedDisasterReadback(b);
   assert.ok(result.checkedRows-previousRows<=25);assert.ok(result.checkedBinaries-previousBinaries<=1);assert.ok(rowsRead-beforeRows<=25);assert.ok(binariesRead-beforeBinaries<=1);
   previousRows=result.checkedRows;previousBinaries=result.checkedBinaries;if(result.complete)break;
 }
 assert.equal(result.complete,true);assert.equal(result.checkedRows,62);assert.equal(result.checkedBinaries,3);
 const before=[rowsRead,binariesRead],repeat=f.context.VS_managedDisasterReadback(b);assert.equal(repeat.verifiedAt,result.verifiedAt);assert.deepEqual([rowsRead,binariesRead],before);
 const fresh=f.context.VS_managedDisasterReadback(auditRequest(completed.fileId));assert.equal(fresh.complete,false);assert.equal(fresh.checkedRows,25);
});
test('audit rejects wrong school incomplete source changed checkpoint and audit ID reuse',()=>{
 const original=storage();assert.throws(()=>original.context.VS_managedDisasterReadback(auditRequest('anything')),/TEST backup authorization/);
 const f=setup();row(f);const backup=finish(f,job(f));assert.throws(()=>f.context.VS_managedDisasterReadback(auditRequest(backup.fileId)),/complete disaster rehearsal/);
 assert.throws(()=>f.context.VS_managedDisasterReadback(auditRequest('rootB')),/Foreign school file|not a function/);
 const completed=finish(f,job(f,'rehearse',backup.fileId)),audit=auditRequest(completed.fileId);f.context.VS_managedDisasterReadback(audit);
 const other=finish(f,job(f,'rehearse',backup.fileId));assert.throws(()=>f.context.VS_managedDisasterReadback({...audit,fileId:other.fileId}),/operation ID conflict/);
 const file=f.all.get(completed.fileId),state=JSON.parse(file.text);state.createdAt++;file.text=JSON.stringify(state);file.setDescription('VIDYA_DISASTER:'+TEST+':'+f.context.VS_layoutHash(file.text));
 assert.throws(()=>f.context.VS_managedDisasterReadback(audit),/operation ID conflict/);
});
test('audit enforces workbook identity row count and bounded retained diagnostic state',()=>{
 const f=setup();row(f);const completed=completedRehearsal(f),state=f.context.VS_disasterRead(completed.fileId),book=f.all.get(state.workbookId),description=book.getDescription();
 book.setDescription('foreign marker');assert.throws(()=>f.context.VS_managedDisasterReadback(auditRequest(completed.fileId)),/workbook identity/);book.setDescription(description);
 const sheet=f.books.get(state.workbookId).getSheetByName('ArchiveRecords');sheet.getRange(3,1,1,4).setValues([['extra','"unlisted"',0,'json:{}']]);assert.throws(()=>f.context.VS_managedDisasterReadback(auditRequest(completed.fileId)),/fresh Sheets readback/);
 for(let n=0;n<25;n++)f.props.set('VS_DISASTER_READBACK_'+crypto.createHash('sha256').update('audit'+n).digest('hex'),'retained');
 assert.throws(()=>f.context.VS_managedDisasterReadback(auditRequest(completed.fileId)),/audit inventory requires review/);
 assert.equal(f.props.get('VS_DISASTER_READBACK_'+crypto.createHash('sha256').update('audit0').digest('hex')),'retained');
 const file=f.all.get(completed.fileId);file.text='corrupt';assert.throws(()=>f.context.VS_disasterRead(completed.fileId),/checkpoint integrity/);
});
test('readback validates backup collection names without provisioning a collection folder',()=>{
 const f=setup();row(f);const completed=completedRehearsal(f),before=f.all.size;
 f.context.VS_managedCollection=()=>{throw Error('Read-only audit attempted folder provisioning');};
 assert.equal(auditFinish(f,auditRequest(completed.fileId)).complete,true);assert.equal(f.all.size,before);
});
test('record backup content changes and foreign scope reject an in-progress audit',()=>{
 const f=setup();for(let n=0;n<26;n++)row(f,'record-'+n);const completed=completedRehearsal(f),state=f.context.VS_disasterRead(completed.fileId),b=auditRequest(completed.fileId);
 assert.equal(f.context.VS_managedDisasterReadback(b).checkedRows,25);
 const backup=f.all.get(state.recordBackupId),data=JSON.parse(backup.text);data.createdAt++;backup.text=JSON.stringify(data);backup.setDescription('VIDYA_RECORD_BACKUP:'+TEST+':'+f.context.VS_layoutHash(backup.text));
 assert.throws(()=>f.context.VS_managedDisasterReadback(b),/operation ID conflict/);
 data.scope='unknown_archive';backup.text=JSON.stringify(data);backup.setDescription('VIDYA_RECORD_BACKUP:'+TEST+':'+f.context.VS_layoutHash(backup.text));
 assert.throws(()=>f.context.VS_managedDisasterReadback(auditRequest(completed.fileId)),/backup scope requires review/);
});
test('readback lease rejects overlap and never releases another owner token',()=>{
 const f=setup();row(f);const completed=completedRehearsal(f),b=auditRequest(completed.fileId),key='VS_DISASTER_READBACK_'+b.operationId;
 f.props.set(key+'_LEASE',String(Date.now()+60000));assert.throws(()=>f.context.VS_managedDisasterReadback(b),/readback busy/);assert.equal(f.props.get(key),undefined);f.props.delete(key+'_LEASE');
 const state=f.context.VS_disasterRead(completed.fileId),tab=f.books.get(state.workbookId).getSheetByName('ArchiveRecords'),range=tab.getRange.bind(tab);
 tab.getRange=(...args)=>{const result=range(...args),read=result.getValues;result.getValues=()=>{f.props.set(key+'_LEASE_TOKEN','other-owner');return read();};return result;};
 assert.throws(()=>f.context.VS_managedDisasterReadback(b),/lease expired/);assert.equal(f.props.get(key),undefined);assert.equal(f.props.get(key+'_LEASE_TOKEN'),'other-owner');assert.ok(Number(f.props.get(key+'_LEASE'))>Date.now());
});
test('audit rejects previously checked worksheet row changes between bounded pages and before cached completion',()=>{
 const f=setup();for(let n=0;n<26;n++)row(f,'record-'+n);const completed=completedRehearsal(f),state=f.context.VS_disasterRead(completed.fileId),sheet=f.books.get(state.workbookId).getSheetByName('ArchiveRecords');
 const b=auditRequest(completed.fileId),first=f.context.VS_managedDisasterReadback(b);assert.equal(first.checkedRows,25);
 const original=sheet.getRange(2,4,1,1).getValues();sheet.getRange(2,4,1,1).setValues([['json:earlier_checked_row_changed']]);
 assert.throws(()=>f.context.VS_managedDisasterReadback(b),/workbook changed/);
 assert.equal(JSON.parse(f.props.get('VS_DISASTER_READBACK_'+b.operationId)).checkedRows,25,'changed workbook cannot advance its cursor');
 sheet.getRange(2,4,1,1).setValues(original);const newAudit=auditRequest(completed.fileId);assert.equal(auditFinish(f,newAudit).complete,true);
 sheet.getRange(2,4,1,1).setValues([['json:changed_after_complete']]);assert.throws(()=>f.context.VS_managedDisasterReadback(newAudit),/workbook changed/);
});
test('audit fails closed on unavailable worksheet generation and on changes during a page read',()=>{
 const f=setup();row(f);const completed=completedRehearsal(f),state=f.context.VS_disasterRead(completed.fileId),file=f.all.get(state.workbookId),getLastUpdated=file.getLastUpdated;
 file.getLastUpdated=()=>null;assert.throws(()=>f.context.VS_managedDisasterReadback(auditRequest(completed.fileId)),/generation unavailable/);file.getLastUpdated=getLastUpdated;
 const b=auditRequest(completed.fileId),sheet=f.books.get(state.workbookId).getSheetByName('ArchiveRecords'),range=sheet.getRange.bind(sheet);
 sheet.getRange=(...args)=>{const result=range(...args),read=result.getValues;result.getValues=()=>{file.modifiedAt++;return read();};return result;};
 assert.throws(()=>f.context.VS_managedDisasterReadback(b),/workbook changed/);assert.equal(f.props.get('VS_DISASTER_READBACK_'+b.operationId),undefined,'no partial cursor is committed for a changing worksheet');
});
test('audit inventory cap reserves active distinct owners and ignores expired leases and token keys without purge',()=>{
 const f=setup();row(f);const completed=completedRehearsal(f),prefix='VS_DISASTER_READBACK_';
 for(let n=0;n<24;n++)f.props.set(prefix+crypto.createHash('sha256').update('retained-cap-'+n).digest('hex'),'retained');
 const active=prefix+crypto.createHash('sha256').update('active-cap').digest('hex');f.props.set(active+'_LEASE',String(Date.now()+60000));f.props.set(active+'_LEASE_TOKEN','active-owner');
 assert.throws(()=>f.context.VS_managedDisasterReadback(auditRequest(completed.fileId)),/audit inventory requires review/);
 f.props.set(active+'_LEASE',String(Date.now()-1000));
 const expiredValue=f.props.get(active+'_LEASE'),request=auditRequest(completed.fileId);assert.equal(f.context.VS_managedDisasterReadback(request).checkedRows,1);
 assert.equal(f.props.get(active+'_LEASE'),expiredValue);assert.equal(f.props.get(active+'_LEASE_TOKEN'),'active-owner');
 assert.throws(()=>f.context.VS_managedDisasterReadback(auditRequest(completed.fileId)),/audit inventory requires review/);
 assert.equal(auditFinish(f,request).complete,true,'existing committed audit may resume at the cap');
});
