'use strict';
const {createHash}=require('node:crypto');

// Share only identical, *simultaneous* authenticated school delta reads.
// Never cache a completed snapshot: a later read must recheck original Drive
// revisions and external edits. No operation or provider receipt is acknowledged.
function createSchoolDeltaSingleflight(maxConcurrent=64){
 if(!Number.isInteger(maxConcurrent)||maxConcurrent<1||maxConcurrent>256)
  throw Error('Invalid school delta singleflight capacity');
 const inflight=new Map();
 return function run(school,body,read){
  if(typeof school!=='string'||!/^vs-[a-f0-9]{32}$/.test(school)||
     !body||body.action!=='managed_delta'||typeof read!=='function')
   throw Error('School-bound read-only delta required');
  const key=createHash('sha256')
   .update(JSON.stringify([school,body])).digest('hex');
  const current=inflight.get(key);
  if(current)return current;
  const task=Promise.resolve().then(read);
  if(inflight.size>=maxConcurrent)return task; // never share a wrong key
  inflight.set(key,task);
  const release=()=>{if(inflight.get(key)===task)inflight.delete(key)};
  task.then(release,release);
  return task;
 };
}
module.exports={createSchoolDeltaSingleflight};
