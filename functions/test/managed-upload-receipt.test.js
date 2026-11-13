'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),crypto=require('node:crypto');
for(const source of ['SaarthiManagedAdapter.gs','SaarthiManagedAll.gs'])test(source+' upload lookup revalidates original ownership and all immutable fields',()=>{
 const cache=new Map();let foreign=false,reads=0;
 const file={getId:()=> 'original',getName:()=> 'original.pdf',getMimeType:()=> 'application/pdf',getSize:()=>85,getDescription:()=> 'exact-marker'};
 const c=vm.createContext({console,CacheService:{getScriptCache:()=>({get:k=>cache.get(k),put:(k,v)=>cache.set(k,v)})}});
 vm.runInContext(fs.readFileSync('../school-backend/managed/'+source,'utf8'),c);
 c.VS_layoutHash=x=>crypto.createHash('sha256').update(JSON.stringify(x)).digest('hex');
 c.VS_managedFile=id=>{reads++;if(foreign)throw Error('foreign root');assert.equal(id,'original');return file;};
 const b={uploadKey:'same-key',name:'original.pdf',mime:'application/pdf'};
 const lookup=(school='school',root='root',body=b,marker='exact-marker',size=85,digest='digest')=>c.VS_cachedOriginalUpload(school,root,body,marker,size,digest);
 assert.equal(lookup(),null);assert.equal(reads,0);
 c.VS_rememberOriginalUpload('school','root',b,file,85,'digest');assert.equal(lookup(),file);
 for(const args of [['other'],['school','other'],['school','root',{...b,name:'replacement.pdf'}],['school','root',b,'changed'],['school','root',b,'exact-marker',86],['school','root',b,'exact-marker',85,'changed']])assert.equal(lookup(...args),null);
 foreign=true;assert.equal(lookup(),null);
 c.CacheService.getScriptCache=()=>{throw Error('outage');};assert.equal(lookup(),null);c.VS_rememberOriginalUpload('school','root',b,file,85,'digest');
});
