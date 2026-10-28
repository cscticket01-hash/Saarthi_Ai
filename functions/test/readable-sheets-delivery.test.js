'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {storage,A}=require('./helpers/managed-storage');
const write=(s,col,id,data)=>s.call({action:'managed_records',operation:'write',collection:col,id,data:{schoolId:A,...data}});
const ok=r=>assert.equal(r.success,true,JSON.stringify(r));
function display(s,col){const tab=s.books.get(s.props.get('VS_MANAGED_SHEET_ID')).getSheetByName(col),headers=tab.getRange(1,34,1,tab.getMaxColumns()-33).getValues()[0],row=tab.getRange(2,34,1,headers.length).getValues()[0];return Object.fromEntries(headers.map((k,n)=>[k,row[n]]));}
test('default correct bundle accepts current managed protocol and stores records in Sheets',()=>{const s=storage();s.props.delete('VS_RECORD_STORAGE');ok(write(s,'students_directory','s1',{name:'Synthetic',photoUrl:'https://drive.google.com/file/d/photo/view'}));assert.equal(s.context.VS_jsonEnabled(),false);assert.equal(s.props.has('VS_JSON_HEAD_students_directory'),false);const tab=s.books.get(s.props.get('VS_MANAGED_SHEET_ID')).getSheetByName('students_directory');assert.equal(tab.getRange(2,34,1,1).getValues()[0][0],'Synthetic');assert.equal(tab.getRange(2,39,1,1).getValues()[0][0],'https://drive.google.com/file/d/photo/view');});
test('teachers, attendance, fees, salary, expenses and notices expose saved fields and Drive links',()=>{const s=storage();for(const col of ['teachers_directory','attendance_records','fee_payments','teacher_salary','school_expenses','school_notices']){ok(write(s,col,'one',{name:'Synthetic',amount:45,photoUrl:'https://drive.google.com/file/d/photo/view',pdfUrl:'https://drive.google.com/file/d/pdf/view',customText:'Readable'}));const d=display(s,col);assert.equal(d['Record ID'],'one');assert.equal(d.name,'Synthetic');assert.equal(d.amount,'45');assert.equal(d.photoUrl,'https://drive.google.com/file/d/photo/view');assert.equal(d.pdfUrl,'https://drive.google.com/file/d/pdf/view');assert.equal(d.customText,'Readable');}});
test('edited and deleted records keep one canonical row and refresh visible fields',()=>{const s=storage();ok(write(s,'school_notices','one',{title:'First'}));ok(write(s,'school_notices','one',{title:'Changed',message:'New field'}));assert.equal(display(s,'school_notices').title,'Changed');assert.equal(display(s,'school_notices').message,'New field');ok(s.call({action:'managed_records',operation:'delete',collection:'school_notices',id:'one'}));assert.equal(display(s,'school_notices').title,'');assert.equal(display(s,'school_notices')['Record ID'],'');const r=s.call({action:'managed_records',operation:'read',collection:'school_notices',syncProtocol:2});assert.equal(r.records.one._syncDeleted,true);});
test('owner columns block derived projection while canonical data and ACK are retained',()=>{const s=storage(),store=s.context.VS_managedSheet('school_notices');store.sheet.insertColumnsAfter(33,4);store.sheet.getRange(2,34,1,1).setValues([['Owner private cell']]);ok(write(s,'school_notices','one',{title:'Saved canonical'}));assert.equal(store.sheet.getRange(2,34,1,1).getValues()[0][0],'Owner private cell');assert.match(s.props.get('VS_RECORD_READABLE_STATUS_school_notices'),/blocked/);assert.equal(s.call({action:'managed_records',operation:'read',collection:'school_notices'}).records.one.title,'Saved canonical');});
test('text is inert and fields introduced later backfill earlier rows',()=>{const s=storage();ok(write(s,'school_notices','one',{title:'=IMPORTXML("bad")'}));ok(write(s,'school_notices','two',{title:'Second',extra:'New'}));ok(s.call({action:'managed_records',operation:'read',collection:'school_notices'}));const d=display(s,'school_notices');assert.equal(d.title,"'=IMPORTXML(\"bad\")");assert.equal(d.extra,'');});
test('existing JSON cutover is retained rather than silently selecting stale Sheets',()=>{const s=storage({json:true});ok(write(s,'school_notices','one',{title:'Retain'}));s.props.delete('VS_RECORD_STORAGE');assert.equal(s.context.VS_jsonEnabled(),true);assert.equal(s.call({action:'managed_records',operation:'read',collection:'school_notices'}).records.one.title,'Retain');});
test('actual paste-ready full bundle accepts signed Windows record/photo APIs and displays Drive link',()=>{const s=storage({bundle:true});s.props.delete('VS_RECORD_STORAGE');const uploaded=s.call({action:'managed_upload',name:'synthetic-photo.jpg',mime:'image/jpeg',base64:Buffer.from('synthetic-media').toString('base64'),uploadKey:'synthetic-photo'});ok(uploaded);const file=s.all.get(uploaded.fileId);assert.equal(file.text,'synthetic-media');ok(write(s,'teachers_directory','teacher',{name:'Synthetic',photoUrl:uploaded.fileUrl}));assert.equal(display(s,'teachers_directory').photoUrl,uploaded.fileUrl);const h=s.call({action:'managed_health'});ok(h);assert.equal(h.recordSyncVersion,2);assert.equal(h.recordStorageVersion,1);assert.equal(h.jsonSchemaVersion,0);});
test('later dynamic fields do not overwrite owner cells under blank headers',()=>{const s=storage();ok(write(s,'school_notices','one',{title:'First'}));const store=s.context.VS_managedSheet('school_notices'),next=store.sheet.getMaxColumns()+1;store.sheet.insertColumnsAfter(store.sheet.getMaxColumns(),1);store.sheet.getRange(2,next,1,1).setValues([['Owner notes']]);ok(write(s,'school_notices','one',{title:'Updated',newField:'Must not overwrite'}));assert.equal(store.sheet.getRange(2,next,1,1).getValues()[0][0],'Owner notes');assert.match(s.props.get('VS_RECORD_READABLE_STATUS_school_notices'),/blocked/);});
test('dynamic application field names cannot become Sheet formulas',()=>{const s=storage();ok(write(s,'school_notices','one',{'=IMPORTXML("bad")':'Safe field value',title:'Notice'}));assert.equal(display(s,'school_notices')['Field: =IMPORTXML("bad")'],'Safe field value');});

