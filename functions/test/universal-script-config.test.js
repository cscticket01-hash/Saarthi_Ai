'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const source=fs.readFileSync('../school-backend/managed/SaarthiManagedAdapter.gs','utf8');
const A='vs-'+ 'a'.repeat(32),B='vs-'+ 'b'.repeat(32),T='vs-db8afb01a3be46a983c8284714d06e5d';
function fixture(entries=[]){
 const props=new Map(entries),calls=[];let created=0;
 const root={getId:()=> 'root',setDescription:v=>root.description=v,getDescription:()=>root.description};
 const c=vm.createContext({JSON,String,Error,Utilities:{getUuid:()=> 'a'.repeat(32)},PropertiesService:{getScriptProperties:()=>({getProperty:k=>props.get(k)??null,setProperty:(k,v)=>props.set(k,v)})},DriveApp:{createFolder:()=>{created++;return root;},getFolderById:()=>root},UrlFetchApp:{fetch:(url,options)=>{calls.push({url,options});return {getResponseCode:()=>200,getContentText:()=>JSON.stringify({success:true,schoolId:props.get('VS_MANAGED_SCHOOL_ID')})};}},jsonResponse:x=>x});
 vm.runInContext(source,c);return {c,props,calls,root,get created(){return created;}};
}
test('identical universal source binds two schools from owner properties without source edits',()=>{
 for(const school of [A,B]){const f=fixture([['VS_SETUP_SCHOOL_ID',school],['VS_SETUP_CREATE_NEW_STORAGE','true']]);assert.equal(f.c.VS_prepareSchoolStorage().schoolId,school);assert.equal(f.created,1);f.c.VS_prepareSchoolStorage();assert.equal(f.created,1);}
});
test('new storage defaults denied and malformed consent cannot create a root',()=>{
 for(const consent of [null,'false','TRUE','1','']){const f=fixture([['VS_SETUP_SCHOOL_ID',A],...(consent===null?[]:[['VS_SETUP_CREATE_NEW_STORAGE',consent]])]);assert.throws(()=>f.c.VS_prepareSchoolStorage());assert.equal(f.created,0);}
});
test('existing upgrade preserves root and secret; conflicting school fails',()=>{
 const f=fixture([['VS_MANAGED_SCHOOL_ID',A],['VS_MANAGED_ROOT_ID','root'],['VS_MANAGED_SECRET','s'.repeat(64)],['VS_SETUP_CREATE_NEW_STORAGE','true']]);f.root.description='VIDYA_MANAGED_SCHOOL:'+A;f.c.VS_prepareSchoolStorage();assert.equal(f.created,0);assert.equal(f.props.get('VS_MANAGED_SECRET'),'s'.repeat(64));f.props.set('VS_SETUP_SCHOOL_ID',B);assert.throws(()=>f.c.VS_prepareSchoolStorage(),/rebinding/);assert.equal(f.created,0);
});
test('central endpoint is owner-configured exact allowlist with isolated TEST binding',()=>{
 const f=fixture();assert.equal(f.c.VS_managedCentralEndpoint(A),'https://saarthi-oauth-staging.onrender.com/school-cloud');
 for(const value of ['https://evil.invalid','https://saarthi-oauth-staging.onrender.com/school-cloud/','']){f.props.set('VS_MANAGED_CENTRAL_ENDPOINT',value);assert.throws(()=>f.c.VS_managedCentralEndpoint(A),/Untrusted/);}
 f.props.set('VS_MANAGED_CENTRAL_ENDPOINT','https://saarthi-sync-v2-test.onrender.com/school-cloud');assert.throws(()=>f.c.VS_managedCentralEndpoint(A),/TEST/);assert.equal(f.c.VS_managedCentralEndpoint(T),'https://saarthi-sync-v2-test.onrender.com/school-cloud');
});
test('connection ignores caller URL and disables secret-bearing redirects',()=>{
 const f=fixture([['VS_MANAGED_SCHOOL_ID',A],['VS_MANAGED_ROOT_ID','root'],['VS_MANAGED_SECRET','a'.repeat(64)]]);f.root.description='VIDYA_MANAGED_SCHOOL:'+A;
 f.c.VS_managedConnect({schoolId:A,ticket:'b'.repeat(64),endpoint:'https://evil.invalid'});assert.equal(f.calls.length,1);assert.equal(f.calls[0].options.followRedirects,false);assert.equal(f.calls[0].url,'https://saarthi-oauth-staging.onrender.com/school-cloud');
});
