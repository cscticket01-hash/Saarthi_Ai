'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {storage,A,B}=require('./helpers/managed-storage');
const G='p-'+'1'.repeat(64),N='p-'+'2'.repeat(64);
const write=(s,collection,id,data,revision='',op='write_operation_0001')=>s.call({action:'managed_records',operation:'write',collection,id,syncProtocol:2,operationId:op,expectedRecordRevision:revision,data:{schoolId:A,...data}});
function rest(s){const calls=[];s.context.ScriptApp={getOAuthToken:()=> 'synthetic-token'};s.context.UrlFetchApp={fetch(url,opt){const id=decodeURIComponent(url.split('/files/')[1].split('?')[0]),file=s.all.get(id);let status=200,body='';
 if(!file)status=404;else if(opt.method==='delete'){calls.push(id);s.all.delete(id);file.trash=true;status=204;}else body=JSON.stringify({id,mimeType:file.mime||'application/vnd.google-apps.folder'});
 return {getResponseCode:()=>status,getContentText:()=>body};}};return calls;}
const deletion=(id,revision,collection='students_directory')=>({action:'managed_records',operation:'delete',collection,id,syncProtocol:2,operationId:'delete_operation_0001',expectedRecordRevision:revision,deleteEverywhereVersion:1});
const read=(s,col)=>s.call({action:'managed_records',operation:'read',collection:col,syncProtocol:2});
test('explicit deletion removes person payload and exact child payloads, preserves receipt/new occupant boundary',()=>{
 const s=storage({lifecycle:true}),a=write(s,'students_directory','one',{name:'Pupil',mobileStableId:G});assert(a.success);rest(s);
 assert(write(s,'fee_payments','fee',{personId:G,studentId:'one',amount:100}).success);
 assert(write(s,'fee_payments','other',{personId:N,studentId:'two',amount:200},'','write_operation_other').success);
 const request=deletion('one',a.recordRevision),r=s.call(request);assert.equal(r.success,true,JSON.stringify(r));assert.equal(r.driveDeletionComplete,true);assert.equal(r.deleteEverywhereVersion,1);
 assert.equal(read(s,'students_directory').records.one.name,undefined);assert.equal(read(s,'fee_payments').records.fee.amount,undefined);assert.equal(read(s,'fee_payments').records.other.amount,200);assert(r.deletionTargets.some(t=>t.collection==='fee_payments'&&t.id==='fee'));
 assert.equal(s.call(request).recordRevision,r.recordRevision);
 assert(write(s,'students_directory','one',{name:'New occupant',mobileStableId:N,replacesStudentGeneration:G},r.recordRevision,'write_new_occupant_0001').success);
 assert.equal(s.call(request).success,false);assert.equal(read(s,'students_directory').records.one.name,'New occupant');
});
test('owned files use permanent Drive delete and exact snapshots are removed instead of recycled',()=>{
 const s=storage({lifecycle:true}),photo=s.roots[A].createFile('Photo','pupil bytes','image/png'),foreign=s.roots[B].createFile('Photo','other bytes','image/png');const calls=rest(s);
 const a=write(s,'students_directory','one',{name:'Pupil',mobileStableId:G,photoFileId:photo.id});assert(a.success);
 const r=s.call(deletion('one',a.recordRevision));assert.equal(r.success,true,JSON.stringify(r));assert(!s.all.has(photo.id));assert(s.all.has(foreign.id));assert.deepEqual(calls,[photo.id]);assert.deepEqual(r.deletedFileIds,[photo.id]);
});
test('shared active file references are retained and never falsely reported deleted',()=>{
 const s=storage({lifecycle:true}),photo=s.roots[A].createFile('Photo','shared','image/png'),calls=rest(s);
 const a=write(s,'students_directory','one',{name:'Pupil',mobileStableId:G,photoFileId:photo.id});assert(a.success);
 assert(write(s,'school_config','shared',{signatureUrl:'https://drive.google.com/file/d/'+photo.id+'/view'}).success);
 const r=s.call(deletion('one',a.recordRevision));assert.equal(r.success,true,JSON.stringify(r));assert(s.all.has(photo.id));assert.equal(calls.length,0);assert.deepEqual(r.deletedFileIds,[]);assert.deepEqual(r.retainedSharedFileIds,[photo.id]);
});
test('partial cascade resumes durable metadata-only plan without reviving any payload',()=>{
 const s=storage({lifecycle:true});rest(s);const a=write(s,'students_directory','one',{name:'Pupil',mobileStableId:G});assert(a.success);
 for(let n=0;n<12;n++)assert(write(s,'fee_payments','fee'+n,{personId:G,studentId:'one',amount:n},'','child_operation_'+n.toString().padStart(5,'0')).success);
 const request=deletion('one',a.recordRevision),first=s.call(request);assert.equal(first.success,false);assert.equal(first.code,'SCRIPT_DELETE_EVERYWHERE_PENDING');
 assert.equal(read(s,'students_directory').records.one.name,undefined);s.restart();rest(s);const done=s.call(request);assert.equal(done.success,true,JSON.stringify(done));assert.equal(done.deletionTargets.length,13);for(let n=0;n<12;n++)assert.equal(read(s,'fee_payments').records['fee'+n].amount,undefined);
});
test('foreign root file never receives a delete request',()=>{
 const s=storage({lifecycle:true}),foreign=s.roots[B].createFile('other','bytes','image/png');rest(s);const a=write(s,'students_directory','one',{name:'Pupil',mobileStableId:G,photoFileId:foreign.id});assert(a.success);assert.equal(s.call(deletion('one',a.recordRevision)).success,false);assert.equal(read(s,'students_directory').records.one.name,'Pupil');assert(s.all.has(foreign.id));
});
test('mixed Sheet backups redact only deleted record, preserving unrelated financial backup',()=>{
 const s=storage({lifecycle:true});rest(s);const a=write(s,'fee_payments','one',{amount:100});assert(a.success);assert(write(s,'fee_payments','other',{amount:200},'','write_operation_other').success);const backup=s.call({action:'managed_backup'});assert(backup.success);
 const r=s.call(deletion('one',a.recordRevision,'fee_payments'));assert.equal(r.success,true,JSON.stringify(r));const sheet=s.books.get(backup.fileId).getSheetByName('fee_payments'),rows=s.context.VS_sheetRecords({school:A,sheet,collection:'fee_payments'});assert.equal(rows.one.amount,undefined);assert.equal(rows.one._syncDeleted,true);assert.equal(rows.other.amount,200);
});

