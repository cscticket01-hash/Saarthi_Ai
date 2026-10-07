'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict'),crypto=require('node:crypto'),fs=require('node:fs'),vm=require('node:vm');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32),secret='d'.repeat(64);
function storage(){
 const all=new Map();let serial=0;
 const iterator=items=>{let n=0;return {hasNext:()=>n<items.length,next:()=>items[n++]};};
 function folder(id,school){const children=[],files=[];const f={getId:()=>id,getName:()=>id,getDescription:()=> 'VIDYA_MANAGED_SCHOOL:'+school,getFolders:()=>iterator(children),getFoldersByName:name=>iterator(children.filter(c=>c.getName()===name)),createFolder:name=>{const c=folder(name,school);children.push(c);return c;},getFiles:()=>iterator(files.filter(x=>!x.trash)),getFilesByName:name=>iterator(files.filter(x=>!x.trash&&x.name===name)),createFile:(name,text,mime)=>{if(typeof name==='object'){mime=name.mime;text=Buffer.from(name.bytes).toString('binary');name=name.name;}const file={id:'file'+ ++serial,name,text,mime,getId(){return this.id;},getDescription(){return this.description||'';},setDescription(v){this.description=v;},getSize(){return Buffer.byteLength(this.text);},getParents:()=>iterator([f]),getBlob(){return {getDataAsString:()=>this.text,getBytes:()=>[...Buffer.from(this.text)],getContentType:()=>this.mime};},setContent(text){this.text=text;},setTrashed(v){this.trash=v;}};files.push(file);all.set(file.id,file);return file;}};all.set(id,f);return f;}
 const roots={[A]:folder('rootA',A),[B]:folder('rootB',B)};
 const props=new Map([['VS_MANAGED_SCHOOL_ID',A],['VS_MANAGED_ROOT_ID','rootA'],['VS_MANAGED_SECRET',secret]]);
 const p={getProperty:k=>props.get(k),setProperty:(k,v)=>props.set(k,v),getProperties:()=>Object.fromEntries(props),deleteProperty:k=>props.delete(k)};
 const context=vm.createContext({Date,JSON,Number,String,Object,Error,PropertiesService:{getScriptProperties:()=>p},DriveApp:{getFolderById:id=>all.get(id),getFileById:id=>all.get(id)},Utilities:{formatDate:()=> '2026-10-05',getUuid:()=>crypto.randomUUID(),DigestAlgorithm:{SHA_256:'sha256'},base64Decode:v=>[...Buffer.from(v,'base64')],base64Encode:v=>Buffer.from(v).toString('base64'),newBlob:(bytes,mime,name)=>({bytes,mime,name}),computeDigest:(_,v)=>[...crypto.createHash('sha256').update(typeof v==='string'?v:Buffer.from(v)).digest()],base64EncodeWebSafe:v=>Buffer.from(v).toString('base64url'),computeHmacSha256Signature:(s,k)=>[...crypto.createHmac('sha256',k).update(s).digest()]},LockService:{getScriptLock:()=>({waitLock(){},releaseLock(){}})},jsonResponse:r=>JSON.parse(JSON.stringify(r))});
 vm.runInContext(fs.readFileSync('../school-backend/managed/SaarthiManagedAdapter.gs','utf8'),context);
 vm.runInContext(fs.readFileSync('../school-backend/managed/SaarthiManagedMobile.gs','utf8'),context);
 const call=body=>{const b={schoolId:A,timestamp:Date.now(),nonce:crypto.randomBytes(24).toString('hex'),payload:JSON.stringify(body)};b.signature=crypto.createHmac('sha256',secret).update(A+'\n'+b.timestamp+'\n'+b.nonce+'\n'+b.payload).digest('hex');return context.VS_managedHandle({postData:{contents:JSON.stringify(b)}});};
 return {call,roots,all};
}
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
 assert.equal(f.call({action:'managed_restore',fileId:backup.fileId}).copied,1);
 assert.equal(f.call({action:'managed_records',operation:'read',collection:'students_directory'}).records.student.name,'Original');
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
test('managed summary measures own root only and includes actual student count',()=>{
 const f=storage();f.call({action:'managed_records',operation:'write',collection:'students_directory',id:'pupil',data:{schoolId:A,name:'A'}});f.roots[B].createFile('foreign','foreign-school-data','text/plain');
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