test('signed deletes clear the entire visible row and repair old ID-only projections without losing deletion evidence',()=>{
 for(const col of ['teachers_directory','school_notices','school_expenses']) {
  const s=storage({bundle:true});
  const created=s.call({action:'managed_records',operation:'write',collection:col,id:'one',syncProtocol:2,
   operationId:'create-'+col,expectedRecordRevision:'',data:{schoolId:A,name:'Synthetic',title:'Saved'}});
  ok(created);
  const removed=s.call({action:'managed_records',operation:'delete',collection:col,id:'one',syncProtocol:2,
   operationId:'delete-'+col,expectedRecordRevision:created.recordRevision});
  ok(removed);
  assert.ok(Object.values(display(s,col)).every(v=>v===''));
  const before=s.call({action:'managed_records',operation:'read',collection:col,syncProtocol:2}).records.one;
  assert.equal(before._syncDeleted,true);assert.equal(before._syncOperationId,'delete-'+col);
  const bookId=s.props.get('VS_MANAGED_SHEET_ID'),tab=s.books.get(bookId).getSheetByName(col);
  tab.getRange(2,34,1,1).setValues([['one']]);
  const viewKey=[...s.props.keys()].find(k=>k.startsWith('VS_RECORD_VIEW_FIELDS_')&&k.endsWith(':'+col));
  s.props.set(viewKey+'_cursor','2');
  const after=s.call({action:'managed_records',operation:'read',collection:col,syncProtocol:2}).records.one;
  assert.ok(Object.values(display(s,col)).every(v=>v===''));
  assert.deepEqual(after,before);
 }
});

test('teacher readable view omits card numbers but preserves canonical identity and personal details',()=>{
 for(const bundle of [false,true]){
  const s=storage({bundle});
  ok(write(s,'teachers_directory','t1',{teacherId:'INTERNAL-1',name:'Teacher',fatherName:'Father',dateOfBirth:'02/03/1988',subject:'Maths',address:'Silchar'}));
  const d=display(s,'teachers_directory');
  assert.equal(d.teacherId,undefined);assert.equal(d.fatherName,'Father');assert.equal(d.dateOfBirth,'02/03/1988');assert.equal(d.subject,'Maths');assert.equal(d.address,'Silchar');
  assert.equal(s.call({action:'managed_records',operation:'read',collection:'teachers_directory'}).records.t1.teacherId,'INTERNAL-1');
  // Simulate the generated visible column from the previous bundle.
  const tab=s.context.VS_managedSheet('teachers_directory').sheet;
  const key=[...s.props.keys()].find(k=>k.startsWith('VS_RECORD_VIEW_FIELDS_')&&k.endsWith(':teachers_directory'));
  const fields=JSON.parse(s.props.get(key)),column=35+fields.length;fields.push('teacherId');s.props.set(key,JSON.stringify(fields));
  if(tab.getMaxColumns()<column)tab.insertColumnsAfter(tab.getMaxColumns(),column-tab.getMaxColumns());
  tab.getRange(1,column,2,1).setValues([['teacherId'],['INTERNAL-1']]);
  const before=s.call({action:'managed_records',operation:'read',collection:'teachers_directory'}).records.t1;
  assert.deepEqual(tab.getRange(1,column,2,1).getValues(),[[''],['']]);
  const after=s.call({action:'managed_records',operation:'read',collection:'teachers_directory'}).records.t1;
  assert.deepEqual(after,before);assert.equal(after.teacherId,'INTERNAL-1');
  assert.equal(display(s,'teachers_directory').fatherName,'Father');
 }
});
