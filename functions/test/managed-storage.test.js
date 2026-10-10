'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict'),crypto=require('node:crypto'),fs=require('node:fs'),vm=require('node:vm');
const secret='d'.repeat(64);
const {storage,A,B}=require('./helpers/managed-storage');
test('document compare-and-set preserves newer edits and refuses unversioned overwrites/deletes',()=>{
 const f=storage(),write=(revision,expected)=>f.call({action:'managed_records',operation:'write',collection:'documents',id:'DOC-1',expectedRevision:expected,data:{schoolId:A,studentId:'S-1',documentRevision:revision}});
 assert.equal(write('first','').success,true);
 assert.equal(write('stale','').success,false);
 assert.equal(write('second','first').success,true);
 assert.equal(f.call({action:'managed_records',operation:'write',collection:'documents',id:'DOC-1',data:{schoolId:A,documentRevision:'unsafe'}}).success,false);
 assert.equal(f.call({action:'managed_records',operation:'delete',collection:'documents',id:'DOC-1',expectedRevision:'first'}).success,false);
 assert.equal(f.call({action:'managed_records',operation:'read',collection:'documents'}).records['DOC-1'].documentRevision,'second');
 assert.equal(f.call({action:'managed_records',operation:'write',collection:'documents',id:'DOC-1',createOnly:true,data:{schoolId:A,documentRevision:'backup'}}).skipped,true);
 assert.equal(f.call({action:'managed_records',operation:'delete',collection:'documents',id:'DOC-1',expectedRevision:'second'}).success,true);
});
test('upload retries reuse one own-school immutable file and reject changed content with the same key',()=>{
 const f=storage(),body={action:'managed_upload',name:'Document_own.jpg',mime:'image/jpeg',base64:Buffer.from('own bytes').toString('base64'),uploadKey:'own-revision'};
 const first=f.call(body),second=f.call(body);
 assert.equal(first.success,true);assert.equal(second.fileId,first.fileId);
 assert.equal(f.call({...body,base64:Buffer.from('changed').toString('base64')}).success,false);
 assert.equal(f.call({action:'managed_health'}).documentVersions,1);
});
test('GS backup and create-only restore retain current records and reject another school backup',()=>{
 const f=storage(),write=(id,name)=>f.call({action:'managed_records',operation:'write',collection:'students_directory',id,data:{schoolId:A,name}});
 assert.equal(write('student','Original').success,true);
 const backup=f.call({action:'managed_backup'});assert.equal(backup.success,true);assert.equal(JSON.parse(f.all.get(backup.fileId).text).schoolId,A);
 write('student','Edited');
 const restore=f.call({action:'managed_restore',fileId:backup.fileId});assert.equal(restore.success,true);assert.equal(restore.skipped,1);assert.equal(restore.copied,0);
 assert.equal(f.call({action:'managed_records',operation:'read',collection:'students_directory'}).records.student.name,'Edited');
 assert.equal(f.call({action:'managed_records',operation:'delete',collection:'students_directory',id:'student'}).success,true);
 assert.equal(f.call({action:'managed_restore',fileId:backup.fileId}).skipped,1);
 assert.equal(f.call({action:'managed_records',operation:'read',collection:'students_directory'}).records.student,undefined);
 const foreign=f.roots[B].createFile('foreign.json',JSON.stringify({schemaVersion:3,schoolId:B,records:{}}),'application/json');
 assert.equal(f.call({action:'managed_restore',fileId:foreign.getId()}).success,false);
 assert.equal(f.call({action:'managed_file',fileId:foreign.getId()}).success,false);
});
test('GS rejects foreign records and unsigned public requests without writing records',()=>{
 const f=storage();assert.equal(f.call({action:'managed_records',operation:'write',collection:'students_directory',id:'bad',data:{schoolId:B,name:'Foreign'}}).success,false);
 assert.deepEqual(f.call({action:'managed_records',operation:'read',collection:'students_directory'}).records,{});
 const bundle=fs.readFileSync('../school-backend/managed/SaarthiManagedAll.gs','utf8');assert.equal((bundle.match(/function doPost\(/g)||[]).length,1);assert.match(bundle,/function doPost\(e\) \{ return VS_managedHandle\(e\); \}/);
});

test('managed mobile reuses existing QR verification and never exposes another pupil records',()=>{
 const f=storage();const write=(col,id,data)=>f.call({action:'managed_records',operation:'write',collection:col,id,data:{...data,schoolId:A}});
 write('students_directory','pupil',{name:'Own pupil',class:'Class 1',rollNo:'1',dob:'2015-01-01',mobileLinkToken:'x'.repeat(48)});
 write('exam_results','own',{personId:'pupil',marks:90});write('exam_results','foreign',{personId:'other',marks:15});
 const mobile=request=>f.call({action:'managed_mobile',lease:{schoolId:A,expiresAt:Date.now()+60000},request});
 const login={action:'mobile_login',role:'student',personId:'pupil',linkToken:'x'.repeat(48),studentClass:'Class 1',rollNo:'1',dob:'2015-01-01'};
 assert.equal(mobile({...login,linkToken:'y'.repeat(48)}).success,false);assert.equal(mobile({...login,dob:'2010-01-01'}).success,false);
 const session=mobile(login);assert.equal(session.success,true);assert.equal(session.projectId,A);assert.equal(session.person.mobileLinkToken,undefined);
 const dashboard=mobile({action:'mobile_dashboard',sessionToken:session.sessionToken});assert.equal(dashboard.success,true);assert.equal(dashboard.reportCards.length,1);assert.equal(dashboard.reportCards[0].marks,90);
 assert.equal(f.call({action:'managed_mobile',lease:{schoolId:B,expiresAt:Date.now()+60000},request:login}).success,false);
 write('students_directory','pupil',{name:'Own pupil',mobileLinkToken:'z'.repeat(48)});assert.equal(mobile({action:'mobile_dashboard',sessionToken:session.sessionToken}).success,false);
});
test('mobile dashboard reuses verified workbook only within its locked request and revalidates next request',()=>{
 const f=storage();const write=(collection,id,data)=>f.call({action:'managed_records',operation:'write',collection,id,data:{...data,schoolId:A}});
 write('students_directory','pupil',{name:'Own pupil',class:'1',rollNo:'1',dob:'2015-01-01',mobileLinkToken:'x'.repeat(48)});
 const mobile=request=>f.call({action:'managed_mobile',lease:{schoolId:A,expiresAt:Date.now()+60000},request});
 const login=mobile({action:'mobile_login',role:'student',personId:'pupil',linkToken:'x'.repeat(48),studentClass:'1',rollNo:'1',dob:'2015-01-01'});
 const request={action:'mobile_dashboard',sessionToken:login.sessionToken};assert.equal(mobile(request).success,true);
 const open=f.context.SpreadsheetApp.openById;let opens=0;f.context.SpreadsheetApp.openById=id=>{opens++;return open(id);};
 assert.equal(mobile(request).success,true);assert.equal(opens,1,'one ancestry/marker verified shared workbook per legacy dashboard');
 write('school_notices','new',{title:'New cloud notice'});assert.equal(mobile(request).notices[0].title,'New cloud notice');
 f.all.get(f.props.get('VS_MANAGED_SHEET_ID')).setDescription('VIDYA_SCHOOL_DATA:'+B);
 assert.equal(mobile(request).success,false,'never reuse verification across requests');
});
test('exam centre result delta reaches only its pupil, deduplicates dual writes and retains deletion',()=>{
 const f=storage();
 const write=(collection,id,data)=>f.call({action:'managed_records',operation:'write',collection,id,data:{...data,schoolId:A}});
 write('students_directory','pupil',{name:'Own pupil',class:'Class 1',rollNo:'1',dob:'2015-01-01',mobileLinkToken:'x'.repeat(48)});
 const mobile=request=>f.call({action:'managed_mobile',lease:{schoolId:A,expiresAt:Date.now()+60000},request});
 const login=mobile({action:'mobile_login',role:'student',personId:'pupil',linkToken:'x'.repeat(48),studentClass:'Class 1',rollNo:'1',dob:'2015-01-01'});
 const request={action:'mobile_dashboard',sessionToken:login.sessionToken};
 const first=mobile(request);assert.equal(first.success,true);
 write('exam_center_results','exam_pupil',{examId:'exam',personId:'pupil',marks:90,timestamp:1});
 write('exam_center_results','exam_foreign',{examId:'exam',personId:'other',marks:15});
 const changed=mobile({...request,knownRevisions:first.revisions});
 assert.equal(changed.reportCards.length,1);assert.equal(changed.reportCards[0].marks,90);
 const same=mobile({...request,knownRevisions:changed.revisions,knownRevision:changed.revision});assert.equal(same.unchanged,true);
 write('exam_results','exam_pupil',{examId:'exam',personId:'pupil',marks:95,timestamp:2});
 const dual=mobile({...request,knownRevisions:changed.revisions});assert.equal(dual.reportCards.length,1);assert.equal(dual.reportCards[0].marks,95);
 assert.equal(f.call({action:'managed_records',operation:'delete',collection:'exam_results',id:'exam_pupil'}).success,true);
 const deleted=mobile({...request,knownRevisions:dual.revisions});assert.equal(deleted.reportCards.length,0);
});
test('owner inventory only reads the verified root and never creates or moves storage',()=>{
 const source=fs.readFileSync('../school-backend/managed/SaarthiManagedAdapter.gs','utf8');
 const iterator=items=>{let i=0;return{hasNext:()=>i<items.length,next:()=>items[i++]};};
 const child={getId:()=> 'photos',getName:()=> 'Student_Photos',getFolders:()=>iterator([]),getFiles:()=>iterator([{getId:()=> 'photo-id',getName:()=> 'photo.png',getMimeType:()=> 'image/png',getSize:()=>123}])};
 const root={getId:()=> 'verified-root',getFolders:()=>iterator([child]),getFiles:()=>iterator([])};
 const context=vm.createContext({PropertiesService:{getScriptProperties:()=>({getProperty:key=>({'VS_MANAGED_SCHOOL_ID':A,'VS_MANAGED_SHEET_ID':'existing-book'})[key]})}});
 vm.runInContext(source,context);context.VS_managedRoot=()=>root;
 const out=context.VS_inventoryManagedStorage();
 assert.equal(out.schoolId,A);assert.equal(out.rootFolderId,'verified-root');assert.equal(out.workbookId,'existing-book');assert.equal(out.partial,false);
 assert.equal(out.files.length,1);assert.equal(out.files[0].id,'photo-id');assert.equal(out.files[0].parentId,'photos');
 assert.equal(JSON.stringify(out).includes('secret'),false);
 assert(!source.includes("b.action==='managed_inventory'"));
});
test('managed summary measures own root only and includes actual student count',()=>{
 const f=storage();f.call({action:'managed_records',operation:'write',collection:'students_directory',id:'pupil',data:{schoolId:A,name:'A'}});f.roots[A].createFile('own','own-data','text/plain');f.roots[B].createFile('foreign','foreign-school-data','text/plain');
 const result=f.call({action:'managed_summary'});assert.equal(result.success,true);assert.equal(result.studentCount,1);assert(result.driveBytes>0);assert.equal(result.partial,false);
});

test('managed GPS attendance keeps school-selected 25–200m range and rejects missing/inaccurate location',()=>{
 const f=storage();const write=(col,id,data)=>f.call({action:'managed_records',operation:'write',collection:col,id,data:{...data,schoolId:A}});
 write('teachers_directory','teacher',{name:'Own teacher',mobileLinkToken:'x'.repeat(48)});write('school_calendar','2026-10-05',{isOpen:true});write('school_settings','school_location',{latitude:0,longitude:0,radiusMeters:25});
 const mobile=request=>f.call({action:'managed_mobile',lease:{schoolId:A,expiresAt:Date.now()+60000},request});
 const session=mobile({action:'mobile_login',role:'teacher',personId:'teacher',linkToken:'x'.repeat(48)});
 const attendance={action:'mobile_mark_attendance',sessionToken:session.sessionToken,role:'teacher',personId:'teacher',linkToken:'x'.repeat(48),latitude:0,longitude:0};
 assert.equal(mobile(attendance).success,false);assert.equal(mobile({...attendance,accuracy:100}).success,false);assert.equal(mobile({...attendance,latitude:1,accuracy:5}).success,false);
 assert.equal(mobile({...attendance,accuracy:5}).success,true);assert.equal(mobile({...attendance,accuracy:5}).success,false);
 const exit=mobile({...attendance,accuracy:5,mode:'exit',operationId:'f'.repeat(64)});assert.equal(exit.success,true);assert.equal(mobile({...attendance,accuracy:5,mode:'exit',operationId:'f'.repeat(64)}).success,true);
});
test('generated school bundle retains managed mobile, summary and preparation implementations',()=>{
 const bundle=fs.readFileSync('../school-backend/managed/SaarthiManagedAll.gs','utf8');
 for(const source of ['SaarthiManagedAdapter.gs','SaarthiManagedMobile.gs'])assert(bundle.includes(fs.readFileSync('../school-backend/managed/'+source,'utf8')));
 assert.match(bundle,/function VS_prepareSchoolStorage\(/);assert.match(bundle,/function VS_managedMobile\(/);assert.match(bundle,/function VS_managedSummary\(/);
});

test('exact Windows/Android shared QR fixtures login student and teacher through signed GS and reject cross-school or wrong credentials',()=>{
 const fixtures=JSON.parse(fs.readFileSync('../test/fixtures/windows_person_qr.json','utf8'));
 for(const qr of fixtures){
  const f=storage(),collection=qr.type==='student'?'students_directory':'teachers_directory';
  assert.equal(f.call({action:'managed_records',operation:'write',collection,id:qr.personId,data:{schoolId:A,name:qr.name,class:'Class 1',rollNo:'1',dob:'2015-01-01',mobileLinkToken:qr.linkToken}}).success,true);
  const request={action:'mobile_login',role:qr.type,personId:qr.personId,linkToken:qr.linkToken,studentClass:qr.class||'',rollNo:qr.rollNo||'',dob:'2015-01-01'};
  const mobile=(request,school=A)=>f.call({action:'managed_mobile',lease:{schoolId:school,expiresAt:Date.now()+60000},request});
  assert.equal(mobile({...request,linkToken:'wrong-token'}).success,false);
  if(qr.type==='student')assert.equal(mobile({...request,dob:'2010-01-01'}).success,false);
  assert.equal(mobile(request,B).success,false);
  const result=mobile(request);assert.equal(result.success,true);assert.equal(result.schoolId,qr.schoolId);assert.equal(result.projectId,qr.schoolId);
  assert.equal(mobile({action:'mobile_dashboard',sessionToken:result.sessionToken}).success,true);
 }
});

test('revision-aware two-PC sync is idempotent, preserves conflicts and tombstones',()=>{
 const f=storage(),id='pupil',write=(operationId,base,name)=>f.call({action:'managed_records',operation:'write',collection:'students_directory',id,syncProtocol:2,operationId,expectedRecordRevision:base,data:{schoolId:A,name}});
 const first=write('operation-0000000000000001','','PC1');assert.equal(first.success,true);
 const duplicate=write('operation-0000000000000001','','PC1');assert.equal(duplicate.recordRevision,first.recordRevision);
 const changedRetry=write('operation-0000000000000001','','Changed payload');
 assert.equal(changedRetry.success,false);assert.equal(changedRetry.message,'Sync operation ID conflict');
 assert.equal(f.call({action:'managed_records',operation:'delete',collection:'students_directory',id,syncProtocol:2,operationId:'operation-0000000000000001',expectedRecordRevision:first.recordRevision}).success,false);
 const snapshot=f.call({action:'managed_records',operation:'read',collection:'students_directory',syncProtocol:2});
 assert.equal(snapshot.records.pupil.name,'PC1');assert.equal(snapshot.records.pupil._syncRevision,first.recordRevision);
 const unchanged=f.call({action:'managed_records',operation:'read',collection:'students_directory',syncProtocol:2,knownRevision:snapshot.collectionRevision});
 assert.equal(unchanged.unchanged,true);assert.deepEqual(unchanged.records,{});
 const second=write('operation-0000000000000002',first.recordRevision,'PC2');assert.equal(second.success,true);
 assert.equal(write('operation-0000000000000003',first.recordRevision,'Stale PC1').success,false);
 const deletion=f.call({action:'managed_records',operation:'delete',collection:'students_directory',id,syncProtocol:2,operationId:'operation-0000000000000004',expectedRecordRevision:second.recordRevision});assert.equal(deletion.success,true);
 assert.equal(f.call({action:'managed_records',operation:'read',collection:'students_directory'}).records.pupil,undefined);
 assert.equal(f.call({action:'managed_records',operation:'read',collection:'students_directory',syncProtocol:2}).records.pupil._syncDeleted,true);
 assert.equal(write('operation-0000000000000005',second.recordRevision,'Resurrection').success,false);
 const replay=f.call({action:'managed_records',operation:'delete',collection:'students_directory',id,syncProtocol:2,operationId:'operation-0000000000000004',expectedRecordRevision:second.recordRevision});assert.equal(replay.recordRevision,deletion.recordRevision);
});
test('incremental manifest rejects foreign data even for versioned writes',()=>{
 const f=storage();const result=f.call({action:'managed_records',operation:'write',collection:'school_notices',id:'n',syncProtocol:2,operationId:'operation-0000000000000001',expectedRecordRevision:'',data:{schoolId:B,title:'Foreign'}});
 assert.equal(result.success,false);assert.deepEqual(f.call({action:'managed_records',operation:'read',collection:'school_notices'}).records,{});
 assert.equal(f.call({action:'managed_health'}).recordSyncVersion,2);
});

test('document deletion retains explicit tombstone across PCs and blocks stale resurrection',()=>{
 const f=storage(),base={action:'managed_records',collection:'documents',id:'gone'};
 assert.equal(f.call({...base,operation:'write',expectedRevision:'',data:{schoolId:A,documentRevision:'r1'}}).success,true);
 assert.equal(f.call({...base,operation:'delete',expectedRevision:'r1'}).success,true);
 assert.equal(f.call({...base,operation:'delete',expectedRevision:'r1'}).success,true);
 assert.equal(f.call({...base,operation:'read'}).records.gone,undefined);
 assert.equal(f.call({...base,operation:'read',syncProtocol:2}).records.gone._syncDeleted,true);
 assert.equal(f.call({...base,operation:'write',expectedRevision:'r1',data:{schoolId:A,documentRevision:'stale'}}).success,false);
});

test('Windows version-safe notice write -> Android changed group -> unchanged checkpoint -> changed notice',()=>{
 const f=storage(),write=(col,id,data,rev='')=>f.call({action:'managed_records',operation:'write',collection:col,id,syncProtocol:2,operationId:crypto.randomBytes(16).toString('hex'),expectedRecordRevision:rev,data:{schoolId:A,...data}});
 write('students_directory','pupil',{name:'Mohit Das',class:'Class 1',rollNo:'1',dob:'2015-01-01',mobileLinkToken:'a'.repeat(48)});
 const mobile=request=>f.call({action:'managed_mobile',request,lease:{schoolId:A,expiresAt:Date.now()+3600000}});
 const login=mobile({action:'mobile_login',projectId:A,role:'student',personId:'pupil',linkToken:'a'.repeat(48),studentClass:'1',rollNo:'1',dob:'2015-01-01'});assert.equal(login.success,true);
 const saved=write('school_notices','notice-1',{title:'Actual synced notice',timestamp:1});assert.equal(saved.syncProtocol,2);
 write('school_notices','notice-stable',{title:'Unchanged retained notice',timestamp:0});
 const first=mobile({action:'mobile_dashboard',sessionToken:login.sessionToken});assert.equal(first.notices[0].title,'Actual synced notice');
 const unchanged=mobile({action:'mobile_dashboard',sessionToken:login.sessionToken,knownRevision:first.revision,knownRevisions:first.revisions});assert.equal(unchanged.unchanged,true);assert.equal(unchanged.notices,undefined);
 write('school_notices','notice-1',{title:'New revision',timestamp:2},saved.recordRevision);
 const changed=mobile({action:'mobile_dashboard',sessionToken:login.sessionToken,knownRevision:first.revision,knownRevisions:first.revisions,knownNoticeRevisions:Object.fromEntries(first.notices.map(n=>[n.id,n._noticeRevision]))});assert.equal(changed.notices.length,1);assert.equal(changed.noticesDelta,true);assert.equal(changed.noticeIds.length,2);assert.equal(changed.notices[0].title,'New revision');assert.equal(changed.reportCards,undefined);assert.equal(changed.calendar,undefined);
});

test('published school PDF is owner-scoped, versioned, exact-byte readable and unchanged versions transfer no file',()=>{
 const f=storage(),write=(collection,id,data)=>f.call({action:'managed_records',operation:'write',collection,id,data:{schoolId:A,...data}});
 const token='a'.repeat(48);write('students_directory','pupil',{name:'Pupil',class:'Class 1',rollNo:'1',dob:'2015-01-01',mobileLinkToken:token});
 const mobile=request=>f.call({action:'managed_mobile',request,lease:{schoolId:A,expiresAt:Date.now()+3600000}});
 const login=mobile({action:'mobile_login',projectId:A,role:'student',personId:'pupil',linkToken:token,studentClass:'1',rollNo:'1',dob:'2015-01-01'});
 const bytes=Buffer.from('%PDF-1.7\nExact school selected front/back package fixture\n%%EOF'),contentHash=crypto.createHash('sha256').update(bytes).digest('hex');
 const file=f.call({action:'managed_upload',name:'Card.pdf',mime:'application/pdf',base64:bytes.toString('base64'),uploadKey:'published-own-card'});assert.equal(file.success,true);
 write('documents','ID-own',{studentId:'pupil',studentName:'Pupil',ownerRole:'student',documentKind:'idCard',fileId:file.fileId,documentRevision:'v10',contentHash});
 const home=mobile({action:'mobile_dashboard',sessionToken:login.sessionToken});assert.equal(home.idCardPackage.documentRevision,'v10');
 const exact=mobile({action:'mobile_document',sessionToken:login.sessionToken,documentId:'ID-own'});assert.equal(Buffer.from(exact.base64,'base64').toString(),bytes.toString());assert.equal(exact.contentHash,contentHash);
 const unchanged=mobile({action:'mobile_document',sessionToken:login.sessionToken,documentId:'ID-own',knownRevision:'v10'});assert.equal(unchanged.unchanged,true);assert.equal(unchanged.base64,undefined);
 write('documents','ID-foreign',{studentId:'someone-else',ownerRole:'student',documentKind:'idCard',fileId:file.fileId,documentRevision:'v11',contentHash});
 assert.equal(mobile({action:'mobile_document',sessionToken:login.sessionToken,documentId:'ID-foreign'}).success,false);
 const replacement=f.call({action:'managed_records',operation:'write',collection:'documents',id:'ID-own',expectedRevision:'v10',data:{schoolId:A,studentId:'pupil',studentName:'Pupil',ownerRole:'student',documentKind:'idCard',fileId:file.fileId,documentRevision:'v11',contentHash}});assert.equal(replacement.success,true);
 const updated=mobile({action:'mobile_dashboard',sessionToken:login.sessionToken,knownRevisions:home.revisions,knownRevision:home.revision});assert.equal(updated.idCardPackage.documentRevision,'v11');
});

test('organized Sheet backfill verifies records, retains legacy JSON and handles interrupted retry',()=>{
 const f=storage(),folder=f.context.VS_managedCollection('students_directory');
 const legacy=folder.createFile(Buffer.from('legacy').toString('base64url')+'.json',JSON.stringify({id:'legacy',schoolId:A,data:{schoolId:A,name:'Legacy pupil',notes:'x'.repeat(100000)}}),'application/json');
 const read=()=>f.call({action:'managed_records',operation:'read',collection:'students_directory',syncProtocol:2});
 assert.equal(read().records.legacy.notes.length,100000);assert.equal(legacy.trash,undefined);
 assert.equal(folder.getFiles().hasNext(),true);assert.equal(f.books.size,1);
 // Crash before the migration completion marker: verified identical rows backfill once.
 f.props.delete('VS_SHEET_MIGRATED_students_directory');
 assert.equal(read().records.legacy.name,'Legacy pupil');assert.equal(f.books.size,1);
 const book=f.books.get(f.props.get('VS_MANAGED_SHEET_ID'));assert.equal(book.getSheetByName('students_directory').getLastRow(),2);
 assert.equal(f.props.get('VS_MANAGED_ROOT_ID'),'rootA');assert.equal(f.props.get('VS_MANAGED_SECRET'),secret);
});
test('backfill refuses foreign or duplicate source records and preserves both conflict versions',()=>{
 const f=storage(),folder=f.context.VS_managedCollection('school_notices');
 const raw={id:'n',schoolId:A,data:{schoolId:A,title:'Old'}};
 folder.createFile('old.json',JSON.stringify(raw),'application/json');
 assert.equal(f.call({action:'managed_records',operation:'read',collection:'school_notices'}).records.n.title,'Old');
 f.props.delete('VS_SHEET_MIGRATED_school_notices');
 folder.getFiles().next().setContent(JSON.stringify({...raw,data:{schoolId:A,title:'Changed externally'}}));
 assert.equal(f.call({action:'managed_records',operation:'read',collection:'school_notices'}).success,false);
 assert.equal(f.props.get('VS_SHEET_MIGRATED_school_notices'),undefined);
 assert.equal(folder.getFiles().next().trash,undefined);
 const foreign=f.context.VS_managedCollection('teachers_directory');foreign.createFile('foreign.json',JSON.stringify({...raw,schoolId:B}),'application/json');
 assert.equal(f.call({action:'managed_records',operation:'read',collection:'teachers_directory'}).success,false);
});
test('organized binary folders reuse existing root upload IDs without copying or deleting originals',()=>{
 const f=storage(),bytes=Buffer.from('existing'),key='revision-own',name='Existing.pdf';
 const legacy=f.roots[A].createFile(name,bytes.toString(),'application/pdf');legacy.setDescription('VIDYA_UPLOAD:'+A+':'+key+':'+crypto.createHash('sha256').update(bytes).digest('hex'));
 const result=f.call({action:'managed_upload',name,mime:'application/pdf',base64:bytes.toString('base64'),uploadKey:key});
 assert.equal(result.fileId,legacy.getId());assert.equal(legacy.trash,undefined);
 const fresh=f.call({action:'managed_upload',name:'New.pdf',mime:'application/pdf',base64:bytes.toString('base64'),uploadKey:'revision-new'});
 assert.equal(f.all.get(fresh.fileId).parent.getName(),'Documents');assert.equal(f.all.get(fresh.fileId).parent.parent.getName(),'Files');
});
test('document tombstone precedes verified owned-file deletion, crash retry is idempotent, foreign files survive',()=>{
 const f=storage(),id='doc',revision='v1',key=crypto.createHash('sha256').update(id+':'+revision).digest('hex');
 const upload=f.call({action:'managed_upload',name:'Own.pdf',mime:'application/pdf',base64:Buffer.from('%PDF-1.4\n%%EOF').toString('base64'),uploadKey:key});
 const write=f.call({action:'managed_records',operation:'write',collection:'documents',id,syncProtocol:2,operationId:'operation-write-00001',expectedRecordRevision:'',expectedRevision:'',data:{schoolId:A,fileId:upload.fileId,documentRevision:revision}});assert.equal(write.success,true);
 const file=f.all.get(upload.fileId),original=file.setTrashed;
 file.setTrashed=()=>{throw new Error('Drive outage');};
 const body={action:'managed_records',operation:'delete',collection:'documents',id,syncProtocol:2,operationId:'operation-delete-0001',expectedRecordRevision:write.recordRevision,expectedRevision:revision};
 assert.equal(f.call(body).success,false);
 assert.equal(f.call({action:'managed_records',operation:'read',collection:'documents',syncProtocol:2}).records.doc._syncDeleted,true);
 file.setTrashed=original;assert.equal(f.call(body).fileCleanup,'deleted');assert.equal(file.trash,true);
 assert.equal(f.call(body).success,true);
 assert.equal(f.call({action:'managed_records',operation:'write',collection:'documents',id,syncProtocol:2,operationId:'operation-stale-00001',expectedRecordRevision:write.recordRevision,expectedRevision:revision,data:{schoolId:A}}).success,false);
 const foreign=f.roots[B].createFile('B.pdf','school-b','application/pdf');
 f.call({action:'managed_records',operation:'write',collection:'documents',id:'foreign-ref',expectedRevision:'',data:{schoolId:A,fileId:foreign.getId(),documentRevision:'v1'}});
 assert.equal(f.call({action:'managed_records',operation:'delete',collection:'documents',id:'foreign-ref',expectedRevision:'v1'}).success,false);assert.equal(foreign.trash,undefined);
});
test('notice deletion is acknowledged as a tombstone and removes mobile delta even after offline retry',()=>{
 const f=storage();f.call({action:'managed_records',operation:'write',collection:'students_directory',id:'pupil',data:{schoolId:A,name:'Pupil',class:'1',rollNo:'1',dob:'2015-01-01',mobileLinkToken:'x'.repeat(48)}});
 const mobile=request=>f.call({action:'managed_mobile',lease:{schoolId:A,expiresAt:Date.now()+60000},request});
 const login=mobile({action:'mobile_login',role:'student',personId:'pupil',linkToken:'x'.repeat(48),studentClass:'1',rollNo:'1',dob:'2015-01-01'});
 const write=f.call({action:'managed_records',operation:'write',collection:'school_notices',id:'n',syncProtocol:2,operationId:'operation-notice-0001',expectedRecordRevision:'',data:{schoolId:A,title:'Exact Windows notice'}});
 const first=mobile({action:'mobile_dashboard',sessionToken:login.sessionToken});assert.equal(first.notices[0].title,'Exact Windows notice');
 const deletion={action:'managed_records',operation:'delete',collection:'school_notices',id:'n',syncProtocol:2,operationId:'operation-delete-0001',expectedRecordRevision:write.recordRevision};
 assert.equal(f.call(deletion).success,true);assert.equal(f.call(deletion).success,true);
 const next=mobile({action:'mobile_dashboard',sessionToken:login.sessionToken,knownRevisions:first.revisions,knownNoticeRevisions:{n:first.notices[0]._noticeRevision}});
 assert.deepEqual(next.noticeIds,[]);assert.deepEqual(next.notices,[]);
 assert.equal(f.call({action:'managed_health'}).scriptBundleVersion,'2026-10-10.3');
});

test('bounded migration resumes across requests and never activates a partial collection',()=>{
 const f=storage(),folder=f.context.VS_managedCollection('attendance_records');
 for(let n=0;n<103;n++)folder.createFile('legacy-'+n+'.json',JSON.stringify({id:'r'+n,schoolId:A,data:{schoolId:A,personId:'p',date:'2026-10-05',value:n}}),'application/json');
 const body={action:'managed_records',operation:'read',collection:'attendance_records',syncProtocol:2};
 const first=f.call(body);assert.equal(first.success,false);assert.match(first.message,/organization in progress/);assert.equal(first.records,undefined);
 assert.equal(f.props.get('VS_SHEET_MIGRATED_attendance_records'),undefined);
 const second=f.call(body);assert.equal(second.success,true);assert.equal(Object.keys(second.records).length,103);
 assert.equal(f.books.get(f.props.get('VS_MANAGED_SHEET_ID')).getSheetByName('attendance_records').getLastRow(),104);
 assert.equal(folder.files.filter(file=>!file.trash).length,103);
});
test('Sheet continuation values are inert quoted fragments; large Unicode records round-trip exactly',()=>{
 const f=storage(),notes='='.repeat(20000)+'😀'.repeat(50000),data={schoolId:A,name:'=HYPERLINK("unsafe")',notes};
 const result=f.call({action:'managed_records',operation:'write',collection:'students_directory',id:'safe',data});assert.equal(result.success,true);
 assert.equal(f.call({action:'managed_records',operation:'read',collection:'students_directory'}).records.safe.notes,notes);
 const tab=f.books.get(f.props.get('VS_MANAGED_SHEET_ID')).getSheetByName('students_directory');
 const row=tab.getRange(2,1,1,33).getValues()[0];assert.equal(row[5][0],"'");
 for(const chunk of row.slice(6).filter(Boolean)){assert.equal(chunk[0],'"');assert(chunk.length<50000);}
});
test('a deleted authoritative Sheet tab never silently becomes an empty collection',()=>{
 const f=storage();assert.equal(f.call({action:'managed_records',operation:'write',collection:'students_directory',id:'p',data:{schoolId:A,name:'Keep'}}).success,true);
 const book=f.books.get(f.props.get('VS_MANAGED_SHEET_ID')),insert=book.insertSheet;let created=0;
 book.getSheetByName=()=>null;book.insertSheet=name=>{created++;return insert(name);};
 assert.equal(f.call({action:'managed_records',operation:'read',collection:'students_directory'}).success,false);assert.equal(created,0);
 assert.equal(f.props.get('VS_SHEET_MIGRATED_students_directory'),'1');
});

test('managed expired login renews indefinitely while token/person/licence remain valid',()=>{
 const f=storage(),write=(collection,id,data)=>f.call({action:'managed_records',operation:'write',collection,id,data:{...data,schoolId:A}});
 const linkToken='x'.repeat(48);
 write('students_directory','pupil',{name:'Own pupil',class:'1',rollNo:'1',dob:'2015-01-01',mobileLinkToken:linkToken});
 const mobile=(request,lease={schoolId:A,expiresAt:Date.now()+60000})=>f.call({action:'managed_mobile',lease,request});
 const login=mobile({action:'mobile_login',role:'student',personId:'pupil',linkToken,studentClass:'1',rollNo:'1',dob:'2015-01-01'});
 assert.equal(login.success,true);
 const sessionId=crypto.createHash('sha256').update(login.sessionToken).digest('hex');
 const sessions=f.call({action:'managed_records',operation:'read',collection:'mobile_sessions'}).records;
 write('mobile_sessions',sessionId,{...sessions[sessionId],expiresAt:1});
 assert.equal(mobile({action:'mobile_dashboard',sessionToken:login.sessionToken}).success,false);
 const renewed=mobile({action:'mobile_refresh',sessionToken:login.sessionToken});
 assert.equal(renewed.success,true);assert.ok(renewed.expiresAt>Date.now());
 assert.equal(mobile({action:'mobile_refresh',sessionToken:login.sessionToken},{schoolId:B,expiresAt:Date.now()+60000}).success,false);
 assert.equal(mobile({action:'mobile_refresh',sessionToken:login.sessionToken},{schoolId:A,expiresAt:1}).success,false);
 assert.equal(mobile({action:'mobile_logout',sessionToken:login.sessionToken}).success,true);
 assert.equal(mobile({action:'mobile_refresh',sessionToken:login.sessionToken}).success,false);
});

test('authenticated Script diagnostics use fixed categories without leaking exception contents',()=>{
 const f=storage();
 for(const [message,code] of [['Permission denied secret-root-id','SCRIPT_PERMISSION_DENIED'],['Service invoked too many times: private-school','SCRIPT_QUOTA_EXCEEDED'],['Managed storage not prepared','SCRIPT_STORAGE_NOT_PREPARED']]) {
  f.context.VS_managedRoot=()=>{throw new Error(message);};
  const out=f.call({action:'managed_health'});
  assert.equal(out.success,false);assert.equal(out.code,code);
  assert.equal(JSON.stringify(out).includes(message),false);
 }
 const unauth=f.context.VS_managedHandle({postData:{contents:'malformed secret'}});
 assert.equal(unauth.code,'SCRIPT_OPERATION_FAILED');
 assert.equal(JSON.stringify(unauth).includes('malformed secret'),false);
});

test('health and storage readiness do not require optional owner email OAuth scope',()=>{
 const f=storage();let calls=0;
 f.context.Session={getEffectiveUser(){calls++;throw new Error('Specified permissions are not sufficient to call Session.getEffectiveUser. Required permissions: userinfo.email');}};
 const out=f.call({action:'managed_health'});
 assert.equal(out.success,true);assert.equal(out.storageReady,true);assert.equal(out.recordSyncVersion,2);assert.equal(out.googleEmail,'');assert.equal(calls,0);
});


test('owner execution diagnostics classify swallowed rejection without exposing raw school payload or secrets',()=>{
 const source=fs.readFileSync('../school-backend/managed/SaarthiManagedAdapter.gs','utf8'),logs=[];
 const c=vm.createContext({console:{info:line=>logs.push(JSON.parse(line))},PropertiesService:{getScriptProperties:()=>({getProperty:()=>A})},jsonResponse:x=>x});vm.runInContext(source,c);
 for(const [message,code] of [['Invalid request signature','SCRIPT_SIGNATURE_REJECTED'],['School Drive root mismatch','SCRIPT_ROOT_IDENTITY_MISMATCH'],['Invalid or duplicate legacy record; operator review required','SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED'],['Versioned document requires a matching revision','SCRIPT_DOCUMENT_REVISION_REQUIRED']]){
  c.VS_managedVerify=()=>{throw Object.assign(new Error(message),{stack:'Error private-secret\n at VS_managedVerify (Code:6521:7)'});};
  const result=c.VS_managedHandle({postData:{contents:'{}'}});assert.equal(result.success,false);assert.equal(result.code,'SCRIPT_OPERATION_FAILED');
  assert.equal(logs.at(-1).code,code);assert.equal(logs.at(-1).phase,'request_verification');assert.equal(logs.at(-1).line,6521);
 }
 c.VS_managedVerify=()=>({action:'managed_records'});c.VS_managedRecord=()=>{throw Object.assign(new Error('private student token path'),{stack:'Error private-secret\n at VS_sheetDecode (Code:6580:7)'});};
 const result=c.VS_managedHandle({postData:{contents:'{}'}});assert.equal(result.success,false);assert.equal(logs.at(-1).phase,'authorized_operation');assert.equal(logs.at(-1).code,'SCRIPT_OPERATION_FAILED');
 assert(!JSON.stringify(logs).includes('private'));assert(!JSON.stringify(logs).includes(A));
});


test('diagnostic owner cache is temporary metadata only and cache failure never changes request result',()=>{
 const logs=[],cached=[];
 const c=vm.createContext({console:{info:line=>logs.push(line)},Logger:{log:line=>logs.push(line)},CacheService:{getScriptCache:()=>({put:(...args)=>cached.push(args),get:()=>cached.at(-1)?.[1]})},PropertiesService:{getScriptProperties:()=>({getProperty:()=>A})},jsonResponse:x=>x});
 vm.runInContext(fs.readFileSync('../school-backend/managed/SaarthiManagedAdapter.gs','utf8'),c);
 c.VS_managedVerify=()=>{throw new Error('Invalid request signature');};
 const before=c.VS_managedHandle({postData:{contents:'{}'}});assert.equal(cached[0][0],'VS_SYNC_DIAGNOSTIC_V1');assert.equal(cached[0][2],1800);assert(!cached[0][1].includes(A));
 c.VS_readLastSyncDiagnostic();assert.equal(logs.at(-1),cached[0][1]);
 c.CacheService.getScriptCache=()=>{throw Error('Unavailable');};
 assert.deepEqual(c.VS_managedHandle({postData:{contents:'{}'}}),before);
});

test('UTF-8 signed multilingual school records are accepted and preserved',()=>{
 const f=storage(),data={schoolId:A,name:'বাংলা हिंदी विद्यालय',address:'গাঁও – स्कूल'};
 const result=f.call({action:'managed_records',operation:'write',collection:'students_directory',id:'unicode-student',data});
 assert.equal(result.success,true);
 const read=f.call({action:'managed_records',operation:'read',collection:'students_directory'});
 assert.equal(read.records['unicode-student'].name,data.name);
 assert.equal(read.records['unicode-student'].address,data.address);
});