test('archive inventory omits ordinary media but retains every supported archive owner',()=>{
 const s=storage({lifecycle:true});rest(s);
 for(let n=0;n<80;n++)s.roots[A].createFile('Portrait'+n,'photo','image/png');
 const legacy=s.roots[A].createFile('School_Backup_legacy.json','{}','application/json');
 const audit=s.roots[A].createFile('Audit_photo-id.json','{}','application/json');
 const marked=s.roots[A].createFile('Exact.json','{}','application/json');marked.setDescription('VIDYA_RECORD_JSON:'+A+':hash');
 const folder=s.roots[A].createFolder('records_students_directory');
 const record=folder.createFile('legacy.json','{}','application/json');
 const ids=Array.from(s.context.VS_eraseArchiveInventory());
 for(const f of [legacy,audit,marked,record])assert(ids.includes(f.id));
 assert.equal(ids.length,4);
});
test('archive cursor persists once per batch and remains resumable on failure',()=>{
 const s=storage({lifecycle:true});rest(s);const files=[];
 for(let n=0;n<5;n++)files.push(s.roots[A].createFile('School_Backup_'+n,JSON.stringify({schoolId:A,schemaVersion:3,records:{}}),'application/json').id);
 const plan={archiveIds:files,archiveCursor:0,files:[]};let saves=0;
 assert.equal(s.context.VS_eraseExactRecordArchives([],plan,()=>saves++),true);assert.equal(saves,1);assert.equal(plan.archiveCursor,5);
 plan.archiveCursor=0;saves=0;let calls=0;
 s.context.VS_eraseOneRecordArchive=()=>{if(++calls===3)throw Error('synthetic failure');};
 assert.throws(()=>s.context.VS_eraseExactRecordArchives([],plan,()=>saves++),/synthetic failure/);
 assert.equal(plan.archiveCursor,2);assert.equal(saves,1);
});

test('old unfiltered deletion plans skip ordinary media without consuming archive batch slots',()=>{
 const s=storage({lifecycle:true});rest(s);const ids=[];
 for(let n=0;n<70;n++)ids.push(s.roots[A].createFile('photo'+n,'private bytes','image/png').id);
 const plan={archiveIds:ids,archiveCursor:0,files:[]};let saves=0;
 assert.equal(s.context.VS_eraseExactRecordArchives([],plan,()=>saves++),true);assert.equal(plan.archiveCursor,70);assert.equal(saves,1);
 assert(ids.every(id=>s.all.has(id)));
});


test('text-only notice delete skips unrelated school collections and retains verified tombstone',()=>{
 const s=storage({lifecycle:true}),a=write(s,'school_notices','notice-only',{title:'Holiday',description:'Holiday tomorrow'});
 assert(a.success);rest(s);
 const before=s.context.VS_managedSheet,inspected=[];
 s.context.VS_managedSheet=collection=>{inspected.push(collection);return before(collection);};
 const request=deletion('notice-only',a.recordRevision,'school_notices');
 const r=s.call(request);
 assert.equal(r.success,true,JSON.stringify(r));
 assert.equal(r.driveDeletionComplete,true);
 assert(inspected.length>0);
 assert(inspected.every(collection=>collection==='school_notices'),JSON.stringify(inspected));
 const after=read(s,'school_notices').records['notice-only'];
 assert.equal(after._syncDeleted,true);
 assert.equal(after.title,undefined);
 assert.equal(s.call(request).recordRevision,r.recordRevision);
});

test('notice with owned file still checks other collections and preserves shared Drive reference',()=>{
 const s=storage({lifecycle:true}),photo=s.roots[A].createFile('Notice image','bytes','image/png'),calls=rest(s);
 const a=write(s,'school_notices','notice-file',{title:'With image',photoFileId:photo.id});
 assert(a.success);
 assert(write(s,'school_config','shared-image',{signatureUrl:'https://drive.google.com/file/d/'+photo.id+'/view'}).success);
 const before=s.context.VS_managedSheet,inspected=[];
 s.context.VS_managedSheet=collection=>{inspected.push(collection);return before(collection);};
 const r=s.call(deletion('notice-file',a.recordRevision,'school_notices'));
 assert.equal(r.success,true,JSON.stringify(r));
 assert(inspected.includes('school_config'),'shared reference collection was not scanned');
 assert(s.all.has(photo.id),'shared file must never be erased');
 assert.equal(calls.length,0);
 assert.deepEqual(r.retainedSharedFileIds,[photo.id]);
});
