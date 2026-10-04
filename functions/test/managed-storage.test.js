'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict'),crypto=require('node:crypto'),fs=require('node:fs'),vm=require('node:vm');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32),secret='d'.repeat(64);
function storage(){
 const all=new Map();let serial=0;
 const iterator=items=>{let n=0;return {hasNext:()=>n<items.length,next:()=>items[n++]};};
 function folder(id,school){const children=[],files=[];const f={getId:()=>id,getName:()=>id,getDescription:()=> 'VIDYA_MANAGED_SCHOOL:'+school,getFolders:()=>iterator(children),getFoldersByName:name=>iterator(children.filter(c=>c.getName()===name)),createFolder:name=>{const c=folder(name,school);children.push(c);return c;},getFiles:()=>iterator(files.filter(x=>!x.trash)),getFilesByName:name=>iterator(files.filter(x=>!x.trash&&x.name===name)),createFile:(name,text,mime)=>{const file={id:'file'+ ++serial,name,text,mime,getId(){return this.id;},getParents:()=>iterator([f]),getBlob(){return {getDataAsString:()=>this.text,getBytes:()=>[...Buffer.from(this.text)],getContentType:()=>this.mime};},setContent(text){this.text=text;},setTrashed(v){this.trash=v;}};files.push(file);all.set(file.id,file);return file;}};all.set(id,f);return f;}
 const roots={[A]:folder('rootA',A),[B]:folder('rootB',B)};
 const props=new Map([['VS_MANAGED_SCHOOL_ID',A],['VS_MANAGED_ROOT_ID','rootA'],['VS_MANAGED_SECRET',secret]]);
 const p={getProperty:k=>props.get(k),setProperty:(k,v)=>props.set(k,v),getProperties:()=>Object.fromEntries(props),deleteProperty:k=>props.delete(k)};
 const context=vm.createContext({Date,JSON,Number,String,Object,Error,PropertiesService:{getScriptProperties:()=>p},DriveApp:{getFolderById:id=>all.get(id),getFileById:id=>all.get(id)},Utilities:{base64EncodeWebSafe:v=>Buffer.from(v).toString('base64url'),computeHmacSha256Signature:(s,k)=>[...crypto.createHmac('sha256',k).update(s).digest()]},LockService:{getScriptLock:()=>({waitLock(){},releaseLock(){}})},jsonResponse:r=>JSON.parse(JSON.stringify(r))});
 vm.runInContext(fs.readFileSync('../school-backend/managed/SaarthiManagedAdapter.gs','utf8'),context);
 const call=body=>{const b={schoolId:A,timestamp:Date.now(),nonce:crypto.randomBytes(24).toString('hex'),payload:JSON.stringify(body)};b.signature=crypto.createHmac('sha256',secret).update(A+'\n'+b.timestamp+'\n'+b.nonce+'\n'+b.payload).digest('hex');return context.VS_managedHandle({postData:{contents:JSON.stringify(b)}});};
 return {call,roots,all};
}
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
