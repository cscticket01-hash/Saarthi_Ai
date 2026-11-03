'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {createDeleteEverywhere}=require('../delete-everywhere');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32),root='schools/'+A+'/students_directory/one';
const request={deleteEverywhereVersion:1,operation:'delete',collection:'students_directory',id:'one',syncProtocol:2};
const result={success:true,schoolId:A,syncProtocol:2,recordRevision:'drive-one',deleteEverywhereVersion:1,driveDeletionComplete:true,deletionTargets:[{collection:'students_directory',id:'one',generation:'p-old'}]};
function fixture(entries=[]){const data=new Map(entries),calls=[];return {data,calls,cleanup:createDeleteEverywhere({db:{doc:path=>({path}),runTransaction:async fn=>{const writes=[];const value=await fn({get:async ref=>({exists:data.has(ref.path),data:()=>data.get(ref.path)}),delete:ref=>writes.push(ref.path)});for(const path of writes){calls.push(path);data.delete(path);}return value;}}})};}
test('exact tenant operations are removed; auth/licence/foreign school and newer occupants survive',async()=>{
 const other='schools/'+B+'/students_directory/one',licence='school_entitlements/'+A;
 const f=fixture([[root,{schoolId:A,mobileStableId:'p-old',name:'Deleted pupil'}],[other,{schoolId:B,name:'Other school'}],[licence,{active:true}]]);
 const r=await f.cleanup.finish(A,request,result);assert.equal(r.firebaseDeletionComplete,true);assert.equal(r.firebaseDeletedRecords,1);assert(!f.data.has(root));assert(f.data.has(other));assert(f.data.has(licence));assert.deepEqual(f.calls,[root]);
 const retry=await f.cleanup.finish(A,request,result);assert.equal(retry.firebaseDeletedRecords,0);
});
test('replacement generation and foreign ownership never get deleted',async()=>{
 for(const row of [{schoolId:A,mobileStableId:'p-new'},{schoolId:B,mobileStableId:'p-old'}]){
  const f=fixture([[root,row]]);await assert.rejects(f.cleanup.finish(A,request,result));assert(f.data.has(root));assert.deepEqual(f.calls,[]);
 }
});
test('partial completion resumes original exact targets without duplicate deletes',async()=>{
 const child='schools/'+A+'/documents/doc';const f=fixture([[root,{schoolId:A,mobileStableId:'p-old'}],[child,{schoolId:A,personId:'p-new'}]]);
 const ack={...result,deletionTargets:[...result.deletionTargets,{collection:'documents',id:'doc',generation:'p-old'}]};
 await assert.rejects(f.cleanup.finish(A,request,ack));assert(!f.data.has(root));assert(f.data.has(child));
 f.data.set(child,{schoolId:A,personId:'p-old'});await f.cleanup.finish(A,request,ack);assert.deepEqual(f.calls,[root,child]);
});
test('unverified ACKs, unsupported namespaces and path injection fail before any Firebase mutation',async()=>{
 const invalid=[{...result,driveDeletionComplete:false},{...result,recordRevision:'cf-not-final'},{...result,recordRevision:'live-not-final'},{...result,schoolId:B},{...result,deletionTargets:[{collection:'school_entitlements',id:A}]},{...result,deletionTargets:[{collection:'students_directory',id:'../one'}]},{...result,deletionTargets:[{collection:'documents',id:'one'}]}];
 for(const ack of invalid){const f=fixture([[root,{schoolId:A,mobileStableId:'p-old'}]]);await assert.rejects(f.cleanup.finish(A,request,ack));assert.equal(f.calls.length,0);}
});
