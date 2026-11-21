'use strict';
const assert=require('node:assert/strict'),crypto=require('node:crypto');
const {createManagedSchools,protect}=require('../../managed-schools');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32),key='c'.repeat(64),secret='d'.repeat(64),time=1800000000000;
// Firestore set({merge:true}) merges nested map fields; update of a
// top-level map replaces that map while retaining unrelated document fields.
function mergeMaps(current,value){
 const result={...current};for(const [key,item] of Object.entries(value)){
  result[key]=item&&Object.getPrototypeOf(item)===Object.prototype&&Object.keys(item).length
   ?mergeMaps(result[key]&&Object.getPrototypeOf(result[key])===Object.prototype?result[key]:{},item):item;
 }return result;
}
function fixture(fetchOverride,options={}){const docs=new Map(),users=new Map(),sent=[];
 const snap=p=>({exists:docs.has(p),data:()=>docs.get(p)});
 const db={doc:p=>({path:p,get:async()=>snap(p),set:async(v,o)=>docs.set(p,o?.merge?mergeMaps(docs.get(p)||{},v):v),update:async v=>{assert(docs.has(p));docs.set(p,{...docs.get(p),...v});}}),collection:name=>({add:async()=>{},where:(field,op,value)=>({get:async()=>({docs:[...docs.entries()].filter(([path,data])=>path.startsWith(name+'/')&&data[field]===value).map(([path,data])=>({id:path.split('/').pop(),data:()=>data}))}),limit:()=>({get:async()=>({empty:![...docs.entries()].some(([path,data])=>path.startsWith(name+'/')&&data[field]===value)})})})}),batch:()=>{const queue=[];return {create:(r,v)=>queue.push(()=>{assert(!docs.has(r.path));docs.set(r.path,v)}),set:(r,v,o)=>queue.push(()=>docs.set(r.path,o?.merge?{...docs.get(r.path),...v}:v)),commit:async()=>queue.forEach(f=>f())}}};
 db.runTransaction=async fn=>fn({get:async ref=>snap(ref.path),set:(ref,value,options)=>docs.set(ref.path,options?.merge?{...docs.get(ref.path),...value}:value)});
 const auth={verifyIdToken:async t=>{if(t==='developer')return {uid:'dev',developer:true};if(users.get(t)?.disabled)throw Error();if(!['A','B','forged','A-new-pc'].includes(t))throw Error();return {uid:['forged','A-new-pc'].includes(t)?'A':t,auth_time:time/1000-10,...(t==='forged'?{admin:true,schoolId:B}:{})}},createUser:async v=>{users.set('new',v);return {uid:'new'}},deleteUser:async u=>users.delete(u),generatePasswordResetLink:async e=>'https://reset.example/'+e,updateUser:async(u,v)=>users.set(u,{...users.get(u),...v}),revokeRefreshTokens:async()=>{}};
 for(const [uid,id]of [['A',A],['B',B]]){docs.set('school_memberships/'+uid,{schoolId:id,role:'school_admin',managed:true,active:true});docs.set('school_entitlements/'+id,{active:true,blocked:false,status:'trial',startsAt:time-1000,expiresAt:time+86400000});docs.set('platform_schools/'+id,{managed:true,authUid:uid,loginEmail:uid+'@school.example'});docs.set('school_storage_private/'+id,{url:'https://script.google.com/macros/s/'+id+'/exec',secret:protect(secret,key),ready:true});}
 const fetchImpl=async(url,opt)=>{sent.push({url,opt});if(fetchOverride)return fetchOverride(url,opt,body=>handle({method:'POST',headers:{},body}));const b=JSON.parse(opt.body);assert.equal(b.signature,crypto.createHmac('sha256',secret).update(b.schoolId+'\n'+b.timestamp+'\n'+b.nonce+'\n'+b.payload).digest('hex'));return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:b.schoolId,records:{},storageReady:true,personId:'verified-pupil',role:'student',expiresAt:time+30*86400000}),json:async()=>({success:true,schoolId:b.schoolId,storageReady:true})}};
 const handle=createManagedSchools({auth,db,projectId:'central',encryptionKey:key,fetchImpl,now:()=>time,scheduleHint:callback=>setImmediate(callback),...options});const call=(body,token='A')=>handle({method:'POST',headers:{authorization:'Bearer '+token},body});return {docs,users,sent,call,db,auth,handle};}
module.exports={fixture,A,B,key,secret,time};
