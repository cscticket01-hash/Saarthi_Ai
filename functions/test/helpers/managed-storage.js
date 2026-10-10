'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict'),crypto=require('node:crypto'),fs=require('node:fs'),vm=require('node:vm');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32),secret='d'.repeat(64);
function storage(){
 const all=new Map();let serial=0;
 const iterator=items=>{let n=0;return {hasNext:()=>n<items.length,next:()=>items[n++]};};
 function folder(id,school){const children=[],files=[];const f={files:files,getParents(){return iterator(this.parent?[this.parent]:[]);},getId:()=>id,getName:()=>id,getDescription:()=> 'VIDYA_MANAGED_SCHOOL:'+school,getFolders:()=>iterator(children),getFoldersByName:name=>iterator(children.filter(c=>c.getName()===name)),createFolder:name=>{const c=folder(name,school);c.parent=f;children.push(c);return c;},getFiles:()=>iterator(files.filter(x=>!x.trash)),getFilesByName:name=>iterator(files.filter(x=>!x.trash&&x.name===name)),createFile:(name,text,mime)=>{if(typeof name==='object'){mime=name.mime;text=Buffer.from(name.bytes).toString('binary');name=name.name;}const file={id:'file'+ ++serial,name,text,mime,getId(){return this.id;},getName(){return this.name;},getMimeType(){return this.mime;},getDescription(){return this.description||'';},setDescription(v){this.description=v;},getSize(){return Buffer.byteLength(this.text);},parent:f,getParents(){return iterator([this.parent]);},moveTo(target){const old=this.parent.files.indexOf(this);if(old>=0)this.parent.files.splice(old,1);target.files.push(this);this.parent=target;return this;},getBlob(){return {getDataAsString:()=>this.text,getBytes:()=>[...Buffer.from(this.text)],getContentType:()=>this.mime};},setContent(text){this.text=text;},isTrashed(){return this.trash===true;},setTrashed(v){this.trash=v;}};files.push(file);all.set(file.id,file);return file;}};all.set(id,f);return f;}
 const roots={[A]:folder('rootA',A),[B]:folder('rootB',B)};
 const props=new Map([['VS_MANAGED_SCHOOL_ID',A],['VS_MANAGED_ROOT_ID','rootA'],['VS_MANAGED_SECRET',secret]]);
 const p={getProperty:k=>props.get(k),setProperty:(k,v)=>props.set(k,v),getProperties:()=>Object.fromEntries(props),deleteProperty:k=>props.delete(k)};
 const books=new Map();
 function sheet(name) {
  const rows=[];let maxRows=1000,maxColumns=26;
  return {name,getMaxRows:()=>maxRows,getMaxColumns:()=>maxColumns,insertRowsAfter(_,count){maxRows+=count;},insertColumnsAfter(_,count){maxColumns+=count;},getName:()=>name,getLastRow:()=>rows.length,setFrozenRows(){},getRange(r,c,h,w) {
   return {getRow:()=>r,
    setValues(values){for(let y=0;y<h;y++){rows[r+y-1]??=[];for(let x=0;x<w;x++)rows[r+y-1][c+x-1]=values[y][x];}},
    getValues:()=>Array.from({length:h},(_,y)=>Array.from({length:w},(_,x)=>rows[r+y-1]?.[c+x-1]??'')),
    createTextFinder(value){return {
     matchEntireCell(){return this;},matchCase(){return this;},
     findAll:()=>Array.from({length:h},(_,y)=>r+y).filter(row=>rows[row-1]?.[c-1]===value).map(row=>({getRow:()=>row}))
    };}
   };
  }};
 }

 const SpreadsheetApp={flush(){},openById:id=>books.get(id),create(name){const file=roots[A].createFile(name,'','application/vnd.google-apps.spreadsheet'),tabs=new Map();const book={getId:()=>file.id,getSheetByName:n=>tabs.get(n),insertSheet(n){const tab=sheet(n);tabs.set(n,tab);return tab;}};books.set(file.id,book);return book;}};
 const context=vm.createContext({SpreadsheetApp,Date,JSON,Number,String,Object,Error,PropertiesService:{getScriptProperties:()=>p},DriveApp:{getFolderById:id=>all.get(id),getFileById:id=>all.get(id),getFilesByName:name=>iterator([...all.values()].filter(f=>f.name===name&&!f.trash))},Utilities:{Charset:{UTF_8:'UTF-8'},formatDate:()=> '2026-10-05',getUuid:()=>crypto.randomUUID(),DigestAlgorithm:{SHA_256:'sha256'},base64Decode:v=>[...Buffer.from(v,'base64')],base64Encode:v=>Buffer.from(v).toString('base64'),newBlob:(bytes,mime,name)=>({bytes,mime,name}),computeDigest:(_,v)=>[...crypto.createHash('sha256').update(typeof v==='string'?v:Buffer.from(v)).digest()],base64EncodeWebSafe:v=>Buffer.from(v).toString('base64url'),computeHmacSha256Signature:(s,k,charset)=>[...crypto.createHmac('sha256',k).update(s,charset==='UTF-8'?'utf8':'latin1').digest()]},LockService:{getScriptLock:()=>({waitLock(){},releaseLock(){}})},jsonResponse:r=>JSON.parse(JSON.stringify(r))});
 vm.runInContext(fs.readFileSync('../school-backend/managed/SaarthiManagedAdapter.gs','utf8'),context);
 vm.runInContext(fs.readFileSync('../school-backend/managed/SaarthiManagedMobile.gs','utf8'),context);
 vm.runInContext(fs.readFileSync('../school-backend/managed/SaarthiManagedDisaster.gs','utf8'),context);
 const call=body=>{const b={schoolId:A,timestamp:Date.now(),nonce:crypto.randomBytes(24).toString('hex'),payload:JSON.stringify(body)};b.signature=crypto.createHmac('sha256',secret).update(A+'\n'+b.timestamp+'\n'+b.nonce+'\n'+b.payload).digest('hex');return context.VS_managedHandle({postData:{contents:JSON.stringify(b)}});};
 return {call,roots,all,props,books,context,collections:vm.runInContext('VS_LAYOUT_COLLECTIONS',context)};
}

module.exports={storage,A,B};
